## 11. Implementation Plan

### Phase 0 — Foundational (Completed 2026-05-14)

**Files:** `hermes-state.el`, `hermes-render.el`

1. **Text/reasoning/tool rendering basics**
   - Reasoning rendered as `*** Reasoning` Org blocks
   - Thinking is UI-only (drives header-line status text)
   - Tools rendered as `*** name (status)` Org sub-headlines
   - `hermes--format-cot-block`, `hermes--format-tool` created

2. **Fix approval choices**
   - Changed to canonical `once`/`session`/`always`/`deny`
   - Quick-keys: `?o` (once), `?s` (session), `?a` (always), `?n` (deny)

3. **Bug fixes: tool.start, error reset, reasoning.available**
   - `tool.start` → reducer transitions `generating` → `running`, stores context
   - `error` → commits in-flight stream before appending error
   - `reasoning.available` → initializes reasoning before deltas arrive
   - `tool.progress` → preview stored in persistent state

### Phase 1 — Segmented Stream Rendering (Completed 2026-05-14)

**Files:** `hermes-state.el`, `hermes-render.el`, `test/hermes-state-test.el`, `test/hermes-render-test.el`

**Goal:** Replace flat `text`/`thinking`/`reasoning`/`tools` slots with a single ordered `segments` vector of typed `hermes-segment` objects. Mirror the TUI's `streamSegments` pattern.

1. **Data model**
   - Added `hermes-segment` struct with `type`, `content`, `id` slots
   - Changed `hermes-stream`: `text thinking reasoning` → `segments` vector
   - Added `segments` slot to `hermes-message`; deprecated old slots populated from segments

2. **Reducer**
   - Segment helpers: `hermes--last-segment`, `hermes--append-segment`, `hermes--update-last-segment`, `hermes--find-tool-segment-index`, `hermes--segments-derive-deprecated`
    - All events (`message.delta`, `reasoning.delta`, `tool.*`) create/append typed segments; `thinking.delta` is UI-only
   - `message.complete` and `error` commit segments + populate deprecated slots

3. **Renderer**
   - New markers: `hermes--stream-segments-start`, `hermes--stream-segments-end`
   - `hermes--format-segment` dispatches by segment type
   - `hermes--render-stream-segments` — full rewrite of segment region on each update (Option A)
   - Removed flat rendering (stable/unstable split, thinking block markers, tool view markers)

4. **Tests**
   - 82 ERT tests pass (71 state + 11 renderer)
   - Tests cover segment creation, ordering, formatting, and lifecycle

### Phase 2 — Critical Fixes (Completed 2026-05-14)

1. **Add `tool.start` event handling** ✅
   - Added `"tool.start"` to `hermes-events-incoming`
   - Added reducer case: transition tool status `generating` → `running`, capture context
   - Renderer rewrites tool subtree with running status + context drawer

2. **Add `reasoning.available` reducer** ✅
   - Initializes reasoning block when `reasoning.available` arrives before `reasoning.delta`

3. **Fix `error` turn reset** ✅
    - Persistent reducer: when `"error"` arrives, logs error to `*hermes-log*`. If stream in-flight, commits it as partial assistant message (no system msg). Clears stream.
   - UI reducer: clears `tool-previews`, resets `status-text`

### Phase 2 — Tool Rendering Polish ✅ Completed

**Files:** `hermes-state.el`, `hermes-render.el`

1. **Render `tool.progress` previews** ✅
   - Added `preview` slot to `hermes-tool` struct
   - Persistent reducer updates `tool.preview` on `tool.progress`
   - Renderer shows preview in `#+begin_example` block for running/generating tools

2. **Handle `inline_diff`** ✅
   - Added `inline-diff` slot to `hermes-tool`
   - Reducer stores `inline_diff` from `tool.complete`
   - Renderer inserts `#+begin_diff` / `#+end_diff` block when present

3. **Handle `todos`** ✅
   - Added `todos` slot to `hermes-tool`
   - Reducer stores `todos` from `tool.complete`
    - Renderer renders as `#+name`d Org table

### Phase 3 — Subagent Support ✅ Completed

**Files:** `hermes-state.el`, `hermes-render.el`, `hermes-events.el`, `hermes-mode.el`, `test/hermes-state-test.el`, `test/hermes-render-test.el`

1. **Add subagent state** ✅
   - New struct: `hermes-subagent` with `id`, `goal`, `status`, `thinking`, `tools`, `notes`, `summary`, `duration`
   - Add `subagents` vector to `hermes-stream` and `hermes-message`

2. **Handle 6 subagent events** ✅
   - Reducer: upsert subagent in `stream.subagents`, copy to `message.subagents` on commit
   - UI reducer: set status text "Delegating to <goal>…" on start, clear on complete

3. **Renderer** ✅
   - Insert subagent subtrees after segment region in stream
   - Show goal, status, thinking, tools, notes
   - Rewrites on update via `hermes--stream-subagents-marker`

4. **Tests** ✅
   - 10+ ERT tests for reducer (spawn, start, thinking, tool, progress, complete, dedup, no-stream, commit)
   - 9+ ERT tests for renderer (formatting with all fields, stream integration, in-place rewrite)

### Phase 4 — Gateway Lifecycle ✅ Completed

**Files:** `hermes-state.el`, `hermes-render.el`, `hermes-mode.el`, `hermes-rpc.el`

1. **Handle `gateway.stderr`** ✅
   - Logs `[stderr] <line>` to `*hermes-log*` (clipped to 120 chars)
   - Routed from `hermes-rpc-stderr-functions` hook
   - Never enters the Org buffer

2. **Handle `gateway.start_timeout`** ✅
   - Sentinel detects gateway exit during `starting` state
   - Collects up to 8 stderr tail lines
   - Logs them to `*hermes-log*`
   - UI reducer sets error status text

3. **Handle `gateway.protocol_error`** ✅
   - Logs `[protocol noise] <preview>` to `*hermes-log*`
   - UI reducer sets warning status text
   - Routed from `hermes-rpc-protocol-error-functions` hook
   - Never enters the Org buffer

4. **Handle `background.complete`** ✅
   - Logs `[bg <id>] <text>` to `*hermes-log*`
   - Never enters the Org buffer

5. **Handle `review.summary`** ✅
   - Logs `[review] <text>` to `*hermes-log*`
   - Never enters the Org buffer

### Phase 4.5 — Session Info & Usage ✅ Completed

**Files:** `hermes-state.el`, `hermes-render.el`

1. **Merge usage from `session.info`** ✅
   - Added `usage` slot to `hermes-state`
   - `session.info` reducer extracts `usage` sub-object and merges into `hermes-state-usage`

2. **Accumulate usage from `message.complete`** ✅
   - `message.complete` reducer extracts `tokens_sent` and `tokens_received`
   - Accumulates into `hermes-state-usage` hash table

3. **Render usage in header line** ✅
   - Header line shows `sent→received` token counts when usage data is available

### Phase 5 — Advanced Session Operations

**Files:** `hermes-mode.el`, `hermes-input.el`

1. **`session.steer`**
   - New command: `hermes-steer` (bound to `C-c C-s` or similar)
   - Sends `session.steer` while stream is live

2. **`session.resume`**
   - Dashboard/session list: `R` to resume by ID

3. **`prompt.background`**
   - Optional: background prompt submission

---
