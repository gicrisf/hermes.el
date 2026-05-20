;;; hermes-doom-theme.el --- Hermes-inspired dark theme -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi <opencode@s.gr晨曦>
;; Keywords: themes
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A dark, warm Emacs theme based on the Hermes AI agent brand colors.
;; Deep teal background (from the web dashboard) with gold, amber, and
;; bronze accents (from the CLI skin engine).  Designed to work with
;; Doom Emacs (`doom-theme`) and vanilla Emacs (`load-theme`).
;;
;; Palette reference:
;;   Gold       #FFD700 — keywords, banner, cursor, prompts
;;   Amber      #FFBF00 — constants, builtins, secondary accents
;;   Bronze     #CD7F32 — types, borders, panel accents
;;   Cornsilk   #FFF8DC — body text (foreground)
;;   Dark teal  #041c1c — background (from Hermes web dashboard)
;;
;; Load in Doom with (setq doom-theme 'hermes-doom).
;; In vanilla: M-x load-theme RET hermes-doom RET

;;; Code:

(deftheme hermes-doom
  "Hermes-inspired dark theme — deep teal with gold accents.")


;;; Colour palette

(let ((bg       "#041c1c")
      (bg-alt   "#0a2626")
      (bg-hl    "#0f2e2e")
      (fg       "#FFF8DC")
      (fg-alt   "#E8D5A0")
      (gold     "#FFD700")
      (amber    "#FFBF00")
      (bronze   "#CD7F32")
      (muted    "#8B7355")
      (red      "#FF6B6B")
      (green    "#4EC9B0")
      (yellow   "#FFD93D")
      (blue     "#7EC8E3")
      (magenta  "#D4A0E5")
      (cyan     "#4EC9B0")
      (region   "#CD7F3240")
      (cursor   "#FFD700"))

  (custom-theme-set-faces
   'hermes-doom

   ;; --- Base ---
   `(default ((t (:foreground ,fg :background ,bg))))
   `(cursor ((t (:background ,cursor))))
   `(region ((t (:background ,region))))
   `(fringe ((t (:background ,bg-alt))))
   `(hl-line ((t (:background ,bg-hl))))
   `(line-number ((t (:foreground ,muted :background ,bg))))
   `(line-number-current-line ((t (:foreground ,gold :background ,bg-hl))))
   `(minibuffer-prompt ((t (:foreground ,gold :weight bold))))
   `(escape-glyph ((t (:foreground ,amber))))
   `(shadow ((t (:foreground ,muted))))
   `(vertical-border ((t (:foreground ,bronze))))

   ;; --- Font Lock ---
   `(font-lock-keyword-face ((t (:foreground ,gold :weight bold))))
   `(font-lock-builtin-face ((t (:foreground ,amber))))
   `(font-lock-constant-face ((t (:foreground ,amber))))
   `(font-lock-type-face ((t (:foreground ,bronze))))
   `(font-lock-string-face ((t (:foreground ,fg-alt))))
   `(font-lock-doc-face ((t (:foreground ,muted))))
   `(font-lock-comment-face ((t (:foreground ,muted :slant italic))))
   `(font-lock-function-name-face ((t (:foreground ,fg))))
   `(font-lock-variable-name-face ((t (:foreground ,fg))))
   `(font-lock-preprocessor-face ((t (:foreground ,gold))))
   `(font-lock-negation-char-face ((t (:foreground ,red))))

   ;; --- Mode line ---
   `(mode-line ((t (:background ,bg-alt :foreground ,fg))))
   `(mode-line-inactive ((t (:background ,bg :foreground ,muted))))
   `(mode-line-highlight ((t (:box (:color ,bronze :line-width 1)))))

   ;; --- Search ---
   `(isearch ((t (:foreground ,bg :background ,gold))))
   `(lazy-highlight ((t (:foreground ,bg :background ,amber))))
   `(query-replace ((t (:foreground ,bg :background ,gold))))

   ;; --- Status ---
   `(success ((t (:foreground ,green))))
   `(error ((t (:foreground ,red :weight bold))))
   `(warning ((t (:foreground ,yellow :weight bold))))

   ;; --- Links ---
   `(link ((t (:foreground ,blue :underline t))))
   `(link-visited ((t (:foreground ,magenta :underline t))))

   ;; --- Widget / button ---
   `(button ((t (:underline t :foreground ,gold))))
   `(widget-field ((t (:background ,bg-alt :box (:color ,bronze :line-width 1)))))
   `(widget-button ((t (:foreground ,gold :weight bold))))

   ;; --- Header line ---
   `(header-line ((t (:background ,bg-alt :foreground ,fg))))

   ;; --- Org mode ---
   `(org-level-1 ((t (:foreground ,gold :weight bold :height 1.2))))
   `(org-level-2 ((t (:foreground ,amber))))
   `(org-level-3 ((t (:foreground ,bronze))))
   `(org-level-4 ((t (:foreground ,fg))))
   `(org-done ((t (:foreground ,green))))
   `(org-todo ((t (:foreground ,red :weight bold))))
   `(org-date ((t (:foreground ,blue))))

   ;; --- Dired ---
   `(dired-directory ((t (:foreground ,gold :weight bold))))
   `(dired-flagged ((t (:foreground ,red))))

   ;; --- Completion (company/corfu) ---
   `(company-tooltip ((t (:background ,bg-alt :foreground ,fg))))
   `(company-tooltip-selection ((t (:background ,region))))
   `(company-tooltip-common ((t (:foreground ,gold))))
   `(company-scrollbar-bg ((t (:background ,bg))))
   `(company-scrollbar-fg ((t (:background ,bronze))))

   ;; --- Vertico ---
   `(vertico-current ((t (:background ,bg-hl :foreground ,gold))))

   ;; --- Which-key ---
   `(which-key-key-face ((t (:foreground ,gold))))
   `(which-key-group-description-face ((t (:foreground ,amber))))
   `(which-key-command-description-face ((t (:foreground ,fg))))

   ;; --- Ivy / Counsel ---
   `(ivy-current-match ((t (:background ,bg-hl :foreground ,gold))))
   `(ivy-minibuffer-match-face-1 ((t (:background ,region))))
   `(ivy-minibuffer-match-face-2 ((t (:background ,region :foreground ,gold))))

   ;; --- Doom modeline ---
   `(doom-modeline-bar ((t (:background ,gold))))
   `(doom-modeline-project-dir ((t (:foreground ,gold))))
   `(doom-modeline-buffer-path ((t (:foreground ,fg))))
   `(doom-modeline-buffer-modified ((t (:foreground ,amber))))
   `(doom-modeline-panel ((t (:background ,bronze :foreground ,bg))))

   ;; --- Powerline ---
   `(powerline-active1 ((t (:background ,bronze :foreground ,bg))))
   `(powerline-active2 ((t (:background ,bg-hl :foreground ,fg)))))

  (custom-theme-set-variables
   'hermes-doom
   `(ansi-color-names-vector
     [,bg ,red ,green ,yellow ,blue ,magenta ,cyan ,fg])))

;;;###autoload
(when (and (boundp 'custom-theme-load-path) load-file-name)
  (add-to-list 'custom-theme-load-path
               (file-name-as-directory (file-name-directory load-file-name))))

(provide 'hermes-doom-theme)
;;; hermes-doom-theme.el ends here
