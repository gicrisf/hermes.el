;;; doom-hermes.el --- Evil keybindings and leader prefix for Hermes
;;; Load from ~/.config/doom/config.el:
;;;   (load-file "~/Projects/emacs-hermes/doom-hermes.el")

(add-to-list 'load-path "~/Projects/emacs-hermes")

(require 'hermes-mode)

;; ── hermes-mode: normal-state C-c bindings (keep org navigation) ──────────

(with-eval-after-load 'hermes-mode
  (evil-define-key 'normal hermes-mode-map
    (kbd "C-c C-i") #'hermes-send-or-focus-bench
    (kbd "C-c C-k") #'hermes-interrupt
    (kbd "C-c C-l") #'hermes-compose))

;; ── Leader prefix: SPC h ──────────────────────────────────────────────────

(when (bound-and-true-p doom-leader-map)
  (define-prefix-command 'hermes-leader-map)
  (define-key doom-leader-map (kbd "h") 'hermes-leader-map)
  (define-key hermes-leader-map (kbd "h") #'hermes)
  (define-key hermes-leader-map (kbd "s") #'hermes)
  (define-key hermes-leader-map (kbd "i") #'hermes)
  (define-key hermes-leader-map (kbd "n") #'hermes-new-session)
  (define-key hermes-leader-map (kbd "c") #'hermes-compose)
  (define-key hermes-leader-map (kbd "l") #'hermes-sessions)
  (define-key hermes-leader-map (kbd "g") #'hermes)
  (define-key hermes-leader-map (kbd "k") #'hermes-interrupt-everywhere)
  (define-key hermes-leader-map (kbd "m") #'hermes-set-model)
  (define-key hermes-leader-map (kbd "f") #'hermes-toggle-fast)
  (define-key hermes-leader-map (kbd "r") #'hermes-toggle-reasoning)
  (define-key hermes-leader-map (kbd "y") #'hermes-toggle-yolo)
  (define-key hermes-leader-map (kbd "t") #'hermes-toolsets-toggle)
  (define-key hermes-leader-map (kbd "S") #'hermes-steer))

;; ── Global helpers ────────────────────────────────────────────────────────

(defun hermes-interrupt-everywhere ()
  "Interrupt the primary session from any buffer."
  (interactive)
  (let ((buf (hermes--primary-session-buffer)))
    (if buf
        (with-current-buffer buf (hermes-interrupt))
      (user-error "No primary Hermes session"))))
