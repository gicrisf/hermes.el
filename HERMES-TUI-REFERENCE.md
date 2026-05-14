# Hermes Emacs Frontend vs. Official TUI — Reference Document

> **Purpose:** Comprehensive analysis of the official Hermes TUI (`ui-tui` + `tui_gateway`) compared to the Emacs frontend (`emacs-hermes`). This document captures protocol semantics, state shapes, event handling, and implementation gaps for future development.
>
> **Date:** 2026-05-13 (updated 2026-05-14)
> **Sources:** `hermes-agent/ui-tui/src/`, `hermes-agent/tui_gateway/server.py`, `hermes-agent/tools/approval.py`, and the Emacs codebase (`*.el`).
>
> **Recent changes reflected in this version:**
> - Segmented stream rendering: stream state uses typed `segments` vector; renderer does full rewrite
> - Tool rendering moved into segments (tool blocks are interleaved in arrival order, not appended after text)
> - Thinking/reasoning rendered as typed segments (not separate marker-managed blocks)
> - Approval choices fixed to canonical `once`/`session`/`always`/`deny`

---

## 1. Architectural Model

### 1.1 Official TUI (Ink + Python)

```
┌─────────────┐     NDJSON-RPC      ┌──────────────────┐
│  Ink (Node) │ ◄──────stdio──────► │ tui_gateway      │
│  React UI   │                     │  (Python)        │
│             │ ◄──event notify──── │                  │
│  - renderer │ ──request id──────► │  - AIAgent       │
│  - state    │                     │  - session mgmt  │
│  - overlays │                     │  - tool dispatch │
└─────────────┘                     └──────────────────┘
```

- **Ink owns the screen.** Python owns sessions, tools, model calls, slash command logic.
- Frontend is **display-only**: it never executes tools, never blocks the agent loop, and never uploads results. It only renders events and responds to blocking prompts.
- Transport: newline-delimited JSON-RPC 2.0 over stdio.

### 1.2 Emacs Frontend

Same architecture, same role. Emacs replaces Ink as the display layer.

```
┌─────────────┐     NDJSON-RPC      ┌──────────────────┐
│ Emacs Lisp  │ ◄──────stdio──────► │ tui_gateway      │
│  hermes-mode│                     │  (Python)        │
│  Org buffer │                     │                  │
└─────────────┘                     └──────────────────┘
```

- `hermes-rpc.el` — transport (make-process, NDJSON, pending callback map)
- `hermes-state.el` — TEA-style reducer (persistent + ephemeral UI state)
- `hermes-render.el` — diff-based Org buffer renderer
- `hermes-mode.el` — major mode, event routing, entry points
- `hermes-prompts.el` — minibuffer handlers for blocking prompts
- `hermes-input.el` — input queue, slash commands, history

---

## 2. Event Protocol Comparison

### 2.1 Incoming Events (gateway → frontend)

The gateway emits events via `_emit(event, sid, payload)` in `tui_gateway/server.py:382-386`. Frames are JSON-RPC notifications:

```json
{"jsonrpc":"2.0","method":"event","params":{"type":"<name>","session_id":"<sid>","payload":{...}}}
```

#### Events: Full Matrix

