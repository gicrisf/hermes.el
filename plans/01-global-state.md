# PLAN 01: Global state layer

## Goal

Promote Hermes session state from **buffer-local** to **global** so
multiple viewer buffers (org-mode, bench, future magit-section view)
can share the same session atom and survive independently.

## Why

Currently, state is buffer-scoped:

```
hermes--state           → defvar-local    (hermes-state.el:148)
hermes--buffer-sessions → defvar-local    (hermes-org.el:42)
```

`hermes--buffer-sessions` is a hash table mapping `session-id → state`.
Because it's `defvar-local`, every buffer gets its own **copy**.  The
dispatching code in `hermes-state.el` has three `boundp`/`hash-table-p`
guards and a secondary sync path to paper over this.  The result:

- Kill the org buffer → state for all sessions registered there is gone.
- Bench reads state from the parent buffer; dies with it.
- Cannot have independent viewers pointing at the same session.

## What changes

### 1. Add global `hermes--sessions` and `hermes--global-state` (hermes-state.el)

```elisp
(defvar hermes--sessions (make-hash-table :test 'equal)
  "Global map: session-id (string) → hermes-state struct.
This is the sole canonical store for per-session state.")

(defvar hermes--global-state (make-hermes-state :connection 'disconnected)
  "State for process-wide events before any session exists.
Receives `gateway.ready`, `skin.changed`, connection-state changes,
and diagnostic events (`gateway.stderr`, `gateway.protocol_error`,
`gateway.start_timeout`) that fire via `hermes--broadcast-dispatch`
or `hermes--route-connection` without a session-id argument.

When a session is created, the existing `hermes--last-gateway-ready`
replay mechanism carries skin data forward into per-session state.")
```

### 2. Remove `hermes--state` as a buffer-local variable

All direct accesses to `hermes--state` are replaced with calls to
`hermes--state-slot-read` (which reads from the global table or
`hermes--global-state` when session-id is nil).  `hermes-dispatch`
writes exclusively to the global store.

### 3. Simplify read/write to gethash/puthash

**Before** (20 lines of guards, `boundp`, `hash-table-p`, fallback):

```elisp
(defun hermes--state-slot-read (session-id)
  (or (and session-id (boundp 'hermes--buffer-sessions)
           (hash-table-p hermes--buffer-sessions)
           (gethash session-id hermes--buffer-sessions))
      hermes--state))

(defun hermes--state-slot-write (session-id new-state)
  (when (and session-id (boundp 'hermes--buffer-sessions) ...)
    (puthash session-id new-state hermes--buffer-sessions))
  (let ((active-sid (hermes-state-session-id new-state)))
    (when (and active-sid (not (equal active-sid session-id)) ...)
      (puthash active-sid new-state hermes--buffer-sessions)))
  (setq hermes--state new-state))
```

**After** (4 lines):

```elisp
(defun hermes--state-slot-read (session-id)
  "Return state for SESSION-ID, or process-wide state when nil."
  (if session-id
      (gethash session-id hermes--sessions)
    hermes--global-state))

(defun hermes--state-slot-write (session-id new-state)
  "Store NEW-STATE for SESSION-ID, or to process-wide state when nil."
  (if session-id
      (puthash session-id new-state hermes--sessions)
    (setq hermes--global-state new-state)))
```

### 4. Simplify `hermes-dispatch`

```elisp
(defun hermes-dispatch (msg &optional session-id)
  (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
         (old (hermes--state-slot-read hermes--current-session-id))
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (hermes--state-slot-write hermes--current-session-id new)
      (run-hook-with-args 'hermes-state-change-hook old new))))
```

No more buffer-local sync.  `hermes--state` is gone.  `hermes--reduce`
already returns a fresh struct when nothing changed; the `eq` check is the
only dispatch guard needed.

### 5. Replace all `hermes--state` access sites

Search-and-replace `hermes--state` → `(hermes--state-slot-read hermes--current-session-id)` everywhere.  This is mechanical.  Files affected:

| File | Approximate sites |
|------|-------------------|
| `hermes-state.el` | `hermes-state-init`, `hermes--reduce`, `hermes--push-pending`, struct serialization |
| `hermes-render.el` | `hermes--render` (reads state in several places) |
| `hermes-bench.el` | `hermes-bench--paint-ephemeral` and helpers |
| `hermes-mode.el` | `hermes--do-session-create`, `hermes-reconnect`, `hermes--route-event` |
| `hermes-org.el` | Registration, lookup |
| `hermes-input.el` | `hermes-input--drain`, `hermes-send` |
| `hermes-prompts.el` | `hermes-prompts-watch` |
| `hermes-skin.el` | `hermes-skin-watch` |
| `hermes-config.el` | Config command helpers |
| `hermes-bg.el` | Background task helpers |
| `hermes-sessions.el` | Session creation, branching, DB renderer |
| `hermes-image.el` | Image attachment helpers |
| `hermes-project.el` | CWD detection (minor — reads `hermes--state` for cwd) |

