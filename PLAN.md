# Plan: Follow point-max after bench (and non-bench) commits

## Problem

When a turn commits from the bench, `hermes--render` appends the finished assistant turn at `point-max` of the org buffer. Because all edits are wrapped in `with-silent-modifications` + `save-excursion`, windows showing the org buffer stay pinned to their old *numerical* position and end up somewhere in the middle of the newly inserted text. The user has to manually scroll down to see the committed content.

## Proposed change

**File:** `hermes-render.el` — function `hermes--render`

### Step 1: capture tail-following windows before the paint block

Before entering `with-silent-modifications`, compute:

- `old-point-max` — the current `point-max` of the buffer.
- `tail-windows` — a list of live windows showing the current buffer whose `window-point` equals `old-point-max`.

Use `get-buffer-window-list (current-buffer) nil t` and filter with `window-point`.

### Step 2: advance captured windows after the commit

After the `with-silent-modifications` block exits, in the existing `derived-mode-p 'org-mode` post-pass, when **either** `msg-append-start` is non-nil (bench commit or pending-turn drain) **or** `committed-region` is non-nil (non-bench `stream-commit`):

- Compute `new-point-max`.
- For each window in `tail-windows` that is still `window-live-p`, call `set-window-point` to `new-point-max`.

### Why this spot?

`hermes--render` is the single paint entry point. `msg-append-start` is set exactly when the buffer appends at `point-max` (bench commit via `hermes-bench--stream-commit`, or queued turn drain via `hermes--insert-committed-turn`). `committed-region` is set for non-bench `stream-commit`.

By capturing windows **before** modifications and advancing them **only** after committed inserts, we avoid interfering with in-flight stream deltas (where the user may have scrolled up to read earlier content while tokens stream in).

### Edge cases handled

- **Window closed during async render:** guarded by `window-live-p`.
- **Buffer not visible:** `get-buffer-window-list` returns nil → no-op.
- **User scrolled up during stream:** `window-point` ≠ `old-point-max` → window is not in `tail-windows` → untouched.
- **Bench window selected:** only windows showing the org buffer are touched; bench is a separate buffer.

## Testing

1. Run `eldev test` after implementation to verify no regressions in `hermes-render-test` (which already covers `stream-commit`, bench overlay removal, and marker clearing).
2. Optionally add an ERT test in `test/hermes-render-test.el`:
   - Open the org buffer in a window.
   - Move `window-point` to `point-max`.
   - Drive `hermes--render` through a `message.complete` transition.
   - Assert that `window-point` now equals the new `point-max`.

## Decision: bench-only or both paths?

Apply it to **both** bench and non-bench commits (whenever `msg-append-start` or `committed-region` is set). The user's expectation ("I was at the bottom, keep me at the bottom") is identical in both modes. Restricting it to bench-only would leave minor-mode users with the same scroll-lag bug.
