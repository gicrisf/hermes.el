# PLAN.md — Persistent Bottom Bench for hermes-mode

## 1. Vision

Provide a persistent bottom panel (the **bench**) for `hermes-mode` major-mode buffers. The bench acts as the interactive control surface — input + ephemeral stream display — while the org buffer remains the canonical committed history.

- **Minor mode** (`hermes-minor-mode` in arbitrary org files): **unchanged**. Header-line at top, no bench.
- **Major mode** (`hermes-mode` dedicated buffers): bench visible at bottom, status bar at bottom of bench (moved header-line), org buffer header-line stays as-is.

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
|  Hermes · ● · claude-sonnet · 12→34     |  <- bench header-line (status)
|  That's an interesting question. Let     |  <- bench ephemeral area
|  me think about it...                    |     (assistant response stream)
|                                          |
|  > hello, what do you think?            |  <- bench input area (cursor)
+------------------------------------------+
```

---

## 2. Key Behaviors

| Behavior | Spec |
|----------|------|
| **Bench size** | Fixed 6 lines (`window-height . 6`), bottom side-window |
| **User message** | Inserted into org buffer **immediately** on send (same as now) |
| **Assistant stream** | Rendered **only in bench ephemeral area**; org buffer untouched during streaming |
| **Commit** | On `message.complete` / error / interrupt, full assistant turn appended to org buffer, bench ephemeral area cleared |
| **Input area** | Single-line feel, but text wraps within window; `C-c C-l` opens full compose buffer for heavy multi-line editing |
| **Focus after send** | Stays in bench input area |
| **Auto-scroll** | Bench ephemeral area auto-scrolls like a terminal (keep latest visible) |
| **`C-c C-i` from org buffer** | Jumps focus to bench input area (when bench is active) |
| **Two org buffers** | Only one bench visible per frame; switching org buffers hides old bench, shows new one via `window-selection-change-functions` |
| **Header-line** | Org buffer keeps its header-line; bench gets its own `header-line-format` mirroring current status |

---

## 3. Architecture Principles

1. **Single source of truth**: `hermes--state` stays buffer-local to the org buffer. The bench is a **pure display surface** with no state atom.
2. **Commit-early for user, commit-late for assistant**: User turn goes to org immediately; assistant turn is held in bench until stream ends, then committed atomically to org.
3. **Minimal intrusion**: Existing `hermes-minor-mode`, `hermes--render`, `hermes-input-send`, and `hermes--stream-*` functions stay untouched for the minor-mode path. Major mode branches only when `hermes-bench-active-p` is non-nil.
4. **Plain-text bench, rich org commit**: The bench shows a lightweight text rendering of segments. The org buffer gets the full org-formatted turn (headlines, drawers, faces) on commit via existing `hermes--insert-committed-turn`.

---

## 4. Files

### 4.1 New file: `hermes-bench.el`

~350 lines. Core bench lifecycle, display, and input handling.

#### Variables (buffer-local in bench buffer)

```elisp
(defvar-local hermes-bench--parent-buffer nil
  "The org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker separating ephemeral area (above) from input area (below).")

(defvar-local hermes-bench--ephemeral-start nil
  "Marker at start of current assistant turn ephemeral content.")

(defvar-local hermes-bench--session-id nil
  "Cached session-id for routing checks.")
