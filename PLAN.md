# Plan: Follow point-max after bench (and non-bench) commits

## Problem

When a turn commits from the bench, `hermes--render` appends the finished assistant turn at `point-max` of the org buffer. Because all edits are wrapped in `with-silent-modifications` + `save-excursion`, windows showing the org buffer stay pinned to their old *numerical* position and end up somewhere in the middle of the newly inserted text. The user has to manually scroll down to see the committed content.

A related gap: if the user starts the bench without ever touching the org buffer (e.g. a fresh session), the org buffer window is not at `point-max`, so the commit-follow logic won't capture it.

## Proposed change

### Part A: Pre-align the parent org buffer on bench entry / send

**Files:** `hermes-bench.el` — `hermes-bench--show` (creation/focus) and `hermes-bench-send`

Before the user can send from the bench, ensure any live windows showing the **parent org buffer** (`hermes-bench--parent-buffer`) are scrolled to `point-max`.

- Use `get-buffer-window-list parent nil t` to find windows showing that specific org buffer.
- For each live window, if `window-point` is not already at `point-max`, call `set-window-point` to `point-max`.

This guarantees that:
- Fresh sessions start with the org buffer aligned to the bottom.
- Users who scrolled up in the org buffer and then focused the bench are brought back to the tail before the next turn.
- The pre-commit capture in Part B naturally includes the parent org buffer windows.

Because the bench knows its exact parent via `hermes-bench--parent-buffer`, this scroll is scoped to **only** that org buffer — no side effects on unrelated buffers.

### Part B: capture tail-following windows before the paint block

**File:** `hermes-render.el` — function `hermes--render`

Before entering `with-silent-modifications`, compute:

- `old-point-max` — the current `point-max` of the buffer.
- `tail-windows` — a list of live windows showing the current buffer whose `window-point` equals `old-point-max`.

Use `get-buffer-window-list (current-buffer) nil t` and filter with `window-point`.

### Part C: advance captured windows after the commit

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
- **Fresh session / never touched org buffer:** Part A pre-aligns the parent org buffer before the first send, so Part B captures it.

## Testing

1. Run `eldev test` after implementation to verify no regressions in `hermes-render-test` (which already covers `stream-commit`, bench overlay removal, and marker clearing).
2. Optionally add an ERT test in `test/hermes-render-test.el`:
   - Open the org buffer in a window.
   - Move `window-point` to `point-max`.
   - Drive `hermes--render` through a `message.complete` transition.
   - Assert that `window-point` now equals the new `point-max`.
3. Optionally add a bench-specific ERT test:
   - Create a parent org buffer with content.
   - Open a bench for that parent.
   - Assert that the parent org buffer's visible window is now at `point-max`.

## Decision: bench-only or both paths?

Apply Part B to **both** bench and non-bench commits (whenever `msg-append-start` or `committed-region` is set). The user's expectation ("I was at the bottom, keep me at the bottom") is identical in both modes. Restricting it to bench-only would leave minor-mode users with the same scroll-lag bug.

Part A (pre-alignment) applies only to the bench path, because that's where the parent-buffer relationship is explicit and unambiguous.
