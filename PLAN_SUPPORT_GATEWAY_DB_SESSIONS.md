# Plan: Support Gateway DB Sessions as First-Class Citizens

## Context

The Hermes Emacs client (`hermes.el`) has historically treated the Org buffer as the sole
source of truth for conversation history. The gateway's SQLite database
(`~/.hermes/state.db`) was regarded as an opaque runtime cache for the official TUI,
not as a persistence layer the Emacs client should interact with.

This assumption is wrong for two reasons:

1. **Multi-client workflows.** Users run Hermes from multiple clients (TUI, CLI,
   Telegram, Emacs). The gateway DB is the only shared persistence layer on a
   single machine. Sessions created in the TUI are invisible to Emacs unless we
   query the DB.

2. **Cross-machine portability.** The Org buffer is portable when synced via
   git/Dropbox, but the DB is local per machine. A user who switches from laptop
   to server has no gateway sessions on the new machine. The Org file is their
   only artifact. However, if they *do* have a DB on the current machine (e.g.
   they used the TUI yesterday), they should be able to resume those sessions
   from Emacs.

The gateway exposes JSON-RPC methods for listing, resuming, branching, deleting,
and saving DB sessions. The Emacs client currently implements none of them.

## Problems

### Problem 1: DB sessions are invisible

The `hermes-sessions` sidebar only shows **live** sessions (buffers currently in
`hermes--session-buffers`). Sessions persisted in the gateway DB but not currently
loaded into Emacs are invisible. There is no way to discover or resume them.

### Problem 2: `session.resume` causes silent divergence

When a user reopens a saved `.org` file and runs `M-x hermes`, the stale
`:HERMES_SESSION:` property triggers `hermes--resume-heading-session`, which calls
`session.resume`. The gateway loads its DB history internally, but the Org buffer
is not updated. The first outgoing prompt then **prepends the Org history as a
seed** via `hermes--build-history-text`. The gateway now sees:

- DB history (everything up to the last TUI/CLI interaction)
- Plus Org history (possibly edited, possibly truncated to 30 turns)

This is duplication at best, conflicting signals at worst. The user has no idea
this is happening.

### Problem 3: No fork / branch workflow

The gateway supports `session.branch`, which copies a session's history into a
new session. This is useful for experimentation: "continue this conversation but
on a different model / with a different approach." The Emacs client has no access
to this feature.

### Problem 4: The `:history` parameter was a lie

`hermes-resume-buffer` (now renamed `hermes-load-org`) used to send a `:history`
parameter to `session.create`. The gateway ignores it. We removed the parameter,
but the conceptual confusion remains: users may think the gateway can be seeded
from Org, when in fact the only working mechanism is the history seed on first
prompt.

## Decisions

### Decision 1: Org is a snapshot, DB is live

The Org buffer is **a** source of truth, not **the only** source of truth. It is a
rich, editable, portable snapshot. The DB is the live shared cache. Both are
valid, and the user should be able to choose which to use.

When opening a stale Org heading, the user must be **prompted** to choose:

1. **Load from org** — fresh session, seed from buffer. Discards any DB turns
   that happened after the last save. This is the "snapshot" path.
2. **Resume from DB** — new buffer rendered from gateway history. The gateway
   has full context. The Org file is left untouched. This is the "live" path.
3. **Branch from DB** — new session branched from the DB session. Same as resume
   but with a new SID, preserving the original.

### Decision 2: No silent DB resume

`hermes--resume-heading-session` must **not** be called silently. The old behavior
(auto-resume from DB on stale heading) is removed. `M-x hermes` on a stale
heading always prompts. `hermes-input-send` on a stale heading also prompts
instead of auto-resuming.

### Decision 3: DB sessions get a minimal, lossy renderer

When resuming from DB, the gateway returns messages via `_history_to_messages`,
which pre-flattens the conversation into a **simplified display format**, not raw
OpenAI format:

- Assistant text → `{role: "assistant", text: "..."}`
- Each tool call → its own `{role: "tool", name: "...", context: "..."}` message
  where `context` is a summarized argument string (not full args)
- `tool_call_id` is **dropped** — no way to match tool calls to tool results
- Reasoning (`reasoning`, `reasoning_content`, `reasoning_details`) is **not
  surfaced** in the response at all
- No `:HERMES_TIMESTAMP:`, no `:HERMES_USAGE_*`, no subagents, no images

We render this to a **new** Org buffer with a minimal flat structure:

```org
* Hermes session :hermes:
:PROPERTIES:
:HERMES_SESSION: <sid>
:END:

** User
:PROPERTIES:
:HERMES_KIND: USER
:END:
<content>

** Assistant
:PROPERTIES:
:HERMES_KIND: ASSISTANT
:END:
<assistant text>

*** Tool (<name>)
:PROPERTIES:
:HERMES_KIND: TOOL
:TOOL_NAME: <name>
:END:
<context string>
```

