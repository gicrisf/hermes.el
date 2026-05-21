;;; hermes-migrate.el --- v1→v2 file format migration -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai

;;; Commentary:

;; One-shot helper to migrate Hermes conversation buffers from the v1
;; `:HERMES_RAW:' format to the v2 `:HERMES_META:' format.  The v1
;; format stored a serialized `hermes-message' plist (including
;; duplicated text) in a drawer at the end of each turn.  The v2
;; format derives text from the visible Org buffer and stores only
;; irreplaceable metadata (tool calls, images, usage, subagents) in a
;; smaller drawer.
;;
;; `M-x hermes-migrate-v1-to-v2' walks every turn-level heading,
;; reconstructs the message from its raw drawer, derives a fresh meta
;; drawer, writes `:HERMES_KIND:' / `:HERMES_TIMESTAMP:' properties on
;; the turn heading, removes the raw drawer, and inserts the meta
;; drawer in its place.  Running the function on an already-migrated
;; buffer is a no-op (no raw drawers found).
;;
;; The buffer is modified in place; save with `C-x C-s' once you've
;; verified the result.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'hermes-state)
(require 'hermes-render)

(defvar hermes--container-level)

(defun hermes--extract-raw-drawer-v1 (&optional pos)
  "Read a legacy `:HERMES_RAW:' drawer at POS (or point).
Returns the deserialized plist or nil.  Does not move point.
This is a self-contained reader so the migration command does not
depend on any v1 code path still being present in the codebase."
  (save-excursion
    (when pos (goto-char pos))
    (let ((bound (save-excursion
                   (cond
                    ((not (derived-mode-p 'org-mode)) (point-max))
                    ((ignore-errors (org-back-to-heading t))
                     (org-end-of-subtree t t)
                     (point))
                    (t (point-max))))))
      (when (re-search-forward "^:HERMES_RAW:[ \t]*$" bound t)
        (let ((body-start (line-end-position)))
          (when (re-search-forward "^:END:[ \t]*$" bound t)
            (let* ((body-end (line-beginning-position))
                   (raw (buffer-substring-no-properties body-start body-end))
                   (trimmed (string-trim raw)))
              (when (and trimmed (> (length trimmed) 0))
                (condition-case nil
                    (car (read-from-string trimmed))
                  (error nil))))))))))

(defun hermes--delete-raw-drawer-here ()
  "Delete the `:HERMES_RAW:' drawer in the subtree at point, if any.
Point must be on a heading.  Returns non-nil if a drawer was deleted."
  (let ((subtree-end (save-excursion (org-end-of-subtree t t)))
        (deleted nil))
    (save-excursion
      (when (re-search-forward "^:HERMES_RAW:[ \t]*$" subtree-end t)
        (let ((start (line-beginning-position)))
          (when (re-search-forward "^:END:[ \t]*$" subtree-end t)
            (let ((end (min (1+ (line-end-position)) (point-max))))
              (delete-region start end)
              (setq deleted t))))))
    deleted))

;;;###autoload
(defun hermes-migrate-v1-to-v2 ()
  "Migrate the current buffer from `:HERMES_RAW:' to `:HERMES_META:' format.
For every turn-level heading carrying a v1 raw drawer:
  1. Reconstruct the `hermes-message' from the raw plist.
  2. Set `:HERMES_KIND:' and `:HERMES_TIMESTAMP:' properties.
  3. Delete the raw drawer.
  4. Insert a `:HERMES_META:' drawer (omitted if no metadata).

Idempotent: turns without a raw drawer are skipped.  Modifies the buffer
in place; save manually after verification."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org-mode buffer"))
  (let ((turn-level (1+ (or (and (boundp 'hermes--container-level)
                                 hermes--container-level)
                            0)))
        (count 0))
    (org-map-entries
     (lambda ()
       (when (= turn-level (org-current-level))
         (let ((raw (save-excursion (hermes--extract-raw-drawer-v1))))
           (when raw
             (let* ((msg       (hermes--plist-to-message raw))
                    (kind      (hermes-message-kind msg))
                    (timestamp (hermes-message-timestamp msg)))
               (when kind
                 (org-set-property "HERMES_KIND"
                                   (upcase (symbol-name kind))))
               (when (and timestamp (stringp timestamp))
                 (org-set-property "HERMES_TIMESTAMP" timestamp))
               (hermes--delete-raw-drawer-here)
               (save-excursion
                 (goto-char (org-end-of-subtree t t))
                 (unless (bolp) (insert "\n"))
                 (hermes--insert-meta-drawer msg))
               (cl-incf count))))))
     nil nil 'file)
    (message "hermes: migrated %d turn(s) from v1 to v2" count)
    count))

(provide 'hermes-migrate)
;;; hermes-migrate.el ends here
