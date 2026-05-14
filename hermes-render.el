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
  (setq hermes--stream-content-start (point-marker)
        hermes--stream-stable-end    (point-marker)
        hermes--stream-end           (point-marker))
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
                    hermes--stream-headline-marker))
    (when (markerp m) (set-marker m nil)))
  (setq hermes--stream-stable-end nil
        hermes--stream-end nil
        hermes--stream-content-start nil
        hermes--stream-headline-marker nil))

(defun hermes--stream-update (old-stream new-stream)
  "Reflect OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-stable-end)
            (null hermes--stream-end))
    ;; Defensive: a delta arrived without a preceding message.start.
    (hermes--stream-begin))
  (let* ((old-text (and old-stream (hermes-stream-text old-stream)))
         (new-text (hermes-stream-text new-stream)))
    (unless (equal old-text new-text)
      (hermes--rewrite-stream new-text))))

(defun hermes--rewrite-stream (text)
  "Place TEXT into the in-flight region using a stable/unstable split.
Stable prefix is converted from markdown and appended at
`hermes--stream-stable-end' (which then advances).  Unstable suffix
replaces only the old unstable characters — tools that sit beyond
`hermes--stream-end' are left untouched."
  (let* ((boundary (hermes--stable-boundary text))
         (already  (- (marker-position hermes--stream-stable-end)
                       (marker-position hermes--stream-content-start)))
         (stable   (substring text 0 boundary))
         (unstable (substring text boundary))
         (new-stable-substring (substring stable already))
         (old-unstable-len
          (- (marker-position hermes--stream-end)
             (marker-position hermes--stream-stable-end))))
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
           (let ((q (and hermes--state (hermes-state-queue hermes--state))))
             (if (and q (> (length q) 0))
                 (format " · queue: %d" (length q))
               "")))
         '(:eval (or hermes--ui-line ""))))
  (force-mode-line-update))

(provide 'hermes-render)
;;; hermes-render.el ends here
