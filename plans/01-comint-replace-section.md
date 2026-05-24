# PLAN 01: Replace hermes-section with hermes-comint

## Goal

Replace `hermes-section.el` (magit-section conversation viewer) with
`hermes-comint.el` (comint-based viewer with inline prompt).  The
comint viewer becomes the primary non-org conversation interface:
`M-x hermes` opens it by default everywhere except inside an
`org-mode` buffer.  The bench stays org-viewer-only — the comint
viewer has its own built-in prompt line.

`hermes-comint.el` already exists at HEAD (802 lines, commit
`f0c7a76`).  This plan covers the integration gaps that prevent it
from being a first-class viewer alongside (and replacing) the
magit-section view.

## 1. Architecture: three viewers → two viewers

```
hermes--sessions[sid].turns  ← canonical event log (sole authority)
       ↕                     ↕
  comint buffer           org buffer
  (read-only history,     (editable org-mode,
   inline prompt,          bench input surface,
   TEA projection)          body-canonical)
```

Both views **project** the same state.  Neither mutates it directly.
Only `hermes--reduce` modifies state.  The user sends prompts; the
reducer appends to `pending-turns` and `turns`; both views update on
`hermes-state-change-hook`.

Key differences from the old architecture:

| Concept | Old (section) | New (comint) |
|---------|--------------|--------------|
| State projection | magit-section trees via EIEIO classes | Flat text with font-lock-face properties |
| Visibility | magit's section cache (per-message-id) | None — always fully visible |
| Navigation | magit section movement (n/p/tab) | Standard buffer movement + scroll |
| Body rendering | Lazy (washer/thunk on first expand) | Always inserted on state change |
| Prompt input | Minibuffer only (bound to `i`) | Inline prompt at buffer bottom (RET) |
| History ring | None | comint-input-ring (M-p/M-n) |
| Dependencies | magit-section (installed via ELPA) | comint (built-in Emacs) |
| Faces | 22 deffaces (section-specific) | 13 deffaces (comint-specific, 22 total) |

## 2. Why comint over magit-section

1. **No external dependency.**  `comint` ships with Emacs; magit does
   not.  The magit dependency forces every user to install
   `magit-section` before using the non-org viewer.  Comint has zero
   install cost.

2. **Built-in input surface.**  Comint gives us prompt detection,
   input ring (M-p/M-n history), scroll-to-bottom-on-input, and field
   navigation — all without reinventing the bench.  The bench
   (`hermes-bench.el`) is a separate side-window with its own mode,
   keymap, and coordination logic; comint collapses all of that into a
   single buffer.

3. **Closer to a "terminal" feel.**  The magit-section viewer is a
   structured tree browser — useful for navigating large org-mode
   documentation, but overkill for a linear conversation log.  Comint
   feels like a REPL: output scrolls up, prompt stays at the bottom,
   everything is linear.  This matches the mental model of chatting
   with an AI agent.

4. **Simpler rendering.**  The section viewer uses 6 EIEIO classes, a
   visibility cache, washer/thunk deferred body insertion,
   `magit-insert-section-body`, section hooks, and manual highlight
   updates.  The comint viewer uses field properties
   (`read-only`/`field`) and `font-lock-face` — a flat, stateless
   paint model that's trivial to debug and extend.

## 3. Buffer layout

```
┌────────────────────────────────────────────┐
│ header-line:  [bg: 1 running]              │  ← hermes-comint--refresh-header-line
├────────────────────────────────────────────┤
│ > 1 · User · 14:22                         │  ← hermes-comint-face-user
│ What does this code do?                    │
│                                            │
│ ● 2 · Assistant · claude-sonnet · 14:22    │  ← hermes-comint-face-assistant
│ --- Reasoning ---                          │  ← hermes-comint-face-reasoning (italic)
│ The user is asking about...                │
│                                            │
│ Here's what the code does:                 │  ← body text (org-fontified)
│                                            │
│ DONE write_file (1.2s) — Wrote foo.py      │  ← hermes-comint-face-tool
│ │ path: /tmp/foo.py                        │
│ │ content: ...                             │
│                                            │
│ Subagent: analyze codebase (complete)       │  ← hermes-comint-face-subagent
│   thinking: ...                            │
│   tools:                                   │
│     - read(/path/to/file)                  │
│   result: ...                              │
├────────────────────────────────────────────┤
│ > prompt text here█                        │  ← comint-highlight-prompt prefix,
└────────────────────────────────────────────┘   writable input after it
```

