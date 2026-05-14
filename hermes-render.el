;;; hermes-render.el --- Segmented renderer for the Hermes Org buffer -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Two render hooks, one per atom.  `hermes--render' inspects which slots
;; changed and dispatches to a sub-renderer.  Each sub-renderer touches
;; only the region it owns: the streaming sentinel for in-flight text, an
;; append at point-max for committed messages, the header-line for
;; session-info.  All edits run inside `with-silent-modifications' and
;; `save-excursion' so the buffer never goes dirty and point doesn't jump.
;;
;; Segmented rendering: state stores a vector of typed segments (text,
;; thinking, reasoning, tool).  The renderer does a full replace of the
;; segment region on every stream update (Option A from the plan), keeping
;; the implementation simple.  Markers track the segment region boundaries.

;;; Code:

(require 'cl-lib)
(require 'org-id)
(require 'hermes-state)
(require 'hermes-skin)
(require 'hermes-md)

;;;; Buffer-local markers for the in-flight region

(defvar-local hermes--ui-line ""
  "Right-hand status text driven by the ephemeral state.")

(defvar-local hermes--stream-headline-marker nil
  "Marker at the start of the in-flight `** assistant' headline.")

(defvar-local hermes--stream-segments-start nil
  "Marker: start of the rendered segment region (after property drawer).")

(defvar-local hermes--stream-segments-end nil
  "Marker: end of the rendered segment region.")

;;;; Top-level dispatch

