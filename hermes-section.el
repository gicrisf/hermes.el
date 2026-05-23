;;; hermes-section.el --- magit-section conversation viewer  -*- lexical-binding: t; -*-

;;; Commentary:
;;
;; Read-only magit-section view over the canonical `turns' vector of a
;; Hermes session.  Projects state from `hermes--sessions'; never mutates
;; it.  See plans/04-section-mode.md.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'magit-section)
(require 'hermes-state)
(require 'hermes-rpc)

(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes-new-session "hermes-mode" (&optional callback))
(declare-function hermes--parse-buffer-messages "hermes-mode" ())
(declare-function hermes-send "hermes-input" (text))
(declare-function hermes-interrupt-current-session "hermes-mode" ())

;;;; Faces

(defface hermes-section-face-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user turn heading labels.")

(defface hermes-section-face-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant turn heading labels.")

(defface hermes-section-face-system
  '((t :inherit font-lock-builtin-face))
  "Face for system turn heading labels.")

;;;; Section classes

(defclass hermes-section-turn-section (magit-section)
  ((selective-highlight :initform t))
  "Base class for conversation turn sections.")

(defclass hermes-section-user-section
  (hermes-section-turn-section) ()
  "A user turn section.")

(defclass hermes-section-assistant-section
  (hermes-section-turn-section) ()
  "An assistant turn section.")

(defclass hermes-section-system-section
  (hermes-section-turn-section) ()
  "A system turn section.")

;;;; Buffer-local snapshot

(defvar-local hermes-section--turns-snapshot nil
  "Last-seen `turns' vector for eq-based change detection.")

;;;; Text helpers

(defun hermes-section--message-text (msg)
  "Concatenate text and reasoning segments of MSG into a string."
  (let ((segs (hermes-message-segments msg))
        (parts nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let* ((seg  (aref segs i))
               (type (hermes-segment-type seg))
               (c    (hermes-segment-content seg)))
          (when (and (memq type '(text reasoning))
                     (stringp c)
                     (> (length c) 0))
            (push c parts)))))
    (if parts
        (mapconcat #'identity (nreverse parts) "")
      "(empty)")))

(defun hermes-section--excerpt (text n)
  "Return first non-blank line of TEXT, newlines collapsed, truncated to N chars."
  (let* ((s (replace-regexp-in-string "[ \t\n\r]+" " " (or text "")))
         (s (string-trim s)))
    (if (> (length s) n)
        (concat (substring s 0 n) "…")
      s)))

(defun hermes-section--format-body (text)
  "Strip Org artifacts from TEXT and return plain text."
  (with-temp-buffer
    (insert (or text ""))
    (goto-char (point-min))
    ;; Property drawers
    (while (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
      (replace-match ""))
    (goto-char (point-min))
    ;; Other drawers
    (while (re-search-forward "^[ \t]*:[A-Za-z_]+:[ \t]*\n\\(?:.*\n\\)*?[ \t]*:END:[ \t]*\n?" nil t)
      (replace-match ""))
    (goto-char (point-min))
    ;; Org comments
    (while (re-search-forward "^[ \t]*#\\+[A-Za-z_]+:.*\n?" nil t)
      (replace-match ""))
    (goto-char (point-min))
    ;; #+begin_…/#+end_… block markers (keep body)
    (while (re-search-forward "^[ \t]*#\\+\\(begin\\|end\\)_[A-Za-z0-9_-]+.*\n?" nil t)
      (replace-match ""))
    (string-trim-right (buffer-string))))

;;;; Refresh pipeline

(defun hermes-section--insert-turn (msg)
  "Insert MSG as a magit section at point."
  (let* ((kind  (hermes-message-kind msg))
         (text  (hermes-section--message-text msg))
         (class (pcase kind
                  ('user      'hermes-section-user-section)
                  ('assistant 'hermes-section-assistant-section)
                  (_          'hermes-section-system-section)))
         (face  (pcase kind
                  ('user      'hermes-section-face-user)
                  ('assistant 'hermes-section-face-assistant)
                  (_          'hermes-section-face-system)))
         (label (pcase kind
                  ('user      "U")
                  ('assistant "A")
                  (_          "S")))
         (id    (or (hermes-message-id msg)
                    (format "anon-%d" (sxhash-equal msg))))
         (hide  (eq kind 'user)))
    (magit-insert-section ((eval class) id hide)
      (magit-insert-heading
        (propertize label 'face face)
        ": "
        (hermes-section--excerpt text 75))
      (magit-insert-section-body
        (insert (hermes-section--format-body text))
        (unless (bolp) (insert "\n"))
        (insert "\n")))))

(defun hermes-section--rebuild (state)
  "Erase the current buffer and rebuild sections from STATE."
  (let ((inhibit-read-only t)
        (turns (hermes-state-turns state)))
    (setq hermes-section--turns-snapshot turns)
    (save-excursion
      (erase-buffer)
      (magit-insert-section (hermes-section-turn-section nil)
        (if (zerop (length turns))
            (insert "(No messages yet)\n")
          (seq-doseq (msg turns)
            (hermes-section--insert-turn msg)))))
    (when magit-root-section
      (magit-section-show magit-root-section))))

(defun hermes-section--refresh (_old new)
  "Rebuild the conversation buffer when `turns' changes.
Routes to the conversation buffer for the currently dispatched
session via `hermes--on-session-buffer'."
  (hermes--on-session-buffer hermes-section--buffers
    (unless (eq (hermes-state-turns new)
                hermes-section--turns-snapshot)
      (hermes-section--rebuild new))))

(defun hermes-section-refresh ()
  "Manually rebuild the current conversation buffer from state."
  (interactive)
  (let ((state (hermes--state-slot-read hermes--current-session-id)))
    (when state
      (setq hermes-section--turns-snapshot nil) ;; force rebuild
      (hermes-section--rebuild state))))

;;;; Inspect

(defun hermes-section-inspect-turn-at-point ()
  "Show the raw `hermes-message' struct at point in a temp buffer."
  (interactive)
  (let* ((sec (magit-current-section))
         (id  (and sec (oref sec value)))
         (state (hermes--state-slot-read hermes--current-session-id))
         (turns (and state (hermes-state-turns state)))
         (msg (and id turns
                   (seq-find (lambda (m) (equal id (hermes-message-id m)))
                             turns))))
    (if (not msg)
        (message "No turn at point")
      (let ((buf (get-buffer-create "*hermes-turn-inspect*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (emacs-lisp-mode)
            (pp msg (current-buffer))))
        (pop-to-buffer buf)))))

;;;; Detach

(defun hermes-section--detach ()
  "Detach this buffer from the conversation registry on kill."
  (when (and hermes--current-session-id
              (eq (current-buffer)
                  (gethash hermes--current-session-id
                           hermes-section--buffers)))
    (remhash hermes--current-session-id hermes-section--buffers)))

;;;; Major mode + keymap

(defvar hermes-section-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m magit-section-mode-map)
    (define-key m (kbd "g") #'hermes-section-refresh)
    (define-key m (kbd "i") #'hermes-send)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt-current-session)
    (define-key m (kbd "C-c C-e") #'hermes-section-export)
    (define-key m (kbd "q") #'quit-window)
    (define-key m (kbd "RET") #'hermes-section-inspect-turn-at-point)
    m)
  "Keymap for `hermes-section-mode'.")

(define-derived-mode hermes-section-mode magit-section-mode
  "Hermes-Section"
  "Magit-section conversation viewer for Hermes sessions.
Reads from `turns' in the global `hermes--sessions' table.
Read-only; input via `hermes-send' (minibuffer)."
  (setq-local buffer-read-only t)
  (setq-local magit-section-cache-visibility t)
  (add-hook 'kill-buffer-hook #'hermes-section--detach nil t)
  (add-hook 'hermes-state-change-hook
            #'hermes-section--refresh t))

;;;; Open + entry point

(defun hermes-section--open (sid &optional buf)
  "Open a magit conversation buffer for session SID.
If BUF is non-nil it is used as the host buffer (already created
by `hermes-new-session'); otherwise a fresh buffer is generated."
  (let ((buf (or buf (generate-new-buffer
                      (format "*hermes-section:%s*" sid)))))
    (with-current-buffer buf
      (hermes-section-mode)
      (setq-local hermes--current-session-id sid)
      (puthash sid buf hermes-section--buffers)
      (let ((state (hermes--state-slot-read sid)))
        (when state
          (hermes-section--rebuild state))))
    (pop-to-buffer buf)
    buf))

;;;###autoload
(defun hermes-section (&optional arg)
  "Open a magit-section conversation viewer.

With prefix ARG, always create a new session.  Otherwise reuse the
most recently active session if one exists.  If no live sessions
exist, create a fresh one (starting the gateway if needed)."
  (interactive "P")
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ((derived-mode-p 'hermes-section-mode)
    (message "Already in a Hermes conversation buffer"))
   ((and (not arg) (hermes--session-exists-p))
    (hermes-section--open (hermes--most-recent-session-id)))
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf))))))))

;;;; Export

(defun hermes-section--org-insert-turn (msg)
  "Insert MSG as a simplified Org heading at point."
  (let ((kind (hermes-message-kind msg))
        (text (hermes-section--message-text msg)))
    (pcase kind
      ('user      (insert "* User\n"))
      ('assistant (insert "* Assistant\n"))
      (_          (insert "* System\n")))
    (insert text)
    (unless (bolp) (insert "\n"))
    (insert "\n")))

(defun hermes-section-export (file)
  "Export the current conversation to an Org FILE."
  (interactive "FExport to: ")
  (let* ((sid   hermes--current-session-id)
         (state (and sid (hermes--state-slot-read sid)))
         (turns (and state (hermes-state-turns state))))
    (unless turns
      (user-error "No session/state for current buffer"))
    (with-temp-buffer
      (org-mode)
      (insert "#+TITLE: Hermes conversation export\n\n")
      (seq-doseq (msg turns)
        (hermes-section--org-insert-turn msg))
      (write-file file))
    (message "Exported %d turns to %s" (length turns) file)))

;;;; Fork

(defun hermes-section-fork-from-org (buffer)
  "Create a new session whose `turns' are parsed from org BUFFER."
  (interactive (list (read-buffer "Fork from org buffer: " nil t)))
  (let ((msgs (with-current-buffer (get-buffer buffer)
                (hermes--parse-buffer-messages))))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p) (hermes-rpc-start))
    (hermes-new-session
     (lambda (buf)
       (when buf
         (let ((v   (apply #'vector msgs))
               (sid (buffer-local-value
                     'hermes--current-session-id buf)))
           (hermes-dispatch (cons :turns-load (list :turns v)) sid)
           (hermes-section--open sid)))))))

(provide 'hermes-section)

;;; hermes-section.el ends here
