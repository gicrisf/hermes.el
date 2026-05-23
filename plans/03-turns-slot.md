# PLAN 03: `turns` slot — canonical in-memory conversation log

## Goal

Add a `turns` slot to `hermes-state` that accumulates every committed
user/assistant message.  This makes the global state the **canonical
conversation history** — any viewer (org minor-mode, future magit
conversation, export) reads from one source.

Plan 01 made state global.  Plan 02 removed the derived major mode.  This
plan makes the state *complete* — not just transient stream data, but the
full committed conversation log.

This is groundwork.  `turns` has no reader in this plan (the org renderer
continues to drain `pending-turns` as before).  It exists so plan 04 can
build the magit conversation viewer on top of a canonical data source.

## What changes

### 1. Add `id` slot to `hermes-message` (`hermes-state.el`)

Stable identity for visibility cache, section-value matching, and import:

```elisp
(cl-defstruct hermes-message
  kind segments usage timestamp subagents
  (id nil))  ;; unique string like "msg-42"
```

Add a counter and generator:

```elisp
(defvar hermes--message-counter 0
  "Monotonic counter for message IDs.")

(defun hermes--next-message-id ()
  "Return a fresh message ID string."
  (format "msg-%d" (cl-incf hermes--message-counter)))
```

### 2. Add `turns` slot to `hermes-state`

```elisp
(cl-defstruct hermes-state
  connection session-id session-info usage stream pending
  (pending-turns [])
  (turns [])             ;; ← new: vector of hermes-message, never cleared
  slash-catalog queue history skin busy-mode cwd attachments
  bg-tasks parent-sid)
```

### 3. Centralize id assignment and turns append

Rather than wiring `:id` and `turns` at every call site, create a single
helper that all committed-turn paths use.  This catches every path
(`:user-submit`, `"message.complete"`, `"error"`) without per-path
wiring:

```elisp
(defun hermes--push-committed (state msg)
  "Return a new STATE with MSG committed as a conversation turn.
Assigns a monotonic `:id', appends to `pending-turns' (for the org
renderer) and `turns' (for the canonical history).  Used by
:user-submit, message.complete, and the error handler."
  (let ((m (hermes--with-copy msg hermes-message-copy x
             (setf (hermes-message-id x) (hermes--next-message-id)))))
    (hermes--with-copy state hermes-state-copy s
      (setf (hermes-state-pending-turns s)
            (hermes--vector-append (hermes-state-pending-turns state) m))
      ;; Read from `state', not `s' — conventional in this codebase
      ;; (cf. hermes--push-pending, hermes--append-segment).  `s' is a
      ;; fresh copy so both pointers are identical here, but reading
      ;; from `state' keeps the two setf forms independent — if someone
      ;; inserts more setf forms later, the ordering remains irrelevant.
      (setf (hermes-state-turns s)
            (hermes--vector-append (hermes-state-turns state) m)))))
```

The old `hermes--push-pending` is kept for **system messages**, which
are now excluded from `turns` entirely (see §6):

```elisp
(defun hermes--push-pending (state msg)
  "Return a new STATE with MSG pushed onto `pending-turns' only.
Used for system messages — no id assignment, no turns entry."
  (hermes--with-copy state hermes-state-copy s
    (setf (hermes-state-pending-turns s)
          (hermes--vector-append (hermes-state-pending-turns state) msg))))
```

### 4. Wire call sites in the reducer

Each call site swaps `hermes--push-pending` → `hermes--push-committed`
if the message is a conversation turn, or keeps `hermes--push-pending`
for system messages:

| Reducer clause | Helper |
|---------------|--------|
| `:user-submit` | `hermes--push-committed` |
| `"message.complete"` | `hermes--push-committed` |
| `"error"` (partial turn commit) | `hermes--push-committed` |
| `:system-message` | `hermes--push-pending` (unchanged) |

No per-path `:id` assignment needed — `hermes--push-committed` sets it.

### 5. Update `hermes--message-from-stream`

Remove any `:id` from the message builder — `hermes--push-committed`
assigns it.  The signature stays identical:

```elisp
(defun hermes--message-from-stream (stream usage)
  (make-hermes-message
   :kind 'assistant
   :segments (hermes--normalize-segments ...)
   :subagents (or (hermes-stream-subagents stream) [])
   :usage usage
   :timestamp (current-time)))
