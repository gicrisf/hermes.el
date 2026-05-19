;;; hermes-skin.el --- Apply gateway skin colors to faces -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; The gateway emits a skin payload on `gateway.ready' (and `skin.changed')
;; with a `colors' hash whose keys come from `hermes-agent/hermes_cli/
;; skin_engine.py'.  We expose four buffer-tinted faces and remap them
;; (buffer-locally) to skin colors on every state change that updates the
;; skin slot.  Renderers tag each headline with the appropriate face so
;; user / assistant / tool / system lines are visually distinct.

;;; Code:

(require 'face-remap)
(require 'hermes-state)

;;;; Faces

(defface hermes-user-face
  '((t :inherit org-level-1 :weight bold))
  "Face for the `* user' headline."
  :group 'hermes)

(defface hermes-assistant-face
  '((t :inherit org-level-1 :weight bold))
  "Face for the `* assistant' headline."
  :group 'hermes)

(defface hermes-system-face
  '((t :inherit org-level-1 :weight bold :slant italic))
  "Face for the `* system' (error) headline."
  :group 'hermes)

(defface hermes-tool-face
  '((t :inherit org-level-2))
  "Face for tool subtree headlines."
  :group 'hermes)

(defface hermes-tool-running-face
  '((t :inherit warning :weight bold))
  "Face for the RUNNING TODO keyword on tool headings."
  :group 'hermes)

(defface hermes-tool-done-face
  '((t :inherit success :weight bold))
  "Face for the DONE TODO keyword on tool headings."
  :group 'hermes)

(defface hermes-tool-error-face
  '((t :inherit error :weight bold))
  "Face for the ERROR TODO keyword on tool headings."
  :group 'hermes)

(defface hermes-bench-face
  '((((class color) (background dark))
     :background "#1c1f26" :extend t)
    (((class color) (background light))
     :background "#f4f4f4" :extend t)
    (t :inherit shadow))
  "Background tint for the live (in-flight) assistant turn region.
Lets the user see at a glance which part of the buffer is being
re-rendered.  Disappears when the turn commits."
  :group 'hermes)

;;;; Application

(defvar-local hermes-skin--remap-cookies nil
  "Buffer-local list of `face-remap' cookies installed by the skin.")

(defun hermes-skin--get (skin key)
  "Read SKIN.colors.KEY from the skin hash, or nil."
  (when (hash-table-p skin)
    (let ((colors (gethash "colors" skin)))
      (and (hash-table-p colors) (gethash key colors)))))

(defvar hermes-skin-applied-hook nil
  "Hook run after `hermes-skin-apply' finishes.
Each function is called with one argument — the SKIN hash table.
Subscribers should refresh any buffers whose styling depends on the
skin (e.g. side-window backgrounds in other buffers).")

(defun hermes-skin-apply (skin)
  "Apply SKIN (a hash table from gateway.ready) to the current buffer."
  ;; Tear down previous remaps so applying a fresh skin is clean.
  (dolist (c hermes-skin--remap-cookies)
    (face-remap-remove-relative c))
  (setq hermes-skin--remap-cookies nil)
  (let* ((assistant (or (hermes-skin--get skin "response_border")
                        (hermes-skin--get skin "ui_accent")))
         (user      (or (hermes-skin--get skin "prompt")
                        (hermes-skin--get skin "banner_text")))
         (tool      (hermes-skin--get skin "ui_label"))
         (system    (hermes-skin--get skin "ui_warn"))
         (running   (hermes-skin--get skin "ui_accent"))
         (done      (hermes-skin--get skin "ui_label"))
         (errcol    (hermes-skin--get skin "ui_warn"))
         (bench     (hermes-skin--get skin "ui_bench"))
         (remaps (list (cons 'hermes-assistant-face     assistant)
                       (cons 'hermes-user-face          user)
                       (cons 'hermes-tool-face          tool)
                       (cons 'hermes-system-face        system)
                       (cons 'hermes-tool-running-face  running)
                       (cons 'hermes-tool-done-face     done)
                       (cons 'hermes-tool-error-face    errcol))))
    ;; Bench is a background — remap separately so we set :background
    ;; rather than :foreground.
    (when bench
      (push (face-remap-add-relative 'hermes-bench-face :background bench)
            hermes-skin--remap-cookies))
    (dolist (pair remaps)
      (when (cdr pair)
        (push (face-remap-add-relative (car pair) :foreground (cdr pair))
              hermes-skin--remap-cookies))))
  (run-hook-with-args 'hermes-skin-applied-hook skin))

(defun hermes-skin-watch (old new)
  "State-change hook: re-apply the skin when it changes."
  (let ((os (and old (hermes-state-skin old)))
        (ns (hermes-state-skin new)))
    (when (and ns (not (eq os ns)))
      (hermes-skin-apply ns))))

(provide 'hermes-skin)
;;; hermes-skin.el ends here
