# PLAN 24: Move Hermes status from org mode-line to bench/comint buffer

## Motivation

Every Hermes session has a bench (a `hermes-comint-mode` buffer displayed as a
bottom side-window).  In org-mode, the bench is a compact prompt area; in
comint-only mode, it *is* the full interface.  The bench is the one UI element
always present.

Currently session status lives in the org buffer's mode-line (connection
indicator, session info, model, tokens, queue, streaming).  But the org buffer
is body-canonical — a document users save, edit, and share.  Status metadata
doesn't belong in a document's mode-line.

Additionally, the bench currently disables its own header-line entirely
(line 1129 of `hermes-comint.el`), missing the bg-task and attachment
counters that the full comint viewer shows.

## Goal

Move **all** Hermes status into the bench/comint buffer, split as:

| Location | Content |
|----------|---------|
| Bench **header-line** | `[bg: N running]`, `[bg #N complete]`, `[N attachment(s)]` |
| Bench **mode-line** | connection dot, session id, model, token count, queue size, streaming status |
| Org **mode-line** | clean default org-mode mode-line (no Hermes indicators) |
| Org **header-line** | default org-mode header-line |

The non-bench comint viewer (`*hermes-comint:<sid>*`) gets the same treatment:
both header-line and mode-line carry the same Hermes status.

## Architectural decision: session-scoped UI state

**Current:** `hermes--ui-state` is `defvar-local` in the org buffer.  Its
buffer-local hook (`hermes-ui-state-change-hook`) fires only in the buffer
where `hermes-ui-dispatch` ran.  The only subscriber (`hermes--render-ui`) is
registered buffer-locally via `(add-hook ... t t)`.

**Problem:** the bench can't see streaming-status text (Thinking…, Running
bash…, tool previews, approval prompts, accumulated thinking-text) because
that text lives in the org buffer's private UI state.  Parsing stream segments
in the bench would re-derive a worse version of what `hermes--ui-reduce`
already produces correctly (hermes-state.el:1500-1584).

**Insight:** UI status is session-level information — every bench for the
same session should agree.  The TUI shows the same status to all clients
(TUI, CLI, Telegram, Emacs) that share a gateway session.  Making it
buffer-local was an accident of where `hermes-ui-dispatch` happened to run.

**Decision:** move `hermes--ui-state` from buffer-local to a session-scoped
hash table `hermes--ui-states` (parallel to `hermes--sessions`).  The hook
`hermes-ui-state-change-hook` *stays* as a plain `defvar` — it was never
buffer-local, it was only subscribed buffer-locally.  Register the bench's
mode-line refresher as a global subscriber.

### Why not embed UI state in `hermes-state` itself

The main state struct (`hermes-state`) carries persistent data and fires
`hermes-state-change-hook` on every mutation.  The UI state fires on every
stream delta (much higher frequency).  Embedding UI state in the main struct
would cause `hermes-state-change-hook` to fire on every stream tick,
triggering full re-renders (including `hermes--append-new-turns` scans) that
the org renderer would see as spurious `(not (eq old new))` transitions.
Separate hash tables keep the two hook chains at their natural frequencies.

### Simplification of event routing

Once UI state is session-scoped, `hermes--route-event` and
`hermes--broadcast-dispatch` no longer need to `with-current-buffer` into the
org buffer just to call `hermes-ui-dispatch`.  The `hermes--lookup-buffer`
calls in both functions are removed — the dispatch functions operate
directly on hash tables.

Before (hermes-mode.el:79-84):
```elisp
(let ((buf (hermes--lookup-buffer session-id)))
  (if (buffer-live-p buf)
      (with-current-buffer buf
        (hermes-dispatch (cons type payload) session-id)
        (hermes-ui-dispatch (cons type payload) session-id))
    (hermes-dispatch (cons type payload) session-id)))
```

After:
```elisp
(hermes-dispatch (cons type payload) session-id)
(hermes-ui-dispatch (cons type payload) session-id)
```

Before (hermes-mode.el:115-118):
```elisp
(let ((buf (hermes--lookup-buffer sid)))
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (hermes-ui-dispatch (cons type payload) sid))))
```

After:
```elisp
(hermes-ui-dispatch (cons type payload) sid)
```

## Design

### Mode-line refresh does not need new hook wiring

The bench's `hermes-comint--refresh` is already subscribed to the global
`hermes-state-change-hook` (hermes-comint.el:395).  On every state change —
connection, session info, model, usage, queue, bg tasks, attachments, stream
tick — it runs and already calls `hermes-comint--refresh-header-line`.
Adding `hermes-comint--refresh-mode-line` right beside it gives us the
mode-line update for free.

