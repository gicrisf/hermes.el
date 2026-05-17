## 9. Input Queue Mechanics

### 9.1 TUI Busy Input Modes

The TUI has three modes for input while busy:
- **`interrupt`** (default) — Ctrl-C cancels current turn, then sends
- **`queue`** — appends to queue, drains when turn ends
- **`steer`** — calls `session.steer`; falls back to queue on rejection

### 9.2 Emacs Input

Emacs uses an **invisible queue** (pi-coding-agent pattern):
- If stream is idle → commit user message to buffer + send `prompt.submit` immediately
- If stream is live → enqueue silently (message is NOT displayed yet)
- Drain hook fires on `message.complete` → dequeue head, commit it to buffer, then send `prompt.submit`

The queue is FIFO and invisible — the user only sees a minibuffer message like "Hermes: Message queued (N ahead of you)". Messages appear in the buffer only when it's their turn to be sent.

**Hook ordering is critical:** `hermes--render` MUST run before `hermes-input--drain` on `hermes-state-change-hook`. If drain runs first, it dispatches `:user-submit` before `stream-commit` has sealed the assistant turn, causing the assistant's `:HERMES_RAW:` drawer to land after the dequeued user heading. `add-hook` with `nil` APPEND prepends, so all hooks are added with `t` to preserve insertion order.

**Gap:** No interrupt-via-input, no steering.

### 9.3 History Seed — Injecting Context After a Fresh Start

When the gateway restarts (or the user explicitly calls `hermes-reconnect`),
the new gateway session starts with empty history.  The Emacs buffer, however,
still contains every committed turn in `:HERMES_RAW:` drawers.  To prevent the
model from starting "cold," every `prompt.submit` checks whether the current
gateway session has already been seeded.

**Trigger** (`hermes--seeded-session-id`): A buffer-local variable holding the
session-id that was last seeded with history.  Before each `prompt.submit`,
the current `(hermes-state-session-id …)` is compared to this value.  When
they differ (including the initial `nil` state), the session is new and
needs seeding.  After seeding, the variable is updated to match the current
session-id so subsequent sends to the same session skip the seed.

No connection-transition hooks are needed — the decision lives at send time,
which guarantees idempotent behavior regardless of how the session was
created (reconnect, manual `session.create`, or opening a saved file).

**Construction** (`hermes--build-history-text`):
- Reads `:HERMES_RAW:` drawers via `hermes--parse-buffer-messages`.
- Formats each non-empty turn as `Role: text`, where `Role` is `User`,
  `Assistant`, or `System` (derived from the message kind).
- Only **text-segment content** is included.  Reasoning, tool, thinking, and
  system segments are skipped — their structured data cannot be faithfully
  represented as prose.
- Truncated to the last `hermes-history-seed-max-turns` (default 30) to
  prevent context-window blowout on long conversations.  When truncation
  occurs, the preamble notes "(last N turns of M)".

**Injection** (`hermes-input--seed-prefix`): Called at all three
`prompt.submit` call sites — idle send, reconnect drain, and queue drain —
so the seed fires from whatever path the first prompt takes.  If the buffer
has no committed turns, the session-id is stamped anyway (one empty walk,
then skipped on subsequent sends).

A user-visible `message` fires once per session when seeding actually adds context:
```
Hermes: seeding history for session abc123…
```

**Behavior matrix**:

| Scenario | Action |
|----------|--------|
| Fresh prompt, new session, buffer has turns | Seed once, stamp sid |
| Subsequent prompt, same session | Skip (sid matches) |
| Gateway crash → reconnect → idle send | Seed once on new sid |
| Gateway crash → reconnect → queued drain | Now seeds (was a gap in v1) |
| Open saved file, gateway already up | Seed once on first send |
| Slash commands (`/clear`, etc.) | Untouched — take `slash.exec`, never reach seed-prefix |
| Empty buffer | Stamp sid, no prefix, no re-walk on subsequent sends |

**Transcript separation**: The `:user-submit` dispatch (which inserts the
user's turn into the Org buffer) receives the **original** prompt text without
the history prefix.  The prefix is for the gateway only; the transcript shows
what the user actually typed.

**Configuration**:

| Variable | Default | Purpose |
|----------|---------|---------|
| `hermes-history-seed-max-turns` | 30 | Truncates the seed to the last N turns; `nil` for no limit |

**Limitations**:
- The gateway does not accept a structured `:history` parameter.  The history
  is sent as a single text block, which the model must parse as a conversation
  transcript.  Role boundaries are preserved (`User:` / `Assistant:`) but
  tool results, reasoning, and subagent output are dropped.
- Very long conversations (>100 turns) exceed most model context windows even
  with the truncation cap.  The preamble informs the model that context is
  partial.

---
