# hermes.el — Architecture (Supplementary Reference)

> **Note:** This document is a comprehensive architecture dump from 2026-05-14,
> updated 2026-05-16 after the buffer-as-truth refactor. For current struct shapes
> see [03-state-shape-comparison.md](03-state-shape-comparison.md), for rendering
> see [08-message-stream-segmentation.md](08-message-stream-segmentation.md).

## Overview

hermes.el is an Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
It communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway` process.
The conversation buffer is a read-only `org-mode` derived buffer with hierarchical
headlines, property drawers, and Org IDs for cross-referencing.

---

## Data Flow

```
Gateway (Python subprocess)
    │
    │  NDJSON over stdio (jsonrpc=2.0, method="event")
    ▼
hermes-rpc.el  ──hermes-rpc-event-functions──►  hermes-mode.el: route-event
                                                      │
                                                      │  dispatch
                                                      ▼
                                              hermes-state.el: hermes-dispatch
                                                      │
                                                      │  pure reducer
                                                      ▼
                                               hermes--state (swap)
                                                       │
                                                       │  run-hook
                                                       ▼
                                                hermes--render (hermes-render.el)
                                                        │
                                                        ├─► diff & edit ──► Org buffer (*hermes:SID*)
                                                        │
                                                        └─► bench active? ──► hermes-bench--stream-update
                                                                    │
                                                                    │  rebuild ephemeral zones
                                                                    ▼
                                                            Bench buffer (*hermes-bench:SID*)

                   hermes-comint.el: hermes-comint--refresh
                                                       │
                                                       │  appends new turns / repaints streaming region
                                                       ▼
                                              Comint buffer (*hermes-comint:SID*)
```

**Comint view path:** The comint view (`hermes-comint.el`) attaches a separate renderer to `hermes-state-change-hook`. When a dispatch modifies `turns`, `hermes-comint--refresh` fires independently from the org renderer. It appends only new turns to the read-only output region above its inline `> ` prompt; the active stream is painted into a pending region between `output-end` and `prompt-start` and sealed on `message.complete`. It has no awareness of org buffers, `pending-turns`, or `hermes-org-minor-mode` — it is a pure projection of the state atom.

**Org view path:** The org renderer (`hermes-render.el`) drains `pending-turns` into the org buffer and renders the live stream segment-by-segment. The bench (`hermes-bench.el`) mirrors the latest turn's ephemeral zones (prompt, reasoning, answer, input).

Both viewers coexist: opening a comint view for an existing session does not affect the org buffer, and vice versa. The `turns` vector is the shared, sole authority.

**Output path:**

```
Emacs (user-input) → hermes-input.el → hermes-dispatch (:user-submit)
    → hermes-rpc.el (prompt.submit request) → Gateway (stdin)
