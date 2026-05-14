# Subagent Support Implementation Plan

> **Status:** Draft  
> **Scope:** Phase 3 — Add full subagent delegation tree to the Emacs frontend  
> **Files touched:** `hermes-events.el`, `hermes-state.el`, `hermes-render.el`, `test/hermes-state-test.el`, `test/hermes-render-test.el`

---

## 1. What Are Subagents?

In the Hermes architecture, the main agent can spawn **subagents** to handle delegated tasks. The TUI renders these as a tree of progress cards showing:

- Goal (what the subagent was asked to do)
- Status (`queued` → `running` → `complete` / `error`)
- Thinking (accumulated reasoning from the subagent)
- Tools (tool calls made by the subagent)
- Notes (progress updates)
- Summary & duration (final result)

The gateway emits 6 events over the lifetime of a subagent:

| Event | When | Payload |
|-------|------|---------|
| `subagent.spawn_requested` | Main agent decides to delegate | `{subagent_id, goal}` |
| `subagent.start` | Subagent actually begins execution | `{subagent_id, goal}` |
| `subagent.thinking` | Subagent produces reasoning | `{subagent_id, text}` |
| `subagent.tool` | Subagent invokes a tool | `{subagent_id, tool_name, args}` |
| `subagent.progress` | Subagent reports progress | `{subagent_id, note}` |
| `subagent.complete` | Subagent finishes | `{subagent_id, status, summary, duration_s}` |

---

## 2. State Changes

### 2.1 New Struct: `hermes-subagent`

```elisp
(cl-defstruct (hermes-subagent (:copier hermes-subagent-copy))
  id          ; string — subagent_id from gateway
  goal        ; string — delegation goal
  status      ; 'queued | 'running | 'complete | 'error
  thinking    ; string — accumulated thinking text
  tools       ; vector of plists (:name :args :timestamp)
  notes       ; vector of strings — progress notes
  summary     ; string — final result summary
  duration)   ; number — duration in seconds
```

**Rationale:** A dedicated struct keeps subagent fields typed and lets the renderer pattern-match on `hermes-subagent-p`. The copier follows the immutable-update pattern used throughout the codebase.

### 2.2 New Slot on `hermes-stream`

Add `subagents` (vector of `hermes-subagent`, default `[]`) to `hermes-stream`.

```elisp
(cl-defstruct (hermes-stream (:copier hermes-stream-copy))
  text thinking reasoning
  tools
  subagents)  ; NEW
```

**Rationale:** Subagents are transient — they exist only during a turn, just like `tools`. Storing them in the stream means they get committed to the final `hermes-message` on `message.complete`, preserving the delegation tree in the chat history.

### 2.3 New Slot on `hermes-message`

Add `subagents` (vector of `hermes-subagent`, default `[]`) to `hermes-message`.

```elisp
(cl-defstruct (hermes-message (:copier hermes-message-copy))
  kind text thinking reasoning tools usage timestamp
  subagents)  ; NEW
```

**Rationale:** Committed messages must retain the full subagent tree so that scrolling back in the chat buffer shows the complete delegation history.

---

## 3. Event Registry

### 3.1 `hermes-events.el`

Add all 6 events to `hermes-events-incoming`:

```elisp
"subagent.spawn_requested"  ; {subagent_id, goal}
"subagent.start"            ; {subagent_id, goal}
"subagent.thinking"         ; {subagent_id, text}
"subagent.tool"             ; {subagent_id, tool_name, args}
"subagent.progress"         ; {subagent_id, note}
"subagent.complete"         ; {subagent_id, status, summary, duration_s}
```

---

## 4. Reducer Design

### 4.1 Persistent Reducer (`hermes--reduce`)

All 6 events operate on `stream.subagents`. If no stream exists, the event is a no-op (same pattern as `tool.generating`).

**Helper:** `hermes--find-subagent (subagents id)` → index or nil

**`subagent.spawn_requested`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`; if found → return state (dedupe)
- If not found → create new `hermes-subagent` with `status='queued`, append to `stream.subagents`

**`subagent.start`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`
- If not found → create one (defensive, should not happen) with `goal` from payload
- Update `status` → `running`

**`subagent.thinking`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`; if not found → return state
- Append `text` to `subagent.thinking` (same pattern as `thinking.delta`)

**`subagent.tool`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`; if not found → return state
- Append plist `(:name tool_name :args args :timestamp (current-time))` to `subagent.tools` vector

**`subagent.progress`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`; if not found → return state
- Append `note` string to `subagent.notes` vector

