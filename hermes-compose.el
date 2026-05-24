;;; hermes-compose.el --- Multi-line input composer -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `C-c C-l' from a Hermes session buffer pops a `*hermes-compose*' buffer
;; in `org-mode'.  Edit freely; `C-c C-c' sends the contents through the
;; usual `hermes-send' (so reconnect, queue and history all apply);
;; `C-c C-k' cancels.  The compose buffer is killed on send/cancel.

;;; Code:

(require 'org)

(declare-function hermes-send "hermes-input" (text))

(defvar-local hermes-compose--target nil
  "The Hermes conversation buffer this composer sends to.")

(defvar hermes-compose-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'hermes-compose-send)
    (define-key m (kbd "C-c C-k") #'hermes-compose-cancel)
    m)
  "Keymap for `hermes-compose-mode'.")

(define-minor-mode hermes-compose-mode
  "Minor mode for composing multi-line input to a Hermes session."
  :lighter " HermesC"
  :keymap hermes-compose-mode-map)

;;;###autoload
(defun hermes-compose ()
  "Pop a `*hermes-compose*' buffer for multi-line input to the current session."
  (interactive)
  (unless (or (bound-and-true-p hermes-org-minor-mode)
              (derived-mode-p 'hermes-comint-mode)
              (derived-mode-p 'hermes-section-mode))
    (user-error "Not in a Hermes buffer"))
  (let ((target (current-buffer))
        (buf (get-buffer-create "*hermes-compose*")))
    (with-current-buffer buf
      (org-mode)
      (hermes-compose-mode 1)
      (setq hermes-compose--target target)
      (erase-buffer)
      (setq header-line-format
            (concat " Hermes compose · "
                    (propertize "C-c C-c" 'face 'help-key-binding) " send · "
                    (propertize "C-c C-k" 'face 'help-key-binding) " cancel")))
    ;; `pop-to-buffer-same-window' is the recommended replacement for
    ;; `switch-to-buffer' in elisp.  It guarantees the new buffer is in the
    ;; selected window and ignores popup-routing rules (notably Doom's
    ;; `+popup-mode' which can steal focus and leave keystrokes hitting
    ;; the previous buffer — `*doom-hermes*' is `special-mode' so typing
    ;; into it is silently swallowed).
    (pop-to-buffer-same-window buf)))

(defun hermes-compose-send ()
  "Send the buffer contents to the target session, then kill the composer."
  (interactive)
  (let ((target hermes-compose--target)
        (text (string-trim (buffer-substring-no-properties
                            (point-min) (point-max))))
        (buf (current-buffer)))
    (unless (buffer-live-p target)
      (user-error "Target session buffer is gone"))
    (when (string-empty-p text)
      (user-error "Nothing to send"))
    (with-current-buffer target
      (hermes-send text))
    (kill-buffer buf)))

(defun hermes-compose-cancel ()
  "Discard the composer without sending."
  (interactive)
  (kill-buffer))

(provide 'hermes-compose)
;;; hermes-compose.el ends here
