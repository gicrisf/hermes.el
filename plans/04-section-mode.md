# PLAN 04: Magit-section conversation viewer (`hermes-section.el`)

## Goal

Add a `hermes-section-mode` buffer — a read-only magit-section view
of the canonical conversation history (`turns`).  This is the first
alternative renderer built on the in-memory state from plans 01 and 03.

No streaming, no nested segments, no inline input.  Just committed
collapsible turns grounded in the fundamentals: `turns + magit-section =
UI`.

## 1. Architecture: projections, not authorities

```
hermes--sessions[sid].turns  ← canonical history (sole authority)
       ↕                     ↕
  magit view             org buffer
  (reads turns,          (drains pending-turns,
   rebuilds on change)    renders via org renderer)
```

Both views **project** the same state.  Neither mutates it directly.
Only `hermes--reduce` modifies state.  The user sends prompts; the
reducer appends to `pending-turns` and `turns`; both views update on
`hermes-state-change-hook`.

**Why not edit org text?**  The org buffer is a projection.  If the user
edits the rendered text, those edits do not propagate to state.  The
org-minor-mode path with manual bench is the current battle-tested org
path — users who want to edit prose in an org buffer do so there.  For
the conversation view, history is stable.

**Export and fork** bridge the two worlds:

```
magit view ──reads── state[sid].turns
  │
  ├── C-c C-e  hermes-section-export → writes .org file (snapshot)
  │
  └──                                          (no sync — fork instead)

org buffer ──has── org text
  │
  └── M-x hermes-section-fork → parse .org → new state[sid2].turns
                                          → new magit view (separate session)
```

Export creates a portable snapshot.  Fork creates a new session from
parsed org data — same as the existing `hermes-resume-from-db` pattern
on the org side.  The original org file and the new magit session are
independent; edits to one never affect the other.

## 2. Section tree (V1 — flat per turn)

```
conversation                              ;; root, invisible
├── user       (id="msg-1", hide=t)       ;; collapsed by default
│   ├── heading:  "U: Hello, can you..."
│   └── body:     Hello, can you help me with...
├── assistant  (id="msg-2", hide=nil)     ;; expanded by default
│   ├── heading:  "A: Sure! Let me look..."
│   └── body:     Sure! Let me look into that...
├── user       (id="msg-3", hide=t)
├── assistant  (id="msg-4", hide=nil)
│   ...
```

Each section stores the message `id` as its `value`.  magit-section's
visibility cache keys on value — collapse states survive rebuilds.

All sections use `magit-insert-section-body` with the `washer` approach:
collapsed sections defer body insertion until first expanded.  Large
responses don't pay the insertion cost until the user opens them.

## 3. Section classes

```elisp
(defclass hermes-section-turn-section (magit-section)
  ((selective-highlight :initform t))
  "Base class for conversation turn sections.
Selective-highlight paints each section individually, so region
selection across sibling turns highlights each heading distinctly.")

(defclass hermes-section-user-section
    (hermes-section-turn-section) ()
  "A user turn section.")

(defclass hermes-section-assistant-section
    (hermes-section-turn-section) ()
  "An assistant turn section.")

(defclass hermes-section-system-section
    (hermes-section-turn-section) ()
  "A system turn section.")
```

## 4. Buffer registry

Following plan 01 §7, add the third viewer registry:

```elisp
(defvar hermes-section--buffers (make-hash-table :test 'equal)
  "Map session-id → magit conversation buffer.")
```

Register on mode activation, detach on `kill-buffer-hook`:

```elisp
;; In hermes-section-mode body:
(add-hook 'kill-buffer-hook #'hermes-section--detach nil t)

(defun hermes-section--detach ()
  "Detach this buffer from the conversation registry on kill."
  (when hermes--current-session-id
    (remhash hermes--current-session-id hermes-section--buffers)))
```

## 5. Major mode

```elisp
(define-derived-mode hermes-section-mode magit-section-mode
  "Hermes-Conversation"
  "Magit-section conversation viewer for Hermes sessions.
Reads from `turns' in the global `hermes--sessions' table.
Read-only; input via `hermes-send' (minibuffer)."
  (setq-local buffer-read-only t)
  ;; Visibility cache: preserve collapse states across rebuilds
  (setq-local magit-section-cache-visibility t)
  ;; Cross-buffer notification: subscribe to state changes globally.
  ;; The hermes--on-session-buffer macro switches into this buffer
  ;; when the dispatched session-id matches.
  (add-hook 'hermes-state-change-hook
            #'hermes-section--refresh t))

(defvar-local hermes-section--turns-snapshot nil
  "Last-seen `turns' vector for eq-based change detection.")
