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
(require 'hermes-input)
(require 'hermes-sessions)

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
  (add-hook 'hermes-rpc-event-functions #'hermes-sessions--refresh-if-open)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (add-hook 'hermes-rpc-connection-functions #'hermes-sessions--refresh-if-open))

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
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   nil t)
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
           (setf (hermes-state-session-id hermes--state) sid)
           (hermes-input-fetch-catalog))
         (pop-to-buffer buf)))))))

(defalias 'hermes-send #'hermes-input-send
  "Queue-aware submission entry; see `hermes-input-send'.")

(defun hermes-reconnect ()
  "Restart the gateway (if needed) and bind the current buffer to a fresh session.
Used after the gateway subprocess has died.  The old session id is removed
from `hermes--session-buffers' once the new one is bound; the buffer is
renamed accordingly; the slash-command catalog is re-fetched; and any
queued input is drained."
  (interactive)
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let ((buf (current-buffer)))
    (hermes-rpc-request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: reconnect session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((old-sid (hermes-state-session-id hermes--state)))
                 (when (and old-sid (not (equal old-sid sid)))
                   (remhash old-sid hermes--session-buffers)))
               (puthash sid buf hermes--session-buffers)
               (setf (hermes-state-session-id hermes--state) sid)
               (rename-buffer (generate-new-buffer-name
                               (format "*hermes:%s*" sid)))
               (hermes-input-fetch-catalog)
               (hermes-input--drain-after-reconnect)
               (message "hermes: reconnected as %s" sid))))))))))

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
