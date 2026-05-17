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

(declare-function hermes-input-send "hermes-input" (text))
(declare-function hermes-interrupt "hermes-mode" ())
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes--insert-committed-turn "hermes-render" (msg))
(declare-function hermes--message-from-stream "hermes-state" (stream usage))

(defcustom hermes-bench-height 20
  "Height in lines of the bench side-window."
  :type 'integer :group 'hermes)

(defcustom hermes-bench-prompt "> "
  "Prompt string shown at the start of the bench input area."
  :type 'string :group 'hermes)

(defcustom hermes-bench-separator "------"
  "Separator line between ephemeral zones and the input area."
  :type 'string :group 'hermes)

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
  "Fallback NOUS HERMES splash banner.")

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

;;;; Buffer-local state (bench buffer)

(defvar-local hermes-bench--parent-buffer nil
  "The hermes-mode org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker at the start of the separator line.
Everything above is ephemeral; everything below (separator + prompt +
user input) is the input frame.")

(defvar-local hermes-bench--current-user-prompt nil
  "Last user prompt painted into the bench (preserved across rebuilds).")

;;;; Buffer-local state (parent buffer)

(defvar-local hermes-bench--buffer nil
  "The bench buffer paired with this hermes-mode buffer.")

;;;; Mode

(defvar hermes-bench-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "RET")     #'hermes-bench-send)
    (define-key m (kbd "C-c C-c") #'hermes-bench-send)
    (define-key m (kbd "C-c C-k") #'hermes-bench-interrupt-parent)
    (define-key m (kbd "C-c C-l") #'hermes-bench-compose)
    m)
  "Keymap for `hermes-bench-mode'.")

(define-derived-mode hermes-bench-mode text-mode "Hermes-Bench"
  "Major mode for the Hermes bottom bench panel."
  (setq truncate-lines nil)
  (visual-line-mode 1)
  (setq-local cursor-type 'bar))

;;;; Lifecycle

(defun hermes-bench--buffer-name (parent)
  (format " *hermes-bench:%s*" (buffer-name parent)))

(defun hermes-bench-active-p (&optional parent)
  "Return the live bench buffer paired with PARENT, or nil."
  (let* ((p (or parent (current-buffer)))
         (b (and (buffer-live-p p)
                 (buffer-local-value 'hermes-bench--buffer p))))
    (and (buffer-live-p b) b)))

(defun hermes-bench--setup (parent)
  "Initialize the bench buffer contents for PARENT."
  (hermes-bench-mode)
  (setq hermes-bench--parent-buffer parent
        hermes-bench--current-user-prompt nil)
  (let ((inhibit-read-only t))
    (erase-buffer)
    ;; Seed `input-boundary' at point-min so the first paint has a
    ;; valid marker to delete up to.
    (setq hermes-bench--input-boundary (copy-marker (point-min) nil))
    (hermes-bench--paint-ephemeral))
  (setq-local header-line-format nil)
  (goto-char (point-max)))

(defun hermes-bench-ensure (parent)
  "Ensure a bench buffer exists and is displayed for PARENT."
  (let* ((name (hermes-bench--buffer-name parent))
         (existing (buffer-local-value 'hermes-bench--buffer parent))
         (buf (or (and (buffer-live-p existing) existing)
                  (get-buffer-create name))))
    (with-current-buffer parent
      (setq hermes-bench--buffer buf)
      (add-hook 'hermes-ui-state-change-hook
                #'hermes-bench--refresh-ui nil t)
      (add-hook 'hermes-state-change-hook
                #'hermes-bench--refresh-ui nil t))
    (with-current-buffer buf
      (unless (and (derived-mode-p 'hermes-bench-mode)
                   (eq hermes-bench--parent-buffer parent))
        (hermes-bench--setup parent)))
    (display-buffer-in-side-window
     buf `((side . bottom)
           (slot . 0)
           (window-height . ,hermes-bench-height)
           (dedicated . t)
           (preserve-size . (nil . t))
           (window-parameters . ((no-other-window . nil)
                                 (no-delete-other-windows . t)))))
    buf))

(defun hermes-bench-hide (parent)
  "Delete the bench window for PARENT and kill the bench buffer."
  (let ((buf (and (buffer-live-p parent)
                  (buffer-local-value 'hermes-bench--buffer parent))))
    (when (buffer-live-p buf)
      (dolist (w (get-buffer-window-list buf nil t))
        (when (window-live-p w) (delete-window w)))
      (kill-buffer buf))
    (when (buffer-live-p parent)
      (with-current-buffer parent
        (setq hermes-bench--buffer nil)))))

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
       hermes-bench--builtin-logo))))

(defun hermes-bench--splash-status ()
  "Return a one-line status string for the splash."
  (let* ((parent hermes-bench--parent-buffer)
         (state (and (buffer-live-p parent)
                     (buffer-local-value 'hermes--state parent)))
         (conn  (and state (hermes-state-connection state)))
         (sid   (and state (hermes-state-session-id state)))
         (info  (and state (hermes-state-session-info state)))
         (model (and (hash-table-p info) (gethash "model" info)))
         (dot   (pcase conn
                  ('connected "●")
                  ('connecting "◐")
                  (_ "○")))
         (label (cond ((eq conn 'connecting) "gateway starting…")
                      ((null sid) "ready · no session yet")
                      (t (format "session %s ready"
                                 (hermes-bench--short-sid sid))))))
    (concat dot "  " label
            (if model (concat "  ·  " model) ""))))

(defun hermes-bench--insert-splash ()
  "Insert the splash banner + status at point."
  (let ((logo (hermes-bench--splash-logo))
        (start (point)))
    (insert logo)
    (add-face-text-property start (point) 'hermes-bench-logo-face)
    (insert "\n\n")
    (insert (propertize (concat "  " (hermes-bench--splash-status))
                        'face 'hermes-bench-splash-status-face))
    (insert "\n\n")))

(defun hermes-bench--should-show-splash-p ()
  "Return non-nil when the bench has no conversation content to display."
  (let* ((parent hermes-bench--parent-buffer)
         (state (and (buffer-live-p parent)
                     (buffer-local-value 'hermes--state parent))))
    (and (or (null hermes-bench--current-user-prompt)
             (string-empty-p hermes-bench--current-user-prompt))
         (not (and state (hermes-state-stream state))))))

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
             (hermes-bench--should-show-splash-p))
        (hermes-bench--insert-splash)
      (unless (string-empty-p effective-user)
        (insert (propertize (concat "** " effective-user "\n\n")
                            'face 'hermes-bench-user-face)))
      ;; Reasoning zone — header always present.
      (insert (propertize "*** Reasoning\n"
                          'face 'hermes-bench-reasoning-heading-face))
      (when (and reasoning (not (string-empty-p reasoning)))
        (insert (propertize reasoning 'face 'hermes-bench-reasoning-face))
        (unless (string-suffix-p "\n" reasoning) (insert "\n")))
      (insert "\n")
      ;; Answer zone.
      (when (and answer (not (string-empty-p answer)))
        (insert answer)
        (unless (string-suffix-p "\n" answer) (insert "\n"))))
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

(defun hermes-bench--latest-user-text (parent)
  "Return the most-recent user prompt text from PARENT, or nil.
Looks at pending-turns first, then walks the parent's history ring."
  (when (buffer-live-p parent)
    (let* ((state (buffer-local-value 'hermes--state parent))
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
                 (and (consp hist) (car hist))))))))

;;;; Splash refresh on UI/session changes

(defun hermes-bench--refresh-ui (&optional _old _new)
  "Repaint the bench splash if it's currently showing.
Hooked into `hermes-ui-state-change-hook' (runs in the parent buffer);
also installed on event hooks that update session metadata."
  (let ((bench (hermes-bench-active-p)))
    (when (buffer-live-p bench)
      (with-current-buffer bench
        (when (hermes-bench--should-show-splash-p)
          (hermes-bench--paint-ephemeral))))))

;;;; Stream lifecycle (called from hermes--render)

(defun hermes-bench--stream-begin (bench)
  "Stream started: ensure user prompt is set, clear reasoning/answer."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      (let ((user (or hermes-bench--current-user-prompt
                      (hermes-bench--latest-user-text
                       hermes-bench--parent-buffer)
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
  "Stream ended: commit OLD-STREAM into the parent's org buffer.
The bench is NOT cleared; the answer remains until the next
`hermes-bench-send'."
  (when (buffer-live-p bench)
    (let ((parent (buffer-local-value 'hermes-bench--parent-buffer bench)))
      (when (and (buffer-live-p parent)
                 (hermes-stream-p old-stream))
        (with-current-buffer parent
          (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                 (msg (hermes--message-from-stream old-stream usage)))
            (with-silent-modifications
              (save-excursion
                (hermes--insert-committed-turn msg)))))))))

;;;; Send / interrupt / compose

(defun hermes-bench-send ()
  "Send the current input-area text to the paired parent buffer.
Clears the bench ephemeral content first (showing the new user prompt),
then dispatches the text to the parent."
  (interactive)
  (let ((text (string-trim (hermes-bench--input-text)))
        (parent hermes-bench--parent-buffer))
    (unless (buffer-live-p parent)
      (user-error "Bench has no live parent buffer"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    ;; 1+2. Clear input area first so it's not preserved by paint.
    (hermes-bench--clear-input)
    ;; 3. Wipe old turn, show new user prompt + empty reasoning/answer.
    (hermes-bench--paint-ephemeral text "" "")
    ;; 4. Dispatch to parent (fires :user-submit + RPC).
    (with-current-buffer parent
      (hermes-input-send text))
    (goto-char (point-max))))

(defun hermes-bench-interrupt-parent ()
  "Interrupt the parent session."
  (interactive)
  (when (buffer-live-p hermes-bench--parent-buffer)
    (with-current-buffer hermes-bench--parent-buffer
      (call-interactively #'hermes-interrupt))))

(defun hermes-bench-compose ()
  "Open the multi-line composer targeting the parent buffer."
  (interactive)
  (when (buffer-live-p hermes-bench--parent-buffer)
    (with-current-buffer hermes-bench--parent-buffer
      (call-interactively #'hermes-compose))))

(provide 'hermes-bench)
;;; hermes-bench.el ends here
