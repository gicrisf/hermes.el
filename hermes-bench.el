;;; hermes-bench.el --- Persistent bottom bench for hermes-mode -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The bench is a bottom side-window paired with a `hermes-mode' buffer.
;; It is the user's interactive surface: ephemeral assistant content
;; above (user prompt, reasoning, answer), separator, editable input
;; area below.  The parent Org buffer remains the canonical history.
;;
;; Rendering model (plan v3): one persistent marker, `input-boundary'.
;; Everything above it is rebuilt from scratch on every paint via
;; `hermes-bench--paint-ephemeral'.  No zone markers, no diffing.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hermes-state)
(require 'hermes-tool-formatters)

(declare-function hermes-send "hermes-input" (text))
(declare-function hermes-input--slash-complete "hermes-input" (beg end catalog))
(declare-function hermes-state-slash-catalog "hermes-state" (state))
(declare-function hermes-interrupt-current-session "hermes-mode" ())
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes-image-attach-file "hermes-image" (&optional file))
(declare-function hermes-image-clipboard-paste "hermes-image" ())
(declare-function hermes-state-attachments "hermes-state" (state))
(declare-function hermes--insert-committed-turn "hermes-render" (msg))
(declare-function hermes--message-from-stream "hermes-state" (stream usage))

(defcustom hermes-bench-height 20
  "Height in lines of the bench side-window."
  :type 'integer :group 'hermes)

(defcustom hermes-bench-prompt "> "
  "Prompt string shown at the start of the bench input area."
  :type 'string :group 'hermes)

(defcustom hermes-bench-banner-type 'ascii
  "Which built-in banner to show when the gateway provides none.
`ascii'  — NOUS HERMES ASCII art
`unicode' — N O U S  R E S E A R C H  Unicode block art"
  :type '(choice (const :tag "ASCII NOUS HERMES" ascii)
                 (const :tag "Unicode block art" unicode))
  :group 'hermes)

(defcustom hermes-bench-separator "------"
  "Separator line between ephemeral zones and the input area."
  :type 'string :group 'hermes)

(defcustom hermes-bench-background-color nil
  "Explicit background color for the bench buffer.
When nil, the bench falls back to the gateway skin color
(`ui_bench'), or to `hermes-bench-buffer-face' as a last resort."
  :type '(choice (const :tag "Use skin / theme default" nil)
                 (color :tag "Custom color"))
  :group 'hermes)

(defvar hermes--last-gateway-ready)
(declare-function hermes-state-stream "hermes-state" (state))
(declare-function hermes-state-session-id "hermes-state" (state))
(declare-function hermes-state-session-info "hermes-state" (state))

(defconst hermes-bench--builtin-logo
  "\
██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗
██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝
███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗
██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║
██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║
╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝"
  "Fallback NOUS HERMES ASCII splash banner.")

(defconst hermes-bench--unicode-logo
  "\
⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣀⡠⠴⠶⠶⠶⣿⣿⣷⣶⣶⣤⣄⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⣤⣶⣿⣿⣿⣿⣿⣿⣶⣤⡀⠉⠻⣿⣿⣿⣿⣿⣷⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢀⣤⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣦⡀⠈⢻⣿⣿⣿⣿⣿⣿⣦⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠀⢀⣴⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⢿⠋⢀⣾⡷⡄⠀⢹⣿⡿⣿⡿⠋⢡⣷⡀⠀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⢀⡞⠉⠉⡻⣟⣽⣉⣻⣽⣦⣤⣯⣉⣀⣈⣿⣿⣿⣿⣷⠀⠀⢻⣷⣿⣿⣿⣿⣿⣷⡀⠀⠀⠀⠀⠀⠀⠀
⠀⠀⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣷⣶⣾⣿⣿⣿⣿⣿⣿⣿⣷⠀⠀⠀⠀⠀⠀⠀
⠀⠀⢠⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⠀⠀⠀⠀⠀⠀
⠀⠀⠘⣿⣿⣿⣿⣿⣿⣿⡿⣿⣿⣿⠷⠿⣿⣿⣿⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⠀⠀⠀⠀⠀⠀
⠀⠀⠀⠹⣿⣿⣿⣿⣛⣧⠀⠀⠉⡾⣿⣿⡷⣦⡄⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡆⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠈⠙⠋⣿⣟⣿⠃⠀⠀⠐⠾⠿⠗⠋⠀⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠀⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⠀⣿⣏⠁⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢰⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡄⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢀⣿⡇⣵⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⣼⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣧⠀⠀⠀⠀
⠀⠀⠀⠀⠀⠀⢸⣿⣷⡹⣟⠳⠖⠀⠀⠀⠀⠀⠀⠀⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡆⠀⠀⠀
⠀⠀⡤⠀⠀⠀⣸⣿⣿⣷⡁⠀⠀⠀⠀⠀⠀⠀⠀⢸⣿⣿⣿⡏⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡟⣿⣷⠀⠀⠀
⠀⢸⡇⠀⠀⢀⣿⣿⣿⣿⣷⣤⣀⣠⣤⣤⣤⡀⠀⢸⣿⣿⣿⡿⢿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡇⣿⣿⡆⣦⠀
⠀⣾⣿⣶⣶⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣄⣼⣿⣿⣿⣤⣴⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣰⣿⣿⡇⣼⡇
⠀⠹⣿⣟⣿⣛⣩⣾⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⡿⠋⠻⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⣿⢡⣿⡇
⠀⠀⠈⠛⠿⣿⠿⠿⣫⣿⣿⣿⣿⣿⣿⣿⣿⡅⠀⠀⠀⠈⣹⣿⣿⣿⣿⣿⣿⠿⢿⣿⣿⣿⣿⣿⣿⣿⣣⣿⠟⠀
⠀⠀⠀⠀⠀⠙⢿⣿⣿⠿⣿⣿⣿⣿⣿⣿⣿⣿⣦⣴⡶⠟⡫⢉⣵⡿⠋⠀⠀⠀⠀⠀⠙⠳⣽⣿⣿⡿⠟⠁⠀⠀
⣀⣀⣀⣀⣀⣀⣀⣀⣀⣴⣿⣿⣿⣿⣿⣿⣿⣿⣋⣉⣠⣾⣱⣿⣋⣀⣀⣀⣀⣀⣀⣀⣀⣀⣙⣿⣇⣀⣀⣀⣀⣀
⠀⠀⠀⠀⠀⠀⠀◎ N O U S  R E S E A R C H ◎⠀⠀⠀⠀⠀⠀⠀"
  "Fallback Unicode splash banner.")