This is **intentionally lossy**. The user must be aware that DB-resumed buffers:
- Lose reasoning traces
- Lose tool argument detail (only summary context string)
- Lose subagents, images, timestamps, usage counters
- Cannot round-trip perfectly back to the gateway

The rendered buffer is a valid `hermes-mode` buffer. The user can edit, save,
and later `hermes-load-org` from it to create a fresh session with the full
history seed. If the user wants perfect fidelity, they should use Org snapshots.

### Decision 4: Full gateway method parity

We add all verified missing gateway methods to `hermes-events.el` and implement
handlers:

| Method | Purpose | Verified |
|--------|---------|----------|
| `session.list` | List DB sessions (with `limit`, `cwd` filtering) | ✅ Yes |
| `session.branch` | Fork a session to a new SID | ✅ Yes (already in long-handlers) |
| `session.delete` | Delete a session from DB | ✅ Yes |
| `session.save` | Export session to JSON file | ✅ Yes |

`session.most_recent` is **not verified** — excluded from Phase 1. Can be added
later once confirmed.

`session.compress` is already registered as a long handler but has no UI planned.

### Decision 5: CWD-aware session listing

The `session.list` method accepts an optional `cwd` parameter that filters
sessions by their working directory. The Emacs client already detects the project
root via `hermes-project-detect-cwd` (used by `hermes--do-session-create`). We
expose this in the DB browser so users can toggle "show only sessions from this
project."

### Decision 6: No backward compatibility

Obsolete aliases, stale docstrings, and misleading feature names are removed, not
deprecated. `hermes-resume-buffer` was already renamed to `hermes-load-org` and
the alias removed. `hermes--resume-heading-session` will be refactored to support
the new prompt flow rather than silent auto-resume.

### Decision 7: Buffer naming consistency

All session buffers use the same naming convention: `*hermes:<sid>*`. There is no
special `*hermes-db:*` prefix. When `session.resume` returns a **new** SID, the
buffer uses the new SID. This avoids confusion about which session is active.

## Implementation Phases

### Phase 1: Register missing RPC methods (`hermes-events.el`)

Add to `hermes-rpc-methods`:

```elisp
"session.list"         ; {limit?, cwd?}              → [{id, title, preview, started_at, message_count, source}]
"session.branch"       ; {session_id, name?}         → {session_id, title, parent}
"session.delete"       ; {session_id}                → bool
"session.save"         ; {session_id}                → {file}
```

Note: `session.branch` is already in `hermes-rpc-long-handlers`. `session.most_recent`
is unverified — do not add yet.

### Phase 2: `hermes-sessions-db.el` — DB session browser

New file. A `tabulated-list-mode` buffer `*Hermes DB Sessions*`.

**Columns:** Title | Msgs | Source | Started

**Keymap:**

| Key | Action |
|-----|--------|
| `RET` | Pick session → prompt: Resume / Branch / Delete / Save |
| `r` | Resume to new buffer |
| `b` | Branch to new session + new buffer |
| `d` | Delete (with confirmation) |
| `s` | Save to JSON |
| `g` | Refresh list |
| `c` | Toggle CWD filter (show only sessions from current project) |
| `l` | Jump to live sessions sidebar (`hermes-sessions`) |
| `q` | Quit |

**Auto-refresh:** Hook into `hermes-rpc-event-functions` like
`hermes-sessions--refresh-if-open`.

**CWD filter:** When `c` is active, `session.list` is called with
`:cwd (hermes-project-detect-cwd)`. When inactive, no `:cwd` is sent.

**Browser cross-link:** The existing `*Hermes Sessions*` (live) sidebar gets a `d`
keybinding to jump to `*Hermes DB Sessions*`. This makes both lists discoverable.

### Phase 3: Minimal DB → Org renderer

Function: `hermes--render-db-messages-to-buffer(messages sid)`

Consumes the gateway's **pre-flattened display format** (not OpenAI format):

- `{role: "user", content: "..."}` → `** User` heading with body text
- `{role: "assistant", text: "..."}` → `** Assistant` heading with body text
- `{role: "tool", name: "...", context: "..."}` → `*** Tool (<name>)` child heading
  with body = context string
- Tool output is **not available** separately (no `tool_call_id` matching possible)
- Reasoning is **not available** (not surfaced by gateway)

**Output structure:**

```org
* Hermes session :hermes:
:PROPERTIES:
:HERMES_SESSION: <sid>
:END:

** User
:PROPERTIES:
:HERMES_KIND: USER
:END:
<content>

** Assistant
:PROPERTIES:
:HERMES_KIND: ASSISTANT
:END:
<assistant text>

*** Tool (<name>)
:PROPERTIES:
:HERMES_KIND: TOOL
:TOOL_NAME: <name>
:END:
<context string>
```

