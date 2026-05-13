;;; doom-dashboard-hermes.el --- Doom-styled landing dashboard for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A standalone landing buffer styled after Doom Emacs's dashboard:
;; centered banner, vertical keyboard-driven menu, dim status footer.
;; Independent of `hermes-dashboard.el' so the vanilla dashboard stays
;; untouched.  Drop into a Doom config with:
;;
;;   (load! "~/Projects/emacs-hermes/doom-dashboard-hermes")
;;   (doom-dashboard-hermes-setup)
;;
;; Performance: a 100ms idle-timer debouncer collapses bursts of RPC
;; events into a single repaint; only event types that change visible
;; fields are allowed through the filter; the whole buffer is built as
;; one propertized string and swapped in atomically.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hermes-rpc)
(require 'hermes-state)

(defvar hermes--session-buffers)        ; hermes-mode.el
(declare-function hermes "hermes-mode" ())
(declare-function hermes-input-send "hermes-input" (text))
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes-sessions "hermes-sessions" ())

;;;; User options

(defgroup doom-dashboard-hermes nil
  "Doom-styled landing dashboard for the Hermes agent."
  :group 'hermes :prefix "doom-dashboard-hermes-")

(defcustom doom-dashboard-hermes-banner
  "\
██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗
██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝
███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗
██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║
██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║
╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝"
  "Banner string shown at the top of the dashboard."
  :type 'string :group 'doom-dashboard-hermes)

(defcustom doom-dashboard-hermes-menu
  '(("s" "Start chatting"          doom-dashboard-hermes-start)
    ("c" "Open multiline composer" doom-dashboard-hermes-compose)
    ("n" "New session"             doom-dashboard-hermes-new)
    ("l" "Session list"            hermes-sessions)
    ("q" "Quit"                    quit-window))
  "Menu rows: each entry is (KEY LABEL COMMAND)."
  :type '(repeat (list string string function))
  :group 'doom-dashboard-hermes)

(defcustom doom-dashboard-hermes-debounce 0.1
  "Idle seconds before a queued refresh actually repaints."
  :type 'number :group 'doom-dashboard-hermes)

(defconst doom-dashboard-hermes-buffer-name "*doom-hermes*")

;;;; Faces

(defface doom-dashboard-hermes-banner-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the centered banner.")

(defface doom-dashboard-hermes-key-face
  '((t :inherit font-lock-constant-face :weight bold))
  "Face for [k] key labels in menu rows.")

(defface doom-dashboard-hermes-menu-face
  '((t :inherit default))
  "Face for menu row labels.")

(defface doom-dashboard-hermes-footer-face
  '((t :inherit shadow))
  "Face for the dim status footer.")

(defface doom-dashboard-hermes-status-face
  '((t :inherit success))
  "Face for the green session-ready indicator.")

(defface doom-dashboard-hermes-status-down-face
  '((t :inherit error))
  "Face for the red gateway-down indicator.")

;;;; Helpers

(defun doom-dashboard-hermes--strip-rich (s)
  "Remove Rich `[…]'/`[/]' open/close markup from S."
  (replace-regexp-in-string "\\[/?[^]]*\\]" "" s))

(defun doom-dashboard-hermes--short-sid (sid)
  (if (and (stringp sid) (> (length sid) 8)) (substring sid 0 8) (or sid "?")))

