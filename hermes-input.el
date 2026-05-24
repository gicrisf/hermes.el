;;; hermes-input.el --- Input queue, slash commands, history -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; M4 input layer.  `hermes-send' reads a line via `read-string', with
;; per-buffer history and slash-name completion-at-point.  Submission
;; rules:
;;
;;   - Input starting with "/" → dispatched immediately via `slash.exec',
;;     bypassing the queue and the transcript.
;;   - Otherwise → optimistically committed (:user-submit, which also
;;     pushes onto history).  If a stream is in flight, it goes onto
;;     `hermes-state-queue'; the drain hook fires `prompt.submit' for the
;;     head when the stream clears.
;;
;; `commands.catalog' is fetched once after `gateway.ready' and cached on
;; every Hermes buffer's `hermes-state-slash-catalog'.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
(require 'hermes-rpc)
(require 'hermes-state)
(require 'hermes-org)

(declare-function hermes-new-session "hermes-session" (&optional callback))
(declare-function hermes-reconnect "hermes-org-minor-mode" ())
(declare-function hermes--parse-buffer-messages "hermes-org-minor-mode" ())
(declare-function hermes--buffer-message-count "hermes-org-minor-mode" ())
(declare-function hermes--message-text-for-display "hermes-org-render" (msg))
(declare-function hermes-interrupt-current-session "hermes-session" ())
(declare-function hermes-resume-from-db "hermes-sessions" (sid))
(declare-function hermes-branch-from-db "hermes-sessions" (sid))

(defvar-local hermes-input--history nil
  "Buffer-local mirror of `hermes-state-history' for `read-string' HISTORY.")

;;;; Background task command (/bg, /background, /btw)

(defconst hermes-input--bg-re
  "\\`\\s-*/\\(bg\\|background\\|btw\\)\\(?:\\s-+\\|\\'\\)"
  "Regex matching the background-task command prefix.
Requires whitespace or end-of-string after the alias so `/background'
matches but `/backgroundsomething' does not.  Used for both detection
and stripping; keeping them on a single source avoids drift.")

(defun hermes-input--is-background-p (text)
  "Return non-nil if TEXT begins with a background-task command prefix."
  (and text (string-match-p hermes-input--bg-re text)))

;;;; Session-management slash interception
;;
;; `/resume', `/sessions', `/delete' need an Emacs minibuffer picker —
;; the gateway implements server-side equivalents, but they open a
;; TUI-flavored selector that doesn't apply here.  Intercept those three
;; client-side before falling through to `slash.exec'.  Everything else
;; (`/title', `/branch', `/compress', `/undo', `/usage', `/save', …)
;; routes server-side as usual.

(defconst hermes-input--session-slash-re
  "\\`\\s-*/\\(resume\\|sessions\\|delete\\)\\(?:\\s-+\\(.*\\)\\)?\\s-*\\'"
  "Regex matching the session-management slashes handled in Emacs.
Group 1 is the bare command name; group 2 is the optional argument
text (currently unused — the pickers ignore arguments).")

(declare-function hermes-current-sessions "hermes-sessions" ())
(declare-function hermes-stored-resume "hermes-sessions" (&optional cwd-filter))
(declare-function hermes-stored-delete "hermes-sessions" (&optional cwd-filter))

(defun hermes-input--try-session-slash (text)
  "If TEXT is an intercepted session-management slash, dispatch it.
Return non-nil when handled, nil otherwise.  Side effect: pops the
appropriate `completing-read' picker.  Any user argument is ignored
for v1 — the pickers carry the entire selection workflow."
  (when (string-match hermes-input--session-slash-re text)
    (pcase (match-string 1 text)
      ("resume"   (call-interactively #'hermes-stored-resume))
      ("sessions" (call-interactively #'hermes-current-sessions))
      ("delete"   (call-interactively #'hermes-stored-delete)))
    t))

(defun hermes-input--dispatch-background (text sid)
  "Send TEXT as a `prompt.background' RPC for session SID.
Strips the /bg prefix; on RPC response, dispatches `:background-start'
into the local state so the bench can show `[bg: N running]'."
  (let ((clean (replace-regexp-in-string hermes-input--bg-re "" text)))
    (hermes--request
     "prompt.background"
     (list :session_id sid :text clean)
     (lambda (result error)
       (cond
        (error (message "hermes: background prompt failed: %S" error))
        (result
         (let ((tid (hermes--get result "task_id")))
           (when tid
             (hermes-dispatch
              (list :background-start
                    :task-id (if (stringp tid) tid (format "%s" tid))
                    :prompt clean)
              sid)))))))))

;;;; History seed — prepend buffer-derived context to the first prompt
;;;; after the gateway connects against a buffer that already has turns.

(defcustom hermes-history-seed-max-turns 30
  "Maximum number of trailing turns to include in the history seed.
Older turns are dropped.  Set to nil for no limit.  The seed runs once
per gateway connection, so this cap only matters for the first prompt
after a reconnect or after opening a saved conversation file."
  :type '(choice (integer :tag "Last N turns")
                 (const :tag "No limit" nil))
  :group 'hermes)

(defvar-local hermes--seeded-session-id nil
  "Session id that was last seeded with history from this buffer.
Compared against `(hermes-state-session-id (hermes--current-state))' before
every outgoing `prompt.submit'.  When the current session id differs
from this value (or this value is nil) and the buffer has committed
turns, a history text block is prepended to the wire payload and this
variable is updated to the current session id.

State-driven rather than event-driven: any prompt sent against a new
gateway session — fresh start, reconnect, post-reconnect drain, or
opening a saved file while the gateway is already up — is seeded
exactly once, no matter which call path reached `prompt.submit'.
Slash commands take a different RPC path (`slash.exec') and never
participate in the comparison.

TEA: session-scoped state mutated via raw `setq' outside the reducer.
Move into a `:seed-stamp' slot on `hermes-state' with a dedicated
reducer action.")

(defun hermes--build-history-text ()
  "Return a text block reconstructed from buffer history, or nil.
Parses each turn from visible buffer structure (heading properties,
body text, and child headings), formats each turn as a Role:text
pair, and truncates to
the last `hermes-history-seed-max-turns' turns.
Returns nil when the buffer has no committed turns or every turn's
text is empty."
  (let* ((messages (hermes--parse-buffer-messages))
         (n        (length messages))
         (cap      hermes-history-seed-max-turns)
         (start    (if (and cap (> n cap)) (- n cap) 0))
         (truncated (and cap (> n cap))))
    (when (> n 0)
      (let (lines)
        (cl-loop for i from start below n
                 do (let* ((msg  (aref messages i))
                           (role (pcase (hermes-message-kind msg)
                                   ('user      "User")
                                   ('assistant "Assistant")
                                   ('system    "System")
                                   (_          "Unknown")))
                           (text (hermes--message-text-for-display msg)))
                      (when (and text (not (string-empty-p (string-trim text))))
                        (push (format "%s: %s" role text) lines))))
        (setq lines (nreverse lines))
        (when lines
          (concat
           "[The following is the previous conversation"
           (if truncated (format " (last %d turns of %d)" cap n) "")
           ", for context only.\n"
           "Do not repeat or echo any of it.  Respond only to the current\n"
           "message after \"---\".]\n\n"
           (mapconcat #'identity lines "\n\n")
           "\n\n---\n\nCurrent: "))))))

(defun hermes-input--seed-prefix (text)
  "Return TEXT prefixed with a history block if this gateway session
hasn't been seeded from this buffer yet; otherwise return TEXT.
Idempotent: stamps `hermes--seeded-session-id' with the current
session id on every call, so subsequent prompts on the same session
skip the seed.  Logs a user-visible message when seeding fires so
the user knows extra tokens are being consumed."
  (let ((sid (hermes-state-session-id (hermes--current-state))))
    (cond
     ;; No session yet — nothing to stamp against.  Leave TEXT alone;
     ;; the next call (once a session id lands) will seed.
     ((null sid) text)
     ;; This session has already been seeded (or born without history
     ;; needing a seed).  Pass through.
     ((equal sid hermes--seeded-session-id) text)
     ;; New session and the buffer has turns — seed and stamp.
     ((> (hermes--buffer-message-count) 0)
      (let ((history-text (hermes--build-history-text)))
        (setq hermes--seeded-session-id sid)
        (message "Hermes: seeding history for session %s" sid)
        (if history-text (concat history-text text) text)))
     ;; New session but no buffer history — stamp so we don't recheck
     ;; the buffer on every send for the lifetime of this session.
     (t (setq hermes--seeded-session-id sid) text))))

(declare-function hermes-project--build-context "hermes-project" (&optional state))
(defvar hermes-project-auto-context)

(defun hermes-input--wire-prefix (text)
  "Return TEXT prepared for the wire.
Prepends the history seed (once per session, via
`hermes-input--seed-prefix') and the project context (always on the
first prompt; on later prompts only when `hermes-project-auto-context'
is non-nil).

\"First prompt\" is detected by inspecting `hermes--seeded-session-id'
*before* calling `hermes-input--seed-prefix' (which stamps it as a side
effect).  Safe to call from any session buffer."
  (let* ((sid (hermes-state-session-id (hermes--current-state)))
         (first-prompt (and sid (not (equal sid hermes--seeded-session-id))))
         (seeded (hermes-input--seed-prefix text))
         (ctx (when (and (or first-prompt
                             (bound-and-true-p hermes-project-auto-context))
                         (fboundp 'hermes-project--build-context))
                (hermes-project--build-context))))
    (if ctx (concat ctx seeded) seeded)))

;;;; Post-reconnect drain

(defun hermes-input--drain-after-reconnect ()
  "After a reconnect, send the head of the queue (if any) on the new session.
Subsequent items keep draining via the normal `message.complete' hook."
  (let ((q (hermes-state-queue (hermes--current-state)))
        (sid (hermes-state-session-id (hermes--current-state))))
    (when (and q sid)
      (let* ((head (car q))
             (wire (hermes-input--wire-prefix head)))
        (hermes-dispatch '(:dequeue))
        (hermes--request
         "prompt.submit"
         (list :session_id sid :text wire)
         (lambda (_r e)
           (when e (message "hermes: post-reconnect submit error: %S" e))))))))

;;;; Drain hook — fires when an in-flight stream transitions to nil.

(defun hermes-input--drain (old new)
  "If a turn just finished and the queue is non-empty, dispatch its head.
Display happens here — not at enqueue time — so the new `* user:'
heading lands at point-max only after the previous turn has fully
committed.  Dispatches are scoped to the session in NEW so this
remains correct under the global state-change-hook."
  (when (and old
             (hermes-state-stream old)
             (null (hermes-state-stream new))
             (hermes-state-queue new))
    (let ((sid (hermes-state-session-id new))
          (head (car (hermes-state-queue new))))
      (hermes-dispatch '(:dequeue) sid)
      (hermes-dispatch (cons :user-submit (list :text head)) sid)
      (when sid
        (let ((wire (hermes-input--wire-prefix head)))
          (hermes--request
           "prompt.submit"
           (list :session_id sid :text wire)
           (lambda (_r e)
             (when e (message "hermes: queued prompt.submit error: %S" e)))))))))

;;;; Catalog fetch

(defun hermes-input-fetch-catalog ()
  "Request `commands.catalog' and dispatch the result into this buffer."
  (let ((buf (current-buffer)))
    (hermes--request
     "commands.catalog" nil
     (lambda (result error)
       (cond
        (error (message "hermes: commands.catalog error: %S" error))
        ((and result (buffer-live-p buf))
         (with-current-buffer buf
           (hermes-dispatch (cons :slash-catalog
                                  (list :catalog result))))))))))

;;;; Slash completion

(defvar hermes-input--catalog-from-minibuffer nil
  "Dynamically bound by `hermes-send' so the minibuffer can see the catalog.")

(defun hermes-input--catalog-pairs (catalog)
  "Return CATALOG's `pairs' as a list, or nil."
  (when (hash-table-p catalog)
    (let ((p (gethash "pairs" catalog)))
      (cond ((vectorp p) (append p nil))
            ((listp p)   p)))))

(defun hermes-input--pair-name (p)
  (cond ((stringp p) p)
        ((vectorp p) (aref p 0))
        ((consp p)   (car p))))

(defun hermes-input--pair-desc (p)
  (cond ((vectorp p) (and (> (length p) 1) (aref p 1)))
        ((consp p)  (cdr-safe p))))

(defun hermes-input--slash-doc-buffer (candidate catalog)
  "Return a buffer with the description of CANDIDATE from CATALOG, or nil."
  (let* ((pairs (hermes-input--catalog-pairs catalog))
         (pair  (cl-find-if (lambda (p)
                              (equal candidate (hermes-input--pair-name p)))
                            pairs))
         (desc  (hermes-input--pair-desc pair)))
    (when (and (stringp desc) (not (string-empty-p desc)))
      (let ((buf (get-buffer-create " *hermes-slash-doc*")))
        (with-current-buffer buf
          (setq buffer-read-only nil)
          (erase-buffer)
          (insert (format "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n%s\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n%s\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\nHermes slash command\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
                          candidate desc))
          (setq-local truncate-lines nil)
          (setq buffer-read-only t))
        buf))))

(defun hermes-input--slash-complete (beg end catalog)
  "Core CAPF worker for slash commands.
BEG and END delimit the completion region.  CATALOG is the hash-table
returned by `commands.catalog'.  Returns a CAPF value with
`:annotation-function' and `:company-doc-buffer', or nil."
  (let* ((pairs (hermes-input--catalog-pairs catalog))
         (names (mapcar #'hermes-input--pair-name pairs)))
    (when names
      (list beg end names
            :annotation-function
            (lambda (cand)
              (let* ((pair (cl-find-if
                            (lambda (p)
                              (equal cand (hermes-input--pair-name p)))
                            pairs))
                     (desc (hermes-input--pair-desc pair)))
                (and (stringp desc) (concat " — " desc))))
            :company-doc-buffer
            (lambda (cand)
              (hermes-input--slash-doc-buffer cand catalog))))))

(defun hermes-input-completion-at-point ()
  "completion-at-point function for `/'-prefixed slash commands.
Minibuffer context only — reads catalog from
`hermes-input--catalog-from-minibuffer' (dynamically bound by
`hermes-send')."
  (save-excursion
    (let ((end (point))
          (bol (line-beginning-position)))
      (when (and (> end bol)
                 (eq (char-after bol) ?/))
        (hermes-input--slash-complete
         (1+ bol) end hermes-input--catalog-from-minibuffer)))))

(defvar hermes-input-minibuffer-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m minibuffer-local-map)
    (define-key m (kbd "TAB") #'completion-at-point)
    m)
  "Keymap used while reading input via `hermes-send'.")

;;;; Public entry — replaces the M2 `hermes-send'.

(defun hermes-send (text)
  "Submit TEXT to a Hermes session.
Resolves the target session from buffer context (section view, org
minor-mode, bench).  When no session is reachable from the current
buffer, offers a minibuffer picker over all live sessions; if none
exist, creates a headless session and sends to it."
  (interactive
   (let* ((hermes-input--catalog-from-minibuffer
           (and (hermes--current-state) (hermes-state-slash-catalog (hermes--current-state))))
          (sym (make-symbol "hermes-input-history-var")))
     (set sym (and (hermes--current-state) (hermes-state-history (hermes--current-state))))
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
       ;; Kept inline because the four branches have heterogeneous side
       ;; effects that don't fit a clean return contract.
       ((and target-sid (null target-state))
        (let ((hermes--current-session-id target-sid)
              (choice (hermes--prompt-stale-heading target-sid))
              (marker (hermes--container-marker-at-point)))
          (pcase choice
            ('load-org
             (push (cons target-sid text) hermes--pre-send-queue)
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
       ;; No target — pick from live sessions or auto-create headless.
       (t (hermes--select-or-create-session text))))))

(defun hermes--select-or-create-session (text)
  "Pick a live session or create a headless one; then send TEXT.
If live sessions exist, prompt the user via minibuffer completion.
Otherwise create a headless session (starting the gateway if
needed) and send TEXT once `session.create' resolves."
  (let ((sessions (hermes--list-active-sessions)))
    (if (null sessions)
        (hermes--create-and-send-headless text)
      (hermes--select-session-and-send sessions text))))

(defun hermes--select-session-and-send (sessions text)
  "Prompt for a session over SESSIONS via completing-read, then send TEXT."
  (let* ((choices (hermes--session-completion-table sessions))
         (display->sid (mapcar (lambda (c) (cons (cdr c) (car c))) choices))
         (def-sid (hermes--most-recent-session-id))
         (def-display (and def-sid
                           (car (rassoc def-sid display->sid))))
         (name (completing-read "Session: "
                                (mapcar #'cdr choices)
                                nil t nil nil def-display)))
    (unless (or (null name) (string-empty-p name))
      (let ((sid (cdr (assoc name display->sid))))
        (when sid
          (let ((hermes--current-session-id sid))
            (hermes-input--send-1 text)))))))

(defun hermes--create-and-send-headless (text)
  "Create a headless session and send TEXT once it's ready.
Returns immediately; the send happens asynchronously when
`session.create' resolves.  The org buffer is created but not
popped — the user can later attach via `hermes' or `hermes-section'."
  (hermes-new-session
   (lambda (buf)
     (when (buffer-live-p buf)
       (with-current-buffer buf
         (let ((hermes--current-session-id
                (buffer-local-value 'hermes--current-session-id buf)))
           (hermes-input--send-1 text)))))))

;;;; Shell interpolation — !cmd and $(cmd)

(defun hermes-input--shell-matches (text)
  "Return a list of (BEG END COMMAND) for every $(...) substring in TEXT.
Non-greedy on the inner command body — does not recurse into nested $()."
  (let ((pos 0) matches)
    (while (string-match "\\$(\\([^)]+\\))" text pos)
      (push (list (match-beginning 0)
                  (match-end 0)
                  (match-string 1 text))
            matches)
      (setq pos (match-end 0)))
    (nreverse matches)))

(defun hermes-input--shell-format-error (e)
  (format "(error: %s)"
          (or (and (hash-table-p e) (gethash "message" e))
              (format "%S" e))))

(defun hermes-input--shell-format-result (r)
  (let ((stdout (gethash "stdout" r))
        (stderr (gethash "stderr" r))
        (code   (gethash "code"   r)))
    (concat (or stdout "")
            (if (and stderr (not (string-empty-p stderr)))
                (concat "\n" stderr) "")
            (if (and (numberp code) (not (zerop code)))
                (format "\n[exit %d]" code) ""))))

(defun hermes-input--shell-expand (text matches k)
  "Run shell.exec for each MATCH; call K with TEXT after substitution.
Substitutions are applied right-to-left to preserve byte offsets."
  (let* ((n (length matches))
         (results (make-vector n nil))
         (remaining n)
         (buf (current-buffer)))
    (cl-loop
     for idx from 0
     for m in matches do
     (let ((i idx)
           (cmd (nth 2 m)))
       (hermes--request
        "shell.exec" (list :command cmd)
        (lambda (r e)
          (let ((out (cond
                      (e (hermes-input--shell-format-error e))
                      ((hash-table-p r) (hermes-input--shell-format-result r))
                      (t ""))))
            (aset results i (string-trim-right out)))
          (setq remaining (1- remaining))
          (when (zerop remaining)
            (let ((expanded text))
              (cl-loop for j from (1- n) downto 0
                       for mm = (nth j matches)
                       do (setq expanded
                                (concat (substring expanded 0 (nth 0 mm))
                                        (aref results j)
                                        (substring expanded (nth 1 mm)))))
              (if (buffer-live-p buf)
                  (with-current-buffer buf (funcall k expanded))
                (funcall k expanded))))))))))

(defun hermes-input--send-1 (text)
  "Internal worker for `hermes-send'.  Assumes `(hermes--current-state)' and
`hermes--current-session-id' are bound to the target session."
  ;; If the gateway died, offer to reconnect.  The text is committed and
  ;; queued; `hermes-reconnect' creates a fresh session and drains the head
  ;; once it lands.
  (when (and text (not (string-empty-p text))
             (not (hermes-rpc-live-p)))
    (if (yes-or-no-p "Hermes gateway is down. Restart and create a new session? ")
        (progn
          (hermes-dispatch (cons :user-submit (list :text text)))
          (hermes-dispatch (cons :enqueue     (list :text text)))
          (hermes-reconnect)
          (setq text nil))               ; consumed
      (user-error "Hermes gateway is not running")))
  (let ((sid (hermes-state-session-id (hermes--current-state))))
    (cond
     ;; Empty input or consumed by reconnect branch → no-op.
     ((or (null text) (string-empty-p text)) nil)
     ;; Bang prefix — run shell command via gateway, show output as a system
     ;; message, do NOT submit to the model.  Mirrors the TUI's `!cmd' form.
     ((eq (aref text 0) ?!)
      (let ((cmd (substring text 1))
            (buf (current-buffer)))
        (if (string-empty-p cmd)
            (message "hermes: empty shell command")
          (hermes--request
           "shell.exec" (list :command cmd)
           (lambda (r e)
             (let* ((body (cond
                           (e (hermes-input--shell-format-error e))
                           ((hash-table-p r) (hermes-input--shell-format-result r))
                           (t "")))
                    (msg (format "$ %s\n%s" cmd body)))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (hermes-dispatch
                    (cons :system-message (list :text msg)))))))))))
     ;; $(cmd) interpolation — expand asynchronously, then recurse so the
     ;; expanded text flows through the normal slash/queue/submit logic.
     ;; Slash commands are exempt (`/` is dispatched verbatim).
     ((and (not (eq (aref text 0) ?/))
           (hermes-input--shell-matches text))
      (let ((matches (hermes-input--shell-matches text)))
        (hermes-input--shell-expand text matches #'hermes-input--send-1)))
     ;; No session yet (e.g. reconnect in flight) — queue without dispatch.
     ((null sid)
      (hermes-dispatch (cons :user-submit (list :text text)))
      (hermes-dispatch (cons :enqueue     (list :text text))))
     ;; Background task prefix — route to `prompt.background' rather than
     ;; the slash dispatcher.  Bypasses the transcript: the result is
     ;; rendered into a dedicated `*hermes-bg:<sid>:<tid>*' buffer when
     ;; `background.complete' fires.
     ((hermes-input--is-background-p text)
      (hermes-input--dispatch-background text sid))
     ;; Session-management slashes (`/resume', `/sessions', `/delete')
     ;; need an Emacs minibuffer picker — intercept before slash.exec.
     ((and (eq (aref text 0) ?/)
           (hermes-input--try-session-slash text))
      nil)
     ;; Slash command — fire immediately, no transcript, no history.
     ((eq (aref text 0) ?/)
      (let ((buf (current-buffer)))
        (hermes--request
         "slash.exec"
         (list :session_id sid :command (substring text 1))
         (lambda (result error)
           (let* ((raw
                   (cond
                    (error
                     (format "%s: %s" text
                             (or (and (hash-table-p error)
                                      (gethash "message" error))
                                 (format "%S" error))))
                    ((and (hash-table-p result)
                          (let ((out (gethash "output" result)))
                            (and out (not (string-empty-p out)) out))))))
                  (msg (and raw (ansi-color-apply raw))))
             (when (and msg (buffer-live-p buf))
               (with-current-buffer buf
                 (hermes-dispatch
                  (cons :system-message (list :text msg))))))))))
     ;; Live turn → enqueue silently; the drain hook will display and
     ;; submit when the in-flight stream clears.  Optimistic commit here
     ;; would place the `* user:' heading at `point-max', which sits
     ;; *after* the still-rendering assistant turn — corrupting structure.
     ;; See `hermes-input--drain' for the deferred user-submit + RPC.
     ((hermes-state-stream (hermes--current-state))
      (pcase (hermes-state-busy-mode (hermes--current-state))
        ("steer"
         (hermes--request
          "session.steer"
          (list :session_id sid :text text)
          (lambda (r e)
            (cond
             (e (message "hermes: steer error: %S" e))
             ((equal (and (hash-table-p r) (gethash "status" r)) "rejected")
              (message "hermes: steer rejected"))
             (t (message "hermes: steer queued"))))))
        ("interrupt"
         (hermes-interrupt-current-session)
         ;; After interrupt the stream clears; the drain hook will
         ;; submit this text once the queue head becomes head-of-line.
         (hermes-dispatch (cons :enqueue (list :text text))))
        (_  ; "queue" (default) or unknown
         (hermes-dispatch (cons :enqueue (list :text text)))
         (message "Hermes: Message queued (%d ahead of you)"
                  (length (hermes-state-queue (hermes--current-state)))))))
     ;; Idle → optimistic commit + immediate prompt.submit.
     (t
      ;; Display the user's actual input — the seed prefix is for the
      ;; gateway only, not the transcript.
      (hermes-dispatch (cons :user-submit (list :text text)))
      (let ((wire-text (hermes-input--wire-prefix text)))
        (hermes--request
         "prompt.submit"
         (list :session_id sid :text wire-text)
         (lambda (_r e)
           (when e (message "hermes: prompt.submit error: %S" e)))))))))

(provide 'hermes-input)
;;; hermes-input.el ends here
