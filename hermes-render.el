;;; hermes-render.el --- Diff-based renderer for the Hermes Org buffer -*- lexical-binding: t; -*-

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
;; M2 scope: plain text streaming, user + assistant messages, header line.
;; No tools, no approvals, no markdown→Org conversion (deferred to M3).

;;; Code:

(require 'cl-lib)
(require 'org-id)
(require 'hermes-state)
(require 'hermes-skin)
(require 'hermes-md)

;;;; Buffer-local markers for the in-flight region

(defvar-local hermes--ui-line ""
  "Right-hand status text driven by the ephemeral state.")

(defvar-local hermes--stream-stable-end nil
  "Marker: end of the stable (frozen) part of the in-flight assistant message.")

(defvar-local hermes--stream-end nil
  "Marker: end of the unstable suffix.")

(defvar-local hermes--stream-headline-marker nil
  "Marker at the start of the in-flight `** assistant' headline.")

(defvar-local hermes--stream-content-start nil
  "Marker: position where stream body text begins (right after the
assistant property drawer).  Used to compute the `already' offset so
the property drawer is not counted as stream text.")

(defvar-local hermes--stream-thinking-marker nil
  "Marker at the start of the thinking block, or nil if none.")

(defvar-local hermes--stream-tools-marker nil
  "Marker at the start of the tool blocks region, or nil if no tools.")

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
  ;; `with-silent-modifications' suppresses change hooks that Org's element
  ;; cache depends on.  Reset it so `org-id-get-create' and other Org
  ;; operations don't trip over stale data.
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
  "Insert a level-1 heading for a new turn (user or system message).

The heading line shows the first line of TEXT, truncated to a
readable prefix.  The full TEXT goes in the body.  A property
drawer with HERMES_SESSION, HERMES_MODEL, HERMES_TIMESTAMP, and
an Org :ID: is stamped."
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

(defun hermes--insert-before-text (content)
  "Insert CONTENT before the main text region, advancing all stream markers.
All existing stream markers are pushed forward by the length of CONTENT."
  (when (and content (> (length content) 0)
             (markerp hermes--stream-content-start)
             (marker-position hermes--stream-content-start))
    (goto-char hermes--stream-content-start)
    (insert content)
    ;; content-start itself must move past the inserted block so it
    ;; still marks the boundary between meta-content and stream text.
    (set-marker hermes--stream-content-start
                (+ (marker-position hermes--stream-content-start)
                   (length content)))
    ;; stable-end has insertion-type nil so it stays put during the
    ;; insert; we must manually advance it.  stream-end has type t
    ;; and auto-advances — do NOT touch it here.
    (when (markerp hermes--stream-stable-end)
      (set-marker hermes--stream-stable-end
                  (+ (marker-position hermes--stream-stable-end)
                     (length content))))))

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
  (setq hermes--stream-content-start   (point-marker)
        hermes--stream-stable-end      (point-marker)
        hermes--stream-end             (point-marker)
        hermes--stream-thinking-marker nil)
  (set-marker-insertion-type hermes--stream-content-start nil)
  (set-marker-insertion-type hermes--stream-stable-end    nil)
  (set-marker-insertion-type hermes--stream-end           t))

(defun hermes--stream-commit ()
  "Stream finished: stamp Org :ID:s on the trail, drop markers."
  ;; Convert any residual unstable tail from markdown to Org.
  (when (and (markerp hermes--stream-stable-end)
             (markerp hermes--stream-end)
             (> (marker-position hermes--stream-end)
                (marker-position hermes--stream-stable-end)))
    (let ((beg (marker-position hermes--stream-stable-end))
          (end (marker-position hermes--stream-end)))
      (save-excursion
        (goto-char beg)
        (insert (hermes-md-to-org (delete-and-extract-region beg end))))))
  ;; Stamp the assistant headline itself so external Org buffers can cite it.
  (when (and (derived-mode-p 'org-mode)
             (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  ;; Drop the markers; the buffer text is already correct.
  (dolist (m (list hermes--stream-stable-end
                    hermes--stream-end
                    hermes--stream-content-start
                    hermes--stream-headline-marker
                    hermes--stream-thinking-marker
                    hermes--stream-tools-marker))
    (when (markerp m) (set-marker m nil)))
  (setq hermes--stream-stable-end nil
        hermes--stream-end nil
        hermes--stream-content-start nil
        hermes--stream-headline-marker nil
        hermes--stream-thinking-marker nil
        hermes--stream-tools-marker nil))

(defun hermes--stream-update (old-stream new-stream)
  "Reflect OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-stable-end)
            (null hermes--stream-end))
    ;; Defensive: a delta arrived without a preceding message.start.
    (hermes--stream-begin))
  (let* ((old-text (and old-stream (hermes-stream-text old-stream)))
         (new-text (hermes-stream-text new-stream))
         (old-thinking (and old-stream (hermes-stream-thinking old-stream)))
         (new-thinking (hermes-stream-thinking new-stream))
         (old-reasoning (and old-stream (hermes-stream-reasoning old-stream)))
         (new-reasoning (hermes-stream-reasoning new-stream))
         (old-tools (and old-stream (hermes-stream-tools old-stream)))
         (new-tools (hermes-stream-tools new-stream)))
    (unless (equal old-text new-text)
      (hermes--rewrite-stream new-text))
    (unless (and (equal old-thinking new-thinking)
                 (equal old-reasoning new-reasoning))
      (hermes--update-thinking-block new-thinking new-reasoning))
    (unless (eq old-tools new-tools)
      (hermes--update-tool-views new-tools))))

(defun hermes--rewrite-stream (text)
  "Place TEXT into the in-flight region using a stable/unstable split.
Stable prefix is converted from markdown and appended at
`hermes--stream-stable-end' (which then advances).  Unstable suffix
replaces only the old unstable characters — tools that sit beyond
`hermes--stream-end' are left untouched."
  (let* ((boundary (hermes--stable-boundary text))
         (already  (max 0 (- (marker-position hermes--stream-stable-end)
                             (marker-position hermes--stream-content-start))))
         (stable   (substring text 0 boundary))
         (unstable (substring text boundary))
         (new-stable-substring (substring stable already))
         (old-unstable-len
          (max 0 (- (marker-position hermes--stream-end)
                    (marker-position hermes--stream-stable-end)))))
    ;; TODO: remove debug log after tool pipeline is stable
    (message "[hermes] rewrite: text=%S boundary=%d already=%d del=%d"
             (substring text 0 (min 120 (length text)))
             boundary already old-unstable-len)
    ;; Append the newly-stable chunk at the stable marker, converting to Org.
    (when (> (length new-stable-substring) 0)
      (goto-char hermes--stream-stable-end)
      (insert (hermes-md-to-org new-stable-substring))
      (set-marker hermes--stream-stable-end (point)))
    ;; Delete exactly the old unstable chars; tools after them stay.
    (goto-char hermes--stream-stable-end)
    (delete-char old-unstable-len)
    (insert unstable)))

(defun hermes--stable-boundary (text)
  "Return the index of the last `\\n\\n' in TEXT outside a fenced code block.
Returns 0 if no such boundary exists yet."
  (let ((in-fence nil)
        (i 0)
        (n (length text))
        (last-boundary 0))
    (while (< i n)
      (cond
       ;; Toggle fence on triple-backtick at start of line.
       ((and (or (zerop i) (eq (aref text (1- i)) ?\n))
             (<= (+ i 3) n)
             (string= (substring text i (+ i 3)) "```"))
        (setq in-fence (not in-fence))
        (setq i (+ i 3)))
       ;; Record `\n\n' when outside a fence.
       ((and (not in-fence)
             (< (1+ i) n)
             (eq (aref text i) ?\n)
             (eq (aref text (1+ i)) ?\n))
        (setq last-boundary (+ i 2))
        (setq i (+ i 2)))
       (t (setq i (1+ i)))))
    last-boundary))

(defun hermes--update-thinking-block (thinking reasoning)
  "Insert or update the thinking block before the text region.
THINKING and REASONING are strings; when both are empty the block
is removed."
  (let ((have-content (or (and thinking (not (string-empty-p thinking)))
                          (and reasoning (not (string-empty-p reasoning))))))
    (cond
     ;; No block yet and we have content → insert before text region.
      ((and (null hermes--stream-thinking-marker) have-content)
       (let ((block (hermes--format-thinking-block thinking reasoning)))
         ;; Remember where the block will start (current content-start).
         (setq hermes--stream-thinking-marker
               (copy-marker hermes--stream-content-start))
         (set-marker-insertion-type hermes--stream-thinking-marker nil)
         (hermes--insert-before-text block)))
     ;; Block exists and we have content → replace region.
      ((and (markerp hermes--stream-thinking-marker)
            (marker-position hermes--stream-thinking-marker)
            have-content)
       (let* ((beg (marker-position hermes--stream-thinking-marker))
              (end (marker-position hermes--stream-content-start))
              (old-len (- end beg))
              (block (hermes--format-thinking-block thinking reasoning))
              (new-len (length block))
              (delta (- new-len old-len)))
         (goto-char beg)
         (delete-region beg end)
         (insert block)
          ;; Re-anchor the marker at the start of the block.
          (set-marker hermes--stream-thinking-marker beg)
          (set-marker hermes--stream-content-start (+ beg new-len))
          ;; After delete+insert, stable-end sits at `beg' (insertion-type
          ;; nil).  Snap it forward to the new content-start so the
          ;; stable region remains consistent.
          (when (markerp hermes--stream-stable-end)
            (set-marker hermes--stream-stable-end
                        (marker-position hermes--stream-content-start)))))
      ;; Block exists but content is now empty → remove.
      ((and (markerp hermes--stream-thinking-marker)
            (marker-position hermes--stream-thinking-marker)
            (not have-content))
       (let* ((beg (marker-position hermes--stream-thinking-marker))
              (end (marker-position hermes--stream-content-start)))
         ;; Deletion automatically shifts markers after the region;
         ;; do NOT manually adjust them again.
         (delete-region beg end)
         (set-marker hermes--stream-thinking-marker nil)
         (setq hermes--stream-thinking-marker nil))))))

;;;; Tool rendering

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
                   ;; Context / preview for running tools
                   (when (and (eq status 'running) context)
                     (format ":CONTEXT:\n%s\n:END:\n" context))
                   (when (and (memq status '(running generating)) preview)
                     (format "#+begin_example\n%s\n#+end_example\n" preview))
                   ;; Output / error for complete tools
                   (cond
                    (err (format "#+begin_example\n%s\n#+end_example\n" err))
                    (output (format "#+begin_example\n%s\n#+end_example\n" output))
                    (t ""))
                   ;; Inline diff
                   (when inline-diff
                     (format "#+begin_diff\n%s\n#+end_diff\n" inline-diff))
                   ;; Todos checklist
                   (when todos
                     (concat (format ":TODOS:\n")
                             (mapconcat
                              (lambda (todo)
                                (let ((text (or (hermes--get todo "text") ""))
                                      (done (hermes--get todo "done")))
                                  (format "- [%s] %s" (if done "X" " ") text)))
                              todos "\n")
                             "\n:END:\n")))))
      ;; Ensure a blank line after every tool block for visual separation.
      (if (> (length body) 0)
          (concat body "\n")
        body))))