```

#### Major mode

```elisp
(define-derived-mode hermes-bench-mode text-mode "Hermes-Bench"
  "Major mode for the Hermes bottom bench panel."
  (setq truncate-lines nil)
  (visual-line-mode 1)
  (setq header-line-format nil)
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
| `hermes-bench-ensure (parent)` | Create or display bench for PARENT buffer. Uses `display-buffer-in-side-window` with `(side . bottom)` `(window-height . 6)` `(slot . 0)` `(dedicated . t)` `(preserve-size . t)`. Returns bench buffer. |
| `hermes-bench-hide (parent)` | Delete bench window (not buffer) for PARENT. Called on parent kill-buffer-hook. |
| `hermes-bench-active-p (&optional parent)` | Return live bench buffer for PARENT (defaults to `current-buffer`), or nil. |
| `hermes-bench--setup (parent)` | Initialize bench buffer: set parent link, create input boundary marker at `(point-min)`, insert prompt `"> "`, set ephemeral-start marker. |
| `hermes-bench-send` | Grab text after `hermes-bench--input-boundary`, trim, call `hermes-input-send` in parent buffer non-interactively, clear input area. |
| `hermes-bench-interrupt-parent` | Call `hermes-interrupt` (or equivalent) in parent buffer. |
| `hermes-bench-compose` | Open `*hermes-compose*` targeting parent buffer (reuse existing `hermes-compose--target` mechanism). |
| `hermes-bench-clear-ephemeral` | Delete region between ephemeral-start and input-boundary. |
| `hermes-bench-append-ephemeral (text)` | Insert TEXT before input-boundary, move ephemeral-start if needed, ensure window point shows end (auto-scroll). |
| `hermes-bench-set-header` | Mirror `hermes--render-header` logic into bench `header-line-format`. Reads `hermes--state` from parent buffer. |
| `hermes-bench--render-stream (bench old-stream new-stream)` | Lightweight segment renderer. Clears ephemeral area, rebuilds plain-text representation of segments (text + reasoning annotations + tool previews), appends to ephemeral area. |
| `hermes-bench--stream-begin (bench)` | Initialize ephemeral area for new assistant turn. |
| `hermes-bench--stream-update (bench old-stream new-stream)` | Diff segments, append deltas to ephemeral area. |
| `hermes-bench--stream-commit (bench old-stream)` | Build `hermes-message` from stream, call `hermes--insert-committed-turn` in parent buffer, clear ephemeral area. |

#### Window lifecycle hooks

- `window-selection-change-functions`: when selected window changes to a different `hermes-mode` buffer, hide old bench and show new one.
- `kill-buffer-hook` on parent: `hermes-bench-hide` + kill bench buffer.

### 4.2 Modify: `hermes-mode.el`

**Line ~214** (after `hermes-minor-mode 1` in `hermes-mode`):
```elisp
(hermes-bench-ensure (current-buffer))
```

**Line ~236-239** (in `hermes--do-session-create` callback, after buffer setup):
```elisp
(with-current-buffer buf
  ...
  (hermes-bench-ensure buf))
```

**Add to `hermes-minor-mode--off`** (line ~182-192):
```elisp
;; When major mode tears down, hide its bench
(when (derived-mode-p 'hermes-mode)
  (hermes-bench-hide (current-buffer)))
```

**Add kill-buffer hook in `hermes-minor-mode--on`**:
```elisp
(add-hook 'kill-buffer-hook
          (lambda () (hermes-bench-hide (current-buffer)))
          nil t)
```

**Update `hermes-send` alias / `C-c C-i` binding**:
In `hermes-mode-map` (line ~140), change `C-c C-i` to a new function:
```elisp
(defun hermes-send-or-focus-bench ()
  "If bench is active, focus it; otherwise fall back to minibuffer prompt."
  (interactive)
  (let ((bench (hermes-bench-active-p)))
    (if bench
        (select-window (get-buffer-window bench))
      (hermes-input-send nil))))  ; interactive path
```

### 4.3 Modify: `hermes-render.el`

**Refactor `hermes--render`** (lines ~178-206) to branch on bench presence:

```elisp
(let ((bench-buf (hermes-bench-active-p (current-buffer))))
  (cond
   ;; Stream begin
   ((and (null os) ns)
    (hermes--stream-flush-cancel)
    (setq structural-change t bench-touched-p t)
    (if bench-buf
        (hermes-bench--stream-begin bench-buf)
      (hermes--stream-begin)))
   ;; Stream commit
   ((and os (null ns))
    (when (timerp hermes--stream-render-timer)
      (if bench-buf
          (hermes-bench--stream-update bench-buf nil os)
        (hermes--stream-update nil os)))
    (hermes--stream-flush-cancel)
    (setq structural-change t bench-touched-p t)
    (setq committed-region
          (if bench-buf
              (progn (hermes-bench--stream-commit bench-buf os) nil)
            (hermes--stream-commit os))))
   ;; Stream update
   ((not (eq os ns))
    (cond
     ((zerop hermes-render-stream-throttle)
      (setq bench-touched-p t)
      (if bench-buf
          (hermes-bench--stream-update bench-buf os ns)
        (hermes--stream-update os ns)))
     ((null hermes--stream-render-timer)
      (setq bench-touched-p t)
      (if bench-buf
          (hermes-bench--stream-update bench-buf os ns)
        (hermes--stream-update os ns))
      (hermes--stream-flush-reschedule))
     (t
      (setq hermes--stream-render-pending ns))))))
```

**Note**: When bench is active, `committed-region` from `hermes--stream-commit` is nil (bench handles org insertion internally), so skip the `hermes--refresh-region` for committed-region at line ~267.

**Header-line sync** (line ~232, inside `hermes--render-header` call block):
```elisp
;; Sync bench header-line if present
(let ((bench (hermes-bench-active-p (current-buffer))))
  (when bench
    (with-current-buffer bench
      (hermes-bench-set-header))))
```

**Important**: `hermes--render-ui` (line ~290) should also propagate to bench header-line if active.

### 4.4 Modify: `hermes-input.el`

**No changes required** to `hermes-input-send` itself. The bench calls it programmatically:
```elisp
(with-current-buffer hermes-bench--parent-buffer
  (hermes-input-send text))
```

However, verify that `hermes-input-send` when called **non-interactively** with a string argument bypasses the minibuffer read. Looking at the code (line ~233-248), the interactive spec only runs when called interactively — programmatic calls with `(hermes-input-send "text")` should work fine.

### 4.5 Update: `AGENTS.md`

Add a section documenting:
- Bench is major-mode only
- Window parameters (`side . bottom`, `window-height . 6`)
- Commit semantics (user immediate, assistant deferred)
- How to test: `eldev test` + manual verify in `eldev emacs`

---

## 5. Data Flow

### 5.1 User sends a message (bench active)

```
User types in bench input area -> RET
  -> hermes-bench-send
    -> grab text after input-boundary
    -> hermes-input-send (in parent org buffer)
      -> :user-submit dispatched
        -> hermes--render inserts "** user: ..." into org buffer
      -> prompt.submit RPC sent
    -> clear bench input area
```

### 5.2 Assistant streams response (bench active)

```
message.delta arrives
  -> hermes--route-event -> hermes-dispatch
    -> reducer updates hermes--state stream segments
    -> hermes-state-change-hook fires
      -> hermes--render
        -> branch: bench active
          -> hermes-bench--stream-update
            -> clear ephemeral area
            -> rebuild plain-text from segments
            -> append before input-boundary
            -> auto-scroll window to show latest
```

### 5.3 Stream commits (bench active)

```
message.complete arrives
  -> reducer clears stream, pushes assistant msg to pending-turns
  -> hermes-state-change-hook fires
    -> hermes--render
      -> branch: bench active
        -> hermes-bench--stream-commit
          -> build hermes-message from final segments
          -> with-current-buffer parent
             -> hermes--insert-committed-turn (existing function)
             -> inserts "** assistant...", raw drawer, etc.
          -> hermes-bench-clear-ephemeral
```

---

## 6. Rendering in the Bench

The bench does **not** use org formatting. It uses plain text with overlays for basic styling.

### Segment → bench text mapping

| Segment type | Bench rendering |
|--------------|-----------------|
| `text` | Plain text, wrapped at window width |
| `thinking` | `[thinking: ...]` in muted face (or hidden) |
| `reasoning` | `--- reasoning ---\n...\n---` in italic face |
| `tool` | `🔧 tool: <name>\n<preview>` (use `hermes-tool-formatters` for preview) |
| `system` | `ℹ <text>` in system face |

### Auto-scroll logic

```elisp
(defun hermes-bench--ensure-visible-end ()
  "If point in bench window is near end, keep it at end."
  (let ((win (get-buffer-window (current-buffer))))
    (when win
      (with-selected-window win
        (when (>= (point) (1- hermes-bench--input-boundary))
          (goto-char hermes-bench--input-boundary)
          (recenter -1))))))
```

---

## 7. Testing Strategy

### Unit tests (`test/hermes-bench-test.el`)

1. **`hermes-bench-ensure`**: creates buffer, correct mode, parent link set
2. **`hermes-bench-active-p`**: returns nil when hidden, returns buffer when shown
3. **`hermes-bench-send`**: extracts text after boundary, calls `hermes-input-send` mock, clears input
4. **`hermes-bench-clear-ephemeral`**: deletes region above boundary, preserves input
5. **`hermes-bench--render-stream`**: converts segment vector to expected plain text
6. **`hermes-bench--stream-commit`**: builds message, calls `hermes--insert-committed-turn` mock, clears ephemeral

### Integration tests

1. Open `hermes-mode` buffer -> bench appears at bottom
2. Send message from bench -> user heading appears in org buffer, input clears
3. Simulate stream deltas -> text appears in bench ephemeral area, org buffer unchanged
4. Simulate `message.complete` -> assistant heading + raw drawer appears in org buffer, bench ephemeral clears
5. Kill org buffer -> bench buffer and window disappear
6. Switch between two `hermes-mode` buffers -> correct bench shown for active buffer

---

## 8. Edge Cases & Gotchas

| Case | Handling |
|------|----------|
| **Bench window deleted manually (`C-x 0`)** | `hermes-bench-active-p` returns nil; next `C-c C-i` recreates it. Or `window-configuration-change-hook` can re-ensure. |
| **Org buffer killed** | `kill-buffer-hook` hides bench + kills bench buffer. |
| **Gateway disconnects mid-stream** | `error` path in reducer clears stream; bench commit handles it same as `message.complete`. |
| **User queues message while streaming** | `hermes-input-send` enqueues; bench input clears immediately. Drain hook fires later. Bench ephemeral area stays showing current stream. |
| **Bench text wraps beyond 6 lines** | Fixed window height truncates; user scrolls. `visual-line-mode` ensures soft wraps. |
| **Multi-byte / emoji in stream** | Plain-text rendering should handle multibyte naturally; no byte/char confusion since we use string operations. |
| **Frame split / window params** | `(preserve-size . t)` on side-window keeps height stable during resizes. |

---

## 9. Open Questions (for implementer)

1. **Bench prompt character**: Should the input area show `"> "` (like a REPL) or nothing? Suggest `"> "` with `hermes-bench-prompt` face for visual distinction.
2. **Ephemeral area separator**: Should there be a horizontal line (`─` repeated) between ephemeral area and input area? Suggest yes, via an overlay or inserted rule line.
3. **History in bench**: Should `M-p` / `M-n` cycle through `hermes-state-history` in the bench input area? Suggest yes — bind in `hermes-bench-mode-map`.
4. **Slash command completion**: Should `TAB` in bench input offer slash completion? Suggest yes — reuse `hermes-input-completion-at-point`.

---

## 10. Implementation Order

1. Create `hermes-bench.el` skeleton (mode, ensure/hide, basic buffer setup)
2. Wire `hermes-mode.el` to call `hermes-bench-ensure` on major mode startup
3. Implement bench input/send loop (`hermes-bench-send`, input boundary)
4. Refactor `hermes-render.el` stream lifecycle to branch on bench presence
5. Implement bench stream rendering (`hermes-bench--stream-begin/update/commit`)
6. Add header-line sync to bench
7. Add `C-c C-i` focus-to-bench behavior
8. Add window-selection-change handling for multi-buffer switching
9. Write tests
10. Update `AGENTS.md`

---

*Plan version: 1.0*
*Target branch: feature/bench*
*Estimated lines: ~450 new, ~100 modified*
