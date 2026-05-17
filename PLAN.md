# PLAN.md — Persistent Bottom Bench for hermes-mode (Revised v3)

## 1. Vision

A single bottom bench buffer (`*hermes-bench:<sid>*`) for `hermes-mode` major-mode buffers. The bench is the user's interactive surface: ephemeral assistant content rendered above, editable input area below. The org buffer remains the canonical history and state source.

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
|  ** hello there                           |  <- user prompt
|                                           |
|  *** Reasoning                            |  <- reasoning zone (always visible)
|  The user sent a greeting...              |
|  ...                                      |
|                                           |
|  Hello! How can I help you today?         |  <- answer zone
|  ...                                      |
|                                           |
|  ------                                   |  <- separator
|  >                                        |  <- input area (cursor)
+------------------------------------------+
```

---

## 2. Key Behaviors

| Behavior | Spec |
|----------|------|
| **Bench size** | 20 lines minimum (`window-height . 20`) |
| **Bench zones** | Ephemeral area (user prompt, reasoning, answer), separator, input area |
| **User prompt** | Echoed in bench as `** <text>` |
| **Reasoning zone** | Always shows `*** Reasoning` header. Empty body when no reasoning segments. No `thinking`. |
| **Answer zone** | Assistant `text`, `tool`, `system` segments. Plain text, `visual-line-mode` wrapping. |
| **ASCII-only** | No emojis: `[tool: <name>] <status>`, `[system] <text>` |
| **User commit** | Inserted into org buffer immediately on send (same as now) |
| **Assistant commit** | On `message.complete`, full turn appended to org buffer |
| **Bench clear** | **Immediately** on RET. Old answer wiped, fresh turn starts. |
| **Last turn persistence** | Assistant answer stays visible after commit until next user prompt. |
| **Separate renderer** | Bench rendering is **completely independent** from org renderer. |
| **Focus** | Stays in bench input area after send. |
| **`C-c C-i` from org** | Jumps focus to bench input area. |
| **Two org buffers** | One bench per frame; switching org buffers swaps via `window-selection-change-functions`. |

---

## 3. Architecture Principles

1. **One boundary marker only.** The only persistent marker is `hermes-bench--input-boundary`. Everything above it is ephemeral and rebuilt from scratch on every paint. Everything below is editable input.
2. **Full ephemeral rebuild on every delta.** Erase everything above the separator, rebuild from current segments, restore input text. No incremental diff, no zone markers, no `replace-zone`. The bench is a small plain-text buffer — full rebuild is fast and eliminates marker drift entirely.
3. **Zero renderer coupling.** `hermes-bench.el` does not import or call any org renderer internals.
4. **Commit-early user, commit-late assistant.** User turn goes to org immediately; assistant streams in bench, commits to org at end.
5. **Clear-on-send.** Bench ephemeral area is wiped on `hermes-bench-send`.

---

## 4. Files

### 4.1 New file: `hermes-bench.el`

~350 lines. Self-contained.

#### Buffer-local variables (in bench buffer)

```elisp
(defvar-local hermes-bench--parent-buffer nil
  "The org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker at the start of the separator line.")

(defvar-local hermes-bench--input-text-snapshot nil
  "Snapshot of input text used during ephemeral rebuilds.")
