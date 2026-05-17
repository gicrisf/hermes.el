# Plan: Unified Status Bar (Mode-Line) + Remove Bench Header-Line

## Context
Currently both the org buffer and the bench buffer have their own `header-line-format`:
- **Org buffer** (`hermes--render-header`): shows "Hermes · ● · model · tokens → queue"
- **Bench buffer** (`hermes-bench-set-header`): shows the same info duplicated

The user wants a **single** status bar positioned at the **bottom** of the org buffer window (directly above the bench side-window). In Emacs, the native bottom bar is `mode-line-format`.

## Goal
1. Remove the bench's `header-line-format` entirely.
2. Move the Hermes status display from `header-line-format` (top) to `mode-line-format` (bottom) on the org buffer.
3. Preserve basic mode-line info (buffer name, position) alongside the Hermes status.
4. Ensure clean restore when `hermes-minor-mode` is turned off.

---

## Analysis of Options

### Option A: Replace `mode-line-format` entirely
Set `mode-line-format` to a custom list that includes only Hermes status + minimal buffer info.

**Pros:** Full control, simple, works in vanilla Emacs.
**Cons:** Loses default mode-line elements (line/column, encoding, etc.) unless we explicitly include them.

### Option B: Append Hermes status to existing `mode-line-format`
Save the original `mode-line-format`, then append the Hermes status segment.

**Pros:** Preserves user's existing mode-line customizations (e.g., `doom-modeline`).
**Cons:** Need to save/restore original format carefully to avoid duplication.

### Option C: Integrate with `doom-modeline` (Doom-specific)
Define a `doom-modeline-def-segment` for Hermes status and add it to the Doom modeline.

**Pros:** Native feel for Doom users.
**Cons:** Doom-only, adds dependency complexity, doesn't help vanilla Emacs users.

---

## Recommendation: Option A with a minimal built-in fallback

Replace `mode-line-format` with a **simple, self-contained** format that includes:
1. Buffer identification (`mode-line-buffer-identification`)
2. Hermes status (connection dot, model, tokens, queue)
3. Cursor position (`mode-line-position`)

This is robust because:
- It doesn't need to save/restore anything complex.
- It works regardless of whether the user uses `doom-modeline`, `powerline`, or vanilla.
- When `hermes-minor-mode` turns off, we restore `mode-line-format` to its default value (`(default-value 'mode-line-format)`), which correctly handles both vanilla and Doom cases.

---

## Proposed Changes

### 1. `hermes-render.el` — `hermes--render-header` becomes `hermes--mode-line-update`

The function no longer sets `header-line-format`. Instead, it updates a **variable** that the mode-line format reads dynamically.

```elisp
(defvar-local hermes--mode-line-status ""
  "Dynamic Hermes status text displayed in the mode-line.
Updated by `hermes--mode-line-update' whenever the ephemeral state changes.")

(defun hermes--mode-line-update (&optional _state)
  "Recompute `hermes--mode-line-status' from the current state.
Called from `hermes-ui-state-change-hook'."
  (setq hermes--mode-line-status
        (concat
         " Hermes"
         (pcase (and hermes--state (hermes-state-connection hermes--state))
           ('connected    " · ●")
           ('connecting   " · ◐")
           ('disconnected " · ○")
           (_             ""))
         (let* ((info  (and hermes--state (hermes-state-session-info hermes--state)))
                (model (and (hash-table-p info) (gethash "model" info))))
           (if model (format " · %s" model) ""))
         (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                (sent  (and usage (gethash "tokens_sent" usage)))
                (recv  (and usage (gethash "tokens_received" usage))))
           (if (or sent recv)
               (format " · %s→%s" (or sent "?") (or recv "?"))
             ""))
         (let ((q (and hermes--state (hermes-state-queue hermes--state))))
           (if (and q (> (length q) 0))
               (format " · queue: %d" (length q))
             ""))
         " "
         (or hermes--ui-line "")))
  (force-mode-line-update))
```

### 2. `hermes-mode.el` — `hermes-minor-mode--on` sets `mode-line-format`

```elisp
(defun hermes-minor-mode--on ()
  "Setup for `hermes-minor-mode': org-local config, hooks, mode-line.
Idempotent — safe to run when already armed."
  ...
  ;; Replace header-line with mode-line status.
  (setq-local mode-line-format
              '("%e"
                mode-line-front-space
                mode-line-mule-info
                mode-line-client
                mode-line-modified
                mode-line-remote
                mode-line-frame-identification
                mode-line-buffer-identification
                "  "
                (:eval hermes--mode-line-status)
                "  "
                mode-line-position
                "  "
                mode-line-modes
                mode-line-end-spaces))
  ;; Clear any stale header-line from a previous activation.
  (setq header-line-format nil)
  ...)