```

---

## File Inventory

| File | Lines | Role |
|------|-------|------|
| `hermes-rpc.el` | 343 | JSON-RPC 2.0 transport (make-process, NDJSON, pending map) |
| `hermes-state.el` | 399 | Buffer-local state atoms + pure reducer |
| `hermes-render.el` | 409 | Diff-based Org buffer renderer |
| `hermes-mode.el` | 225 | org-mode derived major mode + event routing + entrypoint |
| `hermes-bench.el` | ~350 | Persistent bottom bench (major mode only): last-turn display + input |
| `hermes-input.el` | 209 | Input queue, slash commands, history |
| `hermes-prompts.el` | 116 | Minibuffer prompt handlers (approval, clarify, secret, sudo) |
| `hermes-compose.el` | 81 | Multi-line org-mode composer |
| `hermes-comint.el` | 802 | Comint-derived conversation viewer with inline prompt (pure `turns` projection, never reads org buffer; zero external deps) |
| `hermes-sessions.el` | ~420 | Minibuffer selectors (`hermes-current-sessions`, `hermes-stored-{resume,branch,delete,save}`); also hosts the DB→Org renderer and the resume/branch install path |
| `hermes-skin.el` | 83 | Gateway skin → face-remap |
| `hermes-md.el` | 164 | Markdown → Org syntax converter |
| `hermes-dashboard.el` | 393 | Vanilla Emacs dashboard (`*Hermes*`) |
| `hermes-events.el` | 97 | Event/method name registry |
| `doom-dashboard-hermes.el` | 442 | Standalone Doom-styled dashboard (`*doom-hermes*`) |
| `hermes-doom.el` | 66 | Doom `SPC h` leader prefix; pulls in Evil, Transient, Notifications |
| `hermes-evil.el` | 28 | Normal-state Evil C-c bindings (works in any Evil-equipped Emacs) |
| `hermes-doom-theme.el` | 161 | Hermes-branded dark theme |
| **Total** | **~3,853** | |

---

## Core State (`hermes-state.el`)

### Structs

```
hermes-state
├── connection        :: 'disconnected | 'connecting | 'connected
├── session-id        :: string or nil     (set by session.create response)
├── session-info      :: hash-table or nil (set by session.info event)
├── usage             :: hash-table or nil — accumulated tokens/cost
├── stream            :: hermes-stream or nil (in-flight only)
├── pending           :: hermes-pending or nil (blocking prompt)
├── pending-turns []  :: vector of hermes-message — drained into buffer by renderer
├── slash-catalog     :: from commands.catalog response
├── queue []          :: queued user submissions (when stream is live)
├── history []        :: input history (capped at hermes-history-max)
└── skin              :: from gateway.ready payload

hermes-message
├── kind      :: 'user | 'assistant | 'system
├── segments  :: vector of hermes-segment — committed turn narrative
├── usage     :: token usage
├── timestamp :: ISO-8601 string
└── subagents :: vector of hermes-subagent — delegation tree

hermes-stream
├── segments    :: vector of hermes-segment, ordered by arrival
├── tools       :: DEPRECATED — kept for backward compat
└── subagents   :: vector of hermes-subagent — live delegation tree

hermes-segment
├── type    :: 'text | 'thinking | 'reasoning | 'tool | 'system
├── content :: string (for text/thinking/reasoning/system) or hermes-tool
└── id      :: unique segment id (for stable updates)

hermes-tool
├── id          :: string (tool_id from gateway, or falls back to name)
├── name        :: string
├── status      :: 'generating | 'running | 'complete | 'error
├── context     :: tool args preview from tool.start — body-canonical
├── preview     :: live preview from tool.progress
├── inline-diff :: diff output from tool.complete — body-canonical
├── todos       :: list of hash-tables ("content" "status" "id") — body-canonical
├── output      :: string or nil — body-canonical
├── error       :: string or nil — body-canonical
└── duration    :: number or nil

hermes-subagent
├── id        :: string
├── goal      :: string
├── status    :: 'queued | 'running | 'complete | 'error
├── thinking  :: string
├── tools     :: vector of plists (:name :args :timestamp)
├── notes     :: vector of strings
├── summary   :: string
└── duration  :: number

