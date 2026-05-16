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

---
