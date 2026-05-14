# Plan: Segmented Stream Rendering (Option 2)

> **Status:** Draft — ready for implementation  
> **Goal:** Replace flat text+tools-after with ordered typed segments that mirror the TUI's `streamSegments`  
> **Files touched:** `hermes-state.el`, `hermes-render.el`, `test/hermes-state-test.el`, `test/hermes-render-test.el`, `HERMES-TUI-REFERENCE.md`  

---

## 1. The Problem

### Current architecture (flat)

```
** assistant :hermes:
:PROPERTIES:
:END:
[all text streamed here, end-to-end]

*** terminal (0.5s)
[tool output]
```

Tools are rendered **after** all text, regardless of when they executed in the turn narrative. This breaks reading flow.

### Target architecture (segmented)

```
** assistant :hermes:
:PROPERTIES:
:END:
#+begin_example Reasoning
I should check the system uptime...
#+end_example

*** terminal (running…)
:CONTEXT:
uptime
:END:

#+begin_example Reasoning
Now I have the uptime data, I should summarize it concisely.
#+end_example

System has been up for 3 days, 4 hours, 22 minutes.
```

Each block appears **in the order it happened** during the turn.

### TUI reference

The TUI uses `turnState.streamSegments` (array of typed segments):
- `text` segments — assistant prose
- `tool` segments — tool calls with context/output
- `reasoning` segments — thinking/reasoning blocks
- `system` segments — status updates, inline notes

Segments are ordered by arrival time and rendered sequentially in the transcript.

---

## 2. Data Model Changes

### 2.1 New struct: `hermes-segment`

```elisp
(cl-defstruct (hermes-segment (:copier hermes-segment-copy))
  type        ; 'text | 'thinking | 'reasoning | 'tool | 'system
  content     ; string for text/thinking/reasoning/system
              ; hermes-tool for tool segments
  id          ; unique segment id (for stable updates)
  timestamp)  ; when the segment was created
```

**Rationale:** Each segment is an atomic unit of the turn narrative. The copier follows the immutable pattern. `id` lets the renderer match segments across state updates without relying on positional index (which shifts when segments are inserted mid-stream).

### 2.2 Replace `hermes-stream` flat fields with segments

Current:
```elisp
(cl-defstruct (hermes-stream (:copier hermes-stream-copy))
  text thinking reasoning
  tools)
```

Target:
```elisp
(cl-defstruct (hermes-stream (:copier hermes-stream-copy))
  segments    ; vector of hermes-segment, ordered by arrival
  tools)      ; keep for now? (see migration below)
```

**Rationale:** All content lives in `segments` in arrival order. The renderer walks this vector sequentially.

### 2.3 Add `segments` to `hermes-message`

```elisp
(cl-defstruct (hermes-message (:copier hermes-message-copy))
  kind text thinking reasoning tools usage timestamp
  segments    ; vector of hermes-segment — committed turn narrative
  subagents)
```

On `message.complete`, copy `stream.segments` into `message.segments`.

**Question:** Do we keep `text`, `thinking`, `reasoning`, `tools` slots on `hermes-message` for backward compatibility, or deprecate them?

**Recommendation:** Keep them for now but mark as deprecated in comments. Populate them from segments during commit so existing code that reads `hermes-message-text` still works. Remove in a future cleanup pass.

---

## 3. Reducer Changes

### 3.1 Helper: segment management

```elisp
(defun hermes--last-segment (stream)
  "Return the last segment in STREAM, or nil."
  (let ((segs (hermes-stream-segments stream)))
    (when (> (length segs) 0)
      (aref segs (1- (length segs))))))

(defun hermes--append-segment (stream seg)
  "Return a new stream with SEG appended to segments."
  (hermes--with-copy stream hermes-stream-copy s
    (setf (hermes-stream-segments s)
          (hermes--vector-append (hermes-stream-segments stream) seg))))

(defun hermes--update-last-segment (stream updater)
  "Return a new stream with the last segment replaced by (UPDATER last-seg)."
  ...)
```

### 3.2 `message.start`

Create empty stream with empty segments vector:
```elisp
(make-hermes-stream :segments [])
```

### 3.3 `message.delta`

Two cases:

**Case A: last segment is text**
- Append delta text to `last-segment.content`

**Case B: last segment is non-text (or no segments)**
- Create new `hermes-segment` with `type='text`, `content=delta-text`
- Append to segments

