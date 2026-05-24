# PLAN: simplify bench to pure input surface

## 1. Motivation

The bench currently has four zones: user prompt, reasoning, answer, and
input.  The prompt/reasoning/answer zones are redundant — every viewer
now streams its own content:

- Org viewer streams the in-flight turn into the visible org buffer
  (plan 17)
- Section viewer streams via `--paint-stream` (plan 16/17)
- Bench streaming duplicates the work, routing content to a side window
  the user may not even be looking at

The bench should become a pure input surface: status header + separator
+ editable input line.  Everything else lives in the primary viewer.

### UX shift for major-mode users

Previously, hermes-mode org buffers streamed into the bench.  After this
plan, they stream inline into the visible org window above the bench.
This is consistent: the viewer you're looking at gets the stream.

## 2. Target layout

Before (4 zones):
```
** U: what is 2+2?           ← prompt zone
  Let me think...            ← reasoning zone
  Sure, 2+2 is 4.            ← answer zone
──────────────────────
[bg: 1 running]              ← status
> █                          ← input
```

After (1 zone):
```
[bg: 1 running]              ← status header
──────                        ← separator
> █                          ← input
```

## 3. New renderer: `hermes-bench--paint-frame`

Replaces `hermes-bench--paint-ephemeral`.  Draws the static bench frame
once at setup.  The input text and cursor position are preserved across
repaints (same save/restore trick the old code used).

```elisp
(defun hermes-bench--paint-frame ()
  "Draw the static bench frame: status header + separator + input prompt.
Preserves the existing input model: read-only guard regions + pre-command-
hook for boundary enforcement (no `field' text property — keeps parity
with current bench behavior)."
  (let* ((inhibit-read-only t)
         (saved-input (hermes-bench--input-text))
         (saved-offset
          (let ((istart (hermes-bench--input-start)))
            (and istart (>= (point) istart) (- (point) istart)))))
    (delete-region (point-min) (point-max))
    (goto-char (point-min))
    (hermes-bench--insert-bg-status)
    ;; Boundary anchored at start of separator (matches current semantics
    ;; in hermes-bench.el:171-174).  --input-start reads this marker,
    ;; forward-lines past the separator, then adds prompt length.
    (setq hermes-bench--input-boundary (copy-marker (point) nil))
    (insert (propertize "──────\n" 'face 'hermes-bench-separator-face
                        'read-only t 'rear-nonsticky t))
    ;; Prompt + input text — no trailing newline (matches current
    ;; --paint-ephemeral line 699 semantics for --input-text).
    (let ((prompt-end (point)))
      (insert (propertize "> " 'face 'hermes-bench-prompt-face
                          'read-only t 'rear-nonsticky t))
      (insert (or saved-input "")))
    ;; Blanket read-only on the status header (point-min to input boundary).
    (put-text-property (point-min) hermes-bench--input-boundary
                       'read-only t)
    (when saved-offset
      (goto-char (+ (hermes-bench--input-start) saved-offset)))))