(defun hermes--render (old new)
  "Diff OLD vs NEW (both `hermes-state') and update the buffer."
  (with-silent-modifications
    (save-excursion
      ;; 1. Messages grew → append new tail messages (skip assistant ones
      ;;    that were already streamed).
      (let* ((old-n (length (and old (hermes-state-messages old))))
             (new-n (length (hermes-state-messages new))))
        (when (> new-n old-n)
          (cl-loop for i from old-n below new-n
                   for msg = (aref (hermes-state-messages new) i)
                   do (hermes--render-committed-message msg))))
      ;; 2. Stream lifecycle.
      (let ((os (and old (hermes-state-stream old)))
            (ns (hermes-state-stream new)))
        (cond ((and (null os) ns) (hermes--stream-begin))
              ((and os (null ns)) (hermes--stream-commit))
              ((not (eq os ns))   (hermes--stream-update os ns))))
      ;; 3. Header line — session-info / connection / usage.
      (unless (and old
                    (eq (hermes-state-session-info old)
                        (hermes-state-session-info new))
                    (eq (hermes-state-connection old)
                        (hermes-state-connection new))
                    (eq (hermes-state-usage old)
                        (hermes-state-usage new)))
        (hermes--render-header new))
      ;; 4. Queue length changed → refresh header-line :eval forms.
      (unless (eq (and old (hermes-state-queue old))
                   (hermes-state-queue new))
        (force-mode-line-update))))
  (when (derived-mode-p 'org-mode)
    (org-element-cache-reset)))

(defun hermes--render-ui (_old new)
  "Re-render the header line from the ephemeral state NEW."
  (setq hermes--ui-line
        (format " %s" (or (hermes-ui-state-status-text new) "")))
  (force-mode-line-update))

;;;; Committed messages

(defun hermes--render-committed-message (msg)
  "Append MSG to the buffer.  Skip assistant messages — those are streamed."
  (pcase (hermes-message-kind msg)
    ('user      (hermes--insert-turn-headline 'user   'hermes-user-face
                                              (hermes-message-text msg)))
    ('system    (hermes--insert-turn-headline 'system 'hermes-system-face
                                              (hermes-message-text msg)))
    ('assistant nil)))

(defun hermes--insert-turn-headline (kind face text)
  "Insert a level-1 heading for a new turn (user or system message)."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (let* ((prefix   (hermes--first-line (or text "")))
         (tag      (symbol-name kind))
         (heading  (format "* %s: %s" tag prefix))
         (sid      (or (hermes-state-session-id hermes--state) ""))
         (info     (hermes-state-session-info hermes--state))
         (model    (and (hash-table-p info) (gethash "model" info)))
         (hb       (point)))
    (insert (format "%s %s\n" heading (hermes--tag-spacer heading)))
    (hermes--face-overlay hb (1- (point)) face)
    (hermes--insert-properties
     `(("HERMES_SESSION" . ,sid)
       ("HERMES_MODEL" . ,model)
       ("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
    (when (derived-mode-p 'org-mode)
      (goto-char hb)
      (ignore-errors (org-id-get-create))
      (goto-char (point-max)))
    (when (and text (not (string-empty-p text)))
      (insert text)
      (unless (eq (char-before) ?\n) (insert "\n")))))

(defun hermes--tag-spacer (heading)
  "Return enough spaces to right-align a :HERMES: tag at column 80."
  (let* ((width (string-width heading))
         (pad   (- 77 width)))
    (if (> pad 0) (make-string pad ?\s) " ")))

(defun hermes--face-overlay (beg end face)
  "Put a face overlay over the headline region [BEG, END)."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'hermes-headline t)))

;;; Shell helpers

(defun hermes--first-line (text)
  "Return TEXT up to (but not including) the first newline."
  (let ((pos (cl-position ?\n text)))
    (if pos (substring text 0 pos) text)))

(defun hermes--now-iso ()
  "Return current time as an ISO-8601 string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun hermes--insert-properties (alist)
  "Insert a :PROPERTIES: drawer from ALIST ((prop . value) …) at point."
  (insert ":PROPERTIES:\n")
  (dolist (cell alist)
    (let ((prop (car cell))
          (val  (cdr cell)))
      (insert (format ":%s: %s\n" prop (or val "")))))
  (insert ":END:\n"))

;;;; Segment formatting

(defun hermes--format-thinking-block (thinking reasoning)
  "Return an Org block string for THINKING and REASONING content.
If both are empty or nil, return the empty string.
Each block is followed by a blank line for visual separation."
  (let (parts)
    (when (and thinking (not (string-empty-p thinking)))
      (push (concat "#+begin_example Thinking\n"
                    thinking
                    (unless (eq (aref thinking (1- (length thinking))) ?\n) "\n")
                    "#+end_example\n\n")
            parts))
    (when (and reasoning (not (string-empty-p reasoning)))
      (push (concat "#+begin_example Reasoning\n"
                    reasoning
                    (unless (eq (aref reasoning (1- (length reasoning))) ?\n) "\n")
                    "#+end_example\n\n")
            parts))
    (apply #'concat (nreverse parts))))

(defun hermes--format-tool (tool)
  "Return an Org block string for a single TOOL."
  (let* ((name (or (hermes-tool-name tool) "tool"))
         (status (hermes-tool-status tool))
         (dur (hermes-tool-duration tool))
         (output (hermes-tool-output tool))
         (err (hermes-tool-error tool))
         (preview (hermes-tool-preview tool))
         (context (hermes-tool-context tool))
         (inline-diff (hermes-tool-inline-diff tool))
         (todos (hermes-tool-todos tool))
         (status-label (pcase status
                         ('generating "running…")
                         ('running "running…")
                         ('complete (if dur (format "%.1fs" dur) "done"))
                         ('error "error")
                         (_ (format "%s" status)))))
    (let ((body
           (concat (format "*** %s (%s)\n" name status-label)
                   (when (and (eq status 'running) context)
                     (format ":CONTEXT:\n%s\n:END:\n" context))
                   (when (and (memq status '(running generating)) preview)
                     (format "#+begin_example\n%s\n#+end_example\n" preview))
                   (cond
                    (err (format "#+begin_example\n%s\n#+end_example\n" err))
                    (output (format "#+begin_example\n%s\n#+end_example\n" output))
                    (t ""))
                   (when inline-diff
                     (format "#+begin_diff\n%s\n#+end_diff\n" inline-diff))
                   (when todos
                     (concat (format ":TODOS:\n")
                             (mapconcat
                              (lambda (todo)
                                (let ((text (or (hermes--get todo "text") ""))
                                      (done (hermes--get todo "done")))
                                  (format "- [%s] %s" (if done "X" " ") text)))
                              todos "\n")
                             "\n:END:\n")))))
      (if (> (length body) 0)
          (concat body "\n")
        body))))

(defun hermes--format-segment (seg)
  "Return Org string for a single SEGMENT."
  (let ((type (aref seg 1))
        (content (aref seg 2)))
    (pcase type
      ('text (hermes-md-to-org content))
      ('thinking (hermes--format-thinking-block content nil))
      ('reasoning (hermes--format-thinking-block nil content))
      ('tool (hermes--format-tool content))
      ('system (format "#+begin_comment\n%s\n#+end_comment\n" content))
      (_ ""))))

(defun hermes--render-stream-segments (segments)
  "Render all SEGMENTS in order into the buffer."
  (unless (and (markerp hermes--stream-segments-start)
               (markerp hermes--stream-segments-end))
    (setq hermes--stream-segments-start (point-marker)
          hermes--stream-segments-end (point-marker))
    (set-marker-insertion-type hermes--stream-segments-start nil)
    (set-marker-insertion-type hermes--stream-segments-end t))
  (let ((start (marker-position hermes--stream-segments-start))
        (end (marker-position hermes--stream-segments-end)))
    (when (> end start)
      (delete-region start end))
    (goto-char start)
    (dotimes (i (length segments))
      (let ((formatted (hermes--format-segment (aref segments i))))
        (when (> (length formatted) 0)
          (unless (or (= i 0) (bolp))
            (insert "\n"))
          (insert formatted)
          (unless (bolp)
            (insert "\n")))))
    (set-marker hermes--stream-segments-end (point))))

;;;; Stream lifecycle

(defun hermes--stream-begin ()
  "Insert a `** assistant' headline with a property drawer and prepare markers."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (setq hermes--stream-headline-marker (point-marker))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (let ((hb (point))
        (heading "** assistant")
        (spacer  (make-string (- 74 (length "** assistant")) ?\s)))
    (insert (format "%s %s :hermes:\n" heading spacer))
    (hermes--face-overlay hb (1- (point)) 'hermes-assistant-face))
  (hermes--insert-properties
   `(("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  (setq hermes--stream-segments-start (point-marker)
        hermes--stream-segments-end   (point-marker))
  (set-marker-insertion-type hermes--stream-segments-start nil)
  (set-marker-insertion-type hermes--stream-segments-end   t))

(defun hermes--stream-commit ()
  "Stream finished: stamp Org :ID:s on the trail, drop markers."
  (when (and (derived-mode-p 'org-mode)
             (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  (dolist (m (list hermes--stream-segments-start
                    hermes--stream-segments-end
                    hermes--stream-headline-marker))
    (when (markerp m) (set-marker m nil)))
  (setq hermes--stream-segments-start nil
        hermes--stream-segments-end nil
        hermes--stream-headline-marker nil))

(defun hermes--stream-update (old-stream new-stream)
  "Reflect OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-segments-start)
            (null hermes--stream-segments-end))
    (hermes--stream-begin))
  (let ((new-segs (hermes-stream-segments new-stream)))
    (when (vectorp new-segs)
      (hermes--render-stream-segments new-segs))))

;;;; Header line

(defun hermes--render-header (_state)
  "Set `header-line-format'.  Reads `hermes--state' live via :eval."
  (setq header-line-format
        (list
         " Hermes"
         '(:eval (pcase (and hermes--state
                             (hermes-state-connection hermes--state))
                   ('connected    " · ●")
                   ('connecting   " · ◐")
                   ('disconnected " · ○")
                   (_             "")))
          '(:eval
            (let* ((info (and hermes--state
                              (hermes-state-session-info hermes--state)))
                   (model (and (hash-table-p info) (gethash "model" info))))
              (if model (format " · %s" model) "")))
          '(:eval
            (let* ((usage (and hermes--state
                               (hermes-state-usage hermes--state)))
                   (sent (and usage (gethash "tokens_sent" usage)))
                   (recv (and usage (gethash "tokens_received" usage))))
              (if (or sent recv)
                  (format " · %s→%s"
                          (or sent "?") (or recv "?"))
                "")))
          '(:eval
            (let ((q (and hermes--state (hermes-state-queue hermes--state))))
              (if (and q (> (length q) 0))
                  (format " · queue: %d" (length q))
                "")))
         '(:eval (or hermes--ui-line ""))))
  (force-mode-line-update))

(provide 'hermes-render)
;;; hermes-render.el ends here
