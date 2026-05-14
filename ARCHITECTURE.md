# emacs-hermes — Architecture

## Overview

emacs-hermes is an Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
It communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway` process.
The conversation buffer is a read-only `org-mode` derived buffer with hierarchical
headlines, property drawers, and Org IDs for cross-referencing.

---

## Data Flow

```
Gateway (Python subprocess)
    │
    │  NDJSON over stdio (jsonrpc=2.0, method="event")
    ▼
hermes-rpc.el  ──hermes-rpc-event-functions──►  hermes-mode.el: route-event
                                                      │
                                                      │  dispatch
                                                      ▼
                                              hermes-state.el: hermes-dispatch
                                                      │
                                                      │  pure reducer
                                                      ▼
                                              hermes--state (swap)
                                                      │
                                                      │  run-hook
                                                      ▼
                                              hermes--render (hermes-render.el)
                                                      │
                                                      │  diff & edit
                                                      ▼
                                              Org buffer (*hermes:SID*)
```

**Output path:**

```
Emacs (user-input) → hermes-input.el → hermes-dispatch (:user-submit)
    → hermes-rpc.el (prompt.submit request) → Gateway (stdin)
```

---

## File Inventory

| File | Lines | Role |
|------|-------|------|
| `hermes-rpc.el` | 343 | JSON-RPC 2.0 transport (make-process, NDJSON, pending map) |
| `hermes-state.el` | 399 | Buffer-local state atoms + pure reducer |
| `hermes-render.el` | 409 | Diff-based Org buffer renderer |
| `hermes-mode.el` | 225 | org-mode derived major mode + event routing + entrypoint |
| `hermes-input.el` | 209 | Input queue, slash commands, history |
| `hermes-prompts.el` | 116 | Minibuffer prompt handlers (approval, clarify, secret, sudo) |
| `hermes-compose.el` | 81 | Multi-line org-mode composer |
| `hermes-sessions.el` | 174 | tabulated-list-mode sessions sidebar |
| `hermes-skin.el` | 83 | Gateway skin → face-remap |
| `hermes-md.el` | 164 | Markdown → Org syntax converter |
| `hermes-dashboard.el` | 393 | Vanilla Emacs dashboard (`*Hermes*`) |
| `hermes-events.el` | 97 | Event/method name registry |
| `doom-dashboard-hermes.el` | 442 | Standalone Doom-styled dashboard (`*doom-hermes*`) |
| `doom-hermes.el` | 46 | Evil bindings + SPC h leader prefix |
| `doom-hermes-theme.el` | 161 | Hermes-branded dark theme |
| **Total** | **~3,342** | |

---

## Core State (`hermes-state.el`)

### Structs

```
hermes-state
├── connection        :: 'disconnected | 'connecting | 'connected
├── session-id        :: string or nil     (set by session.create response)
├── session-info      :: hash-table or nil (set by session.info event)
├── messages []       :: vector of hermes-message (COMMITTED messages only)
├── stream            :: hermes-stream or nil
├── pending           :: hermes-pending or nil (blocking prompt)
├── slash-catalog     :: from commands.catalog response
├── queue []          :: queued user submissions (when stream is live)
├── history []        :: input history (capped at hermes-history-max)
└── skin              :: from gateway.ready payload

hermes-message
├── kind    :: 'user | 'assistant | 'system
├── text    :: markdown string
├── tools   :: vector of hermes-tool (tool trail)
├── usage   :: token usage
└── timestamp

hermes-stream
├── text        :: accumulated message.delta text
├── thinking    :: accumulated thinking.delta text
├── reasoning   :: accumulated reasoning.delta text
└── tools []    :: vector of hermes-tool (in-flight tools)

hermes-tool
├── id       :: string (tool_id from gateway, or falls back to name)
├── name     :: string
├── status   :: 'generating | 'running | 'complete | 'error
├── output   :: string or nil
├── error    :: string or nil
└── duration :: number or nil

