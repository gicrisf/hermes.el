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
  usage               ; hash-table or nil — accumulated tokens/cost
  stream              ; hermes-stream or nil (in-flight only)
  pending             ; hermes-pending or nil
  (pending-turns [])  ; vector of hermes-message — drained into buffer by renderer
  slash-catalog
  (queue nil)
  (history nil)       ; minibuffer recall ring (kept in state for speed)
  skin)
```

**Note:** `messages` was removed. Committed history lives in the Org buffer; `pending-turns` is a transient staging vector drained by the renderer on every tick.

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
  segments    ; vector of hermes-segment — committed turn narrative
  usage timestamp
  subagents)  ; vector of hermes-subagent — delegation tree
```

The `text`, `thinking`, `reasoning`, and `tools` deprecated slots were removed in the buffer-as-truth refactor. Text is derived on demand by concatenating `text`-type segments. Irreplaceable structured data (tool calls, image metadata, usage, subagents) is serialized to a `:HERMES_META:` Elisp plist drawer at the end of each turn's Org subtree. Text-only turns omit the drawer entirely.

#### Stream State (`hermes-stream`)
```elisp
(cl-defstruct hermes-stream
  segments    ; vector of hermes-segment, ordered by arrival
  tools       ; DEPRECATED — kept for backward compat
  subagents)  ; vector of hermes-subagent — live delegation tree
```

#### Segment State (`hermes-segment`)
```elisp
(cl-defstruct hermes-segment
  type        ; 'text | 'reasoning | 'tool | 'system  ('thinking is UI-only, not persisted)
  content     ; string for text/reasoning/system; hermes-tool for tool segments
  id)         ; unique segment id (for stable updates)
```

#### Tool State (`hermes-tool`)
```elisp
(cl-defstruct hermes-tool
  id name
  status      ; 'generating | 'running | 'complete | 'error
   context     ; tool args preview from tool.start — body-canonical
   preview     ; live preview from tool.progress
   inline-diff ; diff output from tool.complete — body-canonical
   todos       ; list of hash-tables ("content" "status" "id") — body-canonical
   output      ; string or nil — body-canonical
   error       ; string or nil — body-canonical
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
| **Canonical history** | `messages` array in TUI state | **Org buffer** — text parsed from visible headings; `:HERMES_META:` drawer carries irreplaceable structured data |
| **Busy flag** | `uiState.busy` — explicit boolean | Implicit: `(hermes-state-stream state)` |
| **Activity feed** | `turnState.activity` — array of items, capped at 8 | Not present |
| **Tool active list** | `turnState.tools` — active tools with context, tokens | `segments` — all tools in stream as typed tool segments |
| **Tool previews** | Active tool context updates (throttled) | Stored in tool segment's `hermes-tool-preview`; also in `tool-previews` (dead state) |
| **Subagents** | Full delegation tree with depth, status, notes | ✅ `hermes-subagent` struct on `stream.subagents` / `message.subagents`. 6 reducer events, rendered as `****` Org subtrees after segment region. Copied into committed messages on `message.complete`. |
| **Todos** | `turnState.todos` — active todo list | Not present |
| **Turn trail** | `turnState.turnTrail` — transient trail lines | Not present |
| **Segments** | `streamSegments` + `streamPendingTools` — structured | ✅ `stream.segments` vector of typed `hermes-segment` objects. Renderer does full segment rewrite on each update. |
| **Reasoning tokens** | `reasoningTokens`, `toolTokens` | Not present |
| **Usage merging** | Merges usage on every `session.info` | ✅ Merged into `hermes-state-usage`; also accumulated from `message.complete` |
| **Background tasks** | `bgTasks: Set<string>` | Not present |
| **Overlay store** | Multiple overlay types simultaneously possible | Single `pending` slot (replaces wholesale) |
| **Outcome** | `turnState.outcome` — e.g. "denied" | Not present |

---