**`subagent.complete`**
- If `stream` is nil → return state
- Find subagent by `subagent_id`; if not found → return state
- Update `status` → `complete` or `error` (from payload `status`)
- Store `summary` and `duration`

**`message.complete` commit change**
- When committing stream → message, copy `stream.subagents` into `message.subagents`

### 4.2 UI Reducer (`hermes--ui-reduce`)

**`subagent.start`**
- Set `status-text` to something like `Delegating to <goal>…` (truncated)

**`subagent.complete`**
- If all subagents are complete, clear `status-text` (or restore previous)
- Otherwise update to reflect remaining active subagents

**`subagent.spawn_requested`** / **`subagent.thinking`** / **`subagent.tool`** / **`subagent.progress`**
- No-op for UI reducer (or update status text to show active subagent count)

---

## 5. Renderer Design

### 5.1 Placement

Subagent blocks are rendered **after the tool blocks** in the streaming region, and **after the tool blocks** in committed messages. The ordering is:

1. Assistant headline + property drawer
2. Thinking/reasoning blocks (before text)
3. Text region
4. Tool blocks (after text)
5. **Subagent blocks** (after tools) ← NEW

### 5.2 New Markers

- `hermes--stream-subagents-marker` — start of subagent blocks region in stream
- `hermes--msg-subagents-marker-N` — per-message subagent region (or reuse message-end logic)

For committed messages, subagents are rendered inline at the end of the message body (after any tool blocks), so no new per-message marker is needed — the renderer can compute the insertion point from the message region bounds.

### 5.3 Formatting Functions

**`hermes--format-subagent (subagent)`**

Returns an Org subtree:

```org
**** <goal> (<status>)
:PROPERTIES:
:ID:       <subagent_id>
:END:
<thinking block if any>
<tools list if any>
<notes list if any>
<summary block if complete>
```

Specifically:
- Headline: `**** <truncated-goal> (<status>)` — 4 stars so it nests under `*** tool` blocks
- Property drawer with `:ID:` for anchor / dedupe
- Thinking: `#+begin_example Thinking
<thinking>
#+end_example` (only if non-empty)
- Tools: bullet list `- <name>(<args>)` (only if non-empty)
- Notes: bullet list `- <note>` (only if non-empty)
- Summary: `#+begin_example
<summary> (<duration>s)
#+end_example` (only if complete)

**`hermes--format-subagents-block (subagents)`**
- Returns empty string if vector is empty
- Otherwise concatenates `hermes--format-subagent` for each subagent

### 5.4 Stream Rendering

**`hermes--update-subagent-views (subagents)`**
- Same pattern as `hermes--update-tool-views`
- Remove old subagent blocks between `hermes--stream-subagents-marker` and `point-max`
- Insert new formatted block
- Set `hermes--stream-subagents-marker` to insertion point

**`hermes--render` hook change**
- In the stream path, after `hermes--update-tool-views`, call `hermes--update-subagent-views`
- In the committed-message path, append subagent block at the end of the message region

### 5.5 Committed Message Rendering

In `hermes--render-messages` (or wherever committed messages are appended), after inserting tool blocks, check `message.subagents`. If non-empty, append the formatted subagents block before the final newline.

---

## 6. Testing Plan

### 6.1 State Reducer Tests (`test/hermes-state-test.el`)

| Test | What it checks |
|------|----------------|
| `subagent-spawn-creates-queued` | `spawn_requested` with no stream → adds subagent with `status='queued` |
| `subagent-start-transitions-running` | `start` changes `queued` → `running` |
| `subagent-thinking-accumulates` | Multiple `thinking` events append text |
| `subagent-tool-appends` | `tool` event adds to `tools` vector |
| `subagent-progress-appends` | `progress` event adds to `notes` vector |
| `subagent-complete-finalizes` | `complete` sets status, summary, duration |
| `subagent-commit-with-message` | `message.complete` copies subagents into message |
| `subagent-dedupes-spawn` | Duplicate `spawn_requested` with same id is no-op |
| `subagent-without-stream-dropped` | All subagent events without stream → no-op |

### 6.2 Renderer Tests (`test/hermes-render-test.el`)

| Test | What it checks |
|------|----------------|
| `subagent-block-renders-headline` | `hermes--format-subagent` produces `****` headline |
| `subagent-block-includes-thinking` | Thinking text wrapped in example block |
| `subagent-block-includes-tools` | Tool list formatted as bullets |
| `subagent-block-includes-notes` | Notes list formatted as bullets |
| `subagent-block-includes-summary` | Complete subagent shows summary + duration |
| `subagent-blocks-insert-after-tools` | In stream, subagents appear after tool blocks |

