;;; doom-dashboard-hermes.el --- Doom-styled landing dashboard for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A standalone landing buffer styled after Doom Emacs's `+doom-dashboard'.
;; Independent of `hermes-dashboard.el' so the vanilla dashboard stays
;; untouched.
;;
;; Centering mirrors Doom's approach:
;;   - Horizontal: content is inserted flush-left into the buffer, and the
;;     window's left/right margins are widened to push the canvas to the
;;     centre.  This means `string-width' math per line, no per-resize
;;     reformatting — just two `set-window-margins' calls.
;;   - Vertical:  a single block of newlines at the top, sized to whatever
;;     `window-height' currently is.
;;
;; Resize updates margins via `window-configuration-change-hook' and the
;; vertical pad via `window-size-change-functions'.
;;
;; Drop into a Doom config with:
;;
;;   (load! "~/Projects/emacs-hermes/doom-dashboard-hermes")
;;   (doom-dashboard-hermes-setup)   ; binds SPC h h, SPC h c, …

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hermes-rpc)
(require 'hermes-state)

(defvar hermes--session-buffers)        ; hermes-mode.el
(declare-function hermes "hermes-mode" ())
(declare-function hermes-new-session "hermes-mode" (&optional callback))
(declare-function hermes-input-send "hermes-input" (text))
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes-sessions "hermes-sessions" ())

;; The dashboard intentionally avoids `(require 'hermes-mode)' so it can be
;; loaded standalone; autoload the entry points it actually calls.
(autoload 'hermes              "hermes-mode"     nil t)
(autoload 'hermes-new-session  "hermes-mode"     nil nil)
(autoload 'hermes-input-send   "hermes-input"    nil t)
(autoload 'hermes-compose      "hermes-compose"  nil t)
(autoload 'hermes-sessions     "hermes-sessions" nil t)

;;;; User options

(defgroup doom-dashboard-hermes nil
  "Doom-styled landing dashboard for the Hermes agent."
  :group 'hermes :prefix "doom-dashboard-hermes-")

(defcustom doom-dashboard-hermes-width 80
  "Logical canvas width, in columns.  Used to compute window margins."
  :type 'integer :group 'doom-dashboard-hermes)

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
  '(("Start chatting"          doom-dashboard-hermes-start)
    ("Open composer"           doom-dashboard-hermes-compose)
    ("New session"             doom-dashboard-hermes-new)
    ("Session list"            hermes-sessions)
    ("Quit"                    quit-window))
  "Menu rows: each entry is (LABEL COMMAND).
Keybindings shown next to each label are looked up dynamically at render
time via `where-is-internal' — so if you bind a command under the Doom
leader (e.g. `SPC h h'), that key appears automatically."
  :type '(repeat (list string function))
  :group 'doom-dashboard-hermes)

(defcustom doom-dashboard-hermes-debounce 0.1
  "Idle seconds before a queued refresh actually repaints."
  :type 'number :group 'doom-dashboard-hermes)

(defconst doom-dashboard-hermes-buffer-name "*doom-hermes*")

(defvar doom-dashboard-hermes--pending-start nil
  "Non-nil while a `start' is waiting for `hermes-new-session' to resolve.
Prevents accidentally spawning a second session if the user presses `s'
twice before the first one has appeared.")

;;;; Faces

(defface doom-dashboard-hermes-banner-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the banner.")

(defface doom-dashboard-hermes-menu-face
  '((t :inherit default))
  "Face for menu row labels.")

(defface doom-dashboard-hermes-key-face
  '((t :inherit font-lock-constant-face))
  "Face for keybinding strings next to menu labels.")

(defface doom-dashboard-hermes-footer-face
  '((t :inherit shadow))
  "Face for the dim status footer.")

(defface doom-dashboard-hermes-status-face
  '((t :inherit success))
  "Face for the gateway-up status dot.")

(defface doom-dashboard-hermes-status-down-face
  '((t :inherit error))
  "Face for the gateway-down status dot.")

(defface doom-dashboard-hermes-status-starting-face
  '((t :inherit warning))
  "Face for the gateway-starting status dot.")

;;;; Helpers

(defun doom-dashboard-hermes--short-sid (sid)
  (if (and (stringp sid) (> (length sid) 8)) (substring sid 0 8) (or sid "?")))

(defun doom-dashboard-hermes--live-buffers ()
  "Return live session buffers, most-recently-touched first."
  (let (acc)
    (when (boundp 'hermes--session-buffers)
      (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
               hermes--session-buffers))
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))

(defun doom-dashboard-hermes--primary-buffer ()
  (car (doom-dashboard-hermes--live-buffers)))

(defun doom-dashboard-hermes--primary-state ()
  (when-let ((b (doom-dashboard-hermes--primary-buffer)))
    (buffer-local-value 'hermes--state b)))

(defun doom-dashboard-hermes--key-for (cmd)
  "Best-effort: return a human-readable key sequence bound to CMD, or nil.
Prefers leader bindings (e.g. `SPC h h') if visible, otherwise falls back
to a binding in the dashboard's own keymap."
  (let* ((keys (where-is-internal cmd nil t))
         (str  (and keys (key-description keys))))
    (and (stringp str) (not (string-empty-p str)) str)))