hermes-pending
├── kind       :: 'approval | 'clarify | 'secret | 'sudo
├── request-id :: string
└── payload    :: hash-table
```

### Dispatch

```elisp
(defun hermes-dispatch (msg)
  "Reduce MSG into the persistent state and notify subscribers."
  (let* ((old hermes--state)
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (setq hermes--state new)
      (run-hook-with-args 'hermes-state-change-hook old new))))
```

Key property: state is only swapped when the reducer returns a structurally new value
(using `hermes--with-copy` which does a shallow copy of the struct). If the reducer
returns the same object, hooks don't fire and no re-render occurs.

### Reducer pattern

The reducer uses `pcase` on the event type. Most events follow the copy-and-setf pattern:

```elisp
(hermes--with-copy state hermes-state-copy s
  (setf (hermes-state-connection s) 'connected))
```

`hermes--with-copy` copies the struct and binds it to `s`, runs body for side effects,
returns the copy. All events return the copy (or `state` unchanged for no-ops).

---

## Transport (`hermes-rpc.el`)

Spawns `python -m tui_gateway.entry` via `make-process` with a process filter that
parses newline-delimited JSON-RPC 2.0 frames.

### Request flow

```
hermes-rpc-request (method, params, callback)
  │
  │  assign auto-incrementing id
  │  store (callback . method) in pending-map
  │
  ▼
send {"jsonrpc":"2.0","id":N,"method":"<method>","params":{...}}
  │
  │  response arrives:
  │    {"jsonrpc":"2.0","id":N,"result":{...}}
  │    or {"jsonrpc":"2.0","id":N,"error":{...}}
  │
  ▼
lookup id in pending-map → fire callback with (result error)
```

### Event flow

```
Gateway sends:
  {"jsonrpc":"2.0","method":"event",
   "params":{"type":"message.delta","session_id":"abc","payload":{...}}}
  │
  ▼
Process filter → parse JSON → dispatch to hermes-rpc-event-functions
  │
  ▼
hermes--route-event (hermes-mode.el):
  1. If gateway.ready/skin.changed: cache payload globally
  2. Lookup session buffer by session-id
  3. hermes-dispatch in that buffer's context
```

### Long handlers

Methods like `shell.exec`, `session.resume` are processed asynchronously by the
gateway's thread pool. Their responses can interleave with other frames. The pending
map handles this correctly because each request has a unique id.

---

## Rendering (`hermes-render.el`)

### Two hooks

```elisp
(add-hook 'hermes-state-change-hook    #'hermes--render        nil t)  ; persistent
(add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     nil t)  ; header line
```

The renderer compares old and new states (`eq` on each slot) and dispatches to
sub-renderers:

```elisp
(defun hermes--render (old new)
  (with-silent-modifications
    (save-excursion
      ;; 1. Drain pending-turns vector → append committed turns
      ;; 2. Stream lifecycle (begin / commit / update)
      ;; 3. Session info / connection → header line + root properties
      ;; 4. Queue length changed → refresh header-line
      ))
  ;; Post-passes: run *after* exiting with-silent-modifications so
  ;; org-element cache is valid and after-change-functions are not suppressed.
  (when (derived-mode-p 'org-mode)
    (org-element-cache-reset)
    (hermes--refresh-region msg-append-start (point-max))        ; committed tail
    (hermes--refresh-region bench-start bench-end)))             ; live bench
```

### Bench architecture

The **bench** is the live (in-flight) assistant turn region. Renderers mutate
inside the bench every stream tick; everything outside is frozen — never touched
after the previous turn committed. This means:

- The user's manual fold state above the bench survives forever.
- Post-passes scope their work to only the changed tail, not the whole buffer.

### `hermes--refresh-region` — post-pass repairs

These passes do the work that `after-change-functions` would have done were it
not suppressed by `with-silent-modifications`:

1. `org-fold-region` — reveals any stale outline fold that erroneously spans
   into the new region (e.g. a folded `*** Reasoning` from the previous turn
   swallowing a new `* user` headline onto its ellipsis line).
2. `org-indent-add-properties` — attaches `line-prefix` / `wrap-prefix` text
   properties so new sub-headlines get correct virtual indentation.
3. `hermes--hide-drawers` — collapses `:PROPERTIES:` drawers with plain overlays.

### Body-canonical structured data

All structured data is body-canonical in the visible Org buffer — no hidden drawers:

- **Usage counters** → `HERMES_USAGE_*` properties on turn headings
- **Image metadata** → `#+attr_org:` / `#+attr_hermes:` lines above `[[file:…]]` links
- **Tool fields** → `#+name: hermes-tool-<id>-{output,context,inline-diff,error}` blocks;
  `TOOL_STATUS`, `TOOL_NAME`, `TOOL_DURATION`, `TOOL_SUMMARY` heading properties
- **Subagents** → child `HERMES_KIND: SUBAGENT` headings
- **Timestamps** → `:HERMES_TIMESTAMP:` heading properties

Text-only turns have no extra structure. Everything is parsed back from the
visible buffer on resume, so user edits are preserved.

---

## Major Mode (`hermes-mode.el`)

```elisp
(define-derived-mode hermes-mode org-mode "Hermes"
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq buffer-read-only t)
  (hermes-state-init)
  (insert "#+TITLE: hermes\n")
  ;; Register hooks...
  )
```

### Event routing

```elisp
hermes--install-hooks
  ├── hermes-rpc-event-functions   → hermes--route-event
  ├── hermes-rpc-event-functions   → hermes-sessions--refresh-if-open
  ├── hermes-rpc-connection-functions → hermes--route-connection
  └── hermes-rpc-connection-functions → hermes-sessions--refresh-if-open
```

`hermes--route-event` dispatches events into the correct session buffer:
- If `session-id` is known → dispatch in that buffer via `with-current-buffer`
- If `session-id` is nil (gateway.ready, skin.changed) → broadcast to all buffers

### Entry point

```
M-x hermes → hermes → hermes-new-session
  1. Start gateway if not running (hermes-rpc-connect)
  2. Send session.create request
  3. On success: generate-new-buffer "*hermes:SID*"
  4. Activate hermes-mode in that buffer
  5. Replay last-gateway-ready event
  6. Pop dashboard
  ```

---

## Input Pipeline (`hermes-input.el` + `hermes-prompts.el`)

### `hermes-send`

```
C-c C-i → hermes-send → hermes-send (hermes-input.el)
  │
  │  Read input via read-string (with history and slash-completion)
  │
  ├── Input starts with "/" → hermes-input-dispatch-slash
  │     → slash.exec RPC (bypasses queue, transcript, history)
  │
  └── Normal input → hermes-dispatch :user-submit
        │
        ├── Optimistic commit to messages
        ├── Push onto history ring
        │
         ├── Stream is idle → commit to buffer + hermes-rpc-request "prompt.submit"
         │
         └── Stream is busy → enqueue silently (no buffer display yet); drain hook
               fires on message.complete: dequeue → commit to buffer → send RPC
```

### Blocking prompts

`hermes-prompts.el` watches `hermes-state-pending` via a change hook.
When pending becomes non-nil, it schedules a minibuffer interaction
(via `run-at-time` 0 — after the renderer finishes), dispatches the
matching `.respond` RPC, and clears the pending slot.

Events handled: `approval.request`, `clarify.request`, `sudo.request`,
`secret.request`.

---

## Multi-line Composer (`hermes-compose.el`)

`C-c C-l` opens a `*hermes-compose*` buffer in `org-mode`.
Keybindings:
- `C-c C-c` → send content through `hermes-send`, kill buffer
- `C-c C-k` → kill buffer (cancel)

The composer is a clean org-mode buffer (not hermes-mode derived) to avoid
polluting the conversation buffer's state.

---

## Session selectors (`hermes-sessions.el`)

All session management is minibuffer-driven — no dedicated buffers, no
tabulated-list modes.  Each command runs a `completing-read` with
`:annotation-function` metadata, so vertico/marginalia/consult users get
rich annotations for free and vanilla `completing-read` users still see
inline metadata.

| Command | Picks from | Action |
|---------|------------|--------|
| `hermes-current-sessions` | `hermes--session-buffers` (live) | switch to selected buffer |
| `hermes-stored-resume` | `session.list` (gateway DB) | `hermes-resume-from-db` |
| `hermes-stored-branch` | `session.list` | `hermes-branch-from-db` |
| `hermes-stored-delete` | `session.list` | `session.delete` (confirm) |
| `hermes-stored-export-as-json` | `session.list` | `session.save` (JSON export) |

The `hermes-stored-*` commands accept a prefix argument to restrict the
candidate list to the current project's CWD (`hermes-project-detect-cwd`).
Annotations show: model / status / msg count / project for live rows,
title / source / msg count / started-time for stored rows.

---

## Markdown→Org (`hermes-md.el`)

Applied to stable chunks and the unstable tail on commit.

Pipeline:
1. Fenced code blocks (```````` → `#+begin_src` / `#+begin_example`)
2. Table separators (`|---|---|` → `|---+---|`)
3. ATX headings (`# text` → `** text`, demoted)
4. Inline: `**bold**` → `*bold*`
5. Inline: `` `code` `` → `~code~`
6. Inline: `[label](url)` → `[[url][label]]`
7. Inline: `*italic*` / `_italic_` → `/italic/`

Protected regions prevent nested passes from corrupting fenced code bodies.

---

## Skin Engine (`hermes-skin.el`)

The gateway emits a `skin` payload on `gateway.ready` (and `skin.changed`)
with a `colors` hash. The skin module remaps buffer-local faces to these
colors:

```elisp
hermes-user-face      → user headline
hermes-assistant-face → assistant headline
hermes-system-face    → system headline
hermes-tool-face      → tool headline
```

---

## Dashboard (`hermes-dashboard.el`)

The vanilla dashboard (`*Hermes*`) is a `special-mode` buffer shown by
`M-x hermes`. Sections:
1. Unicode "HERMES" block-art logo with connection status
2. Session information (model, session ID, tools/skills)
3. Action menu (send, compose, sessions, refresh, quit)

### Doom Dashboard (`doom-dashboard-hermes.el`)

Standalone alternative (`*doom-hermes*`), Doom-styled. Centering via
window margins + vertical pad. Debounced refresh (0.1s idle timer).
Clickable menu with auto-detected keybindings. Independent faces
inheriting from font-lock faces.

---

## Org Buffer Structure

### Final hierarchy after each turn (v2 format)

\```
#+TITLE: hermes

** U: what is 2+2?
:PROPERTIES:
:HERMES_KIND:     USER
:HERMES_SESSION:  a1b2c3d4
:HERMES_MODEL:    nvidia/nemotron-3
:HERMES_TIMESTAMP: 2026-05-14T03:56:12+0200
:ID:              abc123
:END:
what is 2+2?

** A: Sure, 2+2 is 4.
:PROPERTIES:
:HERMES_KIND:     ASSISTANT
:HERMES_SESSION:  a1b2c3d4
:HERMES_MODEL:    nvidia/nemotron-3
:HERMES_TIMESTAMP: 2026-05-14T03:56:12+0200
:HERMES_USAGE_TOKENS_SENT: 1450
:HERMES_USAGE_TOKENS_RECEIVED: 892
:ID:              def456
:END:
*** Response
:PROPERTIES:
:HERMES_KIND: RESPONSE
:END:
Sure, 2+2 is 4.

*** DONE calculator (0.3s)
:PROPERTIES:
:HERMES_KIND: TOOL
:TOOL_ID:     calc-01
:TOOL_NAME:   calculator
:TOOL_STATUS: complete
:TOOL_DURATION: 0.3
:END:
#+name: hermes-tool-calc-01-output
#+begin_example
4
#+end_example

** U: now 3+3?
:PROPERTIES:
:HERMES_KIND:     USER
:HERMES_SESSION:  a1b2c3d4
:HERMES_MODEL:    openai/gpt-4o       ← model changed
:HERMES_TIMESTAMP: 2026-05-14T03:57:00+0200
:ID:              ghi789
:END:
now 3+3?

** A: It's 6.
:PROPERTIES:
:HERMES_KIND:     ASSISTANT
:HERMES_SESSION:  a1b2c3d4
:HERMES_MODEL:    openai/gpt-4o
:HERMES_TIMESTAMP: 2026-05-14T03:57:00+0200
:ID:              jkl012
:END:
*** Response
:PROPERTIES:
:HERMES_KIND: RESPONSE
:END:
It's 6.
\```

### Property rules

| Heading | `HERMES_KIND` | `HERMES_SESSION` | `HERMES_MODEL` | `HERMES_TIMESTAMP` | `:ID:` |
|---------|:---:|:---:|:---:|:---:|:---:|
| `** user` | `USER` | yes | yes | yes | `org-id-get-create` |
| `** assistant` | `ASSISTANT` | yes | yes | yes | `org-id-get-create` |
| `*** Response` | `RESPONSE` | no | no | no | no |
| `*** Reasoning` | `REASONING` | no | no | no | no |
| `*** Tool` | `TOOL` | no | no | no | no |
| `**** Subagent` | `SUBAGENT` | no | no | no | no |
| `** system` | `SYSTEM` | yes | yes | yes | `org-id-get-create` |

`HERMES_MODEL` can be empty on the first turn if `session.info` hasn't arrived yet.

### Heading truncation

- User/system heading shows the first line of message text prefixed with `U:` / `S:`
- Assistant heading shows the first line of response text prefixed with `A:`

---

## Save, Load, and Resume

The Org buffer is the *snapshot* source of truth; the gateway's SQLite DB
(`~/.hermes/state.db`) is the *live* shared cache used by all clients on
the same machine.  Saving a snapshot is just
`(write-region (point-min) (point-max) "chat.org")`.  Reopening that file
gives a "stale heading" — a `:HERMES_SESSION:` property that no longer has
a matching in-memory state.

### Stale-heading prompt

`M-x hermes` (or `hermes-send`) on a stale heading dispatches through
`hermes--handle-stale-heading`, which prompts the user:

1. **Load from org** — fresh gateway session, history seeded from the
   visible buffer on the first prompt (`hermes--build-history-text`).
   Current buffer keeps its identity.  Discards any DB turns that occurred
   after the snapshot.
2. **Resume from DB** — `session.resume` returns a NEW session id plus the
   stored message list; a fresh `*hermes:<new-sid>*` buffer is rendered
   from the response.  The history seed is stamped immediately so the next
   prompt skips re-seeding.
3. **Branch from DB** — `session.branch` forks the DB session, then
   `session.resume` is called on the new id; same effect as resume but the
   original DB session is preserved.

When the gateway returns code `4007 "session not found"` (DB wiped, old
SID format, etc.), the error message hints to pick "Load from org"
instead.

### `hermes-reload-from-org`

`M-x hermes-reload-from-org` (in a `hermes-mode` buffer) is the direct entry point
for option (1): creates a fresh gateway session bound to the current buffer.
The gateway does not accept a `:history` parameter in `session.create`, so
context is restored on the first outgoing prompt via the history seed
(`hermes--build-history-text`).

### `hermes-resume-from-db` / `hermes-branch-from-db`

Programmatic entry points for options (2) and (3).  Also reachable from
the minibuffer commands (`M-x hermes-stored-resume`, `M-x hermes-stored-branch`).  Both call
`session.resume` and install the response via `hermes--db-install-into-buffer`,
which activates `hermes-mode`, writes `HERMES_SESSION` / `HERMES_CWD`
properties, appends the rendered body, and stamps `hermes--seeded-session-id`
to suppress re-seeding.

### DB-resumed buffers are lossy

The gateway pre-flattens history via `_history_to_messages` for client
display: assistant text → `{role:assistant, text}`; each tool call →
its own `{role:tool, name, context}` row where `context` is a summarised
argument string.  `tool_call_id`, reasoning fields, subagents, images,
usage, and timestamps are NOT surfaced.  The Phase-3 renderer
(`hermes--db-messages-to-org-body`) emits a flat structure reflecting
exactly this — no `:HERMES_META:` drawers, no `*** Reasoning` headings,
no `#+name:'d` tool blocks.  Users wanting full fidelity round-trips
must save and reopen the `.org` snapshot rather than relying on the DB.

### Manual editing safety

All data is body-canonical in heading properties, Org blocks, and child
headings.  A user can manually edit the rendered body (e.g. fix a typo in
the assistant's response) and the edit is preserved on resume because text
and properties are parsed back from the visible buffer, not from a hidden
drawer.  Corrupting a property value or Org block may cause that data to
be absent on resume, but the buffer remains valid and the text still
round-trips.

## Doom Integration

### Evil Bindings (`hermes-evil.el`) & Doom Leader (`hermes-doom.el`)

`hermes-evil.el` provides normal-state C-c bindings in `hermes-mode` buffers.
`hermes-doom.el` provides the `SPC h` leader prefix:

| Key | Action |
|-----|--------|
| `SPC h d` | Dashboard (`doom-dashboard-hermes`) |
| `SPC h s` | Start / send prompt |
| `SPC h i` | Start (alias) |
| `SPC h n` | New session |
| `SPC h c` | Multi-line composer |
| `SPC h l` | Session list sidebar |
| `SPC h g` | Go to primary session buffer |
| `SPC h k` | Interrupt primary session |

In `hermes-mode` normal state:
| Key | Action |
|-----|--------|
| `C-c C-i` | Send prompt |
| `C-c C-k` | Interrupt |
| `C-c C-l` | Multi-line compose |

### Theme (`hermes-doom-theme.el`)

| Role | Hex | Source |
|------|-----|--------|
| Background | `#041c1c` | Hermes web dashboard |
| Foreground | `#FFF8DC` | CLI cornsilk |
| Gold | `#FFD700` | CLI primary |
| Amber | `#FFBF00` | CLI accent |
| Bronze | `#CD7F32` | CLI border |
| Teal | `#4EC9B0` | Success |
| Coral | `#FF6B6B` | Error |
| Yellow | `#FFD93D` | Warning |

---

## Known Issues & Design Decisions

### Tool ID fallback

The gateway sends `tool.generating` and `tool.complete` with `{"name":"terminal"}`
— no `"tool_id"` key. The reducer falls back to `(or tool_id id name)` to
identify tools. (See [13-operational-notes.md](13-operational-notes.md) for details.)

### org-element-cache-reset on structural changes

`with-silent-modifications` suppresses Org change hooks. The cache is reset
after the render exits the silent block, but only when `structural-change` or
`bench-touched-p` is true. Streaming ticks (`stream-update`) do **not** reset
the cache — they only reshape the live bench, so the cache stays valid for
the frozen portion of the buffer. This is a major performance win in long
conversations.

### Guarding org-id-get-create

All `org-id-get-create` calls are guarded with `(when (derived-mode-p 'org-mode) ...)`
to prevent Org warnings on fundamental-mode temp buffers in tests.

### The Org file as a portable snapshot

The state atom stores only ephemeral data.  Every committed turn carries
`:HERMES_KIND:` and `:HERMES_TIMESTAMP:` properties; text content, tool
blocks, subagent trees, image references, and usage counters are all
body-canonical — parsed back from the visible buffer on resume.  Benefits:
- No split-brain — user edits to visible text are preserved on resume.
- No duplication — conversation text exists only once (in the buffer).
- Natural snapshot — save the `.org` file, close Emacs, reopen it.
- Load org — `hermes-reload-from-org` parses visible headings and seeds
  history into a fresh gateway session via the first-prompt seed.

Trade-off: `hermes-md-to-org` is one-way (markdown→Org). The gateway receives
Org-formatted text in the history payload. This drift is acceptable for v1
(gptel precedent); a reverse `hermes-org-to-md` converter can be added later
if needed.

### `with-silent-modifications` in render

All buffer edits run inside `with-silent-modifications` and `save-excursion`
to prevent:
- Org change hooks from firing (cache goes stale, repaired in post-passes)
- Point jumping during streaming
- Modification state changes in the read-only buffer

### Shallow copies in reducers

`hermes--with-copy` uses `copy-<struct>` from `cl-defstruct`, which is a
shallow copy. This means the tools vector is shared between old and new
streams during `reasoning.delta` — only `tool.generating`
and `tool.complete` create new tool vectors via `hermes--vector-append` or
`copy-sequence`. The `eq` comparison in `hermes--stream-update` correctly
detects tool changes because these events produce structurally new vectors.

### Unhandled events

Events the gateway emits but the Emacs reducer treats as no-ops (returns
`state` unchanged, no re-render):

| Event | Why no-op |
|-------|-----------|
| `voice.status` | Voice mode not supported in v1 |
| `voice.transcript` | Voice mode not supported in v1 |
| `browser.progress` | Browser tool progress not rendered in v1 |