For streaming text: register `hermes-comint--refresh-mode-line` on
`hermes-ui-state-change-hook` (global).  That hook fires independently on
every `hermes-ui-dispatch` call, which runs on every stream delta — no new
wiring needed.

### Mode-line format is non-destructive

Do not replace `mode-line-format` wholesale.  Instead, insert
`(:eval hermes-comint--mode-line-status)` after
`mode-line-buffer-identification` in the existing format.  This preserves
process status (`mode-line-process`, shown by comint for running/failed
gateway subprocess), position info, VC state, minor-mode lighters, and the
`Hermes-Comint` major-mode name.

Implementation in `hermes-comint--setup`:
```elisp
(setq mode-line-format
      (let ((parts nil)
            (found nil))
        (dolist (elt mode-line-format)
          (push elt parts)
          (when (eq elt 'mode-line-buffer-identification)
            (push " " parts)
            (push '(:eval hermes-comint--mode-line-status) parts)
            (push " " parts)
            (setq found t)))
        (if found (nreverse parts) mode-line-format)))
```

### Streaming status

`hermes-comint--format-mode-line` reads
`(hermes-ui-state-status-text (gethash sid hermes--ui-states))` to get the
curated label from the reducer — "Thinking…", "Responding…",
"Running bash…", "Delegating to fix bugs…", tool previews, approval prompts,
accumulated thinking-text.  No re-derivation from stream segments.

### Width

The mode-line formatter truncates session ID to 8 chars (already done by the
existing code) and trims model names and status text to ~30 chars each.
The `truncate-string-to-width` function handles Emacs display width
correctly (multibyte-safe).

## Changes by file

### `hermes-state.el` (session-scoped UI state)

1. **Add `hermes--ui-states`** global hash table (parallel to `hermes--sessions`):
   ```elisp
   (defvar hermes--ui-states (make-hash-table :test 'equal)
     "Per-session ephemeral UI state, keyed by session id.")
   ```