Two regions managed by markers:

| Marker | Insertion type | Region purpose |
|--------|---------------|----------------|
| `hermes-comint--output-end` | nil (manual advance) | End of committed read-only output |
| `hermes-comint--prompt-start` | t (advances with insertions) | Start of `> ` prompt prefix |

The `[output-end, prompt-start)` gap is the **pending streaming region**
— painted and repainted during an active stream, then sealed into the
committed region on `message.complete`.

Field properties:
- `[point-min, output-end)` → `field 'output`, `read-only t`
- `[prompt-start, prompt-start+N)` → `field 'input`, `read-only t`, `rear-nonsticky (read-only)` — prompt prefix is protected
- `[prompt-start+N, point-max)` → `field 'input` only (writable by user typing)

The `rear-nonsticky '(read-only)` on the prompt prefix is critical:
typing at the prompt end inherits `field 'input` (so RET detection
works) but **not** `read-only` (so typing actually succeeds).

## 4. Mode definition

```elisp
(define-derived-mode hermes-comint-mode comint-mode "Hermes-Comint"
  "Comint-derived conversation viewer for Hermes sessions.
Read-only output history with a writable prompt at the bottom."
  (setq-local comint-use-prompt-regexp nil)
  (setq-local comint-prompt-regexp
              (concat "^" (regexp-quote hermes-comint--prompt-string)))
  (setq-local comint-input-ring-size 500)
  (setq-local comint-input-ring (make-ring comint-input-ring-size))
  (setq-local comint-input-sender (lambda (_p _s) nil))  ;; no process
  (setq-local comint-eol-on-send nil)
  (setq-local comint-scroll-to-bottom-on-input t)
  (setq-local comint-move-point-for-output 'this)
  (setq-local comint-scroll-show-maximum-output t)
  (visual-line-mode 1)
  (setq-local scroll-conservatively 101)
  (hermes-comint--setup))
```

**`hermes-comint--setup`** (called once on mode activation):
1. Erases the buffer
2. Resets snapshot, stream state, and timer
3. Sets `output-end` to `(point-min)`
4. Inserts the `> ` prompt at `point-max`
5. Registers `#‘hermes-comint--refresh` on `hermes-state-change-hook`
6. Registers `#’hermes-comint--detach` on `kill-buffer-hook`

**Keymap** inherits from `comint-mode-map` and adds:

| Key | Command |
|-----|---------|
| `RET` | `hermes-comint-send` |
| `C-c C-c` | `hermes-comint-send` |
| `M-p` | `hermes-comint-previous-input` |
| `M-n` | `hermes-comint-next-input` |
| `C-c C-k` | `hermes-comint-interrupt` |
| `C-c C-l` | `hermes-compose` (multi-line composer) |
| `C-c C-i` | `hermes-comint-focus-prompt` |
| `g` | `hermes-comint-refresh` (manual full rebuild) |
| `q` | `quit-window` |

## 5. State change routing — the core TEA projection

`hermes-comint--refresh` is the subscriber on `hermes-state-change-hook`.
It receives `(old new)` state atoms and uses
`hermes--on-session-buffer` with the `hermes-comint--buffers` registry
to switch into the correct buffer.  Four dispatch branches:

