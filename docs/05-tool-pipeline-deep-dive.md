## 5. Tool Pipeline Deep Dive

### 5.1 Gateway Tool Lifecycle (`tui_gateway/server.py`)

The agent loop calls callbacks registered per session:

```python
# _agent_cbs() — server.py:1626-1647
{
    "tool_start_callback":    lambda tc_id, name, args: _on_tool_start(sid, tc_id, name, args),
    "tool_complete_callback": lambda tc_id, name, args, result: _on_tool_complete(sid, tc_id, name, args, result),
    "tool_progress_callback": lambda event_type, name=None, preview=None, ...: _on_tool_progress(sid, ...),
    "tool_gen_callback":      lambda name: _tool_progress_enabled(sid) and _emit("tool.generating", sid, {"name": name}),
    ...
}
```

**`_on_tool_start`** (`server.py:1489-1508`):
- Captures local edit snapshot (for diff rendering)
- Records start time
- Emits `tool.start` with `{tool_id, name, context}` if tool progress enabled

**`_on_tool_complete`** (`server.py:1511-1547`):
- Pops snapshot and start time
- Computes `duration_s`
- Generates `summary`
- Extracts `todos` for todo tool
- Generates `inline_diff` via `render_edit_diff_with_delta`
- Emits `tool.complete` with full payload

**`_on_tool_progress`** (`server.py:1550-1561`):
- Only emits if `_tool_progress_enabled(sid)`
- For `event_type == "tool.started"` → emits `tool.progress` with `{name, preview}`

### 5.2 TUI Tool Rendering

The TUI renders tools through `turnController`:
- `tool.generating` → transient trail line "drafting X…"
- `tool.start` → flushes streaming segment, adds to `activeTools`, records todos
- `tool.progress` → updates active tool context (throttled)
- `tool.complete` → removes from active, builds final trail, flushes segments, handles inline diffs

Tools appear inline in the transcript as collapsible segments.

### 5.3 Emacs Tool Rendering (Segmented 2026-05-14)

**Before:** Tools were interleaved into `stream-text` as plain text (`-> running name\n`, `-> done name (0.5s)\n`). This polluted the assistant's prose and broke the stable/unstable split.

**After (v1):** Tools were rendered as **separate Org sub-headlines** after the text region, independent of `stream-text`. Reasoning was managed as separate marker-tracked blocks before text.

**After (v2 — segmented):** All content lives in a single `segments` vector as typed `hermes-segment` objects. The renderer does a **full rewrite of the segment region** on every stream update (Option A from the plan). No stable/unstable split, no per-block markers:

- `tool.generating` → reducer creates tool segment; renderer formats as `*** name (running…)`
- `tool.start` → reducer updates segment in-place; renderer rewrites all segments
- `tool.complete` → reducer updates status/output/etc; renderer rewrites
- `reasoning.delta` → creates/appends typed segments; `thinking.delta` is UI-only (drives header-line status)
- `message.delta` → creates/appends text segments
- End of turn → `message.complete` commits segments to `message.segments`

Segments are rendered in arrival order with blank-line separation. The Org buffer faithfully mirrors the turn narrative: reasoning → tool call → tool output → assistant text, all in the order they happened.

Renderer markers:
- `hermes--stream-segments-start` — after assistant property drawer
- `hermes--stream-segments-end` — end of rendered segments
- `hermes--stream-headline-marker` — at the `** assistant` headline

### 5.4 Tool Pipeline Gaps

| Issue | Detail | Severity |
|-------|--------|----------|
| **Missing `tool.start`** | ✅ Fixed — reducer transitions `generating` → `running`, stores context | **High** |
| **Dead `tool.progress` state** | ✅ Fixed — preview stored in persistent `tool.preview`, rendered in block | **Medium** |
| **No `inline_diff` support** | ✅ Fixed — stored in `tool.inline-diff`, rendered as `#+begin_diff` block | **Medium** |
| **No `todos` support** | ✅ Fixed — stored in `tool.todos`, rendered as `#+name`d Org table | **Low** |
| **No `tool.started` event** | This is a Python-side event type that maps to `tool.progress` emission | N/A |
| **Tool context** | ✅ Fixed — `tool.start` stores context in `hermes-tool-context`; rendered as `:CONTEXT:` drawer in running tool block | Low |

---
