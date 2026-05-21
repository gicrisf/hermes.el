;;; hermes-doom.el --- Doom Emacs leader prefix for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Doom-specific glue: the `SPC h' leader prefix plus a one-liner
;; require of every satellite a Doom user is expected to have
;; (Evil, Transient, desktop notifications).
;;
;; Usage: (require 'hermes-doom)
;;
;; The leader-prefix block is gated on `doom-leader-map' so this file
;; is a silent no-op on non-Doom Emacsen.

;;; Code:

(require 'hermes-mode)
(require 'hermes-evil)
(require 'hermes-transient)
(require 'hermes-notifications)

;; ── Leader prefix: SPC h ──────────────────────────────────────────────────

(when (bound-and-true-p doom-leader-map)
  (define-prefix-command 'hermes-leader-map)
  (define-key doom-leader-map (kbd "h") 'hermes-leader-map)
  (define-key hermes-leader-map (kbd "h") #'hermes)
  (define-key hermes-leader-map (kbd "s") #'hermes)
  (define-key hermes-leader-map (kbd "i") #'hermes)
  (define-key hermes-leader-map (kbd "n") #'hermes-new-session)
  (define-key hermes-leader-map (kbd "c") #'hermes-compose)
  (define-key hermes-leader-map (kbd "l") #'hermes-current-sessions)
  (define-key hermes-leader-map (kbd "g") #'hermes)
  (define-key hermes-leader-map (kbd "k") #'hermes-interrupt-everywhere)
  (define-key hermes-leader-map (kbd "m") #'hermes-set-model)
  (define-key hermes-leader-map (kbd "f") #'hermes-toggle-fast)
  (define-key hermes-leader-map (kbd "r") #'hermes-toggle-reasoning)
  (define-key hermes-leader-map (kbd "y") #'hermes-toggle-yolo)
  (define-key hermes-leader-map (kbd "t") #'hermes-toolsets-toggle)
  (define-key hermes-leader-map (kbd "S") #'hermes-steer)
  ;; Skills sub-prefix: `S' is taken by `hermes-steer'; use `K' (sKills).
  (define-prefix-command 'hermes-skills-leader-map)
  (define-key hermes-leader-map (kbd "K") 'hermes-skills-leader-map)
  (define-key hermes-skills-leader-map (kbd "r") #'hermes-skills-reload)
  (define-key hermes-skills-leader-map (kbd "l") #'hermes-skills-list)
  (define-key hermes-skills-leader-map (kbd "s") #'hermes-skills-search)
  (define-key hermes-skills-leader-map (kbd "i") #'hermes-skills-install)
  (define-key hermes-skills-leader-map (kbd "u") #'hermes-skills-uninstall)
  (when (fboundp 'hermes-transient)
    (define-key hermes-leader-map (kbd ".") #'hermes-transient)))

;; ── Global helpers ────────────────────────────────────────────────────────

(defun hermes-interrupt-everywhere ()
  "Interrupt the primary session from any buffer."
  (interactive)
  (let ((buf (hermes--primary-session-buffer)))
    (if buf
        (with-current-buffer buf (hermes-interrupt))
      (user-error "No primary Hermes session"))))

(provide 'hermes-doom)
;;; hermes-doom.el ends here