;; :id is set by hermes--push-committed
```

### 6. System messages: excluded from `turns`

System messages ("Session resumed from history", etc.) are gateway
diagnostics, not conversation turns.  They should not enter the
canonical history.

The `:system-message` reducer already pushes to `pending-turns` (so it
renders in the org buffer).  After this plan, it pushes to
`pending-turns` only (via `hermes--push-pending`), skipping `turns`.
The org renderer continues to show it in the buffer for now (existing
behaviour).

### 7. Add `:turns-load` reducer message

For future import — overwrites the entire `turns` vector:

```elisp
(:turns-load
 (let ((new-turns (plist-get p :turns)))
   (hermes--with-copy state hermes-state-copy s
     (setf (hermes-state-turns s) new-turns))))
```

No guard on stream state — overwriting is simpler and effective.  `turns`
and `stream` are independent slots.  If a stream is in-flight, the import
replaces committed history; the stream completes and appends its result
after the new base.

### 8. Update serialization

`hermes--message-to-plist` adds an `:id` entry:

```elisp
(defun hermes--message-to-plist (msg)
  `(:kind ,(hermes-message-kind msg)
    :id ,(hermes-message-id msg)
    :segments ,(mapcar #'hermes--segment-to-plist ...)
    :usage ,...
    :timestamp ,...
    :subagents ,...))
```

`hermes--plist-to-message` reads it back:

```elisp
(defun hermes--plist-to-message (pl)
  (make-hermes-message
   :id (plist-get pl :id)
   ...))
```

### 9. Test plan

A few short ERT tests for the new state behavior:

| Test | What it verifies |
|------|-----------------|
| `turns` is empty on fresh state | `(hermes-state-turns (make-hermes-state))` → `[]` |
| `:user-submit` appends to `turns` | Dispatch, check `turns` has one entry with `:kind 'user` |
| `"message.complete"` appends to `turns` | Set up a stream, dispatch `message.complete`, check `turns` has one entry with `:kind 'assistant` |
| `"error"` appends partial turn to `turns` | Stream + dispatch `"error"`, check `turns` has one entry |
| `:system-message` does NOT append to `turns` | Dispatch, `turns` should still be `[]` |
| `:turns-load` overwrites | Load 3 messages, then load 1 → `turns` has 1 |
| `:id` monotonic | Dispatch two turns, ids are `"msg-1"` and `"msg-2"` |

### 10. Acknowledged: `pending-turns` / `turns` duplication

Both vectors accumulate the same committed messages in parallel.
`pending-turns` is drained by the org renderer (`:pending-turns-clear`).
`turns` is never drained.  A render-watermark approach (track
"last-painted-turn index") could replace `pending-turns` entirely, but
that requires changing the org renderer's drain logic.  Deferred to a
future plan — the duplication is cheap and contained within one struct.

## Files touched

| File | Change |
|------|--------|
| `hermes-state.el` | Add `id` to `hermes-message`. Add `turns` to `hermes-state`. Add `hermes--message-counter`, `hermes--next-message-id`. Create `hermes--push-committed`. Keep `hermes--push-pending` for system messages. Wire `:user-submit`, `"message.complete"`, `"error"` → `hermes--push-committed`. Add `:turns-load` to reducer. Update `hermes--message-to-plist` and `hermes--plist-to-message` with `:id`. |
| `test/` | Add new ERT tests for `turns` behavior, `id` monotonicity, `:turns-load` overwrite. |

## Edge cases

| Case | Behaviour |
|------|-----------|
| `turns` is `[]` during streaming | Normal — only set on `message.complete` |
| `"error"` commits partial turn | Caught — `hermes--push-committed` sets id + appends to turns |
| `:turns-load` while stream is active | Overwrites committed turns. Stream completes and appends after new base. Safe: `turns` and `stream` are independent. |
| Duplicate message ids | Impossible — `hermes--message-counter` is monotonic |
| System message dispatch | `hermes--push-pending` only — no `:id`, no `turns` entry |
| `vconcat` O(n) on every append to `turns` | At 3k turns (a year of daily use) still fast. If it ever matters, switch to list + `nreverse` on read. |
| Serialization round-trip | `hermes--message-to-plist` includes `:id`; `hermes--plist-to-message` reads it back. |

## What this plan does NOT cover

- No magit-section viewer (plan 04)
- No streaming pipeline changes — org renderer stays as-is
- No import/export commands — `:turns-load` is the reducer primitive; UI comes later
- No bench changes
- No entry point changes
- No consumer of `turns` — groundwork for plan 04