```
hermes-comint--refresh(old, new)
  │
  ├─ stream began (old-stream=nil, new-stream≠nil)
  │    → hermes-comint--stream-begin  (open streaming region, paint initial turn)
  │
  ├─ stream ended (old-stream≠nil, new-stream=nil)
  │    → hermes-comint--stream-commit (seal pending region, advance output-end)
  │
  ├─ stream delta (both non-nil, different)
  │    → hermes-comint--stream-update (throttled repaint of pending region)
  │
  ├─ committed turns changed, no active stream
  │    → hermes-comint--append-new-turns (insert just the new turns at output-end)
  │
  └─ otherwise (connection, bg, attachments)
       → hermes-comint--refresh-header-line (update header-line only)
```

### Committed turn appends

`hermes-comint--append-new-turns` is an **append, not a full rebuild**.
It compares the length of `hermes-comint--turns-snapshot` against the
current `turns` vector and inserts only new turns at `output-end`,
then advances the marker past the insertion.  This is O(new-turns) per
state tick rather than O(all-turns).

```elisp
(defun hermes-comint--append-new-turns (state)
  (let* ((inhibit-read-only t)
         (turns (hermes-state-turns state))
         (start-idx (if hermes-comint--turns-snapshot
                        (length hermes-comint--turns-snapshot)
                      0)))
    (when (> (length turns) start-idx)
      (save-excursion
        (goto-char (marker-position hermes-comint--output-end))
        (cl-loop for i from start-idx below (length turns)
                 do (hermes-comint--insert-turn (aref turns i) (1+ i)))
        (set-marker hermes-comint--output-end (point))))
    (setq hermes-comint--turns-snapshot turns)))
```

### Streaming lifecycle

**Stream begin:** `hermes-comint--stream-begin` sets
`hermes-comint--stream-active` to t and calls
`hermes-comint--paint-stream`, which builds a temporary
`hermes-message` from the stream (via `hermes--message-from-stream`),
deletes the `[output-end, prompt-start)` gap, and inserts the turn
into that gap.

**Stream update (throttled):** `hermes-comint--stream-update` uses a
cooldown-timer pattern identical to the org renderer's
`hermes-render.el`:
- First delta after cooldown gap → paint immediately, arm timer (40ms).
- Subsequent deltas → stash snapshot in
  `hermes-comint--stream-pending`; timer callback paints the latest.
- Skips painting if buffer is not visible (`hermes--buffer-visible-p`).

**Stream commit:** `hermes-comint--stream-commit` cancels the
throttle timer, sets `hermes-comint--stream-active` to nil, deletes the
pending region, inserts the finalized committed turn from the `turns`
vector (which the reducer populated before clearing `stream`), and
advances `output-end` past it.  This ensures the committed turn carries
final usage/timestamps, not the in-flight stream copy.

### Full rebuild

`hermes-comint-refresh` (bound to `g`) is the panic button: it deletes
everything from `point-min` to `prompt-start`, resets `output-end` to
`(point-min)`, resets the snapshot, and calls
`hermes-comint--load-from-state` to re-insert all turns from scratch.
Used only when the buffer state drifts (rare — almost never needed).

## 6. Turn insertion

`hermes-comint--insert-turn` inserts a single turn as a flat block:

```elisp
(defun hermes-comint--insert-turn (msg index)
  (let* ((kind (hermes-message-kind msg))
         (start (point)))
    ;; Heading line
    (insert (propertize
             (concat (hermes-comint--heading-text msg index) "\n")
             'font-lock-face (hermes-comint--head-face kind)))
    ;; Body (dispatched by kind)
    (pcase kind
      ('user      (hermes-comint--insert-user-body msg))
      ('assistant (hermes-comint--insert-assistant-body msg))
      (_          (hermes-comint--insert-system-body msg)))
    ;; Blank separator
    (unless (bolp) (insert "\n"))
    (insert "\n")
    ;; Lock it
    (hermes-comint--apply-output-props start (point))))
```

Turn types:

| Kind | Heading format | Body content |
|------|---------------|--------------|
| `user` | `> 1 · User · 14:22` | Full text segments + image lines |
| `assistant` | `● 2 · Assistant · claude-sonnet · 14:22` | Reasoning blocks → response text → tool blocks → subagent blocks |
| `system` | `#3 · System · 14:22` | Full text segments |

