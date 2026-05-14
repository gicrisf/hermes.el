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
A copied `hermes-state` struct shares the same `session-info`, `messages`,
`stream`, `queue` objects as the original.  The reducer replaces specific slots
via `setf` to break sharing before returning.

#### `hermes--vector-append` = always new vector

```elisp
(defun hermes--vector-append (vec elt)
  (vconcat vec (vector elt)))
```

`vconcat` always returns a **new** vector.  Safe for `eq` comparison.

#### When `eq` comparison works correctly

In `hermes--stream-update`, the renderer compares old and new stream via `eq`.
If only `thinking.delta` arrives (which copies the stream but leaves `segments`
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
| `hermes--render` (end) | `org-element-cache-reset` | `(derived-mode-p 'org-mode)` |

Additional guards:
- `(hash-table-p info)` before `(gethash "model" info)` — `session-info` can be nil before `session.info` arrives
- `org-hide-leading-stars` and `org-startup-folded` set buffer-locally in `hermes-mode` init

### 13.4 Debugging Lessons

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