(defun doom-dashboard-hermes--live-buffers ()
  "Return the live session buffers, newest-first."
  (let (acc)
    (when (boundp 'hermes--session-buffers)
      (maphash (lambda (_sid b)
                 (when (buffer-live-p b) (push b acc)))
               hermes--session-buffers))
    ;; Sort by buffer-modified-tick descending → most recently touched first.
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))

(defun doom-dashboard-hermes--primary-state ()
  "Return the most-recently-active session's `hermes-state', or nil."
  (when-let ((buf (car (doom-dashboard-hermes--live-buffers))))
    (buffer-local-value 'hermes--state buf)))

(defun doom-dashboard-hermes--primary-buffer ()
  "Return the most-recently-active session buffer, or nil."
  (car (doom-dashboard-hermes--live-buffers)))

(defun doom-dashboard-hermes--center (text width)
  "Return TEXT prefixed with spaces so it sits centered in a WIDTH window.
TEXT may already contain face properties; they are preserved."
  (let* ((len (string-width
               (substring-no-properties (replace-regexp-in-string "\n.*" "" text))))
         (pad (max 0 (/ (- width len) 2))))
    (concat (make-string pad ?\s) text)))

(defun doom-dashboard-hermes--center-block (block width)
  "Center each line of BLOCK independently to WIDTH."
  (mapconcat (lambda (line) (doom-dashboard-hermes--center line width))
             (split-string block "\n")
             "\n"))

;;;; Section builders — each returns a propertized string

(defun doom-dashboard-hermes--banner-str (width)
  (let* ((clean (doom-dashboard-hermes--strip-rich
                 doom-dashboard-hermes-banner))
         (centered (doom-dashboard-hermes--center-block clean width)))
    (propertize centered 'face 'doom-dashboard-hermes-banner-face)))

(defun doom-dashboard-hermes--status-str (width)
  (let* ((live (hermes-rpc-live-p))
         (st (doom-dashboard-hermes--primary-state))
         (sid (and st (hermes-state-session-id st)))
         (info (and st (hermes-state-session-info st)))
         (model (and (hash-table-p info) (gethash "model" info)))
         (face (if live 'doom-dashboard-hermes-status-face
                 'doom-dashboard-hermes-status-down-face))
         (dot (propertize "●" 'face face))
         (label (cond
                 ((not live) "gateway down")
                 ((null sid) "starting session…")
                 (model (format "session %s ready  ·  %s"
                                (doom-dashboard-hermes--short-sid sid)
                                model))
                 (t (format "session %s ready"
                            (doom-dashboard-hermes--short-sid sid))))))
    (doom-dashboard-hermes--center (concat dot "  " label) width)))

(defun doom-dashboard-hermes--menu-str (width)
  (let* ((rows (mapcar
                (lambda (row)
                  (let ((key (nth 0 row))
                        (label (nth 1 row)))
                    (concat
                     (propertize (format "[%s]" key)
                                 'face 'doom-dashboard-hermes-key-face)
                     "  "
                     (propertize label
                                 'face 'doom-dashboard-hermes-menu-face))))
                doom-dashboard-hermes-menu))
         ;; Center the whole block by aligning to the widest row.
         (widest (apply #'max 0 (mapcar (lambda (r)
                                          (string-width
                                           (substring-no-properties r)))
                                        rows)))
         (left-pad (max 0 (/ (- width widest) 2)))
         (prefix (make-string left-pad ?\s)))
    (mapconcat (lambda (r) (concat prefix r)) rows "\n")))

(defun doom-dashboard-hermes--footer-str (width)
  (let* ((n (length (doom-dashboard-hermes--live-buffers)))
         (live (hermes-rpc-live-p))
         (txt (format "%d %s live  ·  gateway %s"
                      n (if (= n 1) "session" "sessions")
                      (if live "up" "down"))))
    (doom-dashboard-hermes--center
     (propertize txt 'face 'doom-dashboard-hermes-footer-face)
     width)))

;;;; Render

(defun doom-dashboard-hermes--build-string (width height)
  "Build the full dashboard contents as a single propertized string."
  (let* ((banner (doom-dashboard-hermes--banner-str width))
         (status (doom-dashboard-hermes--status-str width))
         (menu   (doom-dashboard-hermes--menu-str width))
         (footer (doom-dashboard-hermes--footer-str width))
         (content (string-join (list banner "" status "" menu "" footer) "\n"))
         (content-lines (1+ (cl-count ?\n content)))
         (top-pad (max 1 (/ (- height content-lines) 3))))
    (concat (make-string top-pad ?\n) content "\n")))

(defun doom-dashboard-hermes--render ()
  "Repaint the dashboard buffer.  Must be called inside it."
  (let* ((win (get-buffer-window (current-buffer) 'visible))
         (width (if win (window-width win) (frame-width)))
         (height (if win (window-height win) (frame-height)))
         (inhibit-read-only t)
         (s (doom-dashboard-hermes--build-string width height)))
    (erase-buffer)
    (insert s)
    (goto-char (point-min))))

;;;; Debounced refresh

(defvar doom-dashboard-hermes--refresh-timer nil
  "Pending idle timer, or nil.")

(defconst doom-dashboard-hermes--refresh-events
  '("gateway.ready" "skin.changed" "session.info" "session.closed"
    "message.complete" "error")
  "Event types that should trigger a dashboard repaint.")

(defun doom-dashboard-hermes--schedule-refresh ()
  "Cancel any pending refresh and schedule a fresh one."
  (when (timerp doom-dashboard-hermes--refresh-timer)
    (cancel-timer doom-dashboard-hermes--refresh-timer))
  (setq doom-dashboard-hermes--refresh-timer
        (run-with-idle-timer
         doom-dashboard-hermes-debounce nil
         #'doom-dashboard-hermes--do-refresh)))

(defun doom-dashboard-hermes--do-refresh ()
  "Actually repaint the dashboard if it exists."
  (setq doom-dashboard-hermes--refresh-timer nil)
  (let ((buf (get-buffer doom-dashboard-hermes-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (doom-dashboard-hermes--render)))))

(defun doom-dashboard-hermes--on-event (type &rest _ignore)
  "Hook for `hermes-rpc-event-functions'.  Filter and schedule."
  (when (member type doom-dashboard-hermes--refresh-events)
    (doom-dashboard-hermes--schedule-refresh)))

(defun doom-dashboard-hermes--on-connection (&rest _ignore)
  "Hook for `hermes-rpc-connection-functions'.  Always schedule."
  (doom-dashboard-hermes--schedule-refresh))

(defun doom-dashboard-hermes--on-window-resize (_frame)
  "Re-center on resize, but only if the dashboard is visible somewhere."
  (when (get-buffer-window doom-dashboard-hermes-buffer-name 'visible)
    (doom-dashboard-hermes--schedule-refresh)))

;;;; Hook lifecycle

(defun doom-dashboard-hermes--install-hooks ()
  (add-hook 'hermes-rpc-event-functions      #'doom-dashboard-hermes--on-event)
  (add-hook 'hermes-rpc-connection-functions #'doom-dashboard-hermes--on-connection)
  (add-hook 'window-size-change-functions    #'doom-dashboard-hermes--on-window-resize))

(defun doom-dashboard-hermes--uninstall-hooks ()
  (remove-hook 'hermes-rpc-event-functions      #'doom-dashboard-hermes--on-event)
  (remove-hook 'hermes-rpc-connection-functions #'doom-dashboard-hermes--on-connection)
  (remove-hook 'window-size-change-functions    #'doom-dashboard-hermes--on-window-resize)
  (when (timerp doom-dashboard-hermes--refresh-timer)
    (cancel-timer doom-dashboard-hermes--refresh-timer)
    (setq doom-dashboard-hermes--refresh-timer nil)))

;;;; Commands

(defun doom-dashboard-hermes-refresh ()
  "Force an immediate refresh."
  (interactive)
  (doom-dashboard-hermes--do-refresh))

(defun doom-dashboard-hermes-start ()
  "Pop the primary session buffer and prompt via `hermes-input-send'."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (cond
     (buf (pop-to-buffer buf)
          (call-interactively #'hermes-input-send))
     (t (when (yes-or-no-p "No live session — create one? ")
          (call-interactively #'hermes))))))

(defun doom-dashboard-hermes-compose ()
  "Pop the primary session buffer and open the multi-line composer."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (cond
     (buf (pop-to-buffer buf)
          (call-interactively #'hermes-compose))
     (t (user-error "No live session yet")))))

(defun doom-dashboard-hermes-new ()
  "Create a new Hermes session via `hermes'."
  (interactive)
  (call-interactively #'hermes))

;;;; Mode

(defvar doom-dashboard-hermes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'doom-dashboard-hermes-start)
    (define-key m (kbd "i")   #'doom-dashboard-hermes-start)
    (define-key m (kbd "s")   #'doom-dashboard-hermes-start)
    (define-key m (kbd "c")   #'doom-dashboard-hermes-compose)
    (define-key m (kbd "n")   #'doom-dashboard-hermes-new)
    (define-key m (kbd "l")   #'hermes-sessions)
    (define-key m (kbd "g")   #'doom-dashboard-hermes-refresh)
    (define-key m (kbd "q")   #'quit-window)
    m)
  "Keymap for `doom-dashboard-hermes-mode'.")

(define-derived-mode doom-dashboard-hermes-mode special-mode "Doom-Hermes"
  "Major mode for the Doom-styled Hermes landing buffer."
  (setq-local cursor-type nil)
  (setq-local mode-line-format nil)
  (setq-local header-line-format nil)
  (setq-local truncate-lines t)
  (setq-local show-trailing-whitespace nil)
  (buffer-disable-undo)
  (doom-dashboard-hermes--install-hooks)
  (add-hook 'kill-buffer-hook
            #'doom-dashboard-hermes--uninstall-hooks nil t))

;;;; Entry point

;;;###autoload
(defun doom-dashboard-hermes ()
  "Open the Doom-styled Hermes dashboard."
  (interactive)
  (let ((buf (get-buffer-create doom-dashboard-hermes-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'doom-dashboard-hermes-mode)
        (doom-dashboard-hermes-mode))
      (doom-dashboard-hermes--render))
    (pop-to-buffer-same-window buf)))

;;;###autoload
(defun doom-dashboard-hermes-setup ()
  "Convenience entry for `~/.doom.d/config.el'.
Binds `SPC h h' under the Doom leader when `map!' is available."
  (interactive)
  (when (fboundp 'map!)
    (eval '(map! :leader :desc "Hermes dashboard" "h h"
                 #'doom-dashboard-hermes))))

(provide 'doom-dashboard-hermes)
;;; doom-dashboard-hermes.el ends here
