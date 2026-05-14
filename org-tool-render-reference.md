# Hermes Org & Tool Rendering — Technical Reference

Last updated from a debugging session on 2026-05-14.  Covers findings,
root causes, and fixes applied to `hermes-render.el` and `hermes-state.el`.

---

## 1. Buffer Structure (as of 2026-05-14)

```
#+TITLE: hermes

* user: Hello, what is 2+2?                             :hermes:
:PROPERTIES:
:HERMES_SESSION: a1b2c3d4
:HERMES_MODEL: nvidia/nemotron-3
:HERMES_TIMESTAMP: 2026-05-14T03:50:00+0200
:ID: abc12345
:END:
Hello, what is 2+2?

** assistant                                            :hermes:
:PROPERTIES:
:HERMES_TIMESTAMP: 2026-05-14T03:50:05+0200
:ID: def67890
:END:
Sure, 2+2 is 4.
*** terminal (3.2s)                                    :hermes-tool:
:PROPERTIES:
:tool_id: terminal
:status: complete
:END:
#+begin_example
uptime output
#+end_example

* system: Gateway lost                                   :hermes:
:PROPERTIES:
:HERMES_SESSION: a1b2c3d4
:HERMES_MODEL: nvidia/nemotron-3
:HERMES_TIMESTAMP: 2026-05-14T03:55:00+0200
:ID: ghi90123
:END:
Gateway lost — reconnecting...
```

### Heading conventions

| Level | Who | First line in heading |
|-------|-----|-----------------------|
| `*` | user, system | First line of message text (truncated at `\n`) |
| `**` | assistant | Static `** assistant` (no truncation, for simplicity) |
| `***` | tool | `toolname (status)` |

### Property drawer rules

| Heading | `HERMES_SESSION` | `HERMES_MODEL` | `HERMES_TIMESTAMP` | `:ID:` |
|---------|:---:|:---:|:---:|:---:|
| `* user` | yes | yes (from state at submit time) | yes | yes |
| `** assistant` | no | no | yes | yes |
| `*** tool` | no (inherits from parent) | no | no | yes (via `org-id-get-create`) |
| `* system` | yes | yes | yes | yes |

### Tags

- `:hermes:` on every `* user`, `** assistant`, `* system` heading
- `:hermes-tool:` on every `*** tool` heading
- `:hermes:` tags padded to column 80 for visual alignment

### File-level metadata

`#+TITLE: hermes` inserted at `point-min` during `hermes-mode` init.
No root heading — properties live per-turn, not per-buffer.

---

## 2. Streaming Region Markers

Six buffer-local variables govern the in-flight assistant message:

```
hermes--stream-headline-marker   → start of `** assistant` heading
hermes--stream-content-start     → position right after `:END:\n` of assistant's property drawer
                                    (stream body text begins here)
hermes--stream-stable-end        → boundary between stable & unstable stream text (nil insertion-type)
hermes--stream-end               → end of all stream text (t insertion-type; does NOT cover tool subtrees)
hermes--stream-tool-markers      → alist of tool-id → marker for each tool's headline
hermes--ui-line                  → right-hand status text in header line
```

### Why `hermes--stream-content-start` exists

The `already` offset in `hermes--rewrite-stream` must not count the assistant's
property drawer as stream text.  Before this marker was introduced, `already`
was computed from the end of the heading line, which included the drawer bytes
(~66 chars).  The first delta arrived with `stable=""` and `already≈66`,
producing `(substring "" 66)` → **Args out of range**.

`content-start` is set right after the `:END:\n` of the property drawer in
`hermes--stream-begin` (and also in test setup).

---

## 3. How `hermes--rewrite-stream` avoids deleting tools

**Problem (old code)**: `delete-region(stable-end, stream-end)` wipes everything
between the markers.  Tool subtrees (inserted at `point-max` via
`hermes--render-stream-tools`) sit beyond `stream-end` only if the marker hasn't
drifted.  But `stream-end` has `t` insertion-type, so tool insertions advance it.
The next `delete-region` then deletes the tools.

