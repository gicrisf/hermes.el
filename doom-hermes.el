;;; doom-hermes.el --- Doom-native Hermes dashboard and keybindings
;;; Load from ~/.config/doom/config.el:
;;;   (load-file "~/Projects/emacs-hermes/doom-hermes.el")

(add-to-list 'load-path "~/Projects/emacs-hermes")

;; ─────────────────────────────────────────────────────────────────────────────
;;  Dashboard mode
;; ─────────────────────────────────────────────────────────────────────────────

(defvar +hermes-dashboard-buffer-name "*Hermes*")

(defface +hermes-dashboard-banner
  '((t (:inherit +dashboard-banner))) "Hermes dashboard banner." :group 'hermes)

(defface +hermes-dashboard-label
  '((t (:inherit +dashboard-menu-title))) "Hermes dashboard label." :group 'hermes)

(defface +hermes-dashboard-desc
  '((t (:inherit +dashboard-menu-desc))) "Hermes dashboard key desc." :group 'hermes)

(defface +hermes-dashboard-dim
  '((t (:inherit +dashboard-loaded))) "Hermes dashboard dim text." :group 'hermes)

(defvar +hermes-dashboard-functions
  '(+hermes-dashboard--banner-widget
    +hermes-dashboard--session-widget
    +hermes-dashboard--shortmenu-widget)
  "Hook of widget functions run to compose the Hermes dashboard.")

;; ── Centering helpers ──────────────────────────────────────────────────────

(defun +hermes-dashboard--center-line (line width)
  "Return LINE padded with spaces on the left so its left edge is at WIDTH center.
Centers relative to (window-width)."
  (let* ((w (window-width))
         (line-w (string-width line))
         (block-w width)
         (left-pad (ash (- w block-w) -1))
         (extra-pad (ash (- block-w line-w) -1)))
    (concat (make-string (max 0 (+ left-pad extra-pad)) ?\s) line)))