2. **Add `hermes-ui-state-get`** helper (lazy-init):
   ```elisp
   (defun hermes-ui-state-get (session-id)
     "Return the `hermes-ui-state' for SESSION-ID, creating it if absent."
     (or (gethash session-id hermes--ui-states)
         (let ((st (make-hermes-ui-state)))
           (puthash session-id st hermes--ui-states)
           st)))
   ```

   No explicit init call site needed — first `hermes-ui-dispatch` for any
   session creates the state automatically.

3. **Change `hermes--ui-state`** from `defvar-local` to an internal
   convenience variable bound by `hermes-ui-dispatch` for the hook to use.
   Actually, remove `defvar-local hermes--ui-state` entirely and replace
   with a local let-binding inside `hermes-ui-dispatch`:
   ```elisp
   (defun hermes-ui-dispatch (msg &optional session-id)
     (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
            (hermes--ui-state (hermes-ui-state-get hermes--current-session-id))
            (old hermes--ui-state)
            (new (hermes--ui-reduce old msg)))
       (unless (eq old new)
         (puthash hermes--current-session-id new hermes--ui-states)
         (run-hook-with-args 'hermes-ui-state-change-hook old new))))
   ```
   The variable `hermes--ui-state` becomes a let-binding that the hook
   subscribers can read via `hermes--current-ui-state` or simply from the
   hook arguments (OLD/NEW).  No global `defvar` needed for it.

   Actually, keep it simpler: `hermes-ui-dispatch` can just let-bind
   or compute the value directly.  The hook subscribers will use
   `hermes--current-session-id` to look up the state.

   The cleanest form:
   ```elisp
   (defun hermes-ui-dispatch (msg &optional session-id)
     (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
            (old (hermes-ui-state-get hermes--current-session-id))
            (new (hermes--ui-reduce old msg)))
       (unless (eq old new)
         (puthash hermes--current-session-id new hermes--ui-states)
         (run-hook-with-args 'hermes-ui-state-change-hook old new))))
   ```

4. **Remove `hermes-state-init`** (lines 292-295).  The lazy-init in
   `hermes-ui-state-get` replaces it.

5. **Update `hermes-ui-state-change-hook` docstring** (line 289-290):
   ```elisp
   (defvar hermes-ui-state-change-hook nil
     "Hook of (OLD NEW) called after a session's ephemeral UI state is swapped.
   Both arguments are `hermes-ui-state' structs; OLD may be the initial
   empty struct.  `hermes--current-session-id' is bound to the affected
   session id.")
   ```

### `hermes-mode.el` (event routing + org cleanup)

6. **Simplify `hermes--route-event`** (lines 79-84): remove
   `with-current-buffer` and `hermes--lookup-buffer` — call
   `hermes-ui-dispatch` directly after `hermes-dispatch`.
   After simplification, the `if (buffer-live-p buf)` branch collapses:
   ```elisp
   ((and session-id (not (string-empty-p session-id)))
    (hermes-dispatch (cons type payload) session-id)
    (hermes-ui-dispatch (cons type payload) session-id))
   ```

7. **Simplify `hermes--broadcast-dispatch`** (lines 113-118): remove
   `hermes--lookup-buffer` and `with-current-buffer` — call
   `hermes-ui-dispatch` directly.
   ```elisp
   (maphash (lambda (sid _state)
              (hermes-dispatch (cons type payload) sid)
              (hermes-ui-dispatch (cons type payload) sid))
            hermes--sessions)
   ```

8. **In `hermes-org-minor-mode--on`**:
   - Remove line 218: `(hermes-state-init)` — no longer needed.
   - Remove line 235: `(add-hook 'hermes-state-change-hook #'hermes--mode-line-update t)`.
   - Remove line 237: `(add-hook 'hermes-ui-state-change-hook #'hermes--render-ui t t)`.
   - Remove lines 248-255: the custom `mode-line-format` override and
     `header-line-format nil` assignment.
   - Remove lines 256-264: the initial `hermes--mode-line-update` call.

9. **In `hermes-org-minor-mode--off`**:
   - Remove line 272: `(remove-hook 'hermes-ui-state-change-hook #'hermes--render-ui t)`.
   - Remove lines 275-276: `(kill-local-variable 'mode-line-format)` and
     `(setq header-line-format nil)`.  After step 8 removes the
     corresponding setters in the ON path, these cleanups are dead.

### `hermes-org-render.el` (remove org-specific mode-line code)

10. **Remove `hermes--render-ui`** function (lines 405-412).

11. **Remove `hermes--mode-line-update`** function (lines 1494-1541).

12. **Remove `hermes--ui-line`** buffer-local variable (lines 34-35).

13. **Remove `hermes--mode-line-status`** buffer-local variable (lines 37-39).

14. **In `hermes--render`**:
    - Remove lines 281-291: the "3. Mode line" section that conditionally
      calls `hermes--mode-line-update`.  Dead after the mode-line is
      removed from org buffers.
    - Remove line 343: the unconditional `(hermes--mode-line-update)` call.

### `hermes-comint.el` (bench mode-line + header-line)

15. **Add `hermes-comint--mode-line-status`** buffer-local variable:
    ```elisp
    (defvar-local hermes-comint--mode-line-status ""
      "Dynamic Hermes status text displayed in the bench/comint mode-line.")
    ```

16. **Add `hermes-comint--format-mode-line(state, sid)`** — builds the
    rich status string:
    ```elisp
    (defun hermes-comint--format-mode-line (state sid)
      "Return a mode-line status string for STATE and SID, or \"\"."
      (when state
        (let (parts)
          ;; Connection indicator
          (push (pcase (hermes-state-connection state)
                  ('connected    "●")
                  ('connecting   "◐")
                  ('disconnected "○")
                  (_             "○"))
                parts)
          ;; Session ID + status
          (let ((conn (hermes-state-connection state)))
            (push (format " · session %s %s"
                          (if (> (length sid) 8) (substring sid 0 8) sid)
                          (pcase conn
                            ('connected "ready")
                            ('connecting "connecting")
                            ('disconnected "disconnected")
                            (_ "unknown")))
                  parts))
          ;; Model
          (when-let* ((info (hermes-state-session-info state))
                      (model (and (hash-table-p info) (gethash "model" info))))
            (push (format " · %s" (truncate-string-to-width model 30 nil nil t))
                  parts))
          ;; Streaming status (from session-scoped UI state)
          (let ((ui (and sid (gethash sid hermes--ui-states))))
            (when-let ((st (and ui (hermes-ui-state-status-text ui))))
              (push (format " · %s" (truncate-string-to-width st 30 nil nil t))
                    parts)))
          ;; Token usage
          (when-let* ((usage (hermes-state-usage state))
                      (sent  (gethash "tokens_sent" usage))
                      (recv  (gethash "tokens_received" usage)))
            (when (or sent recv)
              (push (format " · (%s tokens)" (+ (or sent 0) (or recv 0))) parts)))
          ;; Queue
          (when-let ((q (hermes-state-queue state)))
            (when (> (length q) 0)
              (push (format " · queue: %d" (length q)) parts)))
          (string-join (nreverse parts) "")))))
    ```

17. **Add `hermes-comint--refresh-mode-line`**:
    ```elisp
    (defun hermes-comint--refresh-mode-line (&rest _)
      "Refresh the bench/comint mode-line(s) for the current session.
    Accepts &rest args for compatibility with both `hermes-state-change-hook'
    and `hermes-ui-state-change-hook' (each fires (OLD NEW)).

    Iterates both bench and viewer registries — the dispatching buffer
    is usually NOT the bench/viewer, so we must look up the target
    buffers by session id rather than trusting `(current-buffer)'."
      (let ((sid hermes--current-session-id))
        (when sid
          (let ((state (hermes--state-slot-read sid)))
            (dolist (registry (list hermes--bench-buffers
                                    hermes-comint--buffers))
              (let ((buf (gethash sid registry)))
                (when (buffer-live-p buf)
                  (with-current-buffer buf
                    (setq hermes-comint--mode-line-status
                          (hermes-comint--format-mode-line state sid))
                    (force-mode-line-update)))))))))
    ```
    Registered as a global subscriber on both hooks. Following the same
    convention as `hermes-comint--refresh` (hermes-comint.el:519-554):
    the function discovers its target buffers by iterating the registry
    rather than reading buffer-local state.

18. **Register `hermes-comint--refresh-mode-line` on hooks**
    (in `hermes-comint--setup`, alongside the existing hook registration):
    ```elisp
    (add-hook 'hermes-state-change-hook #'hermes-comint--refresh-mode-line t)
    (add-hook 'hermes-ui-state-change-hook #'hermes-comint--refresh-mode-line t)
    ```

19. **In `hermes-comint--setup`**, set non-destructive mode-line format
    (after prompt insertion, before hook registration):
    ```elisp
    (setq mode-line-format
          (let ((parts nil)
                (found nil))
            (dolist (elt mode-line-format)
              (push elt parts)
              (when (eq elt 'mode-line-buffer-identification)
                (push " " parts)
                (push '(:eval hermes-comint--mode-line-status) parts)
                (push " " parts)
                (setq found t)))
            (if found (nreverse parts) mode-line-format)))
    ```

20. **In `hermes-comint--refresh`** (line 554), no change needed —
    `hermes-comint--refresh-header-line` is already called by this function,
    and `hermes-comint--refresh-mode-line` is registered independently on
    `hermes-state-change-hook` (step 18).  Both fire on every state change.

21. **In `hermes-comint--load-from-state`** (line 894), add mode-line
    refresh after header-line refresh (this is not a hook — it's called
    explicitly during buffer init):
    ```elisp
    (hermes-comint--refresh-header-line state)
    (hermes-comint--refresh-mode-line)
    ```
    Note: `hermes-comint--refresh-mode-line` reads `hermes--current-session-id`
    (set by the caller — same place that lets the existing header-line
    refresh work) and discovers the target buffer via the registries.

22. **In `hermes-bench-ensure`** (line 1129), **remove**:
    ```elisp
    (setq-local header-line-format nil)
    ```
    The bench now inherits the header-line from comint mode —
    `hermes-comint--refresh-header-line` is already called during refresh.

23. **No hook removal in `hermes-comint--detach`.** `add-hook` deduplicates
    by function symbol, so all N comint buffers share a single registry
    entry for `hermes-comint--refresh-mode-line`; removing it on one
    detach would break every other live bench/viewer. The existing
    `hermes-comint--refresh` follows the same convention — registered
    globally in `--setup`, never removed in `--detach` (the iteration
    pattern in step 17 filters dead buffers via `buffer-live-p`).

### `hermes-image.el` (no change)

The reviewer is correct: step 16 of the original plan adds a mode-line
refresh to `hermes-image--repaint-bench`, but attachments live in the
header-line per the plan's own table.  The mode-line refresh is unnecessary
and couples the image module to mode-line state for no current consumer.
**Skip this change entirely.**

### Tests

24. **Add tests** in `test/hermes-comint-test.el`:
    - `hermes-comint-test/mode-line-basic` — connection dot + session info
      appear in the formatted string.
    - `hermes-comint-test/mode-line-model` — model name appears.
    - `hermes-comint-test/mode-line-streaming-status` — streaming text
      from UI state appears.
    - `hermes-comint-test/mode-line-usage` — token counts appear.
    - `hermes-comint-test/mode-line-queue` — queue length appears.
    - `hermes-comint-test/mode-line-nil-on-empty` — returns empty string
      when state is nil.

25. **Update tests** in `test/hermes-state-test.el`: any test that relies
    on `hermes--ui-state` being `defvar-local` needs updating.  Scan the
    file; if tests call `hermes-ui-dispatch` without a `hermes--current-session-id`,
    they need to bind it.  If tests read `hermes--ui-state` directly, they
    need to read from `hermes--ui-states` via `hermes-ui-state-get` instead.

26. **Update test helpers** in `test/hermes-test-helpers.el`: reset
    `hermes--ui-states` alongside `hermes--sessions` (and
    `hermes--bench-buffers` which is already reset there).

27. **No existing tests rely on org buffer mode-line behavior**, so no
    tests break from the org-mode cleanup.

## Files touched

| File | Lines changed | Nature |
|------|---------------|--------|
| `hermes-state.el` | ~+20 / −10 | Add `hermes--ui-states` hash table, `hermes-ui-state-get`, remove `hermes-state-init`, update `hermes-ui-dispatch` |
| `hermes-mode.el` | +6 / −24 | Simplify event routing, remove org mode-line/header-line code |
| `hermes-org-render.el` | +0 / −30 | Remove `hermes--render-ui`, `hermes--mode-line-update`, `hermes--ui-line`, `hermes--mode-line-status` |
| `hermes-comint.el` | ~+85 / −4 | Add mode-line infra, non-destructive format, hook registration, un-suppress bench header-line |
| `hermes-image.el` | +0 / −0 | Unchanged |
| `test/hermes-comint-test.el` | ~+50 / −0 | Mode-line formatting tests including streaming status |
| `test/hermes-state-test.el` | ~+5 / −5 | Adapt to session-scoped UI state |
| `test/hermes-test-helpers.el` | +1 / −0 | Reset `hermes--ui-states` |

Total: ~+165 / −75 lines.

## Edge cases

- **No state yet** (gateway not started): `hermes-comint--format-mode-line`
  returns `""`.  The bench always exists via `hermes-bench-ensure`, so the
  mode-line renders immediately with the format but empty Hermes section.

- **Bench buffer killed and recreated**: `hermes-bench-ensure` calls
  `hermes-comint-mode`, which calls `hermes-comint--setup`, which re-installs
  the mode-line format and hooks.  The UI state persists in
  `hermes--ui-states` across buffer lifetime — mode-line is recomputed
  from the session-scoped state on refresh.

- **Non-bench comint viewer** (`*hermes-comint:<sid>*`): gets the same
  mode-line treatment.  `hermes-comint--setup` runs for ALL
  `hermes-comint-mode` buffers.  `hermes-comint--bench-p` does not change
  mode-line behavior.

- **Multiple comint viewers for the same session**: each has its own
  `hermes-comint--refresh-mode-line` on the global hook (registered in
  `hermes-comint--setup`).  Since the hook fires with
  `hermes--current-session-id`, each buffer checks whether the session
  matches and updates if so.

- **`hermes-comint--load-from-state` explicit call**: this function is
  called during buffer initialization, outside the hook context.  The
  mode-line refresh call there must work — `hermes-comint--refresh-mode-line`
  reads `hermes--current-session-id` which is set by the caller (line 881
  of `hermes-comint--load-from-state` already binds it before calling
  `hermes-comint--refresh-header-line`).  The mode-line refresh call is
  added immediately after.

- **`hermes-ui-state-get` lazy-init on first dispatch**: the first
  `hermes-ui-dispatch` for any session creates an empty
  `hermes-ui-state` struct.  This struct has nil for all fields, so
  `hermes-ui-state-status-text` returns nil, and the mode-line shows no
  streaming text until the first status/thinking event arrives.  This is
  the same behavior as today.

## Not in scope

- The `hermes-compose` buffer's static header-line is unchanged.
- The `hermes-sessions` sidebar buffer is unchanged.
- Background task buffers (`*hermes-bg:<sid>:<tid>*`) are unchanged.
- The bench's `hermes-comint--steer-messages` are not surfaced in the
  mode-line — they're transient dispatch messages (approval, clarification
  requests) that belong in the bench body, not the chrome.
- Right-alignment of Hermes status in the mode-line (requires Emacs 30+
  `mode-line-format-right-align`).  Could be a follow-up.
