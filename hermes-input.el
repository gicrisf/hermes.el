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

(declare-function hermes-reconnect "hermes-mode" ())
(declare-function hermes--parse-buffer-messages "hermes-mode" ())
(declare-function hermes--buffer-message-count "hermes-mode" ())
(declare-function hermes--message-text-for-display "hermes-render" (msg))

(defvar-local hermes-input--history nil
  "Buffer-local mirror of `hermes-state-history' for `read-string' HISTORY.")

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
Compared against `(hermes-state-session-id hermes--state)' before
every outgoing `prompt.submit'.  When the current session id differs
from this value (or this value is nil) and the buffer has committed
turns, a history text block is prepended to the wire payload and this
variable is updated to the current session id.

State-driven rather than event-driven: any prompt sent against a new
gateway session — fresh start, reconnect, post-reconnect drain, or
opening a saved file while the gateway is already up — is seeded
exactly once, no matter which call path reached `prompt.submit'.
Slash commands take a different RPC path (`slash.exec') and never
participate in the comparison.")

(defun hermes--build-history-text ()
  "Return a text block reconstructed from buffer history, or nil.
Reads `:HERMES_RAW:' drawers, formats each turn as a \"Role: text\"
pair, and truncates to the last `hermes-history-seed-max-turns' turns.
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
  (let ((sid (hermes-state-session-id hermes--state)))
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

;;;; Post-reconnect drain

(defun hermes-input--drain-after-reconnect ()
  "After a reconnect, send the head of the queue (if any) on the new session.
Subsequent items keep draining via the normal `message.complete' hook."
  (let ((q (hermes-state-queue hermes--state))
        (sid (hermes-state-session-id hermes--state)))
    (when (and q sid)
      (let* ((head (car q))
             (wire (hermes-input--seed-prefix head)))
        (hermes-dispatch '(:dequeue))
        (hermes-rpc-request
         "prompt.submit"
         (list :session_id sid :text wire)
         (lambda (_r e)
           (when e (message "hermes: post-reconnect submit error: %S" e))))))))

;;;; Drain hook — fires when an in-flight stream transitions to nil.

(defun hermes-input--drain (old new)
  "If a turn just finished and the queue is non-empty, dispatch its head.
Display happens here — not at enqueue time — so the new `* user:'
heading lands at point-max only after the previous turn has fully
committed.  This is the pi-coding-agent pattern: invisible queue,
deferred user-submit."
  (when (and old
             (hermes-state-stream old)
             (null (hermes-state-stream new))
             (hermes-state-queue new))
    (let ((sid (hermes-state-session-id new))
          (head (car (hermes-state-queue new))))
      (hermes-dispatch '(:dequeue))
      (hermes-dispatch (cons :user-submit (list :text head)))
      (when sid
        (let ((wire (hermes-input--seed-prefix head)))
          (hermes-rpc-request
           "prompt.submit"
           (list :session_id sid :text wire)
           (lambda (_r e)
             (when e (message "hermes: queued prompt.submit error: %S" e)))))))))

;;;; Catalog fetch

(defun hermes-input-fetch-catalog ()
  "Request `commands.catalog' and dispatch the result into this buffer."
  (let ((buf (current-buffer)))
    (hermes-rpc-request
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

(defun hermes-input--slash-catalog-pairs ()
  "Return the catalog's `pairs' as a list, or nil."
  (let ((cat hermes-input--catalog-from-minibuffer))
    (when (hash-table-p cat)
      (let ((pairs (gethash "pairs" cat)))
        (cond ((vectorp pairs) (append pairs nil))
              ((listp pairs)   pairs))))))

(defun hermes-input-completion-at-point ()
  "completion-at-point function for `/'-prefixed slash commands."
  (save-excursion
    (let ((end (point))
          (bol (line-beginning-position)))
      (when (and (> end bol)
                 (eq (char-after bol) ?/))
        (let* ((beg (1+ bol))
               (pairs (hermes-input--slash-catalog-pairs))
               (names (mapcar (lambda (p)
                                (cond ((stringp p) p)
                                      ((vectorp p) (aref p 0))
                                      ((consp p)   (car p))))
                              pairs)))
          (when names
            (list beg end names
                  :annotation-function
                  (lambda (cand)
                    (let* ((pair (cl-find-if
                                  (lambda (p)
                                    (equal cand
                                           (cond ((stringp p) p)
                                                 ((vectorp p) (aref p 0))
                                                 ((consp p)   (car p)))))
                                  pairs))
                           (desc (cond ((vectorp pair) (and (> (length pair) 1)
                                                            (aref pair 1)))
                                       ((consp pair)  (cdr-safe pair)))))
                      (and (stringp desc) (concat " — " desc)))))))))))

(defvar hermes-input-minibuffer-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m minibuffer-local-map)
    (define-key m (kbd "TAB") #'completion-at-point)
    m)
  "Keymap used while reading input via `hermes-send'.")

;;;; Public entry — replaces the M2 `hermes-send'.

(defun hermes-input-send (text)
  "Submit TEXT to the current Hermes session.
Slash commands bypass the queue and transcript; idle text is committed
immediately, while busy text is queued silently and sent when the turn
ends."
  (interactive
   (let* ((hermes-input--catalog-from-minibuffer
           (and hermes--state (hermes-state-slash-catalog hermes--state)))
          (sym (make-symbol "hermes-input-history-var")))
     (set sym (and hermes--state (hermes-state-history hermes--state)))
     (minibuffer-with-setup-hook
         (lambda ()
           (use-local-map hermes-input-minibuffer-map)
           (add-hook 'completion-at-point-functions
                     #'hermes-input-completion-at-point nil t))
       (list (read-string "Hermes> " nil sym)))))
  (unless (or (derived-mode-p 'hermes-mode)
              (bound-and-true-p hermes-minor-mode))
    (user-error "Not in a Hermes buffer (enable `hermes-minor-mode' in this Org buffer first)"))
  ;; Resolve which session this send targets and, if it differs from
  ;; the buffer-local `hermes--state', dynamically rebind so downstream
  ;; reads/dispatches target the right slot.  In a `hermes-mode' buffer
  ;; the resolved state IS the buffer-local one — we must NOT let-bind
  ;; it there, otherwise dispatch's `setq hermes--state' would only
  ;; mutate the dynamic binding and revert on exit, losing the queue.
  (let* ((target (hermes--resolve-session-target))
         (target-sid (car target))
         (target-state (cdr target))
         (hermes--current-session-id target-sid))
    (cond
     ;; No container at all → user must create one first.
     ((null target)
      (user-error "No Hermes session at point — use `M-x hermes-create-session-here' or move into a `:hermes:' subtree"))
     ;; Stale: heading has a session id but the registry has no entry
     ;; (file was reopened, gateway restarted, etc.).  Stash the text
     ;; and trigger an async resume; the callback drains and submits.
     ((null target-state)
      (when (and text (not (string-empty-p text)))
        (push (cons target-sid text) hermes--pre-send-queue)
        (hermes--resume-heading-session target-sid)
        (message "Hermes: resuming session %s…" target-sid)))
     ;; Live state → send directly.  Only let-bind `hermes--state' when
     ;; the resolved state differs from the buffer-local — otherwise the
     ;; dynamic binding shadows the buffer-local and dispatch mutations
     ;; revert on exit (lost queue, lost history).
     ((eq target-state hermes--state)
      (hermes-input--send-1 text))
     (t
      (let ((hermes--state target-state))
        (hermes-input--send-1 text))))))

(defun hermes-input--send-1 (text)
  "Internal worker for `hermes-input-send'.  Assumes `hermes--state' and
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
  (let ((sid (hermes-state-session-id hermes--state)))
    (cond
     ;; Empty input or consumed by reconnect branch → no-op.
     ((or (null text) (string-empty-p text)) nil)
     ;; No session yet (e.g. reconnect in flight) — queue without dispatch.
     ((null sid)
      (hermes-dispatch (cons :user-submit (list :text text)))
      (hermes-dispatch (cons :enqueue     (list :text text))))
     ;; Slash command — fire immediately, no transcript, no history.
     ((eq (aref text 0) ?/)
      (let ((buf (current-buffer)))
        (hermes-rpc-request
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
     ((hermes-state-stream hermes--state)
      (hermes-dispatch (cons :enqueue (list :text text)))
      (message "Hermes: Message queued (%d ahead of you)"
               (length (hermes-state-queue hermes--state))))
     ;; Idle → optimistic commit + immediate prompt.submit.
     (t
      ;; Display the user's actual input — the seed prefix is for the
      ;; gateway only, not the transcript.
      (hermes-dispatch (cons :user-submit (list :text text)))
      (let ((wire-text (hermes-input--seed-prefix text)))
        (hermes-rpc-request
         "prompt.submit"
         (list :session_id sid :text wire-text)
         (lambda (_r e)
           (when e (message "hermes: prompt.submit error: %S" e)))))))))

(provide 'hermes-input)
;;; hermes-input.el ends here
