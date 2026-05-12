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
(require 'hermes-state)

;;;; Buffer-local markers for the in-flight region

(defvar-local hermes--ui-line ""
  "Right-hand status text driven by the ephemeral state.")

(defvar-local hermes--stream-stable-end nil
  "Marker: end of the stable (frozen) part of the in-flight assistant message.")

(defvar-local hermes--stream-end nil
  "Marker: end of the unstable suffix.
Text inserts happen between `hermes--stream-stable-end' and this marker;
tool subtrees accumulate AFTER this marker.")

(defvar-local hermes--stream-tool-markers nil
  "Alist of tool-id (string) → marker at the tool's headline start.")

(defvar-local hermes--stream-headline-marker nil
  "Marker at the start of the in-flight `* assistant' headline.")

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
      ;; 3. Header line — session-info / connection.
      (unless (and old
                   (eq (hermes-state-session-info old)
                       (hermes-state-session-info new))
                   (eq (hermes-state-connection old)
                       (hermes-state-connection new)))
        (hermes--render-header new)))))

(defun hermes--render-ui (_old new)
  "Re-render the header line from the ephemeral state NEW."
  (setq hermes--ui-line
        (format " %s" (or (hermes-ui-state-status-text new) "")))
  (force-mode-line-update))

;;;; Committed messages

