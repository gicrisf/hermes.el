## 6. Subagent / Delegation Deep Dive

### 6.1 Gateway Events

6 events form the subagent lifecycle:

| Event | Payload | TUI Action |
|-------|---------|------------|
| `subagent.spawn_requested` | `{goal, task_count, ...}` | Upsert status `queued`, refresh delegation caps |
| `subagent.start` | `{goal, ...}` | Upsert status `running` |
| `subagent.thinking` | `{text, ...}` | Append to `thinking` array (max 6) |
| `subagent.tool` | `{name, tool_preview, text, ...}` | Append to `tools` array (max 8) |
| `subagent.progress` | `{text, ...}` | Append to `notes` array (max 6) |
| `subagent.complete` | `{duration_seconds, status, summary, text, ...}` | Finalize with duration, status, summary |

### 6.2 TUI Rendering

Subagents are rendered as a tree in the transcript:
- Each subagent has: `goal`, `status`, `depth`, `thinking[]`, `tools[]`, `notes[]`, `outputTail`
- The `/agents` overlay shows the full spawn tree
- `spawn_tree.save` persists completed trees to disk

### 6.3 Emacs Implementation

**Full support (Phase 3, completed 2026-05-14).**

#### State

```elisp
(cl-defstruct hermes-subagent
  id          ; string — subagent_id from gateway
  goal        ; string — delegation goal
  status      ; 'queued | 'running | 'complete | 'error
  thinking    ; string — accumulated thinking text
  tools       ; vector of plists (:name :args :timestamp)
  notes       ; vector of strings — progress notes
  summary     ; string — final result summary
  duration)   ; number — duration in seconds
```

Subagents live on `hermes-stream.subagents` during a turn and are copied to `hermes-message.subagents` on `message.complete`, preserving the delegation tree in chat history.

#### Reducer

| Event | Action |
|-------|--------|
| `subagent.spawn_requested` | If stream exists & id not found → create `hermes-subagent` with `status='queued`, append to `stream.subagents` |
| `subagent.start` | Transition `queued` → `running`. UI reducer sets status text `"Delegating to <goal>…"` |
| `subagent.thinking` | Concatenate `text` onto subagent's `thinking` string |
| `subagent.tool` | Append plist `(:name tool_name :args args :timestamp)` to subagent's `tools` vector |
| `subagent.progress` | Append `note` string to subagent's `notes` vector |
| `subagent.complete` | Set status (`complete`/`error`), summary, duration. UI reducer clears status text |

All events are no-ops when no stream is active (same pattern as tool events).

#### Renderer

Subagent blocks are rendered as `****` Org subtrees after the segment region:

```
**** <goal> (running…)
:PROPERTIES:
:ID:       <subagent_id>
:END:
#+begin_example Thinking
<thinking text>
#+end_example
- bash(ls /tmp)
- searching
- found
#+begin_example
<summary> (2.5s)
#+end_example
```

- **Thinking**: `#+begin_example Thinking` block (only if non-empty)
- **Tools**: bullet list `- <name>(<args>)` (only if non-empty)
- **Notes**: bullet list `- <note>` (only if non-empty)
- **Summary**: `#+begin_example` block with duration (only for terminal status)
- The subagent region is tracked by `hermes--stream-subagents-marker` and rewrites in place on each stream update

#### Tests

- 10+ ERT tests for reducer: spawn, start, thinking accumulation, tool append, notes append, complete finalization, error status, commit with message, deduplication, no-stream dropping
- 9+ ERT tests for renderer: formatting with all fields, stream integration (after segments), in-place rewrite
- 2 UI reducer tests: status text set on start, cleared on complete

---