The assistant body insertion is a four-pass walk over segments:

1. **Reasoning blocks** — each `reasoning` segment renders as
   `--- Reasoning ---` header (italic/comment face) followed by the
   org-fontified reasoning text.  No collapsibility — always visible.

2. **Response text** — all `text` segments joined with newlines and
   org-fontified (markdown→org→faces→font-lock-face).

3. **Tool blocks** — each `tool` segment renders as:
   `DONE tool_name (1.2s) — gateway summary`
   followed by the tool's formatted body (org tables, inline diffs,
   etc. from `hermes-tool-formatters`).  Status keywords (`DONE`,
   `ERROR`, `RUNNING`) have distinct faces.

4. **Subagent blocks** — each subagent renders its goal, status,
   thinking, notes, tool usage list, and result summary.

### Fontification pipeline

Since `comint-mode` buffers disable syntactic font-locking, faces are
applied as `font-lock-face` text properties (not `face`).  The pipeline:

```
raw markdown
  → hermes-md-to-org (markdown→org conversion)
  → hermes-comint--fontify-as-org
      → temp org-mode buffer with org-src-fontify-natively
      → font-lock-ensure
      → copy face → font-lock-face
  → insert into comint buffer
```

## 7. Input — inline prompt

`hermes-comint-send` (bound to RET):
1. Reads and trims text from the writable area (after the `> ` prefix).
2. Pushes to `comint-input-ring` (deduplicated — ignores consecutive duplicates).
3. Clears the input area.
4. Calls `hermes-send input` — delegates to the existing input
   pipeline (`hermes-input.el`) which handles slash commands, queue,
   streaming, history seed, and gateway communication.

`hermes-comint-previous-input` / `hermes-comint-next-input` use
`comint-input-ring`, providing M-p/M-n history cycling.  The current
prompt text is preserved (not pushed) until explicitly sent.

## 8. Event routing — what changes in hermes-mode.el

The comint viewer needs to receive per-session events from the gateway.
Three functions must be updated:

### `hermes--lookup-buffer`

Currently looks up only `hermes--org-buffers`.  Must also check
`hermes-comint--buffers`:

```elisp
(defun hermes--lookup-buffer (session-id)
  "Return any live viewer buffer for SESSION-ID, or nil."
  (let ((buf (or (gethash session-id hermes--org-buffers)
                 (gethash session-id hermes-comint--buffers))))
    (and (buffer-live-p buf) buf)))
```

This lets `hermes--route-event` dispatch `hermes-ui-dispatch` into
the comint buffer when events arrive for its session.

### `hermes--broadcast-dispatch`

**No changes needed.**  `hermes--broadcast-dispatch` calls
`hermes--lookup-buffer` internally (`hermes-mode.el:109`).  Once
`hermes--lookup-buffer` checks both registries, every
`broadcast-dispatch` call site automatically covers comint buffers.
The rewrite in the original plan draft was redundant — drop it.

### `hermes--live-session-buffers`

Currently walks only `hermes--org-buffers`.  Must also include
`hermes-comint--buffers` so `M-x hermes` can pop the most recent
comint session as its default:

```elisp
(defun hermes--live-session-buffers ()
  "Return live session buffers across all viewer registries, most-recently-touched first."
  (let (acc)
    (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
             hermes--org-buffers)
    (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
             hermes-comint--buffers)
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))
```

### `hermes` entry point

The current `hermes` function (`hermes-mode.el:380`) has these branches:

1. `hermes-org-minor-mode` active → ensure bench visible, focus input.
2. `(derived-mode-p 'org-mode)` → ancestor walk for `:hermes:` heading,
   handle stale headings, or create session heading.
3. Catch-all → pop most-recent live session buffer, or `hermes-new-session`.

**Prepend** a comint-mode branch; leave branches 1–3 untouched:

```elisp
(defun hermes ()
  "Context-aware entry point — never sends a prompt."
  (interactive)
  (cond
   ;; NEW: Comint viewer → focus the writable prompt.
   ((derived-mode-p 'hermes-comint-mode)
    (goto-char (point-max)))
   ;; Existing branches — unchanged.
   (hermes-org-minor-mode
    ;; ... keep entire existing branch ...)
   ((derived-mode-p 'org-mode)
    ;; ... keep entire existing branch ...)
   (t
    ;; ... keep entire existing branch; it calls
    ;;     hermes--primary-session-buffer which now returns
    ;;     comint buffers since hermes--live-session-buffers
    ;;     includes hermes-comint--buffers ...)))
```

The catch-all branch already calls `hermes--primary-session-buffer`
→ `hermes--live-session-buffers`.  Once §8 updates that function to
walk both registries, comint sessions appear in the picker and are
popped by default — no branch rewrites needed.  The only code change
in `hermes` itself is the 4-line comint-mode prepend.

## 9. Session resolution — what changes in hermes-org.el

`hermes--resolve-session-target` (in `hermes-org.el:165`) is the
function that `hermes-send` calls to figure out which session to send
to.  It currently recognizes four contexts:
1. Buffer registered in `hermes--org-buffers`
2. `hermes-org-minor-mode` active (walks headings)
3. `(or (derived-mode-p 'hermes-section-mode) (derived-mode-p 'hermes-bench-mode))` — section or bench buffers

The section/bench branch at `hermes-org.el:202` is a single `or`:

```elisp
((or (derived-mode-p 'hermes-section-mode)
     (derived-mode-p 'hermes-bench-mode))
 ...)
```

**Swap `hermes-section-mode` for `hermes-comint-mode`** — keep
`hermes-bench-mode` in the `or`:

```elisp
((or (derived-mode-p 'hermes-comint-mode)
     (derived-mode-p 'hermes-bench-mode))
 (let ((sid (buffer-local-value 'hermes--current-session-id
                                (current-buffer))))
   (and sid (cons sid (gethash sid hermes--sessions)))))
```

The original branch shared a body between section and bench modes.
The new branch shares the same body between comint and bench modes —
the variable read (`hermes--current-session-id`) is set
buffer-locally by both `hermes-comint-mode` and `hermes-bench-mode`
at creation time, so no branching is needed inside the body.

This lets `hermes-send` work transparently when called from a comint
buffer — critical because `hermes-comint-send` delegates to
`hermes-send`.

## 10. Buffer registry — what changes in hermes-state.el

### Add `hermes-comint--buffers`

```elisp
(defvar hermes-comint--buffers (make-hash-table :test 'equal)
  "Map session-id (string) → comint conversation buffer.")
```

Placed alongside the other viewer registries (currently line 170):

| Variable | Line | Registry for |
|----------|------|-------------|
| `hermes--org-buffers` | 167 | Org-mode conversation buffers |
| `hermes--bench-buffers` | 170 | Bench buffers |
| `hermes-comint--buffers` | new | Comint conversation buffers |

### Remove `hermes-section--buffers`

```elisp
(defvar hermes-section--buffers (make-hash-table :test 'equal)
  "Map session-id (string) → magit-section conversation buffer.")
```
→ **Delete these 2 lines.**

### Update `hermes--maybe-kill-bench`

Currently checks `hermes--org-buffers` and `hermes-section--buffers`.
Replace the section reference with the comint registry:

```elisp
(defun hermes--maybe-kill-bench (sid)
  "Kill the bench for SID if no viewers remain across all registries."
  (unless (or (buffer-live-p (gethash sid hermes--org-buffers))
              (buffer-live-p (gethash sid hermes-comint--buffers)))
    (let ((bb (gethash sid hermes--bench-buffers)))
      (when (buffer-live-p bb)
        (let ((win (get-buffer-window bb)))
          (when (window-live-p win) (delete-window win)))
        (kill-buffer bb)))))
```

## 11. Cleanup — what gets deleted

### Files to delete

