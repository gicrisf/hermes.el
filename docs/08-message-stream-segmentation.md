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
- Segment types: `text`, `reasoning`, `tool`, `system` (`thinking` is UI-only, not persisted)
  - Segments are appended in arrival order as events arrive from the gateway
  - Renderer uses **incremental diffing**: only the changed tail segment is replaced in place; unchanged prefix segments are skipped entirely (O(delta) cost, not O(total text))
  - A snapshot vector of `(:id :type :length)` plists mirrors the rendered buffer, making boundaries deterministic without per-segment markers
  - On `message.complete`, segments are committed to `message.segments` (the deprecated `text`/`tools` slots are populated from segments for backward compat)

**Formatting per segment type:**
- `text` → markdown-to-Org conversion via `hermes-md-to-org`
- `thinking` → not rendered (UI-only via header-line status)
- `reasoning` → `#+begin_example Reasoning` block
- `tool` → `*** name (status)` sub-headline with context, output, diff, todos
- `system` → `#+begin_comment` block

**Key properties:**
- Segments are rendered in order → tools appear **interleaved** with text where they happened in the turn
- No stable/unstable split, no per-block markers, no manual marker bookkeeping
- The renderer diffs the new segment vector against a `hermes--stream-segments-snapshot` (parallel `:id`/`:type`/`:length` metadata), replacing only the divergent suffix

### Stream Paint Throttling

High-frequency token streams (>25 Hz) would saturate the Emacs UI thread even with incremental rendering. The renderer uses a **hard-cap throttle** with **adaptive backoff**:

- A `run-with-timer` cooldown arms on the first paint after an idle gap
- Deltas arriving during the cooldown stash their snapshot in `hermes--stream-render-pending`
- The timer fires, paints the latest snapshot, and re-arms with an **adaptive interval** based on total rendered text size
- Lifecycle transitions (`stream-begin`, `stream-commit`, error) always paint synchronously

**Adaptive thresholds** (discrete steps, one-interval lag):

| Total rendered text | Interval | Frequency |
|---------------------|----------|-----------|
| < 1,000 chars | 0.04s | 25 Hz |
| < 5,000 chars | 0.20s | 5 Hz |
| < 10,000 chars | 1.00s | 1 Hz |
| ≥ 10,000 chars | 2.00s | 0.5 Hz |

The existing `hermes-render-stream-throttle` custom variable acts as a **floor** (minimum interval). Set to `0` for pure adaptive; set to `1.0` to force at least 1-second gaps regardless of text size.

### Bench Renderer (Major Mode Only)

When `hermes-bench-active-p` returns non-nil (i.e. a `hermes-mode` buffer has its
bottom bench visible), the org renderer's stream lifecycle is **bypassed** for
stream updates. Instead:

- `hermes-bench--stream-begin` — called when the first delta arrives; clears the
  bench ephemeral area and shows the user prompt
- `hermes-bench--stream-update` — called on every throttled delta; rebuilds the
  reasoning and answer zones from scratch (no incremental diff)
- `hermes-bench--stream-commit` — called on `message.complete`; builds a
  `hermes-message` from the final stream and calls `hermes--insert-committed-turn`
  in the parent org buffer

The bench renderer does **not** use org markup, markers, or incremental diffing.
It is a plain-text rebuild: delete ephemeral region, reinsert user prompt +
reasoning header + answer text, restore separator + input. This is fast enough
for a 20-line text buffer and eliminates marker-drift issues entirely.

The org buffer still receives the full rich turn (headings, property drawers,
meta drawers, org IDs) on commit via `hermes--insert-committed-turn`.

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
