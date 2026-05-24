## 2. Event Protocol Comparison

### 2.1 Incoming Events (gateway → frontend)

The gateway emits events via `_emit(event, sid, payload)` in `tui_gateway/server.py:382-386`. Frames are JSON-RPC notifications:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"<name>","session_id":"<sid>","payload":{...}}}
```

#### Events: Full Matrix

| # | Event | Emacs Status | TUI Handler | Notes |
|---|-------|--------------|-------------|-------|
| 1 | `gateway.ready` | **Handled** | `handleReady()` — applies skin, fetches `commands.catalog`, auto-resumes or creates session, schedules startup prompt | Emacs: sets connection=connected, stores skin. Does **not** auto-resume or fetch catalog on its own (catalog fetch is wired separately via `hermes-input-fetch-catalog`). |
| 2 | `skin.changed` | **Handled** | `applySkin()` — hot-swaps theme | Emacs: stores skin, `hermes-skin-watch` re-applies face remaps. |
| 3 | `session.info` | **Handled** | Patches `uiStore.info`, merges usage, updates status, patches intro messages in history | Emacs: merges into `session-info` hash table. Extracts and merges `usage` sub-object into `hermes-state-usage`. Does not patch intro messages. |
| 4 | `message.start` | **Handled** | `turnController.startMessage()` — resets turn state, sets `busy=true` | Emacs: creates empty `hermes-stream` with empty `segments` vector. |
| 5 | `message.delta` | **Handled** | `turnController.recordMessageDelta()` — accumulates text, prunes trails, schedules batched flush | Emacs: appends to last text segment, or creates new `hermes-segment` if last is non-text. |
| 6 | `message.complete` | **Handled** | `turnController.recordMessageComplete()` — closes reasoning, dedupes inline diffs, archives todos, builds final segments, archives spawn tree, appends transcript, rings bell, updates usage, resets turn state | Emacs: commits `stream.segments` into `message.segments`, populates deprecated `text`/`thinking`/`tools` slots from segments for backward compat. |
| 7 | `thinking.delta` | **Handled** | Sets status, forwards to `recordReasoningDelta()` | Emacs: UI-only — concatenates onto `thinking-text` and drives the header-line `status-text`. Not persisted as a segment. |
| 8 | `reasoning.delta` | **Handled** | `turnController.recordReasoningDelta()` | Emacs: creates/appends `reasoning` segment in stream. Rendered as `#+begin_example Reasoning` block. |
| 9 | `reasoning.available` | **Handled** | `turnController.recordReasoningAvailable()` — initializes reasoning block before deltas | Emacs: creates `reasoning` segment if not already present (same as `reasoning.delta`). |
| 10 | `status.update` | **Handled** | Sets status text; if `kind` is compressing/goal, emits system line; else pushes activity item (capped at 8), restores default after 4000ms | Emacs: sets `status-text` and `status-kind` in ephemeral UI state. No activity feed, no auto-restore. |
| 11 | `tool.generating` | **Handled** | Pushes transient trail line "drafting X…" into `turnTrail` | Emacs: creates `tool` segment with `hermes-tool` content (status `generating`). |
| 12 | `tool.start` | **Handled** | Flushes streaming segment, closes reasoning, records todos, adds tool to `activeTools`, updates tool-token accumulator | Emacs: updates existing tool segment's status to `running`, stores `context`. |
| 13 | `tool.progress` | **Handled** | Updates `activeTool.context`, throttles UI refresh to `STREAM_BATCH_MS` | Emacs: updates tool segment's `preview` in-place. |
| 14 | `tool.complete` | **Handled** | Removes from `activeTools`, builds final trail line, flushes into segments, handles `inline_diff`, handles `todos`, updates `turnTrail` | Emacs: updates tool segment's status/output/error/duration/inline-diff/todos. |
| 15 | `approval.request` | **Handled** | Patches `overlayStore.approval`, sets status="approval needed" | Emacs: sets `pending` to `hermes-pending` with kind `approval`. `hermes-prompts.el` handles the minibuffer prompt with canonical choices `once`/`session`/`always`/`deny` (fixed 2026-05-14). |
| 16 | `clarify.request` | **Handled** | Patches `overlayStore.clarify`, sets status="waiting for input…" | Emacs: sets `pending` with kind `clarify`. Minibuffer handler dispatches `clarify.respond`. |
| 17 | `sudo.request` | **Handled** | Patches `overlayStore.sudo`, sets status="sudo password needed" | Emacs: sets `pending` with kind `sudo`. Minibuffer handler dispatches `sudo.respond`. |
| 18 | `secret.request` | **Handled** | Patches `overlayStore.secret`, sets status="secret input needed" | Emacs: sets `pending` with kind `secret`. Minibuffer handler dispatches `secret.respond`. |
| 19 | `error` | **Handled** | `turnController.recordError()` — resets turn state, pushes activity, checks for "No provider" to show setup overlay, logs to system | Emacs: logs error to `*hermes-log*`. If a stream is in-flight, commits it as partial assistant message (no system msg). UI reducer sets error status text. |
| 20 | `gateway.stderr` | **Handled** | Pushes stderr line as activity item in turn feed (clipped to 120 chars) | Emacs: logs `[stderr] <line>` to `*hermes-log*` (clipped to 120). Routed from `hermes-rpc-stderr-functions` hook. Never enters the Org buffer. |
| 21 | `gateway.start_timeout` | **Handled** | Sets error status, pushes error activity, surfaces up to 8 stderr tail lines | Emacs: sentinel collects last 8 stderr lines on process exit during `starting` state, logs them to `*hermes-log*`. UI reducer sets error status text. Never enters the Org buffer. |
| 22 | `gateway.protocol_error` | **Handled** | Sets warning status, pushes one-time "protocol noise" activity, shows truncated preview | Emacs: logs `[protocol noise] <preview>` to `*hermes-log*`. UI reducer sets warning status text. Routed from `hermes-rpc-protocol-error-functions` hook. Never enters the Org buffer. |
| 23 | `background.complete` | **Handled** | Removes task from `bgTasks`, emits system line `[bg <id>] <text>` | Emacs: logs `[bg <id>] <text>` to `*hermes-log*`. Never enters the Org buffer. |
| 24 | `review.summary` | **Handled** | Emits persistent system line (self-improvement review summary) | Emacs: logs `[review] <text>` to `*hermes-log*`. Never enters the Org buffer. |
| 25 | `subagent.spawn_requested` | **Handled** | Upserts subagent with status `queued`, fetches delegation caps | Emacs: reducer creates `hermes-subagent` with `status='queued` on `stream.subagents`. Dedupes by id. |
| 26 | `subagent.start` | **Handled** | Upserts subagent with status `running` | Emacs: reducer transitions `queued` → `running`. UI reducer sets status text. |
| 27 | `subagent.thinking` | **Handled** | Appends thinking text to subagent's `thinking` array | Emacs: reducer concatenates text onto `hermes-subagent.thinking`. |
| 28 | `subagent.tool` | **Handled** | Appends formatted tool call to subagent's `tools` array | Emacs: reducer stores plist `(:name :args :timestamp)` in `hermes-subagent.tools` vector. |
| 29 | `subagent.progress` | **Handled** | Appends progress note to subagent's `notes` array | Emacs: reducer appends note string to `hermes-subagent.notes` vector. |
| 30 | `subagent.complete` | **Handled** | Finalizes subagent with duration, status, summary | Emacs: reducer sets status (`complete`/`error`), summary, duration. UI reducer clears status text. |
| 31 | `browser.progress` | **No-op** | Emits to system log | Emacs: commented "v1: no-op". Low impact. |
| 32 | `voice.status` | **No-op** | Updates voice recording/processing state | Emacs: commented "v1: no-op". |
| 33 | `voice.transcript` | **No-op** | Clears input, submits transcript as new turn | Emacs: commented "v1: no-op". |