| # | Event | Emacs Status | TUI Handler | Notes |
|---|-------|--------------|-------------|-------|
| 1 | `gateway.ready` | **Handled** | `handleReady()` — applies skin, fetches `commands.catalog`, auto-resumes or creates session, schedules startup prompt | Emacs: sets connection=connected, stores skin. Does **not** auto-resume or fetch catalog on its own (catalog fetch is wired separately via `hermes-input-fetch-catalog`). |
| 2 | `skin.changed` | **Handled** | `applySkin()` — hot-swaps theme | Emacs: stores skin, `hermes-skin-watch` re-applies face remaps. |
| 3 | `session.info` | **Handled** | Patches `uiStore.info`, merges usage, updates status, patches intro messages in history | Emacs: merges into `session-info` hash table. Extracts and merges `usage` sub-object into `hermes-state-usage`. Does not patch intro messages. |
| 4 | `message.start` | **Handled** | `turnController.startMessage()` — resets turn state, sets `busy=true` | Emacs: creates empty `hermes-stream` with empty `segments` vector. |
| 5 | `message.delta` | **Handled** | `turnController.recordMessageDelta()` — accumulates text, prunes trails, schedules batched flush | Emacs: appends to last text segment, or creates new `hermes-segment` if last is non-text. |
| 6 | `message.complete` | **Handled** | `turnController.recordMessageComplete()` — closes reasoning, dedupes inline diffs, archives todos, builds final segments, archives spawn tree, appends transcript, rings bell, updates usage, resets turn state | Emacs: commits `stream.segments` into `message.segments`, populates deprecated `text`/`thinking`/`tools` slots from segments for backward compat. |
| 7 | `thinking.delta` | **Handled** | Sets status, forwards to `recordReasoningDelta()` | Emacs: creates/appends `thinking` segment in stream. Rendered as `#+begin_example Thinking` block. |
| 8 | `reasoning.delta` | **Handled** | `turnController.recordReasoningDelta()` | Emacs: creates/appends `reasoning` segment in stream. Rendered as `#+begin_example Reasoning` block. |
| 9 | `reasoning.available` | **Handled** | `turnController.recordReasoningAvailable()` — initializes reasoning block before deltas | Emacs: creates `reasoning` segment if not already present (same as `reasoning.delta`). |
| 10 | `status.update` | **Handled** | Sets status text; if `kind` is compressing/goal, emits system line; else pushes activity item (capped at 8), restores default after 4000ms | Emacs: sets `status-text` and `status-kind` in ephemeral UI state. No activity feed, no auto-restore. |
| 11 | `tool.generating` | **Handled** | Pushes transient trail line "drafting X…" into `turnTrail` | Emacs: creates `tool` segment with `hermes-tool` content (status `generating`). |
| 12 | `tool.start` | **Handled** | Flushes streaming segment, closes reasoning, records todos, adds tool to `activeTools`, updates tool-token accumulator | Emacs: updates existing tool segment's status to `running`, stores `context`. |
| 13 | `tool.progress` | **Handled** | Updates `activeTool.context`, throttles UI refresh to `STREAM_BATCH_MS` | Emacs: updates tool segment's `preview` in-place. |
| 14 | `tool.complete` | **Handled** | Removes from `activeTools`, builds final trail line, flushes into segments, handles `inline_diff`, handles `todos`, updates `turnTrail` | Emacs: updates tool segment's status/output/error/duration/inline-diff/todos. |
| 15 | `approval.request` | **Handled** | Patches `overlayStore.approval`, sets status="approval needed" | Emacs: sets `pending` to `hermes-pending` with kind `approval`. `hermes-prompts.el` handles the minibuffer prompt with canonical choices `once`/`session`/`always`/`deny` (fixed 2026-05-14). |
| 16 | `clarify.request` | **Handled** | Patches `overlayStore.clarify`, sets status="waiting for input…" | Emacs: sets `pending` with kind `clarify`. Minibuffer handler dispatches `clarify.respond`. |
| 17 | `sudo.request` | **Handled** | Patches `overlayStore.sudo`, sets status="sudo password needed" | Emacs: sets `pending` with kind `sudo`. Minibuffer handler dispatches `sudo.respond`. |
| 18 | `secret.request` | **Handled** | Patches `overlayStore.secret`, sets status="secret input needed" | Emacs: sets `pending` with kind `secret`. Minibuffer handler dispatches `secret.respond`. |
| 19 | `error` | **Handled** | `turnController.recordError()` — resets turn state, pushes activity, checks for "No provider" to show setup overlay, logs to system | Emacs: commits in-flight stream as partial assistant message, appends error system message, clears stream. UI reducer clears `tool-previews` and `status-text`. |
| 20 | `gateway.stderr` | **Handled** | Pushes stderr line as activity item in turn feed (clipped to 120 chars) | Emacs: reducer appends `[stderr] <line>` system message (clipped to 120). Routed from `hermes-rpc-stderr-functions` hook. |
| 21 | `gateway.start_timeout` | **Handled** | Sets error status, pushes error activity, surfaces up to 8 stderr tail lines | Emacs: sentinel collects last 8 stderr lines on process exit during `starting` state, reducer appends `[gateway start timeout]` system message. UI reducer sets error status text. |
| 22 | `gateway.protocol_error` | **Handled** | Sets warning status, pushes one-time "protocol noise" activity, shows truncated preview | Emacs: reducer appends `[protocol noise] <preview>` system message. UI reducer sets warning status text. Routed from `hermes-rpc-protocol-error-functions` hook. |
| 23 | `background.complete` | **Handled** | Removes task from `bgTasks`, emits system line `[bg <id>] <text>` | Emacs: reducer appends `[bg <id>] <text>` system message. |
| 24 | `review.summary` | **Handled** | Emits persistent system line (self-improvement review summary) | Emacs: reducer appends `[review] <text>` system message. |
| 25 | `subagent.spawn_requested` | **Missing** | Upserts subagent with status `queued`, fetches delegation caps | Emacs: no subagent state. |
| 26 | `subagent.start` | **Missing** | Upserts subagent with status `running` | Emacs: no handler. |
| 27 | `subagent.thinking` | **Missing** | Appends thinking text to subagent's `thinking` array | Emacs: no handler. |
| 28 | `subagent.tool` | **Missing** | Appends formatted tool call to subagent's `tools` array | Emacs: no handler. |
| 29 | `subagent.progress` | **Missing** | Appends progress note to subagent's `notes` array | Emacs: no handler. |
| 30 | `subagent.complete` | **Missing** | Finalizes subagent with duration, status, summary | Emacs: no handler. |
| 31 | `browser.progress` | **No-op** | Emits to system log | Emacs: commented "v1: no-op". Low impact. |
| 32 | `voice.status` | **No-op** | Updates voice recording/processing state | Emacs: commented "v1: no-op". |
| 33 | `voice.transcript` | **No-op** | Clears input, submits transcript as new turn | Emacs: commented "v1: no-op". |

