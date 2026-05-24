## 10. Detailed Gap Matrix

### 10.1 Incoming Events

| Category | Event | Emacs | TUI | Gap Level |
|----------|-------|-------|-----|-----------|
| **Lifecycle** | `gateway.ready` | Partial | Full | Low |
| | `skin.changed` | Full | Full | None |
| | `session.info` | Full | Full | None |
| | `reasoning.available` | Full | Full | None |
| | `gateway.start_timeout` | Full | Full | None |
| | `gateway.protocol_error` | Full | Full | None |
| | `gateway.stderr` | Full | Full | None |
| **Stream** | `message.start` | Full | Full | None |
| | `message.delta` | Full | Full | None |
| | `message.complete` | Full | Full | None |
| | `thinking.delta` | Full | Full | None |
| | `reasoning.delta` | Full | Full | None |
| **Status** | `status.update` | Partial | Full | Low |
| **Tools** | `tool.generating` | Full | Full | None |
| | `tool.start` | Full | Full | None |
| | `tool.progress` | Full | Full | None |
| | `tool.complete` | Full | Full | None |
| **Blocking** | `approval.request` | Full | Full | None |
| | `clarify.request` | Full | Full | None |
| | `sudo.request` | Full | Full | None |
| | `secret.request` | Full | Full | None |
| **Background** | `background.complete` | Full | Full | None |
| **Review** | `review.summary` | Full | Full | None |
| **Subagent** | `subagent.spawn_requested` | Full | Full | None |
| | `subagent.start` | Full | Full | None |
| | `subagent.thinking` | Full | Full | None |
| | `subagent.tool` | Full | Full | None |
| | `subagent.progress` | Full | Full | None |
| | `subagent.complete` | Full | Full | None |
| **Other** | `error` | Full | Full | None |
| | `browser.progress` | No-op | Full | Low |
| | `voice.status` | No-op | Full | Low |
| | `voice.transcript` | No-op | Full | Low |

**Notes:**
- `gateway.ready`: Emacs stores skin, sets connection=connected. Does **not** auto-resume or fetch catalog itself (catalog fetch is wired separately via `hermes-input-fetch-catalog`).
- `status.update`: Emacs sets `status-text` and `status-kind` in ephemeral UI state. No activity feed (TUI has a capped activity trail with auto-restore). Low priority — the status text appears on the bench header line.
- `browser.progress`, `voice.*`: No-ops by design — browser control and voice are not Emacs use cases.

### 10.2 Outgoing (RPC) Methods

| Method | Emacs | TUI | Gap | Caller / Notes |
|--------|-------|-----|-----|----------------|
| `session.create` | Full | Full | None | `hermes--do-session-create` — only sends `{:cols 100}`; no title (two-step via `session.title`) |
| `session.resume` | Full | Full | None | `hermes-resume-from-db`, `hermes-stored-resume` (M-x), `/resume` slash (client-side picker) |
| `session.close` | Full | Full | None | `session.close` registered in hermes-events.el, not called from client code |
| `session.interrupt` | Full | Full | None | `hermes-interrupt-current-session`, `C-c C-k` |
| `session.list` | Full | Full | None | `hermes--stored-fetch` used by all `hermes-stored-*` commands |
| `session.branch` | Full | Full | None | `hermes-branch-from-db`, `hermes-stored-branch` (M-x) |
| `session.delete` | Full | Full | None | `hermes-stored-delete` (M-x), `/delete` slash (client-side picker) |
| `session.save` | Full | Full | None | `hermes-stored-export-as-json` (M-x); `/save` passes through to `slash.exec` (gateway handles it) |
| `session.steer` | Full | Full | None | `hermes-input--send-1` when `busy-mode` is `"steer"` |
| `session.title` | — | Full | **Low** | Not in `hermes-events.el`; gateway exposes it; `/title` currently passes through to `slash.exec` (gateway handles it for v1) |
| `session.compress` | Registered | Full | Low | In `hermes-rpc-long-handlers` but never called client-side; gateway handles `/compress` via `slash.exec` |
| `session.undo` | — | Full | Low | Not in `hermes-events.el`; TUI has `/undo`; gateway may handle it via `slash.exec` |
| `session.usage` | — | Full | Low | Not in `hermes-events.el`; usage is tracked internally from `session.info` |
| `session.status` | — | Full | Low | Not in `hermes-events.el` |
| `session.history` | — | Full | Low | Not in `hermes-events.el` |
| `session.most_recent` | Registered | Full | Low | In `hermes-events.el` but unused client-side |
| `prompt.submit` | Full | Full | None | `hermes-send` |
| `prompt.background` | Full | Full | None | `/bg` slash handler; `hermes-input--dispatch-background` |
| `slash.exec` | Full | Full | None | Generic `/`-prefixed dispatch; session slashes intercepted client-side for `/resume`/`/sessions`/`/delete` |
| `shell.exec` | Full | Full | None | `!cmd` and `$(cmd)` interpolation in `hermes-input--send-1` |
| `commands.catalog` | Full | Full | None | Fetched once after `gateway.ready` |
| `command.dispatch` | Registered | Full | Low | In `hermes-events.el` but never called |
| `config.get` / `config.set` | Full | Full | None | `hermes-config.el` — `hermes-config-get` / `hermes-config-set` |
| `toolsets.list` | Full | Full | None | `hermes-config.el` — `hermes-toolsets-list` |
| `tools.configure` | Full | Full | None | `hermes-config.el` — `hermes-toolsets-toggle` |
| `skills.reload` | Full | Full | None | `hermes-config.el` |
| `skills.manage` | Full | Full | None | `hermes-config.el` — list/search/install/uninstall |
| `image.attach` | Full | Full | None | `hermes-image-attach` |
| `clipboard.paste` | Full | Full | None | In `hermes-events.el`; wired via `hermes-config.el` |
| `input.detect_drop` | Full | Full | None | In `hermes-events.el` |
| `approval.respond` | Full | Full | None | `hermes-prompts.el` sends canonical `once`/`session`/`always`/`deny` |
| `clarify.respond` | Full | Full | None | `hermes-prompts.el` |
| `sudo.respond` | Full | Full | None | `hermes-prompts.el` |
| `secret.respond` | Full | Full | None | `hermes-prompts.el` |
| `reload.mcp` | — | Full | Low | Gateway-only (MCP server reload); not applicable to Emacs workflow |
| `reload.env` | — | Full | Low | Gateway-only |
| `delegation.status` / `.pause` | — | Full | Medium | Not wired — subagent delegation caps not surfaced in Emacs |
| `spawn_tree.*` | — | Full | Low | Subagent tree persistence — niche |
| `rollback.*` | — | Full | Low | Conversation checkpointing — niche |
| `voice.*` | — | Full | Low | Voice — not applicable to Emacs |
| `browser.manage` | Registered | Full | Low | In `hermes-rpc-long-handlers` but never called |
| `terminal.resize` | — | Full | Low | Emacs terminal resize is automatic |
| `complete.slash` / `complete.path` | — | Full | Low | Emacs has native `completion-at-point` for slashes |