(defun +hermes-dashboard--block-width (lines)
  "Return the display width of the widest string in LINES."
  (apply #'max (mapcar #'string-width lines)))

;; ── Banner ───────────────────────────────────────────────────────────────────

(defun +hermes-dashboard--banner-widget ()
  (let* ((logo (hermes-dashboard--logo))
         (lines (split-string logo "\n"))
         (w (+hermes-dashboard--block-width lines)))
    (dolist (l lines)
      (insert (+hermes-dashboard--center-line (propertize l 'face '+hermes-dashboard-banner) w) "\n"))
    (insert "\n")))

;; ── Session info ─────────────────────────────────────────────────────────────

(defun +hermes-dashboard--session-widget ()
  (let ((st (hermes-dashboard--primary-state)))
    (insert (+hermes-dashboard--center-line (hermes-dashboard--connection-line) (window-width)) "\n")
    (if (null st)
        (insert (+hermes-dashboard--center-line
                 (propertize "Press SPC h n to start a session"
                             'face '+hermes-dashboard-dim)
                 (window-width))
                "\n")
      (let* ((info (and st (hermes-state-session-info st)))
             (model (and (hash-table-p info) (gethash "model" info)))
             (sid (hermes-state-session-id st))
             (tools (and (hash-table-p info) (gethash "tools" info)))
             (skills (and (hash-table-p info) (gethash "skills" info)))
             (tc (cond ((numberp tools) tools) ((sequencep tools) (length tools)) (t "?")))
             (sc (cond ((numberp skills) skills) ((sequencep skills) (length skills)) (t "?"))))
        (dolist (line (list (hermes-dashboard--connection-line)
                            (propertize (format "Model: %s" (or model "—")) 'face '+hermes-dashboard-label)
                            (propertize (format "Session: %s" (or sid "—")) 'face '+hermes-dashboard-dim)
                            (propertize (format "Tools: %s   Skills: %s" tc sc) 'face '+hermes-dashboard-dim)))
          (insert (+hermes-dashboard--center-line line (window-width)) "\n"))))
    (insert "\n")))

;; ── Shortmenu ──────────────────────────────────────────────────────────────────

(defvar +hermes-dashboard-menu-sections
  '((:label "Send"        :action hermes-dashboard-send)
    (:label "Interrupt"   :action hermes-dashboard-interrupt)
    (:label "Compose"     :action hermes-dashboard-compose)
    (:label "New session" :action hermes)
    (:label "Sessions"    :action hermes-sessions)
    (:label "Refresh"     :action revert-buffer))
  "Menu sections for the Hermes dashboard shortmenu.")

(defun +hermes-dashboard--shortmenu-widget ()
  (dolist (item +hermes-dashboard-menu-sections)
    (let ((label (plist-get item :label))
          (action (plist-get item :action)))
      (insert (+hermes-dashboard--center-line
               (format "%s%10s"
                       (with-temp-buffer
                         (insert-text-button
                          label
                          'action `(lambda (_)
                                     (call-interactively
                                      (or (command-remapping #',action) #',action)))
                          'face '+hermes-dashboard-label
                          'follow-link t)
                         (buffer-string))
                       (propertize
                        (or (when-let*
                                ((keymaps (delq nil (list (when (bound-and-true-p evil-local-mode)
                                                            (evil-get-auxiliary-keymap +hermes-dashboard-mode-map 'normal))
                                                          +hermes-dashboard-mode-map)))
                                 (key (or (when keymaps (where-is-internal action keymaps t))
                                          (where-is-internal action nil t))))
                              (key-description key))
                            "")
                        'face '+hermes-dashboard-desc))
               (window-width))
              "\n"))))

;; ── Mode ──────────────────────────────────────────────────────────────────────

(defvar +hermes-dashboard-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key! m
      [remap forward-button]  #'+hermes-dashboard-forward-button
      [remap backward-button] #'+hermes-dashboard-backward-button
      "n"       #'forward-button
      "p"       #'backward-button
      "C-n"     #'forward-button
      "C-p"     #'backward-button
      [down]    #'forward-button
      [up]      #'backward-button
      [tab]     #'forward-button
      [backtab] #'backward-button
      "g"       #'revert-buffer
      "q"       #'quit-window
      [remap evil-next-line]         #'forward-button
      [remap evil-previous-line]     #'backward-button
      [remap evil-next-visual-line]  #'forward-button
      [remap evil-previous-visual-line] #'backward-button
      [remap evil-paste-pop-next]    #'forward-button
      [remap evil-paste-pop]         #'backward-button
      [remap evil-delete]            #'ignore
      [remap evil-delete-line]       #'ignore
      [remap evil-insert]            #'ignore
      [remap evil-append]            #'ignore
      [remap evil-replace]           #'ignore
      [remap evil-enter-replace-state] #'ignore
      [remap evil-change]            #'ignore
      [remap evil-change-line]       #'ignore
      [remap evil-visual-char]       #'ignore
      [remap evil-visual-line]       #'ignore)
    m)
  "Keymap for `+hermes-dashboard-mode'.")

(define-derived-mode +hermes-dashboard-mode special-mode "Hermes"
  "Major mode for the Doom-styled Hermes dashboard."
  :syntax-table nil :abbrev-table nil
  (buffer-disable-undo)
  (setq-local revert-buffer-function #'+hermes-dashboard-reload)
  (setq truncate-lines t)
  (setq-local hscroll-margin 0)
  (setq-local scroll-preserve-screen-position nil)
  (setq-local display-line-numbers-type nil)
  (add-hook 'post-command-hook #'+hermes-dashboard-reposition-point nil 'local))

(defun +hermes-dashboard-forward-button (&optional n)
  (interactive "p") (forward-button (or n 1) t nil t) (message (help-echo)))
(defun +hermes-dashboard-backward-button (&optional n)
  (interactive "p") (forward-button (- (or n 1)) t nil t) (message (help-echo)))

(defvar-local +hermes-dashboard--content-start nil
  "Marker at the first content line after vertical centering padding.")

(defun +hermes-dashboard-reposition-point ()
  (unless (button-at (point))
    (condition-case _ (forward-button 1)
      (error (ignore-errors (forward-button -1))))))

;; ── Vertical centering ───────────────────────────────────────────────────────

(defun +hermes-dashboard--recenter (&optional _frame)
  "Adjust vertical centering without rebuilding content.
Called from `window-size-change-functions' on resize."
  (let ((buf (get-buffer +hermes-dashboard-buffer-name)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (markerp +hermes-dashboard--content-start)
          (let ((inhibit-read-only t))
            (save-excursion
              ;; Count content lines
              (let* ((content-lines (count-lines
                                     +hermes-dashboard--content-start
                                     (point-max)))
                     (wh (window-body-height))
                     (top-pad (max 0 (ash (- wh content-lines) -1))))
                ;; Remove existing padding
                (delete-region (point-min) +hermes-dashboard--content-start)
                ;; Re-insert padding at correct height
                (goto-char (point-min))
                (dotimes (_ top-pad) (insert "\n"))
                (set-marker +hermes-dashboard--content-start (point))))))))))

(defun +hermes-dashboard--rebuild (&optional _force)
  "Full content rebuild: erase, insert widgets, center vertically."
  (interactive)
  (let ((buf (get-buffer-create +hermes-dashboard-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t) (pt (point)))
        (unless (derived-mode-p '+hermes-dashboard-mode)
          (+hermes-dashboard-mode))
        (erase-buffer)
        (run-hooks '+hermes-dashboard-functions)
        ;; Mark content start (before vertical padding)
        (setq +hermes-dashboard--content-start (point-marker))
        ;; Vertical centering
        (let* ((total-lines (count-lines (point-min) (point-max)))
               (wh (window-body-height))
               (top-pad (max 0 (ash (- wh total-lines) -1))))
          (goto-char (point-min))
          (dotimes (_ top-pad) (insert "\n"))
          (set-marker +hermes-dashboard--content-start (point)))
        (goto-char (min pt (point-max)))
        (+hermes-dashboard-reposition-point)))))

(defun +hermes-dashboard-reload (&optional _force)
  "Public reload: delegates to `+hermes-dashboard--rebuild'."
  (interactive)
  (+hermes-dashboard--rebuild))

(defun +hermes-dashboard-open ()
  (interactive)
  (let ((buf (get-buffer-create +hermes-dashboard-buffer-name)))
    (+hermes-dashboard--rebuild)
    (pop-to-buffer-same-window buf)))

;; ── Event refresh ────────────────────────────────────────────────────────────

(defun +hermes-dashboard--refresh-if-open (&optional type &rest _ignore)
  (when (or (null type) (symbolp type)
            (member type '("gateway.ready" "session.info" "session.closed"
                           "message.complete" "error")))
    (let ((buf (get-buffer +hermes-dashboard-buffer-name)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (+hermes-dashboard--rebuild))))))

(defun +hermes-dashboard--on-resize (&optional _frame)
  "Window size changed: recenter content without rebuilding."
  (+hermes-dashboard--recenter))

(defun +hermes-dashboard--install-hooks ()
  (remove-hook 'hermes-rpc-event-functions #'hermes-dashboard--refresh-if-open)
  (remove-hook 'hermes-rpc-connection-functions #'hermes-dashboard--refresh-if-open)
  (add-hook 'hermes-rpc-event-functions #'+hermes-dashboard--refresh-if-open)
  (add-hook 'hermes-rpc-connection-functions #'+hermes-dashboard--refresh-if-open)
  (add-hook 'window-size-change-functions #'+hermes-dashboard--on-resize))

;; ─────────────────────────────────────────────────────────────────────────────
;;  hermes-mode: normal-state C-c bindings
;; ─────────────────────────────────────────────────────────────────────────────

(with-eval-after-load 'hermes-mode
  (evil-define-key 'normal hermes-mode-map
    (kbd "C-c C-i") #'hermes-send
    (kbd "C-c C-k") #'hermes-interrupt
    (kbd "C-c C-l") #'hermes-compose))

;; ─────────────────────────────────────────────────────────────────────────────
;;  Leader prefix: SPC h
;; ─────────────────────────────────────────────────────────────────────────────

(when (bound-and-true-p doom-leader-map)
  (+hermes-dashboard--install-hooks)
  (define-prefix-command 'hermes-leader-map)
  (define-key doom-leader-map (kbd "h") 'hermes-leader-map)
  (define-key hermes-leader-map (kbd "d") #'+hermes-dashboard-open)
  (define-key hermes-leader-map (kbd "s") #'hermes-sessions)
  (define-key hermes-leader-map (kbd "n") #'hermes)
  (define-key hermes-leader-map (kbd "i") #'hermes-dashboard-send)
  (define-key hermes-leader-map (kbd "k") #'hermes-dashboard-interrupt)
  (define-key hermes-leader-map (kbd "c") #'hermes-dashboard-compose)
  (define-key hermes-leader-map (kbd "g") #'hermes-dashboard-go-primary))

(defun hermes-dashboard-go-primary ()
  (interactive)
  (let ((buf (hermes-dashboard--primary-buffer)))
    (if buf (pop-to-buffer-same-window buf)
      (user-error "No primary Hermes session"))))
