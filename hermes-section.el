;;; hermes-section.el --- magit-section conversation viewer  -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1") (magit-section "3.0"))

;;; Commentary:
;;
;; Read-only magit-section view over the canonical `turns' vector of a
;; Hermes session.  Projects state from `hermes--sessions'; never mutates
;; it.  See plans/04-section-mode.md,
;; plans/08-hermes-section-presentation.md, and
;; plans/10-hermes-section-org-fontification.md.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'org)
(require 'magit-section)
(require 'hermes-state)
(require 'hermes-md)
(require 'hermes-rpc)
(require 'hermes-tool-formatters)

(declare-function hermes-bench-ensure "hermes-bench" (sid))

(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes-new-session "hermes-mode" (&optional callback))
(declare-function hermes--parse-buffer-messages "hermes-mode" ())
(declare-function hermes-send "hermes-input" (text))
(declare-function hermes-interrupt-current-session "hermes-mode" ())

;;;; Faces — turn headings

(defface hermes-section-face-user
  '((t :weight normal))
  "Face for user turn heading text.")

(defface hermes-section-face-assistant
  '((t :weight normal))
  "Face for assistant turn heading text.")

(defface hermes-section-face-system
  '((t :weight normal))
  "Face for system turn heading text.")

;;;; Faces — child headings

(defface hermes-section-face-reasoning
  '((t :inherit (italic font-lock-comment-face)))
  "Face for reasoning child heading.")

(defface hermes-section-face-tool
  '((t :inherit font-lock-keyword-face))
  "Face for tool child heading base.")

(defface hermes-section-face-tool-done
  '((t :inherit font-lock-doc-face))
  "Face for tool DONE status keyword.")

(defface hermes-section-face-tool-error
  '((t :inherit font-lock-error-face))
  "Face for tool ERROR status keyword.")

(defface hermes-section-face-tool-running
  '((t :inherit font-lock-warning-face))
  "Face for tool RUNNING status keyword.")

(defface hermes-section-face-subagent
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for subagent child heading.")

;;;; Faces — background tints

(defface hermes-section-bg-user
  '((((background dark)) :background "#45403b" :extend t)
    (t                   :background "#fcf7ef" :extend t))
  "Warm tint for user turn sections.")

(defface hermes-section-bg-assistant
  '((((background dark)) :background "#2e3640" :extend t)
    (t                   :background "#e8edf3" :extend t))
  "Cool tint for assistant turn sections.")

(defface hermes-section-bg-system
  '((((background dark)) :background "#353035" :extend t)
    (t                   :background "#f5f0eb" :extend t))
  "Subtle tint for system turn sections.")

;;;; Section classes

(defclass hermes-section-turn-section (magit-section)
  ((selective-highlight :initform t))
  "Base class for conversation turn sections.")

(defclass hermes-section-user-section
  (hermes-section-turn-section) ()
  "A user turn section.")

(defclass hermes-section-assistant-section
  (hermes-section-turn-section) ()
  "An assistant turn section.")

(defclass hermes-section-system-section
  (hermes-section-turn-section) ()
  "A system turn section.")

(defclass hermes-section-reasoning-section (magit-section) ()
  "Reasoning child section (chain-of-thought).")

(defclass hermes-section-tool-section (magit-section) ()
  "Tool invocation child section.")

(defclass hermes-section-subagent-section (magit-section) ()
  "Subagent delegation child section.")

;;;; Buffer-local snapshot

(defvar-local hermes-section--turns-snapshot nil
  "Last-seen `turns' vector for eq-based change detection.")

;;;; Text helpers

(defun hermes-section--text-segments (msg)
  "Return list of text-segment content strings from MSG, in arrival order."
  (let ((segs (hermes-message-segments msg))
        (out nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let* ((seg  (aref segs i))
               (type (hermes-segment-type seg))
               (c    (hermes-segment-content seg)))
          (when (and (eq type 'text) (stringp c) (> (length c) 0))
            (push c out)))))
    (nreverse out)))

(defun hermes-section--body-text (msg)
  "Return MSG's raw text-segment content joined with newlines."
  (mapconcat #'identity (hermes-section--text-segments msg) "\n"))

(defun hermes-section--has-segment-type-p (msg type)
  (let ((segs (hermes-message-segments msg))
        (found nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (when (eq type (hermes-segment-type (aref segs i)))
          (setq found t))))
    found))

(defun hermes-section--heading-text (msg index)
  "Return turn-number heading for MSG at 1-based INDEX."
  (let* ((kind (hermes-message-kind msg))
         (ts   (hermes-message-timestamp msg))
         (time (and ts
                    (ignore-errors
                      (format-time-string "%H:%M" (date-to-time ts))))))
    (pcase kind
      ('user (concat (format "> %d · User" index)
                     (and time (concat " · " time))))
      ('assistant
       (concat
        (if (hermes-section--has-segment-type-p msg 'text)
            (format "● %d · Assistant · %s" index
                    (or (hermes-section--session-model
                         hermes--current-session-id)
                        "?"))
          (format "● %d · Assistant · (tool-only)" index))
        (and time (concat " · " time))))
      (_ (concat (format "#%d · System" index)
                 (and time (concat " · " time)))))))

(defun hermes-section--bg-face (kind)
  (pcase kind
    ('user      'hermes-section-bg-user)
    ('assistant 'hermes-section-bg-assistant)
    (_          'hermes-section-bg-system)))

(defun hermes-section--head-face (kind)
  (pcase kind
    ('user      'hermes-section-face-user)
    ('assistant 'hermes-section-face-assistant)
    (_          'hermes-section-face-system)))

(defun hermes-section--turn-class (kind)
  (pcase kind
    ('user      'hermes-section-user-section)
    ('assistant 'hermes-section-assistant-section)
    (_          'hermes-section-system-section)))

;;;; Org-mode fontification (plan 10)

(defun hermes-section--fontify-as-org (text)
  "Return TEXT (already valid Org) fontified with `font-lock-face' properties.
Enables `org-mode' in a temp buffer with `org-src-fontify-natively'
so embedded source blocks (e.g. `#+begin_src diff') are fontified
by their language modes.  Converts the resulting `face' properties
to `font-lock-face' so the colors render in `magit-section-mode'
buffers where syntactic font-locking is disabled."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert text)
      ;; org-src-fontify-natively must be let-bound BEFORE org-mode init:
      ;; org-mode reads it when building org-font-lock-keywords.
      (let ((org-src-fontify-natively t))
        (delay-mode-hooks (org-mode))
        ;; Align named hermes-tool tables before fontifying — matches
        ;; the org renderer's post-pass (hermes-render.el `org-table-
        ;; align' loop).  `font-lock-ensure' below catches any whitespace
        ;; changes from the alignment.
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward
                  "^#\\+name: hermes-tool-[^ \t\r\n]+[ \t]*$" nil t)
            (forward-line 1)
            (when (looking-at "^[ \t]*|")
              (ignore-errors (org-table-align)))))
        (font-lock-ensure))
      (let ((pos (point-min)))
        (while (< pos (point-max))
          (let* ((next (or (next-single-property-change
                            pos 'face nil (point-max))
                           (point-max)))
                 (val (get-text-property pos 'face)))
            (when val
              (put-text-property pos next 'font-lock-face val)
              (remove-text-properties pos next '(face nil)))
            (setq pos next))))
      (buffer-string))))

(defun hermes-section--fontify-org (text)
  "Convert TEXT from markdown to Org and fontify.
Applied to LLM-generated markdown response/reasoning text — runs
through `hermes-md-to-org' first, then `hermes-section--fontify-as-org'."
  (hermes-section--fontify-as-org (hermes-md-to-org (or text ""))))

(defun hermes-section--format-timestamp (ts)
  (cond ((stringp ts) ts)
        ((null ts) "")
        (t (format-time-string "%Y-%m-%dT%H:%M:%S%z" ts))))

(defun hermes-section--session-model (sid)
  (let* ((state (and sid (hermes--state-slot-read sid)))
         (info  (and state (hermes-state-session-info state))))
    (and (hash-table-p info) (gethash "model" info))))

(defun hermes-section--usage-tokens (usage)
  "Return (SENT . RECV) from USAGE hash-table, or nil if neither present."
  (when (hash-table-p usage)
    (let ((sent (or (gethash "tokens_sent" usage)
                    (gethash "input_tokens" usage)))
          (recv (or (gethash "tokens_received" usage)
                    (gethash "output_tokens" usage))))
      (when (or sent recv)
        (cons (or sent 0) (or recv 0))))))

(defun hermes-section--format-duration (dur)
  (cond ((null dur) "")
        ((numberp dur) (format " (%.1fs)" dur))
        (t (format " (%s)" dur))))

;;;; Body insertion

(defun hermes-section--insert-full-text (msg _bg-face)
  "Insert MSG body text in full.
Body text is fontified as markdown (per plan 09) and carries no
background tint — only the turn heading shows the writer's tint.
Heading is turn-number based (per plan 11), so no dedup needed."
  (let ((text (hermes-section--body-text msg)))
    (unless (string-empty-p text)
      (insert (hermes-section--fontify-org
               (concat text (unless (string-suffix-p "\n" text) "\n")))))))

(defun hermes-section--insert-lines (lines _bg-face)
  "Insert metadata LINES as plain text (no tint, no markdown)."
  (dolist (line lines)
    (insert line "\n")))

(defun hermes-section--image-lines (msg)
  (let ((segs (hermes-message-segments msg))
        (out nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let ((seg (aref segs i)))
          (when (eq 'image (hermes-segment-type seg))
            (let* ((c (hermes-segment-content seg))
                   (name (or (and (listp c) (plist-get c :name))
                             (let ((p (and (listp c) (plist-get c :path))))
                               (and p (file-name-nondirectory p)))
                             "image")))
              (push (format "[image: %s]" name) out))))))
    (nreverse out)))

(defun hermes-section--insert-user-body (msg bg-face)
  (hermes-section--insert-full-text msg bg-face)
  (let ((imgs (hermes-section--image-lines msg)))
    (when imgs
      (hermes-section--insert-lines imgs bg-face))))

(defun hermes-section--insert-system-body (msg bg-face)
  (hermes-section--insert-full-text msg bg-face)
  (let* ((sid hermes--current-session-id)
         (ts  (hermes-section--format-timestamp
               (hermes-message-timestamp msg)))
         (model (hermes-section--session-model sid))
         (meta nil))
    (unless (string-empty-p ts) (push (format "at %s" ts) meta))
    (when model (push (format "model: %s" model) meta))
    (when meta
      (insert "---\n")
      (hermes-section--insert-lines (nreverse meta) bg-face))))

;;;; Child sections

(defun hermes-section--insert-reasoning-child (seg bg-face)
  (let ((id (or (hermes-segment-id seg)
                (format "reasoning-%d" (sxhash-equal seg))))
        (c  (or (hermes-segment-content seg) "")))
    (magit-insert-section (hermes-section-reasoning-section id nil)
      (magit-insert-heading
        (propertize "Reasoning"
                     'font-lock-face (list 'hermes-section-face-reasoning bg-face)))
      (magit-insert-section-body
        (insert (propertize
                 (hermes-section--fontify-org
                  (concat c (if (or (string-empty-p c)
                                    (string-suffix-p "\n" c))
                                "" "\n")))
                 'font-lock-face 'hermes-section-face-reasoning))))))

(defun hermes-section--tool-status-keyword (tool)
  (pcase (hermes-tool-status tool)
    ('complete   (cons "DONE"    'hermes-section-face-tool-done))
    ('error      (cons "ERROR"   'hermes-section-face-tool-error))
    ('running    (cons "RUNNING" 'hermes-section-face-tool-running))
    ('generating (cons "RUNNING" 'hermes-section-face-tool-running))
    (_           (cons "..."     'hermes-section-face-tool-running))))

(defun hermes-section--insert-tool-child (tool bg-face)
  (let* ((id (or (hermes-tool-id tool)
                 (format "tool-%d" (sxhash-equal tool))))
         (kw (hermes-section--tool-status-keyword tool))
         (name (or (hermes-tool-name tool) "tool"))
         (dur (hermes-section--format-duration (hermes-tool-duration tool)))
         (formatter (hermes-tool--lookup name))
         (parts (and formatter (funcall formatter tool)))
         (fmt-summary (or (plist-get parts :summary) name))
         (gw-summary (let ((s (hermes-tool-summary tool)))
                       (if (and s (> (length s) 0)) (format " — %s" s) "")))
         (body (or (plist-get parts :body) "")))
    (magit-insert-section (hermes-section-tool-section id nil)
      (magit-insert-heading
        (propertize (car kw) 'font-lock-face (list (cdr kw) bg-face))
        (propertize (format " %s%s%s" fmt-summary dur gw-summary)
                    'font-lock-face (list 'hermes-section-face-tool bg-face)))
      (magit-insert-section-body
        (when (and body (> (length body) 0))
          (insert (hermes-section--fontify-as-org body))
          (unless (bolp) (insert "\n")))))))

(defun hermes-section--subagent-body (sa)
  "Return plain-text body string for subagent SA struct."
  (let ((parts nil)
        (thinking (hermes-subagent-thinking sa))
        (notes (hermes-subagent-notes sa))
        (tools (hermes-subagent-tools sa))
        (summary (hermes-subagent-summary sa))
        (status (hermes-subagent-status sa))
        (dur (hermes-section--format-duration (hermes-subagent-duration sa))))
    (when (and thinking (stringp thinking) (> (length thinking) 0))
      (push (format "thinking: %s" thinking) parts))
    (when (and (vectorp notes) (> (length notes) 0))
      (let ((note-lines nil))
        (dotimes (i (length notes))
          (push (format "  - %s" (aref notes i)) note-lines))
        (push (concat "notes:\n"
                      (mapconcat #'identity (nreverse note-lines) "\n"))
              parts)))
    (when (and (vectorp tools) (> (length tools) 0))
      (let ((tool-lines nil))
        (dotimes (i (length tools))
          (let* ((tp (aref tools i))
                 (n  (and (listp tp) (or (plist-get tp :name)
                                         (plist-get tp 'name))))
                 (a  (and (listp tp) (or (plist-get tp :args)
                                         (plist-get tp 'args)))))
            (push (format "  - %s%s" (or n "tool")
                          (if a (format "(%s)" a) ""))
                  tool-lines)))
        (push (concat "tools:\n"
                      (mapconcat #'identity (nreverse tool-lines) "\n"))
              parts)))
    (when (and (memq status '(complete error)) summary)
      (push (format "result: %s%s" summary dur) parts))
    (if parts
        (concat (mapconcat #'identity (nreverse parts) "\n") "\n")
      "")))

(defun hermes-section--insert-subagent-child (sa bg-face)
  (let* ((id   (or (hermes-subagent-id sa)
                   (format "sa-%d" (sxhash-equal sa))))
         (goal (or (hermes-subagent-goal sa) "subagent"))
         (status (or (hermes-subagent-status sa) 'queued))
         (thinking (hermes-subagent-thinking sa))
         (notes (hermes-subagent-notes sa))
         (tools (hermes-subagent-tools sa))
         (summary (hermes-subagent-summary sa))
         (dur (hermes-section--format-duration (hermes-subagent-duration sa))))
    (magit-insert-section (hermes-section-subagent-section id nil)
      (magit-insert-heading
        (propertize (format "%s (%s)" goal status)
                    'font-lock-face (list 'hermes-section-face-subagent bg-face)))
      (magit-insert-section-body
        (when (and thinking (stringp thinking) (> (length thinking) 0))
          (insert "thinking: "
                  (hermes-section--fontify-org thinking)
                  "\n"))
        (when (and (vectorp notes) (> (length notes) 0))
          (insert "notes:\n")
          (dotimes (i (length notes))
            (insert (format "  - %s\n" (aref notes i)))))
        (when (and (vectorp tools) (> (length tools) 0))
          (insert "tools:\n")
          (dotimes (i (length tools))
            (let* ((tp (aref tools i))
                   (n  (and (listp tp) (or (plist-get tp :name)
                                           (plist-get tp 'name))))
                   (a  (and (listp tp) (or (plist-get tp :args)
                                           (plist-get tp 'args)))))
              (insert (format "  - %s%s\n" (or n "tool")
                              (if a (format "(%s)" a) ""))))))
        (when (and (memq status '(complete error)) summary)
          (insert "result: "
                  (hermes-section--fontify-org summary)
                  (format "%s\n" dur)))))))

(defun hermes-section--insert-assistant-body (msg bg-face)
  (let* ((segs (or (hermes-message-segments msg) []))
         (sas  (or (hermes-message-subagents msg) []))
         (any-child
          (or (> (length sas) 0)
              (catch 'yes
                (dotimes (i (length segs))
                  (when (eq 'tool (hermes-segment-type (aref segs i)))
                    (throw 'yes t)))
                nil)))
         (any-child-emitted nil)
         (emit (lambda (thunk)
                 (when any-child-emitted (insert "\n"))
                 (funcall thunk)
                 (setq any-child-emitted t))))
    ;; Pass 1: reasoning segments → child sections (before response text)
    (let ((had-reasoning nil))
      (dotimes (i (length segs))
        (let ((seg (aref segs i)))
          (when (eq 'reasoning (hermes-segment-type seg))
            (hermes-section--insert-reasoning-child seg bg-face)
            (setq had-reasoning t))))
      (when had-reasoning (insert "\n")))
    ;; Response text (all text segments joined, no heading dedup)
    (hermes-section--insert-full-text msg bg-face)
    ;; Blank line between response text and first tool/subagent child.
    (when any-child
      (insert "\n"))
    ;; Pass 2: tool segments + subagents, blank line between consecutive
    ;; children, and a trailing blank line for breathing room.
    (dotimes (i (length segs))
      (let ((seg (aref segs i)))
        (when (eq 'tool (hermes-segment-type seg))
          (let ((c (hermes-segment-content seg)))
            (when (hermes-tool-p c)
              (funcall emit
                       (lambda ()
                         (hermes-section--insert-tool-child c bg-face))))))))
    (dotimes (i (length sas))
      (funcall emit
               (lambda ()
                 (hermes-section--insert-subagent-child
                  (aref sas i) bg-face))))
    (when any-child
      (insert "\n"))))

;;;; Insert turn

(defun hermes-section--insert-turn (msg index)
  "Insert MSG as a magit section at point, labeled with 1-based INDEX."
  (let* ((kind  (hermes-message-kind msg))
         (class (hermes-section--turn-class kind))
         (head-face (hermes-section--head-face kind))
         (bg-face (hermes-section--bg-face kind))
         (heading (hermes-section--heading-text msg index))
         (id    (or (hermes-message-id msg)
                    (format "anon-%d" (sxhash-equal msg))))
         (hide  nil))
    (magit-insert-section ((eval class) id hide)
      (magit-insert-heading
        (propertize heading
                    'face (list head-face bg-face)
                    'font-lock-face (list head-face bg-face)))
      (magit-insert-section-body
        (pcase kind
          ('user      (hermes-section--insert-user-body msg bg-face))
          ('assistant (hermes-section--insert-assistant-body msg bg-face))
          (_          (hermes-section--insert-system-body msg bg-face)))
        (unless (bolp) (insert "\n"))
        (insert "\n")))))

;;;; Refresh pipeline

(defun hermes-section--rebuild (state)
  "Erase the current buffer and rebuild sections from STATE.
Point lands at the end so the window shows latest content on
streaming updates.  Previously wrapped in `save-excursion', but
`erase-buffer' inside it causes the saved marker to fall to
position 1, and default marker insertion type does not advance
when text is inserted at that position, so point jumped to the
top of the buffer on every refresh."
  (let ((inhibit-read-only t)
        (turns (hermes-state-turns state)))
    (setq hermes-section--turns-snapshot turns)
    (erase-buffer)
    (magit-insert-section (hermes-section-turn-section nil)
      (if (zerop (length turns))
          (insert "(No messages yet)\n")
        (seq-do-indexed (lambda (msg i)
                          (hermes-section--insert-turn msg (1+ i)))
                        turns)))
    (when magit-root-section
      (magit-section-show magit-root-section))
    (goto-char (point-max))))

(defun hermes-section--refresh (_old new)
  "Rebuild the conversation buffer when `turns' changes.
Routes to the conversation buffer for the currently dispatched
session via `hermes--on-session-buffer'."
  (hermes--on-session-buffer hermes-section--buffers
    (unless (eq (hermes-state-turns new)
                hermes-section--turns-snapshot)
      (let ((tail-windows nil))
        (dolist (win (get-buffer-window-list (current-buffer) nil t))
          (when (= (window-point win) (point-max))
            (push win tail-windows)))
        (hermes-section--rebuild new)
        (dolist (win tail-windows)
          (when (window-live-p win)
            (set-window-point win (point-max))))))))

(defun hermes-section-refresh ()
  "Manually rebuild the current conversation buffer from state."
  (interactive)
  (let ((state (hermes--state-slot-read hermes--current-session-id)))
    (when state
      (setq hermes-section--turns-snapshot nil) ;; force rebuild
      (hermes-section--rebuild state))))

;;;; Inspect

(defun hermes-section-inspect-turn-at-point ()
  "Show the raw `hermes-message' struct at point in a temp buffer."
  (interactive)
  (let* ((sec (magit-current-section))
         (id  (and sec (oref sec value)))
         (state (hermes--state-slot-read hermes--current-session-id))
         (turns (and state (hermes-state-turns state)))
         (msg (and id turns
                   (seq-find (lambda (m) (equal id (hermes-message-id m)))
                             turns))))
    (if (not msg)
        (message "No turn at point")
      (let ((buf (get-buffer-create "*hermes-turn-inspect*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (emacs-lisp-mode)
            (pp msg (current-buffer))))
        (pop-to-buffer buf)))))

;;;; Detach

(defun hermes-section--detach ()
  "Detach this buffer from the conversation registry on kill.
Kills the paired bench when the last viewer goes."
  (when (and hermes--current-session-id
              (eq (current-buffer)
                  (gethash hermes--current-session-id
                           hermes-section--buffers)))
    (let ((sid hermes--current-session-id))
      (remhash sid hermes-section--buffers)
      (hermes--maybe-kill-bench sid))))

;;;; Major mode + keymap

(defvar hermes-section-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m magit-section-mode-map)
    (define-key m (kbd "g") #'hermes-section-refresh)
    (define-key m (kbd "i") #'hermes-send)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt-current-session)
    (define-key m (kbd "C-c C-e") #'hermes-section-export)
    (define-key m (kbd "q") #'quit-window)
    (define-key m (kbd "RET") #'hermes-section-inspect-turn-at-point)
    m)
  "Keymap for `hermes-section-mode'.")

(define-derived-mode hermes-section-mode magit-section-mode
  "Hermes-Section"
  "Magit-section conversation viewer for Hermes sessions.
Reads from `turns' in the global `hermes--sessions' table.
Read-only; input via `hermes-send' (minibuffer)."
  (setq-local buffer-read-only t)
  (setq-local magit-section-cache-visibility t)
  (add-hook 'magit-section-set-visibility-hook
            #'magit-section-cached-visibility nil t)
  (visual-line-mode 1)
  (add-hook 'kill-buffer-hook #'hermes-section--detach nil t)
  (add-hook 'hermes-state-change-hook
            #'hermes-section--refresh t))

;;;; Open + entry point

(defun hermes-section--open (sid &optional buf)
  "Open a magit conversation buffer for session SID.
If BUF is non-nil it is used as the host buffer (already created
by `hermes-new-session'); otherwise a fresh buffer is generated."
  (let ((buf (or buf (generate-new-buffer
                      (format "*hermes-section:%s*" sid)))))
    (with-current-buffer buf
      (hermes-section-mode)
      (setq-local hermes--current-session-id sid)
      (puthash sid buf hermes-section--buffers)
      (let ((state (hermes--state-slot-read sid)))
        (when state
          (hermes-section--rebuild state))))
    (pop-to-buffer buf)
    (when (fboundp 'hermes-bench-ensure)
      (hermes-bench-ensure sid))
    buf))

(defun hermes--maybe-pick-session ()
  "Offer a session picker over live sessions; return the chosen sid or nil."
  (let* ((sessions (hermes--list-active-sessions))
         (choices  (hermes--session-completion-table sessions))
         (display->sid (mapcar (lambda (c) (cons (cdr c) (car c))) choices))
         (def-sid (hermes--most-recent-session-id))
         (def-display (and def-sid
                           (car (rassoc def-sid display->sid))))
         (name (completing-read "Session: "
                                (mapcar #'cdr choices)
                                nil t nil nil def-display)))
    (unless (or (null name) (string-empty-p name))
      (cdr (assoc name display->sid)))))

(defun hermes-section--open-or-focus (sid)
  "Open SID in a section view, or focus the existing one if any."
  (if-let ((existing (gethash sid hermes-section--buffers)))
      (if (buffer-live-p existing)
          (pop-to-buffer existing)
        (remhash sid hermes-section--buffers)
        (hermes-section--open sid))
    (hermes-section--open sid)))

;;;###autoload
(defun hermes-section (&optional arg)
  "Open a magit-section conversation viewer.

With prefix ARG, always create a new session.  Otherwise, if live
sessions exist, offer a session picker (defaulting to the most
recent).  If no live sessions exist, create a fresh one (starting
the gateway if needed)."
  (interactive "P")
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ((derived-mode-p 'hermes-section-mode)
    (message "Already in a Hermes conversation buffer"))
   (arg
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf))))))
   ((hermes--session-exists-p)
    (let ((sid (hermes--maybe-pick-session)))
      (when sid (hermes-section--open-or-focus sid))))
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-section--open
          (buffer-local-value 'hermes--current-session-id buf))))))))

;;;; Export

(defun hermes-section--org-insert-turn (msg)
  "Insert MSG as a simplified Org heading at point."
  (let ((kind (hermes-message-kind msg))
        (text (hermes-section--body-text msg)))
    (pcase kind
      ('user      (insert "* User\n"))
      ('assistant (insert "* Assistant\n"))
      (_          (insert "* System\n")))
    (insert text)
    (unless (bolp) (insert "\n"))
    (insert "\n")))

(defun hermes-section-export (file)
  "Export the current conversation to an Org FILE."
  (interactive "FExport to: ")
  (let* ((sid   hermes--current-session-id)
         (state (and sid (hermes--state-slot-read sid)))
         (turns (and state (hermes-state-turns state))))
    (unless turns
      (user-error "No session/state for current buffer"))
    (with-temp-buffer
      (org-mode)
      (insert "#+TITLE: Hermes conversation export\n\n")
      (seq-doseq (msg turns)
        (hermes-section--org-insert-turn msg))
      (write-file file))
    (message "Exported %d turns to %s" (length turns) file)))

;;;; Fork

(defun hermes-section-fork-from-org (buffer)
  "Create a new session whose `turns' are parsed from org BUFFER."
  (interactive (list (read-buffer "Fork from org buffer: " nil t)))
  (let ((msgs (with-current-buffer (get-buffer buffer)
                (hermes--parse-buffer-messages))))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p) (hermes-rpc-start))
    (hermes-new-session
     (lambda (buf)
       (when buf
         (let ((v   (apply #'vector msgs))
               (sid (buffer-local-value
                     'hermes--current-session-id buf)))
           (hermes-dispatch (cons :turns-load (list :turns v)) sid)
           (hermes-section--open sid)))))))

(provide 'hermes-section)

;;; hermes-section.el ends here
