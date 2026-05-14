## 8. Message Stream Segmentation

### 8.1 TUI

The TUI treats the stream as structured segments:

- **Segments** (`streamSegments`): structured message parts (assistant text, tool diffs, tool trails, reasoning blocks)
- **Pending tools** (`streamPendingTools`): tools that finished but haven't been flushed into a segment yet
- **Trail** (`turnTrail`): transient lines showing tool selection/execution
- **Activity** (`activity`): info/warn/error items

On `message.complete`, the TUI:
1. Archives done todos
2. Deduplicates inline diff segments against final text
3. Builds final message list: `archivedTodos + segments + details + finalText`
4. Archives spawn-tree snapshot
5. Appends to transcript history

### 8.2 Emacs (Segmented)

**Emacs now uses a typed segment model matching the TUI's approach:**

- `stream.segments` — vector of `hermes-segment` objects, each with `type`, `content`, `id`
- Segment types: `text`, `thinking`, `reasoning`, `tool`, `system`
- Segments are appended in arrival order as events arrive from the gateway
- Renderer does a **full rewrite** of the segment region on every stream update (simple, correct)
- On `message.complete`, segments are committed to `message.segments` (the deprecated `text`/`thinking`/`tools` slots are populated from segments for backward compat)

**Formatting per segment type:**
- `text` → markdown-to-Org conversion via `hermes-md-to-org`
- `thinking` → `#+begin_example Thinking` block
- `reasoning` → `#+begin_example Reasoning` block
- `tool` → `*** name (status)` sub-headline with context, output, diff, todos
- `system` → `#+begin_comment` block

**Key properties:**
- Segments are rendered in order → tools appear **interleaved** with text where they happened in the turn
- No stable/unstable split, no per-block markers, no manual marker bookkeeping
- The renderer is a simple format-each-segment loop with full region replace

### Stream Markers

Six buffer-local variables govern the in-flight assistant message:

| Variable | Role |
|----------|------|
| `hermes--stream-headline-marker` | Start of `** assistant` heading |
| `hermes--stream-segments-start` | Right after assistant's `:END:\n` (nil insertion-type) |
| `hermes--stream-segments-end` | End of rendered segment content (t insertion-type) |
| `hermes--stream-subagents-marker` | Boundary between segments and subagent blocks (t insertion-type) |
| `hermes--ui-line` | Right-hand status text in header line |

### Heading Conventions

| Level | Who | First line |
|-------|-----|------------|
| `*` | user, system | First line of message text (truncated at `\n`) |
| `**` | assistant | Static `** assistant` |
| `***` | tool | `toolname (status)` |
| `****` | subagent | `goal (status)` |

### Property Drawer Rules

| Heading | `HERMES_SESSION` | `HERMES_MODEL` | `HERMES_TIMESTAMP` | `:ID:` |
|---------|:---:|:---:|:---:|:---:|
| `* user` | yes | yes (from state at submit) | yes | yes |
| `** assistant` | no | no | yes | yes |
| `*** tool` | no | no | no | yes (via `org-id-get-create`) |
| `* system` | yes | yes | yes | yes |

### Tags

- `:hermes:` on every `* user`, `** assistant`, `* system` heading
- `:hermes-tool:` on every `*** tool` heading
- All tags padded to column 80 for visual alignment

---