```

**Keymap** inherits magit-section navigation (`TAB`, `n`, `p`, `M-n`,
`M-p`, `^`, `1`–`4`) plus:

| Key | Command |
|-----|---------|
| `g` | `hermes-section-refresh` (manual full rebuild) |
| `i` | `hermes-send` (minibuffer input) |
| `C-c C-k` | `hermes-interrupt-current-session` |
| `C-c C-e` | `hermes-section-export` |
| `q` | `quit-window` |
| `RET` | `hermes-section-inspect-turn-at-point` (V1 — show message struct in temp buffer) |

## 6. Cross-buffer notification (hook routing)

Plan 01 made `hermes-state-change-hook` global — subscribers fire in
whatever buffer called `hermes-dispatch`, not in the conversation
buffer itself.  The `hermes--on-session-buffer` macro from plan 01 §6
handles this:

```elisp
(defun hermes-section--refresh (old new)
  "Rebuild the conversation buffer when `turns' changes.
Runs in whatever buffer triggered the hook; uses
hermes--on-session-buffer to switch into the conversation buffer
for the changed session."
  (hermes--on-session-buffer hermes-section--buffers
    (unless (eq (hermes-state-turns new)
                hermes-section--turns-snapshot)
      (hermes-section--rebuild new))))
```

`hermes--on-session-buffer` checks `hermes--current-session-id`
(dynamically bound by `hermes-dispatch`).  If the conversation buffer
for that session is live, execution switches into it.  If no
conversation buffer exists for the session, the hook body is a no-op.

The `eq` check is the zero-cost filter — `hermes--reduce` uses
structural sharing, so most events (connection state, queue, stream
deltas, tool.progress) return the same `turns` vector reference.

`hermes-section--rebuild` is the nuke-and-replant:

```elisp
(defun hermes-section--rebuild (state)
  "Erase buffer and rebuild all sections from STATE."
  (let ((inhibit-read-only t)
        (turns (hermes-state-turns state)))
    (setq hermes-section--turns-snapshot turns)
    (save-excursion
      (erase-buffer)
      (magit-insert-section (conversation)
        (if (zerop (length turns))
            (insert "(No messages yet)\n")
          (seq-doseq (msg turns)
            (hermes-section--insert-turn msg)))))
    (magit-section-show magit-root-section)
    (magit-section-update-highlight)))