### 6. Globalize `hermes-state-change-hook` subscribers

Currently all 5 subscribers in `hermes-mode.el` are added with the LOCAL
flag:

```elisp
(add-hook 'hermes-state-change-hook #'hermes--render        t t)  ;; LOCAL
(add-hook 'hermes-state-change-hook #'hermes-prompts-watch  t t)
(add-hook 'hermes-state-change-hook #'hermes-input--drain   t t)
(add-hook 'hermes-state-change-hook #'hermes-skin-watch     t t)
(add-hook 'hermes-state-change-hook #'hermes--mode-line-update t t)
```

This means when dispatch fires in Buffer A (org-mode), only Buffer A's
subscribers run.  A future magit-section buffer never sees org-sourced
state changes.

**Fix:** Remove LOCAL (change `t t` to `t`).  Each subscriber becomes
buffer-aware — it uses a target buffer loaded from one of the viewer
registries, driven by `hermes--current-session-id` (which is dynamically
bound during `hermes-dispatch`).

A helper macro reduces boilerplate:

```elisp
(defmacro hermes--on-session-buffer (registry &rest body)
  "If the current session has a live buffer in REGISTRY, run BODY there."
  (declare (indent 1))
  `(when-let ((sid hermes--current-session-id)
              (buf (gethash sid ,registry)))
     (when (buffer-live-p buf)
       (with-current-buffer buf ,@body))))
```

Each of the five subscribers applies this pattern:

```elisp
;; Global hook, no LOCAL flag
(add-hook 'hermes-state-change-hook #'hermes--render t)

(defun hermes--render (old new)
  (hermes--on-session-buffer hermes--org-buffers
    ;; existing rendering logic — reads from hermes--sessions
    ))

(defun hermes-prompts-watch (old new)
  (hermes--on-session-buffer hermes--org-buffers
    (when (hermes-state-pending
           (hermes--state-slot-read hermes--current-session-id))
      ...)))

(defun hermes-input--drain (old new)
  (hermes--on-session-buffer hermes--org-buffers
    ;; drain queue, send to gateway
    ))

(defun hermes-skin-watch (old new)
  (hermes--on-session-buffer hermes--org-buffers
    ;; apply face remaps
    ))

(defun hermes--mode-line-update (old new)
  (hermes--on-session-buffer hermes--org-buffers
    (force-mode-line-update)))