### 2.2 Outgoing Requests (frontend → gateway)

Defined in `hermes-events.el` and used across the Emacs codebase.

#### Methods the Emacs frontend currently calls

| Method | Params | Purpose | Caller |
|--------|--------|---------|--------|
| `session.create` | `{cols?}` | Create new session | `hermes--do-session-create` |
| `session.resume` | `{session_id}` | Resume prior session | *(not wired in M2-M4)* |
| `session.close` | `{session_id}` | Close session | `hermes-sessions-close` |
| `session.interrupt` | `{session_id}` | Interrupt turn | `hermes-interrupt` |
| `prompt.submit` | `{session_id, text}` | Send user message | `hermes-input-send` |
| `approval.respond` | `{session_id, request_id, choice, all?}` | Respond to approval | `hermes--prompt-approval` |
| `clarify.respond` | `{request_id, answer}` | Respond to clarify | `hermes--prompt-clarify` |
| `sudo.respond` | `{request_id, password}` | Respond to sudo | `hermes--prompt-sudo` |
| `secret.respond` | `{request_id, value}` | Respond to secret | `hermes--prompt-secret` |
| `slash.exec` | `{session_id, command}` | Execute slash command | `hermes-input-send` |
| `command.dispatch` | `{session_id?, name, arg}` | Direct command dispatch | *(not wired)* |
| `commands.catalog` | `{}` | Fetch slash command list | `hermes-input-fetch-catalog` |

#### Methods the TUI calls that Emacs does **not**

| Method | Purpose | Priority |
|--------|---------|----------|
| `session.steer` | Inject message into active turn without interrupting | Medium |
| `session.branch` | Fork conversation | Low |
| `session.compress` | Compress history with topic focus | Low |
| `session.undo` | Rollback last exchange | Low |
| `session.save` | Export transcript | Low |
| `session.status` | Get live session status | Low |
| `session.usage` | Get token/cost usage | Low |
| `session.most_recent` | Find most recent session (for auto-resume) | Medium |
| `prompt.background` | Launch background prompt | Medium |
| `config.get` / `config.set` | Read/write config keys | Low |
| `setup.status` | Check if LLM provider configured | Low |
| `tools.configure` | Enable/disable toolsets | Low |
| `reload.mcp` | Reload MCP servers | Low |
| `reload.env` | Re-read `.env` | Low |
| `voice.toggle` / `voice.record` | Voice control | Low |
| `clipboard.paste` / `image.attach` | Image attachments | Low |
| `input.detect_drop` | File drop detection | Low |
| `shell.exec` | `!cmd` and `$()` interpolation | Medium |
| `browser.manage` | Chrome CDP control | Low |
| `delegation.status` / `delegation.pause` | Delegation caps | Medium |
| `spawn_tree.save` / `.list` / `.load` | Subagent tree archive | Low |
| `rollback.list` / `.diff` / `.restore` | Checkpoints | Low |
| `skills.reload` / `skills.manage` | Skill management | Low |
| `terminal.resize` | Notify gateway of new dimensions | Low |
| `complete.slash` / `complete.path` | Autocomplete | Low |

