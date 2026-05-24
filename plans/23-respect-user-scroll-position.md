# PLAN 23: Respect user scroll position during output

## Problem

Every time new stream content arrives, `hermes-comint--ensure-prompt-visible`
jumps the window back to `(point-max)` — even when the user has scrolled up
to read older turns.

### Autoscroll trigger points

There are **5 call sites** for `hermes-comint--ensure-prompt-visible`:

| Call site | Trigger | Condition |
|-----------|---------|-----------|
| `hermes-comint--paint-stream` (L597) | Every stream tick (0.04–2s throttle) | Always |
| `hermes-comint--stream-commit` (L745) | Turn finishes | Always |
| `hermes-comint--open` (L1003) | Buffer first opened | Always |
| `hermes-comint-bench--repaint-ephemeral` (L1195) | Steer / status push | Always |
| `hermes-comint--setup` (L897) | Mode init | Always |

The function itself is unconditional:

```elisp
(defun hermes-comint--ensure-prompt-visible ()
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (with-selected-window w
        (when (< (window-point w) (marker-position hermes-comint--prompt-start))
          (set-window-point w (point-max)))))))
```

If the user's `window-point` is anywhere above the prompt prefix, the window
jumps to the bottom.  There is no check for whether the user *chose* to be
up there (reading) or just happens to be there (because new output pushed
them).

Additional comint-level autoscroll is enabled by three mode-local settings:

```elisp
(setq-local comint-scroll-to-bottom-on-input t)   ;; L958
(setq-local comint-move-point-for-output 'this)   ;; L959
(setq-local comint-scroll-show-maximum-output t)  ;; L960
```

`comint-move-point-for-output 'this` scrolls the selected window when
process output is inserted.  Since we insert stream ticks as comint output,
this is a second layer of unwanted autoscroll.

### Impact

- **Streaming:** every 0.04–2 seconds, scrolling up to read an older turn
  is interrupted by a jump to the bottom.
- **Stream commit:** the turn you were reading before the assistant finished
  is yanked away.
- **Bench steer/status pushes:** status feedback like `[steer] ...` forces
  the bench window back to the bottom even while the user navigates.

### Non-trivial edge cases

1. **Bench + full-viewer windows on the same buffer:** `get-buffer-window-list`
   iterates ALL windows.  If the user is reading history in the full-viewer
   and a stream tick fires, BOTH windows scroll.  A stick-to-bottom check
   must be per-window.

2. **Comint `comint-move-point-for-output`:** even if we fix our own
   `ensure-prompt-visible`, comint itself scrolls on output insertion.
   Setting this to nil would disable auto-scroll entirely, but then users
   who *are* reading the latest output (point at `point-max`) need to
   manually scroll.

3. **Bench bench-p case:** the ephemeral region is tiny (user heading +
   stream).  The user is unlikely to scroll there, but if they do (e.g.
   to copy an error message), we shouldn't fight them.

4. **Initial open (`hermes-comint--open`):** this one should probably
   always scroll to bottom — the user just opened the buffer and wants
   to see the latest content.  But even here, if the buffer was already
   open in a window and the user had scrolled up, should we respect
   that?

5. **`scroll-conservatively 101` (L962):** Emacs tries to keep point on
   screen, which interacts with `set-window-point` in complex ways.

## Proposed approach

### Core rule: per-window stick-to-bottom predicate

Before painting, check each window: the user is "at bottom" if their
`window-point` is at or after the prompt-start marker (i.e. in the
prompt/input area).  Scroll only for those windows; leave scrolled-up
windows alone.

```elisp
(defun hermes-comint--window-at-bottom-p (w)
  "Return non-nil if window W is scrolled to the bottom (prompt visible).
The user is at bottom when `window-point' is at or past the prompt prefix."
  (and (marker-position hermes-comint--prompt-start)
       (>= (window-point w) (marker-position hermes-comint--prompt-start))))
