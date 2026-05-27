;;; hermes.el --- Hermes entry point, routing, and core infrastructure  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `hermes' is the context-aware entry point.  Core routing dispatches
;; RPC events into per-session state atoms.  Debug commands round out
;; the file.
;;
;; The org-based minor mode lives in `hermes-org-minor-mode.el';
;; session lifecycle and browsing in `hermes-session.el';
;; the comint viewer in `hermes-comint.el'.

(require 'org)
(require 'hermes-rpc)
(require 'hermes-events)
(require 'hermes-state)
(require 'hermes-org-render)
(require 'hermes-session)
(require 'hermes-org-minor-mode)
(require 'hermes-comint)
(require 'hermes-config)
(require 'hermes-image)
(require 'hermes-project)

;;;; Cached gateway-ready payload

(defvar hermes--last-gateway-ready nil
  "Most recent `gateway.ready' payload, cached for replay into new buffers.
The event broadcasts to every existing session when it arrives, but the
first session is typically created AFTER `gateway.ready' lands — so
without this cache, the very first session would never see the skin.")

;;;; Routing: filter event → buffer

(defun hermes--route-event (type session-id payload)
  "Dispatch event TYPE/PAYLOAD into the session's state slot."
  (when (or (equal type "gateway.ready") (equal type "skin.changed"))
    (setq hermes--last-gateway-ready payload))
  (cond
   ((and session-id (not (string-empty-p session-id)))
    (hermes-dispatch (cons type payload) session-id)
    (hermes-ui-dispatch (cons type payload) session-id))
   (t
    (hermes--broadcast-dispatch type payload))))

(defun hermes--route-connection (state)
  "Broadcast a connection state change to every known session."
  (when (eq state 'disconnected)
    (setq hermes--last-gateway-ready nil))
  (let ((msg (list (pcase state
                     ('connecting   :connecting)
                     ('connected    :connected)
                     ('disconnected :disconnected)
                     (_             :disconnected)))))
    (hermes-dispatch msg)
    (maphash (lambda (sid _state)
               (hermes-dispatch msg sid))
             hermes--sessions)))

(defun hermes--broadcast-dispatch (type payload)
  "Dispatch TYPE + PAYLOAD to the global slot and every active session."
  (hermes-dispatch (cons type payload))
  (maphash (lambda (sid _state)
             (hermes-dispatch (cons type payload) sid)
             (hermes-ui-dispatch (cons type payload) sid))
           hermes--sessions))

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

;;;; Hook wiring

(defun hermes--install-hooks ()
  "Wire RPC hooks once.  Truly idempotent — removes before adding."
  (remove-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (remove-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (remove-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (remove-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (remove-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout)
  (add-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (add-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (add-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (add-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout))

;;;; Entry point

;;;###autoload
(defun hermes ()
  "Context-aware entry point — never sends a prompt.
- In a `hermes-comint-mode' buffer: go to the prompt at point-max.
- In a `hermes-org-minor-mode' buffer: ensure the bench is visible
  and focus its input area.
- In a generic `org-mode' buffer: create a Hermes session heading as
  a child of the heading at/above point.
- Everywhere else: create a new Hermes comint session."
  (interactive)
  (cond
   ((derived-mode-p 'hermes-comint-mode)
    (goto-char (point-max)))
   (hermes-org-minor-mode
    (when-let ((sid (hermes--buffer-sid (current-buffer))))
      (hermes-bench-ensure sid))
    (let* ((bench (hermes-bench-active-p))
           (win   (and bench (get-buffer-window bench))))
      (when (window-live-p win)
        (select-window win)
        (goto-char (point-max)))))
   ((derived-mode-p 'org-mode)
    (let* ((marker (or (hermes--container-marker-at-point)
                       (hermes--any-container-in-buffer)))
           (sid    (and marker
                        (save-excursion
                          (goto-char marker)
                          (or (hermes--session-at-point)
                              (hermes--session-id-at-heading)))))
           (state  (and sid (hermes--lookup-session-state sid))))
      (cond
       (state
        (when (marker-position marker) (goto-char marker))
        (when-let ((s (hermes--buffer-sid (current-buffer))))
          (hermes-bench-ensure s))
        (let* ((bench (hermes-bench-active-p))
               (win   (and bench (get-buffer-window bench))))
          (when (window-live-p win)
            (select-window win)
            (goto-char (point-max)))))
       (sid
        (when (marker-position marker) (goto-char marker))
        (hermes--handle-stale-heading sid marker))
       (t
        (hermes--create-session-under-heading)))))
   (t
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p) (hermes-rpc-start))
    (hermes-comint--create-session
     (lambda (buf)
       (when (buffer-live-p buf)
         (pop-to-buffer-same-window buf)
         (goto-char (point-max))))))))

;;;; Dev — log viewer

(defun hermes-view-log ()
  "Pop to the *hermes-log* diagnostic buffer."
  (interactive)
  (pop-to-buffer (hermes--log-buffer)))

;;;; Debug inspectors

(defun hermes-inspect-turn ()
  "Pretty-print the parsed turn at point into a temp buffer.
In Org mode, parses the visible heading via `hermes--parse-turn-at-point'.
In `hermes-comint-mode', reads the `hermes-comint--turn-index' text
property at point and looks the turn up directly in the session state."
  (interactive)
  (let ((msg
         (cond
          ((derived-mode-p 'hermes-comint-mode)
           (let* ((idx (get-text-property (point) 'hermes-comint--turn-index))
                  (state (and hermes--current-session-id
                              (hermes--state-slot-read
                               hermes--current-session-id)))
                  (turns (and state (hermes-state-turns state))))
             (and idx (vectorp turns) (<= idx (length turns))
                  (aref turns (1- idx)))))
          (t
           (save-excursion
             (when (derived-mode-p 'org-mode)
               (ignore-errors (org-back-to-heading t)))
             (hermes--parse-turn-at-point))))))
    (unless msg
      (user-error "No Hermes turn at point"))
    (let ((buf (get-buffer-create "*Hermes Turn Inspector*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (emacs-lisp-mode)
          (insert ";; Parsed hermes-message:\n")
          (pp (hermes--message-to-plist msg) (current-buffer))
          (goto-char (point-min)))
        (setq buffer-read-only t))
      (display-buffer buf))))

(defun hermes-debug-state ()
  "Pop a buffer inspecting the active session's state struct."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (st (and target (cdr target))))
    (unless st (user-error "No Hermes state for this buffer"))
    (hermes--debug-state-pop st)))

(defun hermes--debug-state-pop (st)
  "Render ST in a popup buffer."
  (let* ((_ st)
         (data `(:session-id    ,(hermes-state-session-id st)
                 :connection    ,(hermes-state-connection st)
                 :stream        ,(and (hermes-state-stream st) t)
                 :queue-length  ,(length (hermes-state-queue st))
                 :pending       ,(hermes-state-pending st)
                 :history-len   ,(length (hermes-state-history st))
                 :slash-catalog ,(and (hermes-state-slash-catalog st) t)
                 :session-info  ,(hermes-state-session-info st)
                 :usage         ,(hermes-state-usage st)
                 :busy-mode     ,(hermes-state-busy-mode st)))
         (buf (get-buffer-create "*Hermes State Inspector*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp data (current-buffer))
        (goto-char (point-min)))
      (setq buffer-read-only t))
    (display-buffer buf)))

(provide 'hermes)
;;; hermes.el ends here