---

## 3. State Shape Comparison

### 3.1 TUI State (nanostores)

The TUI splits state across **three nanostore atoms** plus local React state.

#### `$uiState` — Global UI State
```typescript
{
  sid: string | null;              // active session ID
  busy: boolean;                   // agent processing
  busyInputMode: 'interrupt' | 'queue' | 'steer';
  status: string;                  // status-bar text
  statusBar: 'bottom' | 'off' | 'top';
  info: SessionInfo | null;        // model, cwd, skills, tools, etc.
  usage: Usage;                    // tokens, cost, context percent
  theme: Theme;                    // full color/branding object
  streaming: boolean;              // live text streaming enabled
  compact: boolean;                // compact transcript
  inlineDiffs: boolean;            // render inline diff blocks
  mouseTracking: boolean;
  showCost: boolean;
  showReasoning: boolean;
  detailsMode: 'hidden' | 'collapsed' | 'expanded';
  detailsModeCommandOverride: boolean;
  sections: SectionVisibility;     // thinking, tools, subagents, activity
  indicatorStyle: 'ascii' | 'emoji' | 'kaomoji' | 'unicode';
  bgTasks: Set<string>;            // background prompt task IDs
}
```

#### `$turnState` — Per-Turn Ephemeral State
```typescript
{
  streaming: string;               // live assistant text buffer
  streamSegments: Msg[];           // segmented messages
  streamPendingTools: string[];    // tools waiting to flush
  reasoning: string;               // accumulated reasoning
  reasoningActive: boolean;
  reasoningStreaming: boolean;
  reasoningTokens: number;
  toolTokens: number;
  tools: ActiveTool[];             // currently running tools
  turnTrail: string[];             // tool trail lines
  subagents: SubagentProgress[];   // delegation tree
  todos: TodoItem[];               // active todo list
  todoCollapsed: boolean;
  activity: ActivityItem[];        // live activity feed (capped at 8)
  outcome: string;                 // turn outcome label
}
```

#### `$overlayState` — Blocking Prompts
```typescript
{
  approval: ApprovalReq | null;
  clarify: ClarifyReq | null;
  sudo: SudoReq | null;
  secret: SecretReq | null;
  confirm: ConfirmReq | null;
  pager: PagerState | null;
  picker: boolean;
  modelPicker: boolean;
  skillsHub: boolean;
  agents: boolean;
  agentsInitialHistoryIndex: number;
}
```

### 3.2 Emacs State (`hermes-state.el`)

#### Persistent State (`hermes-state`)
```elisp
(cl-defstruct hermes-state
  connection          ; 'disconnected | 'connecting | 'connected
  session-id
  session-info        ; hash-table or nil
  (messages [])       ; vector of hermes-message
  stream              ; hermes-stream or nil
  pending             ; hermes-pending or nil
  slash-catalog
  (queue nil)
  (history nil)
  skin)
```

#### Ephemeral UI State (`hermes-ui-state`)
```elisp
(cl-defstruct hermes-ui-state
  status-text
  status-kind
  spinner-frame
  (tool-previews nil))  ; alist tool-id → preview string (dead state)
```

#### Message State (`hermes-message`)
```elisp
(cl-defstruct (hermes-message (:copier hermes-message-copy))
  kind        ; 'user | 'assistant | 'system
  text        ; DEPRECATED — derive from segments
  thinking    ; DEPRECATED — derive from segments
  reasoning   ; DEPRECATED — derive from segments
  tools       ; DEPRECATED — derive from segments
  segments    ; vector of hermes-segment — committed turn narrative
  usage timestamp)
```

#### Stream State (`hermes-stream`)
```elisp
(cl-defstruct hermes-stream
  segments    ; vector of hermes-segment, ordered by arrival
  tools)      ; DEPRECATED — kept for backward compat
```

#### Segment State (`hermes-segment`)
```elisp
(cl-defstruct hermes-segment
  type        ; 'text | 'thinking | 'reasoning | 'tool | 'system
  content     ; string for text/thinking/reasoning/system; hermes-tool for tool segments
  id)         ; unique segment id (for stable updates)
```