```elisp
(let* ((str (or (hermes-state-stream state)
                (make-hermes-stream :segments [])))
       (chunk (or (hermes--get p "text") ""))
       (last (hermes--last-segment str)))
  (if (and last (eq 'text (hermes-segment-type last)))
      ;; Append to existing text segment
      (hermes--update-last-segment str
        (lambda (seg)
          (hermes--with-copy seg hermes-segment-copy s
            (setf (hermes-segment-content s)
                  (concat (hermes-segment-content seg) chunk)))))
    ;; Create new text segment
    (hermes--append-segment str
      (make-hermes-segment :type 'text :content chunk))))
```

### 3.4 `thinking.delta`

Same pattern as `message.delta` but with `type='thinking`:

```elisp
(let* ((str ...)
       (chunk ...)
       (last (hermes--last-segment str)))
  (if (and last (eq 'thinking (hermes-segment-type last)))
      (append to last thinking segment)
    (create new thinking segment and append)))
```

### 3.5 `reasoning.delta` / `reasoning.available`

Same as thinking but with `type='reasoning`.

### 3.6 `tool.generating`

Create a new tool segment when a tool first appears:

```elisp
(let* ((str ...)
       (tid ...)
       (tname ...))
  (if tool already in segments
      state  ; dedupe
    (hermes--append-segment str
      (make-hermes-segment
       :type 'tool
       :content (make-hermes-tool :id tid :name tname :status 'generating)))))
```

**Important:** The segment's `content` is the `hermes-tool` struct. This keeps tool state localized to its segment.

### 3.7 `tool.start`

Find the tool segment by `tool_id`, update its `hermes-tool` status to `running`, set `context`.

### 3.8 `tool.progress`

Find the tool segment, update `hermes-tool-preview`.

### 3.9 `tool.complete`

Find the tool segment, update `hermes-tool` status/output/error/duration/inline-diff/todos.

### 3.10 `message.complete`

Copy `stream.segments` into `message.segments`. Also populate deprecated `text`/`thinking`/`reasoning`/`tools` slots for backward compatibility.

### 3.11 `error`

Commit stream as-is (preserving segments), append error system message.

---

## 4. Renderer Changes

### 4.1 Current markers (to be replaced)

Current markers:
- `hermes--stream-content-start` — start of text
- `hermes--stream-stable-end` — stable/unstable boundary
- `hermes--stream-end` — end of text
- `hermes--stream-thinking-marker` — start of thinking blocks
- `hermes--stream-tools-marker` — start of tool blocks

These assume flat regions. Segmented rendering needs a different approach.

### 4.2 New marker strategy: per-segment or region-based

**Option A: Single region, full rewrite**
- One marker at start of assistant content (after property drawer)
- One marker at end of assistant content
- On every state update: delete entire region, re-render all segments from scratch
- **Simple** but wasteful for large streams (rewrites entire turn on every delta)

**Option B: Per-segment markers**
- Each segment gets a start marker
- On update: find changed segment by ID, delete/re-render only that segment
- **Efficient** but complex marker bookkeeping

**Option C: Hybrid — diff-based**
- Walk old segments vs new segments
- For unchanged segments: skip
- For changed segments: delete/re-render
- For new segments: insert at correct position
- **Most efficient**, moderate complexity

**Recommendation:** Start with **Option A** (full rewrite during streaming). It's simple and correct. Optimize to **Option C** later if profiling shows it's needed.

### 4.3 Segment formatters

```elisp
(defun hermes--format-segment (seg)
  "Return Org string for a single SEGMENT."
  (pcase (hermes-segment-type seg)
    ('text (hermes-md-to-org (hermes-segment-content seg)))
    ('thinking (hermes--format-thinking-block (hermes-segment-content seg) nil))
    ('reasoning (hermes--format-thinking-block nil (hermes-segment-content seg)))
    ('tool (hermes--format-tool (hermes-segment-content seg)))
    ('system (format "#+begin_comment\n%s\n#+end_comment\n" (hermes-segment-content seg)))
    (_ "")))
```

### 4.4 Stream rendering

