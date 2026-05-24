;;; hermes-bench.el --- Persistent bottom bench for hermes-mode -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The bench is a bottom side-window paired with a `hermes-mode' buffer.
;; It is the user's input surface: a status header (background tasks,
;; pending attachments), a separator, and an editable prompt line.
;;
;; All streaming content lives in the primary viewer (org or section);
;; the bench never renders the assistant's in-flight turn.  See plan 20.

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

(defcustom hermes-bench-height 20
  "Height in lines of the bench side-window."
  :type 'integer :group 'hermes)

(defcustom hermes-bench-prompt "> "
  "Prompt string shown at the start of the bench input area."
  :type 'string :group 'hermes)

(defcustom hermes-bench-separator "------"
  "Separator line between the status header and the input area."
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

(defface hermes-bench-prompt-face
  '((t :inherit minibuffer-prompt))
  "Face for the bench input prompt."
  :group 'hermes)

(defface hermes-bench-separator-face
  '((t :inherit shadow))
  "Face for the bench separator line."
  :group 'hermes)

(defface hermes-bench-status-face
  '((t :inherit warning :weight bold))
  "Face for bench status header lines (bg tasks, attachments)."
  :group 'hermes)

(defface hermes-bench-attachment-face
  '((t :inherit shadow))
  "Face for the per-attachment metadata line in the bench."
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
Set once by `hermes-bench--paint-frame' and never moves.  Everything
above the marker is the status header (rebuilt by
`hermes-bench--refresh-status'); the separator lives at the marker
position and survives across refreshes; everything below is the prompt
and editable user input.")

(defvar-local hermes-bench--bg-cookie nil
  "`face-remap-add-relative' cookie for the bench background.
Removed and recreated when the skin changes.")

;;;; Mode

(defvar hermes-bench-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")     #'hermes-bench-send)
    (define-key m (kbd "C-c C-c") #'hermes-bench-send)
    (define-key m (kbd "C-c C-k") #'hermes-bench-interrupt-parent)
    (define-key m (kbd "C-c C-l") #'hermes-bench-compose)
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

;; State-change subscription is GLOBAL (not buffer-local): dispatch fires
;; from whatever buffer triggered the RPC, not the bench.  The handler
;; uses `hermes--on-session-buffer' to route to the right bench.
(add-hook 'hermes-state-change-hook #'hermes-bench--on-state-change t)

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
  (setq hermes-bench--session-id sid)
  ;; Buffer-local hint so resolvers (`hermes--resolve-session-target',
  ;; `hermes--current-state', `hermes-send' fallback path) can find the
  ;; session without walking registries.
  (setq-local hermes--current-session-id sid)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (hermes-bench--paint-frame))
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

;;;; Status header

(declare-function hermes-tool--truncate "hermes-tool-formatters" (s n))
(declare-function hermes-bg--list-for-sid "hermes-bg" (sid))

(defun hermes-bench--insert-bg-status ()
  "Insert the status header at point: bg tasks (if any) + attachments (if any).
No-op when neither has content."
  (let* ((state (hermes-bench--state))
         (bg-tasks (and state (hermes-state-bg-tasks state)))
         (running 0))
    ;; Background task summary line.
    (when (and (vectorp bg-tasks) (> (length bg-tasks) 0))
      (dotimes (i (length bg-tasks))
        (when (eq 'running (hermes-bg-task-status (aref bg-tasks i)))
          (cl-incf running)))
      (cond
       ((> running 0)
        (insert (propertize (format "[bg: %d running]\n" running)
                            'face 'hermes-bench-status-face)))
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
              'face 'hermes-bench-status-face)))))))
    ;; Pending image/clipboard attachments — one line each.
    (let ((atts (hermes-bench--attachments)))
      (when atts
        (dolist (a atts)
          (insert (propertize (hermes-bench--format-attachment a)
                              'face 'hermes-bench-attachment-face)
                  "\n"))))))

