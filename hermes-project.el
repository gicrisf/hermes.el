;;; hermes-project.el --- Per-session project context for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai, project
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Auto-detects the project root for each Hermes session via `project.el'
;; (built-in) with a `projectile' fallback, stores it locally on the
;; session state, mirrors it as a `:HERMES_CWD:' org property, and
;; injects a short project-context prefix on the wire for the first
;; prompt of every session (and optionally for later prompts).
;;
;; The gateway's per-session cwd is process-global (set at session.create
;; from `TERMINAL_CWD'), so we do not attempt to push runtime updates to
;; the gateway.  All cwd tracking here is local.

;;; Code:

(require 'cl-lib)
(require 'project nil t)
(require 'hermes-state)

(declare-function projectile-project-root "projectile" (&optional dir))
(declare-function hermes--container-marker-at-point "hermes-mode" ())
(declare-function hermes--primary-session-buffer "hermes-mode" ())
(declare-function hermes--buffer-message-count "hermes-mode" ())
(declare-function hermes-bench-live-p "hermes-bench" (&optional buffer))

(defvar hermes--state)
(defvar hermes--container-level)

;;;; Customization

(defgroup hermes-project nil
  "Project-root awareness for Hermes sessions."
  :group 'hermes)

(defcustom hermes-project-auto-context nil
  "If non-nil, inject project context on every prompt, not just the first."
  :type 'boolean
  :group 'hermes-project)

(defcustom hermes-project-context-max-files 10
  "Maximum number of project files listed in the context prefix."
  :type 'integer
  :group 'hermes-project)

(defcustom hermes-project-context-max-chars 2000
  "Hard cap on the size of the project context prefix, in characters."
  :type 'integer
  :group 'hermes-project)

;;;; Root detection

(defun hermes-project--project-el-root (dir)
  "Return the `project.el' root for DIR or nil.
Compat: uses `project-root' on Emacs 28.1+, `project-roots' on 27."
  (when (fboundp 'project-current)
    (let ((default-directory (or dir default-directory)))
      (when-let ((proj (project-current nil)))
        (cond
         ((fboundp 'project-root) (project-root proj))
         ((fboundp 'project-roots) (car (project-roots proj))))))))

(defun hermes-project--projectile-root (dir)
  "Return the `projectile' root for DIR or nil, only if loaded."
  (when (and (featurep 'projectile) (fboundp 'projectile-project-root))
    (ignore-errors (projectile-project-root dir))))

(defun hermes-project-detect-cwd (&optional directory)
  "Detect a project root for DIRECTORY (default `default-directory').
Tries `project.el' first, then `projectile' (if loaded), then nil.
The returned path is expanded; callers may abbreviate for display."
  (let ((dir (or directory default-directory)))
    (when-let ((root (or (hermes-project--project-el-root dir)
                         (hermes-project--projectile-root dir))))
      (expand-file-name (file-name-as-directory root)))))

;;;; Recent-files collection

(defun hermes-project--git-modified (root)
  "Return paths of files modified under ROOT according to git, or nil."
  (when (and root (file-exists-p (expand-file-name ".git" root)))
    (let ((default-directory root))
      (ignore-errors
        (split-string
         (shell-command-to-string
          "git diff --name-only HEAD 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null")
         "\n" t "[ \t]+")))))

(defun hermes-project--under-root-p (path root)
  "Return non-nil if PATH lives under ROOT."
  (and path root
       (let ((p (expand-file-name path))
             (r (file-name-as-directory (expand-file-name root))))
         (string-prefix-p r p))))

(defun hermes-project--recentf-under (root)
  "Return entries of `recentf-list' that live under ROOT, relative to ROOT."
  (when (and root (boundp 'recentf-list))
    (cl-loop for f in (symbol-value 'recentf-list)
             when (hermes-project--under-root-p f root)
             collect (file-relative-name (expand-file-name f) root))))

(defun hermes-project--open-buffers-under (root)
  "Return relative paths of live file buffers under ROOT."
  (cl-loop for buf in (buffer-list)
           for f = (buffer-file-name buf)
           when (and f (hermes-project--under-root-p f root))
           collect (file-relative-name f root)))

(defun hermes-project--recent-files (root)
  "Collect a deduplicated list of interesting files under ROOT.
Order: git-modified first, then recentf, then open file-buffers."
  (when root
    (let ((git (hermes-project--git-modified root))
          (rec (hermes-project--recentf-under root))
          (buf (hermes-project--open-buffers-under root))
          seen acc)
      (dolist (f (append git rec buf))
        (unless (or (null f) (string-empty-p f) (member f seen))
          (push f seen)
          (push f acc)))
      (nreverse acc))))

;;;; Context string builder

(defun hermes-project--build-context (&optional state)
  "Build a project-context prefix string for STATE (default `hermes--state').
Returns nil if no cwd is set or no files can be collected."
  (let* ((st (or state (and (boundp 'hermes--state) hermes--state)))
         (root (and st (hermes-state-cwd st)))
         (files (and root (hermes-project--recent-files root))))
    (when (and root files)
      (let* ((take (cl-subseq files 0
                              (min (length files)
                                   hermes-project-context-max-files)))
             (body (mapconcat (lambda (f) (concat " " f)) take "\n"))
             (out (format "[Project context (%s):\n%s]\n\nCurrent: "
                          (abbreviate-file-name root) body)))
        (if (> (length out) hermes-project-context-max-chars)
            (concat (substring out 0 (max 0
                                          (- hermes-project-context-max-chars
                                             20)))
                    " …]\n\nCurrent: ")
          out)))))

;;;; Org property mirroring

(defun hermes-project--write-org-property (cwd)
  "Write CWD to the `:HERMES_CWD:' property on the container heading.
Silently no-ops if not in a hermes/org buffer or no container heading exists."
  (when (and cwd (derived-mode-p 'org-mode))
    (save-excursion
      (let ((marker (and (fboundp 'hermes--container-marker-at-point)
                         (ignore-errors (hermes--container-marker-at-point)))))
        (cond
         ((and marker (marker-position marker))
          (goto-char (marker-position marker))
          (when (org-at-heading-p)
            (org-set-property "HERMES_CWD" (abbreviate-file-name cwd))))
         (t
          (goto-char (point-min))
          (when (org-at-heading-p)
            (org-set-property "HERMES_CWD" (abbreviate-file-name cwd)))))))))

(defun hermes-project--read-org-property ()
  "Return the `:HERMES_CWD:' property of the container heading, or nil."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char (point-min))
      (when (org-at-heading-p)
        (let ((v (org-entry-get (point) "HERMES_CWD")))
          (and v (not (string-empty-p v)) v))))))

;;;; Apply cwd to current session

(defun hermes-project--apply-cwd (cwd)
  "Apply CWD to the current session: state + org property.
The gateway is intentionally not notified; runtime cwd changes are not
supported by the gateway.  CWD may be nil (clears the local cwd)."
  (when (boundp 'hermes--state)
    (hermes-dispatch (cons :set-cwd (list :cwd cwd))))
  (hermes-project--write-org-property cwd))

;;;; Interactive commands

;;;###autoload
(defun hermes-project-set-cwd (&optional cwd)
  "Set the project cwd for the current Hermes session.
With no prefix arg, auto-detect via `hermes-project-detect-cwd'.
With \\[universal-argument], prompt for a directory."
  (interactive
   (list (if current-prefix-arg
             (read-directory-name "Project root: "
                                  (or (hermes-project-detect-cwd)
                                      default-directory))
           (hermes-project-detect-cwd))))
  (let ((cwd (and cwd (expand-file-name (file-name-as-directory cwd)))))
    (hermes-project--apply-cwd cwd)
    (message "hermes: cwd %s" (if cwd (abbreviate-file-name cwd) "cleared"))))

;;;###autoload
(defun hermes-project-toggle-auto-context (&optional arg)
  "Toggle automatic project context for every prompt.
With prefix ARG, enable if positive, otherwise disable."
  (interactive "P")
  (setq hermes-project-auto-context
        (cond ((null arg) (not hermes-project-auto-context))
              ((> (prefix-numeric-value arg) 0) t)
              (t nil)))
  (message "hermes: project auto-context %s"
           (if hermes-project-auto-context "enabled" "disabled")))

;;;###autoload
(defun hermes-project-attach-file (file)
  "Insert FILE's path into the bench input area for the current session.
The file is chosen from those under the session's `cwd' via
`completing-read'.  This inserts plain text into the editable input area
— it does not send a sidecar attachment.  Distinct from
`hermes-image-attach-file', which uses the `image.attach' RPC."
  (interactive
   (let* ((root (or (and (boundp 'hermes--state)
                         (hermes-state-cwd hermes--state))
                    (hermes-project-detect-cwd)
                    default-directory))
          (default-directory root))
     (list (read-file-name "Attach project file: " root nil t))))
  (let* ((root (or (and (boundp 'hermes--state)
                        (hermes-state-cwd hermes--state))
                   (hermes-project-detect-cwd)))
         (rel (if root (file-relative-name file root) file))
         (target (and (fboundp 'hermes-bench-live-p)
                      (hermes-bench-live-p))))
    (cond
     ((buffer-live-p target)
      (with-current-buffer target
        (goto-char (point-max))
        (unless (or (bobp) (bolp)) (insert " "))
        (insert rel))
      (when-let ((w (get-buffer-window target)))
        (select-window w)
        (goto-char (point-max))))
     (t
      (kill-new rel)
      (message "hermes: no bench input — path copied to kill ring: %s" rel)))))

;;;; Project-switch hook

(defun hermes-project--on-switch-project ()
  "Update the primary session's cwd after a project switch.
Only fires for sessions with zero committed turns to avoid desyncing
a half-finished conversation from its files."
  (let ((root (hermes-project-detect-cwd)))
    (when root
      (when-let ((buf (and (fboundp 'hermes--primary-session-buffer)
                           (hermes--primary-session-buffer))))
        (with-current-buffer buf
          (when (and (fboundp 'hermes--buffer-message-count)
                     (zerop (hermes--buffer-message-count))
                     (not (equal root (hermes-state-cwd hermes--state))))
            (hermes-project--apply-cwd root)))))))

(with-eval-after-load 'projectile
  (add-hook 'projectile-after-switch-project-hook
            #'hermes-project--on-switch-project))

(with-eval-after-load 'project
  (when (boundp 'project-switch-project-hook)
    (add-hook 'project-switch-project-hook
              #'hermes-project--on-switch-project)))

(provide 'hermes-project)
;;; hermes-project.el ends here
