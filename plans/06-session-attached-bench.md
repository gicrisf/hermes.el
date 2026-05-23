# PLAN 06: Session-attached bench

## Goal

Detach the bench from a specific parent buffer and attach it to a
session-id instead.  One bench per session, shared by all viewers
(org-minor-mode and section-mode).  The bench knows its `sid`, reads
from `hermes--sessions[sid]`, and lives independently.

Plan 01 made state global.  The bench still carries a
`hermes-bench--parent-buffer` pointer — a leftover from when the org
buffer owned the state.  This plan removes that indirection.

## 1. Current state

The bench stores `hermes-bench--parent-buffer` (a buffer-local variable
on the bench buffer, `hermes-bench.el:166`).  It uses the parent for
three things:

| Use | How | Why obsolete |
|-----|-----|-------------|
| State access | `hermes--buffer-session-state(parent)` → session-id → `gethash` | Store sid directly: `(gethash hermes-bench--session-id hermes--sessions)` |
| Send | `(with-current-buffer parent (hermes-send text))` | `hermes-send` works from any buffer since plan 05 |
| Scroll alignment | `hermes-bench--align-parent-to-tail` | Org-specific hack — section view doesn't need it |
| Kill propagation | `kill-buffer-hook` on parent kills bench | Bench dies when session has no viewers, not when a buffer dies |

Additionally, `hermes--buffer-session-state` (`hermes-state.el:326`)
only walks `hermes--org-buffers` — it can't resolve the session for a
section-mode parent.  With `hermes-bench--session-id`, no lookup is
needed at all.

## 2. What changes

### 2.1 Replace `hermes-bench--parent-buffer` with `hermes-bench--session-id`

```elisp
(defvar-local hermes-bench--session-id nil
  "Session-id for this bench.  Reads state from `hermes--sessions' directly.")
```

Every call site that reads `hermes-bench--parent-buffer` to look up
state is replaced with a direct `gethash` on `hermes-bench--session-id`.
Every call site that switches into the parent buffer for dispatch is
replaced with a direct `hermes-dispatch` or `hermes-send` in the
bench buffer itself.

### 2.2 State access pattern

**Before:**

```elisp
(let* ((parent hermes-bench--parent-buffer)
       (state (and (buffer-live-p parent)
                   (hermes--buffer-session-state parent))))
  ...)
```

**After:**

```elisp
(let* ((state (and hermes-bench--session-id
                   (gethash hermes-bench--session-id hermes--sessions))))
  ...)
```

`hermes--buffer-session-state` is no longer called from bench code.
It remains available for `hermes--resolve-session-target` (the org
path) but the bench doesn't use it.

### 2.3 Send from bench

**Before:**

```elisp
(with-current-buffer parent
  (hermes-send text))
```

**After:**

```elisp
(let ((hermes--current-session-id hermes-bench--session-id))
  (hermes-send text))
