# PLAN 05: Buffer-agnostic send + session picker

## Goal

Decouple `hermes-send` from buffer mode checks.  The command should work
from any buffer — `hermes-section-mode`, `hermes-org-minor-mode`, the
bench, a shell buffer — by resolving the target session from context or
falling back to a minibuffer session picker.  When no sessions exist,
`hermes-send` creates one (headless — no viewer buffer popped) and sends.

Additionally, `M-x hermes-section` gains a session picker for
pre-existing sessions instead of silently reusing the most recent one.

## 1. `hermes-send` becomes buffer-agnostic

### 1.1 Current behaviour

`hermes-input.el:371-372` guards with a mode check:

```elisp
(unless (bound-and-true-p hermes-org-minor-mode)
  (user-error "Not in a Hermes buffer (enable `hermes-org-minor-mode' ...)"))
```

This rejects sends from `hermes-section-mode`, the bench, and any
arbitrary buffer.  The user must be in an org buffer with the minor mode
active — even if a live session is open in another frame.

### 1.2 Target behaviour

`hermes-send` accepts input from any buffer.  Resolution order:

```
1. hermes-section-mode     → hermes--current-session-id (buffer-local)
2. hermes-org-minor-mode   → point-walk container headings (existing)
3. hermes-bench-mode       → delegate to parent buffer (existing)
4. No match                → fallback path:
     a. If live sessions exist → minibuffer picker
     b. If no sessions         → auto-create headless, then send
