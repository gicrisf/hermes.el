;;; hermes-session.el --- Hermes session lifecycle and browsing -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Session creation (RPC-based), lookup, browsing, bench management,
;; and session-level commands (interrupt, background-task listing).

(require 'hermes-rpc)
(require 'hermes-state)

(declare-function hermes--install-hooks "hermes" ())
(declare-function hermes--last-gateway-ready "hermes" ())
(declare-function hermes-org-minor-mode "hermes-org-minor-mode" (&optional arg))
(declare-function hermes--ensure-container "hermes-org-minor-mode" ())
(declare-function hermes--container-heading-in-buffer-p "hermes-org-minor-mode" ())
(declare-function hermes--register-session "hermes-org" (session-id state marker))
(declare-function hermes-input-fetch-catalog "hermes-input" ())
(declare-function hermes-bench-ensure "hermes-comint" (sid))
(declare-function hermes-bench-active-p "hermes-comint" (&optional buffer-or-sid))
(declare-function hermes-bg--list-for-sid "hermes-bg" (sid))
(declare-function hermes-project-detect-cwd "hermes-project" ())

(defvar hermes--last-gateway-ready)
(defvar hermes--seeded-session-id)
(defvar hermes--container-level)
(defvar hermes-comint--buffers)
(defvar hermes-org-minor-mode)

;;;; Session lifecycle

(defun hermes--do-session-create (callback)
  "Internal: send `session.create' and wire its response to CALLBACK."
  (let ((detected-cwd (ignore-errors (hermes-project-detect-cwd))))
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error
         (message "hermes: session.create failed: %S" error)
         (when callback (funcall callback nil)))
        (result
         (let* ((sid (gethash "session_id" result))
                (buf (generate-new-buffer (format "*hermes:%s*" sid))))
           (with-current-buffer buf
             (org-mode)
             (hermes--ensure-container)
             (hermes-org-minor-mode 1)
             (let ((state (make-hermes-state :connection 'connected
                                             :session-id sid
                                             :cwd detected-cwd)))
               (hermes--register-session
                sid state
                (save-excursion (goto-char (point-min))
                                (copy-marker (point) nil))))
             (save-excursion
               (goto-char (point-min))
               (when (org-at-heading-p)
                 (org-set-property "HERMES_SESSION" sid)
                 (when detected-cwd
                   (org-set-property "HERMES_CWD"
                                     (abbreviate-file-name detected-cwd)))))
             (when hermes--last-gateway-ready
               (hermes-dispatch
                (cons "gateway.ready" hermes--last-gateway-ready)
                sid))
             (hermes-input-fetch-catalog))
           (when callback (funcall callback buf)))))))))

(defun hermes-new-session (&optional callback)
  "Start the gateway (if needed), create a session, and prepare its buffer.
The buffer is registered in `hermes--org-buffers' but NOT popped to the
user; that's the caller's job.  CALLBACK, if non-nil, is called with the new
buffer (or nil on error) once `session.create' resolves."
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (hermes--do-session-create callback))

;;;; Session browsing

(defun hermes--lookup-buffer (session-id)
  "Return any live viewer buffer for SESSION-ID, or nil.
Checks the org and comint registries in that order."
  (let ((buf (or (gethash session-id hermes--org-buffers)
                 (gethash session-id hermes-comint--buffers))))
    (and (buffer-live-p buf) buf)))

(defun hermes--live-session-buffers ()
  "Return live session buffers across all viewer registries.
Sorted most-recently-touched first."
  (let (acc)
    (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
             hermes--org-buffers)
    (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
             hermes-comint--buffers)
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))

(defun hermes--primary-session-buffer ()
  "Return the most-recently-active live session buffer, or nil."
  (car (hermes--live-session-buffers)))

;;;; Bench management

(defun hermes-bench-focus ()
  "Move cursor to the bench input zone for the current Hermes buffer.
If the bench window is hidden, redisplay it first.  When no bench is
attached to the buffer, fall back to `hermes-send' for a minibuffer
prompt."
  (interactive)
  (let ((bench (and hermes-org-minor-mode
                    (hermes-bench-active-p))))
    (cond
     ((and bench (get-buffer-window bench))
      (select-window (get-buffer-window bench))
      (goto-char (point-max)))
     (bench
      (when-let ((sid (hermes--buffer-sid (current-buffer))))
        (hermes-bench-ensure sid))
      (let ((w (get-buffer-window bench)))
        (when (window-live-p w)
          (select-window w)
          (goto-char (point-max)))))
     (t (call-interactively #'hermes-send)))))

(defun hermes--focus-bench-input (buf)
  "Select the bench window for BUF and move point to its input end."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((bench (hermes-bench-active-p))
             (win   (and bench (get-buffer-window bench))))
        (when (window-live-p win)
          (select-window win)
          (goto-char (point-max)))))))

;;;; Session commands

(defun hermes-interrupt-current-session ()
  "Send `session.interrupt' for the Hermes session at point.
In an Org buffer with `hermes-org-minor-mode' enabled, it resolves to
the `:hermes:' container containing point."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (sid (car target)))
    (unless target
      (user-error "No Hermes session at point"))
    (unless sid (user-error "No session id assigned yet"))
    (hermes--request "session.interrupt"
                     (list :session_id sid)
                     (lambda (_r e)
                       (when e (message "hermes: interrupt error: %S" e))))
    (hermes-dispatch '(:attachments-clear) sid)))

;;;###autoload
(defun hermes-bg-list ()
  "Pop a tabulated list of background tasks for the current session."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (sid (car target)))
    (if sid
        (progn (require 'hermes-bg)
               (hermes-bg--list-for-sid sid))
      (user-error "No active Hermes session in this buffer"))))

(provide 'hermes-session)
;;; hermes-session.el ends here
