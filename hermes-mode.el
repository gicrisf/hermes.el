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
(require 'hermes-skin)
(require 'hermes-compose)

;;;; Routing: filter event → buffer

(defvar hermes--session-buffers (make-hash-table :test 'equal)
  "Map of session-id → conversation buffer.")

(defvar hermes--last-gateway-ready nil
  "Most recent `gateway.ready' payload, cached for replay into new buffers.
The event broadcasts to every existing session buffer when it arrives, but
the first session is typically created AFTER `gateway.ready' lands — so
without this cache, the very first buffer would never see the skin.")

(defun hermes--lookup-buffer (session-id)
  "Return the buffer for SESSION-ID, or nil."
  (let ((buf (gethash session-id hermes--session-buffers)))
    (and (buffer-live-p buf) buf)))

;;;; Event routing — installed once on the RPC layer

(defun hermes--route-event (type session-id payload)
  "Dispatch event TYPE/PAYLOAD into the session buffer's atoms."
  (when (or (equal type "gateway.ready") (equal type "skin.changed"))
    (setq hermes--last-gateway-ready payload))
  (let ((buf (and session-id (not (string-empty-p session-id))
                  (hermes--lookup-buffer session-id))))
    ;; Some events arrive before we know the session id (gateway.ready,
    ;; skin.changed) — broadcast those to every existing Hermes buffer.
    (cond
     (buf (with-current-buffer buf
            (hermes-dispatch (cons type payload))
            (hermes-ui-dispatch (cons type payload))))
     ((or (null session-id) (string-empty-p session-id))
      (maphash (lambda (_sid b)
                 (when (buffer-live-p b)
                   (with-current-buffer b
                     (hermes-dispatch (cons type payload))
                     (hermes-ui-dispatch (cons type payload)))))
               hermes--session-buffers)))))

(defun hermes--route-connection (state)
  "Broadcast a connection state change into every Hermes buffer."
  ;; Clear the cached `gateway.ready' payload so that the *next* time we
  ;; reconnect we wait for a fresh one before firing `session.create'.
  (when (eq state 'disconnected)
    (setq hermes--last-gateway-ready nil))
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
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt)
    m)
  "Keymap for `hermes-mode'.")

(define-derived-mode hermes-mode org-mode "Hermes"
  "Major mode for a Hermes conversation buffer."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq buffer-read-only t)
  (hermes-state-init)
  ;; Insert file-level metadata line.
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert "#+TITLE: hermes\n")))
  (add-hook 'hermes-state-change-hook    #'hermes--render        nil t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  nil t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   nil t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     nil t)
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     nil t)
  ;; Initial header line.
  (with-silent-modifications
    (hermes--render-header hermes--state)))

;;;; Public entry points

(defun hermes--do-session-create (callback)
  "Internal: send `session.create' and wire its response to CALLBACK."
  (hermes-rpc-request
   "session.create" '(:cols 100)
   (lambda (result error)
     (cond
      (error
       (message "hermes: session.create failed: %S" error)
       (when callback (funcall callback nil)))
      (result
       (let* ((sid (gethash "session_id" result))
              (buf (generate-new-buffer (format "*hermes:%s*" sid))))
         (puthash sid buf hermes--session-buffers)
         (with-current-buffer buf
           (hermes-mode)
           (setf (hermes-state-session-id hermes--state) sid)
           (when hermes--last-gateway-ready
             (hermes-dispatch
              (cons "gateway.ready" hermes--last-gateway-ready)))
           (hermes-input-fetch-catalog))
         (when callback (funcall callback buf))))))))

(defun hermes-new-session (&optional callback)
  "Start the gateway (if needed), create a session, and prepare its buffer.
The buffer is registered in `hermes--session-buffers' but NOT popped to the
user; that's the caller's job.  CALLBACK, if non-nil, is called with the new
buffer (or nil on error) once `session.create' resolves.

If the gateway is still warming up, the request is queued by the transport
(`hermes-rpc--pending-frames') and flushed when `gateway.ready' arrives —
no special-casing required here.

This is the building block dashboards use to spawn sessions in the
background; for the user-facing entry that also pops the buffer, see
`hermes'."
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (hermes--do-session-create callback))

;;;###autoload
(defun hermes ()
  "Start the gateway (if needed), create a session, and pop its chat buffer.
This is the lean entry point — it does not open a dashboard.  For a landing
screen, use `M-x hermes-dashboard' or `M-x doom-dashboard-hermes' instead."
  (interactive)
  (hermes-new-session
   (lambda (buf) (when (buffer-live-p buf) (pop-to-buffer buf)))))

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
               (when hermes--last-gateway-ready
                 (hermes-dispatch
                  (cons "gateway.ready" hermes--last-gateway-ready)))
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