;;;; Section builders — each returns a propertized string, no padding

(defun doom-dashboard-hermes--banner-str ()
  (propertize doom-dashboard-hermes-banner
              'face 'doom-dashboard-hermes-banner-face))

(defun doom-dashboard-hermes--status-str ()
  (let* ((state hermes-rpc--state)
         (st    (doom-dashboard-hermes--primary-state))
         (sid   (and st (hermes-state-session-id st)))
         (info  (and st (hermes-state-session-info st)))
         (model (and (hash-table-p info) (gethash "model" info)))
         (face  (pcase state
                  ('ready    'doom-dashboard-hermes-status-face)
                  ('starting 'doom-dashboard-hermes-status-starting-face)
                  (_         'doom-dashboard-hermes-status-down-face)))
         (dot   (propertize "●" 'face face))
         (label (pcase state
                  ('down     "gateway down")
                  ('starting "gateway starting…")
                  ('ready
                   (cond
                    (doom-dashboard-hermes--pending-start "creating session…")
                    ((null sid) "ready  ·  no session yet")
                    (model (format "session %s ready  ·  %s"
                                   (doom-dashboard-hermes--short-sid sid)
                                   (if (> (length model) 28)
                                       (concat (substring model 0 27) "…")
                                     model)))
                    (t (format "session %s ready"
                               (doom-dashboard-hermes--short-sid sid))))))))
    (concat dot "  " label)))

(defun doom-dashboard-hermes--insert-menu-row (row)
  "Insert ROW (LABEL COMMAND) as a clickable text-button.
Label is flush-left; key (looked up via `where-is-internal') is
right-aligned within `doom-dashboard-hermes-width' columns."
  (let* ((label (nth 0 row))
         (cmd   (nth 1 row))
         (key   (or (doom-dashboard-hermes--key-for cmd) ""))
         (lw    (string-width label))
         (kw    (string-width key))
         (gap   (max 1 (- doom-dashboard-hermes-width lw kw 4)))
         (text  (concat "  "
                        (propertize label 'face 'doom-dashboard-hermes-menu-face)
                        (make-string gap ?\s)
                        (propertize key 'face 'doom-dashboard-hermes-key-face)
                        "  ")))
    (insert-text-button
     text
     'action (lambda (_btn) (call-interactively cmd))
     'follow-link t
     'help-echo (format "Run `%s'" cmd)
     'mouse-face 'highlight
     'face nil)))

(defun doom-dashboard-hermes--insert-menu ()
  "Insert all menu rows; called from the render function."
  (let ((first t))
    (dolist (row doom-dashboard-hermes-menu)
      (unless first (insert "\n"))
      (setq first nil)
      (doom-dashboard-hermes--insert-menu-row row))))

(defun doom-dashboard-hermes--footer-str ()
  (let* ((n (length (doom-dashboard-hermes--live-buffers)))
         (txt (format "%d %s live  ·  gateway %s"
                      n (if (= n 1) "session" "sessions")
                      (pcase hermes-rpc--state
                        ('ready "up") ('starting "starting") (_ "down")))))
    (propertize txt 'face 'doom-dashboard-hermes-footer-face)))

;;;; Render (flush-left, no per-line centering)

(defun doom-dashboard-hermes--render-content ()
  "Insert the dashboard content flush-left.  Margins handle centering."
  (insert (doom-dashboard-hermes--banner-str) "\n\n")
  (insert (doom-dashboard-hermes--status-str) "\n\n")
  (doom-dashboard-hermes--insert-menu)
  (insert "\n\n")
  (insert (doom-dashboard-hermes--footer-str)))

(defun doom-dashboard-hermes--render ()
  "Repaint the dashboard buffer and re-centre via margins + top padding."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (doom-dashboard-hermes--render-content)
    (doom-dashboard-hermes--apply-vertical-padding)
    (doom-dashboard-hermes--apply-margins)
    (goto-char (point-min))
    ;; Park point on the first menu button so RET / TAB Just Work.
    (when (ignore-errors (forward-button 1))
      t)))

;;;; Window-margin centering (mirrors `+doom-dashboard-resize-h')

(defun doom-dashboard-hermes--apply-margins ()
  "Set left/right margins on every window showing the dashboard buffer."
  (dolist (win (get-buffer-window-list (current-buffer) nil t))
    (let* ((total (window-total-width win))
           (margin (max 0 (/ (- total doom-dashboard-hermes-width) 2))))
      (set-window-margins win margin margin))))

(defun doom-dashboard-hermes--apply-vertical-padding ()
  "Insert blank lines at the top so content sits vertically centred."
  (let* ((win (get-buffer-window (current-buffer) 'visible))
         (h   (if win (window-height win) (frame-height)))
         (lines (count-lines (point-min) (point-max)))
         (pad (max 1 (- (/ h 2) (/ lines 2)))))
    (save-excursion
      (goto-char (point-min))
      (insert (make-string pad ?\n)))))

;;;; Debounced refresh

(defvar doom-dashboard-hermes--refresh-timer nil
  "Pending idle timer, or nil.")

(defconst doom-dashboard-hermes--refresh-events
  '("gateway.ready" "skin.changed" "session.info" "session.closed"
    "message.complete" "error")
  "Event types that should trigger a dashboard repaint.")

(defun doom-dashboard-hermes--schedule-refresh ()
  (when (timerp doom-dashboard-hermes--refresh-timer)
    (cancel-timer doom-dashboard-hermes--refresh-timer))
  (setq doom-dashboard-hermes--refresh-timer
        (run-with-idle-timer
         doom-dashboard-hermes-debounce nil
         #'doom-dashboard-hermes--do-refresh)))

(defun doom-dashboard-hermes--do-refresh ()
  (setq doom-dashboard-hermes--refresh-timer nil)
  (let ((buf (get-buffer doom-dashboard-hermes-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (doom-dashboard-hermes--render)))))

(defun doom-dashboard-hermes--on-event (type &rest _ignore)
  (when (member type doom-dashboard-hermes--refresh-events)
    (doom-dashboard-hermes--schedule-refresh)))

(defun doom-dashboard-hermes--on-connection (&rest _ignore)
  (doom-dashboard-hermes--schedule-refresh))

(defun doom-dashboard-hermes--on-window-change (&rest _ignore)
  "Re-apply margins/vertical pad on window resize or split."
  (let ((buf (get-buffer doom-dashboard-hermes-buffer-name)))
    (when (and (buffer-live-p buf)
               (get-buffer-window buf 'visible))
      (doom-dashboard-hermes--schedule-refresh))))

;;;; Hook lifecycle

(defun doom-dashboard-hermes--install-hooks ()
  (add-hook 'hermes-rpc-event-functions       #'doom-dashboard-hermes--on-event)
  (add-hook 'hermes-rpc-connection-functions  #'doom-dashboard-hermes--on-connection)
  (add-hook 'window-size-change-functions     #'doom-dashboard-hermes--on-window-change)
  (add-hook 'window-configuration-change-hook #'doom-dashboard-hermes--on-window-change))

(defun doom-dashboard-hermes--uninstall-hooks ()
  (remove-hook 'hermes-rpc-event-functions       #'doom-dashboard-hermes--on-event)
  (remove-hook 'hermes-rpc-connection-functions  #'doom-dashboard-hermes--on-connection)
  (remove-hook 'window-size-change-functions     #'doom-dashboard-hermes--on-window-change)
  (remove-hook 'window-configuration-change-hook #'doom-dashboard-hermes--on-window-change)
  (when (timerp doom-dashboard-hermes--refresh-timer)
    (cancel-timer doom-dashboard-hermes--refresh-timer)
    (setq doom-dashboard-hermes--refresh-timer nil)))

;;;; Commands

(defun doom-dashboard-hermes-refresh ()
  "Force an immediate refresh."
  (interactive)
  (doom-dashboard-hermes--do-refresh))

(defun doom-dashboard-hermes-start ()
  "Start chatting: pop the primary session buffer and read a prompt.
If no session exists yet, create one in the background and pop the
buffer the moment it appears.  A second press while creation is still
in flight is a no-op."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (cond
     (buf
      (pop-to-buffer buf)
      (call-interactively #'hermes-input-send))
     (doom-dashboard-hermes--pending-start
      (message "Hermes: session is on its way…"))
     (t
      (setq doom-dashboard-hermes--pending-start t)
      (message "Hermes: creating session…")
      (hermes-new-session
       (lambda (b)
         (setq doom-dashboard-hermes--pending-start nil)
         (doom-dashboard-hermes--schedule-refresh)
         (when (buffer-live-p b)
           (pop-to-buffer b)
           (call-interactively #'hermes-input-send))))))))

(defun doom-dashboard-hermes-compose ()
  "Pop the primary session buffer and open the multi-line composer."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (cond
     (buf (pop-to-buffer buf)
          (call-interactively #'hermes-compose))
     (t (user-error "No live session yet")))))

(defun doom-dashboard-hermes-new ()
  "Create a new Hermes session in the background, without leaving the dashboard."
  (interactive)
  (hermes-new-session
   (lambda (_buf) (doom-dashboard-hermes--schedule-refresh))))

;;;; Mode

(defvar doom-dashboard-hermes-mode-map
  (let ((m (make-sparse-keymap)))
    ;; Single-letter shortcuts inside the buffer.  Doom users will mostly
    ;; reach the same commands via SPC h h / SPC h c / … which `where-is'
    ;; picks up automatically and shows next to each menu row.
    ;; Button navigation (mirrors `+doom-dashboard-mode-map').
    (define-key m (kbd "TAB")     #'forward-button)
    (define-key m (kbd "<tab>")   #'forward-button)
    (define-key m (kbd "<backtab>") #'backward-button)
    (define-key m (kbd "C-n")     #'forward-button)
    (define-key m (kbd "C-p")     #'backward-button)
    (define-key m (kbd "<down>")  #'forward-button)
    (define-key m (kbd "<up>")    #'backward-button)
    ;; Direct triggers (preserved muscle-memory).
    (define-key m (kbd "RET") #'push-button)
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
        (doom-dashboard-hermes-mode)))
    ;; Display BEFORE rendering so `--apply-margins' has a real window
    ;; to read `window-total-width' from.  Rendering first leaves the
    ;; first frame flush-left until a resize hook fires.
    (pop-to-buffer-same-window buf)
    (with-current-buffer buf
      (doom-dashboard-hermes--render))))

;;;###autoload
(defun doom-dashboard-hermes-setup ()
  "Convenience entry for `~/.doom.d/config.el'.
Adds leader bindings under `SPC h' so the dashboard's menu rows show real
key sequences (`SPC h h', `SPC h c', …) via `where-is-internal'."
  (interactive)
  (when (fboundp 'map!)
    (eval
     '(map! :leader
            (:prefix ("h" . "hermes")
             :desc "Hermes dashboard" "h" #'doom-dashboard-hermes
             :desc "Start chatting"   "s" #'doom-dashboard-hermes-start
             :desc "Compose"          "c" #'doom-dashboard-hermes-compose
             :desc "New session"      "n" #'doom-dashboard-hermes-new
             :desc "Session list"     "l" #'hermes-sessions)))))

(provide 'doom-dashboard-hermes)
;;; doom-dashboard-hermes.el ends here
