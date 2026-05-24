;;; hermes-evil.el --- Evil keybindings for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Normal-state Evil bindings for `hermes-org-minor-mode' buffers.
;; Works in any Emacs that has Evil installed (vanilla + evil-mode,
;; Spacemacs, Doom).
;;
;; Usage: (require 'hermes-evil)
;;
;; Safe to load before Evil is initialised: the bindings are deferred
;; with `with-eval-after-load' and fire once Evil is available.

;;; Code:

(require 'hermes-mode)

;; Ensure `evil-define-key' macro is available at compile time so
;; byte-compilation in environments without Evil loaded does not
;; fall back to a broken function call.
(eval-when-compile
  (require 'evil nil t))

(with-eval-after-load 'evil
  (evil-define-key 'normal hermes-org-minor-mode-map
    (kbd "C-c C-i") #'hermes-bench-focus
    (kbd "C-c C-k") #'hermes-interrupt-current-session
    (kbd "C-c C-l") #'hermes-compose)
  ;; The comint viewer is a typing surface — start in insert state so
  ;; bare letters flow to the prompt instead of being swallowed by Evil
  ;; normal-state prefix keys (e.g. `g').
  (evil-set-initial-state 'hermes-comint-mode 'insert))

(provide 'hermes-evil)
;;; hermes-evil.el ends here