```

After the rebuild, `magit-section-show` on the root restores visibility
from the cache (which keyed on message ids via `magit-section-cache-visibility`).
Collapse states survive rebuilds.

## 7. Turn insertion

```elisp
(defun hermes-section--insert-turn (msg)
  "Insert MSG as a magit section at point."
  (let* ((kind    (hermes-message-kind msg))
         (text    (hermes-section--message-text msg))
         (class   (pcase kind
                    ('user      'hermes-section-user-section)
                    ('assistant 'hermes-section-assistant-section)
                    (_          'hermes-section-system-section)))
         (face    (pcase kind
                    ('user      'hermes-section-face-user)
                    ('assistant 'hermes-section-face-assistant)
                    (_          'hermes-section-face-system)))
         (label   (pcase kind
                    ('user "U")
                    ('assistant "A")
                    (_ "S")))
         (id      (hermes-message-id msg))
         (hide    (eq kind 'user)))       ;; user turns start collapsed
    (magit-insert-section ((eval class) id hide)
      ;; ^ (eval class) is magit's runtime-class resolution:
      ;;   the section class is determined dynamically from the
      ;;   pcase binding above rather than a compile-time symbol.
      (magit-insert-heading
        (propertize label 'face face)
        " " (hermes-section--excerpt text 75))
      (magit-insert-section-body
        (insert (hermes-section--format-body text))))))
```

## 8. Text helpers

- **`hermes-section--message-text`** — concatenates all `text` and
  `reasoning` segment content.  Skips `tool`, `image`, `system`.  Returns
  `"(empty)"` if no text or reasoning segments exist.

- **`hermes-section--excerpt`** — first non-blank line, truncated to
  N chars, newlines collapsed to spaces.

- **`hermes-section--format-body`** — strips Org comments, property
  drawers, `#+begin_…` blocks, drawer markers.  Rendered as plain text.

## 9. Faces

```elisp
(defface hermes-section-face-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user turn heading labels.")
(defface hermes-section-face-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant turn heading labels.")
(defface hermes-section-face-system
  '((t :inherit font-lock-builtin-face))
  "Face for system turn heading labels.")
```

Inherit from semantic faces (light/dark safe).  `hermes-skin.el` can
override them later.

## 10. Export and fork

**Export** — writes `turns` to an org file using a small inline
formatter.  No dependency on `hermes-render.el` (which assumes a live
session buffer with markers, property drawers, and container headings).
The export is a portable snapshot — not a resumable session:

```elisp
(defun hermes-section--org-insert-turn (msg)
  "Insert MSG as a simplified Org heading."
  (pcase (hermes-message-kind msg)
    ('user
     (insert "* User\n")
     (insert (hermes-section--message-text msg) "\n\n"))
    ('assistant
     (insert "* Assistant\n")
     (insert (hermes-section--message-text msg) "\n\n"))
    ('system
     (insert "* System\n")
     (insert (hermes-section--message-text msg) "\n\n"))))

(defun hermes-section-export (file)
  "Export the current conversation to an org FILE."
  (interactive "FExport to: ")
  (let* ((sid   hermes--current-session-id)
         (state (hermes--state-slot-read sid))
         (turns (hermes-state-turns state)))
    (with-temp-buffer
      (org-mode)
      (insert "#+TITLE: Hermes conversation export\n\n")
      (seq-doseq (msg turns)
        (hermes-section--org-insert-turn msg))
      (write-file file)
      (message "Exported %d turns to %s" (length turns) file))))
```

**Fork** — parse an org buffer, create a new session, seed its `turns`:

```elisp
(defun hermes-section-fork-from-org (buffer)
  "Create a new session from the conversation in org BUFFER."
  (interactive (list (read-buffer "Fork from org buffer: ")))
  (let ((msgs (with-current-buffer buffer
                (hermes--parse-buffer-messages))))  ;; current-buffer only
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p) (hermes-rpc-start))
    (hermes-new-session
     (lambda (buf)
       (when buf
         (let ((v (apply #'vector msgs))
               (sid (buffer-local-value
                     'hermes--current-session-id buf)))
           (hermes-dispatch
            (cons :turns-load (list :turns v))
            sid))
         (hermes-section--open sid)))))))
```

`hermes--parse-buffer-messages` works on `current-buffer` only — the
`with-current-buffer` wrapper ensures the org buffer is current during
parsing.

`:turns-load` payload: `(cons :turns-load (list :turns v))` produces
`(:turns-load :turns [...] )`.  `cdr` is `(:turns [...] )`, a plist.
`(plist-get p :turns)` in the reducer extracts the vector correctly.

Fork creates a **new** session — the original org file is untouched.
This matches the existing `hermes-resume-from-db` / `hermes-branch-from-db`
pattern on the org side.

## 11. Session lookup helpers

The entry point needs two functions that don't exist yet:

```elisp
(defun hermes--session-exists-p ()
  "Return non-nil when at least one session is in the global table."
  (> (hash-table-count hermes--sessions) 0))

(defun hermes--most-recent-session-id ()
  "Return the session-id of the most recently dispatched session, or nil.
Walks `hermes--sessions' and returns the one with the newest
`hermes-message-timestamp' in its `turns' vector."
  (let (best-id best-ts)
    (maphash
     (lambda (sid st)
       (let ((turns (hermes-state-turns st)))
         (when (> (length turns) 0)
           (let ((ts (hermes-message-timestamp (aref turns (1- (length turns))))))
             (when (or (null best-ts) (time-less-p best-ts ts))
               (setq best-id sid best-ts ts))))))
     hermes--sessions)
    best-id))
```

`hermes-section--open` creates (or reuses) the conversation buffer:
  "Open a magit conversation buffer for session SID.
If BUF is non-nil, use that buffer (already created by
hermes-new-session).  Otherwise create one."
  (let ((buf (or buf (generate-new-buffer
                      (format "*hermes-section:%s*" sid)))))
    (with-current-buffer buf
      (hermes-section-mode)
      (setq hermes--current-session-id sid)
      (puthash sid buf hermes-section--buffers)
      ;; Initial paint of current turns
      (let ((state (hermes--state-slot-read sid)))
        (when state
          (hermes-section--rebuild state))))
    (pop-to-buffer buf)))
```

## 12. Entry point

```elisp
(defun hermes-section (&optional arg)
  "Open a magit-section conversation viewer.

With prefix ARG, always create a new session.  Otherwise reuses the
most recently active session if one exists.  If no live sessions exist,
creates a fresh one (starts the gateway if needed)."
  (interactive "P")
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ;; Already a magit conversation buffer → focus it
   ((derived-mode-p 'hermes-section-mode)
    (message "Already in a Hermes conversation buffer"))
   ;; Reuse an existing live session
   ((and (not arg) (hermes--session-exists-p))
    (hermes-section--open
     (hermes--most-recent-session-id)))
   ;; Create a fresh session
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf)
          buf)))))))
```

`M-x hermes` stays the org entry point.  `M-x hermes-section` is
the new command.  Both work; both show the same session when pointed at
the same session-id; users pick which view they prefer.

## 13. Coexistence with the org view

Both buffers subscribe to `hermes-state-change-hook` (global, no LOCAL,
per plan 01 §4.3).  When the reducer appends to `turns`, the hook fires
and each subscriber switches into its target buffer:

- **Magit view** — `hermes--on-session-buffer` switches into the
  conversation buffer. `eq` compares `turns` snapshot; if changed,
  `erase-buffer` + rebuild all sections.  Visibility cache restores
  collapse states.  Cursor stays at last turn (point-max).

- **Org view** — `hermes--on-session-buffer` switches into the org
  buffer. `hermes--render` drains `pending-turns`.  Commits new
  user/assistant headings to the org buffer.  Streaming works as before.
  The bench updates if visible.

| Scenario | Magit view | Org view |
|----------|-----------|----------|
| User sends prompt | New "U:" turn appears | New user heading appears |
| Assistant responds | New "A:" turn on message.complete | Assistant streamed in real-time, sealed on complete |
| User switches between views | Point at last turn, state identical | Point at last heading, state identical |
| User edits org text manually | Magit state unchanged (no sync) | Org buffer diverged from `turns` — user must fork to reconcile |
| User kills one buffer | Other keeps working (global state survives) | Other keeps working |

## 14. What this plan does NOT cover

| Feature | Status |
|---------|--------|
| Streaming (live token-by-token) | No — committed turns only |
| Nested sections (reasoning, tools, subagents) | No — flat U/A sections |
| Inline input area | No — minibuffer `hermes-send` only |
| Segmented rendering (per-segment sections) | No — plain body text |
| Markdown→Org conversion in body | No — plain text only |
| Edit sync (org → magit) | No — fork instead |
| `M-x hermes` rename | No — separate `M-x hermes-section` |
| Bench replacement | No — bench stays with org view |

## 15. Sequence

| Step | File | Description |
|------|------|-------------|
| 1 | `hermes-state.el` | Add `hermes-section--buffers` (plan 01 §7 reserved it). Add `hermes--session-exists-p`, `hermes--most-recent-session-id`. |
| 2 | `hermes-section.el` | New file: section classes, major mode, hook routing, refresh pipeline, section builders, text helpers, faces, keymap, `hermes-section--detach`, `hermes-section--open`, entry point, export, fork. |
| 3 | `AGENTS.md` | Update architecture section. |
| 4 | test/ | Add ERT tests for turn insertion, rebuild on `turns` change, export format, fork round-trip. |

## 16. References

| What | Where |
|------|-------|
| `hermes-state-turns` + `hermes-message-id` | `hermes-state.el` (plan 03) |
| `hermes--sessions` global table | `hermes-state.el` (plan 01) |
| `hermes--on-session-buffer` macro | `hermes-state.el` (plan 01 §6) |
| `hermes-section--buffers` registry | `hermes-state.el` (plan 01 §7) |
| magit-section source / docs | `lisp/magit-section.el` in [magit/magit](https://github.com/magit/magit) |
| `hermes-render.el` org-formatting | Not used — export uses inline formatter to avoid session-buffer assumptions |
| `hermes--push-committed` | `hermes-state.el` (plan 03) |
| `hermes--parse-buffer-messages` | `hermes-mode.el` (existing, current-buffer only) |
| `hermes-new-session` | `hermes-mode.el` (existing) |