```elisp
(defun hermes--render-stream-segments (segments)
  "Render all SEGMENTS in order into the buffer."
  (let ((start (or (and (markerp hermes--stream-segments-start)
                        (marker-position hermes--stream-segments-start))
                   (point-max)))
        (end (or (and (markerp hermes--stream-segments-end)
                      (marker-position hermes--stream-segments-end))
                 (point-max))))
    ;; Delete old content
    (when (> end start)
      (delete-region start end))
    ;; Insert new content
    (goto-char start)
    (dotimes (i (length segments))
      (let ((formatted (hermes--format-segment (aref segments i))))
        (when (> (length formatted) 0)
          (insert formatted)
          ;; Ensure blank line between segments
          (unless (or (eobp) (looking-at-p "\n"))
            (insert "\n")))))
    ;; Update end marker
    (set-marker hermes--stream-segments-end (point))))
```

**New markers needed:**
- `hermes--stream-segments-start` — after assistant property drawer
- `hermes--stream-segments-end` — end of all segments

### 4.5 Stable/unstable optimization

For text segments specifically, we can still do stable/unstable splitting within the segment's content. But since we're doing full rewrites during streaming (Option A), this optimization is deferred.

**Future optimization:** Within a text segment, track how much has been converted from markdown→Org and only convert the new suffix.

### 4.6 Committed message rendering

When a message is committed, the stream markers are dropped and the segments become static text in the buffer. No special handling needed — the segments were already rendered in order.

---

## 5. UI Reducer Changes

The UI reducer already handles events well. Minor updates:

- `tool.generating` / `tool.start` → status text: "Running X…"
- `message.complete` → clear status
- `error` → clear status

No structural changes needed.

---

## 6. Testing Plan

### 6.1 State reducer tests

| Test | What it checks |
|------|----------------|
| `segments-start-empty` | `message.start` creates stream with empty segments |
| `message-delta-creates-text-segment` | First delta creates text segment |
| `message-delta-appends-to-text-segment` | Second delta appends to same segment |
| `message-delta-after-tool-creates-new-text-segment` | Delta after tool creates new text segment (not append to tool) |
| `thinking-delta-creates-thinking-segment` | Thinking creates separate segment |
| `reasoning-delta-creates-reasoning-segment` | Reasoning creates separate segment |
| `tool-generating-creates-tool-segment` | Tool appears as segment |
| `tool-complete-updates-segment` | Tool segment updated with output |
| `segments-ordered-by-arrival` | Text→tool→text produces 3 segments in order |
| `message-complete-commits-segments` | Segments survive commit to message |
| `message-complete-populates-deprecated-slots` | text/thinking/tools still set for compat |
| `error-commits-segments` | Partial segments preserved on error |

### 6.2 Renderer tests

| Test | What it checks |
|------|----------------|
| `segment-text-rendered` | Text segment renders as markdown→Org |
| `segment-thinking-rendered` | Thinking segment renders as example block |
| `segment-tool-rendered` | Tool segment renders as headline |
| `segments-ordered-in-buffer` | Text→tool→text appears in correct order |
| `segment-update-rewrites` | Updating segment content rewrites in place |
| `blank-line-between-segments` | Each segment separated by blank line |

### 6.3 Integration tests

| Test | What it checks |
|------|----------------|
| `full-turn-with-interleaved-tool` | Realistic turn: text→reasoning→tool→text |
| `multiple-tools-ordered` | tool1→tool2→text appears in correct order |
| `thinking-before-and-after-tool` | Thinking segments surround tool segment |

---

## 7. Migration & Backward Compatibility

### 7.1 Deprecation strategy

Keep these slots on `hermes-message` but mark deprecated:
- `text` — derive from text segments
- `thinking` — derive from thinking segments
- `reasoning` — derive from reasoning segments
- `tools` — derive from tool segments

During `message.complete`, populate deprecated slots from segments:
```elisp
(let* ((segs (hermes-stream-segments str))
       (text-parts nil)
       (thinking-parts nil)
       (reasoning-parts nil)
       (tools-vec nil))
  (dotimes (i (length segs))
    (let ((seg (aref segs i)))
      (pcase (hermes-segment-type seg)
        ('text (push (hermes-segment-content seg) text-parts))
        ('thinking (push (hermes-segment-content seg) thinking-parts))
        ('reasoning (push (hermes-segment-content seg) reasoning-parts))
        ('tool (push (hermes-segment-content seg) tools-vec)))))
  ;; Build message with both segments and deprecated slots
  (make-hermes-message
   :segments segs
   :text (apply #'concat (nreverse text-parts))
   :thinking (apply #'concat (nreverse thinking-parts))
   ...))
```