(defun hermes--render-committed-message (msg)
  "Append MSG to the buffer.  Skip assistant messages — those are streamed."
  (pcase (hermes-message-kind msg)
    ('user      (hermes--insert-headline "user" (hermes-message-text msg)))
    ('system    (hermes--insert-headline "system" (hermes-message-text msg)))
    ('assistant
     ;; Streaming already rendered the text; we only need to make sure the
     ;; sentinel markers are gone (stream-commit handles that).
     nil)))

(defun hermes--insert-headline (kind text)
  "Insert a `* KIND' headline followed by TEXT at `point-max'."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert (format "* %s\n" kind))
  (when (and text (not (string-empty-p text)))
    (insert text)
    (unless (eq (char-before) ?\n) (insert "\n"))))

;;;; Stream lifecycle

(defun hermes--stream-begin ()
  "Insert a `* assistant' headline and prepare the in-flight markers."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (setq hermes--stream-headline-marker (point-marker))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (insert "* assistant\n")
  (setq hermes--stream-stable-end (point-marker)
        hermes--stream-end        (point-marker)
        hermes--stream-tool-markers nil)
  ;; stable-end stays put on insert (we want appended chars to go AFTER it
  ;; only when we explicitly advance it); stream-end follows insertions so
  ;; it always points at end-of-text.
  (set-marker-insertion-type hermes--stream-stable-end nil)
  (set-marker-insertion-type hermes--stream-end       t))

(defun hermes--stream-commit ()
  "Stream finished: stamp Org :ID:s on the trail, drop markers."
  ;; Walk every in-flight tool subtree and stamp it with an :ID:.
  (dolist (cell hermes--stream-tool-markers)
    (let ((m (cdr cell)))
      (when (and (markerp m) (marker-position m))
        (save-excursion
          (goto-char m)
          (ignore-errors (org-id-get-create))))))
  ;; Stamp the assistant headline itself so external Org buffers can cite it.
  (when (and (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  ;; Drop the markers; the buffer text is already correct.
  (dolist (m (list hermes--stream-stable-end
                   hermes--stream-end
                   hermes--stream-headline-marker))
    (when (markerp m) (set-marker m nil)))
  (dolist (cell hermes--stream-tool-markers)
    (when (markerp (cdr cell)) (set-marker (cdr cell) nil)))
  (setq hermes--stream-stable-end nil
        hermes--stream-end nil
        hermes--stream-headline-marker nil
        hermes--stream-tool-markers nil))

(defun hermes--stream-update (old-stream new-stream)
  "Reflect OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-stable-end)
            (null hermes--stream-end))
    ;; Defensive: a delta arrived without a preceding message.start.
    (hermes--stream-begin))
  (let* ((old-text (and old-stream (hermes-stream-text old-stream)))
         (new-text (hermes-stream-text new-stream)))
    (unless (equal old-text new-text)
      (hermes--rewrite-stream new-text)))
  (let ((old-tools (and old-stream (hermes-stream-tools old-stream)))
        (new-tools (hermes-stream-tools new-stream)))
    (unless (eq old-tools new-tools)
      (hermes--render-stream-tools old-tools new-tools))))

(defun hermes--rewrite-stream (text)
  "Place TEXT into the in-flight region using a stable/unstable split.
Stable prefix is appended at `hermes--stream-stable-end' (which then
advances).  Unstable suffix replaces the region between the stable
marker and `hermes--stream-end'."
  (let* ((boundary (hermes--stable-boundary text))
         (already  (- (marker-position hermes--stream-stable-end)
                      (save-excursion
                        (goto-char hermes--stream-stable-end)
                        (re-search-backward "^\\* assistant\n" nil t)
                        (match-end 0))))
         (stable   (substring text 0 boundary))
         (unstable (substring text boundary))
         (new-stable-substring (substring stable already)))
    ;; Append the newly-stable chunk at the stable marker, advancing it.
    (when (> (length new-stable-substring) 0)
      (goto-char hermes--stream-stable-end)
      (insert new-stable-substring))
    ;; Replace the unstable region.
    (delete-region hermes--stream-stable-end hermes--stream-end)
    (goto-char hermes--stream-stable-end)
    (insert unstable)
    ;; `hermes--stream-end' has insertion-type t, so it tracked our inserts.
    ))

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

;;;; Tool subtrees

(defun hermes--render-stream-tools (old-tools new-tools)
  "Sync OLD-TOOLS → NEW-TOOLS by inserting or rewriting subtrees at point-max."
  ;; Pass 1: any new tool not present before → insert a subtree at point-max.
  (let ((old-ids (mapcar #'hermes-tool-id (append old-tools nil))))
    (dotimes (i (length new-tools))
      (let ((tool (aref new-tools i)))
        (unless (member (hermes-tool-id tool) old-ids)
          (hermes--insert-tool-subtree tool)))))
  ;; Pass 2: any tool whose status/output changed → rewrite subtree in place.
  (let ((n (min (length old-tools) (length new-tools))))
    (dotimes (i n)
      (let ((old (aref old-tools i))
            (new (aref new-tools i)))
        (unless (eq old new)
          (hermes--rewrite-tool-subtree new))))))

(defun hermes--insert-tool-subtree (tool)
  "Append the subtree for TOOL at point-max, recording a marker."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (let ((start (point-marker)))
    (set-marker-insertion-type start nil)
    (insert (hermes--format-tool-subtree tool))
    (push (cons (hermes-tool-id tool) start) hermes--stream-tool-markers)))

(defun hermes--rewrite-tool-subtree (tool)
  "Locate TOOL's subtree via its marker and replace its contents."
  (let ((m (alist-get (hermes-tool-id tool)
                      hermes--stream-tool-markers nil nil #'equal)))
    (when (and (markerp m) (marker-position m))
      (save-excursion
        (goto-char m)
        (let ((beg (point))
              (end (save-excursion
                     (forward-line 1)
                     (let ((next (save-excursion
                                   (re-search-forward "^\\* " nil t))))
                       (if next
                           (progn (forward-line -1)
                                  (line-beginning-position 2))
                         (point-max))))))
          ;; Find the start of the next sibling `**' or higher to bound.
          (setq end (save-excursion
                      (goto-char beg)
                      (forward-line 1)
                      (if (re-search-forward "^\\*\\{1,2\\} " nil t)
                          (line-beginning-position)
                        (point-max))))
          (delete-region beg end)
          (insert (hermes--format-tool-subtree tool)))))))

(defun hermes--format-tool-subtree (tool)
  "Return the Org text for TOOL's subtree (headline + drawer + output)."
  (let* ((name (or (hermes-tool-name tool) "tool"))
         (status (hermes-tool-status tool))
         (dur (hermes-tool-duration tool))
         (status-label (pcase status
                         ('generating "running…")
                         ('running    "running…")
                         ('complete   (if dur (format "%.1fs" dur) "done"))
                         ('error      "error")
                         (_           (format "%s" status))))
         (output (hermes-tool-output tool))
         (err    (hermes-tool-error tool)))
    (concat
     (format "** %s (%s)                                              :hermes-tool:\n"
             name status-label)
     ":PROPERTIES:\n"
     (format ":tool_id:  %s\n" (hermes-tool-id tool))
     (format ":status:   %s\n" status)
     (when dur (format ":duration: %s\n" dur))
     ":END:\n"
     (cond
      (err    (format "#+begin_example\n%s\n#+end_example\n" err))
      (output (format "#+begin_example\n%s\n#+end_example\n" output))
      (t      "")))))

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
         '(:eval (or hermes--ui-line ""))))
  (force-mode-line-update))

(provide 'hermes-render)
;;; hermes-render.el ends here