#### Tool State (`hermes-tool`)
```elisp
(cl-defstruct hermes-tool
  id
  name
  status      ; 'generating | 'running | 'complete | 'error
  output
  error
  duration)
```

#### Pending State (`hermes-pending`)
```elisp
(cl-defstruct hermes-pending
  kind        ; 'approval | 'clarify | 'secret | 'sudo
  request-id
  payload)
```

### 3.3 Key State Differences

| Aspect | TUI | Emacs |
|--------|-----|-------|
| **Busy flag** | `uiState.busy` — explicit boolean | Implicit: `(hermes-state-stream state)` |
| **Activity feed** | `turnState.activity` — array of items, capped at 8 | Not present |
| **Tool active list** | `turnState.tools` — active tools with context, tokens | `segments` — all tools in stream as typed tool segments |
| **Tool previews** | Active tool context updates (throttled) | Stored in tool segment's `hermes-tool-preview`; also in `tool-previews` (dead state) |
| **Subagents** | Full delegation tree with depth, status, notes | Not present |
| **Todos** | `turnState.todos` — active todo list | Not present |
| **Turn trail** | `turnState.turnTrail` — transient trail lines | Not present |
| **Segments** | `streamSegments` + `streamPendingTools` — structured | ✅ `stream.segments` vector of typed `hermes-segment` objects. Renderer does full segment rewrite on each update. |
| **Reasoning tokens** | `reasoningTokens`, `toolTokens` | Not present |
| **Usage merging** | Merges usage on every `session.info` | ✅ Merged into `hermes-state-usage`; also accumulated from `message.complete` |
| **Background tasks** | `bgTasks: Set<string>` | Not present |
| **Overlay store** | Multiple overlay types simultaneously possible | Single `pending` slot (replaces wholesale) |
| **Outcome** | `turnState.outcome` — e.g. "denied" | Not present |

---

## 4. Approval Flow Deep Dive

### 4.1 Gateway Side (`tui_gateway/server.py`)

Approvals are routed through `tools/approval.py`.

**Session registration** (`server.py:1937-1942`):
```python
from tools.approval import register_gateway_notify, load_permanent_allowlist
register_gateway_notify(key, lambda data: _emit("approval.request", sid, data))
load_permanent_allowlist()
```

**Blocking prompt factory** (`server.py:723-731`):
```python
def _block(event: str, sid: str, payload: dict, timeout: int = 300) -> str:
    rid = uuid.uuid4().hex[:8]
    ev = threading.Event()
    _pending[rid] = (sid, ev)
    payload["request_id"] = rid
    _emit(event, sid, payload)
    ev.wait(timeout=timeout)
    _pending.pop(rid, None)
    return _answers.pop(rid, "")
```

**Approval response method** (`server.py:3596-3615`):
```python
@method("approval.respond")
def _(rid, params: dict) -> dict:
    session, err = _sess(params, rid)
    if err: return err
    try:
        from tools.approval import resolve_gateway_approval
        return _ok(rid, {
            "resolved": resolve_gateway_approval(
                session["session_key"],
                params.get("choice", "deny"),
                resolve_all=params.get("all", False),
            )
        })
    except Exception as e:
        return _err(rid, 5004, str(e))
```

**Resolution** (`tools/approval.py:517-543`):
```python
def resolve_gateway_approval(session_key: str, choice: str,
                             resolve_all: bool = False) -> int:
    """Called by gateway's /approve or /deny handler to unblock waiting threads.
    When resolve_all=True every pending approval is resolved at once.
    Returns number of approvals resolved."""
    with _lock:
        queue = _gateway_queues.get(session_key)
        if not queue: return 0
        if resolve_all:
            targets = list(queue)
            queue.clear()
        else:
            targets = [queue.pop(0)]
        if not queue:
            _gateway_queues.pop(session_key, None)
    for entry in targets:
        entry.result = choice
        entry.event.set()
    return len(targets)
```

### 4.2 Approval Choices

The canonical choices are:
- **`once`** — allow this single invocation
- **`session`** — allow for this session (adds pattern to `_session_approved`)
- **`always`** — permanently allowlist (adds to persistent allowlist)
- **`deny`** — reject

