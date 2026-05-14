## 9. Input Queue Mechanics

### 9.1 TUI Busy Input Modes

The TUI has three modes for input while busy:
- **`interrupt`** (default) — Ctrl-C cancels current turn, then sends
- **`queue`** — appends to queue, drains when turn ends
- **`steer`** — calls `session.steer`; falls back to queue on rejection

### 9.2 Emacs Input

Emacs only has **queue** mode:
- If stream is live → optimistic commit + enqueue
- Drain hook fires on `message.complete` → dispatch head of queue

**Gap:** No interrupt-via-input, no steering.

---