(defun hermes--format-tools-block (tools)
  "Format TOOLS (vector of hermes-tool) as Org blocks.
Returns the empty string if TOOLS is empty."
  (let ((n (length tools)))
    (if (= n 0)
        ""
      (let (parts)
        (dotimes (i n)
          (push (hermes--format-tool (aref tools i)) parts))
        (apply #'concat (nreverse parts))))))

(defun hermes--insert-after-text (content)
  "Insert CONTENT after the text region, keeping `hermes--stream-end'
at the text/tool boundary.  Ensures a blank line between text and
the inserted content."
  (when (and content (> (length content) 0)
             (markerp hermes--stream-end)
             (marker-position hermes--stream-end))
    (let ((boundary (marker-position hermes--stream-end)))
      (goto-char (point-max))
      ;; Ensure at least one blank line between text and inserted content.
      (unless (<= (point) 1)
        (insert "\n"))
      (insert content)
      ;; stream-end may have auto-advanced if we inserted at its
      ;; position; snap it back to the boundary.
      (set-marker hermes--stream-end boundary))))

(defun hermes--update-tool-views (tools)
  "Render TOOLS as Org blocks after the text region."
  (let ((block (hermes--format-tools-block tools)))
    ;; Remove any existing tool blocks first.
    ;; stream-end and stream-tools-marker both sit at the text/tool boundary,
    ;; so we must delete from the marker to point-max (tools are always last).
    (when (markerp hermes--stream-tools-marker)
      (let ((beg (marker-position hermes--stream-tools-marker)))
        (when (< beg (point-max))
          (delete-region beg (point-max))))
      (set-marker hermes--stream-tools-marker nil)
      (setq hermes--stream-tools-marker nil))
    ;; Insert new tool blocks if any.
    (when (> (length block) 0)
      (let ((boundary (marker-position hermes--stream-end)))
        (goto-char (point-max))
        ;; Ensure at least one blank line between text and first tool.
        ;; Always insert a newline unconditionally: if the text already ends
        ;; with one we get a blank line; if not we guarantee separation.
        (unless (<= (point) 1)
          (insert "\n"))
        (insert block)
        (setq hermes--stream-tools-marker (copy-marker boundary))
        (set-marker-insertion-type hermes--stream-tools-marker nil)
        ;; Keep stream-end at the text boundary.
        (set-marker hermes--stream-end boundary)))))

;;; Header line

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