| File | Action |
|------|--------|
| `hermes-section.el` | Delete entire file |
| `hermes-section.elc` | Delete (if present) |
| `test/hermes-section-test.el` | Delete entire file (246 lines, all tests assume magit-section infrastructure) |

### Files to modify

| File | Action |
|------|--------|
| `AGENTS.md` | Replace "hermes-section.el" line with "hermes-comint.el". Replace section architecture paragraph. |
| `docs/01-architectural-model.md` | Replace section viewer reference with comint. |
| `docs/14-architecture-reference.md` | Replace section diagram and references. |
| `Eldev` | Remove `hermes-section.el` from the comment at line 7 and the source list at line 31. Remove `test/hermes-section-test.el` from the test list at line 42. |
| `test/hermes-test-helpers.el` | Replace `hermes-section--buffers` with `hermes-comint--buffers` in the reset helper at line 19. |
| `hermes-transient.el` | Update the comment at line 28: s/hermes-section-mode/hermes-comint-mode/. No code change — the function calls `hermes--resolve-session-target`, which is viewer-agnostic. |

### State-level changes

| Variable/Function | File | Action |
|-------------------|------|--------|
| `hermes-section--buffers` | `hermes-state.el` | Remove declaration (line 173) |
| `hermes-section--buffers` ref | `hermes-state.el` → `hermes--maybe-kill-bench` (line 368) | Replace with `hermes-comint--buffers` |
| `hermes-section-mode` check | `hermes-org.el` → `hermes--resolve-session-target` (line 202) | Replace with `hermes-comint-mode` in the `or` |

## 12. Entry point — session pickers

The existing `hermes-comint` autoload (already in `hermes-comint.el`)
provides the standalone entry point:

```elisp
(defun hermes-comint (&optional arg)
  "Open a comint-mode conversation viewer.
With prefix ARG, always create a new session."
  (interactive "P")
  (require 'hermes-mode)
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ((derived-mode-p 'hermes-comint-mode)
    (message "Already in a Hermes comint buffer"))
   (arg
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-comint--open
          (buffer-local-value 'hermes--current-session-id buf))))))
   ((hermes--session-exists-p)
    (let ((sid (hermes-comint--pick-session)))
      (when sid (hermes-comint--open sid))))
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-comint--open
          (buffer-local-value 'hermes--current-session-id buf))))))))
```

The session picker (`hermes-comint--pick-session`) uses existing
helpers from `hermes-state.el`:
- `hermes--list-active-sessions` — returns list of `(sid . state)` pairs
  from `hermes--sessions`
- `hermes--session-completion-table` — builds `completing-read` table
  with annotations (model, status, title, message count)
- `hermes--most-recent-session-id` — default choice

## 13. What this plan does NOT cover

| Feature | Status | Reason |
|---------|--------|--------|
| Stale heading handling for comint | No | Comint buffers are ephemeral — they reference live in-memory sessions, never org headings. The stale-heading flow (load-from-org / resume-from-DB / branch-from-DB) is org-buffer-only by design. |
| DB→Comint resume | No | `hermes-sessions.el` always creates org buffers for DB resume. The gateway's flattened history is lossy; org is the body-canonical format. Comint is for "live" viewing of in-memory state. |
| Attachment/image previews | No | The comint viewer renders image labels (`[image: name]`) but not inline images. Org buffer handles inline images. |
| CWD / project context | No | Project context is injected at prompt-send time in `hermes-input.el`, not rendered in the viewer. |
| Evil bindings for comint | No | `hermes-evil.el` adds `C-c` bindings for `hermes-org-minor-mode` only — zero section references, no code change needed. Evil comint bindings may come later. |
| Doom `SPC h` integration for comint | No | `hermes-doom.el` binds `SPC h h` to `hermes` — which will now open comint by default. The transient popup already delegates through `hermes--resolve-session-target`. |
| Notifications for comint sessions | No | `hermes-notifications.el` already works — it hooks on state-change, not viewer type. |
| Collapsible reasoning/tool sections | No | Comint is linear — content is always visible. The org viewer's folding is available for users who prefer it. |
| org-mode folding parity | No | comint-mode has no heading structure — there's nothing to fold. Export to org for structured browsing. |

