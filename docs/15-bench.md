## 15. Bottom Bench

> **Scope:** The persistent bottom bench for `hermes-mode` major-mode buffers.
> Minor mode (`hermes-minor-mode` in arbitrary org files) does **not** show a bench.
>
> **Date:** 2026-05-17

---

## 15.1 Overview

The bench is a bottom side-window paired with a `hermes-mode` buffer. It serves
as the user's primary interactive surface: the last turn (user prompt,
reasoning, answer) is displayed in structured zones, with an editable input
area at the bottom. The org buffer remains the canonical history.

### Visual layout

```
+------------------------------------------+
|  Hermes · ● · claude-sonnet · 12->34     |  <- header-line (status)
|                                           |
|  ** hello there                           |  <- user prompt zone
|                                           |
|  *** Reasoning                            |  <- reasoning zone (always visible)
|  The user sent a greeting...              |
|  ...                                      |
|                                           |
|  Hello! How can I help you today?         |  <- answer zone
|  ...                                      |
|                                           |
|  ------                                   |  <- separator (read-only)
|  >                                        |  <- input area (cursor)
+------------------------------------------+
```

### Key behaviors

| Behavior | Spec |
|----------|------|
| **Window** | Bottom side-window, 20 lines, dedicated, preserve-size |
| **User prompt** | Echoed as `** <text>` when sent |
| **Reasoning** | Always shows `*** Reasoning` header; populated from `reasoning` segments |
| **Answer** | Populated from `text`, `tool`, `system` segments |
| **No thinking** | `thinking` deltas are ignored (not committed-visible) |
| **ASCII-only** | `[tool: <name>] <status>`, `[system] <text>` — no emojis |
| **Clear-on-send** | Old answer wiped immediately on RET |
| **Commit-late** | Assistant turn commits to org buffer on `message.complete` |
| **Persistence** | Answer stays visible after commit until next user prompt |
| **Auto-scroll** | Window stays pinned to bottom (input area always visible) |

---

## 15.2 Architecture

### Design principles

1. **Pure display surface.** The bench has no state atom. All reads go through
the parent's buffer-local `hermes--state`.
2. **One boundary marker.** `hermes-bench--input-boundary` is the only persistent
marker. Everything above it is ephemeral and rebuilt from scratch on every paint.
Everything below is editable input.
3. **Zero renderer coupling.** The bench does not import or call any org renderer
internals (`hermes--render-stream-segments`, `hermes--segment-block`, etc.).
4. **Full rebuild per delta.** The bench rebuilds its entire ephemeral area on
every stream update. This is fast for a 20-line plain-text buffer and eliminates
marker-drift issues entirely.

### Buffer structure

```
[point-min]

** <user prompt>              (optional, face: hermes-bench-user-face)

*** Reasoning                 (always present, face: hermes-bench-reasoning-heading-face)
<reasoning text>              (face: hermes-bench-reasoning-face)

<answer text>                 (plain text)

------                        (read-only separator, face: hermes-bench-separator-face)
>                             (read-only prompt, face: hermes-bench-prompt-face)
<input text>                  (user-editable)
[point-max]
```

The separator and prompt use `rear-nonsticky (read-only)` so the `read-only`
property does not leak into the input area. The prompt uses `front-sticky
(read-only)` so it does not leak backward into the separator.

---

## 15.3 Rendering model

### `hermes-bench--paint-ephemeral`

The single renderer function. Called from:
- `hermes-bench-send` — clears old turn, shows new user prompt
- `hermes-bench--stream-begin` — initializes empty reasoning/answer zones
- `hermes-bench--stream-update` — rebuilds reasoning/answer from latest segments

Algorithm:
1. Save input text and point offset from input start
2. Delete entire buffer contents (`(delete-region (point-min) (point-max))`)
3. Insert ephemeral content (user prompt, reasoning header + text, answer text)
4. Insert separator line + prompt (read-only)
5. Restore input text and point

This is stateless: no zone markers, no incremental diff, no snapshot vectors.

### Segment partitioning

`hermes-bench--segments-by-zone` walks the segment vector and buckets content:

| Segment type | Destination |
|--------------|-------------|
| `reasoning` | Reasoning zone text |
| `text` | Answer zone text |
| `tool` | Answer zone: `[tool: <name>] <status> <summary>` |
| `system` | Answer zone: `[system] <text>` |
| `thinking` | Dropped |

---

## 15.4 Stream lifecycle

The bench hooks into the existing `hermes-state-change-hook` via `hermes--render`
branching. When `hermes-bench-active-p` is non-nil:

### Stream begin (`os` nil, `ns` non-nil)

```
hermes-bench--stream-begin
  → paint-ephemeral(user-prompt, "", "")
  → set-header
```

### Stream update (`os` and `ns` both non-nil)

```
hermes-bench--stream-update
  → segments-by-zone(stream-segments)
  → paint-ephemeral(nil, reasoning, answer)
```

The `nil` user-text preserves the existing prompt.

### Stream commit (`os` non-nil, `ns` nil)

```
hermes-bench--stream-commit
  → builds hermes-message from old-stream
  → hermes--insert-committed-turn (in parent org buffer)
  → bench NOT cleared
```

The answer remains visible until the next `hermes-bench-send`.

---

## 15.5 Send flow

```
User hits RET in bench input area
  → hermes-bench-send
    1. Grab input text
    2. hermes-bench--clear-input
    3. hermes-bench--paint-ephemeral(text, "", "")
       → wipes old turn, shows "** <text>"
    4. hermes-input-send (in parent org buffer)
       → :user-submit dispatched → org buffer gets "** user: <text>"
       → prompt.submit RPC sent
    5. goto-char (point-max)
```

---

## 15.6 Keybindings

| Context | Key | Action |
|---------|-----|--------|
| hermes-mode | `C-c C-i` | Focus bench input area |
| Bench | `RET` | Send prompt |
| Bench | `C-c C-c` | Send prompt |
| Bench | `C-c C-k` | Interrupt parent session |
| Bench | `C-c C-l` | Open multi-line composer |

---

## 15.7 Files

| File | Role |
|------|------|
| `hermes-bench.el` | Bench buffer lifecycle, renderer, input handling, stream hooks |
| `hermes-mode.el` | Creates bench on `hermes-mode` startup, `C-c C-i` binding |
| `hermes-render.el` | Branches stream lifecycle when bench is active |
| `hermes-input.el` | Called programmatically by bench send |

---

*Document version: 1.0*
