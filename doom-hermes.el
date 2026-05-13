;;; doom-hermes.el --- Evil integration for Hermes, loadable from Doom config
;;; Load from ~/.config/doom/config.el:
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
  (define-key hermes-leader-map (kbd "d") #'hermes-dashboard-show)
  (define-key hermes-leader-map (kbd "s") #'hermes-sessions)
  (define-key hermes-leader-map (kbd "n") #'hermes)
  (define-key hermes-leader-map (kbd "i") #'hermes-dashboard-send)
  (define-key hermes-leader-map (kbd "k") #'hermes-dashboard-interrupt)
  (define-key hermes-leader-map (kbd "c") #'hermes-dashboard-compose)
  (define-key hermes-leader-map (kbd "g") #'hermes-dashboard-go-primary))

(defun hermes-dashboard-go-primary ()
  "Switch to the primary Hermes session buffer."
  (interactive)
  (let ((buf (hermes-dashboard--primary-buffer)))
    (if buf
        (pop-to-buffer-same-window buf)
      (user-error "No primary Hermes session"))))
