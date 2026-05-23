# PLAN: hermes-section streaming

## 1. Motivation

The last parity gap between the Org renderer and the section viewer.  The
Org renderer shows live responses character by character; the section
viewer stays frozen until `message.complete` fires.  This plan adds
streaming to the magit-section buffer.

## 2. Approach: region-rebuild (not markers)

### 2.1 Why not markers

The reducer mutates the in-flight stream in ways that aren't pure append:

| Mutation | Example | Marker impact |
|----------|---------|---------------|
| In-place text-segment update | `message.delta` rewrites contiguous tail segment | Marker silently drifts |
| Reasoning dedup | `reasoning.delta` suppressed when duplicate of prior text/reasoning | Marker goes stale |
| Tool body replacement | `tool.complete` replaces preview with full formatter output | Needs per-tool update logic |

Tracking these with per-segment markers leaks implementation knowledge
about the reducer into the section viewer.  Worse: it violates the
file's design principle — _"section view is a pure projection of state"_
(CLAUDE.md).

### 2.2 Region-rebuild

On each throttled tick: erase the streaming region and rebuild it from
the current `hermes-state-stream`.  This is a pure `state → UI` function.

```
[committed magit sections]     ← frozen, never touched during streaming

─────────────────              ← sentinel position (marker, nil insertion-type)

  [streaming region]           ← erased + rebuilt every throttle tick
  ● 3 · Assistant · model     ← from hermes-state-stream.segments
  ├─ Reasoning
  │   ...
    response text...
  ├─ RUNNING calculator
```

Performance: the adaptive throttle already caps repaints at 0.5 Hz once
the response exceeds 10,000 chars.  At that rate the cost of a full
region re-render is bounded — tool fontification is the heaviest step,
and even that is ~5ms per tool.

Compared to the marker approach:

| | Markers | Region-rebuild |
|---|---|---|
| Pure projection | No (mutable markers + streaming-p flag) | Yes |
| Code size | ~80 lines + 4 buffer-local variables | ~40 lines, 1 marker (sentinel) |
| Handles in-place text updates | Breaks silently | Works (full re-render) |
| Handles reasoning dedup | Breaks | Works |
| Handles tool body replacement | Manual per-tool update | Reuses existing inserters |
| Tool body fontification | Manual per-tool during streaming | `--fontify-as-org` on every paint (capped by throttle) |

## 3. Visual layout during streaming

```
[committed magit sections]
#1 · User · 14:30
  what is 2+2?

#2 · Assistant · deepseek-v4-flash · 14:32
  Sure, 2+2 is 4.

──────────────────────────────  ← sentinel

● 3 · Assistant · deepseek-v4-flash · 14:33
├─ Reasoning                    ← collapsed (visibility cache stable)
│   The user asked a simple...
  Let me calculate 2+2 for you.
  The answer is...

├─ RUNNING calculator            ← tool.generating
│   generating...
```

The streaming region is rebuilt from scratch on every throttled paint.
Committed content above the sentinel is never touched during streaming.
When `message.complete` fires: delete streaming region → commit to
`turns` → normal `--rebuild`.  The visibility cache (wired in Plan 15)
preserves any folds the user made during streaming.

## 4. Streaming state

One buffer-local marker — the sentinel:

| Variable | Insertion-type | Purpose |
|----------|:---:|---------|
| `--stream-sentinel` | nil | First char of the streaming region.  nil between turns. |

Plus throttle state (identical to the Org renderer):
- `--stream-timer` — active cooldown timer
- `--stream-pending` — latest un-flushed state snapshot

No `--streaming-p` flag needed — sentinel being non-nil IS the guard.
No per-segment markers.  No mutable UI state beyond throttle internals.

## 5. State diffs → rendering

The section viewer hooks `hermes-state-change-hook`, which delivers
`(old new)` state pairs.  Every "event" below is a diff between
`(hermes-state-stream old)` and `(hermes-state-stream new)`.

### 5.1 `stream-begin`  (old-stream nil, new-stream non-nil)

`message.start` creates an empty stream in state.  The section viewer:

1. Insert sentinel separator line at point-max
2. Insert stream heading: `● N · Assistant · model · HH:MM` where
   N = `(1+ (length hermes-state-turns))`
3. Create the sentinel marker
4. Call `--stream-update` to render initial content (reasoning may
   already be present)

### 5.2 `stream-update`  (old-stream and new-stream both non-nil, different)

Every `message.delta`, `reasoning.delta`, `tool.*`, and `subagent.*`
event mutates `stream.segments` in place.  `eq` detects the change.
The section viewer:

1. Throttle check: if within cooldown → stash `new` as `--stream-pending`, return
2. `(delete-region sentinel (point-max))`
3. Rebuild streaming turn from `new-stream.segments`:
   - Reasoning pass: insert child sections via `--insert-reasoning-child`
   - Response text: insert via `--insert-full-text`
   - Tool pass: insert child sections via `--insert-tool-child`
   - Subagents: insert via `--insert-subagent-child`
4. `(goto-char (point-max))`
5. Auto-scroll tail-windows to point-max (Plan 13 §4)

All four insertion functions are the same ones used for committed turns
— including `--fontify-as-org` for tool bodies.  The visibility cache
preserves the user's collapse state across the re-render because section
identities (`hermes-tool-id`, `hermes-segment-id`) are stable.

### 5.3 `stream-commit`  (old-stream non-nil, new-stream nil)

`message.complete` (or `error`) clears the stream in state.  The section
viewer:

1. Cancel pending throttle timer
2. `(delete-region sentinel (point-max))`
3. Reset sentinel marker to nil
4. `(goto-char (point-max))`
5. The reducer pushes the committed message to `pending-turns`, which
   updates `turns` → the normal `turns-changed` path in `--refresh`
   fires `--rebuild`.  Cache preserves user's fold state.

### 5.4 `turns-changed`  (no stream, turns vector grew)

Same as current behavior: `--rebuild`.  Not affected by streaming.

## 6. Throttling

Reuse the existing `hermes--adaptive-throttle-interval` helper from
`hermes-state.el`.  Same pattern as the Org renderer:

- First paint after idle → paint immediately, arm cooldown timer
- Subsequent paints within cooldown → stash `new` state, skip
- Timer fires → paint stashed state, re-arm

Lifecycle transitions (`stream-begin`, `stream-commit`) always paint
synchronously.

Adaptive thresholds:

| Rendered size | Interval | Rate |
|--------------|----------|------|
| < 1,000 chars | 40 ms | 25 Hz |
| < 5,000 chars | 200 ms | 5 Hz |
| < 10,000 chars | 1,000 ms | 1 Hz |
| ≥ 10,000 chars | 2,000 ms | 0.5 Hz |

Rendered size is estimated from `(length printed-string)` of the
streaming region.  At 10K+ chars and 2s per repaint, even a full
re-render (including tool fontification) is negligible.

## 7. Auto-scroll during streaming

Same pattern as Plan 13 §4, applied to streaming paints:

- Before every `--stream-update` throttled paint: snapshot which
  windows are at point-max
- After paint: advance those windows to new point-max

User who scrolled up during streaming stays put.  User at tail sees
real-time text flow.

## 8. Integration with `hermes-section--refresh`

The current `--refresh` function (called from `hermes-state-change-hook`)
gains a stream dispatch branch.  **Bug fix from previous version:** the
old-stream is read from the `old` parameter (not re-fetched from the
state slot):

```elisp
(defun hermes-section--refresh (old new)
  (hermes--on-session-buffer hermes-section--buffers
    (let ((old-stream (hermes-state-stream old))
          (new-stream (hermes-state-stream new)))
      (cond
       ;; Stream began
       ((and (null old-stream) new-stream)
        (hermes-section--stream-begin new))
       ;; Stream updated
       ((and old-stream new-stream (not (eq old-stream new-stream)))
        (hermes-section--stream-update old-stream new-stream))
       ;; Stream ended → fall through to turns check for rebuild
       ((and old-stream (null new-stream))
        (hermes-section--stream-commit))
       ;; Turns changed (no stream involved, or after stream-commit)
       ((not (eq (hermes-state-turns new)
                 hermes-section--turns-snapshot))
        (hermes-section--rebuild new))
       ;; Stream was the only change (e.g. same stream object pointer,
       ;; which shouldn't happen but is harmless)
       (t nil)))))
```

Note: `old` no longer has the `_` prefix — it's actually used.

## 9. Scope

`hermes-section.el` only.  New code:
- One buffer-local marker variable (`--stream-sentinel`)
- Throttle state (`--stream-timer`, `--stream-pending`)
- `--stream-begin`, `--stream-update`, `--stream-commit`
- Revised `--refresh` dispatch

All streaming region rendering reuses the same `--insert-*` functions
used for committed turns.  No new rendering code.  No new dependencies.
No state layer changes.  No Org renderer changes.  Estimated ~40 new
lines.
