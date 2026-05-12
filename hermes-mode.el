;;; hermes-mode.el --- Org-derived major mode and session entry point -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `hermes-mode' is the major mode for a conversation buffer.  It derives
;; from `org-mode' so headlines, folding, properties and links work for
;; free.  The buffer's textual history is read-only; input happens via
;; `hermes-send' (minibuffer prompt) bound to `C-c C-i'.
;;
;; `hermes' is the entrypoint: start the gateway, create a session, open
;; a buffer.

;;; Code:

(require 'org)
(require 'hermes-rpc)
(require 'hermes-events)
(require 'hermes-state)
(require 'hermes-render)
(require 'hermes-prompts)

;;;; Routing: filter event → buffer

(defvar hermes--session-buffers (make-hash-table :test 'equal)
  "Map of session-id → conversation buffer.")

(defun hermes--lookup-buffer (session-id)
  "Return the buffer for SESSION-ID, or nil."
  (let ((buf (gethash session-id hermes--session-buffers)))
    (and (buffer-live-p buf) buf)))

;;;; Event routing — installed once on the RPC layer

(defun hermes--route-event (type session-id payload)
  "Dispatch event TYPE/PAYLOAD into the session buffer's atoms."
  (let ((buf (and session-id (hermes--lookup-buffer session-id))))
    ;; Some events arrive before we know the session id (e.g. gateway.ready);
    ;; broadcast those to every Hermes buffer.
    (cond
     (buf (with-current-buffer buf
            (hermes-dispatch (cons type payload))
            (hermes-ui-dispatch (cons type payload))))
     ((null session-id)
      (maphash (lambda (_sid b)
                 (when (buffer-live-p b)
                   (with-current-buffer b
                     (hermes-dispatch (cons type payload))
                     (hermes-ui-dispatch (cons type payload)))))
               hermes--session-buffers)))))

(defun hermes--route-connection (state)
  "Broadcast a connection state change into every Hermes buffer."
  (maphash (lambda (_sid b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (hermes-dispatch
                  (list (pcase state
                          ('connecting   :connecting)
                          ('connected    :connected)
                          ('disconnected :disconnected)
                          (_             :disconnected)))))))
           hermes--session-buffers))

(defun hermes--install-hooks ()
  "Wire RPC hooks once.  Idempotent."
  (add-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection))

;;;; Major mode

(defvar hermes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-i") #'hermes-send)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt)
    m)
  "Keymap for `hermes-mode'.")

(define-derived-mode hermes-mode org-mode "Hermes"
  "Major mode for a Hermes conversation buffer."
  (setq-local org-startup-folded nil)
  (setq buffer-read-only t)
  (hermes-state-init)
  (add-hook 'hermes-state-change-hook    #'hermes--render        nil t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  nil t)
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     nil t)
  ;; Initial header line.
  (with-silent-modifications
    (hermes--render-header hermes--state)))

;;;; Public entry points

;;;###autoload
(defun hermes ()
  "Start the Hermes gateway (if needed), create a session, open a buffer."
  (interactive)
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (hermes-rpc-request
   "session.create" '(:cols 100)
   (lambda (result error)
     (cond
      (error (message "hermes: session.create failed: %S" error))
      (result
       (let* ((sid (gethash "session_id" result))
              (buf (generate-new-buffer (format "*hermes:%s*" sid))))
         (puthash sid buf hermes--session-buffers)
         (with-current-buffer buf
           (hermes-mode)
           (setf (hermes-state-session-id hermes--state) sid))
         (pop-to-buffer buf)))))))

(defun hermes-send (text)
  "Submit TEXT to the current session as a `prompt.submit'."
  (interactive
   (list (read-string "Hermes> "
                      nil
                      (when (and hermes--state
                                 (hermes-state-history hermes--state))
                        '(hermes--history-ring . 0)))))
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (let ((sid (hermes-state-session-id hermes--state)))
    (unless sid (user-error "No session id in this buffer"))
    ;; Optimistic local commit, then fire the RPC.
    (hermes-dispatch (cons :user-submit (list :text text)))
    (hermes-rpc-request "prompt.submit"
                        (list :session_id sid :text text)
                        (lambda (_r e)
                          (when e (message "hermes: prompt.submit error: %S" e))))))

(defun hermes-interrupt ()
  "Send `session.interrupt' for the current session."
  (interactive)
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (let ((sid (hermes-state-session-id hermes--state)))
    (unless sid (user-error "No session id in this buffer"))
    (hermes-rpc-request "session.interrupt"
                        (list :session_id sid)
                        (lambda (_r e)
                          (when e (message "hermes: interrupt error: %S" e))))))

(provide 'hermes-mode)
;;; hermes-mode.el ends here
