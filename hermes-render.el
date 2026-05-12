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
  "Marker: end of the unstable suffix.  Points at buffer end while streaming.")

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
  (insert "* assistant\n")
  (setq hermes--stream-stable-end (point-marker)
        hermes--stream-end        (point-marker))
  ;; Both markers must advance when text is inserted at their position.
  (set-marker-insertion-type hermes--stream-stable-end nil)
  (set-marker-insertion-type hermes--stream-end       t))

(defun hermes--stream-commit ()
  "Stream finished: drop markers; the buffer text is already correct."
  (when (markerp hermes--stream-stable-end)
    (set-marker hermes--stream-stable-end nil))
  (when (markerp hermes--stream-end)
    (set-marker hermes--stream-end nil))
  (setq hermes--stream-stable-end nil
        hermes--stream-end nil))

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
