;;; doom-hermes.el --- Evil keybindings and leader prefix for Hermes
;;; Load from ~/.config/doom/config.el AFTER doom-dashboard-hermes.el:
;;;   (load-file "~/Projects/emacs-hermes/doom-dashboard-hermes.el")
;;;   (doom-dashboard-hermes-setup)
;;;   (load-file "~/Projects/emacs-hermes/doom-hermes.el")

(add-to-list 'load-path "~/Projects/emacs-hermes")

;; ── hermes-mode: normal-state C-c bindings (keep org navigation) ──────────

(with-eval-after-load 'hermes-mode
  (evil-define-key 'normal hermes-mode-map
    (kbd "C-c C-i") #'hermes-send
    (kbd "C-c C-k") #'hermes-interrupt
    (kbd "C-c C-l") #'hermes-compose))

;; ── Leader prefix: SPC h ──────────────────────────────────────────────────

(when (bound-and-true-p doom-leader-map)
  (define-prefix-command 'hermes-leader-map)
  (define-key doom-leader-map (kbd "h") 'hermes-leader-map)
  (define-key hermes-leader-map (kbd "d") #'doom-dashboard-hermes)
  (define-key hermes-leader-map (kbd "s") #'doom-dashboard-hermes-start)
  (define-key hermes-leader-map (kbd "n") #'doom-dashboard-hermes-new)
  (define-key hermes-leader-map (kbd "i") #'doom-dashboard-hermes-start)
  (define-key hermes-leader-map (kbd "c") #'doom-dashboard-hermes-compose)
  (define-key hermes-leader-map (kbd "l") #'hermes-sessions)
  (define-key hermes-leader-map (kbd "g") #'doom-dashboard-hermes-go-primary)
  (define-key hermes-leader-map (kbd "k") #'hermes-interrupt-everywhere))

;; ── Global helpers ────────────────────────────────────────────────────────

(defun doom-dashboard-hermes-go-primary ()
  "Switch to the primary session buffer."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (if buf (pop-to-buffer-same-window buf)
      (user-error "No primary Hermes session"))))

(defun hermes-interrupt-everywhere ()
  "Interrupt the primary session from any buffer."
  (interactive)
  (let ((buf (doom-dashboard-hermes--primary-buffer)))
    (if buf
        (with-current-buffer buf (hermes-interrupt))
      (user-error "No primary Hermes session"))))
