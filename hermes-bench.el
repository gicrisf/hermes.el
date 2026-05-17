;;; hermes-bench.el --- Persistent bottom bench for hermes-mode -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The bench is a bottom side-window paired with a `hermes-mode' buffer.
;; It is the user's interactive surface: ephemeral assistant stream
;; rendered above, single-line-feeling input area below.  The parent
;; Org buffer remains the canonical history; committed turns land there
;; only after the stream completes.
;;
;; The bench buffer is a pure display surface — no state atom.  All
;; reads go through the parent's buffer-local `hermes--state'.

;;; Code:

(require 'cl-lib)
(require 'hermes-state)
(require 'hermes-tool-formatters)

(declare-function hermes-input-send "hermes-input" (text))
(declare-function hermes-interrupt "hermes-mode" ())
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes--insert-committed-turn "hermes-render" (msg))
(declare-function hermes--message-from-stream "hermes-state" (stream usage))

(defcustom hermes-bench-height 6
  "Height in lines of the bench side-window."
  :type 'integer :group 'hermes)

(defcustom hermes-bench-prompt "> "
  "Prompt string shown at the start of the bench input area."
  :type 'string :group 'hermes)

(defface hermes-bench-prompt-face
  '((t :inherit minibuffer-prompt))
  "Face for the bench input prompt."
  :group 'hermes)

(defface hermes-bench-separator-face
  '((t :inherit shadow))
  "Face for the bench ephemeral/input separator line."
  :group 'hermes)

(defface hermes-bench-reasoning-face
  '((t :inherit italic :foreground "gray60"))
  "Face for reasoning text in the bench ephemeral area."
  :group 'hermes)

(defface hermes-bench-tool-face
  '((t :inherit hermes-tool-face))
  "Face for tool lines in the bench ephemeral area."
  :group 'hermes)

;;;; Buffer-local state (in bench buffer)

(defvar-local hermes-bench--parent-buffer nil
  "The hermes-mode org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker between ephemeral area (above) and input area (below).
Points at the start of the input prompt line.")

(defvar-local hermes-bench--ephemeral-start nil
  "Marker at the start of the ephemeral content (point-min normally).")

;;;; Buffer-local state (in parent buffer)

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
  (setq-local cursor-type 'bar)
  (setq-local hermes-bench--parent-buffer nil))

;;;; Lifecycle

(defun hermes-bench--buffer-name (parent)
  (format " *hermes-bench:%s*" (buffer-name parent)))

(defun hermes-bench-active-p (&optional parent)
  "Return the live bench buffer paired with PARENT (defaults to current).
Returns nil when no bench buffer exists for that parent."
  (let* ((p (or parent (current-buffer)))
         (b (and (buffer-live-p p)
                 (buffer-local-value 'hermes-bench--buffer p))))
    (and (buffer-live-p b) b)))

(defun hermes-bench--setup (parent)
  "Initialize the bench buffer contents for PARENT."
  (hermes-bench-mode)
  (setq hermes-bench--parent-buffer parent)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq hermes-bench--ephemeral-start (copy-marker (point-min) nil))
    ;; Separator line — visual hint between ephemeral area and input.
    (let ((sep-start (point)))
      (insert (propertize "──────\n" 'face 'hermes-bench-separator-face
                          'read-only t 'rear-nonsticky t
                          'hermes-bench-separator t))
      (setq hermes-bench--input-boundary (copy-marker (point) nil)))
    (let ((p-start (point)))
      (insert (propertize hermes-bench-prompt
                          'face 'hermes-bench-prompt-face
                          'read-only t 'rear-nonsticky t
                          'front-sticky '(read-only)))
      (set-marker hermes-bench--input-boundary (point))))
  (hermes-bench-set-header)
  (goto-char (point-max)))

(defun hermes-bench-ensure (parent)
  "Ensure a bench buffer exists and is displayed for PARENT.
Returns the bench buffer."
  (let* ((name (hermes-bench--buffer-name parent))
         (existing (buffer-local-value 'hermes-bench--buffer parent))
         (buf (or (and (buffer-live-p existing) existing)
                  (get-buffer-create name))))
    (with-current-buffer parent
      (setq hermes-bench--buffer buf))
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

(defun hermes-bench--input-text ()
  "Return trimmed input-area text."
  (when (and (markerp hermes-bench--input-boundary)
             (marker-position hermes-bench--input-boundary))
    (string-trim
     (buffer-substring-no-properties
      (marker-position hermes-bench--input-boundary) (point-max)))))

(defun hermes-bench--clear-input ()
  "Erase text after the input boundary."
  (let ((inhibit-read-only t))
    (delete-region (marker-position hermes-bench--input-boundary)
                   (point-max))))

(defun hermes-bench-send ()
  "Send the current input-area text to the paired parent buffer."
  (interactive)
  (let ((text (hermes-bench--input-text))
        (parent hermes-bench--parent-buffer))
    (unless (buffer-live-p parent)
      (user-error "Bench has no live parent buffer"))
    (when (or (null text) (string-empty-p text))
      (user-error "Nothing to send"))
    (hermes-bench--clear-input)
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

;;;; Ephemeral area: rendering

(defun hermes-bench-clear-ephemeral ()
  "Delete content between ephemeral-start and the separator boundary.
Preserves the input area."
  (when (and (markerp hermes-bench--ephemeral-start)
             (markerp hermes-bench--input-boundary))
    (let* ((inhibit-read-only t)
           (eph (marker-position hermes-bench--ephemeral-start))
           ;; The separator sits just before the input prompt; find it.
           (sep-end
            (save-excursion
              (goto-char (marker-position hermes-bench--input-boundary))
              (let ((p (previous-single-property-change
                        (point) 'hermes-bench-separator)))
                (or p eph)))))
      (delete-region eph sep-end))))

(defun hermes-bench--segment-text (seg)
  "Return a plain-text rendering of SEG, or nil for hidden segments."
  (let ((type (hermes-segment-type seg))
        (content (hermes-segment-content seg)))
    (pcase type
      ('text (and (stringp content) content))
      ('thinking nil)
      ('reasoning
       (and (stringp content) (not (string-empty-p content))
            (propertize (concat "[reasoning] " content "\n")
                        'face 'hermes-bench-reasoning-face)))
      ('tool
       (let* ((tool content)
              (name (and (hermes-tool-p tool) (hermes-tool-name tool)))
              (status (and (hermes-tool-p tool) (hermes-tool-status tool)))
              (formatter (and name (hermes-tool--lookup name)))
              (parts (and formatter (funcall formatter tool)))
              (summary (or (plist-get parts :summary) name "tool")))
         (propertize (format "🔧 %s [%s]\n" summary (or status "?"))
                     'face 'hermes-bench-tool-face)))
      ('system
       (and (stringp content) (concat "ℹ " content "\n")))
      (_ nil))))

(defun hermes-bench--render-segments (segments)
  "Replace ephemeral content with a plain-text rendering of SEGMENTS."
  (hermes-bench-clear-ephemeral)
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (marker-position hermes-bench--ephemeral-start))
      (when (vectorp segments)
        (dotimes (i (length segments))
          (let ((piece (hermes-bench--segment-text (aref segments i))))
            (when piece
              (insert piece)
              (unless (string-suffix-p "\n" piece) (insert "\n"))))))))
  (hermes-bench--ensure-visible-end))

(defun hermes-bench--ensure-visible-end ()
  "Auto-scroll: ensure the input boundary stays visible in bench windows."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (with-selected-window w
        (set-window-point w (point-max))
        (recenter -1)))))

;;;; Stream hooks called from hermes--render

(defun hermes-bench--stream-begin (bench)
  "Initialize the bench ephemeral area for a new assistant turn."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      (hermes-bench-clear-ephemeral)
      (hermes-bench-set-header))))

(defun hermes-bench--stream-update (bench _old-stream new-stream)
  "Repaint the bench ephemeral area from NEW-STREAM."
  (when (and (buffer-live-p bench) (hermes-stream-p new-stream))
    (with-current-buffer bench
      (hermes-bench--render-segments (hermes-stream-segments new-stream)))))

(defun hermes-bench--stream-commit (bench old-stream)
  "Build a message from OLD-STREAM, insert it into the parent, clear bench."
  (when (buffer-live-p bench)
    (let ((parent (buffer-local-value 'hermes-bench--parent-buffer bench)))
      (when (and (buffer-live-p parent)
                 (hermes-stream-p old-stream))
        (with-current-buffer parent
          (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                 (msg (hermes--message-from-stream old-stream usage)))
            (with-silent-modifications
              (save-excursion
                (hermes--insert-committed-turn msg))))))
      (with-current-buffer bench
        (hermes-bench-clear-ephemeral)
        (hermes-bench-set-header)))))

;;;; Header line

(defun hermes-bench-set-header ()
  "Set the bench `header-line-format' from the parent state."
  (let ((parent hermes-bench--parent-buffer))
    (setq header-line-format
          (list
           " Hermes"
           `(:eval
             (let ((s (and (buffer-live-p ,parent)
                           (buffer-local-value 'hermes--state ,parent))))
               (pcase (and s (hermes-state-connection s))
                 ('connected    " · ●")
                 ('connecting   " · ◐")
                 ('disconnected " · ○")
                 (_ ""))))
           `(:eval
             (let* ((s (and (buffer-live-p ,parent)
                            (buffer-local-value 'hermes--state ,parent)))
                    (info (and s (hermes-state-session-info s)))
                    (model (and (hash-table-p info) (gethash "model" info))))
               (if model (format " · %s" model) "")))
           `(:eval
             (let* ((s (and (buffer-live-p ,parent)
                            (buffer-local-value 'hermes--state ,parent)))
                    (u (and s (hermes-state-usage s)))
                    (sent (and u (gethash "tokens_sent" u)))
                    (recv (and u (gethash "tokens_received" u))))
               (if (or sent recv)
                   (format " · %s→%s" (or sent "?") (or recv "?"))
                 "")))
           `(:eval
             (let* ((s (and (buffer-live-p ,parent)
                            (buffer-local-value 'hermes--state ,parent)))
                    (q (and s (hermes-state-queue s))))
               (if (and q (> (length q) 0))
                   (format " · queue: %d" (length q))
                 "")))))
    (force-mode-line-update)))

(provide 'hermes-bench)
;;; hermes-bench.el ends here