(defun hermes-minor-mode--off ()
  "Teardown for `hermes-minor-mode'."
  ...
  (setq mode-line-format (default-value 'mode-line-format))
  (setq header-line-format nil)
  ...)
```

**Note:** Using `(default-value 'mode-line-format)` correctly restores:
- Vanilla Emacs default
- Doom-modeline's custom format (if Doom is active)
- Any other global mode-line customization

### 3. `hermes-bench.el` — Remove bench header-line

In `hermes-bench--setup`, explicitly disable the header-line:

```elisp
(defun hermes-bench--setup (parent)
  "Initialize the bench buffer contents for PARENT."
  (hermes-bench-mode)
  (setq hermes-bench--parent-buffer parent
        hermes-bench--current-user-prompt nil)
  (setq-local header-line-format nil)   ; ← no bench header
  ...)
```

Remove or deprecate `hermes-bench-set-header`. It is no longer called. The function body can become a no-op (to avoid breaking any external callers), or be deleted entirely.

Also update `hermes-bench--refresh-ui` to remove the `hermes-bench-set-header` call:

```elisp
(defun hermes-bench--refresh-ui (&optional _old _new)
  "Repaint the bench splash if it's currently showing."
  (let ((bench (hermes-bench-active-p)))
    (when (buffer-live-p bench)
      (with-current-buffer bench
        (when (hermes-bench--should-show-splash-p)
          (hermes-bench--paint-ephemeral)
          ;; (hermes-bench-set-header)  ; ← REMOVED
          )))))
```

And remove the call in `hermes-bench--stream-begin`:

```elisp
(defun hermes-bench--stream-begin (bench)
  "Stream started: ensure user prompt is set, clear reasoning/answer."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      (let ((user (or hermes-bench--current-user-prompt ...)))
        (hermes-bench--paint-ephemeral user "" ""))
      ;; (hermes-bench-set-header)  ; ← REMOVED
      )))
```

### 4. `hermes-mode.el` — Update hooks

In `hermes-minor-mode--on`, the `hermes-ui-state-change-hook` should call `hermes--mode-line-update` instead of `hermes--render-ui`:

```elisp
(add-hook 'hermes-ui-state-change-hook #'hermes--mode-line-update t t)
```

In `hermes-minor-mode--off`:

```elisp
(remove-hook 'hermes-ui-state-change-hook #'hermes--mode-line-update t)
```

Remove or update `hermes--render-ui` (the old header-line function). It can be deleted since `hermes--mode-line-update` replaces it.

---

## Visual Result

**Before (two bars):**
```
┌─────────────────────────────────────────────┐
│ Hermes · ● · deepseek-v4-flash              │ ← org header-line
├─────────────────────────────────────────────┤
│ * Hermes session :hermes:                   │
│ ** U: Hello                                 │
│ ...                                         │
├─────────────────────────────────────────────┤
│ Hermes · ● · deepseek-v4-flash · 12→45     │ ← bench header-line
│ Hello, how can I help?                      │
│ ------                                      │
│ >                                           │
└─────────────────────────────────────────────┘
```

**After (single bar at bottom):**
```
┌─────────────────────────────────────────────┐
│ * Hermes session :hermes:                   │
│ ** U: Hello                                 │
│ ...                                         │
├─────────────────────────────────────────────┤
│ *hermes:abc123*  Hermes · ● · deepseek...  │ ← org mode-line (bottom)
├─────────────────────────────────────────────┤
│ Hello, how can I help?                      │
│ ------                                      │
│ >                                           │
└─────────────────────────────────────────────┘
```

---

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| `hermes-minor-mode` toggled off | `mode-line-format` restored to global default. Bench header stays nil. |
| `doom-modeline` active | `(default-value 'mode-line-format)` returns Doom's format; restore works correctly. |
| Bench killed and recreated | `hermes-bench--setup` sets `header-line-format` to nil; no duplicate bar. |
| Multiple Hermes sessions in one org file | Each buffer has its own `mode-line-format`; only the active session's status is shown (buffer-local `hermes--state`). |

## Out of Scope
- Doom-modeline custom segment integration (Option C): can be added later as an enhancement.
- Preserving every element of a highly customized user mode-line: Option A replaces the format entirely; users who want full control can customize `mode-line-format` themselves after enabling `hermes-minor-mode`.