**Gap level key:**
- **None** — Emacs and TUI both implement it equivalently
- **Low** — Useful but not blocking; workaround exists or feature is niche
- **Medium** — Important feature with meaningful UX gap
- **High** — Critical missing functionality (none remaining)

### 10.3 Slash Commands

| Slash | Emacs | TUI | Notes |
|-------|-------|-----|-------|
| `/bg`, `/background`, `/btw` | Full | Full | Intercepted client-side → `prompt.background` RPC |
| `/resume [name\|id]` | Full | Full | Intercepted client-side → minibuffer picker |
| `/sessions` | Full | Full | Intercepted client-side → minibuffer picker |
| `/delete` | Full | Full | Intercepted client-side → minibuffer picker with confirmation |
| `/title <text>` | Gateway | Full | Falls through to `slash.exec`; gateway's `slash.exec` handler dispatches `session.title` |
| `/branch [name]` | Gateway | Full | Falls through to `slash.exec`; gateway handles branching server-side |
| `/save` | Gateway | Full | Falls through to `slash.exec`; gateway's `slash.exec` handler dispatches `session.save` |
| `/compress [topic?]` | Gateway | Full | Falls through to `slash.exec` |
| `/undo` | Gateway | Full | Falls through to `slash.exec` |
| `/usage` | Gateway | Full | Falls through to `slash.exec` |
| `/model` | Full | Full | `hermes-config.el` |
| `/fast` | Full | Full | `hermes-config.el` |
| `/reasoning` | Full | Full | `hermes-config.el` |
| `/yolo` | Full | Full | `hermes-config.el` |
| `/personality` | Full | Full | `hermes-config.el` |
| `/skin` | Full | Full | `hermes-config.el` |
| `/tools` | Full | Full | `hermes-config.el` — toolsets toggle |
| `/skills` | Full | Full | `hermes-config.el` — reload/list/search/install/uninstall |
| `/help` | Full | Full | Displays gateway's slash catalog as system message |
| `/clear` | Full | Full | Gateway handles it |
| `/new` | Full | Full | Gateway handles it |
| `/exit` | Full | Full | Gateway handles it |
| `!cmd` (shell) | Full | Full | Intercepted client-side → `shell.exec` RPC |
| `$(cmd)` (interpolation) | Full | Full | Intercepted client-side → `shell.exec` RPC |

**Interception model:** Slash commands are processed in order:
1. Shell (`!…`, `$(…)`) — intercepted client-side
2. Background (`/bg` et al.) — intercepted client-side → `prompt.background`
3. Session management (`/resume`, `/sessions`, `/delete`) — intercepted client-side → minibuffer picker / RPC
4. Everything else → `slash.exec` RPC — gateway handles it (title, branch, save, compress, undo, usage, model, fast, etc.)

This means all session-management slashes work in v1. The three client-side interceptions handle the picker-heavy flows; the rest defer to the gateway as async long handlers.

### 10.4 Registration Status in `hermes-events.el`

| Method | In `hermes-rpc-methods` | In `hermes-rpc-long-handlers` | Wired in code |
|--------|------------------------|-------------------------------|---------------|
| `session.create` | ✓ | — | ✓ |
| `session.resume` | ✓ | ✓ | ✓ |
| `session.close` | ✓ | — | ✓ |
| `session.interrupt` | ✓ | — | ✓ |
| `session.list` | ✓ | — | ✓ |
| `session.branch` | ✓ | ✓ | ✓ |
| `session.delete` | ✓ | — | ✓ |
| `session.save` | ✓ | — | ✓ |
| `session.steer` | ✓ | — | ✓ |
| `session.compress` | — | ✓ | — |
| `session.undo` | — | — | — |
| `session.title` | — | — | — |
| `session.usage` | — | — | — |
| `session.status` | — | — | — |
| `session.history` | — | — | — |
| `session.most_recent` | — | — | — |

---

*Last updated: 2026-05-22 — reflects Phase 1 slash interception (419 tests, 0 unexpected).*
