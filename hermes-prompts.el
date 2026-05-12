;;; hermes-prompts.el --- Minibuffer handlers for approval/clarify/secret/sudo -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Watches the persistent state's `pending' slot.  When it becomes non-nil,
;; schedules a minibuffer interaction (via `run-at-time' 0 so the renderer
;; finishes its work first), then dispatches the matching `.respond' RPC
;; and clears the pending slot.

;;; Code:

(require 'cl-lib)
(require 'hermes-rpc)
(require 'hermes-state)

(defvar-local hermes--pending-active nil
  "Non-nil while a minibuffer interaction is in flight.
Guards against re-entrant prompts when the renderer hook fires again.")

(defun hermes-prompts-watch (old new)
  "State-change hook: when pending becomes non-nil, schedule a prompt."
  (let ((op (and old (hermes-state-pending old)))
        (np (hermes-state-pending new)))
    (when (and np (not (eq op np)) (not hermes--pending-active))
      (setq hermes--pending-active t)
      (let ((buf (current-buffer))
            (sid (hermes-state-session-id new))
            (pending np))
        (run-at-time
         0 nil
         (lambda ()
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (unwind-protect
                   (hermes--prompts-handle sid pending)
                 (setq hermes--pending-active nil)
                 (hermes-dispatch '(:pending-clear)))))))))))

(defun hermes--prompts-handle (sid pending)
  "Run the right minibuffer prompt for PENDING and dispatch the response."
  (let* ((kind (hermes-pending-kind pending))
         (rid  (hermes-pending-request-id pending))
         (p    (hermes-pending-payload pending)))
    (pcase kind
      ('approval (hermes--prompt-approval sid rid p))
      ('clarify  (hermes--prompt-clarify  rid p))
      ('sudo     (hermes--prompt-sudo     rid))
      ('secret   (hermes--prompt-secret   rid p)))))

(defun hermes--prompts-get (payload key)
  (cond ((hash-table-p payload) (gethash key payload))
        ((null payload) nil)
        (t (plist-get payload key))))

;;;; Approval

(defun hermes--prompt-approval (sid rid payload)
  "Ask the user to allow/deny a tool call, then dispatch `approval.respond'."
  (let* ((cmd (hermes--prompts-get payload "command"))
         (desc (hermes--prompts-get payload "description"))
         (prompt (format "Approve%s%s? "
                         (if desc (format " (%s)" desc) "")
                         (if cmd (format " [%s]" cmd) "")))
         (choice (condition-case _
                     (read-multiple-choice
                      prompt
                      '((?y "yes" "allow this once")
                        (?a "all" "allow this and similar in this session")
                        (?n "no"  "deny")))
                   (quit '(?n "no" "deny"))))
         (key (car choice))
         (resp (pcase key (?y "allow") (?a "allow") (_ "deny"))))
    (hermes-rpc-request
     "approval.respond"
     (list :session_id sid :request_id rid :choice resp
           :all (if (eq key ?a) t :false)))))

;;;; Clarify

(defun hermes--prompt-clarify (rid payload)
  "Show the question, let the user pick from choices or free-type."
  (let* ((question (or (hermes--prompts-get payload "question") "Clarify:"))
         (choices  (let ((c (hermes--prompts-get payload "choices")))
                     (cond ((vectorp c) (append c nil))
                           ((listp c) c)
                           (t nil))))
         (answer (if choices
                     (completing-read (concat question " ") choices nil nil)
                   (read-string (concat question " ")))))
    (hermes-rpc-request "clarify.respond"
                        (list :request_id rid :answer answer))))

;;;; Sudo / secret

(defun hermes--prompt-sudo (rid)
  "Read a sudo password and dispatch `sudo.respond'."
  (let ((pw (read-passwd "sudo password: ")))
    (hermes-rpc-request "sudo.respond"
                        (list :request_id rid :password pw))))

(defun hermes--prompt-secret (rid payload)
  "Read a secret value and dispatch `secret.respond'."
  (let* ((var (hermes--prompts-get payload "env_var"))
         (hint (or (hermes--prompts-get payload "prompt")
                   (and var (format "Value for %s: " var))
                   "Secret: "))
         (val (read-passwd hint)))
    (hermes-rpc-request "secret.respond"
                        (list :request_id rid :value val))))

(provide 'hermes-prompts)
;;; hermes-prompts.el ends here