**What's omitted:**
- No `:HERMES_TIMESTAMP:` (not in gateway response)
- No `:HERMES_USAGE_*` properties (not in response)
- No subagents (not in response)
- No images (not in response)
- No reasoning headings (not surfaced)
- No `#+name:'d blocks, no tables (minimal flat structure)
- No `TOOL_ID` property (dropped by gateway)

The rendered buffer is a valid `hermes-mode` buffer. The user can edit, save,
and later `hermes-load-org` from it.

### Phase 4: `hermes-resume-from-db` command

Interactive command. Can be called:
- From the DB browser (`RET` or `r` on a session row)
- Directly with a SID argument

Steps:
1. Call `session.resume` with `:session_id old-sid`
2. On success, the response contains a **new** `session_id` (distinct from the
   resumed one). Extract this new SID.
3. Create `*hermes:<new-sid>*` buffer
4. Render messages from the response via Phase 3
5. Set `hermes-mode`, register session with the **new** SID
6. **Stamp `hermes--seeded-session-id`** with the new SID immediately (gateway has
   full history, no seed needed)
7. Show bench, ready to continue

Error handling: if `session.resume` fails (session deleted, DB wiped), show
message and fall back to `hermes-load-org` if an org file is available.

### Phase 5: `M-x hermes` and `hermes-input-send` stale heading prompt

When `hermes--resolve-session-target` returns `(sid . nil)` (stale heading with
no in-memory state), both `M-x hermes` and `hermes-input-send` present the same
prompt:

```
Session <sid> is stale. Choose:
[1] Load from org — fresh session, seed from buffer
[2] Resume from DB — new buffer with gateway history
[3] Branch from DB — new session branched from gateway history
```

Default is `[1]`. User selects with number key or arrow keys.

If `[1]`: call `hermes-load-org` (current buffer, fresh session, seed on first
prompt).

If `[2]`: call `hermes-resume-from-db` with the stale SID (new buffer).

If `[3]`: call `session.branch` with the stale SID, then render the branched
session to a new buffer (Phase 4 with new SID).

If the heading has no `:HERMES_SESSION:` property at all → current behavior
(create fresh session under heading, no prompt).

**Rationale:** Both entry points (`M-x hermes` and direct send) must prompt
because both can trigger a stale session resume. The old silent resume path in
`hermes-input-send` (line 361) is replaced by this prompt.

### Phase 6: Update `hermes-load-org`

Keep as-is (already fixed in a previous pass):
- No `:history` parameter to `session.create`
- History seed fires on first prompt via `hermes--build-history-text`
- Message: "hermes: loaded org as %s (%d turns parsed)"

### Phase 7: Update `hermes--resume-heading-session`

Refactor to support the new prompt flow. Instead of silently calling
`session.resume` and rebuilding state, it becomes an internal helper called from
the stale-heading prompt handler. It no longer auto-drains the pre-send queue;
that responsibility moves to the prompt handler.

### Phase 8: Documentation updates

- `AGENTS.md`: Update architecture description to reflect "Org snapshot + DB live"
duality. Remove stale `:HERMES_META:` references.
- `docs/14-architecture-reference.md`: Update save/load/resume section.
- `docs/16-integration-roadmap.md`: Mark DB session support as in-progress.

## Files to create

- `hermes-sessions-db.el` — DB session browser
- `PLAN_SUPPORT_GATEWAY_DB_SESSIONS.md` — this file

## Files to modify

- `hermes-events.el` — add missing RPC methods
- `hermes-mode.el` — stale heading prompt, refactor `hermes--resume-heading-session`
- `hermes-org.el` — refactor resume helpers
- `hermes-render.el` or inline — minimal DB→Org renderer
- `hermes-input.el` — stale heading prompt on send
- `hermes-sessions.el` — add `d` key to jump to DB browser
- `AGENTS.md` — architectural update
- `docs/14-architecture-reference.md` — resume section
- `docs/16-integration-roadmap.md` — debt / features

## Out of scope (future work)

- Full reverse renderer (tool args, subagents, images, reasoning from DB format) —
  blocked on gateway surfacing richer message format
- `session.most_recent` auto-resume — unverified, can be added later
- `session.compress` UI — not understood well enough
- Syncing DB across machines — not a Hermes feature, use your own sync

## Acceptance criteria

- [ ] `session.list` returns sessions and renders in `*Hermes DB Sessions*`
- [ ] `session.list` with `:cwd` filter works from the browser
- [ ] `hermes-resume-from-db` creates a new buffer with rendered DB history
- [ ] `session.resume` new SID is used for buffer name and registry
- [ ] `M-x hermes` on stale heading prompts user (load/resume/branch)
- [ ] `hermes-input-send` on stale heading prompts user (load/resume/branch)
- [ ] Resumed DB sessions do NOT fire history seed (stamped immediately)
- [ ] Branch creates new SID, renders to new buffer
- [ ] Delete requires confirmation
- [ ] Save exports to JSON
- [ ] All existing tests pass
- [ ] New tests for DB browser and renderer