```

### 1.3 Updated `hermes-send`

```elisp
(defun hermes-send (text)
  "Submit TEXT to a Hermes session.
Resolves the target session from buffer context (section view, org
minor-mode, bench).  When no session is reachable from the current
buffer, offers a minibuffer picker over all live sessions.  When no
session exists, creates a headless session and sends to it."
  (interactive
   (let* ((hermes-input--catalog-from-minibuffer
           (and (hermes--current-state)
                (hermes-state-slash-catalog (hermes--current-state))))
          (sym (make-symbol "hermes-input-history-var")))
     (set sym (and (hermes--current-state)
                   (hermes-state-history (hermes--current-state))))
     (minibuffer-with-setup-hook
         (lambda ()
           (use-local-map hermes-input-minibuffer-map)
           (add-hook 'completion-at-point-functions
                     #'hermes-input-completion-at-point nil t))
       (list (read-string "Hermes> " nil sym)))))
  ;; Short-circuit empty/whitespace early — no-op, no target resolution.
  (unless (or (null text) (string-empty-p (string-trim text)))
    (let* ((target (hermes--resolve-session-target))
         (target-sid (car target))
         (target-state (cdr target)))
    (cond
     ;; Stale heading (has sid but no in-memory state) — prompt the user
     ;; with the existing load-org / resume-from-DB / branch-from-DB flow.
     ;; This is kept inline (not extracted to a separate function)
     ;; because the four branches have heterogeneous side effects that
     ;; don't fit a clean return contract.
     ((and target-sid (null target-state))
      (let ((choice (hermes--prompt-stale-heading target-sid))
            (marker (hermes--container-marker-at-point)))
        (pcase choice
          ('load-org
           (when (and text (not (string-empty-p text)))
             (push (cons target-sid text) hermes--pre-send-queue))
           (hermes--create-fresh-session target-sid marker)
           (message "Hermes: loading fresh session from org…"))
          ('resume-db
           (require 'hermes-sessions)
           (hermes-resume-from-db target-sid)
           (message "Hermes: resumed into new buffer — resend prompt there"))
          ('branch-db
           (require 'hermes-sessions)
           (hermes-branch-from-db target-sid)
           (message "Hermes: branched into new buffer — resend prompt there"))
          (_ (message "Cancelled")))))
     ;; Live target from buffer context → send directly.
     ((and target-sid target-state)
      (let ((hermes--current-session-id target-sid))
        (hermes-input--send-1 text)))
     ;; No target at all → pick from live sessions or auto-create headless.
     (t (hermes--select-or-create-session text)))))
```

**Key changes from current code:**

- The `hermes-org-minor-mode` guard at `hermes-input.el:371-372` is deleted.
- Empty/whitespace text short-circuits before any target resolution.
- `hermes--current-session-id` is let-bound around `hermes-input--send-1`
  rather than passed as an argument (the function reads it dynamically).
- The stale-heading handling stays inline (was always inline — no extraction).
- The fallback for unresolved targets goes through `hermes--select-or-create-session`
  (new function, see §2).

### 1.4 `hermes--resolve-session-target` — new section-mode arm

```elisp
(defun hermes--resolve-session-target ()
  "Return (SID . STATE) for the active session, or nil."
  (cond
   ;; ... existing arms for hermes--org-buffers, hermes-org-minor-mode,
   ;;     hermes-bench-mode ... stay unchanged ...

   ;; Section view: read session-id from the buffer-local variable.
   ;; Section buffers always have a live session (set by
   ;; hermes-section--open), so read sid and look up state directly
   ;; in hermes--sessions.  Do NOT use hermes--state-slot-read, which
   ;; never returns nil for known sids (falls back to hermes--global-state).
   ((derived-mode-p 'hermes-section-mode)
    (let ((sid (buffer-local-value 'hermes--current-session-id
                                   (current-buffer))))
      (and sid (cons sid (gethash sid hermes--sessions)))))

   ;; ... fallthrough → nil ...
   ))
```

**Why `gethash` not `hermes--state-slot-read`:** `hermes--state-slot-read`
falls back to `hermes--global-state` when the sid is not found in
`hermes--sessions`.  Since section buffers are always created with a live
session, sid lookup should return nil if somehow absent, not silently
return the global-state struct.

## 2. Session picker

`hermes--select-or-create-session` is the fallback when no session is
reachable from the current buffer context:

```elisp
(defun hermes--select-or-create-session (text)
  "Pick a live session or create a headless one; then send TEXT.
If live sessions exist, prompt the user to pick one via minibuffer
completion.  If none exist, auto-create a headless session (start
the gateway if needed).  Headless sessions have no displayed viewer
buffer; the user can later attach via `hermes-section' or
`hermes-org-minor-mode'."
  (let ((sessions (hermes--list-active-sessions)))
    (if (null sessions)
        (hermes--create-and-send-headless text)
      (hermes--select-session-and-send sessions text))))
```

`hermes--list-active-sessions` returns an alist `(("sid-1" . state-1) ...)`.
**All** live sessions are shown — no filter for turn count.  Sorted by
recency (most recent last-turn timestamp first).  An empty session is
perfectly valid to send to (it just hasn't had a turn yet).

`hermes--select-session-and-send` shows a completing-read with annotated
entries:

```elisp
(defun hermes--select-session-and-send (sessions text)
  "Prompt for a session via minibuffer completion, then send TEXT to it."
  (let* ((choices (hermes--session-completion-table sessions))
         (name    (completing-read "Session: " choices nil t
                                   nil nil  ; no initial input, no hist
                                   (hermes--most-recent-session-id))))
     (unless (string-empty-p name)
       (let ((sid (car (rassoc name choices #'string=))))
         (when sid
           (let ((hermes--current-session-id sid))
             (hermes-input--send-1 text)))))))
```

**DEF parameter note:** `completing-read`'s 6th positional argument is
`DEF` (the default value offered on empty `RET`).  The 5th
(`INITIAL-INPUT`) is deprecated.  We pass `nil nil` for the 4th–5th
args and place `(hermes--most-recent-session-id)` as the 6th, so the
most-recent session is the default.

Each choice is formatted: the display string shows session age and an
excerpt of the last user message.  The return value is the raw
session-id.

```elisp
;; Example completion display:
;;   "sid-x  What is the capital of France?  (2 min ago)"
;;   "sid-y  Write a Python script that...    (15 min ago)"
;;   "sid-z  Hello                            (2 hours ago)"
```

### 2.1 Headless sessions

When no session exists, `hermes--create-and-send-headless` calls
`hermes-new-session` with a callback that sends TEXT once the session-id
is bound.  The session's org buffer is created but **not popped** — the
user never sees it unless they later open it via `hermes-section` or
`hermes`.

**This is fully async — no `accept-process-output` blocking loop.**
The transport is callback-based; the callback fires when `session.create`
resolves.

```elisp
(defun hermes--create-and-send-headless (text)
  "Create a headless session and send TEXT to it.
Returns immediately; sending happens asynchronously once
session.create resolves."
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (hermes-new-session
   (lambda (buf)
     (when buf
       (let ((sid (buffer-local-value 'hermes--current-session-id buf)))
         (hermes-input--send-1 text))))))
```

`hermes-new-session` → `hermes--do-session-create` already handles
gateway startup, `session.create`, state registration,
`gateway.ready` replay, and catalog fetch.  The callback receives the
new org buffer; we extract its `hermes--current-session-id` (set
during `hermes--ensure-container`) and fire `hermes-input--send-1`
with it dynamically bound.

## 3. `M-x hermes-section` with session picker

When live sessions exist, instead of silently reusing the most recent
one, offer the picker.  Before opening, check `hermes-section--buffers`
to avoid creating a duplicate section buffer for a session that already
has one.

```elisp
(defun hermes-section (&optional arg)
  "Open the magit-section conversation viewer.

With prefix ARG, always create a new session.
If live sessions exist, offer the session picker (checking
`hermes-section--buffers' first for an existing viewer).
If no sessions exist, create one and open the view."
  (interactive "P")
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ;; Already in a section buffer → focus
   ((derived-mode-p 'hermes-section-mode)
    (message "Already in a Hermes section buffer"))
   ;; Explicit new session
   (arg
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf)
          buf)))))
   ;; Existing sessions → pick one (check for existing viewer first)
   ((hermes--session-exists-p)
    (let ((sid (hermes--maybe-pick-session)))
      (when sid
        ;; Avoid duplicate section buffers for the same session.
        (if-let ((existing (gethash sid hermes-section--buffers)))
            (when (buffer-live-p existing)
              (pop-to-buffer existing))
          (hermes-section--open sid)))))
   ;; No sessions → create and open
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf)
          buf)))))))
```

`hermes--maybe-pick-session` wraps the completing-read picker (same
function used by `hermes--select-session-and-send`) but returns just the
raw sid without sending:

```elisp
(defun hermes--maybe-pick-session ()
  "Offer a session picker; return the chosen sid, or nil on cancel."
  (let* ((sessions (hermes--list-active-sessions))
         (choices  (hermes--session-completion-table sessions))
         (name     (completing-read "Session: " choices nil t
                                    nil nil
                                    (hermes--most-recent-session-id))))
    (unless (string-empty-p name)
      (car (rassoc name choices #'string=)))))
```

## 4. `hermes--select-session` opening viewers

When the user picks a session from the picker (e.g. via `hermes-section`
or `hermes-send` fallback) and that session has no active viewer buffer:

- **From `hermes-section`**: open the section view for the picked session
  (checking `hermes-section--buffers` first to avoid duplicates).
- **From `hermes-send`**: just send — no viewer opened.  The send itself
  is the primary action; the user chose to send, not to view.

If the session already has a viewer, `hermes-section--open` finds it
and pops it instead of creating a duplicate.

## 5. What this plan does NOT cover

| Feature | Status |
|---------|--------|
| Session killing (explicit `hermes-close-session`) | No — deferred.  `remhash` is currently triggered manually or on reconnect. |
| Session renaming | No |
| Stale-heading UX improvements | No — existing load-org/resume-db/branch-db flow stays as-is |
| Batch operations across sessions | No |
| Multiple simultaneous bench windows per session | No — one bench per session |

## 6. Files touched

| File | Change |
|------|--------|
| `hermes-input.el` | Remove `hermes-org-minor-mode` guard. Rewrite `hermes-send` to use new resolution flow with short-circuit, let-bound sid, stale-heading inline, and fallback picker/headless path. Add `hermes--select-or-create-session`, `hermes--select-session-and-send`, `hermes--create-and-send-headless`. |
| `hermes-org.el` | Add `hermes-section-mode` arm to `hermes--resolve-session-target`. |
| `hermes-state.el` | Add `hermes--list-active-sessions`, `hermes--session-completion-table`. |
| `hermes-section.el` | Update `hermes-section` entry point with session picker; check `hermes-section--buffers` before `hermes-section--open`. Add `hermes--maybe-pick-session`. |
| `test/` | Add ERT tests for send-from-section-buffer, send-from-arbitrary-buffer, session picker, headless creation. |

## 7. References

| What | Where |
|------|-------|
| `hermes-send` | `hermes-input.el:355` |
| `hermes-input--send-1` | `hermes-input.el:469` |
| `hermes--resolve-session-target` | `hermes-org.el:165` |
| `hermes-section-mode` | `hermes-section.el` |
| `hermes-section--buffers` | `hermes-state.el:173` |
| `hermes-section--open` | `hermes-section.el:231` |
| `hermes--most-recent-session-id` | `hermes-state.el:180` |
| `hermes--session-exists-p` | `hermes-state.el:176` |
| `hermes--sessions` | `hermes-state.el:156` |
| `hermes--state-slot-read` | `hermes-state.el:218` |
| `hermes-new-session` | `hermes-mode.el:347` |
| `hermes--do-session-create` | `hermes-mode.el:306` |
| `hermes--prompt-stale-heading` | `hermes-input.el` |
| `hermes--create-fresh-session` | `hermes-org.el` |
| `hermes--pre-send-queue` | `hermes-org.el:207` |