### 4.3 TUI Frontend (`ui-tui/src/app/useMainApp.ts:681-689`)

```typescript
const answerApproval = useCallback(
  (choice: string) =>
    respondWith('approval.respond', { choice, session_id: ui.sid }, () => {
      patchOverlayState({ approval: null })
      patchTurnState({ outcome: choice === 'deny' ? 'denied' : `approved (${choice})` })
      patchUiState({ status: 'running…' })
    }),
  [respondWith, ui.sid]
)
```

### 4.4 Emacs Frontend (`hermes-prompts.el:61-80`) — Fixed 2026-05-14

```elisp
(defun hermes--prompt-approval (sid rid payload)
  "Ask the user to allow/deny a tool call, then dispatch `approval.respond'.
Canonical choices match the TUI: once, session, always, deny."
  (let* ((cmd (hermes--prompts-get payload "command"))
         (desc (hermes--prompts-get payload "description"))
         (prompt (format "Approve%s%s? "
                         (if desc (format " (%s)" desc) "")
                         (if cmd (format " [%s]" cmd) "")))
         (choice (condition-case _
                     (read-multiple-choice
                      prompt
                      '((?o "once"    "allow this single invocation")
                        (?s "session" "allow for this session")
                        (?a "always"  "allowlist this pattern permanently")
                        (?n "no"      "deny")))
                   (quit '(?n "no" "deny"))))
         (key (car choice))
         (resp (pcase key
                 (?o "once")
                 (?s "session")
                 (?a "always")
                 (_  "deny"))))
    (hermes-rpc-request
     "approval.respond"
     (list :session_id sid :request_id rid :choice resp))))
```

### 4.5 Approval Gap Analysis

| Issue | Detail | Severity | Status |
|-------|--------|----------|--------|
| ~~Non-canonical choice values~~ | ~~Sends `"allow"` instead of `"once"` / `"session"`~~ | ~~**High**~~ | **Fixed 2026-05-14** |
| ~~Missing `always` choice~~ | ~~No way to permanently allowlist a pattern~~ | ~~**High**~~ | **Fixed 2026-05-14** |
| ~~`all` param semantics~~ | ~~`all: true` with `"allow"` approximates `session`, but is ambiguous~~ | ~~**Medium**~~ | **Fixed 2026-05-14** — `all` param removed entirely |
| **No `outcome` tracking** | Turn state does not record approval outcome | Low | Open |
| **Minibuffer UX** | `read-multiple-choice` with `?o/?s/?a/?n` matches TUI keybindings | Low | Fixed 2026-05-14 |

---

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

**After (v1):** Tools were rendered as **separate Org sub-headlines** after the text region, independent of `stream-text`. Thinking/reasoning were managed as separate marker-tracked blocks before text.

**After (v2 — segmented):** All content lives in a single `segments` vector as typed `hermes-segment` objects. The renderer does a **full rewrite of the segment region** on every stream update (Option A from the plan). No stable/unstable split, no per-block markers:

- `tool.generating` → reducer creates tool segment; renderer formats as `*** name (running…)`
- `tool.start` → reducer updates segment in-place; renderer rewrites all segments
- `tool.complete` → reducer updates status/output/etc; renderer rewrites
- `thinki.ng.delta` / `reasoning.delta` → creates/appends typed segments
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
| **No `todos` support** | ✅ Fixed — stored in `tool.todos`, rendered as `:TODOS:` checklist | **Low** |
| **No `tool.started` event** | This is a Python-side event type that maps to `tool.progress` emission | N/A |
| **Tool context missing** | TUI shows tool context (args preview); Emacs does not | Low |

---

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

### 6.3 Emacs Gap

**Zero support.** No state, no renderer, no RPC calls. Delegation tasks run silently.

---

## 7. Gateway Lifecycle Deep Dive

### 7.1 Startup Sequence

**TUI:**
1. Spawn gateway process
2. Wait for `gateway.ready`
3. Apply skin
4. Fetch `commands.catalog`
5. Check `STARTUP_RESUME_ID` env → resume if set
6. Else check `display.tui_auto_resume_recent` config → resume most recent
7. Else create new session
8. Schedule `STARTUP_QUERY` / `STARTUP_IMAGE` if set

**Emacs:**
1. Spawn gateway process (`hermes-rpc-start`)
2. Wait for `gateway.ready`
3. Set connection=connected, store skin
4. Create new session (`session.create`)
5. Fetch `commands.catalog` after session creation

**Gap:** No auto-resume, no startup prompt, no `STARTUP_RESUME_ID` handling.

### 7.2 Error Handling

**TUI:**
- `gateway.start_timeout` → detailed error with stderr tail
- `gateway.protocol_error` → warning status + activity
- `gateway.stderr` → activity items in turn feed
- `error` → resets turn state, pushes activity, handles "No provider" setup overlay

**Emacs:**
- `gateway.start_timeout` → no handler
- `gateway.protocol_error` → `message` call only
- `gateway.stderr` → separate hook, never in chat buffer
- `error` → appends system message, does not reset turn state

**Gap:** Critical debug info is invisible or insufficient.

---

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
- ~6-7 hours total implementation time (per PLAN-segmented-stream.md)

---

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

## 10. Detailed Gap Matrix

### 10.1 Events

| Category | Event | Emacs | TUI | Gap Level |
|----------|-------|-------|-----|-----------|
| **Lifecycle** | `gateway.ready` | Partial | Full | Medium |
| | `skin.changed` | Full | Full | None |
| | `session.info` | Full | Full | None |
| | `gateway.start_timeout` | Full | Full | None |
| | `gateway.protocol_error` | Full | Full | None |
| | `gateway.stderr` | Full | Full | None |
| **Stream** | `message.start` | Full | Full | None |
| | `message.delta` | Full | Full | None |
| | `message.complete` | Full | Full | None |
| | `thinking.delta` | Full | Full | None |
| | `reasoning.delta` | Full | Full | None |
| | `reasoning.available` | Full | Full | None |
| **Status** | `status.update` | Partial | Full | Low |
| **Tools** | `tool.generating` | Full | Full | None |
| | `tool.start` | Full | Full | None |
| | `tool.progress` | Full | Full | None |
| | `tool.complete` | Full | Full | None |
| **Blocking** | `approval.request` | Full | Full | None |
| | `clarify.request` | Full | Full | None |
| | `sudo.request` | Full | Full | None |
| | `secret.request` | Full | Full | None |
| **Other** | `error` | Full | Full | None |
| | `browser.progress` | No-op | Full | Low |
| | `voice.status` | No-op | Full | Low |
| | `voice.transcript` | No-op | Full | Low |
| | `background.complete` | Full | Full | None |
| | `review.summary` | Full | Full | None |
| **Subagent** | `subagent.spawn_requested` | Missing | Full | **High** |
| | `subagent.start` | Missing | Full | **High** |
| | `subagent.thinking` | Missing | Full | Medium |
| | `subagent.tool` | Missing | Full | Medium |
| | `subagent.progress` | Missing | Full | Low |
| | `subagent.complete` | Missing | Full | Medium |

### 10.2 RPC Methods

| Method | Emacs | TUI | Gap Level |
|--------|-------|-----|-----------|
| `session.create` | Yes | Yes | None |
| `session.resume` | No | Yes | Medium |
| `session.close` | Yes | Yes | None |
| `session.interrupt` | Yes | Yes | None |
| `session.steer` | No | Yes | **High** |
| `session.branch` | No | Yes | Low |
| `session.compress` | No | Yes | Low |
| `session.undo` | No | Yes | Low |
| `session.save` | No | Yes | Low |
| `session.most_recent` | No | Yes | Medium |
| `prompt.submit` | Yes | Yes | None |
| `prompt.background` | No | Yes | Medium |
| `approval.respond` | Partial | Yes | **High** |
| `clarify.respond` | Yes | Yes | None |
| `sudo.respond` | Yes | Yes | None |
| `secret.respond` | Yes | Yes | None |
| `slash.exec` | Yes | Yes | None |
| `command.dispatch` | No | Yes | Low |
| `commands.catalog` | Yes | Yes | None |
| `config.get` / `config.set` | No | Yes | Low |
| `tools.configure` | No | Yes | Low |
| `reload.mcp` | No | Yes | Low |
| `delegation.status` | No | Yes | Medium |
| `spawn_tree.*` | No | Yes | Low |
| `rollback.*` | No | Yes | Low |
| `skills.*` | No | Yes | Low |
| `voice.*` | No | Yes | Low |
| `image.attach` / `clipboard.paste` | No | Yes | Low |
| `shell.exec` | No | Yes | Medium |
| `browser.manage` | No | Yes | Low |
| `terminal.resize` | No | Yes | Low |

---

## 11. Implementation Plan

### Phase 0 — Foundational (Completed 2026-05-14)

**Files:** `hermes-state.el`, `hermes-render.el`

1. **Text/reasoning/tool rendering basics**
   - Thinking/reasoning rendered as `#+begin_example` Org blocks
   - Tools rendered as `*** name (status)` Org sub-headlines
   - `hermes--format-thinking-block`, `hermes--format-tool` created

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
   - All events (`message.delta`, `thinking.delta`, `reasoning.delta`, `tool.*`) create/append typed segments
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
   - Persistent reducer: when `"error"` arrives, commits in-flight stream as partial assistant message, appends error system message, clears stream
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
   - Renderer renders as `:TODOS:` drawer with checklist

### Phase 3 — Subagent Support

**Files:** `hermes-state.el`, `hermes-render.el`

1. **Add subagent state**
   - New struct: `hermes-subagent` with `id`, `goal`, `status`, `thinking`, `tools`, `notes`, `summary`, `duration`
   - Add `subagents` vector to `hermes-stream`

2. **Handle 6 subagent events**
   - Reducer: upsert subagent in `stream.subagents`
   - UI reducer: set status text for active subagents

3. **Renderer**
   - Insert subagent subtrees under assistant headline
   - Show goal, status, thinking, tools, notes

### Phase 4 — Gateway Lifecycle ✅ Completed

**Files:** `hermes-state.el`, `hermes-render.el`, `hermes-mode.el`, `hermes-rpc.el`

1. **Handle `gateway.stderr`** ✅
   - Reducer appends `[stderr] <line>` system message (clipped to 120 chars)
   - Routed from `hermes-rpc-stderr-functions` hook

2. **Handle `gateway.start_timeout`** ✅
   - Sentinel detects gateway exit during `starting` state
   - Collects up to 8 stderr tail lines
   - Reducer appends `[gateway start timeout]` system message
   - UI reducer sets error status text

3. **Handle `gateway.protocol_error`** ✅
   - Reducer appends `[protocol noise] <preview>` system message
   - UI reducer sets warning status text
   - Routed from `hermes-rpc-protocol-error-functions` hook

4. **Handle `background.complete`** ✅
   - Reducer appends `[bg <id>] <text>` system message

5. **Handle `review.summary`** ✅
   - Reducer appends `[review] <text>` system message

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

## 12. References

### Key Files in Official TUI

| File | Purpose |
|------|---------|
| `ui-tui/src/app/createGatewayEventHandler.ts` | Main event handler (33 event types) |
| `ui-tui/src/app/useMainApp.ts` | Main app hook, action callbacks, RPC calls |
| `ui-tui/src/app/interfaces.ts` | State shape definitions |
| `ui-tui/src/app/overlayStore.ts` | Overlay state management |
| `ui-tui/src/components/prompts.tsx` | Approval/clarify UI components |
| `ui-tui/src/components/appOverlays.tsx` | Overlay dispatch |
| `tui_gateway/server.py` | Gateway RPC methods, event emission, session mgmt |
| `tui_gateway/entry.py` | Gateway entry point, cold-start guards |
| `tools/approval.py` | Approval detection, prompting, session state, resolution |

### Key Files in Emacs Frontend

| File | Purpose |
|------|---------|
| `hermes-rpc.el` | JSON-RPC transport, process lifecycle |
| `hermes-events.el` | Event/method name registry |
| `hermes-state.el` | State atoms, reducer, structs |
| `hermes-render.el` | Diff-based Org buffer renderer |
| `hermes-mode.el` | Major mode, event routing, entry points |
| `hermes-prompts.el` | Minibuffer handlers for blocking prompts |
| `hermes-input.el` | Input queue, slash commands, history |
| `hermes-sessions.el` | Session list sidebar |
| `hermes-skin.el` | Gateway skin → face remapping |
| `hermes-md.el` | Markdown→Org converter |
| `hermes-compose.el` | Multi-line composer |
| `hermes-dashboard.el` | Landing dashboard |

---

*Document generated from analysis of `hermes-agent` commit (May 2026) and `emacs-hermes` codebase.*