**Fix**: replaced `delete-region` with character-counted deletion:

```elisp
;; old
(delete-region hermes--stream-stable-end hermes--stream-end)
(goto-char hermes--stream-stable-end)
(insert unstable)

;; new
(let ((old-unstable-len
       (- (marker-position hermes--stream-end)
          (marker-position hermes--stream-stable-end))))
  ...
  (goto-char hermes--stream-stable-end)
  (delete-char old-unstable-len)
  (insert unstable))
```

`delete-char N` removes exactly N characters forward from point.  Tools that
sit beyond those N characters (because they were inserted at `point-max` after
the old unstable text) are untouched.  No marker save/restore needed.

---

## 4. Gateway Payload Structure (discovered via debugging)

### Tool events are sent WITHOUT `tool_id`

Actual `tool.generating` payload from the gateway:

```
{"name": "terminal"}
```

Only `"name"` is present — **no `"tool_id"` key**.  The same applies to
`tool.complete` and `tool.progress`.

The events registry in `hermes-events.el` documents `{name, tool_id}` but this
is aspirational, not reality.

### Unhandled event types

The gateway also emits events NOT in the reducer's `pcase`:

- `"tool.start"` — informational, reducer has no handler → returns `state` unchanged
- `"reasoning.available"` — informational, reducer has no handler → returns `state` unchanged

These are harmless: unhandled events return the old state via the default
`pcase` clause, so `(eq old new)` → t → hooks don't fire.  No side effects.

### Core event flow

```
gateway JSON → RPC process filter → hermes--route-event
  → hermes-dispatch (persistent state)
  → hermes-ui-dispatch (ephemeral state)
  → hooks fire (hermes--render, hermes--render-ui, etc.)
```

Hooks only fire when `(not (eq old new))` — i.e., when the reducer produces a
new state object.

---

## 5. Reducer Copy Semantics (critical for `eq` guards)

### `hermes--with-copy` = shallow copy

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

### `hermes--vector-append` = always new vector

```elisp
(defun hermes--vector-append (vec elt)
  (vconcat vec (vector elt)))
```

`vconcat` always returns a **new** vector.  Safe for `eq` comparison.

### When `eq` comparison on tools fails silently

In `hermes--stream-update`:

```elisp
(unless (eq old-tools new-tools)
  (hermes--render-stream-tools old-tools new-tools))
```

