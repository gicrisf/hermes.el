# PLAN.md — Persistent Bottom Bench for hermes-mode (Revised)

## 1. Vision

A dedicated bottom panel (`*hermes-bench:<sid>*`) for `hermes-mode` major-mode buffers. The bench displays the **last turn** in a structured, multi-zone layout. The org buffer remains the canonical history and state source.

- **Minor mode** (`hermes-minor-mode` in arbitrary org files): **unchanged**. No bench.
- **Major mode** (`hermes-mode`): bench visible at bottom, 20 lines minimum.

### Visual layout (major mode)

```
+------------------------------------------+
|  * Hermes session :hermes:               |  <- org buffer (history)
|  ** user: hello                           |
|  ** Hello! How can I help? :hermes:       |
|  :HERMES_RAW:                             |
|  ...                                      |
|  :END:                                    |
+------------------------------------------+
|  Hermes · ● · claude-sonnet · 12->34     |  <- bench header-line
|                                           |
|  ** hello there                           |  <- user prompt zone
|                                           |
|  *** Reasoning                            |  <- reasoning zone header
|  The user sent a greeting.                |
|  I'll respond warmly and concisely.       |
|  ...                                      |
|                                           |
|  Hello! How can I help you today?         |  <- answer zone
|  ...                                      |
|                                           |
|  ------                                   |  <- separator
|  >                                        |  <- input area
+------------------------------------------+
```

---

## 2. Key Behaviors

| Behavior | Spec |
|----------|------|
| **Bench size** | 20 lines minimum (`window-height . 20`) |
| **Bench zones** | Header-line, User prompt, Reasoning (min 6 lines), Answer (min 10 lines), Separator, Input area |
| **User prompt** | Echoed in bench as `** <text>` mimicking org headline |
| **Reasoning zone** | Always shows `*** Reasoning` header. Fixed visual space. Only `reasoning` segments populate it. No `thinking`. |
| **Answer zone** | Assistant `text` segments. Remaining space after reasoning. |
| **Tool calls** | Rendered as plain text lines in answer zone: `[tool: <name>] <status>` |
| **System messages** | Rendered in answer zone: `[system] <text>` |
| **User message commit** | Inserted into org buffer immediately on send (same as now) |
| **Assistant commit** | On `message.complete` / error / interrupt, full assistant turn appended to org buffer |
| **Bench clear timing** | **Immediately** when user hits RET for a new prompt. Old answer wiped, fresh turn starts. |
| **Last turn persistence** | After commit, the assistant answer stays visible in bench until the **next** user prompt clears it. |
| **No emojis** | ASCII-only indicators (`[tool:]`, `[system]`, `[reasoning]`). |
| **Separate renderer** | Bench rendering is **completely independent** from `hermes--render-stream-segments`. Zero shared code. |
| **Focus after send** | Stays in bench input area |
| **`C-c C-i` from org buffer** | Jumps focus to bench input area |
| **Two org buffers** | One bench per frame; `window-selection-change-functions` swaps |

---

## 3. Architecture Principles

1. **Bench is pure display**: No state atom. Reads `hermes--state` from parent org buffer.
2. **Zero renderer coupling**: `hermes-bench.el` does not call, reference, or import any org-renderer internals (`hermes--render-stream-segments`, `hermes--segment-block`, bench markers, etc.).
3. **Copy-on-read segments**: The bench receives the same `hermes-stream` struct but builds its own plain-text representation. It can snapshot segment state locally.
4. **Commit-early user, commit-late assistant**: User turn goes to org immediately; assistant turn streams in bench, commits to org at end.
5. **Clear-on-send**: Bench ephemeral area is wiped on `hermes-bench-send` before `hermes-input-send` is called.

---

## 4. Files

### 4.1 New file: `hermes-bench.el`

~400 lines. Self-contained.

#### Variables (buffer-local in bench buffer)

