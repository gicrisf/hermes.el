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
model from starting "cold," the first real prompt after reconnect is
prefixed with a text block reconstructed from the buffer's history.

**Trigger**: A single buffer-local flag `hermes--pending-history-seed` is set
to `t` in `hermes--route-connection` when the connection transitions to
`'connected` and `hermes--buffer-message-count` is > 0.  No second trigger
(e.g. minor-mode activation) is needed — a buffer without a running gateway
can't send prompts anyway.

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

**Injection** (`hermes-input--seed-prefix`):
- Called on the idle `prompt.submit` path only (`hermes-input--send-1`).
- Prepend the history block before the user's text: `"<history>\n\nCurrent: <prompt>"`.
- Consume the flag (one-shot): set to `nil` whether or not a history block
  was produced, so an empty buffer can't leave the flag stuck.

**Slash command exemption**: Slash commands (`/clear`, `/reconnect`, etc.)
take the `slash.exec` RPC, not `prompt.submit`.  Since `hermes-input--seed-prefix`
is called only in the `prompt.submit` branch, slash commands naturally leave
the flag armed — the next real prompt still gets the seed.  No explicit
`is-slash` predicate is needed.

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
- The seed is a one-shot injection — after the first turn, the gateway's
  internal `session["history"]` takes over.  If the model was mid-tool-call
  when the connection dropped, that context is lost.
- Very long conversations (>100 turns) exceed most model context windows even
  with the truncation cap.  The preamble informs the model that context is
  partial.

---
