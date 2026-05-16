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
  ;; TODO: remove debug log after tool pipeline is stable
  (message "[hermes] event: %s keys=%S"
           type
           (and (hash-table-p payload)
                (let (ks) (maphash (lambda (k _v) (push k ks)) payload) ks)))
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
       (hermes--broadcast-dispatch type payload)))))

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

(defun hermes--broadcast-dispatch (type payload)
  "Dispatch TYPE + PAYLOAD to every active Hermes buffer."
  (maphash (lambda (_sid b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (hermes-dispatch (cons type payload))
                 (hermes-ui-dispatch (cons type payload)))))
           hermes--session-buffers))

(defun hermes--route-stderr (line)
  "Broadcast a `gateway.stderr' event with LINE to all Hermes buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "line" line ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.stderr" payload)))

(defun hermes--route-protocol-error (preview)
  "Broadcast a `gateway.protocol_error' event with PREVIEW to all buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "preview" preview ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.protocol_error" payload)))

(defun hermes--route-start-timeout (lines)
  "Broadcast a `gateway.start_timeout' event with LINES to all buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "lines" lines ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.start_timeout" payload)))

(defun hermes--install-hooks ()
  "Wire RPC hooks once.  Truly idempotent — removes before adding."
  (remove-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (remove-hook 'hermes-rpc-event-functions #'hermes-sessions--refresh-if-open)
  (remove-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (remove-hook 'hermes-rpc-connection-functions #'hermes-sessions--refresh-if-open)
  (remove-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (remove-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (remove-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout)
  (add-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (add-hook 'hermes-rpc-event-functions #'hermes-sessions--refresh-if-open)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (add-hook 'hermes-rpc-connection-functions #'hermes-sessions--refresh-if-open)
  (add-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (add-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (add-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout))

;;;; Major mode

(defvar hermes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-i") #'hermes-send)
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt)
    (define-key m (kbd "C-c C-v") #'hermes-view-log)
    m)
  "Keymap for `hermes-mode'.")

(defun hermes-minor-mode--on ()
  "Setup for `hermes-minor-mode': org-local config, hooks, header-line.
Idempotent — safe to run when already armed.  In Phase 1 the major mode
creates the state atom before enabling the minor mode; if no state is
present (Phase 2: arbitrary Org buffers), one is created here."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq-local org-todo-keywords
              '((sequence "RUNNING(r)" "|" "DONE(d)" "ERROR(e)")))
  (setq-local org-todo-keyword-faces
              '(("RUNNING" . hermes-tool-running-face)
                ("DONE"    . hermes-tool-done-face)
                ("ERROR"   . hermes-tool-error-face)))
  (unless (and (boundp 'hermes--state) hermes--state)
    (hermes-state-init))
  (add-hook 'org-cycle-hook #'hermes--remember-cycle nil t)
  ;; Order matters: `hermes--render' MUST run before `hermes-input--drain'.
  ;; If drain runs first, it dispatches `:user-submit' for the queued
  ;; head; the recursive render inserts that user heading at point-max
  ;; with stream already nil → `stream-commit' won't have fired yet, so
  ;; when the outer render finally runs, `bench-end' has been rear-
  ;; advanced past the user content and the assistant raw drawer lands
  ;; at the end of the buffer.  `add-hook' with nil APPEND *prepends*,
  ;; reversing insertion order — so we explicitly append.
  (add-hook 'hermes-state-change-hook    #'hermes--render        t t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  t t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   t t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     t t)
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     t t)
  (with-silent-modifications
    (hermes--render-header hermes--state)))

(defun hermes-minor-mode--off ()
  "Teardown for `hermes-minor-mode': removes hooks, clears header-line."
  (remove-hook 'org-cycle-hook #'hermes--remember-cycle t)
  (remove-hook 'hermes-state-change-hook #'hermes--render t)
  (remove-hook 'hermes-state-change-hook #'hermes-prompts-watch t)
  (remove-hook 'hermes-state-change-hook #'hermes-input--drain t)
  (remove-hook 'hermes-state-change-hook #'hermes-skin-watch t)
  (remove-hook 'hermes-ui-state-change-hook #'hermes--render-ui t)
  (setq header-line-format nil))

;;;###autoload
(define-minor-mode hermes-minor-mode
  "Minor mode for Hermes presentation in Org buffers.
Provides streaming render, auto-fold, header-line, and key bindings.
When enabled in the dedicated `*hermes*' buffer, it is the full
presentation layer.  When enabled in arbitrary Org buffers (Phase 2),
it renders a heading-scoped session into that subtree."
  :init-value nil
  :lighter " Hermes"
  :keymap hermes-mode-map
  (if hermes-minor-mode
      (hermes-minor-mode--on)
    (hermes-minor-mode--off)))

(define-derived-mode hermes-mode org-mode "Hermes"
  "Major mode for a dedicated Hermes conversation buffer.
Thin wrapper: enables `org-mode', turns on `hermes-minor-mode' (which
owns all presentation logic), marks the buffer read-only, initialises
session state, and inserts the session container heading."
  (hermes-state-init)
  (hermes-minor-mode 1)
  (setq buffer-read-only t)
  ;; Phase 1: container always at level 1 (it lives at point-min).
  (setq-local hermes--container-level 1)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (insert (concat (make-string hermes--container-level ?*)
                      " Hermes session :hermes:\n")))))

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
           (let ((inhibit-read-only t))
             (save-excursion
               (goto-char (point-min))
               (when (org-at-heading-p)
                 (org-set-property "HERMES_SESSION" sid))))
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

(defun hermes-view-log ()
  "Pop to the *hermes-log* diagnostic buffer."
  (interactive)
  (pop-to-buffer (hermes--log-buffer)))

;;;; Buffer parsing — read canonical history back from the Org buffer

(defun hermes--buffer-message-count ()
  "Count committed turns in the current buffer.
A turn is a heading one level below the session container carrying a
`:HERMES_RAW:' drawer.  The container itself and any deeper sub-headings
\(reasoning/response/tools) are skipped."
  (let ((count 0)
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (and (= turn-level (org-current-level))
                    (save-excursion (hermes--extract-raw-drawer)))
           (cl-incf count)))
       nil nil 'file))
    count))

(defun hermes--parse-buffer-messages ()
  "Walk the buffer and return a vector of `hermes-message' structs.
Reads `:HERMES_RAW:' drawers under turn headings (direct children of
the session container, i.e. `hermes--container-level' + 1).  The
heading text itself is ignored, so older `** user: …' headings resume
the same as the content-first format (`** … :user:')."
  (let (messages
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (= turn-level (org-current-level))
           (let ((raw (save-excursion (hermes--extract-raw-drawer))))
             (when raw
               (push (hermes--plist-to-message raw) messages)))))
       nil nil 'file))
    (vconcat (nreverse messages))))

(defun hermes-resume-buffer ()
  "Connect to gateway and resume conversation from the current buffer.
Parses buffer turns; attempts to seed history into a fresh session.

FIXME: The Hermes gateway may not currently accept a history list in
`session.create'.  If gateway rejects the `history' field, this will
silently fall back to a cold start (session created with no seeded
context).  The parsed history is still useful as a local read-only
reference.  Verify with the gateway spec before relying on resume."
  (interactive)
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (let* ((history (hermes--parse-buffer-messages))
         (history-plists (mapcar #'hermes--message-to-plist
                                 (append history nil))))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes-rpc-request
     "session.create"
     ;; FIXME: gateway may ignore :history — confirm protocol support.
     (list :cols 100 :history (vconcat history-plists))
     (lambda (result error)
       (cond
        (error (message "hermes: resume session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when sid
             (setf (hermes-state-session-id hermes--state) sid)
             (puthash sid (current-buffer) hermes--session-buffers)
             (message "hermes: resumed as %s (%d turns parsed)"
                      sid (length history))))))))))

(provide 'hermes-mode)
;;; hermes-mode.el ends here