```elisp
(defvar-local hermes-bench--parent-buffer nil
  "The org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker at the start of the input prompt line.")

;; Zone markers — these delimit the rigid-ish regions
(defvar-local hermes-bench--user-prompt-start nil)
(defvar-local hermes-bench--user-prompt-end nil)
(defvar-local hermes-bench--reasoning-start nil)
(defvar-local hermes-bench--reasoning-end nil)
(defvar-local hermes-bench--answer-start nil)
(defvar-local hermes-bench--answer-end nil)
```

#### Major mode

```elisp
(define-derived-mode hermes-bench-mode text-mode "Hermes-Bench"
  "Major mode for the Hermes bottom bench panel."
  (setq truncate-lines nil)
  (visual-line-mode 1)
  (setq header-line-format nil))

(defvar hermes-bench-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")     #'hermes-bench-send)
    (define-key m (kbd "C-c C-c") #'hermes-bench-send)
    (define-key m (kbd "C-c C-k") #'hermes-bench-interrupt-parent)
    (define-key m (kbd "C-c C-l") #'hermes-bench-compose)
    m))
```

#### Core functions

| Function | Purpose |
|----------|---------|
| `hermes-bench-ensure (parent)` | Create or display bench for PARENT. `display-buffer-in-side-window` with `(side . bottom) (slot . 0) (window-height . 20) (dedicated . t) (preserve-size . (nil . t))`. Returns bench buffer. |
| `hermes-bench-hide (parent)` | Delete bench window, kill bench buffer. |
| `hermes-bench-active-p (&optional parent)` | Return live bench buffer for PARENT, or nil. |
| `hermes-bench--setup (parent)` | Initialize bench buffer: erase, insert zone structure, set markers, insert prompt. |
| `hermes-bench--rebuild-zones ()` | Erase ephemeral content and rebuild the zone structure (user-prompt, reasoning header, answer space, separator). Called on clear. |
| `hermes-bench--clear-ephemeral ()` | Delete content between zone start and separator. Resets zone markers. |
| `hermes-bench--input-text ()` | Return trimmed text after input-boundary. |
| `hermes-bench--clear-input ()` | Erase text after input-boundary. |
| `hermes-bench-send ()` | **Clear ephemeral, then send.** Grab input, call `hermes-input-send` in parent, clear input. |
| `hermes-bench-interrupt-parent ()` | Call `hermes-interrupt` in parent. |
| `hermes-bench-compose ()` | Open `*hermes-compose*` targeting parent. |
| `hermes-bench--render-stream (bench old-stream new-stream)` | **The bench renderer.** Reads segments from NEW-STREAM, maps to plain text, inserts into correct zone. See section 5 for algorithm. |
| `hermes-bench-set-header ()` | Mirror parent status into bench `header-line-format`. |

#### Stream lifecycle hooks (called from `hermes--render`)

```elisp
(defun hermes-bench--stream-begin (bench)
  "Called when stream starts. Ensures zones are ready."
  (with-current-buffer bench
    (hermes-bench--rebuild-zones)
    (hermes-bench-set-header)))

(defun hermes-bench--stream-update (bench _old-stream new-stream)
  "Called on every stream delta (throttled)."
  (with-current-buffer bench
    (hermes-bench--render-stream bench _old-stream new-stream)))

(defun hermes-bench--stream-commit (bench old-stream)
  "Called when stream ends. Build message, insert into parent org buffer."
  (with-current-buffer bench
    (let ((parent hermes-bench--parent-buffer))
      (when (buffer-live-p parent)
        (with-current-buffer parent
          (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                 (msg (hermes--message-from-stream old-stream usage)))
            (with-silent-modifications
              (save-excursion
                (hermes--insert-committed-turn msg)))))))))
```

**Important**: `stream-commit` does **NOT** clear the bench. The answer stays visible.

---

## 5. Bench Renderer Algorithm

