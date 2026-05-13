;;; hermes-dashboard.el --- Landing dashboard for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; `*Hermes*' is the landing buffer shown by `M-x hermes'.  It auto-starts
;; the gateway, fires `session.create' in the background, and renders four
;; sections: logo, connection state, primary session info, and a compact
;; session list.  `i' (or RET on the logo region) opens the minibuffer
;; composer for the primary session; the conversation buffer pops into view
;; on first prompt.  RET on a session row switches to that buffer.

;;; Code:

(require 'cl-lib)
(require 'hermes-rpc)
(require 'hermes-state)

(defvar hermes--session-buffers)        ; hermes-mode.el
(defvar hermes--last-gateway-ready)     ; hermes-mode.el
(declare-function hermes-input-send "hermes-input" (text))
(declare-function hermes-sessions "hermes-sessions" ())
(declare-function hermes "hermes-mode" ())
(declare-function hermes-interrupt "hermes-mode" ())

(defcustom hermes-dashboard-logo nil
  "If non-nil, a string used as the dashboard banner instead of the builtin.
Overrides any banner the gateway may provide via `gateway.ready'."
  :type '(choice (const nil) string) :group 'hermes)

(defconst hermes-dashboard-buffer-name "*Hermes*")

(defconst hermes-dashboard--builtin-logo
  "\
██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗
██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝
███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗
██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║
██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║
╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝"
  "Fallback NOUS HERMES banner.")

;;;; State

(defvar hermes-dashboard--primary-sid nil
  "Session id treated as the dashboard's `current' for the composer.")

;;;; Faces

(defface hermes-dashboard-logo-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the dashboard banner." :group 'hermes)

(defface hermes-dashboard-heading-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for dashboard section headings." :group 'hermes)

(defface hermes-dashboard-key-face
  '((t :inherit font-lock-constant-face))
  "Face for keybinding labels." :group 'hermes)

(defface hermes-dashboard-dim-face
  '((t :inherit shadow))
  "Face for dimmed/secondary text." :group 'hermes)

;;;; Helpers

(defun hermes-dashboard--logo ()
  "Pick the best available logo string."
  (or hermes-dashboard-logo
      (let* ((skin hermes--last-gateway-ready)
             (h (and (hash-table-p skin) (gethash "skin" skin)))
             (banner (and (hash-table-p (or h skin))
                          (or (gethash "banner_hero" (or h skin))
                              (gethash "banner_logo" (or h skin))))))
        (and (stringp banner) (not (string-empty-p banner)) banner))
      hermes-dashboard--builtin-logo))

(defun hermes-dashboard--strip-rich (string)
  "Return STRING with Rich `[style]…[/]' open/close tags removed."
  (replace-regexp-in-string
   "\\[/?[^]]*\\]" "" string))

(defun hermes-dashboard--insert-logo (string)
  "Insert STRING as the dashboard banner, faced with `hermes-dashboard-logo-face'."
  (let ((start (point)))
    (insert (hermes-dashboard--strip-rich string))
    (add-face-text-property start (point) 'hermes-dashboard-logo-face)))

(defun hermes-dashboard--logo-with-status (logo status)
  "Return LOGO with STATUS appended to its last line, right-padded to logo width.
Returns LOGO unchanged when STATUS is empty."
  (if (or (null status) (string-empty-p (string-trim status)))
      logo
    (let* ((lines (split-string logo "\n")))
      (when lines
        (let* ((width (apply #'max (mapcar #'length lines)))
               (last (car (last lines)))
               (pad (max 1 (- width (length last) (length status) 2))))
          (setf (car (last lines))
                (concat last (make-string pad ?\s) " " status))))
      (string-join lines "\n"))))

(defun hermes-dashboard--short-sid (sid)
  (if (and (stringp sid) (> (length sid) 8)) (substring sid 0 8) (or sid "?")))

(defun hermes-dashboard--connection-line ()
  (let* ((live (hermes-rpc-live-p))
         (sid hermes-dashboard--primary-sid)
         (label (cond ((not live) "gateway down")
                      ((null sid) "starting session…")
                      (t (format "session %s ready"
                                 (hermes-dashboard--short-sid sid))))))
    (propertize (format "  ● %s" label) 'face
                (if live 'success 'error))))

(defun hermes-dashboard--primary-state ()
  "Return the `hermes-state' of the primary session buffer, or nil."
  (let* ((sid hermes-dashboard--primary-sid)
         (buf (and sid (boundp 'hermes--session-buffers)
                   (gethash sid hermes--session-buffers))))
    (and (buffer-live-p buf)
         (buffer-local-value 'hermes--state buf))))

(defun hermes-dashboard--insert-heading (text)
  (insert (propertize (format "◆  %s" text) 'face 'hermes-dashboard-heading-face) "\n"))

(defun hermes-dashboard--info-row (label value)
  (insert (format "   %-10s %s\n"
                  (propertize label 'face 'hermes-dashboard-dim-face)
                  (or value "—"))))

(defun hermes-dashboard--insert-session-info ()
  (let* ((st (hermes-dashboard--primary-state))
         (info (and st (hermes-state-session-info st))))
    (hermes-dashboard--insert-heading "Session")
    (cond
     ((null st) (insert "   (no session)\n"))
     (t
      (let* ((sid (hermes-state-session-id st))
             (model (and (hash-table-p info) (gethash "model" info)))
             (cwd   (and (hash-table-p info) (gethash "cwd"   info)))
             (tools (and (hash-table-p info) (gethash "tools" info)))
             (skills (and (hash-table-p info) (gethash "skills" info)))
             (sysp  (and (hash-table-p info) (gethash "system_prompt" info))))
        (hermes-dashboard--info-row "Model"   model)
        (hermes-dashboard--info-row "CWD"     (and cwd (abbreviate-file-name cwd)))
        (hermes-dashboard--info-row "Session" sid)
        (hermes-dashboard--info-row
         "Tools"
         (format "%s   Skills: %s"
                 (cond ((numberp tools) tools)
                       ((sequencep tools) (length tools))
                       (t "?"))
                 (cond ((numberp skills) skills)
                       ((sequencep skills) (length skills))
                       (t "?"))))
        (when (and (stringp sysp) (not (string-empty-p sysp)))
          (insert (propertize "   system prompt:\n"
                              'face 'hermes-dashboard-dim-face))
          (dolist (line (split-string sysp "\n"))
            (insert "     " (propertize line 'face 'hermes-dashboard-dim-face)
                    "\n"))))))
    (insert "\n")))

(defun hermes-dashboard--insert-session-list ()
  (hermes-dashboard--insert-heading "Sessions")
  (let ((empty t))
    (when (boundp 'hermes--session-buffers)
      (insert (propertize "   SID        Model              Status      Msgs\n"
                          'face 'hermes-dashboard-dim-face))
      (maphash
       (lambda (sid buf)
         (when (buffer-live-p buf)
           (setq empty nil)
           (let* ((st (buffer-local-value 'hermes--state buf))
                  (info (and st (hermes-state-session-info st)))
                  (model (or (and (hash-table-p info) (gethash "model" info)) "?"))
                  (msgs (length (and st (hermes-state-messages st))))
                  (status (cond ((and st (eq (hermes-state-connection st)
                                             'disconnected)) "dead")
                                ((and st (hermes-state-pending st)) "blocked")
                                ((and st (hermes-state-stream  st)) "running")
                                (t "idle")))
                  (start (point)))
             (insert (format "   %-10s  %-16s  %-8s  %d msgs\n"
                             (hermes-dashboard--short-sid sid)
                             model status msgs))
             (add-text-properties start (point)
                                  (list 'hermes-dashboard-sid sid
                                        'mouse-face 'highlight)))))
       hermes--session-buffers))
    (when empty
      (insert (propertize "   (no live sessions)\n"
                          'face 'hermes-dashboard-dim-face))))
  (insert "\n"))

(defun hermes-dashboard--insert-commands ()
  (hermes-dashboard--insert-heading "Commands")
  (dolist (row '(("i / RET" . "send")
                 ("c"       . "compose")
                 ("n"       . "new session")
                 ("s"       . "sidebar")
                 ("g"       . "refresh")
                 ("q"       . "quit")))
    (insert (format "   %-9s %s\n"
                    (propertize (car row) 'face 'hermes-dashboard-key-face)
                    (cdr row)))))

;;;; Refresh

(defun hermes-dashboard--refresh ()
  "Repaint the dashboard buffer.  Must be called inside it."
  (let ((inhibit-read-only t)
        (pt (point)))
    (erase-buffer)
    (insert "\n")
    (let ((logo (hermes-dashboard--logo-with-status
                 (hermes-dashboard--logo)
                 (hermes-dashboard--connection-line))))
      (hermes-dashboard--insert-logo logo)
      (insert "\n")
      (let ((w (car (sort (mapcar #'length (split-string logo "\n")) #'>))))
        (insert (propertize (make-string (min w 80) ?─) 'face 'hermes-dashboard-dim-face) "\n\n")))
    (hermes-dashboard--insert-session-info)
    (hermes-dashboard--insert-session-list)
    (hermes-dashboard--insert-commands)
    (goto-char (min pt (point-max)))))

(defconst hermes-dashboard--refresh-events
  '("gateway.ready" "skin.changed" "session.info" "session.closed"
    "message.complete" "error")
  "Event types that should trigger a dashboard repaint.
Streaming events (`message.delta', `tool.progress', …) are excluded
because they fire hundreds of times per turn and the dashboard does
not display any data that changes on a per-delta basis.")

(defun hermes-dashboard--refresh-if-open (&optional type &rest _ignore)
  "Hook entry: repaint the dashboard buffer if it exists.
When called from `hermes-rpc-event-functions' TYPE is the event name;
streaming events are filtered out.  When called from
`hermes-rpc-connection-functions' or interactively TYPE is a symbol or
nil and we always refresh."
  (when (or (null type)
            (symbolp type)                  ; connection-state hook
            (member type hermes-dashboard--refresh-events))
    (let ((buf (get-buffer hermes-dashboard-buffer-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (hermes-dashboard--refresh))))))

;;;; Mode

(defvar hermes-dashboard-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET") #'hermes-dashboard-dwim)
    (define-key m (kbd "i")   #'hermes-dashboard-send)
    (define-key m (kbd "c")   #'hermes-dashboard-compose)
    (define-key m (kbd "n")   #'hermes-dashboard-new-session)
    (define-key m (kbd "s")   #'hermes-sessions)
    (define-key m (kbd "g")   #'hermes-dashboard--refresh-if-open)
    (define-key m (kbd "q")   #'quit-window)
    m)
  "Keymap for `hermes-dashboard-mode'.")

(define-derived-mode hermes-dashboard-mode special-mode "Hermes-Dash"
  "Landing dashboard for the Hermes agent."
  (setq truncate-lines t)
  (buffer-disable-undo))

;;;; Commands

(defun hermes-dashboard--primary-buffer ()
  "Return the buffer for the primary session, or nil."
  (let ((sid hermes-dashboard--primary-sid))
    (and sid (boundp 'hermes--session-buffers)
         (let ((b (gethash sid hermes--session-buffers)))
           (and (buffer-live-p b) b)))))

(defun hermes-dashboard-dwim ()
  "RET: switch to session at point, else send prompt to primary session."
  (interactive)
  (let ((sid (get-text-property (point) 'hermes-dashboard-sid)))
    (if sid
        (let ((buf (gethash sid hermes--session-buffers)))
          (if (buffer-live-p buf)
              (pop-to-buffer-same-window buf)
            (user-error "Session buffer is gone — press g to refresh")))
      (hermes-dashboard-send))))

(defun hermes-dashboard-send ()
  "Pop the primary session buffer and call `hermes-input-send'."
  (interactive)
  (let ((buf (hermes-dashboard--primary-buffer)))
    (unless buf
      (user-error "No primary session yet — wait for `session ready'"))
    (pop-to-buffer buf)
    (call-interactively #'hermes-input-send)))

(defun hermes-dashboard-compose ()
  "Pop the primary session buffer and open the multi-line composer."
  (interactive)
  (let ((buf (hermes-dashboard--primary-buffer)))
    (unless buf
      (user-error "No primary session yet — wait for `session ready'"))
    (pop-to-buffer buf)
    (call-interactively (intern-soft "hermes-compose"))))

(defun hermes-dashboard-interrupt ()
  "Interrupt the primary session from anywhere."
  (interactive)
  (let ((buf (hermes-dashboard--primary-buffer)))
    (unless buf
      (user-error "No primary session yet — wait for `session ready'"))
    (with-current-buffer buf
      (call-interactively #'hermes-interrupt))))

(defun hermes-dashboard-new-session ()
  "Create another Hermes session and make it the primary."
  (interactive)
  (call-interactively #'hermes))

;;;; Entry / hook installation

(defun hermes-dashboard--note-session (sid)
  "Mark SID as the dashboard's primary session and refresh."
  (setq hermes-dashboard--primary-sid sid)
  (hermes-dashboard--refresh-if-open))

(defun hermes-dashboard-show ()
  "Pop up the dashboard buffer in the current window."
  (interactive)
  (let ((buf (get-buffer-create hermes-dashboard-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'hermes-dashboard-mode)
        (hermes-dashboard-mode))
      (hermes-dashboard--refresh))
    (pop-to-buffer-same-window buf)))

(provide 'hermes-dashboard)
;;; hermes-dashboard.el ends here