(defface hermes-bench-logo-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the bench splash banner."
  :group 'hermes)

(defface hermes-bench-splash-status-face
  '((t :inherit shadow))
  "Face for the bench splash status line."
  :group 'hermes)

(defface hermes-bench-prompt-face
  '((t :inherit minibuffer-prompt))
  "Face for the bench input prompt."
  :group 'hermes)

(defface hermes-bench-separator-face
  '((t :inherit shadow))
  "Face for the bench separator line."
  :group 'hermes)

(defface hermes-bench-user-face
  '((t :inherit hermes-user-face))
  "Face for the user prompt in the bench."
  :group 'hermes)

(defface hermes-bench-reasoning-heading-face
  '((t :inherit org-level-3))
  "Face for the `*** Reasoning' heading in the bench."
  :group 'hermes)

(defface hermes-bench-reasoning-face
  '((t :inherit italic :foreground "gray60"))
  "Face for reasoning text in the bench."
  :group 'hermes)

(defface hermes-bench-steer-face
  '((t :inherit warning :weight bold))
  "Face for `[steer]' messages shown above the reasoning zone."
  :group 'hermes)

(defface hermes-bench-buffer-face
  '((((class color) (background dark))
     :background "#1c1f26" :extend t)
    (((class color) (background light))
     :background "#f4f4f4" :extend t)
    (t :inherit default))
  "Background face applied to the entire bench buffer window."
  :group 'hermes)

(defface hermes-bench-hl-line-face
  '((((class color) (background dark))
     :background "#2a2e38" :extend t)
    (((class color) (background light))
     :background "#e0e0e0" :extend t)
    (t :inherit hl-line))
  "Face for `hl-line-mode' in the bench buffer.
Kept separate from `hl-line' so users and skins can override it
without affecting the rest of Emacs."
  :group 'hermes)

;;;; Buffer-local state (bench buffer)

(defvar-local hermes-bench--session-id nil
  "Session-id this bench is bound to.
The bench reads its persistent state directly from `hermes--sessions'
keyed by this id, and is registered in `hermes--bench-buffers'.")

(defvar-local hermes-bench--input-boundary nil
  "Marker at the start of the separator line.
Everything above is ephemeral; everything below (separator + prompt +
user input) is the input frame.")

(defvar-local hermes-bench--current-user-prompt nil
  "Last user prompt painted into the bench (preserved across rebuilds).")

(defvar-local hermes-bench--bg-cookie nil
  "`face-remap-add-relative' cookie for the bench background.
Removed and recreated when the skin changes.")

(defvar-local hermes-bench--steer-messages nil
  "List of `[steer]' messages (oldest-first) shown above the reasoning zone.
Cleared by `hermes-bench--stream-commit' when the turn ends.")

(defvar-local hermes-bench--status-message nil
  "Transient status plist (:text :error-p) rendered above the separator.
Cleared after one paint cycle.")

(defface hermes-bench-attachment-face
  '((t :inherit shadow))
  "Face for the per-attachment metadata line in the bench."
  :group 'hermes)

;;;; Mode

(defvar hermes-bench-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")     #'hermes-bench-send)
    (define-key m (kbd "C-c C-c") #'hermes-bench-send)
    (define-key m (kbd "C-c C-k") #'hermes-bench-interrupt-parent)
    (define-key m (kbd "C-c C-l") #'hermes-bench-compose)
    (define-key m (kbd "C-c C-s") #'hermes-bench-steer)
    (define-key m (kbd "C-c C-a") #'hermes-image-attach-file)
    (define-key m (kbd "C-c C-v") #'hermes-image-clipboard-paste)
    (define-key m (kbd "C-c C-b") #'hermes-bench-bg-list)
    m)
  "Keymap for `hermes-bench-mode'.")

(with-eval-after-load 'which-key
  (when (fboundp 'which-key-add-keymap-based-replacements)
    (which-key-add-keymap-based-replacements hermes-bench-mode-map
      "C-c C-c" "Send prompt"
      "C-c C-k" "Interrupt session"
      "C-c C-l" "Compose multi-line"
      "C-c C-s" "Steer mid-turn"
      "C-c C-a" "Attach image file"
      "C-c C-v" "Paste from clipboard")))

;; `define-derived-mode' bodies run BEFORE `after-change-major-mode-hook',
;; which is where `global-display-line-numbers-mode' enables itself in
;; new buffers — so disabling it in the body is overwritten.  Two
;; defences: exempt the mode (Emacs 28+ supports
;; `display-line-numbers-exempt-modes') and override via the mode hook,
;; which runs AFTER the global mode has had its turn.
(with-eval-after-load 'display-line-numbers
  (when (boundp 'display-line-numbers-exempt-modes)
    (add-to-list 'display-line-numbers-exempt-modes 'hermes-bench-mode)))

(defun hermes-bench--disable-line-numbers ()
  "Force `display-line-numbers-mode' off in the current bench buffer."
  (display-line-numbers-mode -1))

(defun hermes-bench--state ()
  "Return the persistent state for this bench's session, or nil."
  (and hermes-bench--session-id
       (gethash hermes-bench--session-id hermes--sessions)))

(defun hermes-bench-completion-at-point ()
  "Slash-command CAPF for the bench input area.
The slash must appear immediately after the bench prompt (i.e. at
`hermes-bench--input-start').  Pulls the catalog from the session
state in `hermes--sessions' and delegates to `hermes-input--slash-complete'."
  (when (and hermes-bench--session-id
             (hermes-bench--in-input-area-p))
    (let ((input-start (hermes-bench--input-start)))
      (when (and input-start
                 (> (point) input-start)
                 (eq (char-after input-start) ?/))
        (let* ((state (hermes-bench--state))
               (catalog (and state (hermes-state-slash-catalog state))))
          (when catalog
            (hermes-input--slash-complete input-start (point) catalog)))))))

(define-derived-mode hermes-bench-mode text-mode "Hermes-Bench"
  "Major mode for the Hermes bottom bench panel."
  (setq truncate-lines nil)
  (visual-line-mode 1)
  (hl-line-mode 1)
  (setq-local hl-line-face 'hermes-bench-hl-line-face)
  (setq-local cursor-type 'bar)
  (add-hook 'pre-command-hook #'hermes-bench--ensure-input-point nil t)
  (add-hook 'completion-at-point-functions
            #'hermes-bench-completion-at-point nil t))

(add-hook 'hermes-bench-mode-hook #'hermes-bench--disable-line-numbers)

;;;; Lifecycle

(defun hermes-bench--buffer-name (sid)
  (format "*hermes-bench:%s*" sid))

(defun hermes-bench--effective-bg (skin)
  "Return the background color string to use for the bench buffer.
Respects `hermes-bench-background-color'; when that is nil, uses
SKIN.colors.ui_bench if present, otherwise the default from
`hermes-bench-buffer-face'."
  (or hermes-bench-background-color
      (and (hash-table-p skin)
           (let ((colors (gethash "colors" skin)))
             (and (hash-table-p colors) (gethash "ui_bench" colors))))
      (face-background 'hermes-bench-buffer-face nil 'default)))

(defun hermes-bench--refresh-bg-all (skin)
  "Refresh the bench background of every live bench buffer from SKIN.
Subscribed to `hermes-skin-applied-hook'."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (buffer-local-value 'hermes-bench--bg-cookie buf))
      (with-current-buffer buf
        (hermes-bench--apply-bg skin)))))

(with-eval-after-load 'hermes-skin
  (add-hook 'hermes-skin-applied-hook #'hermes-bench--refresh-bg-all))

(defun hermes-bench--apply-bg (&optional skin)
  "Refresh the bench buffer's background remap from SKIN.
If SKIN is nil, falls back to `hermes--last-gateway-ready'.  Removes
the previous cookie first so the effect is idempotent."
  (let ((bg (hermes-bench--effective-bg
             (or skin (and (boundp 'hermes--last-gateway-ready)
                           hermes--last-gateway-ready)))))
    (when hermes-bench--bg-cookie
      (face-remap-remove-relative hermes-bench--bg-cookie)
      (setq hermes-bench--bg-cookie nil))
    (when bg
      (setq hermes-bench--bg-cookie
            (face-remap-add-relative 'default :background bg)))))

(defun hermes-bench-buffer-p (&optional buffer)
  "Return non-nil if BUFFER (or current buffer) is a bench buffer."
  (let ((buf (or buffer (current-buffer))))
    (and (buffer-live-p buf)
         (eq (buffer-local-value 'major-mode buf) 'hermes-bench-mode))))

(defun hermes-bench-active-p (&optional buffer-or-sid)
  "Return the live bench buffer for BUFFER-OR-SID, or nil.
BUFFER-OR-SID can be: a session-id string, a viewer buffer (any kind),
or nil (= current buffer).  In every case the session-id is resolved
and looked up in `hermes--bench-buffers'."
  (let ((sid (cond
              ((stringp buffer-or-sid) buffer-or-sid)
              ((bufferp buffer-or-sid) (hermes--buffer-sid buffer-or-sid))
              (t (hermes--buffer-sid (current-buffer))))))
    (and sid
         (let ((buf (gethash sid hermes--bench-buffers)))
           (and (buffer-live-p buf) buf)))))

(defalias 'hermes-bench-live-p #'hermes-bench-active-p
  "Return the live bench buffer associated with BUFFER, or nil.
Alias for `hermes-bench-active-p'.")

(defun hermes-bench--setup (sid)
  "Initialize the bench buffer contents for session SID."
  (hermes-bench-mode)
  (hermes-bench--apply-bg)
  (setq hermes-bench--session-id sid
        hermes-bench--current-user-prompt nil)
  ;; Buffer-local hint so resolvers (`hermes--resolve-session-target',
  ;; `hermes--current-state', `hermes-send' fallback path) can find the
  ;; session without walking registries.
  (setq-local hermes--current-session-id sid)
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; Seed `input-boundary' at point-min so the first paint has a
    ;; valid marker to delete up to.
    (setq hermes-bench--input-boundary (copy-marker (point-min) nil))
    (hermes-bench--paint-ephemeral))
  (setq-local header-line-format nil)
  (goto-char (point-max)))

(defun hermes-bench--align-org-to-tail ()
  "Pull org-viewer windows of this bench's session to `point-max'.
No-ops when the session has no org viewer (section-mode only).
Pre-aligns the org buffer so the post-commit follow logic in
`hermes--render' captures the window as tail-tracking."
  (when hermes-bench--session-id
    (let ((buf (gethash hermes-bench--session-id hermes--org-buffers)))
      (when (buffer-live-p buf)
        (let ((end (with-current-buffer buf (point-max))))
          (dolist (win (get-buffer-window-list buf nil t))
            (when (and (window-live-p win)
                       (/= (window-point win) end))
              (set-window-point win end))))))))

(defun hermes-bench-ensure (sid)
  "Ensure a bench buffer exists and is displayed for session SID."
  (let* ((name (hermes-bench--buffer-name sid))
         (existing (gethash sid hermes--bench-buffers))
         (buf (or (and (buffer-live-p existing) existing)
                  (get-buffer-create name))))
    (puthash sid buf hermes--bench-buffers)
    (with-current-buffer buf
      (unless (and (derived-mode-p 'hermes-bench-mode)
                   (equal hermes-bench--session-id sid))
        (hermes-bench--setup sid)))
    (display-buffer-in-side-window
     buf `((side . bottom)
           (slot . 0)
           (window-height . ,hermes-bench-height)
           (dedicated . t)
           (preserve-size . (nil . t))
           (window-parameters . ((no-other-window . nil)
                                 (no-delete-other-windows . t)))))
    (with-current-buffer buf
      (hermes-bench--align-org-to-tail))
    buf))

(defun hermes-bench-hide (sid)
  "Delete the bench window for SID and kill the bench buffer."
  (let ((buf (gethash sid hermes--bench-buffers)))
    (when (buffer-live-p buf)
      (dolist (w (get-buffer-window-list buf nil t))
        (when (window-live-p w) (delete-window w)))
      (kill-buffer buf))
    (remhash sid hermes--bench-buffers)))

;;;; Input area

(defun hermes-bench--input-start ()
  "Return the buffer position where editable input begins, or nil.
Returns nil when the input frame hasn't been built yet."
  (when (and (markerp hermes-bench--input-boundary)
             (marker-position hermes-bench--input-boundary))
    (save-excursion
      (goto-char (marker-position hermes-bench--input-boundary))
      ;; Past the separator line.
      (when (zerop (forward-line 1))
        ;; Past the prompt string, clamped to point-max.
        (min (point-max) (+ (point) (length hermes-bench-prompt)))))))

(defun hermes-bench--in-input-area-p ()
  "Return non-nil if point is in the editable input area."
  (let ((start (hermes-bench--input-start)))
    (and start (>= (point) start))))

(defconst hermes-bench--motion-commands
  '(nil
    ;; Vanilla navigation
    forward-char backward-char
    next-line previous-line
    beginning-of-line end-of-line
    beginning-of-buffer end-of-buffer
    scroll-up scroll-down
    scroll-up-command scroll-down-command
    goto-char mouse-set-point mouse-goto-line
    ;; Copy / kill ring (read-only zone is safe for these)
    kill-ring-save clipboard-kill-ring-save
    mouse-save-then-kill
    ;; Search / isearch
    isearch-forward isearch-backward
    isearch-forward-regexp isearch-backward-regexp
    isearch-repeat-forward isearch-repeat-backward
    ;; Mark / region
    set-mark-command mark-page exchange-point-and-mark
    ;; Evil normal-state motion commands
    evil-forward-char evil-backward-char
    evil-next-line evil-previous-line
    evil-beginning-of-line evil-end-of-line
    evil-goto-first-line evil-goto-line
    evil-scroll-page-down evil-scroll-page-up
    evil-scroll-line-down evil-scroll-line-up
    evil-goto-mark evil-set-marker
    evil-jump-forward evil-jump-backward
    evil-search-next evil-search-previous
    evil-ex-search-next evil-ex-search-previous
    evil-find-char evil-find-char-backward
    evil-find-char-to evil-find-char-to-backward
    evil-repeat-find-char evil-repeat-find-char-reverse
    evil-goto-percentage
    evil-window-top evil-window-middle evil-window-bottom
    ;; Evil visual mode (selection without modification)
    evil-visual-char evil-visual-line evil-visual-block
    evil-exit-visual-state
    ;; Evil misc safe commands
    evil-escape)
  "Commands that move or inspect text without modifying it.
These are allowed to run outside the input area.
All other commands trigger an auto-jump to `hermes-bench--input-start'.")

(defun hermes-bench--ensure-input-point ()
  "If point is outside the input area, move it to the input start.
Does nothing if the current command is a motion command."
  (when (and hermes-bench--input-boundary
             (not (hermes-bench--in-input-area-p))
             (not (memq this-command hermes-bench--motion-commands)))
    (let ((start (hermes-bench--input-start)))
      (when start
        (goto-char start)))))

(defun hermes-bench--input-text ()
  "Return the input-area text verbatim (no trim)."
  (let ((start (hermes-bench--input-start)))
    (if (and start (<= start (point-max)))
        (buffer-substring-no-properties start (point-max))
      "")))

(defun hermes-bench--clear-input ()
  "Erase user-typed text after the prompt."
  (let ((start (hermes-bench--input-start))
        (inhibit-read-only t))
    (when (and start (< start (point-max)))
      (delete-region start (point-max)))))

;;;; Splash

(defun hermes-bench--short-sid (sid)
  (if (and (stringp sid) (> (length sid) 8)) (substring sid 0 8) (or sid "?")))

(defun hermes-bench--strip-rich (string)
  "Drop Rich `[style]…[/]' tags from STRING."
  (replace-regexp-in-string "\\[/?[^]]*\\]" "" string))

(defun hermes-bench--splash-logo ()
  "Return the splash banner: gateway-provided when available, else builtin."
  (let* ((skin (and (boundp 'hermes--last-gateway-ready)
                    hermes--last-gateway-ready))
         (h (and (hash-table-p skin) (gethash "skin" skin)))
         (src (or h skin))
         (banner (and (hash-table-p src)
                      (or (gethash "banner_hero" src)
                          (gethash "banner_logo" src)))))
    (hermes-bench--strip-rich
     (if (and (stringp banner) (not (string-empty-p banner)))
         banner
       (pcase hermes-bench-banner-type
         ('unicode hermes-bench--unicode-logo)
         (_        hermes-bench--builtin-logo))))))

(defun hermes-bench--insert-splash ()
  "Insert the splash banner at point."
  (let ((logo (hermes-bench--splash-logo)))
    (insert "\n\n")
    (let ((start (point)))
      (insert logo)
      (add-face-text-property start (point) 'hermes-bench-logo-face)
      (insert "\n\n"))))

(defun hermes-bench--should-show-splash-p ()
  "Return non-nil when the bench has no conversation content to display."
  (let ((state (hermes-bench--state)))
    (and (or (null hermes-bench--current-user-prompt)
             (string-empty-p hermes-bench--current-user-prompt))
         (not (and state (hermes-state-stream state))))))

;;;; Attachment helpers

(defun hermes-bench--attachments ()
  "Return the attachments list from the bench's session state, or nil."
  (let ((state (hermes-bench--state)))
    (and state (hermes-state-attachments state))))

(defun hermes-bench--format-attachment (a)
  "Return a one-line summary for attachment plist A.
Statuses render as: pending → trailing ellipsis; attached → dims and
token estimate; error → error marker."
  (let* ((name (or (plist-get a :name) "?"))
         (status (or (plist-get a :status) 'pending))
         (w (plist-get a :width))
         (h (plist-get a :height))
         (tok (plist-get a :token-estimate)))
    (pcase status
      ('pending  (format "[img] %s ..." name))
      ('error    (format "[img] %s [failed]" name))
      (_
       (let ((parts (list name)))
         (when (and w h) (push (format "%dx%d" w h) parts))
         (when tok (push (format "~%s tok" tok) parts))
         (concat "[img] " (string-join (nreverse parts) " | ")))))))

(defun hermes-bench--repaint-preserving-stream ()
  "Repaint the bench, preserving any in-flight stream content.
Used by `hermes-image' callbacks to refresh the attachment line(s)."
  (let* ((state  (hermes-bench--state))
         (stream (and state (hermes-state-stream state))))
    (if (hermes-stream-p stream)
        (pcase-let ((`(,reasoning . ,answer)
                     (hermes-bench--segments-by-zone
                      (hermes-stream-segments stream))))
          (hermes-bench--paint-ephemeral nil reasoning answer))
      (hermes-bench--paint-ephemeral nil nil nil))))

;;;; Background-task status zone

(declare-function hermes-tool--truncate "hermes-tool-formatters" (s n))
(declare-function hermes-bg--list-for-sid "hermes-bg" (sid))

(defun hermes-bench--insert-bg-status ()
  "Insert a one-line summary of background tasks into the bench.
Shows `[bg: N running]' while any task is running, otherwise
`[bg #ID complete] PROMPT' for the most recently completed task.
No-op when the session has no background tasks."
  (let* ((state (hermes-bench--state))
         (bg-tasks (and state (hermes-state-bg-tasks state)))
         (running 0))
    (when (and (vectorp bg-tasks) (> (length bg-tasks) 0))
      (dotimes (i (length bg-tasks))
        (when (eq 'running (hermes-bg-task-status (aref bg-tasks i)))
          (cl-incf running)))
      (cond
       ((> running 0)
        (insert (propertize (format "[bg: %d running]\n" running)
                            'face 'hermes-bench-steer-face)))
       (t
        ;; Walk backward to find the most recently completed task.
        (let* ((n (length bg-tasks))
               (last
                (catch 'found
                  (dotimes (i n)
                    (let ((bt (aref bg-tasks (- n 1 i))))
                      (when (memq (hermes-bg-task-status bt) '(complete error))
                        (throw 'found bt)))))))
          (when last
            (insert
             (propertize
              (format "[bg #%s %s] %s → C-c C-b to view\n"
                      (hermes-bg-task-task-id last)
                      (symbol-name (hermes-bg-task-status last))
                      (hermes-tool--truncate
                       (or (hermes-bg-task-prompt last) "") 40))
              'face 'hermes-bench-steer-face)))))))))

(defun hermes-bench-bg-list ()
  "Pop the background-task list for this bench's session."
  (interactive)
  (let ((sid hermes-bench--session-id))
    (if sid
        (progn (require 'hermes-bg)
               (hermes-bg--list-for-sid sid))
      (message "hermes: no active session"))))

;;;; The single renderer

(defun hermes-bench--paint-ephemeral (&optional user-text reasoning answer)
  "Rebuild the ephemeral area above the separator.
USER-TEXT, when non-nil, replaces the stored user prompt (a nil value
preserves it).  REASONING and ANSWER are inserted verbatim into their
zones; nil/empty leaves the zone empty.  The user's draft input text
(below the prompt) is preserved across the rebuild."
  (when user-text
    (setq hermes-bench--current-user-prompt user-text))
  (let* ((inhibit-read-only t)
         (effective-user (or hermes-bench--current-user-prompt ""))
         (saved-input (hermes-bench--input-text))
         ;; Where (relative to start-of-input) was point sitting?
         (saved-point-offset
          (let ((istart (hermes-bench--input-start)))
            (if (and istart (>= (point) istart))
                (- (point) istart)
              nil))))
    ;; 1. Wipe everything from point-min through the old input frame.
    (delete-region (point-min) (point-max))
    (goto-char (point-min))
    ;; 2. Splash, or normal ephemeral zones.
    (if (and (string-empty-p effective-user)
             (null (hermes-bench--attachments))
             (hermes-bench--should-show-splash-p))
        (hermes-bench--insert-splash)
      (unless (string-empty-p effective-user)
        (insert (propertize (concat "** U: " effective-user "\n\n")
                            'face 'hermes-bench-user-face)))
      ;; Pending image/clipboard attachments — one metadata line each.
      ;; Shown above any reasoning/answer so the user can see what will be
      ;; sent with the next prompt.  No inline thumbnails (bench is 20
      ;; lines tall; thumbnails would blow the layout).
      (let ((atts (hermes-bench--attachments)))
        (when atts
          (dolist (a atts)
            (insert (propertize (hermes-bench--format-attachment a)
                                'face 'hermes-bench-attachment-face)
                    "\n"))
          (insert "\n")))
      ;; Steer messages — shown between user prompt and reasoning so the
      ;; user can see what was injected into the running turn.
      (when hermes-bench--steer-messages
        (dolist (steer hermes-bench--steer-messages)
          (insert (propertize (concat "[steer] " steer "\n")
                              'face 'hermes-bench-steer-face)))
        (insert "\n"))
      ;; Reasoning zone — trim model-supplied trailing whitespace so we
      ;; control the exact spacing between zones (otherwise stray "\n\n"
      ;; in the stream stacks with the separator newlines below).
      (let ((trimmed (and reasoning (string-trim-right reasoning))))
        (when (and trimmed (not (string-empty-p trimmed)))
          (insert (propertize trimmed 'face 'hermes-bench-reasoning-face))
          (insert "\n\n")))
      ;; Answer zone.
      (let ((trimmed (and answer (string-trim-right answer))))
        (when (and trimmed (not (string-empty-p trimmed)))
          (insert trimmed)
          (insert "\n")))
      ;; Transient status message (skills command feedback, etc.).
      (when hermes-bench--status-message
        (let ((text (plist-get hermes-bench--status-message :text))
              (err (plist-get hermes-bench--status-message :error-p)))
          (insert (propertize text
                              'face (if err 'error 'hermes-bench-user-face))
                  "\n"))
        (setq hermes-bench--status-message nil))
      ;; Background task status — counts and most-recent-complete pointer.
      (hermes-bench--insert-bg-status))
    ;; 3. Separator + prompt — input frame.
    (setq hermes-bench--input-boundary (copy-marker (point) nil))
    (insert (propertize (concat hermes-bench-separator "\n")
                        'face 'hermes-bench-separator-face
                        'read-only t
                        'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (insert (propertize hermes-bench-prompt
                        'face 'hermes-bench-prompt-face
                        'read-only t
                        'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (put-text-property (point-min) (point) 'read-only t)
    (put-text-property (point-min) (1+ (point-min)) 'front-sticky '(read-only))
    ;; 4. Restore input text + point.
    (unless (string-empty-p saved-input)
      (insert saved-input))
    (let ((istart (hermes-bench--input-start)))
      (goto-char (if saved-point-offset
                     (min (point-max) (+ istart saved-point-offset))
                   (point-max)))))
  (hermes-bench--ensure-visible-end))

(defun hermes-bench--ensure-visible-end ()
  "Keep bench windows showing the bottom (input area)."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (with-selected-window w
        (goto-char (point-max))
        (recenter -1)))))

;;;; Segment partitioning

(defun hermes-bench--segments-by-zone (segments)
  "Return (REASONING-TEXT . ANSWER-TEXT) from SEGMENTS (a vector)."
  (let (rparts aparts)
    (when (vectorp segments)
      (dotimes (i (length segments))
        (let* ((s (aref segments i))
               (type (hermes-segment-type s))
               (content (hermes-segment-content s)))
          (pcase type
            ('reasoning
             (when (and (stringp content) (not (string-empty-p content)))
               (push content rparts)))
            ('text
             (when (stringp content) (push content aparts)))
            ('tool
             (let* ((tool content)
                    (name (and (hermes-tool-p tool) (hermes-tool-name tool)))
                    (status (and (hermes-tool-p tool) (hermes-tool-status tool)))
                    (formatter (and name (hermes-tool--lookup name)))
                    (parts (and formatter (funcall formatter tool)))
                    (summary (or (plist-get parts :summary) name "tool"))
                    (one (replace-regexp-in-string
                          "[ \t\n]+" " " (format "%s" summary))))
               (push (format "[tool: %s] %s %s"
                             (or name "?") (or status "?") one)
                     aparts)))
            ('system
             (when (stringp content)
               (push (format "[system] %s" content) aparts)))
            ('thinking nil)
            (_ nil)))))
    (cons (string-join (nreverse rparts) "")
          (string-join (nreverse aparts) ""))))

;;;; Latest user prompt discovery (fallback for out-of-bench submissions)

(defun hermes-bench--latest-user-text (&optional state)
  "Return the most-recent user prompt text from STATE, or nil.
STATE defaults to the bench's session state.  Looks at pending-turns
first, then walks the session's history ring."
  (let* ((state (or state (hermes-bench--state)))
         (turns (and state (hermes-state-pending-turns state))))
      (or (and (vectorp turns)
               (let ((i (1- (length turns))) found)
                 (while (and (not found) (>= i 0))
                   (let ((m (aref turns i)))
                     (when (eq 'user (hermes-message-kind m))
                       (let ((segs (hermes-message-segments m)))
                         (when (and (vectorp segs) (> (length segs) 0))
                           (let ((s (aref segs 0)))
                             (when (eq 'text (hermes-segment-type s))
                               (setq found (hermes-segment-content s))))))))
                   (cl-decf i))
                 found))
          (and state
               (let ((hist (hermes-state-history state)))
                 (and (consp hist) (car hist)))))))

;;;; Stream lifecycle (called from hermes--render)

(defun hermes-bench--stream-begin (bench)
  "Stream started: ensure user prompt is set, clear reasoning/answer."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      (let ((user (or hermes-bench--current-user-prompt
                      (hermes-bench--latest-user-text)
                      "")))
        (hermes-bench--paint-ephemeral user "" "")))))

(defun hermes-bench--stream-update (bench _old new)
  "Repaint reasoning and answer zones from NEW stream."
  (when (and (buffer-live-p bench) (hermes-stream-p new))
    (with-current-buffer bench
      (pcase-let ((`(,reasoning . ,answer)
                   (hermes-bench--segments-by-zone
                    (hermes-stream-segments new))))
        (hermes-bench--paint-ephemeral nil reasoning answer)))))

(defun hermes-bench--stream-commit (bench old-stream)
  "Stream ended: commit OLD-STREAM into the session's org buffer.
The bench is NOT cleared; the answer remains until the next
`hermes-bench-send'."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      ;; Steer messages were valid for the now-ending turn only.
      (setq hermes-bench--steer-messages nil))
    (let* ((sid (buffer-local-value 'hermes-bench--session-id bench))
           (org-buf (and sid (gethash sid hermes--org-buffers))))
      (when (and (buffer-live-p org-buf)
                 (hermes-stream-p old-stream))
        (with-current-buffer org-buf
          (let* ((state (gethash sid hermes--sessions))
                 (usage (and state (hermes-state-usage state)))
                 (msg (hermes--message-from-stream old-stream usage)))
            (with-silent-modifications
              (save-excursion
                (hermes--insert-committed-turn msg)))))))))

(defun hermes-bench-add-steer (sid text)
  "Append TEXT as a `[steer]' message to the bench for session SID.
No-op if SID has no live bench.  Repaints so the message is visible
above the reasoning zone immediately, preserving any in-flight stream
content."
  (let ((bench (hermes-bench-active-p sid)))
    (when (and bench (stringp text) (not (string-empty-p text)))
      (with-current-buffer bench
        (setq hermes-bench--steer-messages
              (append hermes-bench--steer-messages (list text)))
        (let* ((state  (hermes-bench--state))
               (stream (and state (hermes-state-stream state))))
          (if (hermes-stream-p stream)
              (pcase-let ((`(,reasoning . ,answer)
                           (hermes-bench--segments-by-zone
                            (hermes-stream-segments stream))))
                (hermes-bench--paint-ephemeral nil reasoning answer))
            (hermes-bench--paint-ephemeral nil nil nil)))))))

;;;; Send / interrupt / compose

(defun hermes-bench-send ()
  "Send the current input-area text to this bench's session.
Clears the bench ephemeral content first (showing the new user prompt),
then dispatches the text via `hermes-send'."
  (interactive)
  (let ((text (string-trim (hermes-bench--input-text)))
        (sid hermes-bench--session-id))
    (unless sid
      (user-error "Bench has no session"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    ;; 1+2. Clear input area first so it's not preserved by paint.
    (hermes-bench--clear-input)
    ;; 3. Wipe old turn, show new user prompt + empty reasoning/answer.
    (hermes-bench--paint-ephemeral text "" "")
    ;; 3a. Pull org-viewer windows to point-max so the post-commit
    ;; follow logic in `hermes--render' sees them as tail-tracking.
    (hermes-bench--align-org-to-tail)
    ;; 4. Dispatch via `hermes-send' bound to this session.
    (let ((hermes--current-session-id sid))
      (hermes-send text))
    (goto-char (point-max))))

(defun hermes-bench-interrupt-parent ()
  "Interrupt the bench's session."
  (interactive)
  (when hermes-bench--session-id
    (let ((hermes--current-session-id hermes-bench--session-id))
      (call-interactively #'hermes-interrupt-current-session))))

(declare-function hermes-steer "hermes-config" (text))

(defun hermes-bench-steer ()
  "Send the current input-area text as a `session.steer' message.
Clears the input area, shows `[steer] <text>' above the reasoning zone,
and dispatches the steer RPC against the bench's session."
  (interactive)
  (let ((text (string-trim (hermes-bench--input-text)))
        (sid hermes-bench--session-id))
    (unless sid
      (user-error "Bench has no session"))
    (when (string-empty-p text)
      (user-error "Nothing to steer"))
    (hermes-bench--clear-input)
    (let ((hermes--current-session-id sid))
      (hermes-steer text))))

(defun hermes-bench-compose ()
  "Open the multi-line composer targeting the bench's session."
  (interactive)
  (when hermes-bench--session-id
    (call-interactively #'hermes-compose)))

(defun hermes-bench-show-status (sid text &optional error-p)
  "Show TEXT as a transient status line in the bench for SID.
If ERROR-P is non-nil, apply `error' face.  The text is stored in
`hermes-bench--status-message' and rendered immediately."
  (let ((bench (hermes-bench-active-p sid)))
    (when bench
      (with-current-buffer bench
        (setq hermes-bench--status-message
              (list :text text :error-p error-p))
        ;; Trigger repaint so the status appears immediately.
        (let* ((state  (hermes-bench--state))
               (stream (and state (hermes-state-stream state))))
          (if (hermes-stream-p stream)
              (pcase-let ((`(,reasoning . ,answer)
                           (hermes-bench--segments-by-zone
                            (hermes-stream-segments stream))))
                (hermes-bench--paint-ephemeral nil reasoning answer))
            (hermes-bench--paint-ephemeral nil nil nil)))))))

(declare-function ansi-color-apply "ansi-color" (string))

(provide 'hermes-bench)
;;; hermes-bench.el ends here