### 5.1 Zone structure after `hermes-bench--rebuild-zones`

```
[point-min]

** <user prompt text, or empty>

*** Reasoning
<reasoning text, or empty>

<answer text, or empty>

------
> <cursor>
[point-max]
```

Markers:
- `hermes-bench--user-prompt-start` → start of `** ` line
- `hermes-bench--user-prompt-end` → end of user prompt text
- `hermes-bench--reasoning-start` → start of `*** Reasoning` line
- `hermes-bench--reasoning-end` → end of reasoning text
- `hermes-bench--answer-start` → start of first answer text line
- `hermes-bench--answer-end` → end of answer text
- `hermes-bench--input-boundary` → start of `------` line

### 5.2 On `hermes-bench-send`

```
1. Grab input text
2. hermes-bench--clear-ephemeral
3. hermes-bench--rebuild-zones
4. Insert user prompt: "** " + text  (into user-prompt zone)
5. Call hermes-input-send in parent
6. Clear input area
```

This ensures the old answer is gone before the new RPC starts.

### 5.3 On `hermes-bench--stream-update`

```
1. Read segments vector from new-stream
2. Separate into buckets: text, reasoning, tool, system
3. For reasoning bucket:
   a. Delete region between reasoning-start and reasoning-end
   b. Insert concatenated reasoning text
   c. Set reasoning-end marker
4. For answer bucket (text + tool + system):
   a. Delete region between answer-start and answer-end
   b. Insert concatenated text
   c. Insert tool lines
   d. Insert system lines
   e. Set answer-end marker
5. Do NOT touch user-prompt zone
```

**Why full delete+insert per zone is fine here**: The bench is plain text. There are no org headlines, property drawers, ID creation, or fold overlays to preserve. The cost of deleting and reinserting a few KB of text in a 20-line text buffer is negligible even at 25 Hz. The org renderer uses incremental diff because it manipulates complex org structure and must preserve markers/IDs/folds. The bench has no such constraint.

### 5.4 Segment → bench text mapping

| Segment type | Bench rendering |
|--------------|-----------------|
| `text` | Plain text, no prefix |
| `reasoning` | Plain text inserted into reasoning zone |
| `thinking` | **Ignored** — not committed-visible |
| `tool` | `[tool: <name>] <status> <preview-one-line>` |
| `system` | `[system] <text>` |

All text uses `visual-line-mode` soft wrapping. No manual line breaking.

---

## 6. Data Flow

### 6.1 User sends a message (bench active)

```
User types in bench input area -> RET
  -> hermes-bench-send
    1. Grab text after input-boundary
    2. hermes-bench--clear-ephemeral
    3. hermes-bench--rebuild-zones
    4. Insert "** " + text into user-prompt zone
    5. hermes-input-send (in parent org buffer)
         -> :user-submit dispatched
         -> "** user: hello" inserted into org buffer
         -> prompt.submit RPC sent
    6. Clear bench input area
```

### 6.2 Assistant streams response (bench active)

```
message.delta arrives
  -> hermes--route-event -> hermes-dispatch
    -> reducer updates hermes--state stream segments
    -> hermes-state-change-hook fires
      -> hermes--render
        -> branch: bench active
          -> hermes-bench--stream-update
            -> read segments vector
            -> rebuild reasoning zone from reasoning segments
            -> rebuild answer zone from text/tool/system segments
```

### 6.3 Stream commits (bench active)

```
message.complete arrives
  -> reducer clears stream, pushes assistant msg to pending-turns
  -> hermes-state-change-hook fires
    -> hermes--render
      -> branch: bench active
        -> hermes-bench--stream-commit
          -> build hermes-message from final stream
          -> with-current-buffer parent
             -> hermes--insert-committed-turn (existing function)
          -> bench stays as-is (answer still visible)
```

### 6.4 Next user prompt (bench active, previous answer still visible)