```

Alternative: also treat "point-max is visible in the window" as at-bottom
(handles narrow windows where the visible region still contains point-max
even if window-point is slightly before prompt-start).  `pos-visible-in-window-p`
is the usual check, but `>= prompt-start` is simpler and covers the
dominant case.

### Rewrite `hermes-comint--ensure-prompt-visible`

Add a STICKY parameter: when non-nil, only scroll windows the user left at
bottom.

```elisp
(defun hermes-comint--ensure-prompt-visible (&optional sticky)
  "Scroll windows so the prompt is visible.
When STICKY is non-nil, only scroll windows whose `window-point' is
already at or past the prompt — windows the user has scrolled up are
left alone."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (and (window-live-p w)
               (or (not sticky)
                   (hermes-comint--window-at-bottom-p w)))
      (with-selected-window w
        (when (< (window-point w) (marker-position hermes-comint--prompt-start))
          (set-window-point w (point-max)))))))
```

### Disable comint's second autoscroll layer

`comint-move-point-for-output 'this` fights us: it fires during
`delete-region` + re-insertion on every tick, before our own function
can inspect window positions.  Set it to nil mode-wide and let our
function be the sole authority.

```elisp
(setq-local comint-move-point-for-output nil)
```

`comint-scroll-to-bottom-on-input` stays `t` — it scrolls when the user
types, which is a different path and not disruptive (the user is typing
and wants to see the prompt).

### Call-site classification

| Call site | Sticky? | Rationale |
|-----------|---------|-----------|
| `hermes-comint--paint-stream` (L597) | **yes** | Streaming; user may be reading history |
| `hermes-comint--stream-commit` (L745) | **yes** | Turn finishes mid-read — worst offender |
| `hermes-comint-bench--repaint-ephemeral` (L1195) | **yes** | Steer/status push; user may be inspecting output |
| `hermes-comint--setup` (L897) | **no** | Mode init — always start at bottom |
| `hermes-comint--open` (L1003) | **no** | User explicitly opened buffer — show latest |

### Recovery

`C-c C-i` (`hermes-comint-focus-prompt`) already does `(goto-char (point-max))`
and makes the bench window visible.  No new affordance needed.

## Net diff

| File | Action | Lines |
|------|--------|-------|
| `hermes-comint.el` | Add `hermes-comint--window-at-bottom-p` | +6 |
| `hermes-comint.el` | Rewrite `hermes-comint--ensure-prompt-visible` with sticky param | -6 +12 |
| `hermes-comint.el` | Set `comint-move-point-for-output` to nil | -1 +1 |
| `hermes-comint.el` | Update 3 call sites to pass `t` | -3 +3 |
| **Net** | | **+10** |

## Sequence

| Step | Action | Verify |
|------|--------|--------|
| 1 | Add `hermes-comint--window-at-bottom-p` | `eldev compile` |
| 2 | Rewrite `hermes-comint--ensure-prompt-visible` with sticky param | `eldev compile` |
| 3 | Set `comint-move-point-for-output` to nil | `eldev compile` |
| 4 | Update `paint-stream`, `stream-commit`, `bench-repaint` call sites to pass `t` | `eldev compile` |
| 5 | Run `eldev test` | `eldev test` |
| 6 | Manual smoke: scroll up during active stream → window stays put; type → prompt stays visible | — |

## References

| What | Where |
|------|-------|
| `hermes-comint--ensure-prompt-visible` | `hermes-comint.el:859-865` |
| `hermes-comint--paint-stream` | `hermes-comint.el:578-597` |
| `hermes-comint--stream-commit` | `hermes-comint.el:717-745` |
| `hermes-comint--setup` | `hermes-comint.el:384-398` |
| `hermes-comint--open` | `hermes-comint.el:985-1004` |
| `hermes-comint-bench--repaint-ephemeral` | `hermes-comint.el:1184-1195` |
| Comint scroll settings | `hermes-comint.el:958-960` |