## 14. Sequence

| Step | File | Description |
|------|------|-------------|
| 1 | `hermes-state.el` | Add `hermes-comint--buffers` declaration. Remove `hermes-section--buffers` (line 173). Update `hermes--maybe-kill-bench` (line 368) to check `hermes-comint--buffers` instead of `hermes-section--buffers`. |
| 2 | `hermes-mode.el` | Update `hermes--lookup-buffer` to also check `hermes-comint--buffers`. Update `hermes--live-session-buffers` to include comint buffers. Prepend `hermes-comint-mode` branch to `hermes` entry point. Add `declare-function` for `hermes-comint`. |
| 3 | `hermes-org.el` | In `hermes--resolve-session-target` (line 202): swap `hermes-section-mode` for `hermes-comint-mode` in the `or`, keeping `hermes-bench-mode`. |
| 4 | `hermes-comint.el` | Strip stale comment at line 213 claiming `hermes-comint--buffers` is declared in `hermes-state.el`. Verify all `declare-function` entries exist and resolve. |
| 5 | Delete files | Remove `hermes-section.el`, `hermes-section.elc`, `test/hermes-section-test.el`. |
| 6 | `Eldev` | Remove section references at lines 7, 31, 42. |
| 7 | `test/hermes-test-helpers.el` | Replace `hermes-section--buffers` with `hermes-comint--buffers` at line 19. |
| 8 | `hermes-transient.el` | Update comment at line 28. |
| 9 | `AGENTS.md` | Replace section viewer line + section view paragraph with comint viewer. |
| 10 | `docs/01-architectural-model.md` | Replace section viewer reference. |
| 11 | `docs/14-architecture-reference.md` | Replace diagram and references. |
| 12 | Test — `eldev compile` | Byte-compile all sources. `hermes-comint.el` has been unreachable without the missing `defvar`; verify it compiles clean after step 1. |
| 13 | Test — `eldev test` | Run full ERT suite. Expect existing tests to pass; the deleted `hermes-section-test.el` must be removed from Eldev first. Add comint-specific ERT tests for: turn insertion with all segment types, the streaming lifecycle (begin → update → commit), header-line refresh, and `hermes-comint--open` round-trip. Budget tests as required, not optional — this viewer replaces the section viewer and becomes the default non-org interface. |
| 14 | Theming | Verify the 13 `hermes-comint-faced-*` faces render legibly against `hermes-doom-theme` (gold/teal). No code changes expected — faces inherit from semantic faces (`font-lock-comment-face`, `font-lock-keyword-face`, etc.) that the theme already customizes. See `docs/hermes-doom-theme-spec.md` for the theme's face palette. |

## 15. References

| What | Where |
|------|-------|
| `hermes-state-turns` + `hermes-message` struct | `hermes-state.el` |
| `hermes--sessions` global table | `hermes-state.el:156` |
| `hermes--on-session-buffer` macro | `hermes-state.el:381` |
| `hermes--push-committed` | `hermes-state.el:552` |
| `hermes-dispatch` / state change hook | `hermes-state.el:393` |
| `hermes--route-event` | `hermes-mode.el:64` |
| `hermes--resolve-session-target` | `hermes-org.el:165` |
| `hermes--live-session-buffers` | `hermes-mode.el:367` |
| `hermes--primary-session-buffer` | `hermes-mode.el:375` |
| `hermes-send` | `hermes-input.el:355` |
| `hermes-comint.el` (existing) | Project root, 802 lines |
| `hermes-md-to-org` | `hermes-md.el` |
| `hermes-tool--lookup` / `hermes-tool-formatters` | `hermes-tool-formatters.el` |
| `hermes--buffer-visible-p` | `hermes-state.el:376` |
| `hermes--message-from-stream` | `hermes-state.el:808` |
| AGENTS.md architecture section | Project root |