### 7.2 Breaking changes

- `hermes-stream-text` accessor will return nil or empty string (since text lives in segments now)
- Any code that reads `stream.text` directly needs to be updated
- Any code that reads `message.text` directly still works (deprecated slot populated)

### 7.3 Files to audit for `stream.text` usage

- `hermes-render.el`: `hermes--rewrite-stream` (will be replaced)
- `hermes-state.el`: `message.complete` reducer (already being changed)
- Tests: any test that checks `(hermes-stream-text ...)`

---

## 8. Implementation Order

### Phase 1: Data model (1 hour)
1. Add `hermes-segment` struct
2. Change `hermes-stream` to use `segments` vector
3. Add `segments` slot to `hermes-message`
4. Run tests — should fail (expected, no reducer logic yet)

### Phase 2: Reducer (2 hours)
1. Implement segment helpers (`last-segment`, `append-segment`, `update-last-segment`)
2. Update `message.start` to create empty segments
3. Update `message.delta` to create/append text segments
4. Update `thinking.delta` for thinking segments
5. Update `reasoning.delta` / `reasoning.available` for reasoning segments
6. Update `tool.generating` / `tool.start` / `tool.progress` / `tool.complete` for tool segments
7. Update `message.complete` to commit segments + populate deprecated slots
8. Update `error` to commit segments
9. Write reducer tests

### Phase 3: Renderer (2 hours)
1. Add `hermes--stream-segments-start` / `hermes--stream-segments-end` markers
2. Implement `hermes--render-stream-segments` (Option A: full rewrite)
3. Implement `hermes--format-segment`
4. Wire into `hermes--render` hook (replace old flat rendering)
5. Update `hermes--stream-begin` to initialize segment markers
6. Update `hermes--stream-commit` to drop segment markers
7. Write renderer tests

### Phase 4: Integration & cleanup (1 hour)
1. Remove old markers (`stream-content-start`, `stream-stable-end`, `stream-end`, `stream-thinking-marker`, `stream-tools-marker`)
2. Remove old render functions (`hermes--rewrite-stream`, `hermes--update-thinking-block`, `hermes--update-tool-views`, `hermes--insert-before-text`, `hermes--insert-after-text`)
3. Update any remaining code that reads `stream.text`
4. Full test run

### Phase 5: Documentation (30 min)
1. Update `HERMES-TUI-REFERENCE.md` with new architecture
2. Document segment types and ordering
3. Mark old flat architecture as deprecated

**Total estimated time:** 6-7 hours

---

## 9. Open Questions

### Q1: Do we need segment IDs?
**A:** Yes, but simple. Use a monotonic counter or `(format "%s-%d" session-id segment-idx)`. IDs let the renderer match old→new segments for efficient updates (Phase 4 optimization).

### Q2: What about `stream.tools`?
**A:** Deprecate it. Tool state lives in tool segments now. Keep the slot temporarily populated from segments for backward compatibility, remove later.

### Q3: How do we handle empty segments?
**A:** Empty segments (zero-length content) are simply not rendered. They stay in the vector for state tracking but produce no output.

### Q4: What if the gateway sends text after `message.complete`?
**A:** The reducer ignores it (same as current behavior). `message.complete` clears the stream. Any late deltas arrive with no stream and are dropped.

### Q5: Do segments need timestamps?
**A:** Nice to have for debugging and future features (e.g., "show me what happened in the last 30 seconds"), but not required for rendering. Start without, add later.

### Q6: How does this affect subagent support?
**A:** Positively. Subagents can be rendered as segments too — either a new `subagent` segment type or nested segments. The segmented architecture is the right foundation.

---

## 10. Acceptance Criteria

- [ ] `hermes-stream` uses `segments` vector instead of flat `text`/`thinking`/`reasoning`
- [ ] All reducer events produce correct segments in arrival order
- [ ] Renderer displays segments in correct order with proper spacing
- [ ] Tool segments appear interleaved with text (not all at end)
- [ ] Committed messages preserve segment ordering
- [ ] Deprecated `text`/`thinking`/`reasoning`/`tools` slots still populated for backward compatibility
- [ ] 15+ new ERT tests pass
- [ ] `eldev test` reports 0 unexpected failures
- [ ] `HERMES-TUI-REFERENCE.md` updated with segmented architecture

---

*End of plan. Ready for implementation when you are.*