If `old-tools` and `new-tools` are the **same vector object** (shared via
shallow copy), `eq` returns `t` and `hermes--render-stream-tools` is never
called.  This happens after `thinking.delta` updates (which copy the stream
but don't touch tools — the tools vector is shared between old and new stream).
This is correct behaviour (tools haven't changed).  For `tool.generating`,
`hermes--vector-append` creates a new vector, so `eq` → nil → render proceeds.

---

## 6. tool_id Fallback Fix

Since the gateway doesn't emit `tool_id`, all three tool reducers now fall back:

```elisp
(tid (or (hermes--get p "tool_id")
         (hermes--get p "id")
         (hermes--get p "name")))
```

Applied in:
- `hermes-state.el`: `tool.generating` reducer (line ~255)
- `hermes-state.el`: `tool.complete` reducer (line ~275)

`tool.progress` lives only in the UI reducer (ephemeral state) and also uses
the same fallback pattern implicitly via the UI dispatch.

---

## 7. Org Integration Guards

### `(derived-mode-p 'org-mode)` before all `org-*` calls

Five `org-id-get-create` call sites are guarded:

| Location | What | Guard? |
|----------|------|--------|
| `hermes--insert-turn-headline` | stamp `:ID:` on user/system heading | `(derived-mode-p 'org-mode)` |
| `hermes--stream-begin` | stamp `:ID:` on assistant heading | `(derived-mode-p 'org-mode)` |
| `hermes--stream-commit` (tools) | stamp `:ID:` on tool subtrees | `(derived-mode-p 'org-mode)` |
| `hermes--stream-commit` (assistant) | stamp `:ID:` on assistant headline | `(derived-mode-p 'org-mode)` |
| `hermes--render` (end) | `org-element-cache-reset` | `(derived-mode-p 'org-mode)` |

All are wrapped in `ignore-errors` for additional safety.  Without these guards,
tests in `fundamental-mode` buffers produced
`org-element-at-point cannot be used in non-Org buffer` warnings (5 per
`org-id-get-create` call due to internal Org implementation details).

### `(hash-table-p info)` guard for nil session-info

`hermes--insert-turn-headline` reads `(gethash "model" info)` where `info` may
be nil before `session.info` arrives.  Guarded:

```elisp
(model (and (hash-table-p info) (gethash "model" info)))
```

### `org-hide-leading-stars t` and `org-startup-folded nil`

Set buffer-locally in `hermes-mode` init for cleaner Org appearance.

---

## 8. Known Unhandled Gateway Events

| Event | Handler | Effect |
|-------|---------|--------|
| `"tool.start"` | none | Returns `state` unchanged (no-op render) |
| `"reasoning.available"` | none | Returns `state` unchanged (no-op render) |

These are informational events from the gateway's turn controller.
Adding handlers is optional — they don't currently affect render output.

---

## 9. Test Coverage

| File | Tests | Scope |
|------|-------|-------|
| `test/hermes-render-test.el` | 8 | Streaming render engine (boundaries, conversion, commit) |
| `test/hermes-md-test.el` | 16 | Markdown→Org conversion |
| `test/hermes-state-test.el` | 40 | Reducer purity and event handling |

Status: **64/64 green, zero warnings** as of 2026-05-14.

---

## 10. Debugging Lessons

* **Dispatch ≠ render**.  Seeing `dispatch: "tool.generating"` in logs does
  NOT mean the reducer produced a new state.  Always check if `[render:]`
  follows.  If it doesn't, the reducer returned `state` unchanged — either
  because an early `if` guard returned `state` (`null str`, `null tid`, etc.)
  or the `pcase` fell through to the default clause.

* **Use `hash-table-p` to dump payload keys**.  `(maphash (lambda (k _) ...) p)`
  reveals actual field names from the gateway, which may differ from the
  documented protocol.

* **`delete-region` + `t` insertion-type = danger**.  Any insert at `point-max`
  causes `t`-type markers to follow.  Prefer character-counted operations
  (`delete-char`, `insert`) when markers guard regions that should not grow.

* **`.elc` shadowing is real**.  `eldel compile` produces `.elc` files.  If
  Emacs loads from `load-path` (via `require`) instead of `load-file`, it may
  load the stale `.elc`.  Delete `.elc` files before debugging, or use
  `load-file` on the `.el` directly.

---

## 11. File Reference (as of 2026-05-14)

| File | Lines | Role |
|------|-------|------|
| `hermes-state.el` | 398 | State atoms, pure reducers, `hermes-dispatch` |
| `hermes-render.el` | ~410 | Diff-based Org buffer renderer, streaming, tools |
| `hermes-mode.el` | 225 | `org-mode`-derived major mode, event routing, entry points |
| `hermes-events.el` | 96 | Event/method name registry |
| `hermes-rpc.el` | 283 | JSON-RPC 2.0 transport over stdio |
| `hermes-input.el` | ~200 | Input queue, slash commands, history ring |
| `hermes-prompts.el` | 116 | Minibuffer prompt handlers |
| `hermes-compose.el` | 75 | Multi-line composer |
| `hermes-sessions.el` | 172 | Sessions sidebar |
| `hermes-skin.el` | 83 | Gateway skin → face-remap |
| `hermes-md.el` | 164 | Markdown→Org converter |
| `hermes-dashboard.el` | 345 | Vanilla Emacs dashboard |
| `doom-dashboard-hermes.el` | 442 | Standalone Doom-styled dashboard |
| `doom-hermes.el` | 46 | Doom Evil bindings + `SPC h` leader prefix |
| `doom-hermes-theme.el` | 130 | Hermes brand theme (gold/teal) |