(defun hermes-bench-bg-list ()
  "Pop the background-task list for this bench's session."
  (interactive)
  (let ((sid hermes-bench--session-id))
    (if sid
        (progn (require 'hermes-bg)
               (hermes-bg--list-for-sid sid))
      (message "hermes: no active session"))))

;;;; Frame renderer

(defun hermes-bench--paint-frame ()
  "Draw the static bench frame: status header + separator + input prompt.
Sets `hermes-bench--input-boundary' once at the start of the separator
line; `--input-start' / `--refresh-status' depend on that semantics.
Preserves any pre-existing input text and cursor position so callers
may invoke it from setup or from a full reset without losing the
user's draft."
  (let* ((inhibit-read-only t)
         (saved-input (hermes-bench--input-text))
         (saved-offset
          (let ((istart (hermes-bench--input-start)))
            (and istart (>= (point) istart) (- (point) istart)))))
    (delete-region (point-min) (point-max))
    (goto-char (point-min))
    (hermes-bench--insert-bg-status)
    ;; Boundary anchored at start of separator (option a from plan 20).
    (setq hermes-bench--input-boundary (copy-marker (point) nil))
    (insert (propertize (concat hermes-bench-separator "\n")
                        'face 'hermes-bench-separator-face
                        'read-only t 'rear-nonsticky '(read-only)))
    (insert (propertize hermes-bench-prompt
                        'face 'hermes-bench-prompt-face
                        'read-only t 'rear-nonsticky '(read-only)))
    (put-text-property (point-min) (point) 'read-only t)
    (unless (string-empty-p (or saved-input ""))
      (insert saved-input))
    (let ((istart (hermes-bench--input-start)))
      (goto-char (if (and saved-offset istart)
                     (min (point-max) (+ istart saved-offset))
                   (point-max))))
    (hermes-bench--ensure-visible-end)))

(defun hermes-bench--refresh-status ()
  "Rewrite the status header region, preserving input text and cursor.
Deletes `[point-min, boundary)' — the separator lives at the boundary
position and survives.  The input area below the boundary is also
preserved (untouched).  Cheap no-op when the bench hasn't been
initialised yet."
  (when (and hermes-bench--input-boundary
             (marker-position hermes-bench--input-boundary))
    (let* ((inhibit-read-only t)
           (boundary (marker-position hermes-bench--input-boundary))
           (saved-offset
            (let ((istart (hermes-bench--input-start)))
              (and istart (>= (point) istart) (- (point) istart)))))
      (save-excursion
        (delete-region (point-min) boundary)
        (goto-char (point-min))
        (hermes-bench--insert-bg-status)
        ;; Re-anchor boundary at the (new) start of separator.  After
        ;; the delete-region the marker collapsed to point-min, then
        ;; the bg-status insertion (insertion-type nil) pushed it to
        ;; the new separator start automatically.  Setting it
        ;; explicitly is defensive.
        (set-marker hermes-bench--input-boundary (point))
        (put-text-property (point-min) hermes-bench--input-boundary
                           'read-only t))
      (when saved-offset
        (let ((istart (hermes-bench--input-start)))
          (when istart
            (goto-char (min (point-max) (+ istart saved-offset)))))))))

(defun hermes-bench--on-state-change (_old _new)
  "`hermes-state-change-hook' callback: refresh the bench status header.
Routes to the bench buffer for the currently dispatched session via
`hermes--on-session-buffer'."
  (hermes--on-session-buffer hermes--bench-buffers
    (hermes-bench--refresh-status)))

(defun hermes-bench--ensure-visible-end ()
  "Keep bench windows showing the bottom (input area)."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (with-selected-window w
        (goto-char (point-max))
        (recenter -1)))))

;;;; Send / interrupt / compose

(defun hermes-bench-send ()
  "Send the current input-area text to this bench's session."
  (interactive)
  (let ((text (string-trim (hermes-bench--input-text)))
        (sid hermes-bench--session-id))
    (unless sid
      (user-error "Bench has no session"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    (hermes-bench--clear-input)
    ;; Pull org-viewer windows to point-max so the post-commit follow
    ;; logic in `hermes--render' sees them as tail-tracking.
    (hermes-bench--align-org-to-tail)
    (let ((hermes--current-session-id sid))
      (hermes-send text))
    (goto-char (point-max))))

(defun hermes-bench-interrupt-parent ()
  "Interrupt the bench's session."
  (interactive)
  (when hermes-bench--session-id
    (let ((hermes--current-session-id hermes-bench--session-id))
      (call-interactively #'hermes-interrupt-current-session))))

(defun hermes-bench-compose ()
  "Open the multi-line composer targeting the bench's session."
  (interactive)
  (when hermes-bench--session-id
    (call-interactively #'hermes-compose)))

(defun hermes-bench-show-status (_sid text &optional error-p)
  "Show TEXT as a transient status message in the echo area.
ERROR-P selects the `error' face.  Kept as a thin wrapper so existing
callers (image, config) keep working without a behavior fork."
  (let ((msg (if error-p (propertize text 'face 'error) text)))
    (message "%s" msg)))

(declare-function ansi-color-apply "ansi-color" (string))

(provide 'hermes-bench)
;;; hermes-bench.el ends here