---

## 7. Implementation Order

The implementation should proceed in small, testable increments. Recommended order:

### Step 1: Structs and registry (no logic)
1. Add `hermes-subagent` struct to `hermes-state.el`
2. Add `subagents` slot to `hermes-stream` and `hermes-message`
3. Add 6 events to `hermes-events-incoming`
4. Run `eldev test` — should still pass (no logic yet)

### Step 2: Persistent reducer
1. Add `hermes--find-subagent` helper
2. Implement `subagent.spawn_requested` reducer case
3. Implement `subagent.start` reducer case
4. Implement `subagent.thinking` reducer case
5. Implement `subagent.tool` reducer case
6. Implement `subagent.progress` reducer case
7. Implement `subagent.complete` reducer case
8. Update `message.complete` to copy `stream.subagents`
9. Write reducer tests for each case
10. Run `eldev test`

### Step 3: UI reducer
1. Add `subagent.start` → status text
2. Add `subagent.complete` → status text cleanup
3. Write UI reducer tests
4. Run `eldev test`

### Step 4: Renderer
1. Add `hermes--format-subagent` and `hermes--format-subagents-block`
2. Add `hermes--stream-subagents-marker` buffer-local var
3. Add `hermes--update-subagent-views` function
4. Wire into `hermes--render` hook (stream path + committed path)
5. Write renderer tests
6. Run `eldev test`

### Step 5: Documentation
1. Update `HERMES-TUI-REFERENCE.md` event matrix (6 events → Handled)
2. Update Phase 3 section → Completed
3. Update gap analysis table

---

## 8. Open Questions / Risks

### 8.1 Nesting Depth
Subagents render as `****` (4-star) headlines under tools (`***`). If a message has many subagents, the Org outline could become deeply nested. Consider whether subagents should be rendered as plain blocks instead of headlines, or whether we should use `:DRAWER:` syntax.

**Recommendation:** Start with `****` headlines — they fold naturally in Org mode and match the visual hierarchy. Revisit if users complain about clutter.

### 8.2 Committed Message Size
Subagents carry `thinking`, `tools`, `notes` vectors. A busy subagent could produce a large message. This is fine for correctness but may impact buffer performance on very long conversations.

**Mitigation:** The data is already produced by the gateway; we're just persisting it. No additional overhead.

### 8.3 Tool Overlap
A subagent can invoke tools, which the gateway reports via `subagent.tool`. These are separate from the main turn's `tool.generating` / `tool.complete` events. Ensure we don't conflate subagent tools with main turn tools.

**Mitigation:** Subagent tools are stored in `hermes-subagent.tools` (vector of plists), while main turn tools are `hermes-tool` structs in `stream.tools`. The namespaces are distinct.

### 8.4 Renderer Complexity
The streaming region now has 3 replaceable blocks after the text:
1. Tool blocks (`hermes--stream-tools-marker`)
2. Subagent blocks (`hermes--stream-subagents-marker`) ← NEW
3. (Future: activity feed?)

Each insertion must preserve the markers of the blocks that come after it. The existing `hermes--insert-after-text` pattern handles this, but we need to be careful about marker ordering.

**Mitigation:** Insert in order: text → tools → subagents. When replacing, delete from the back (subagents first, then tools, then text) and re-insert in forward order. This is the same pattern used for thinking blocks.

### 8.5 Unknown Payload Shapes
The exact shape of `subagent.tool` args and `subagent.complete` status strings isn't fully documented in the reference. We should use `hermes--get` with fallbacks, same as we do for tool events.

**Mitigation:** All payload access goes through `hermes--get`, which handles hash-table, alist, and plist transparently. Add nil guards for every field.

---

## 9. Acceptance Criteria

- [ ] All 6 subagent events are handled by the persistent reducer
- [ ] Subagent state survives `message.complete` and appears in committed messages
- [ ] Subagent blocks render in the Org buffer with correct nesting
- [ ] UI reducer shows status text for active subagents
- [ ] 9+ ERT tests pass for reducer logic
- [ ] 6+ ERT tests pass for renderer logic
- [ ] `eldev test` reports 0 unexpected failures
- [ ] `HERMES-TUI-REFERENCE.md` event matrix updated

---

*End of plan.*
