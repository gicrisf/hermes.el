## 1. Architectural Model

### 1.1 Official TUI (Ink + Python)

```
┌─────────────┐     NDJSON-RPC      ┌──────────────────┐
│  Ink (Node) │ ◄──────stdio──────► │ tui_gateway      │
│  React UI   │                     │  (Python)        │
│             │ ◄──event notify──── │                  │
│  - renderer │ ──request id──────► │  - AIAgent       │
│  - state    │                     │  - session mgmt  │
│  - overlays │                     │  - tool dispatch │
└─────────────┘                     └──────────────────┘
```

- **Ink owns the screen.** Python owns sessions, tools, model calls, slash command logic.
- Frontend is **display-only**: it never executes tools, never blocks the agent loop, and never uploads results. It only renders events and responds to blocking prompts.
- Transport: newline-delimited JSON-RPC 2.0 over stdio.

### 1.2 Emacs Frontend

Same architecture, same role. Emacs replaces Ink as the display layer.

```
┌─────────────┐     NDJSON-RPC      ┌──────────────────┐
│ Emacs Lisp  │ ◄──────stdio──────► │ tui_gateway      │
│  hermes-mode│                     │  (Python)        │
│  Org buffer │                     │                  │
└─────────────┘                     └──────────────────┘
```

- `hermes-rpc.el` — transport (make-process, NDJSON, pending callback map)
- `hermes-state.el` — TEA-style reducer (persistent + ephemeral UI state)
- `hermes-render.el` — diff-based Org buffer renderer
- `hermes-mode.el` — major mode, event routing, entry points
- `hermes-comint.el` — comint-derived conversation viewer; also hosts the bench (`hermes-comint--bench-p = t` variant) displayed as a bottom side-window
- `hermes-prompts.el` — minibuffer handlers for blocking prompts
- `hermes-input.el` — input queue, slash commands, history

### 1.3 Integration Approaches

The Emacs frontend implements **Approach 1** from the original design:

| Approach | Description | Status |
|----------|-------------|--------|
| **1. Emacs as Custom TUI** | Emacs spawns `python -m tui_gateway.entry` and speaks JSON-RPC directly over stdio. Full agent control: conversation, tools, approvals, sessions | ✅ Implemented |
| **2. Hermes as MCP Server** | Hermes runs `hermes mcp serve`, exposes messaging tools. Emacs MCP client consumes them | ❌ Rejected — only messaging, not the full agent loop |
| **3. Hermes as ACP Server** | Hermes runs `hermes acp`, exposes editor-oriented toolset | ❌ Rejected — no Emacs ACP client exists |

### 1.4 Architecture: Elm-style Reducer

The Emacs frontend follows an Elm architecture pattern:

```
Event/action → dispatch → reducer → new state → render hook → Org buffer
```

- **State** — two buffer-local atoms: ephemeral `hermes-state` (connection, in-flight stream, queue, pending) + ephemeral `hermes-ui-state` (header-line text, spinner)
- **Canonical history** — two equivalent representations, interconvertible without loss:
  - **Event-canonical:** `hermes--sessions[sid].turns` — a vector of `hermes-message` structs accumulated by the reducer via `hermes--push-committed`. This is the TEA-style single source of truth, populated across three reducer paths (`:user-submit`, `"message.complete"`, `"error"`). The section view (`hermes-section`) is a pure projection of this vector; it has no awareness of org buffers.
  - **Body-canonical:** the Org buffer itself. Every committed turn heading carries `:HERMES_KIND:` (USER / ASSISTANT / SYSTEM) and `:HERMES_TIMESTAMP:` properties; assistant child headings (Response / Reasoning / Tool / Subagent) carry their own `:HERMES_KIND:` markers. Text content is parsed back from the visible buffer on resume. Usage counters are body-canonical in `HERMES_USAGE_*` heading properties; tool segments are body-canonical in `#+name:'d blocks and heading properties; subagents are body-canonical in child `HERMES_KIND: SUBAGENT` headings. Image references are body-canonical in `#+attr_*:` lines above `[[file:…]]` links.
- **Message (Msg)** — every event and user action is a tagged pair `(type . payload)` where `type` is a string (gateway event) or keyword (client action) and `payload` is a hash-table, alist, or plist
- **Update (reducer)** — pure `hermes--reduce(state, msg) → new-state`. Returns the same object (via `eq`) when nothing changes, so render hooks don't fire on no-ops. The reducer pushes committed turns into a `pending-turns` staging vector; the renderer drains them into the buffer.
- **View (render)** — `hermes--render(old, new)` diffs old vs new state and applies minimal changes to the Org buffer. Two render hooks: one for persistent state, one for ephemeral UI state

---
