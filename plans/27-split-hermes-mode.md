# PLAN 27: Split `hermes-mode.el` into `hermes-org-minor-mode.el` and `hermes-session.el`

## Motivation

`hermes-mode.el` is 705 lines / 34 definitions spanning four concerns:
routing, org-minor-mode, session lifecycle, and commands.  Now that comint is
the primary viewer, the org-specific code and session-management code deserve
their own homes.

## New files

### `hermes-org-minor-mode.el` — the org add-on

Everything needed to turn an org buffer into a Hermes session buffer.

| Function | From | Deps |
|----------|------|------|
| `hermes-org-minor-mode-map` | mode.el:167 | `hermes-comint` (declare: `hermes-bench-focus`) |
| `hermes-org-minor-mode--on` | mode.el:190 | `hermes-state` (`hermes-state-init` removed in plan 24), `hermes-comint` (declare: `hermes-bench-ensure`), `hermes-org-render` (declare: rendering hooks) |
| `hermes-org-minor-mode--off` | mode.el:233 | none |
| `hermes-org-minor-mode` | mode.el:243 | above |
| `hermes--container-heading-in-buffer-p` | mode.el:147 | pure org |
| `hermes--ensure-container` | mode.el:153 | pure org |
| `hermes--create-session-under-heading` | mode.el:505 | `hermes-rpc` (declare: `hermes-rpc-live-p`, `hermes-rpc-start`, `hermes--request`), `hermes-state`, `hermes-org` (declare: `hermes--register-session`) |
| `hermes--org-detach` | mode.el:55 | `hermes-state` (declare: `hermes--sessions`, `hermes--org-buffers`, `hermes--session-markers`) |
| `hermes-reconnect` | mode.el:435 | `hermes-rpc`, `hermes-state`, `hermes-input` (declare: `hermes-input-fetch-catalog`) |
| `hermes-reload-from-org` | mode.el:603 | below |
| `hermes--buffer-message-count` | mode.el:568 | pure org |
| `hermes--parse-buffer-messages` | mode.el:585 | `hermes-state` (struct accessors) |

**`declare-function`s from other modules:**
- `hermes--install-hooks` ("hermes-mode")
- `hermes--route-event` ("hermes-mode") — used by reconnect
- `hermes-bench-ensure` ("hermes-comint")
- `hermes-bench-active-p` ("hermes-comint")
- `hermes-bench-focus` ("hermes-comint") — used in keymap
- `hermes--register-session` ("hermes-org")
- `hermes--prompts-watch` ("hermes-prompts")
- `hermes--input-drain` ("hermes-input")
- `hermes-input-fetch-catalog` ("hermes-input")
- `hermes--skin-watch` ("hermes-skin")

### `hermes-session.el` — session lifecycle and browsing

| Function | From | Deps |
|----------|------|------|
| `hermes--do-session-create` | mode.el:278 | `hermes-rpc`, `hermes-state`, `hermes-project` (declare: `hermes-project-detect-cwd`), `hermes-org` (declare: `hermes--register-session`), `hermes-input` (declare: `hermes-input-fetch-catalog`) |
| `hermes-new-session` | mode.el:319 | `hermes-rpc` (declare: `hermes-rpc-live-p`, `hermes-rpc-start`) |
| `hermes--live-session-buffers` | mode.el:337 | `hermes-state` (declare: `hermes--org-buffers`), `hermes-comint` (declare: `hermes-comint--buffers`) |
| `hermes--primary-session-buffer` | mode.el:348 | above |
| `hermes--lookup-buffer` | mode.el:48 | `hermes-state` (declare: `hermes--org-buffers`) |
| `hermes--focus-bench-input` | mode.el:425 | `hermes-comint` (declare: `hermes-bench-active-p`) |
| `hermes-bench-focus` | mode.el:255 | `hermes-comint` (declare: `hermes-bench-active-p`) |
| `hermes-interrupt-current-session` | mode.el:488 | `hermes-rpc` (declare: `hermes--request`) |
| `hermes-bg-list` | mode.el:694 | `hermes-state`, `hermes-comint` (declare: `hermes-comint-bench--apply-bg`) — or keep in `hermes-mode.el` |