```

### 7. Add viewer registries

Three global hash tables, one per viewer type:

```elisp
(defvar hermes--org-buffers (make-hash-table :test 'equal)
  "Map session-id → org-mode conversation buffer.")
(defvar hermes--bench-buffers (make-hash-table :test 'equal)
  "Map session-id → bench buffer.")
;; Future:
;; (defvar hermes-conversation--buffers (make-hash-table :test 'equal)
;;   "Map session-id → magit conversation buffer.")   ;; plan 02
```

These replace:
- `hermes--session-buffers` (buffer-local hash table in `hermes-mode.el`)
- `hermes-bench--parent-buffer` (buffer-local pointer in `hermes-bench.el`)

### 8. Remove `hermes--buffer-sessions` and `hermes--session-markers`

From `hermes-org.el` — both `defvar-local`, both now redundant.  All
registrations point at `hermes--org-buffers` and `hermes--sessions`.

### 9. Lifecycle: detach-only on buffer kill

Do NOT `remhash` from `hermes--sessions` when the last viewer is killed.
The in-memory state contains data the gateway DB doesn't preserve
(reasoning, tool args, subagent details, usage — documented-lossy in
AGENTS.md).

Cleanup triggers:
- Explicit `hermes-close-session` command (future — not in this plan).
- Gateway disconnect (connection lost).

On `kill-buffer-hook`: just remove the buffer from the viewer registry.

```elisp
(defun hermes--org-detach ()
  (let ((sid hermes--current-session-id))
    (when sid (remhash sid hermes--org-buffers))))

(add-hook 'kill-buffer-hook #'hermes--org-detach nil t)
```

Same pattern for bench and (future) conversation buffers.

## Precedent

Global state with buffer-local references is the standard Emacs pattern:

- **Eglot** (`eglot--servers-by-project` — global hash table, each buffer has `eglot--managed-mode`)
- **project.el** (`project--list` — global)
- **lsp-mode** (`lsp-clients`, `lsp-workspaces` — global)
- **perspective.el** (`persp-alist` — global)

All manage lifecycle via `kill-buffer-hook` → decrement reference → clean
up when empty.  We follow the same pattern.

## Edge cases

| Case | Behaviour |
|------|-----------|
| Kill org buffer, bench still open | State survives in global table. Bench reads via session-id. |
| Kill all viewers | State stays in global table (turns, stream, usage). Explicit close needed to discard. |
| gateway.ready before any session | Dispatched into `hermes--global-state` (process-wide). Skin colors cached for `hermes--last-gateway-ready` replay into new sessions. |
| `hermes--broadcast-dispatch` without session-id | Dispatches into `hermes--global-state`. All session buffers see the event via hook. |
| `hermes--route-connection` for all buffers | Dispatches into `hermes--global-state`. Mode-line updates in each buffer via `hermes--on-session-buffer`. |
| Gateway restarts | Old session IDs stale. Reconnect creates new session. Old global state replaced by fresh `make-hermes-state`. |
| dispatch from buffer without session-id | `hermes--current-session-id` is nil → reads/writes `hermes--global-state`. |
| Two buffers dispatch for same session | Both write to same global entry. No conflict (Emacs single-threaded). |
| `hermes--state` in macro-expanded code | Search-and-replace catches both direct reads and `setf` targets. |

## Test impact

Tests that currently assume:
- `hermes--state` is buffer-local
- `hermes--buffer-sessions` exists as a buffer-local hash table
- State is isolated between buffers

will break.  229 references to `hermes--state` across `.el` files; tests
use patterns like:

```elisp
(let ((hermes--state (make-hermes-state ...)))
  ...)
```

**Migration:**

1. Add to test helpers:
   ```elisp
   (defun hermes-test--reset-global-state ()
     "Reset global state before each test."
     (setq hermes--sessions (make-hash-table :test 'equal))
     (setq hermes--org-buffers (make-hash-table :test 'equal))
     (setq hermes--bench-buffers (make-hash-table :test 'equal))
     (setq hermes--global-state (make-hermes-state :connection 'disconnected)))
   ```

2. Replace `(let ((hermes--state ...))` with:
   ```elisp
   (let ((hermes--current-session-id "test-sid"))
     (hermes--state-slot-write "test-sid" (make-hermes-state ...))
     ...)
   ```

3. Replace `(hermes-state-* hermes--state)` with:
   `(hermes-state-* (hermes--state-slot-read hermes--current-session-id))`.

4. Remove `hermes--buffer-sessions` setup from test fixtures.

5. Run full test suite after migration; fix any remaining failures.

## Files touched

| File | Change |
|------|--------|
| `hermes-state.el` | Add global `hermes--sessions`, `hermes--global-state`, `hermes--org-buffers`, `hermes--bench-buffers`. Remove `hermes--state` (defvar-local). Simplify read/write/dispatch. Add `hermes--on-session-buffer` macro. |
| `hermes-org.el` | Remove `hermes--buffer-sessions` and `hermes--session-markers`. Flatten registrations. |
| `hermes-mode.el` | Make all `hermes-state-change-hook` entries global (remove LOCAL). `hermes--render` → buffer-aware. Update session-creation/detach to use global registries. |
| `hermes-bench.el` | Remove parent-buffer indirection. Use `hermes--bench-buffers` + session-id. |
| `hermes-render.el` | Replace `hermes--state` reads with `hermes--state-slot-read`. |
| `hermes-input.el` | Replace `hermes--state` reads. |
| `hermes-prompts.el` | Replace `hermes--state` reads. |
| `hermes-skin.el` | Replace `hermes--state` reads. |
| `hermes-config.el` | Replace `hermes--state` reads. |
| `hermes-bg.el` | Replace `hermes--state` reads. |
| `hermes-sessions.el` | Replace `hermes--state` reads; update registrations. |
| `hermes-image.el` | Replace `hermes--state` reads. |
| `hermes-project.el` | Replace `hermes--state` reads (cwd access). |
| `hermes-notifications.el` | Update to use global table (already uses global hook). |
| test/ | Add `hermes-test--reset-global-state`. Migrate all test files. |

## What this plan does NOT cover

- No magit-section viewer (plan 02)
- No `turns` slot in `hermes-state` (plan 02)
- No `id` slot in `hermes-message` (plan 02 — unblocks visibility cache)
- No conversation buffer mode (plan 02)
- No streaming changes — org renderer stays as-is
- No entry point changes — `M-x hermes` unchanged
- No `hermes-close-session` command (future — explicit cleanup deferred)
