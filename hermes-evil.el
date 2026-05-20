;;; hermes-evil.el --- Evil keybindings for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Normal-state Evil bindings for `hermes-mode' buffers.  Works in any
;; Emacs that has Evil installed (vanilla + evil-mode, Spacemacs, Doom).
;;
;; Usage: (require 'hermes-evil)
;;
;; Safe to load before Evil is initialised: the bindings are deferred
;; with `with-eval-after-load' and fire once Evil is available.

;;; Code:

(require 'hermes-mode)

(with-eval-after-load 'evil
  (evil-define-key 'normal hermes-mode-map
    (kbd "C-c C-i") #'hermes-send-or-focus-bench
    (kbd "C-c C-k") #'hermes-interrupt
    (kbd "C-c C-l") #'hermes-compose))

(provide 'hermes-evil)
;;; hermes-evil.el ends here