hermes-pending
├── kind       :: 'approval | 'clarify | 'secret | 'sudo
├── request-id :: string
└── payload    :: hash-table
```

### Dispatch

```elisp
(defun hermes-dispatch (msg)
  "Reduce MSG into the persistent state and notify subscribers."
  (let* ((old hermes--state)
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (setq hermes--state new)
      (run-hook-with-args 'hermes-state-change-hook old new))))
```

Key property: state is only swapped when the reducer returns a structurally new value
(using `hermes--with-copy` which does a shallow copy of the struct). If the reducer
returns the same object, hooks don't fire and no re-render occurs.

### Reducer pattern

The reducer uses `pcase` on the event type. Most events follow the copy-and-setf pattern:

```elisp
(hermes--with-copy state hermes-state-copy s
  (setf (hermes-state-connection s) 'connected))
```

`hermes--with-copy` copies the struct and binds it to `s`, runs body for side effects,
returns the copy. All events return the copy (or `state` unchanged for no-ops).

---

## Transport (`hermes-rpc.el`)

Spawns `python -m tui_gateway.entry` via `make-process` with a process filter that
parses newline-delimited JSON-RPC 2.0 frames.

### Request flow

```
hermes-rpc-request (method, params, callback)
  │
  │  assign auto-incrementing id
  │  store (callback . method) in pending-map
  │
  ▼
send {"jsonrpc":"2.0","id":N,"method":"<method>","params":{...}}
  │
  │  response arrives:
  │    {"jsonrpc":"2.0","id":N,"result":{...}}
  │    or {"jsonrpc":"2.0","id":N,"error":{...}}
  │
  ▼
lookup id in pending-map → fire callback with (result error)
```

### Event flow

```
Gateway sends:
  {"jsonrpc":"2.0","method":"event",
   "params":{"type":"message.delta","session_id":"abc","payload":{...}}}
  │
  ▼
Process filter → parse JSON → dispatch to hermes-rpc-event-functions
  │
  ▼
hermes--route-event (hermes-mode.el):
  1. If gateway.ready/skin.changed: cache payload globally
  2. Lookup session buffer by session-id
  3. hermes-dispatch in that buffer's context
```

### Long handlers

Methods like `shell.exec`, `session.resume` are processed asynchronously by the
gateway's thread pool. Their responses can interleave with other frames. The pending
map handles this correctly because each request has a unique id.

---

## Rendering (`hermes-render.el`)

### Two hooks

```elisp
(add-hook 'hermes-state-change-hook    #'hermes--render        nil t)  ; persistent
(add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     nil t)  ; header line
```

The renderer compares old and new states (`eq` on each slot) and dispatches to
sub-renderers:

```elisp
(defun hermes--render (old new)
  (with-silent-modifications
    (save-excursion
      ;; 1. Messages grew → append committed messages
      ;; 2. Stream lifecycle (begin / commit / update)
      ;; 3. Session info / connection → header line + root properties
      ;; 4. Queue length changed → refresh header-line
      ))
  (when (derived-mode-p 'org-mode)
    (org-element-cache-reset)))   ; restore Org cache after silent mods
```

### Streaming (in-flight assistant text)

The assistant's response arrives as a sequence of `message.delta` events. The buffer
region between `hermes--stream-stable-end` and `hermes--stream-end` holds text that
may still change. Text before `stable-end` is frozen ("stable").

**Markers:**

```
hermes--stream-headline-marker   → start of ** assistant headline
hermes--stream-content-start     → where body text begins (after property drawer)
hermes--stream-stable-end        → end of frozen / start of unstable
hermes--stream-end               → end of all in-flight text
hermes--stream-tool-markers      → alist (tool-id . marker) for tool subtrees
```

**The rewrite function:**

```elisp
(defun hermes--rewrite-stream (text)
  (let* ((boundary (hermes--stable-boundary text))  ; last \n\n outside fences
         (already  (- stable-end content-start))     ; chars already in stable
         (stable   (substring text 0 boundary))
         (unstable (substring text boundary))
         (new-stable-substring (substring stable already))
         (old-unstable-len (- stream-end stable-end)))
    ;; 1. Insert newly-stable chunk (converted to Org)
    (when (> (length new-stable-substring) 0)
      (goto-char stable-end)
      (insert (hermes-md-to-org new-stable-substring))
      (set-marker stable-end (point)))
    ;; 2. Delete exactly the old unstable chars
    (goto-char stable-end)
    (delete-char old-unstable-len)
    ;; 3. Insert new unstable text
    (insert unstable)))
```

Key design decisions:
- `delete-char N` removes exactly N characters (the old unstable text).
  Tools that sit beyond `stream-end` are untouched. This replaced a previous
  `delete-region stable-end stream-end` which could wipe tools inserted after the text.
- `already` is computed from `content-start`, NOT from the headline start,
  so the property drawer between the heading and body text is not counted as stream text.
- Stable chunks are converted through `hermes-md-to-org` before insertion;
  unstable chunks stay as raw markdown until they cross a `\n\n` boundary or commit.

### Stream lifecycle

```
message.start → hermes--stream-begin
  Insert ** assistant heading + property drawer + :hermes: tag + :ID:
  Set content-start, stable-end, stream-end markers

tool.generating / tool.complete → hermes--render-stream-tools
  Insert or rewrite *** tool subtrees at point-max.
  stream-end (t insertion type) follows tool insertions but tools are
  beyond stream-end (stable text is between stable-end and stream-end).

message.delta → hermes--rewrite-stream (via hermes--stream-update)
  Rewrite unstable region. delete-char removes only old unstable text.

message.complete → hermes--stream-commit
  Stamp :ID: on tool subtrees and assistant headline.
  Convert unstable tail from markdown to Org.
  Drop all stream markers.
  Append user message to committed messages vector.
  Stream set to nil.
```

### Tool subtrees

Tools are inserted AT point-max, which is AFTER `hermes--stream-end`.
The `delete-char` in `hermes--rewrite-stream` removes only the characters
between `stable-end` and `stream-end`, leaving tools intact.

When tools update (progress → complete), `hermes--rewrite-tool-subtree` finds
the tool by its marker in `hermes--stream-tool-markers` and replaces its content
in place.

### Tick integration

`org-element-cache-reset` is called at the end of every render (when
`derived-mode-p` is `org-mode`). This compensates for the suppression of
Org change hooks by `with-silent-modifications`.

---

## Major Mode (`hermes-mode.el`)

```elisp
(define-derived-mode hermes-mode org-mode "Hermes"
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq buffer-read-only t)
  (hermes-state-init)
  (insert "#+TITLE: hermes\n")
  ;; Register hooks...
  )
```

### Event routing

```elisp
hermes--install-hooks
  ├── hermes-rpc-event-functions   → hermes--route-event
  ├── hermes-rpc-event-functions   → hermes-sessions--refresh-if-open
  ├── hermes-rpc-connection-functions → hermes--route-connection
  └── hermes-rpc-connection-functions → hermes-sessions--refresh-if-open
```

`hermes--route-event` dispatches events into the correct session buffer:
- If `session-id` is known → dispatch in that buffer via `with-current-buffer`
- If `session-id` is nil (gateway.ready, skin.changed) → broadcast to all buffers

### Entry point

```
M-x hermes → hermes → hermes-new-session
  1. Start gateway if not running (hermes-rpc-connect)
  2. Send session.create request
  3. On success: generate-new-buffer "*hermes:SID*"
  4. Activate hermes-mode in that buffer
  5. Replay last-gateway-ready event
  6. Pop dashboard
  ```

---

## Input Pipeline (`hermes-input.el` + `hermes-prompts.el`)

### `hermes-send`

```
C-c C-i → hermes-send → hermes-input-send (hermes-input.el)
  │
  │  Read input via read-string (with history and slash-completion)
  │
  ├── Input starts with "/" → hermes-input-dispatch-slash
  │     → slash.exec RPC (bypasses queue, transcript, history)
  │
  └── Normal input → hermes-dispatch :user-submit
        │
        ├── Optimistic commit to messages
        ├── Push onto history ring
        │
        ├── Stream is idle → hermes-rpc-request "prompt.submit" immediately
        │
        └── Stream is busy → append to queue; drain hook fires
              prompt.submit when stream clears (message.complete)
```

### Blocking prompts

`hermes-prompts.el` watches `hermes-state-pending` via a change hook.
When pending becomes non-nil, it schedules a minibuffer interaction
(via `run-at-time` 0 — after the renderer finishes), dispatches the
matching `.respond` RPC, and clears the pending slot.

Events handled: `approval.request`, `clarify.request`, `sudo.request`,
`secret.request`.

---

## Multi-line Composer (`hermes-compose.el`)

`C-c C-l` opens a `*hermes-compose*` buffer in `org-mode`.
Keybindings:
- `C-c C-c` → send content through `hermes-input-send`, kill buffer
- `C-c C-k` → kill buffer (cancel)

The composer is a clean org-mode buffer (not hermes-mode derived) to avoid
polluting the conversation buffer's state.

---

## Sessions Sidebar (`hermes-sessions.el`)

`*Hermes Sessions*` is a `tabulated-list-mode` buffer listing all sessions
in `hermes--session-buffers`:

| Column | Content |
|--------|---------|
| Session ID | short (8 chars) |
| Model | from session-info |
| Status | from connection state |

Keybindings: `RET` to switch, `k` to close session, `+` to create new, `g` refresh.

Auto-refreshes on every incoming event (cheap because short-circuits when
the sidebar isn't open).

---

## Markdown→Org (`hermes-md.el`)

Applied to stable chunks and the unstable tail on commit.

Pipeline:
1. Fenced code blocks (```````` → `#+begin_src` / `#+begin_example`)
2. Table separators (`|---|---|` → `|---+---|`)
3. ATX headings (`# text` → `** text`, demoted)
4. Inline: `**bold**` → `*bold*`
5. Inline: `` `code` `` → `~code~`
6. Inline: `[label](url)` → `[[url][label]]`
7. Inline: `*italic*` / `_italic_` → `/italic/`

Protected regions prevent nested passes from corrupting fenced code bodies.

---

## Skin Engine (`hermes-skin.el`)

The gateway emits a `skin` payload on `gateway.ready` (and `skin.changed`)
with a `colors` hash. The skin module remaps buffer-local faces to these
colors:

```elisp
hermes-user-face      → user headline
hermes-assistant-face → assistant headline
hermes-system-face    → system headline
hermes-tool-face      → tool headline
```

---

## Dashboard (`hermes-dashboard.el`)

The vanilla dashboard (`*Hermes*`) is a `special-mode` buffer shown by
`M-x hermes`. Sections:
1. Unicode "HERMES" block-art logo with connection status
2. Session information (model, session ID, tools/skills)
3. Action menu (send, compose, sessions, refresh, quit)

### Doom Dashboard (`doom-dashboard-hermes.el`)

Standalone alternative (`*doom-hermes*`), Doom-styled. Centering via
window margins + vertical pad. Debounced refresh (0.1s idle timer).
Clickable menu with auto-detected keybindings. Independent faces
inheriting from font-lock faces.

---

## Org Buffer Structure

### Final hierarchy after each turn

\```
#+TITLE: hermes

* user: what is 2+2?                                    :hermes:
:PROPERTIES:
:HERMES_SESSION: a1b2c3d4
:HERMES_MODEL: nvidia/nemotron-3
:HERMES_TIMESTAMP: 2026-05-14T03:56:12+0200
:ID: abc123
:END:
what is 2+2?

** assistant                                            :hermes:
:PROPERTIES:
:HERMES_TIMESTAMP: 2026-05-14T03:56:12+0200
:ID: def456
:END:
Sure, 2+2 is 4.
*** calculator (0.3s)                                 :hermes-tool:
:PROPERTIES:
:tool_id:  calc-01
:status:   complete
:duration: 0.3
:END:
#+begin_example
4
#+end_example

* user: now 3+3?                                        :hermes:
:PROPERTIES:
:HERMES_SESSION: a1b2c3d4
:HERMES_MODEL: openai/gpt-4o       ← model changed
:HERMES_TIMESTAMP: 2026-05-14T03:57:00+0200
:ID: ghi789
:END:
now 3+3?

** assistant                                            :hermes:
:PROPERTIES:
:HERMES_TIMESTAMP: 2026-05-14T03:57:00+0200
:ID: jkl012
:END:
It's 6.
\```

### Property rules

| Heading | `HERMES_SESSION` | `HERMES_MODEL` | `HERMES_TIMESTAMP` | `:ID:` |
|---------|:---:|:---:|:---:|:---:|
| `* user` | yes | yes | yes | `org-id-get-create` |
| `** assistant` | no | no | yes | `org-id-get-create` |
| `*** tool` | no | no | no | `org-id-get-create` |
| `* system` | yes | yes | yes | `org-id-get-create` |

`HERMES_MODEL` can be empty on the first turn if `session.info` hasn't arrived yet.

### Tag rules

| Heading | Tag |
|---------|-----|
| `* user` | `:hermes:` |
| `** assistant` | `:hermes:` |
| `*** tool` | `:hermes-tool:` |
| `* system` | `:hermes:` |

### Heading truncation

- User/system heading shows the first line of message text (no trailing newline)
- Assistant heading always shows bare `** assistant` (no truncation)

---

## Doom Integration

### Evil Bindings (`doom-hermes.el`)

The `SPC h` leader prefix handles collision detection and provides:

| Key | Action |
|-----|--------|
| `SPC h d` | Dashboard (`doom-dashboard-hermes`) |
| `SPC h s` | Start / send prompt |
| `SPC h i` | Start (alias) |
| `SPC h n` | New session |
| `SPC h c` | Multi-line composer |
| `SPC h l` | Session list sidebar |
| `SPC h g` | Go to primary session buffer |
| `SPC h k` | Interrupt primary session |

In `hermes-mode` normal state:
| Key | Action |
|-----|--------|
| `C-c C-i` | Send prompt |
| `C-c C-k` | Interrupt |
| `C-c C-l` | Multi-line compose |

### Theme (`doom-hermes-theme.el`)

| Role | Hex | Source |
|------|-----|--------|
| Background | `#041c1c` | Hermes web dashboard |
| Foreground | `#FFF8DC` | CLI cornsilk |
| Gold | `#FFD700` | CLI primary |
| Amber | `#FFBF00` | CLI accent |
| Bronze | `#CD7F32` | CLI border |
| Teal | `#4EC9B0` | Success |
| Coral | `#FF6B6B` | Error |
| Yellow | `#FFD93D` | Warning |

---

## Known Issues & Design Decisions

### Tool ID fallback

The gateway sends `tool.generating` and `tool.complete` with `{"name":"terminal"}`
— no `"tool_id"` key. The reducer falls back to `(or tool_id id name)` to
identify tools. Currently each tool name is unique per turn, so `name` works.

### delete-char vs delete-region

`delete-region stable-end stream-end` could delete tool subtrees because
`hermes--stream-end` has t insertion type and follows tool insertions at
point-max. `delete-char old-unstable-len` removes exactly the right number
of characters and leaves tools intact.

### org-element-cache-reset on every render

`with-silent-modifications` suppresses Org change hooks. The cache reset
at the end of every render ensures Org operations (org-id-get-create,
org-entry-put) work correctly on the next call. This is safe because
hermes buffers are modest in size.

### hermes--stream-content-start marker

The `already` offset in `hermes--rewrite-stream` measures how many
characters of body text are already committed to the stable region.
`content-start` is set after the assistant's property drawer, so the
drawer content is not counted as body text.

### Guarding org-id-get-create

All `org-id-get-create` calls are guarded with `(when (derived-mode-p 'org-mode) ...)`
to prevent Org warnings on fundamental-mode temp buffers in tests.

### `with-silent-modifications` in render

All buffer edits run inside `with-silent-modifications` and `save-excursion`
to prevent:
- Org change hooks from firing (cache goes stale, reset at end)
- Point jumping during streaming
- Modification state changes in the read-only buffer

### Shallow copies in reducers

`hermes--with-copy` uses `copy-<struct>` from `cl-defstruct`, which is a
shallow copy. This means the tools vector is shared between old and new
streams during `thinking.delta` / `reasoning.delta` — only `tool.generating`
and `tool.complete` create new tool vectors via `hermes--vector-append` or
`copy-sequence`. The `eq` comparison in `hermes--stream-update` correctly
detects tool changes because these events produce structurally new vectors.

### Unhandled events

Events like `tool.start`, `reasoning.available`, `status.update` are not
handled in the reducer. They return `state` unchanged, which means no re-render.
This is intentional — they are informational and don't affect the buffer's
visible content.
