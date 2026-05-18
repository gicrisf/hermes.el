# Plan: Canonical bench resolution utilities

## Background

The skills command implementation revealed a subtle but recurring problem: when a user invokes a command from the **bench buffer** (the bottom side-window where input happens), code that wants to display feedback in the bench must first resolve "am I in the bench buffer?" to "what's the parent org buffer?". This logic was ad-hoc in `hermes--skills-show-output` and will keep being rediscovered by every new feature that displays status in the bench.

## Problem

There is no single canonical way to answer these questions:
- Is the current buffer a bench buffer?
- What is the parent org buffer of this bench?
- Is there an active bench for this buffer (regardless of whether I'm in it)?

Every caller currently does its own `(eq major-mode 'hermes-bench-mode)` check or manually reads `hermes-bench--parent-buffer`. This is fragile and will break as soon as someone adds a new command without knowing about the bench/parent duality.

## Proposed changes

### 1. Add three utility functions to `hermes-bench.el`

#### `hermes-bench-buffer-p`
```elisp
(defun hermes-bench-buffer-p (&optional buffer)
  "Return non-nil if BUFFER (or current buffer) is a bench buffer.
Checks `major-mode' against `hermes-bench-mode'.")
```

#### `hermes-bench-resolve-parent`
```elisp
(defun hermes-bench-resolve-parent (&optional buffer)
  "Resolve BUFFER to its parent org buffer.
If BUFFER is a bench buffer, return `hermes-bench--parent-buffer'.
If BUFFER is already an org/hermes buffer, return it as-is.
Otherwise return nil.")
```

#### `hermes-bench-live-p`
```elisp
(defun hermes-bench-live-p (&optional buffer)
  "Return non-nil if an active bench exists for BUFFER.
BUFFER may be a bench buffer or a parent org buffer.
Returns the live bench buffer, or nil.")
```

### 2. Refactor `hermes-bench-active-p`

`hermes-bench-active-p` already does parent→bench lookup. Keep it as the low-level primitive, but document that `hermes-bench-live-p` is the preferred public API for "is there a bench?" checks.

### 3. Replace ad-hoc bench detection in `hermes-config.el`

In `hermes--skills-show-output`, replace the inline `major-mode` check:

```elisp
;; Before (current, ad-hoc)
(when (and (buffer-live-p buf)
           (eq (buffer-local-value 'major-mode buf)
               'hermes-bench-mode))
  (setq buf (buffer-local-value 'hermes-bench--parent-buffer buf)))

;; After (using canonical utility)
(setq buf (hermes-bench-resolve-parent buf))
```

Also remove the `parent-buf` parameter from `hermes--skills-show-output` — `hermes-bench-resolve-parent` with no args handles the `current-buffer` case automatically.

### 4. Audit other callers

Search for these patterns across the codebase and migrate to canonical utilities:
- `(eq major-mode 'hermes-bench-mode)` → `hermes-bench-buffer-p`
- `(buffer-local-value 'hermes-bench--parent-buffer ...)` → `hermes-bench-resolve-parent`
- `(hermes-bench-active-p (current-buffer))` without first resolving parent → `hermes-bench-live-p`

Expected files to touch:
- `hermes-bench.el` — add utilities, update docstrings
- `hermes-config.el` — replace ad-hoc detection in skills commands
- Possibly `hermes-mode.el`, `hermes-render.el` if they have bench-related conditionals

### 5. Add ERT tests

In `test/hermes-render-test.el` (or a new `test/hermes-bench-test.el`):

- `hermes-bench-test/buffer-p-nil-for-org-buffer`
- `hermes-bench-test/buffer-p-t-for-bench-buffer`
- `hermes-bench-test/resolve-parent-from-bench`
- `hermes-bench-test/resolve-parent-returns-self-for-org`
- `hermes-bench-test/live-p-returns-bench-for-parent`
- `hermes-bench-test/live-p-returns-bench-for-bench`

## Files to change

| File | What |
|------|------|
| `hermes-bench.el` | Add `hermes-bench-buffer-p`, `hermes-bench-resolve-parent`, `hermes-bench-live-p` |
| `hermes-config.el` | Replace ad-hoc bench detection in `hermes--skills-show-output` |
| `test/hermes-render-test.el` (or new `test/hermes-bench-test.el`) | Add unit tests for the three utilities |

## Testing

1. `eldev test` — must remain 193/193 green (or 199/199+ after adding bench tests).
2. Live gateway test:
   - `M-x hermes-skills-uninstall` from the **bench buffer** — error should appear in bench
   - `M-x hermes-skills-uninstall` from the **org buffer** — error should still appear in bench
   - `M-x hermes-skills-reload` from either buffer — output should appear correctly

## Notes

- This is a **pure refactor** — no behavior change for users. The only observable difference is cleaner code.
- `hermes-bench-resolve-parent` should be the single point of truth for "which org buffer owns this bench?". Any future feature that needs to display in the bench should call it first.
- Keep `hermes-bench-active-p` as the low-level primitive for direct parent→bench lookup. `hermes-bench-live-p` is the convenience wrapper that handles both directions.
