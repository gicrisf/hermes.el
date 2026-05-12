;;; hermes-sessions.el --- Tabulated sidebar of live Hermes sessions -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A `tabulated-list-mode' buffer (`*Hermes Sessions*') listing every
;; session in `hermes--session-buffers'.  RET switches to the session's
;; buffer; `k' closes a session via `session.close' and kills the buffer;
;; `g' refreshes.
;;
;; The sidebar auto-refreshes whenever the route layer sees an incoming
;; event for a known session — cheap, since the hook short-circuits when
;; the sidebar isn't open.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'hermes-state)
(require 'hermes-rpc)

(defvar hermes--session-buffers)        ; defined in hermes-mode.el

(defconst hermes-sessions-buffer-name "*Hermes Sessions*")

;;;; Row data

(defun hermes-sessions--short-sid (sid)
  "Return the first 8 chars of SID for display."
  (if (and (stringp sid) (> (length sid) 8))
      (substring sid 0 8)
    (or sid "?")))

(defun hermes-sessions--row (sid buf)
  "Build a tabulated-list entry (ID VECTOR) for SID/BUF."
  (with-current-buffer buf
    (let* ((st    hermes--state)
           (info  (and st (hermes-state-session-info st)))
           (model (or (and (hash-table-p info) (gethash "model" info)) "?"))
           (cwd   (or (and (hash-table-p info) (gethash "cwd"   info)) ""))
           (msgs  (length (and st (hermes-state-messages st))))
           (q     (length (and st (hermes-state-queue st))))
           (status (cond ((and st (hermes-state-pending st)) "blocked")
                         ((and st (hermes-state-stream  st)) "running")
                         (t "idle")))
           (status+q (if (> q 0) (format "%s (+%d)" status q) status)))
      (list sid
            (vector (hermes-sessions--short-sid sid)
                    (format "%s" model)
                    status+q
                    (number-to-string msgs)
                    (abbreviate-file-name (or cwd "")))))))

(defun hermes-sessions--entries ()
  "Collect entries for every live session buffer."
  (let (rows)
    (maphash
     (lambda (sid buf)
       (when (buffer-live-p buf)
         (push (hermes-sessions--row sid buf) rows)))
     hermes--session-buffers)
    (nreverse rows)))

;;;; Buffer lookup helpers

(defun hermes-sessions--buffer ()
  "Return the live sidebar buffer, or nil."
  (get-buffer hermes-sessions-buffer-name))

(defun hermes-sessions--refresh-if-open (&rest _ignore)
  "Revert the sidebar buffer if it exists.  Cheap no-op otherwise."
  (let ((buf (hermes-sessions--buffer)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (let ((pt (point)))
          (tabulated-list-print t)
          (goto-char (min pt (point-max))))))))

;;;; Mode

(defvar hermes-sessions-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m tabulated-list-mode-map)
    (define-key m (kbd "RET") #'hermes-sessions-switch)
    (define-key m (kbd "o")   #'hermes-sessions-switch-other-window)
    (define-key m (kbd "k")   #'hermes-sessions-close)
    (define-key m (kbd "+")   #'hermes-sessions-new)
    m)
  "Keymap for `hermes-sessions-mode'.")

(define-derived-mode hermes-sessions-mode tabulated-list-mode "HermesSessions"
  "Major mode for the Hermes sessions sidebar."
  (setq tabulated-list-format
        [("SID"    10 t)
         ("Model"  12 t)
         ("Status" 16 t)
         ("Msgs"    5 (lambda (a b)
                        (< (string-to-number (aref (cadr a) 3))
                           (string-to-number (aref (cadr b) 3)))))
         ("CWD"     0 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries #'hermes-sessions--entries)
  (tabulated-list-init-header))

;;;; Commands

(defun hermes-sessions--sid-at-point ()
  "Return the session id at point, or signal."
  (or (tabulated-list-get-id)
      (user-error "No session on this line")))

(defun hermes-sessions-switch ()
  "Switch to the session buffer at point."
  (interactive)
  (let ((buf (gethash (hermes-sessions--sid-at-point)
                      hermes--session-buffers)))
    (if (buffer-live-p buf)
        (pop-to-buffer-same-window buf)
      (user-error "Session buffer is gone — refresh with g"))))

(defun hermes-sessions-switch-other-window ()
  "Display the session buffer at point in another window."
  (interactive)
  (let ((buf (gethash (hermes-sessions--sid-at-point)
                      hermes--session-buffers)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (user-error "Session buffer is gone — refresh with g"))))

(defun hermes-sessions-close ()
  "Close the session at point: send `session.close', then kill its buffer."
  (interactive)
  (let* ((sid (hermes-sessions--sid-at-point))
         (buf (gethash sid hermes--session-buffers)))
    (unless (yes-or-no-p (format "Close session %s? "
                                 (hermes-sessions--short-sid sid)))
      (user-error "Cancelled"))
    (when (hermes-rpc-live-p)
      (hermes-rpc-request "session.close"
                          (list :session_id sid)
                          (lambda (_r e)
                            (when e
                              (message "hermes: session.close error: %S" e)))))
    (remhash sid hermes--session-buffers)
    (when (buffer-live-p buf) (kill-buffer buf))
    (hermes-sessions--refresh-if-open)))

(defun hermes-sessions-new ()
  "Create a new Hermes session."
  (interactive)
  ;; `hermes' is defined in hermes-mode.el; this file is loaded after it.
  (call-interactively (intern-soft "hermes")))

;;;###autoload
(defun hermes-sessions ()
  "Pop up the Hermes sessions sidebar."
  (interactive)
  (let ((buf (get-buffer-create hermes-sessions-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'hermes-sessions-mode)
        (hermes-sessions-mode))
      (tabulated-list-print t))
    (pop-to-buffer buf
                   '(display-buffer-in-side-window
                     (side . right)
                     (window-width . 50)))))

(provide 'hermes-sessions)
;;; hermes-sessions.el ends here