### 2.2 Outgoing Requests (frontend → gateway)

Defined in `hermes-events.el` and used across the Emacs codebase.

#### Methods the Emacs frontend currently calls (full list)

| Method | Params | Purpose | Caller |
|--------|--------|---------|--------|
| **Session lifecycle** | | | |
| `session.create` | `{cols?}` | Create new session | `hermes--do-session-create` |
| `session.resume` | `{session_id}` | Resume prior session (long handler) | `hermes-resume-from-db`, `hermes-stored-resume`, `/resume` slash |
| `session.close` | `{session_id}` | Close session | `hermes-rpc-request` (registered in events.el, not called from client code) |
| `session.interrupt` | `{session_id}` | Interrupt turn | `hermes-interrupt-current-session`, `C-c C-k` |
| `session.list` | `{limit?, cwd?}` | List stored sessions | `hermes--stored-fetch` (used by all `hermes-stored-*` commands) |
| `session.branch` | `{session_id, name?}` | Fork conversation (long handler) | `hermes-branch-from-db`, `hermes-stored-branch` |
| `session.delete` | `{session_id}` | Delete session from DB | `hermes-stored-delete`, `/delete` slash |
| `session.save` | `{session_id}` | Export transcript to JSON file | `hermes-stored-export-as-json` |
| `session.steer` | `{session_id, text}` | Inject message into active turn | `hermes-input--send-1` (busy-mode `"steer"`) |
| **Conversation** | | | |
| `prompt.submit` | `{session_id, text}` | Send user message | `hermes-send` |
| `prompt.background` | `{session_id, text}` | Launch background task | `/bg` slash handler |
| **Blocking prompt responses** | | | |
| `approval.respond` | `{session_id, request_id, choice, all?}` | Respond to approval | `hermes--prompt-approval` |
| `clarify.respond` | `{request_id, answer}` | Respond to clarify | `hermes--prompt-clarify` |
| `sudo.respond` | `{request_id, password}` | Respond to sudo | `hermes--prompt-sudo` |
| `secret.respond` | `{request_id, value}` | Respond to secret | `hermes--prompt-secret` |
| **Commands** | | | |
| `slash.exec` | `{session_id, command}` | Execute slash command (long handler) | `hermes-send` (fallthrough for non-intercepted slashes) |
| `shell.exec` | `{command}` | Run shell command (long handler) | `!cmd` and `$(cmd)` in `hermes-input--send-1` |
| `commands.catalog` | `{}` | Fetch slash command catalog | `hermes-input-fetch-catalog` |
| **Configuration** | | | |
| `config.get` | `{key, session_id?}` | Read config key | `hermes-config.el` |
| `config.set` | `{key, value, session_id?}` | Write config key | `hermes-config.el` |
| `toolsets.list` | `{session_id?}` | List available toolsets | `hermes-config.el` |
| `tools.configure` | `{session_id?, action, names}` | Enable/disable toolsets | `hermes-config.el` |
| **Skills** | | | |
| `skills.reload` | `{}` | Reload skills from disk | `hermes-config.el` |
| `skills.manage` | `{action, query?, page?, page_size?}` | Manage skills (long handler) | `hermes-config.el` — list/search/install/uninstall |
| **Multimodal** | | | |
| `image.attach` | `{session_id, path}` | Attach image to session | `hermes-config.el` — `hermes-image-attach` |
| `clipboard.paste` | `{session_id}` | Paste clipboard image | `hermes-config.el` |
| `input.detect_drop` | `{session_id, text}` | Detect file drop in input | (registered in events.el) |