```
User hits RET with new prompt
  -> hermes-bench-send
    1. Grab text
    2. hermes-bench--clear-ephemeral  <-- old answer wiped
    3. hermes-bench--rebuild-zones
    4. Insert new user prompt
    5. Send RPC
```

---

## 7. Files to Modify

### 7.1 `hermes-mode.el` (unchanged from first plan)

- After `(hermes-minor-mode 1)` in `hermes-mode`: `(hermes-bench-ensure (current-buffer))`
- In `hermes--do-session-create` callback: `(hermes-bench-ensure buf)`
- `hermes-minor-mode--off`: `(hermes-bench-hide (current-buffer))` when major mode
- `kill-buffer-hook`: `(hermes-bench-hide (current-buffer))`
- `C-c C-i` binding: jump to bench if active

### 7.2 `hermes-render.el` (unchanged from first plan)

Branch stream lifecycle on `hermes-bench-active-p`:
- `stream-begin` → `hermes-bench--stream-begin` or `hermes--stream-begin`
- `stream-update` → `hermes-bench--stream-update` or `hermes--stream-update`
- `stream-commit` → `hermes-bench--stream-commit` or `hermes--stream-commit`

Also: sync bench header-line when parent header-line updates.

### 7.3 `hermes-input.el`

No changes. Bench calls `hermes-input-send` programmatically.

---

## 8. Edge Cases

| Case | Handling |
|------|----------|
| **Bench window deleted manually** | `hermes-bench-active-p` returns nil; `C-c C-i` recreates it. |
| **Org buffer killed** | `kill-buffer-hook` hides bench + kills bench buffer. |
| **Gateway disconnects mid-stream** | `error` path clears stream; `stream-commit` inserts partial message into org, bench keeps last rendered state. |
| **User queues while streaming** | `hermes-bench-send` sees stream is active, clears bench anyway, inserts user prompt, enqueues. User sees their prompt + empty reasoning/answer zones while waiting. |
| **No reasoning segments** | Reasoning zone shows `*** Reasoning` header with empty body. |
| **Only reasoning, no text** | Answer zone empty, reasoning zone populated. |
| **Multi-byte / emoji in stream** | Plain text insert handles naturally. No emoji policy enforced by bench — it just doesn't add its own. |

---

## 9. Testing Strategy

### Unit tests (`test/hermes-bench-test.el`)

1. `hermes-bench-ensure`: creates buffer, correct mode, 20-line window
2. `hermes-bench--rebuild-zones`: correct marker positions, zones in order
3. `hermes-bench-send`: clears old content, inserts user prompt, calls mock
4. `hermes-bench--render-stream`: reasoning segments go to reasoning zone, text to answer zone, thinking ignored
5. `hermes-bench--stream-commit`: calls `hermes--insert-committed-turn` mock, bench not cleared
6. `hermes-bench-hide`: window gone, buffer killed

### Integration tests

1. Open `hermes-mode` → bench appears at bottom, 20 lines
2. Send message from bench → user prompt visible in bench, heading in org
3. Stream deltas → reasoning and text appear in correct zones
4. `message.complete` → assistant heading + raw drawer in org, bench still shows answer
5. Send second message → bench clears old answer, shows new user prompt

---

## 10. Implementation Order

1. Create `hermes-bench.el` skeleton (mode, ensure/hide, setup)
2. Implement zone structure (`hermes-bench--rebuild-zones`, markers)
3. Implement `hermes-bench-send` with clear-on-send behavior
4. Implement bench renderer (`hermes-bench--render-stream`)
5. Implement stream lifecycle hooks (`stream-begin/update/commit`)
6. Wire `hermes-mode.el` to create bench on startup
7. Wire `hermes-render.el` stream lifecycle branching
8. Add header-line sync
9. Add window-selection-change handling
10. Write tests

---

*Plan version: 2.0*
*Target branch: feature/bench*
*Estimated lines: ~500 new, ~100 modified*
