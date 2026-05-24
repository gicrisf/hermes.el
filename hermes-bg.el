;;; hermes-bg.el --- Background task buffers for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Lightweight mode for background task results.  No RPC connection,
;; no bench, no streaming.  Content is written atomically on
;; `background.complete' and the user may save the buffer manually.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'tabulated-list)
(require 'hermes-state)

(declare-function hermes--lookup-buffer "hermes-session" (session-id))

(defface hermes-bg-heading-face
  '((t :inherit org-level-1 :weight bold))
  "Face for the background task heading."
  :group 'hermes)

(defvar hermes-bg-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "RET") #'hermes-bg-list-visit-task)
    (define-key map (kbd "k")   #'hermes-bg-list-kill-task)
    map)
  "Keymap for `hermes-bg-list-mode'.
Inherits from `tabulated-list-mode-map' with RET to visit and k to kill.")

(define-derived-mode hermes-bg-mode org-mode "Hermes-BG"
  "Major mode for background task result buffers.
Derived from `org-mode' with no RPC, bench, or streaming support.
Content is written atomically on task completion."
  (setq-local buffer-read-only t)
  (setq-local truncate-lines nil))

(define-derived-mode hermes-bg-list-mode tabulated-list-mode "Hermes-BG-List"
  "Major mode for the background task listing buffer.
RET visits the task buffer; k kills it.")

(defun hermes-bg--list-for-sid (sid)
  "Pop a tabulated list of background tasks for session SID."
  (let* ((parent (and sid (hermes--lookup-buffer sid)))
         (state  (and sid (gethash sid hermes--sessions)))
         (tasks  (and state (hermes-state-bg-tasks state)))
         (buf    (get-buffer-create (format "*hermes-bg-list:%s*" (or sid "?")))))
    (with-current-buffer buf
      (hermes-bg-list-mode)
      (setq tabulated-list-format
            [("Task"   8  t)
             ("Status" 10 t)
             ("Prompt" 50 t)
             ("Buffer" 30 t)])
      (setq tabulated-list-entries
            (when (vectorp tasks)
              (cl-loop for i from 0 below (length tasks)
                       for task = (aref tasks i)
                       collect
                       (list i
                             (vector
                              (or (hermes-bg-task-task-id task) "")
                              (symbol-name (or (hermes-bg-task-status task) 'unknown))
                              (or (hermes-bg-task-prompt task) "")
                              (or (hermes-bg-task-buffer-name task) ""))))))
      (tabulated-list-init-header)
      (tabulated-list-print)
      (setq-local revert-buffer-function
                  (lambda (&rest _) (hermes-bg--list-for-sid sid))))
    (pop-to-buffer buf)))

(defun hermes-bg-list-visit-task ()
  "Visit the background task buffer at point in the list."
  (interactive)
  (let* ((entry (tabulated-list-get-entry))
         (bname (and entry (aref entry 3))))
    (if (and bname (not (string-empty-p bname))
             (get-buffer bname))
        (pop-to-buffer (get-buffer bname))
      (message "hermes: no buffer for this task"))))

(defun hermes-bg-list-kill-task ()
  "Kill the background task buffer at point in the list."
  (interactive)
  (let* ((entry (tabulated-list-get-entry))
         (bname (and entry (aref entry 3))))
    (when (and bname (not (string-empty-p bname))
               (get-buffer bname))
      (kill-buffer (get-buffer bname))
      (revert-buffer))))

(defun hermes-bg-kill-all (sid)
  "Kill all live background task buffers for session SID."
  (when sid
    (let ((prefix (format "*hermes-bg:%s:" sid)))
      (dolist (buf (buffer-list))
        (when (and (buffer-live-p buf)
                   (with-current-buffer buf
                     (derived-mode-p 'hermes-bg-mode))
                   (string-prefix-p prefix (buffer-name buf)))
          (kill-buffer buf))))))

(provide 'hermes-bg)
;;; hermes-bg.el ends here