#### Methods registered in `hermes-events.el` but not yet called by client code

| Method | Purpose | Note |
|--------|---------|------|
| `command.dispatch` | Direct command dispatch | In `hermes-rpc-methods` but unused |
| `session.compress` | Compress history with topic focus | In `hermes-rpc-long-handlers`; gateway handles `/compress` via `slash.exec` |
| `session.most_recent` | Find most recent session | In `hermes-events.el` (method list) but unused client-side |
| `browser.manage` | Chrome CDP control | In `hermes-rpc-long-handlers`; not applicable to Emacs |

#### Methods the TUI calls that Emacs does **not** (truly absent)

| Method | Purpose | Priority |
|--------|---------|----------|
| `session.undo` | Rollback last exchange | Low |
| `session.title` | Set/get session title | Low (gateway handles via `slash.exec`) |
| `session.usage` | Get token/cost usage | Low |
| `session.status` | Get live session status | Low |
| `session.history` | Get message history | Low |
| `reload.mcp` | Reload MCP servers | Low |
| `reload.env` | Re-read `.env` | Low |
| `setup.status` | Check if LLM provider configured | Low |
| `voice.toggle` / `voice.record` | Voice control | Low (not applicable) |
| `delegation.status` / `delegation.pause` | Delegation caps | Low |
| `spawn_tree.save` / `.list` / `.load` | Subagent tree archive | Low |
| `rollback.list` / `.diff` / `.restore` | Checkpoints | Low |
| `terminal.resize` | Notify gateway of new dimensions | Low (automatic) |
| `complete.slash` / `complete.path` | Autocomplete | Low (Emacs has native CAPF) |

---
