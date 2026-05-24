## 15. Bottom Bench

> **Scope:** The persistent bottom bench for Org buffers with `hermes-org-minor-mode`.
>
> **Date:** 2026-05-24

---

## 15.1 Overview

The bench is a bottom side-window paired with an Org buffer that has `hermes-org-minor-mode` enabled.  It is
a `hermes-comint-mode` buffer flagged with `hermes-comint--bench-p = t`.  It
shows only the current in-flight turn (user prompt + assistant stream) above a
writable `> ` prompt; committed history lives in the org buffer only.  The
bench provides comint's history ring (M-p / M-n) and field-based prompt
handling.

### Visual layout

```
┌──────────────────────────────────────────┐
│ > User · 14:52                            │  ← user heading (shown on send)
│ what is 2+2?                              │
│                                            │
│ Let me think carefully...                  │  ← reasoning + answer
│                                            │     (from stream)
│ 2+2 is 4.  This is basic arithmetic.      │
│                                            │
│ [tool: calculator] DONE 2+2=4 (0.3s)      │  ← tool summaries
├──────────────────────────────────────────┤
│ > █                                prompt │  ← field-based input (cursor)
└──────────────────────────────────────────┘
```

The header-line shows persistent session-level status: background task counters
(`[bg: 1 running]`) and attachment counts (`[2 attachment(s)]`).

### Key behaviors

| Behavior | Spec |
|----------|------|
| **Window** | Bottom side-window, 20 lines, dedicated |
| **User prompt** | Shown as `> User · HH:MM\n<text>` on send |
| **Stream** | In-flight turn rendered atomically via `hermes-comint--paint-stream` |
| **Commit** | On `message.complete`, ephemeral region clears; turn lands in org buffer only |
| **History ring** | comint-input-ring — M-p / M-n cycling through past prompts |
| **Auto-scroll** | Window stays pinned to bottom (prompt always visible) |
| **Status** | Bg tasks + attachments in header-line; steer + transient feedback in ephemeral region |

---

## 15.2 Architecture

### Design principles

1. **Single mode, two behaviors.** The bench is `hermes-comint-mode` with a
   buffer-local `hermes-comint--bench-p` flag.  When t, committed-turn
   rendering is suppressed (`load-from-state` and `append-new-turns` are no-ops).

2. **One region, two markers.** `hermes-comint--output-end` and
   `hermes-comint--prompt-start` partition the buffer: everything between them
   is the ephemeral region; everything after `prompt-start` is the writable
   prompt + input.

3. **Atomic rebuild per delta.** `paint-stream` deletes the entire ephemeral
   region and re-inserts all content on every tick: user heading + steer lines
   + transient status + assistant turn.  No incremental diff, no zone markers.

4. **Pure projection.** The bench reads from the same `hermes--sessions` state
   atom as the org viewer and comint viewer.  It subscribes to
   `hermes-state-change-hook` independently.

### Buffer structure

```
[point-min]
                                           ← output-end (nil insertion-type)
> User · 14:52                             ← ephemeral user heading
what is 2+2?                                     (read-only, field output)

Let me think carefully...                   ← stream content
2+2 is 4.                                         (overwritten on every tick)
[tool: calculator] DONE 2+2=4 (0.3s)

                                           ← prompt-start (t insertion-type)
>                                          ← prompt prefix (read-only, field input)
█                                          ← user input (editable)
[point-max]
```

The prompt uses `rear-nonsticky (read-only)` on the `> ` prefix so typed text
inherits the `field 'input` property but not `read-only`.

### Buffer-local state

| Variable | Purpose |
|----------|---------|
| `hermes-comint--bench-p` | Non-nil → bench mode (suppress history rendering) |
| `hermes-comint--current-user-prompt` | Last user prompt text, preserved across stream ticks |
| `hermes-comint--steer-messages` | List of `[steer]` strings; cleared on commit |
| `hermes-comint--status-message` | Transient status `(:text :error-p)`; cleared on commit |
| `hermes-comint--bg-cookie` | face-remap cookie for skin background |

---

## 15.3 Rendering model

### `hermes-comint--paint-stream` (bench mode)

In bench mode, `paint-stream` prepends ephemeral content before the assistant
turn.  On every stream tick, the entire ephemeral region is rebuilt atomically:

1. Delete `[output-end, prompt-start)` — wipe the old ephemeral region
2. If `current-user-prompt` is set: insert `> User · HH:MM\n<fontified body>\n\n`
3. If `steer-messages` non-empty: insert `[steer] <msg>\n` lines
4. If `status-message` set: insert the status line
5. Insert the in-flight assistant turn via `hermes-comint--insert-turn`

In full-comint mode, only step 5 runs (unchanged behavior).

### Segment content

Bench rendering goes through `hermes-comint--insert-turn`, which handles all
segment types using the same logic as the full comint viewer:

| Segment type | Bench rendering |
|--------------|-----------------|
| `reasoning` | `--- Reasoning ---` block in reasoning face |
| `text` | Markdown→Org fontified body |
| `tool` | `STATUS name summary duration` line + formatted body |
| `subagent` | `Subagent: goal (status)` with thinking/notes/tools/result |
| `system` | Fontified text |

No separate `segments-by-zone` function — comint's `--insert-turn` already
does this.

---

## 15.4 Stream lifecycle

The bench subscribes to `hermes-state-change-hook` via `hermes-comint--refresh`,
which dispatches four branches.  Bench-mode gating (`when hermes-comint--bench-p`)
controls which branches are active:

### Stream begin (`old-stream` nil, `new-stream` non-nil)

```
hermes-comint--stream-begin
  → paint-stream(state)
    → delete ephemeral, insert user-heading + steer + status + assistant turn
```

### Stream update (`old-stream` and `new-stream` both non-nil, not `eq`)

```
hermes-comint--stream-update
  → throttle dispatch → paint-stream(state)
    → same atomic rebuild as stream-begin
```

The `current-user-prompt` variable survives across ticks, so the user heading
is re-rendered on every paint-stream call.

### Stream commit (`old-stream` non-nil, `new-stream` nil)

```
hermes-comint--stream-commit (bench branch)
  → cancel throttle timer
  → clear steer-messages, status-message
  → delete-region [output-end, prompt-start)   ← clear ephemeral
  → do NOT advance output-end
  → do NOT update turns-snapshot
```

### Committed appends (no stream, turns changed)

Bench mode: **no-op**.  The `append-new-turns` path is gated with
`(when hermes-comint--bench-p (cl-return nil))`.  Committed turns
live only in the org buffer.

### State load (on bench creation)

Bench mode: **no-op**.  `load-from-state` returns immediately.  The bench starts
with an empty ephemeral region — no history is loaded.

---

## 15.5 Send flow

```
User hits RET in bench prompt
  → hermes-comint-send
    1. Read prompt text (hermes-comint--prompt-text)
    2. Push to comint-input-ring (M-p / M-n history)
    3. Clear old ephemeral: delete [output-end, prompt-start)
    4. Store user prompt: (setq hermes-comint--current-user-prompt input)
    5. Insert user heading in ephemeral region
    6. Clear prompt input area
    7. hermes-send
       → :user-submit dispatched → org buffer gets user turn
       → prompt.submit RPC sent
```

The user heading stays visible until the first stream tick overwrites it with
the assistant's response.  On commit, the ephemeral region clears entirely.

---

## 15.6 Keybindings

| Context | Key | Action |
|---------|-----|--------|
| Org buffer | `C-c C-i` | Focus bench input area |
| Bench | `RET` | Send prompt |
| Bench | `C-c C-c` | Send prompt |
| Bench | `M-p` | Previous input from history ring |
| Bench | `M-n` | Next input from history ring |
| Bench | `C-c C-k` | Interrupt parent session |
| Bench | `C-c C-l` | Open multi-line composer |
| Bench | `C-c C-a` | Attach image file |
| Bench | `C-c C-b` | List background tasks |

---

## 15.7 Files

| File | Role |
|------|------|
| `hermes-comint.el` | Bench API (`hermes-bench-ensure/active-p/hide/...`) + implementation (`bench-p` flag, paint-stream bench path, skin bg, CAPF) |
| `hermes.el` / `hermes-org-minor-mode.el` | Creates bench on startup via `hermes-bench-ensure`, `C-c C-i` binding |
| `hermes-state.el` | `hermes--bench-buffers` registry, `hermes--maybe-kill-bench` lifecycle |

---

*Document version: 2.0*
