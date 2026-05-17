;;; hermes-bench.el --- Persistent bottom bench for hermes-mode -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The bench is a bottom side-window paired with a `hermes-mode' buffer.
;; It is the user's interactive surface: structured zones for the last
;; turn (user prompt, reasoning, answer) plus an input area at the
;; bottom.  The parent Org buffer remains the canonical history; the
;; bench only mirrors the last turn for inspection while it streams,
;; and keeps it visible until the next user prompt arrives.
;;
;; The bench buffer is a pure display surface — no state atom.  All
;; reads go through the parent's buffer-local `hermes--state'.

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
  "Face for the user prompt heading in the bench."
  :group 'hermes)

(defface hermes-bench-reasoning-heading-face
  '((t :inherit org-level-3))
  "Face for the `*** Reasoning' heading in the bench."
  :group 'hermes)

(defface hermes-bench-reasoning-face
  '((t :inherit italic :foreground "gray60"))
  "Face for reasoning text in the bench."
  :group 'hermes)

(defface hermes-bench-tool-face
  '((t :inherit hermes-tool-face))
  "Face for tool lines in the bench."
  :group 'hermes)

;;;; Buffer-local state (in bench buffer)

(defvar-local hermes-bench--parent-buffer nil
  "The hermes-mode org buffer this bench renders for.")

(defvar-local hermes-bench--input-boundary nil
  "Marker just before the input prompt (start of the prompt string).
Text after this marker is the user-editable input area.")

(defvar-local hermes-bench--user-prompt-start nil)
(defvar-local hermes-bench--user-prompt-end nil)
(defvar-local hermes-bench--reasoning-start nil)
(defvar-local hermes-bench--reasoning-end nil)
(defvar-local hermes-bench--answer-start nil)
(defvar-local hermes-bench--answer-end nil)

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

(defun hermes-bench--make-marker (pos type)
  (let ((m (copy-marker pos type))) m))

(defun hermes-bench--insert-input-frame ()
  "Insert the separator + prompt at point, set `hermes-bench--input-boundary'.
The separator and prompt are read-only; the area after the prompt is
the user-editable input."
  (progn
    (insert (propertize (concat hermes-bench-separator "\n")
                        'face 'hermes-bench-separator-face
                        'read-only t 'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))
    (setq hermes-bench--input-boundary
          (hermes-bench--make-marker (point) nil))
    (insert (propertize hermes-bench-prompt
                        'face 'hermes-bench-prompt-face
                        'read-only t 'front-sticky '(read-only)
                        'rear-nonsticky '(read-only)))))

(defun hermes-bench--rebuild-zones ()
  "Erase the ephemeral region and insert the zone scaffold.
Sets all `hermes-bench--*-start/end' markers.  Leaves the separator and
input area below untouched (they are re-inserted only when missing)."
  (let ((inhibit-read-only t))
    ;; If an input frame already exists, wipe everything above it.
    ;; Otherwise wipe the whole buffer and reinstall the frame at the
    ;; tail later.
    (if (and (markerp hermes-bench--input-boundary)
             (marker-position hermes-bench--input-boundary))
        (let ((sep-line-start
               (save-excursion
                 (goto-char (marker-position hermes-bench--input-boundary))
                 (forward-line -1)
                 (line-beginning-position))))
          (delete-region (point-min) sep-line-start))
      (erase-buffer))
    (goto-char (point-min))
    ;; --- User prompt zone --------------------------------------------
    (insert (propertize "** " 'face 'hermes-bench-user-face))
    (setq hermes-bench--user-prompt-start
          (hermes-bench--make-marker (point) nil))
    (setq hermes-bench--user-prompt-end
          (hermes-bench--make-marker (point) t))
    (insert "\n\n")
    ;; --- Reasoning zone ----------------------------------------------
    (insert (propertize "*** Reasoning\n"
                        'face 'hermes-bench-reasoning-heading-face))
    (setq hermes-bench--reasoning-start
          (hermes-bench--make-marker (point) nil))
    (setq hermes-bench--reasoning-end
          (hermes-bench--make-marker (point) t))
    (insert "\n\n")
    ;; --- Answer zone -------------------------------------------------
    (setq hermes-bench--answer-start
          (hermes-bench--make-marker (point) nil))
    (setq hermes-bench--answer-end
          (hermes-bench--make-marker (point) t))
    (insert "\n\n")
    ;; --- Input frame (only if missing) -------------------------------
    (unless (and (markerp hermes-bench--input-boundary)
                 (marker-position hermes-bench--input-boundary))
      (hermes-bench--insert-input-frame))))

(defun hermes-bench--setup (parent)
  "Initialize the bench buffer contents for PARENT."
  (hermes-bench-mode)
  (setq hermes-bench--parent-buffer parent)
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq hermes-bench--input-boundary nil)
    (hermes-bench--rebuild-zones))
  (hermes-bench-set-header)
  (goto-char (point-max)))

(defun hermes-bench-ensure (parent)
  "Ensure a bench buffer exists and is displayed for PARENT."
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
    (when (and (markerp hermes-bench--input-boundary)
               (marker-position hermes-bench--input-boundary))
      (delete-region (marker-position hermes-bench--input-boundary)
                     (point-max)))))

;;;; Zone writers

(defun hermes-bench--replace-zone (start-marker end-marker text &optional face)
  "Delete the region between START-MARKER and END-MARKER, insert TEXT.
If FACE is non-nil, propertize the inserted text with it."
  (when (and (markerp start-marker) (marker-position start-marker)
             (markerp end-marker)   (marker-position end-marker))
    (let ((inhibit-read-only t))
      (delete-region (marker-position start-marker)
                     (marker-position end-marker))
      (save-excursion
        (goto-char (marker-position start-marker))
        (insert (if face (propertize text 'face face) text))))))

(defun hermes-bench--set-user-prompt (text)
  (hermes-bench--replace-zone
   hermes-bench--user-prompt-start hermes-bench--user-prompt-end
   (or text "") 'hermes-bench-user-face))

(defun hermes-bench--set-reasoning (text)
  (hermes-bench--replace-zone
   hermes-bench--reasoning-start hermes-bench--reasoning-end
   (or text "") 'hermes-bench-reasoning-face))

(defun hermes-bench--set-answer (text)
  (hermes-bench--replace-zone
   hermes-bench--answer-start hermes-bench--answer-end (or text "")))

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

;;;; Auto-scroll

(defun hermes-bench--ensure-visible-end ()
  "Keep point in bench windows pinned to the input area."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (set-window-point w (point-max)))))

;;;; Stream lifecycle (called from hermes--render)

(defun hermes-bench--latest-user-text (parent)
  "Return the most recently-submitted user prompt text from PARENT, or nil."
  (when (buffer-live-p parent)
    (let* ((state (buffer-local-value 'hermes--state parent))
           (turns (and state (hermes-state-pending-turns state)))
           (n (and (vectorp turns) (length turns))))
      (when (and n (> n 0))
        (let ((found nil)
              (i (1- n)))
          (while (and (not found) (>= i 0))
            (let ((m (aref turns i)))
              (when (eq 'user (hermes-message-kind m))
                (setq found m)))
            (cl-decf i))
          (when found
            (let ((segs (hermes-message-segments found)))
              (when (and (vectorp segs) (> (length segs) 0))
                (let ((s (aref segs 0)))
                  (and (eq 'text (hermes-segment-type s))
                       (hermes-segment-content s)))))))))))

(defun hermes-bench--stream-begin (bench)
  "Stream started: clear answer/reasoning zones, ensure user prompt is set."
  (when (buffer-live-p bench)
    (with-current-buffer bench
      (hermes-bench--set-reasoning "")
      (hermes-bench--set-answer "")
      ;; If `hermes-bench-send' didn't run (e.g. user submitted via
      ;; another path), backfill the user-prompt zone from the parent's
      ;; latest pending user turn.
      (let ((current (string-trim
                      (buffer-substring-no-properties
                       (marker-position hermes-bench--user-prompt-start)
                       (marker-position hermes-bench--user-prompt-end)))))
        (when (string-empty-p current)
          (let ((text (hermes-bench--latest-user-text
                       hermes-bench--parent-buffer)))
            (when text (hermes-bench--set-user-prompt text)))))
      (hermes-bench-set-header)
      (hermes-bench--ensure-visible-end))))

(defun hermes-bench--stream-update (bench _old new)
  "Repaint the bench reasoning and answer zones from NEW stream."
  (when (and (buffer-live-p bench) (hermes-stream-p new))
    (with-current-buffer bench
      (pcase-let ((`(,reasoning . ,answer)
                   (hermes-bench--segments-by-zone
                    (hermes-stream-segments new))))
        (hermes-bench--set-reasoning reasoning)
        (hermes-bench--set-answer answer))
      (hermes-bench--ensure-visible-end))))

(defun hermes-bench--stream-commit (bench old-stream)
  "Stream ended: commit OLD-STREAM into the parent's org buffer.
The bench is NOT cleared — the rendered answer persists until the next
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
                (hermes--insert-committed-turn msg))))))
      (with-current-buffer bench
        (hermes-bench-set-header)
        (hermes-bench--ensure-visible-end)))))

;;;; Send

(defun hermes-bench-send ()
  "Send the current input-area text to the paired parent buffer.
Clears the bench ephemeral content first, then echoes the user prompt
into the bench, then dispatches the text to the parent."
  (interactive)
  (let ((text (hermes-bench--input-text))
        (parent hermes-bench--parent-buffer))
    (unless (buffer-live-p parent)
      (user-error "Bench has no live parent buffer"))
    (when (or (null text) (string-empty-p text))
      (user-error "Nothing to send"))
    ;; 1+2+3. Wipe old turn from the bench, rebuild the zone scaffold.
    (hermes-bench--rebuild-zones)
    ;; 4. Echo the user prompt.
    (hermes-bench--set-user-prompt text)
    ;; 5. Dispatch to the parent (this fires :user-submit + RPC).
    (with-current-buffer parent
      (hermes-input-send text))
    ;; 6. Clear input area.
    (hermes-bench--clear-input)
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
                   (format " · %s->%s" (or sent "?") (or recv "?"))
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
