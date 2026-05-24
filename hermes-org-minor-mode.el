;;; hermes-org-minor-mode.el --- Org-based Hermes conversation surface  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `hermes-org-minor-mode' is the minor mode that turns an `org-mode'
;; buffer into a Hermes conversation surface.  It owns the streaming
;; renderer, keybindings, hook wiring, org container helpers, org
;; buffer parsing (body-canonical), session heading creation, and
;; reconnect/reload.

(require 'org)
(require 'hermes-rpc)
(require 'hermes-state)
(require 'hermes-org-render)
(require 'hermes-prompts)
(require 'hermes-input)
(require 'hermes-skin)
(require 'hermes-org)
(require 'hermes-image)

(declare-function hermes--install-hooks "hermes" ())
(declare-function hermes-bench-ensure "hermes-comint" (sid))
(declare-function hermes-bench-active-p "hermes-comint" (&optional buffer-or-sid))
(declare-function hermes-bench-focus "hermes-session" ())
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes-interrupt-current-session "hermes-session" ())
(declare-function hermes-view-log "hermes" ())
(declare-function hermes-set-model "hermes-config" (&optional refresh-providers))
(declare-function hermes-toggle-fast "hermes-config" ())
(declare-function hermes-image-attach-file "hermes-image" (&optional file))
(declare-function hermes-input-fetch-catalog "hermes-input" ())
(declare-function hermes-input--drain-after-reconnect "hermes-input" ())
(declare-function hermes--maybe-kill-bench "hermes-state" (sid))

;; Forward declaration from hermes-session — dependency injected at load time
;; for container-level tracking in multi-session buffers.
(defvar hermes--container-level)

;;;; Container heading helpers

(defun hermes--container-heading-in-buffer-p ()
  "Return non-nil when the buffer holds at least one `:hermes:'-tagged heading."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\\*+ .*:hermes:" nil t)))

(defun hermes--ensure-container ()
  "Insert a Hermes session container heading at point-min if absent.
Called by the `hermes' entry point and the DB-resume installer before
activating `hermes-org-minor-mode', which requires a container to
exist somewhere in the buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (hermes--container-heading-in-buffer-p)
      (insert (concat (make-string (or (bound-and-true-p hermes--container-level) 1)
                                   ?*)
                      " Hermes session :hermes:\n")))))

;;;; Org detach

(defun hermes--org-detach ()
  "Remove the current buffer from `hermes--org-buffers'.
Run on `kill-buffer-hook' for Hermes-aware buffers.  Leaves the
session state in `hermes--sessions' untouched so it survives until
explicit close.  Kills the paired bench when the last viewer goes."
  (let ((buf (current-buffer))
        (drops nil))
    (maphash (lambda (sid b) (when (eq b buf) (push sid drops)))
             hermes--org-buffers)
    (dolist (sid drops)
      (remhash sid hermes--org-buffers)
      (hermes--maybe-kill-bench sid))))

;;;; Minor mode

(defvar hermes-org-minor-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-i") #'hermes-bench-focus)
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt-current-session)
    (define-key m (kbd "C-c C-v") #'hermes-view-log)
    (define-key m (kbd "C-c C-m") #'hermes-set-model)
    (define-key m (kbd "C-c C-f") #'hermes-toggle-fast)
    (define-key m (kbd "C-c C-a") #'hermes-image-attach-file)
    m)
  "Keymap for `hermes-org-minor-mode'.")

(with-eval-after-load 'which-key
  (when (fboundp 'which-key-add-keymap-based-replacements)
    (which-key-add-keymap-based-replacements hermes-org-minor-mode-map
      "C-c C-i" "Focus bench"
      "C-c C-l" "Compose multi-line"
      "C-c C-k" "Interrupt session"
      "C-c C-v" "View log"
      "C-c C-m" "Set model"
      "C-c C-f" "Toggle fast mode"
      "C-c C-a" "Attach image file")))

(defun hermes-org-minor-mode--on ()
  "Setup for `hermes-org-minor-mode': org-local config, hooks.
Requires a `:hermes:' container heading at point-min — the entry point
and DB-resume installer create it before activation.  Idempotent: safe
to run when already armed."
  (unless (derived-mode-p 'org-mode)
    (error "hermes-org-minor-mode requires org-mode"))
  (unless (hermes--container-heading-in-buffer-p)
    (error "No Hermes session heading found — use M-x hermes to create one"))
  (setq-local hermes--container-level 1)
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq-local org-todo-keywords
              '((sequence "RUNNING(r)" "|" "DONE(d)" "ERROR(e)")))
  (setq-local org-todo-keyword-faces
              '(("RUNNING" . hermes-tool-running-face)
                ("DONE"    . hermes-tool-done-face)
                ("ERROR"   . hermes-tool-error-face)))
  (hermes--install-hooks)
  (add-hook 'org-cycle-hook #'hermes--remember-cycle nil t)
  (add-hook 'hermes-state-change-hook    #'hermes--render        t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     t)
  (add-hook 'kill-buffer-hook            #'hermes--stream-flush-cancel nil t)
  (add-hook 'kill-buffer-hook            #'hermes--org-detach nil t))

(defun hermes-org-minor-mode--off ()
  "Teardown for `hermes-org-minor-mode': remove buffer-local hooks.
The global state-change-hook subscribers are intentionally left in
place — they are global and shared by every Hermes buffer; removing
them here would tear down other live viewers."
  (remove-hook 'org-cycle-hook #'hermes--remember-cycle t)
  (remove-hook 'kill-buffer-hook #'hermes--stream-flush-cancel t)
  (hermes--stream-flush-cancel))

;;;###autoload
(define-minor-mode hermes-org-minor-mode
  "Minor mode for Hermes presentation in Org buffers.
Provides streaming render, auto-fold, and key bindings.
Works in any `org-mode' buffer with a `:hermes:' container heading at
point-min."
  :init-value nil
  :lighter " Hermes"
  :keymap hermes-org-minor-mode-map
  (if hermes-org-minor-mode
      (hermes-org-minor-mode--on)
    (hermes-org-minor-mode--off)))

;;;; Session heading creation

(defun hermes--create-session-under-heading ()
  "Insert a Hermes session heading as a child of the heading at/above point.
Used by `hermes' when invoked from a generic `org-mode' buffer.  The
heading is added at the end of the parent's subtree so existing body
text is never split.  `hermes--container-level' is set buffer-locally
so turn insertion follows the relative depth."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let* ((insert-pos nil)
         (container-level
          (save-excursion
            (if (ignore-errors (org-back-to-heading t))
                (let ((lvl (1+ (org-current-level))))
                  (org-end-of-subtree t t)
                  (setq insert-pos (point))
                  lvl)
              (goto-char (point-max))
              (setq insert-pos (point))
              1)))
         (buf (current-buffer)))
    (goto-char insert-pos)
    (unless (bolp) (insert "\n"))
    (let* ((heading-pos (point))
           (_ (insert (format "%s Hermes session :hermes:\n"
                              (make-string container-level ?*))))
           (marker (copy-marker heading-pos nil)))
      (setq-local hermes--container-level container-level)
      (unless hermes-org-minor-mode
        (hermes-org-minor-mode 1)
        (setq-local hermes--container-level container-level))
      (hermes--request
       "session.create" '(:cols 100)
       (lambda (result error)
         (cond
          (error
           (message "hermes: session.create failed: %S" error))
          (result
           (let ((sid (gethash "session_id" result)))
             (when (and sid (buffer-live-p buf))
               (with-current-buffer buf
                 (save-excursion
                   (goto-char (marker-position marker))
                   (when (org-at-heading-p)
                     (org-set-property "HERMES_SESSION" sid)))
                 (let ((state (make-hermes-state :session-id sid
                                                 :connection 'connected)))
                   (hermes--register-session sid state marker))
                 (when hermes--last-gateway-ready
                   (hermes-dispatch
                    (cons "gateway.ready" hermes--last-gateway-ready)
                    sid))
                 (message "hermes: session %s ready" sid)))))))))))

;;;; Reconnect

(declare-function hermes--last-gateway-ready "hermes" ())
(defvar hermes--last-gateway-ready)

(defun hermes-reconnect ()
  "Restart the gateway (if needed) and bind the current buffer to a fresh session.
Used after the gateway subprocess has died.  The old session id is removed
from `hermes--org-buffers' once the new one is bound; the buffer is
renamed accordingly; the slash-command catalog is re-fetched; and any
queued input is drained."
  (interactive)
  (unless hermes-org-minor-mode
    (user-error "Not in a Hermes buffer"))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let ((buf (current-buffer)))
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: reconnect session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let* ((old-sid (catch 'found
                                 (maphash (lambda (k b)
                                            (when (eq b buf)
                                              (throw 'found k)))
                                          hermes--org-buffers)
                                 nil))
                      (old-state (and old-sid (hermes--state-slot-read old-sid))))
                 (when (and old-sid (not (equal old-sid sid)))
                   (remhash old-sid hermes--org-buffers)
                   (remhash old-sid hermes--sessions)
                   (remhash old-sid hermes--session-markers))
                 (let ((state (or (and old-state
                                       (let ((s (hermes-state-copy old-state)))
                                         (setf (hermes-state-session-id s) sid)
                                         s))
                                  (make-hermes-state :connection 'connected
                                                     :session-id sid))))
                   (hermes--register-session
                    sid state
                    (save-excursion (goto-char (point-min))
                                    (copy-marker (point) nil)))))
               (rename-buffer (generate-new-buffer-name
                               (format "*hermes:%s*" sid)))
               (when hermes--last-gateway-ready
                 (hermes-dispatch
                  (cons "gateway.ready" hermes--last-gateway-ready)
                  sid))
               (hermes-input-fetch-catalog)
               (hermes-input--drain-after-reconnect)
               (message "hermes: reconnected as %s" sid))))))))))

;;;; Buffer parsing — body-canonical Org → state vector

(defun hermes--buffer-message-count ()
  "Count committed turns in the current buffer.
A turn is a heading one level below the session container carrying a
recognized `:HERMES_KIND:' property.  The container itself and any
deeper sub-headings (reasoning/response/tools) are skipped."
  (let ((count 0)
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (and (= turn-level (org-current-level))
                    (let ((k (org-entry-get (point) "HERMES_KIND")))
                      (member k '("USER" "ASSISTANT" "SYSTEM"))))
           (cl-incf count)))
       nil nil 'file))
    count))

(defun hermes--parse-buffer-messages ()
  "Walk the buffer and return a vector of `hermes-message' structs.
Derives each turn from its visible Org structure: heading properties
for metadata and usage, body text + `#+attr_org:'/`#+attr_hermes:'
lines for content (including images), child SUBAGENT headings for
subagents."
  (let (messages
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (= turn-level (org-current-level))
           (let ((msg (hermes--parse-turn-at-point)))
             (when msg
               (push msg messages)))))
       nil nil 'file))
    (vconcat (nreverse messages))))

(defun hermes-reload-from-org ()
  "Reload the current Org buffer into a fresh gateway session.
A new `session.create' is issued; the buffer's existing visible
conversation is replayed to the new session via the history seed on
the first outgoing prompt (see `hermes--build-history-text').  The
gateway does not accept a history parameter on session creation, so
this is the only way to re-attach an Org snapshot to a live session."
  (interactive)
  (unless hermes-org-minor-mode
    (user-error "Not in a Hermes buffer"))
  (let* ((history (hermes--parse-buffer-messages)))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: load-org session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when sid
             (let ((state (make-hermes-state :session-id sid
                                             :connection 'connected)))
               (hermes--register-session
                sid state
                (save-excursion
                  (goto-char (point-min)) (copy-marker (point) nil))))
             (setq hermes--seeded-session-id nil)
             (message "hermes: loaded org as %s (%d turns parsed)"
                      sid (length history))))))))))

(provide 'hermes-org-minor-mode)
;;; hermes-org-minor-mode.el ends here