```

Since plan 05, `hermes-send` resolves the target from
`hermes--current-session-id` when the buffer context doesn't match
any viewer.  Dynamically binding it ensures the send targets the
correct session.

### 2.4 Bench lifecycle

**Before:** bench lives as long as the parent buffer lives.  The
parent's `kill-buffer-hook` kills the bench.

**After:** bench lives as long as the session has at least one active
viewer.  `hermes-bench-ensure` is called whenever a viewer opens for a
session.  When the **last** viewer is killed, the bench is killed too.
This follows the Eglot pattern: the LSP server lives until the last
managed buffer is killed.

```elisp
(defun hermes-bench-ensure (sid)
  "Ensure a bench buffer exists and is displayed for session SID."
  (let* ((name (format "*hermes-bench:%s*" sid))
         (buf (or (get-buffer name)
                  (generate-new-buffer name))))
    (with-current-buffer buf
      (unless (and (derived-mode-p 'hermes-bench-mode)
                   (equal hermes-bench--session-id sid))
        (hermes-bench-mode)
        (setq hermes-bench--session-id sid)
        (hermes-bench--apply-bg)
        (hermes-bench--initial-paint)))
    (display-buffer-in-side-window
     buf `((side . bottom)
           (slot . 0)
           (window-height . ,hermes-bench-height)
           (dedicated . t)
           (preserve-size . (nil . t))
           (window-parameters . ((no-other-window . nil)
                                  (no-delete-other-windows . t)))))
    (with-current-buffer buf
      (goto-char (point-max)))
    buf))
```

### 2.5 Kill propagation — last viewer kills bench

Each viewer registry (`hermes--org-buffers`, `hermes-section--buffers`)
already has a `kill-buffer-hook` detach function.  After detaching,
if the session has zero viewers across all registries, the bench is
killed:

```elisp
(defun hermes--maybe-kill-bench (sid)
  "Kill the bench for SID if no viewers remain."
  (unless (or (gethash sid hermes--org-buffers)
              (gethash sid hermes-section--buffers))
    (let ((bench (get-buffer (format "*hermes-bench:%s*" sid))))
      (when bench
        (let ((win (get-buffer-window bench)))
          (when (window-live-p win)
            (delete-window win)))
        (kill-buffer bench)))))
```

Called from the org viewer's `hermes--org-detach` and the section
viewer's `hermes-section--detach`.

### 2.6 Section view auto-attach

`hermes-section--open` calls `hermes-bench-ensure` after creating the
buffer:

```elisp
(defun hermes-section--open (sid &optional buf)
  ...
  (pop-to-buffer buf)
  (hermes-bench-ensure sid)
  buf)
```

The section view gets a bench automatically, same as the org view.
No keybinding change needed — `i` can stay bound to `hermes-send`,
or switch to `hermes-bench-focus`.  Both work; preference call.

### 2.7 Guard scroll alignment to org buffers

`hermes-bench--align-parent-to-tail` is called from stream functions to
align the org buffer's windows for the post-commit follow logic.  This
is org-specific — section-mode buffers don't need it.  Resolve the org
buffer from `hermes--org-buffers` with the bench's session-id; silently
no-ops when the session has only section-mode viewers:

```elisp
(defun hermes-bench--align-parent-to-tail ()
  "Align org-viewer windows to point-max for post-commit follow.
No-ops when the session has no org viewer (section-mode only)."
  (when hermes-bench--session-id
    (let ((buf (gethash hermes-bench--session-id hermes--org-buffers)))
      (when (buffer-live-p buf)
        (let ((end (with-current-buffer buf (point-max))))
          (dolist (win (get-buffer-window-list buf nil t))
            (when (/= (window-point win) end)
              (set-window-point win end))))))))
```

### 2.8 Splash detection

`hermes-bench--should-show-splash-p` currently reads state from the
parent.  After the change, it reads from `hermes--sessions` directly:

```elisp
(defun hermes-bench--should-show-splash-p ()
  (let ((state (and hermes-bench--session-id
                    (gethash hermes-bench--session-id hermes--sessions))))
    (and (or (null hermes-bench--current-user-prompt)
             (string-empty-p hermes-bench--current-user-prompt))
         (not (and state (hermes-state-stream state))))))
```

## 3. Files touched

| File | Change |
|------|--------|
| `hermes-bench.el` | Replace `hermes-bench--parent-buffer` with `hermes-bench--session-id`. Replace state lookups with direct `gethash`. Replace `(with-current-buffer parent (hermes-send ...))` with let-bound `hermes--current-session-id`. Replace `hermes-bench-ensure(buffer)` → `hermes-bench-ensure(sid)`. Guard `hermes-bench--align-parent-to-tail` with org-buffer check. |
| `hermes-state.el` | Add `hermes--maybe-kill-bench`. |
| `hermes-section.el` | Call `hermes-bench-ensure(sid)` from `hermes-section--open`. |
| `hermes-mode.el` | Five `hermes-bench-ensure(buffer)` callers (lines 297, 389, 412, 435, 441) → pass `hermes--current-session-id` instead of the buffer. |
| `hermes-sessions.el` | Update `declare-function` signature for `hermes-bench-ensure`; update call site (lines 423-424). |
| `hermes-image.el` | Three reads of `hermes-bench--parent-buffer` (lines 118, 121, 279) → resolve bench via session-id lookup in `hermes-bench-active-p`. |
| `hermes-org.el` | Delete the now-dead `hermes-bench--parent-buffer` arm in `hermes--resolve-session-target` (lines 199-203). The bench stores sid directly so it resolves via the section-mode arm. |
| `hermes-transient.el` | Update docstring reference at line 28 (trivial). |
| test/ | Update bench tests: replace parent-buffer setup with session-id. Test bench attach/detach for section buffers. Test bench kill on last viewer detach. |

## 4. What does NOT change

| Aspect | Stays |
|--------|-------|
| Bench mode (`hermes-bench-mode`) | Same keymap, faces, paint-ephemeral, input handling |
| Bench layout | Same 20-line side window at bottom |
| Slash-command completion | Same — uses session-id for catalog lookup instead of parent-buffer |
| Org viewer bench attach | Same flow — `hermes-bench-ensure(sid)` replaces `hermes-bench-ensure(buffer)` |
| `hermes--buffer-session-state` | Stays (org path still uses it) — bench just stops calling it |

## 5. References

| What | Where |
|------|-------|
| `hermes-bench--parent-buffer` | `hermes-bench.el:166` |
| `hermes-bench-ensure` | `hermes-bench.el:378` |
| `hermes--buffer-session-state` | `hermes-state.el:326` |
| `hermes-section--open` | `hermes-section.el:231` |
| `hermes-bench-send` | `hermes-bench.el:862` |
| `hermes-bench--should-show-splash-p` | `hermes-bench.el:535` |
| `hermes--org-buffers` | `hermes-state.el` (plan 01) |
| `hermes-section--buffers` | `hermes-state.el` (plan 04) |
