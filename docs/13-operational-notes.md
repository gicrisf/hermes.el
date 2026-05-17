## 13. Operational Notes & Debugging

### 13.1 Reducer Copy Semantics

#### `hermes--with-copy` = shallow copy

```elisp
(defmacro hermes--with-copy (struct copier place &rest body)
  `(let ((,place (,copier ,struct)))   ;; shallow copy via cl-defstruct copier
     ,@body
     ,place))
```

The copier created by `cl-defstruct` uses `copy-sequence`, which is **shallow**.
A copied `hermes-state` struct shares the same `session-info`, `stream`,
`queue` objects as the original.  The reducer replaces specific slots
via `setf` to break sharing before returning.

**Note:** `messages` was removed in the buffer-as-truth refactor. The only
vectors now are `pending-turns` (drained immediately by the renderer) and
`history` (minibuffer recall ring).

#### `hermes--vector-append` = always new vector

```elisp
(defun hermes--vector-append (vec elt)
  (vconcat vec (vector elt)))
```

`vconcat` always returns a **new** vector.  Safe for `eq` comparison.

#### When `eq` comparison works correctly

In `hermes--stream-update`, the renderer compares old and new stream via `eq`.
If only `reasoning.delta` arrives (which copies the stream but leaves `segments`
unchanged), the segments vector is shared — `eq` returns `t` → no re-render.
For `message.delta` or `tool.generating`, a new vector is created → `eq` fails
→ re-render proceeds.  This is correct behaviour.

#### Dispatch ≠ render

Seeing `dispatch: "tool.generating"` in logs does **not** mean the reducer
produced a new state.  Always check if a render follows.  If it doesn't, the
reducer returned `state` unchanged — either because an early `if` guard returned
`state` (`null str`, `null tid`, etc.) or the `pcase` fell through to the
default clause.

### 13.2 `tool_id` Fallback

The gateway does **not** always emit `tool_id` in tool events.  Observed
`tool.generating` payload: `{"name": "terminal"}` — no `"tool_id"` key.

All three tool reducers (`tool.generating`, `tool.start`, `tool.complete`) fall
back through `id` and `name`:

```elisp
(tid (or (hermes--get p "tool_id")
         (hermes--get p "id")
         (hermes--get p "name")))
```

`tool.progress` lives only in the UI reducer and uses the same fallback
pattern.

### 13.3 Org Integration Guards

All `org-*` calls are guarded with `(derived-mode-p 'org-mode)` to prevent
crashes in non-Org buffers (e.g. test buffers in `fundamental-mode`):

| Location | Call | Guard |
|----------|------|-------|
| `hermes--insert-turn-headline` | `org-id-get-create` | `(derived-mode-p 'org-mode)` + `ignore-errors` |
| `hermes--stream-begin` | `org-id-get-create` | `(derived-mode-p 'org-mode)` + `ignore-errors` |
| `hermes--stream-commit` | `org-id-get-create` | `(derived-mode-p 'org-mode)` + `ignore-errors` |
| `hermes--render` (post-pass) | `org-element-cache-reset` | `(derived-mode-p 'org-mode)` |

Additional guards:
- `(hash-table-p info)` before `(gethash "model" info)` — `session-info` can be nil before `session.info` arrives
- `org-hide-leading-stars` and `org-startup-folded` set buffer-locally in `hermes-mode` init

#### `with-silent-modifications` and post-passes

All buffer edits run inside `with-silent-modifications`, which suppresses
`after-change-functions`. This breaks `org-indent-mode` and `org-fold-core`
because they rely on those hooks to update text properties and fold boundaries.

The fix is a two-phase architecture:

1. **Silent phase:** Batch all mutations without hooks.
2. **Post phase:** After exiting the silent block, reset the org-element cache
   and run targeted repairs (`org-indent-add-properties`, `org-fold-region`,
   `hermes--hide-drawers`) only on the regions that actually changed:
   - `msg-append-start` → `point-max` for newly committed turns
   - `hermes--bench-start` → `hermes--bench-end` for the live stream region

This keeps streaming fast (no per-tick hook overhead) while preserving correct
indentation and fold boundaries.

### 13.4 Stream Throttle Lifecycle

The adaptive throttle is stateful and must be carefully managed across buffer lifecycles:

| Event | Action |
|-------|--------|
| `stream-begin` | Cancels any pending timer (defensive), paints immediately |
| First delta after idle gap | Paints inline + arms timer with adaptive interval |
| Deltas during cooldown | Stash snapshot in `hermes--stream-render-pending`; do not paint |
| Timer fires (`hermes--stream-flush`) | Paints pending snapshot, re-arms timer with new adaptive interval |
| `stream-commit` | Flushes any pending snapshot synchronously, then cancels timer |
| `hermes-minor-mode--off` | Cancels timer, clears accumulator |
| Buffer kill | `kill-buffer-hook` calls `hermes--stream-flush-cancel` |

**Key invariant:** The timer callback checks `(buffer-live-p buf)` and that the pending snapshot still matches the live stream state before painting. If a newer delta has already arrived and started a fresh timer, the stale callback is a no-op.

### 13.5 Debugging Lessons

1. **Inspect actual payload keys**: The gateway may send different field names
   than documented.  Use `(maphash (lambda (k _) (message "key: %s" k)) p)` to
   dump hash-table payload keys.

2. **`delete-region` + `t` insertion-type = danger**: Any insert at `point-max`
   causes `t`-type markers to follow.  Prefer character-counted operations
   (`delete-char`, `insert`) when markers guard regions that should not grow.

3. **`.elc` shadowing**: `eldev compile` produces `.elc` files.  If Emacs loads
   from `load-path` (via `require`) instead of `load-file`, it may load stale
   `.elc`.  Delete `.elc` files before debugging, or use `load-file` on the
   `.el` directly.

4. **All subagent events are no-ops without a stream**: Same pattern as tool
   events — every `subagent.*` event returns `state` unchanged if
   `(hermes-state-stream state)` is nil.

5. **Tool context rendering**: The `:CONTEXT:` drawer only appears while the
   tool is `running`.  Once complete, the tool block shows output/error
   instead.  The context is not preserved in committed messages.

---

*Merged from archived references (2026-05-12 through 2026-05-14).*
