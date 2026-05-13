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
(require 'hermes-rpc)
(require 'hermes-state)

(declare-function hermes-reconnect "hermes-mode" ())

(defvar-local hermes-input--history nil
  "Buffer-local mirror of `hermes-state-history' for `read-string' HISTORY.")

;;;; Post-reconnect drain

(defun hermes-input--drain-after-reconnect ()
  "After a reconnect, send the head of the queue (if any) on the new session.
Subsequent items keep draining via the normal `message.complete' hook."
  (let ((q (hermes-state-queue hermes--state))
        (sid (hermes-state-session-id hermes--state)))
    (when (and q sid)
      (let ((head (car q)))
        (hermes-dispatch '(:dequeue))
        (hermes-rpc-request
         "prompt.submit"
         (list :session_id sid :text head)
         (lambda (_r e)
           (when e (message "hermes: post-reconnect submit error: %S" e))))))))

;;;; Drain hook — fires when an in-flight stream transitions to nil.

(defun hermes-input--drain (old new)
  "If a turn just finished and the queue is non-empty, dispatch its head."
  (when (and old
             (hermes-state-stream old)
             (null (hermes-state-stream new))
             (hermes-state-queue new))
    (let ((sid (hermes-state-session-id new))
          (head (car (hermes-state-queue new))))
      (hermes-dispatch '(:dequeue))
      (when sid
        (hermes-rpc-request
         "prompt.submit"
         (list :session_id sid :text head)
         (lambda (_r e)
           (when e (message "hermes: queued prompt.submit error: %S" e))))))))

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
Slash commands bypass the queue and transcript; ordinary text is
optimistically committed and queued behind any in-flight turn."
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
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
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
      (hermes-rpc-request
       "slash.exec"
       (list :session_id sid :command (substring text 1))
       (lambda (_r e)
         (when e (message "hermes: slash.exec error: %S" e)))))
     ;; Live turn → optimistic commit + enqueue (drain hook handles dispatch).
     ((hermes-state-stream hermes--state)
      (hermes-dispatch (cons :user-submit (list :text text)))
      (hermes-dispatch (cons :enqueue     (list :text text))))
     ;; Idle → optimistic commit + immediate prompt.submit.
     (t
      (hermes-dispatch (cons :user-submit (list :text text)))
      (hermes-rpc-request
       "prompt.submit"
       (list :session_id sid :text text)
       (lambda (_r e)
         (when e (message "hermes: prompt.submit error: %S" e))))))))

(provide 'hermes-input)
;;; hermes-input.el ends here
