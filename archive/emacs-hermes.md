# Emacs ↔ Hermes TUI: Design Notes

## Overview

Hermes is an autonomous AI agent framework (Python) with a replaceable TUI layer.
The TUI communicates with the Python backend via **newline-delimited JSON-RPC 2.0 over stdio**.

## Integration Approaches

### Approach 1: Emacs as a Custom TUI (focus)

Emacs spawns `python -m tui_gateway.entry` and speaks JSON-RPC directly.

- Full agent control: conversation, tools, approvals, sessions
- Emacs built-in `json-encode` / `json-parse-string` for JSON
- Emacs built-in `make-process` / `process-send-string` / filter functions for stdio
- No external library needed for JSON-RPC client
- ~100 lines of glue; the real work is the UI

### Approach 2: Hermes as MCP Server

Hermes runs `hermes mcp serve`, exposes messaging tools.
Emacs MCP (already installed) consumes them.
**Problem**: only messaging, not the full agent loop.

### Approach 3: Hermes as ACP Server

Hermes runs `hermes acp`, exposes editor-oriented toolset.
**Problem**: no Emacs ACP client exists.

---

## Architecture: Elm-style Reducer

### State (model)

A single plist/alist representing everything:

- `connection` — disconnected | connecting | connected
- `session-id` — current session UUID
- `messages` — vector of complete messages (user + assistant)
- `stream` — current partial response text
- `active-tools` — vector of currently running tool entries
- `pending-approval` — nil or approval request plist
- `pending-clarify` — nil or clarify request plist
- `pending-secret` — nil or secret request plist
- `slash-commands` — cached catalog of available /commands
- `queue` — queued user inputs (drained after each assistant turn)

### Messages (Msg)

Every event and user action is a tagged plist `(type . <keyword>)`:

**Incoming (from gateway stdout filter):**

| Event | Key payloads |
|-------|-------------|
| `gateway.ready` | skin data |
| `session.info` | session-id, metadata |
| `message.start` | — |
| `message.delta` | text (incremental) |
| `message.complete` | text, rendered, usage |
| `thinking.delta` | text |
| `reasoning.delta` | text |
| `status.update` | kind, text |
| `tool.start` | name, tool_id, todos |
| `tool.progress` | name, preview |
| `tool.complete` | name, tool_id, summary, duration_s, error |
| `clarify.request` | request_id, question, choices |
| `approval.request` | request_id, command, description |
| `sudo.request` | request_id |
| `secret.request` | request_id, env_var, prompt |
| `gateway.stderr` | line |
| `gateway.protocol_error` | preview |

**Outgoing (user commands):**

| Action | Payload |
|--------|---------|
| `user-input` | text |
| `approval-respond` | allow (t/nil) |
| `clarify-respond` | choice (index) |
| `secret-respond` | value |
| `sudo-respond` | password |
| `slash-exec` | command, args |
| `session-create` | — |
| `session-resume` | session-id |

### Update (reducer)

A single `hermes-tui--reduce(state, msg) → new-state` function.
Pcase dispatches on `(alist-get 'type msg)`.

### Render

A `hermes-tui--render(old, new)` function that diffs old vs new state and
applies minimal changes to the Org buffer(s).

---

## Conversation Buffer: Org-mode

The conversation lives in an Org buffer. This gives:

- **Foldable tool blocks** — each tool call is an Org subtree or drawer,
  collapsible for free
- **Sections per message** — `* user`, `* assistant` headlines
- **Inline code blocks** — `#+begin_src` for code in tool results
- **Properties drawer** — store metadata (tool_id, duration, etc.)
- **Stable/incremental streaming** — keep rendered messages as completed
  subtrees; the in-progress stream lives in a dedicated drawer or temp
  headline that gets rewritten on each `message.delta`

### Streaming rendering strategy

Split incoming text at last stable block boundary:

- **Stable prefix** → rendered as Org content, never re-parsed
- **Unstable suffix** → the in-flight block, replaced on each delta

(This mirrors the official TUI's `StreamingMd` component strategy.)

### Tool rendering

Tool calls display inline as foldable Org subtrees:

```org
** assistant says...
:PROPERTIES:
:tool_id: 0
:END:
**** bash (2.3s)
:RESULTS:
$ ls -la
total 42
...
:END
next paragraph of assistant text...
**** read (0.1s)
:RESULTS:
...file content...
:END
```

Display modes (like official TUI's ToolTrail):
- `hidden` — don't show
- `collapsed` — show summary line only
- `expanded` — fully open (default)

---

## User Input Mechanics

| Behavior | Detail |
|----------|--------|
| Queue while busy | Text entered while agent runs is queued, not sent |
| Slash commands | Execute immediately, never queued |
| Auto-drain | Queue drains after each assistant response |
| Blocking prompts | `clarify.request`, `approval.request`, etc. suspend input |
| History | Up/Down cycle through history when queue is empty |

---

## Parallel Sessions

Elm architecture makes this straightforward: each session is a separate
state atom + Org buffer pair. The process filter dispatches events to the
correct state atom based on `session-id`.

Open questions:
- How to switch between session buffers?
- Tab-style UI or separate windows/frames?

---

## Open Questions / Tradeoffs

1. **Streaming rendering frequency**
   Render on every `message.delta` (jumpy but responsive) or batch with a
   timer (smoother but laggy)? Official TUI renders every delta with
   memoized stable prefix.

2. **Tool folding UX**
   Inline in conversation (like official TUI) or separate tool output
   buffer? Inline as Org subtrees seems natural.

3. **Markdown in Org**
   The gateway sends rendered HTML/markdown. How to best display that in
   Org? Convert to Org syntax? Use `#+begin_export` blocks?

4. **Multiple sessions UI**
   Tabs? Separate windows? Single buffer with section per session?

5. **Gateway lifecycle**
   One gateway process shared across sessions, or one per session?
   Official TUI uses one shared gateway.

6. **Initial state / config loading**
   Load config from `~/.hermes/config.yaml` or let the gateway provide it?

7. **Approval flow UX**
   Official TUI uses modal prompts. In Emacs: minibuffer, transient menu,
   or inline editable region?

8. **Interrupt handling**
   Hermes supports Ctrl-C to cancel. How to surface that in Emacs?