**`declare-function`s from other modules:**
- `hermes--org-buffers` ("hermes-state")
- `hermes--session-markers` ("hermes-state")
- `hermes-comint--buffers` ("hermes-comint")
- `hermes-bench-active-p` ("hermes-comint")
- `hermes-input-fetch-catalog` ("hermes-input")
- `hermes-project-detect-cwd` ("hermes-project")
- `hermes--register-session` ("hermes-org")
- `hermes-rpc-live-p` / `hermes-rpc-start` / `hermes--request` ("hermes-rpc")
- `hermes--install-hooks` ("hermes-mode")
- `hermes--last-gateway-ready` ("hermes-mode") — for dispatching on session create

### `hermes-mode.el` — what stays (the thinner core)

| Function | Rationale |
|----------|-----------|
| `hermes` | entry point (simplified per plan 26) |
| `hermes--route-event` | core routing, dispatches to state |
| `hermes--route-connection` | core routing |
| `hermes--broadcast-dispatch` | core routing |
| `hermes--route-stderr` | routing |
| `hermes--route-protocol-error` | routing |
| `hermes--route-start-timeout` | routing |
| `hermes--install-hooks` | wiring RPC events to routing |
| `hermes--last-gateway-ready` | cached payload |
| `hermes-inspect-turn` | dev command |
| `hermes-debug-state` | dev command |
| `hermes--debug-state-pop` | dev helper |
| `hermes-view-log` | dev command |

~15 functions (down from ~34).  The file becomes the core dispatcher:
entry point, routing, and hook wiring.

### Dependency graph after split

```
hermes-rpc.el              (transporte)
hermes-state.el             (state atoms, hooks, hash tables)
hermes-comint.el            (comint viewer)
hermes-org-render.el        (org rendering)
hermes-org-minor-mode.el    (org minor mode, org parsing, reconnect)  ← NEW
hermes-session.el           (session lifecycle, browsing, commands)   ← NEW
hermes-mode.el              (entry point, routing, dev commands)      ← THINNER

hermes-mode.el → hermes-session.el → hermes-org-minor-mode.el
                                       → hermes-org-render.el
                                       → hermes-comint.el
                 → hermes-state.el
                 → hermes-rpc.el
```

No circular `require`s — `hermes-org-minor-mode.el` uses `declare-function`
for `hermes--install-hooks` and `hermes--route-event` (both from
`hermes-mode.el`), which are available at runtime since `hermes-mode.el`
is the entry point and always loaded first.

## Files touched

| File | Lines | Nature |
|------|-------|--------|
| `hermes-org-minor-mode.el` | ~280 new | Org minor mode, container helpers, org parsing, reconnect (11 funcs from hermes-mode.el) |
| `hermes-session.el` | ~200 new | Session lifecycle, browsing, bench focus, interrupt, bg-list (9 funcs from hermes-mode.el) |
| `hermes-mode.el` | ~350 remaining | Entry point, routing, install-hooks, dev commands (15 funcs, down from 34) |

## Callers to update

| Caller | Currently uses | Replace with |
|--------|---------------|--------------|
| `hermes-doom.el` line 57 | `hermes--primary-session-buffer` | unchanged (moved to hermes-session, declare-function updated) |
| `hermes-project.el` line 257 | `hermes--primary-session-buffer` | unchanged |
| `hermes-sessions.el` line 425 | `hermes--focus-bench-input` | unchanged |
| `hermes-image.el` (various) | `hermes--session-markers` | unchanged (already in hermes-state) |
| `hermes-input.el` line 35, `hermes-config.el` line 28 | various declare-functions | update file names in declare |

Most callers only need their `declare-function` file names updated —
the function names and signatures don't change.

## Not in scope

- Moving routing/dispatch (`hermes--route-event` etc.) to `hermes-state.el`
  or a new `hermes-routing.el`.  They stay in `hermes-mode.el` for now.
- Moving `hermes--install-hooks` — it's small (15 lines) and sits naturally
  beside the routing functions it wires.
- Splitting `hermes-comint.el` or `hermes-org-render.el`.
