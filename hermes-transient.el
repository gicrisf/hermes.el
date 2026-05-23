;;; hermes-transient.el --- Optional Transient UI for Hermes  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Optional Transient popup for Hermes commands.  Load with
;; `(require 'hermes-transient)' after `hermes-mode' is loaded.
;;
;; When loaded, this file binds `C-c C-t' in `hermes-org-minor-mode-map'
;; to the main transient prefix.  In Doom, `hermes-doom.el' additionally
;; binds it under the `SPC h' leader.
;;
;; Safe to load without Transient installed: the prefix definition and
;; keybinding are skipped, leaving the helper commands available.

;;; Code:

(require 'transient nil t)
(require 'hermes-mode)

(defun hermes-transient--in-session-p ()
  "Non-nil when the current buffer has a reachable Hermes session target.
Returns non-nil in:
- `hermes-org-minor-mode' Org buffers inside a `:hermes:' container;
- `hermes-bench-mode' and `hermes-section-mode' buffers (resolved via the
  buffer-local `hermes--current-session-id').
Returns nil in arbitrary buffers and before `session.create' resolves."
  (and (fboundp 'hermes--resolve-session-target)
       (hermes--resolve-session-target)))

(defun hermes-transient--ensure-gateway ()
  "Start the Hermes gateway if it is not currently running.
Idempotent: safe to call when the gateway is already up."
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start)))

(defun hermes-transient--skills-reload ()
  "Reload skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (hermes-skills-reload))

(defun hermes-transient--skills-list ()
  "List skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (hermes-skills-list))

(defun hermes-transient--skills-search ()
  "Search skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (call-interactively #'hermes-skills-search))

(defun hermes-transient--skills-install ()
  "Install a skill, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (call-interactively #'hermes-skills-install))

(defun hermes-transient--new-session ()
  "Interactive wrapper for `hermes-new-session' (which is not a command)."
  (interactive)
  (hermes-new-session))

;; Groups carrying `:if hermes-transient--in-session-p' are hidden when
;; no Hermes session is reachable.  This keeps the popup useful from
;; arbitrary buffers (Session/Skills/Misc only) and from active Hermes
;; sessions (all groups visible).
(when (fboundp 'transient-define-prefix)
  ;;;###autoload
  (transient-define-prefix hermes-transient ()
    "Hermes command dispatch popup.
Shows session commands always; input, config, and session-scoped
skills commands only when a Hermes session is reachable."
    ["Session"
     ("o" "Open / create session" hermes)
     ("n" "New session" hermes-transient--new-session)
     ("l" "Session list" hermes-current-sessions)]

    ["Input" :if hermes-transient--in-session-p
     ("i" "Focus bench" hermes-bench-focus)
     ("c" "Compose" hermes-compose)
     ("k" "Interrupt" hermes-interrupt-current-session)
     ("S" "Steer" hermes-steer)]

    ["Config" :if hermes-transient--in-session-p
     ("m" "Model" hermes-set-model)
     ("f" "Fast mode" hermes-toggle-fast)
     ("r" "Reasoning" hermes-toggle-reasoning)
     ("y" "YOLO" hermes-toggle-yolo)
     ("p" "Personality" hermes-set-personality)
     ("s" "Skin" hermes-set-skin)
     ("t" "Toolsets" hermes-toolsets-toggle)]

    ["Project" :if hermes-transient--in-session-p
     ("d" "Set cwd" hermes-project-set-cwd)
     ("C" "Toggle auto-context" hermes-project-toggle-auto-context)
     ("a" "Attach project file" hermes-project-attach-file)]

    ["Skills"
     ("R" "Reload" hermes-transient--skills-reload)
     ("L" "List" hermes-transient--skills-list)
     ("/" "Search" hermes-transient--skills-search)
     ("I" "Install" hermes-transient--skills-install)
     ("U" "Uninstall" hermes-skills-uninstall :if hermes-transient--in-session-p)]

    ["Misc"
     ("v" "View log" hermes-view-log)])

  ;;;###autoload
  (with-eval-after-load 'hermes-mode
    (define-key hermes-org-minor-mode-map (kbd "C-c C-t") #'hermes-transient)))

(provide 'hermes-transient)
;;; hermes-transient.el ends here
