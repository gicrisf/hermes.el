## 10. Detailed Gap Matrix

### 10.1 Events

| Category | Event | Emacs | TUI | Gap Level |
|----------|-------|-------|-----|-----------|
| **Lifecycle** | `gateway.ready` | Partial | Full | Medium |
| | `skin.changed` | Full | Full | None |
| | `session.info` | Full | Full | None |
| | `gateway.start_timeout` | Full | Full | None |
| | `gateway.protocol_error` | Full | Full | None |
| | `gateway.stderr` | Full | Full | None |
| **Stream** | `message.start` | Full | Full | None |
| | `message.delta` | Full | Full | None |
| | `message.complete` | Full | Full | None |
| | `thinking.delta` | Full | Full | None |
| | `reasoning.delta` | Full | Full | None |
| | `reasoning.available` | Full | Full | None |
| **Status** | `status.update` | Partial | Full | Low |
| **Tools** | `tool.generating` | Full | Full | None |
| | `tool.start` | Full | Full | None |
| | `tool.progress` | Full | Full | None |
| | `tool.complete` | Full | Full | None |
| **Blocking** | `approval.request` | Full | Full | None |
| | `clarify.request` | Full | Full | None |
| | `sudo.request` | Full | Full | None |
| | `secret.request` | Full | Full | None |
| **Other** | `error` | Full | Full | None |
| | `browser.progress` | No-op | Full | Low |
| | `voice.status` | No-op | Full | Low |
| | `voice.transcript` | No-op | Full | Low |
| | `background.complete` | Full | Full | None |
| | `review.summary` | Full | Full | None |
| **Subagent** | `subagent.spawn_requested` | Full | Full | None |
| | `subagent.start` | Full | Full | None |
| | `subagent.thinking` | Full | Full | None |
| | `subagent.tool` | Full | Full | None |
| | `subagent.progress` | Full | Full | None |
| | `subagent.complete` | Full | Full | None |

### 10.2 RPC Methods

| Method | Emacs | TUI | Gap Level |
|--------|-------|-----|-----------|
| `session.create` | Yes | Yes | None |
| `session.resume` | No | Yes | Medium |
| `session.close` | Yes | Yes | None |
| `session.interrupt` | Yes | Yes | None |
| `session.steer` | No | Yes | **High** |
| `session.branch` | No | Yes | Low |
| `session.compress` | No | Yes | Low |
| `session.undo` | No | Yes | Low |
| `session.save` | No | Yes | Low |
| `session.most_recent` | No | Yes | Medium |
| `prompt.submit` | Yes | Yes | None |
| `prompt.background` | No | Yes | Medium |
| `approval.respond` | Partial | Yes | **High** |
| `clarify.respond` | Yes | Yes | None |
| `sudo.respond` | Yes | Yes | None |
| `secret.respond` | Yes | Yes | None |
| `slash.exec` | Yes | Yes | None |
| `command.dispatch` | No | Yes | Low |
| `commands.catalog` | Yes | Yes | None |
| `config.get` / `config.set` | No | Yes | Low |
| `tools.configure` | No | Yes | Low |
| `reload.mcp` | No | Yes | Low |
| `delegation.status` | No | Yes | Medium |
| `spawn_tree.*` | No | Yes | Low |
| `rollback.*` | No | Yes | Low |
| `skills.*` | No | Yes | Low |
| `voice.*` | No | Yes | Low |
| `image.attach` / `clipboard.paste` | No | Yes | Low |
| `shell.exec` | No | Yes | Medium |
| `browser.manage` | No | Yes | Low |
| `terminal.resize` | No | Yes | Low |

---