```

Plus `hermes-bench--refresh-status`: rewrites only the status header
(lines above the separator), preserving input text + cursor.  Deletes
`[point-min, boundary)` — the separator lives at the boundary position
so it survives across refreshes.  Installed in `hermes-bench-mode` via
`(add-hook 'hermes-state-change-hook #'hermes-bench--refresh-status nil t)`.

```elisp
(defun hermes-bench--refresh-status ()
  "Rewrite the status header region, preserving input text and cursor.
Deletes only [point-min, boundary) — the separator and input area
below the boundary are never touched."
  (let* ((inhibit-read-only t)
         (saved-input (hermes-bench--input-text))
         (saved-offset
          (let ((istart (hermes-bench--input-start)))
            (and istart (>= (point) istart) (- (point) istart)))))
    ;; Wipe [point-min, input-boundary) — the status header only.
    ;; The separator lives at the boundary position → survives.
    (delete-region (point-min) hermes-bench--input-boundary)
    (goto-char (point-min))
    (hermes-bench--insert-bg-status)
    ;; Re-apply read-only on the new status area.
    (put-text-property (point-min) hermes-bench--input-boundary
                       'read-only t)
    ;; Restore input text and cursor position.
    (save-excursion
      (goto-char hermes-bench--input-boundary)
      (let ((inhibit-read-only t))
        (delete-region (point) (point-max))
        (insert (propertize "> " 'face 'hermes-bench-prompt-face
                            'read-only t 'rear-nonsticky t))
        (insert (or saved-input ""))))
    (when saved-offset
      (goto-char (+ (hermes-bench--input-start) saved-offset)))))
```

## 4. `hermes-bench--input-boundary`: kept, not removed

Set once in `--paint-frame` at the start of the separator line (before
separator insertion — matches current semantics in `hermes-bench.el`
lines 171-174).  `--input-start` reads this marker, forward-lines past
the separator, then adds prompt length.  All input functions read from
it unchanged.

The boundary is a nil-insertion-type marker.  In `--refresh-status`, the
delete-region `[point-min, boundary)` wipes only the status header — the
separator lives at the boundary position and survives.  After one or more
status refreshes, the separator, boundary, and input area are all
identical to the initial `--paint-frame` layout.

## 5. Functions to remove

| Function | Reason |
|----------|--------|
| `hermes-bench--paint-ephemeral` | Replaced by `--paint-frame` + `--refresh-status` |
| `hermes-bench--segments-by-zone` | Zone rendering no longer needed |
| `hermes-bench--latest-user-text` | Extracts last user prompt |
| `hermes-bench--stream-begin` | Bench no longer handles streaming |
| `hermes-bench--stream-update` | Bench no longer handles streaming |
| `hermes-bench--stream-commit` | Bench no longer handles streaming |
| `hermes-bench--repaint-preserving-stream` | Preserved streaming state during repaint |
| `hermes-bench--insert-splash` | Splash banner no longer shown |
| `hermes-bench--splash-logo` | Splash logo text |
| `hermes-bench--should-show-splash-p` | Splash gating |

## 6. Variables to remove

| Variable | Reason |
|----------|--------|
| `hermes-bench--current-user-prompt` | Stored user prompt |
| `hermes-bench--steer-messages` | Steer message display |
| `hermes-bench--status-message` | Used by `--show-status` |
| `hermes-bench--builtin-logo` | Splash logo |
| `hermes-bench--unicode-logo` | Splash logo |

## 7. Faces to remove

| Face | Reason |
|------|--------|
| `hermes-bench-user-face` | Prompt zone gone |
| `hermes-bench-reasoning-face` | Reasoning zone gone |
| `hermes-bench-attachment-face` | Attachments moved to status line |
| `hermes-bench-steer-face` | Steer display gone |
| `hermes-bench-logo-face` | Splash gone |
| `hermes-bench-splash-status-face` | Splash gone |
| `hermes-bench-banner-type` (defcustom) | Splash gone |

## 8. Callers of removed functions — explicit fate

| Caller | Fate |
|--------|------|
| `hermes-bench-add-steer` / `hermes-bench-steer` | Delete both functions. Remove `C-c C-s` binding from `hermes-bench-mode-map`. Verify with grep that section `--paint-stream` surfaces steer data before assuming it's safe to drop — if absent, relocate steer messages to the status header region rather than orphaning the feature. |
| `hermes-bench-show-status` | Rewrite: show status via `message` (transient echo-area feedback, no skin dependency). Drop `--status-message` variable. |
| Image callbacks → `--repaint-preserving-stream` | Verify with grep. If unreferenced (likely — image callbacks were restructured in plan 02), delete. If still referenced, redirect to `--paint-frame`. |
| Attachments in `--paint-ephemeral` | Move per-attachment detail lines into the status header region (above separator). Keep the same info (`--format-attachment`): name, dimensions, token estimate, status. No info loss. |
| `hermes-bench--setup` | Remove the pre-init `(setq hermes-bench--input-boundary (copy-marker (point-min) nil))` — `--paint-frame` sets the boundary itself. Replace `--paint-ephemeral` call with `--paint-frame`. |

## 9. `hermes--render-1` cleanup (hermes-render.el)

Remove bench-buf dispatch from stream-begin, stream-update, and
stream-commit paths.  The bench no longer handles streaming.

Specifically:

- Drop the `bench-buf` let-binding and `target-visible` resolution
  (lines 231-239)
- Stream-begin: remove `(if bench-buf ...)` branch (lines 245-247)
- Stream-commit: drop the non-bench catch-up guard — the
  `(hermes--stream-update nil os)` call at line 255-256 becomes
  unconditional (no `unless bench-buf` wrapper)
- Stream-update: simplify to just `--stream-update` calls without
  bench dispatch (lines 264-283)

The org buffer streams inline into itself.  The section viewer streams
via its own hook.  The bench has no streaming code path.

## 10. Functions to keep

| Function | Purpose |
|----------|---------|
| `hermes-bench--setup` | Bench buffer init (calls `--paint-frame`) |
| `hermes-bench--input-boundary` (variable) | Set once in `--paint-frame`, never moves |
| `hermes-bench--insert-bg-status` | Bg tasks, attachments, streaming status |
| `hermes-bench--refresh-status` (new) | Rewrites status header only, preserves input |
| `hermes-bench--paint-frame` (new) | Draws static bench frame |
| `hermes-bench--input-start` | Input field start position |
| `hermes-bench--in-input-area-p` | Point-in-input check |
| `hermes-bench--ensure-input-point` | Focus input |
| `hermes-bench--input-text` | Get input text |
| `hermes-bench--clear-input` | Clear input text |
| `hermes-bench--align-org-to-tail` | Org buffer alignment |
| `hermes-bench--state` | State accessor |
| `hermes-bench--apply-bg` / `--effective-bg` / `--refresh-bg-all` | Skin support |
| `hermes-bench-mode` / `--disable-line-numbers` | Mode setup |

## 11. Docs update

CLAUDE.md bench section changes from:

> Bench (major mode only): hermes-mode buffers display a persistent bottom
> bench with structured zones for the last turn: user prompt, reasoning,
> answer, and an editable input area.

To:

> Bench: pure input surface — status header + editable prompt.  All
> streaming content lives in the primary viewer (org or section).

## 12. Scope

`hermes-bench.el` (~300 lines removed, ~40 added), `hermes-render.el`
(remove bench dispatch), `CLAUDE.md` (update bench description),
`hermes-bench.el` (remove `C-c C-s` steer binding from
`hermes-bench-mode-map`).