```

**No zone markers.** No `user-prompt-start/end`, `reasoning-start/end`, `answer-start/end`.

#### Major mode

```elisp
(define-derived-mode hermes-bench-mode text-mode "Hermes-Bench"
  "Major mode for the Hermes bottom bench panel."
  (setq truncate-lines nil)
  (visual-line-mode 1)
  (setq-local cursor-type 'bar))

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
| `hermes-bench-ensure (parent)` | Create or display bench for PARENT. Side-window `(side . bottom) (slot . 0) (window-height . 20) (dedicated . t) (preserve-size . (nil . t))`. |
| `hermes-bench-hide (parent)` | Delete bench window, kill bench buffer. |
| `hermes-bench-active-p (&optional parent)` | Return live bench buffer for PARENT, or nil. |
| `hermes-bench--setup (parent)` | Initialize: erase, set `input-boundary` to `point-min`, insert separator + prompt, set header. |
| `hermes-bench--input-text ()` | Return trimmed text after `input-boundary`. |
| `hermes-bench--clear-input ()` | Erase text after `input-boundary`. |
| `hermes-bench-send ()` | Save input text, call `hermes-bench--paint-ephemeral` with user prompt, call `hermes-input-send` in parent, clear input. |
| `hermes-bench-interrupt-parent ()` | Call `hermes-interrupt` in parent. |
| `hermes-bench-compose ()` | Open `*hermes-compose*` targeting parent. |
| `hermes-bench--paint-ephemeral (&optional user-text reasoning answer)` | **The single renderer.** Wipes everything above separator, inserts user prompt + reasoning header + answer, reinserts separator + preserved input text. |
| `hermes-bench--segments-by-zone (segments)` | Return `(REASONING-TEXT . ANSWER-TEXT)` from segment vector. |
| `hermes-bench-set-header ()` | Mirror parent status into bench `header-line-format`. |

#### Stream lifecycle hooks

```elisp
(defun hermes-bench--stream-begin (bench)
  "Called when stream starts."
  (with-current-buffer bench
    (hermes-bench--paint-ephemeral
     (or (hermes-bench--latest-user-text hermes-bench--parent-buffer)
         ""))
    (hermes-bench-set-header)))

(defun hermes-bench--stream-update (bench _old new)
  "Called on every throttled delta."
  (with-current-buffer bench
    (pcase-let ((`(,reasoning . ,answer)
                 (hermes-bench--segments-by-zone
                  (hermes-stream-segments new))))
      (hermes-bench--paint-ephemeral nil reasoning answer))))

(defun hermes-bench--stream-commit (bench old-stream)
  "Called when stream ends. Commit to org, bench stays visible."
  (with-current-buffer bench
    (let ((parent hermes-bench--parent-buffer))
      (when (buffer-live-p parent)
        (with-current-buffer parent
          (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                 (msg (hermes--message-from-stream old-stream usage)))
            (with-silent-modifications
              (save-excursion
                (hermes--insert-committed-turn msg)))))))
    (hermes-bench-set-header)))
```

### 4.2 Modify: `hermes-mode.el`

- After `(hermes-minor-mode 1)` in `hermes-mode`: `(hermes-bench-ensure (current-buffer))`
- In `hermes--do-session-create` callback: `(hermes-bench-ensure buf)`
- `hermes-minor-mode--off`: `(hermes-bench-hide (current-buffer))` when major mode
- `kill-buffer-hook`: `(hermes-bench-hide (current-buffer))`
- `C-c C-i` binding: `hermes-send-or-focus-bench` — jump to bench if active, else minibuffer

### 4.3 Modify: `hermes-render.el`

Branch stream lifecycle on `hermes-bench-active-p`:
- `stream-begin` → `hermes-bench--stream-begin` or `hermes--stream-begin`
- `stream-update` → `hermes-bench--stream-update` or `hermes--stream-update`
- `stream-commit` → `hermes-bench--stream-commit` or `hermes--stream-commit`

Also sync bench header-line when parent header-line updates.

### 4.4 Modify: `hermes-input.el`

No changes. Bench calls `hermes-input-send` programmatically.

---

## 5. The Single Renderer Algorithm

### 5.1 `hermes-bench--paint-ephemeral`

```elisp
(defun hermes-bench--paint-ephemeral (&optional user-text reasoning answer)
  "Wipe ephemeral area, rebuild it, preserve input text below separator."
  (let ((inhibit-read-only t)
        (saved-input (hermes-bench--input-text))
        (saved-point-offset (- (point) (marker-position hermes-bench--input-boundary))))
    ;; 1. Delete everything from point-min up to (and including) the old separator.
    (delete-region (point-min) (marker-position hermes-bench--input-boundary))
    ;; 2. Insert ephemeral content.
    (goto-char (point-min))
    ;; User prompt
    (when (and user-text (not (string-empty-p user-text)))
      (insert (propertize (concat "** " user-text "\n\n")
                          'face 'hermes-bench-user-face)))
    ;; Reasoning zone
    (insert (propertize "*** Reasoning\n"
                        'face 'hermes-bench-reasoning-heading-face))
    (when (and reasoning (not (string-empty-p reasoning)))
      (insert (propertize reasoning 'face 'hermes-bench-reasoning-face))
      (unless (string-suffix-p "\n" reasoning) (insert "\n")))
    (insert "\n")
    ;; Answer zone
    (when (and answer (not (string-empty-p answer)))
      (insert answer)
      (unless (string-suffix-p "\n" answer) (insert "\n")))
    ;; 3. Insert separator + input.
    (insert (propertize (concat hermes-bench-separator "\n")
                        'face 'hermes-bench-separator-face
                        'read-only t 'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (setq hermes-bench--input-boundary (copy-marker (point) nil))
    (insert (propertize hermes-bench-prompt
                        'face 'hermes-bench-prompt-face
                        'read-only t 'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    ;; 4. Restore input text and point.
    (unless (string-empty-p saved-input)
      (insert saved-input))
    (goto-char (max (marker-position hermes-bench--input-boundary)
                    (+ (marker-position hermes-bench--input-boundary)
                       saved-point-offset)))))
```

**Why this works:**
- The separator line itself has `rear-nonsticky (read-only)` — the `read-only` property does not extend to text inserted after it.
- The prompt `> ` has `front-sticky (read-only)` — the `read-only` property does not extend backward into the input area.
- The user can freely type after `> `. They cannot edit above the separator because that entire region has `read-only`.
- No zone markers to maintain. The only marker is `input-boundary`, which is recreated from scratch on every paint.

### 5.2 On `hermes-bench-send`

```
1. Grab input text as the new user prompt
2. Call hermes-bench--paint-ephemeral with:
     user-text = <input text>
     reasoning = ""
     answer = ""
   This wipes the old turn and shows the new user prompt.
3. Call hermes-input-send in parent org buffer
4. Input area is already empty (paint-ephemeral preserved nothing)
```

### 5.3 On `hermes-bench--stream-update`

```
1. Read segments vector from new-stream
2. Separate into reasoning-text and answer-text
3. Call hermes-bench--paint-ephemeral with:
     user-text = nil  (keep existing)
     reasoning = <reasoning text>
     answer = <answer text>
   This preserves whatever user prompt is already there, rebuilds reasoning + answer.
```

**Implementation detail**: `paint-ephemeral` preserves the current input text across rebuilds. During streaming, the input area is empty, so this is a no-op. If the user starts typing while a stream is in flight, their draft is preserved.

### 5.4 Segment → bench text mapping

| Segment type | Bench rendering |
|--------------|-----------------|
| `text` | Plain text, no prefix |
| `reasoning` | Plain text in reasoning zone, `hermes-bench-reasoning-face` |
| `thinking` | **Ignored** |
| `tool` | `[tool: <name>] <status> <summary>` |
| `system` | `[system] <text>` |

---

## 6. Data Flow

### 6.1 User sends a message (bench active)

```
User types in bench input area -> RET
  -> hermes-bench-send
    1. Grab input text
    2. hermes-bench--paint-ephemeral(user-text, "", "")
       -> wipes old turn, shows "** hello there"
    3. hermes-input-send (in parent org buffer)
       -> :user-submit dispatched
       -> "** user: hello there" inserted into org buffer
       -> prompt.submit RPC sent
    4. Input area cleared (paint-ephemeral did this)
```

### 6.2 Assistant streams response (bench active)

```
message.delta arrives
  -> reducer updates hermes--state stream segments
  -> hermes-state-change-hook fires
  -> hermes--render
     -> branch: bench active
     -> hermes-bench--stream-update
        -> segments-by-zone separates reasoning vs answer
        -> hermes-bench--paint-ephemeral(nil, reasoning, answer)
           -> preserves user prompt, rebuilds reasoning + answer
```

### 6.3 Stream commits (bench active)

```
message.complete arrives
  -> reducer clears stream, pushes assistant msg to pending-turns
  -> hermes--render
     -> branch: bench active
     -> hermes-bench--stream-commit
        -> builds hermes-message from final stream
        -> hermes--insert-committed-turn (in org buffer)
        -> bench NOT cleared (answer still visible)
```

### 6.4 Next user prompt (bench active, previous answer still visible)

```
User hits RET with new prompt
  -> hermes-bench-send
    1. Grab text
    2. hermes-bench--paint-ephemeral(new-prompt, "", "")
       -> old answer wiped, new prompt shown
    3. hermes-input-send
```

---

## 7. Edge Cases

| Case | Handling |
|------|----------|
| **Bench window deleted manually** | `hermes-bench-active-p` returns nil; `C-c C-i` recreates it. |
| **Org buffer killed** | `kill-buffer-hook` hides bench + kills bench buffer. |
| **Gateway disconnect mid-stream** | `error` path clears stream; `stream-commit` inserts partial message into org, bench keeps last rendered state. |
| **User queues while streaming** | `hermes-bench-send` clears bench anyway, shows new prompt, enqueues. User sees prompt + empty reasoning/answer while waiting. |
| **No reasoning segments** | Reasoning zone shows `*** Reasoning` header with empty body. |
| **Only reasoning, no text** | Answer zone empty, reasoning zone populated. |
| **User types during stream** | `paint-ephemeral` preserves their draft input text across rebuilds. |
| **Multi-byte / emoji in stream** | Plain text insert handles naturally. No emoji policy enforced by bench. |

---

## 8. Testing Strategy

### Unit tests (`test/hermes-bench-test.el`)

1. `hermes-bench-ensure`: creates buffer, correct mode, 20-line window
2. `hermes-bench--paint-ephemeral`: correct structure, input preserved, separator present
3. `hermes-bench-send`: clears old content, shows user prompt, calls mock
4. `hermes-bench--stream-update`: reasoning segments go to reasoning zone, text to answer zone, thinking ignored
5. `hermes-bench--stream-commit`: calls `hermes--insert-committed-turn` mock, bench not cleared
6. `hermes-bench-hide`: window gone, buffer killed

### Integration tests

1. Open `hermes-mode` → bench appears at bottom, 20 lines
2. Send message from bench → user prompt visible in bench, heading in org
3. Stream deltas → reasoning and text appear in correct zones
4. `message.complete` → assistant heading + raw drawer in org, bench still shows answer
5. Send second message → bench clears old answer, shows new user prompt
6. Type during stream → input text preserved across delta paints

---

## 9. Implementation Order

1. Create `hermes-bench.el` skeleton (mode, ensure/hide, setup)
2. Implement `hermes-bench--paint-ephemeral` (the core renderer)
3. Implement `hermes-bench-send`
4. Implement `hermes-bench--segments-by-zone`
5. Implement stream lifecycle hooks (`stream-begin/update/commit`)
6. Wire `hermes-mode.el` to create bench on startup
7. Wire `hermes-render.el` stream lifecycle branching
8. Add header-line sync
9. Add window-selection-change handling
10. Write tests

---

## 10. What changed from v2

| Aspect | v2 | v3 |
|--------|-----|-----|
| Zone markers | 6 markers (`user-prompt-start/end`, `reasoning-start/end`, `answer-start/end`) | 1 marker (`input-boundary`) |
| Render strategy | `replace-zone` per zone (markers drift) | Full ephemeral rebuild in one function |
| Read-only handling | Sticky properties on zone boundaries | Single separator line with rear-nonsticky |
| Lines of code | ~400 | ~350 |
| Failure mode after N turns | Marker drift, buffer corruption | None — stateless rebuild |

---

*Plan version: 3.0*
*Target branch: feature/bench*
*Estimated lines: ~350 new, ~100 modified*
