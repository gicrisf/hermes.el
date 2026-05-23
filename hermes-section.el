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

(declare-function hermes-bench-ensure "hermes-bench" (sid))

(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes-new-session "hermes-mode" (&optional callback))
(declare-function hermes--parse-buffer-messages "hermes-mode" ())
(declare-function hermes-send "hermes-input" (text))
(declare-function hermes-interrupt-current-session "hermes-mode" ())

;;;; Faces — turn headings

(defface hermes-section-face-user
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for user turn heading text.")

(defface hermes-section-face-assistant
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for assistant turn heading text.")

(defface hermes-section-face-system
  '((t :inherit font-lock-builtin-face))
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
  '((((background dark)) :background "#3a3530")
    (t                   :background "#f0ebe3"))
  "Warm tint for user turn sections.")

(defface hermes-section-bg-assistant
  '((((background dark)) :background "#2e3640")
    (t                   :background "#e8edf3"))
  "Cool tint for assistant turn sections.")

(defface hermes-section-bg-system
  '((((background dark)) :background "#353035")
    (t                   :background "#f5f0eb"))
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

(defun hermes-section--first-non-blank-line (s)
  "Return the first non-blank line of S, trimmed.  Empty if none."
  (let ((s (or s "")))
    (catch 'done
      (dolist (line (split-string s "\n"))
        (let ((trimmed (string-trim line)))
          (unless (string-empty-p trimmed)
            (throw 'done trimmed))))
      "")))

(defun hermes-section--has-segment-type-p (msg type)
  (let ((segs (hermes-message-segments msg))
        (found nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (when (eq type (hermes-segment-type (aref segs i)))
          (setq found t))))
    found))

(defun hermes-section--heading-text (msg)
  "Return the single-line heading text for MSG."
  (let ((line (hermes-section--first-non-blank-line
               (hermes-section--body-text msg))))
    (cond
     ((not (string-empty-p line)) line)
     ((and (eq (hermes-message-kind msg) 'assistant)
           (hermes-section--has-segment-type-p msg 'tool))
      "(tool-only turn)")
     (t "(empty)"))))

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

(defun hermes-section--fontify-org (text)
  "Return TEXT fontified as Org-mode body, with `font-lock-face' properties.
Runs TEXT through `hermes-md-to-org' (matching the canonical Org
renderer's pipeline), then enables `org-mode' in a temp buffer
and ensures font-lock.  Converts the resulting `face' properties
to `font-lock-face' so the colors render in
`magit-section-mode' buffers where syntactic font-locking is
disabled.  Per plan 10, body text carries no background tint;
only the heading does.

Applied only to fields known to be LLM-generated markdown — tool
output/summary/context are inserted plain to preserve what the
tool actually returned (see plan 10 §4)."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert (hermes-md-to-org text))
      ;; org-src-fontify-natively must be let-bound BEFORE org-mode init:
      ;; org-mode reads it when building org-font-lock-keywords.
      (let ((org-src-fontify-natively t))
        (delay-mode-hooks (org-mode))
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

(defun hermes-section--insert-full-text (msg _bg-face heading)
  "Insert MSG body text, deduping first non-blank line equal to HEADING.
Body text is fontified as markdown (per plan 09) and carries no
background tint — only the turn heading shows the writer's tint."
  (let* ((text (hermes-section--body-text msg))
         (lines (split-string text "\n"))
         (seen-content nil)
         (out nil))
    (dolist (line lines)
      (cond
       ((and (not seen-content) (string-empty-p (string-trim line))) nil)
       ((and (not seen-content) (equal (string-trim line) heading))
        (setq seen-content t))
       (t (setq seen-content t)
          (push line out))))
    (when out
      (insert (hermes-section--fontify-org
               (concat (mapconcat #'identity (nreverse out) "\n") "\n"))))))

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

(defun hermes-section--insert-user-body (msg bg-face heading)
  (hermes-section--insert-full-text msg bg-face heading)
  (let* ((sid hermes--current-session-id)
         (ts  (hermes-section--format-timestamp
               (hermes-message-timestamp msg)))
         (model (hermes-section--session-model sid))
         (usage (hermes-section--usage-tokens (hermes-message-usage msg)))
         (imgs (hermes-section--image-lines msg))
         (meta nil))
    (unless (string-empty-p ts) (push (format "submitted at %s" ts) meta))
    (when model (push (format "model: %s" model) meta))
    (when usage (push (format "tokens: %d sent, %d received"
                              (car usage) (cdr usage))
                      meta))
    (when (or meta imgs)
      (insert "---\n")
      (hermes-section--insert-lines (nreverse meta) bg-face)
      (hermes-section--insert-lines imgs bg-face))))

(defun hermes-section--insert-system-body (msg bg-face heading)
  (hermes-section--insert-full-text msg bg-face heading)
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
    (magit-insert-section (hermes-section-reasoning-section id t)
      (magit-insert-heading
        (propertize "Reasoning"
                    'face (list 'hermes-section-face-reasoning bg-face)))
      (magit-insert-section-body
        (insert (hermes-section--fontify-org
                 (concat c (if (or (string-empty-p c)
                                   (string-suffix-p "\n" c))
                               "" "\n"))))))))

(defun hermes-section--tool-status-keyword (tool)
  (pcase (hermes-tool-status tool)
    ('complete   (cons "DONE"    'hermes-section-face-tool-done))
    ('error      (cons "ERROR"   'hermes-section-face-tool-error))
    ('running    (cons "RUNNING" 'hermes-section-face-tool-running))
    ('generating (cons "RUNNING" 'hermes-section-face-tool-running))
    (_           (cons "..."     'hermes-section-face-tool-running))))

(defun hermes-section--tool-body (tool)
  "Return plain-text body string for TOOL struct.
Used by tests; production rendering inserts the body piecewise so
the result value can be fontified as markdown while keeping the
structural labels and the context line as plain text."
  (let* ((ctx (let ((c (hermes-tool-context tool)))
                (if (and c (stringp c) (> (length c) 0)) c "(no input)")))
         (dur (hermes-section--format-duration (hermes-tool-duration tool)))
         (err (hermes-tool-error tool))
         (result (or (hermes-tool-output tool)
                     (hermes-tool-summary tool)
                     "(no result)")))
    (if err
        (format "input: %s\nerror: %s%s\n" ctx err dur)
      (format "input: %s\nresult: %s%s\n" ctx result dur))))

(defun hermes-section--insert-tool-child (tool bg-face)
  (let* ((id (or (hermes-tool-id tool)
                 (format "tool-%d" (sxhash-equal tool))))
         (kw (hermes-section--tool-status-keyword tool))
         (name (or (hermes-tool-name tool) "tool"))
         (dur (hermes-section--format-duration (hermes-tool-duration tool)))
         (summ (let ((s (hermes-tool-summary tool)))
                 (if (and s (> (length s) 0)) (format " — %s" s) "")))
         (status (hermes-tool-status tool))
         (hide (memq status '(complete error)))
         (ctx (let ((c (hermes-tool-context tool)))
                (if (and c (stringp c) (> (length c) 0)) c "(no input)")))
         (err (hermes-tool-error tool))
         (result (or (hermes-tool-output tool)
                     (hermes-tool-summary tool)
                     "(no result)")))
    (magit-insert-section (hermes-section-tool-section id hide)
      (magit-insert-heading
        (propertize (car kw) 'face (list (cdr kw) bg-face))
        (propertize (format " %s%s%s" name dur summ)
                    'face (list 'hermes-section-face-tool bg-face)))
      (magit-insert-section-body
        (insert (format "input: %s\n" ctx))
        (if err
            (insert (format "error: %s%s\n" err dur))
          (insert (format "result: %s%s\n" result dur)))))))

(defun hermes-section--subagent-body (sa)
  "Return plain-text body string for subagent SA struct."
  (let ((parts nil)
        (thinking (hermes-subagent-thinking sa))
        (tools (hermes-subagent-tools sa))
        (summary (hermes-subagent-summary sa))
        (status (hermes-subagent-status sa))
        (dur (hermes-section--format-duration (hermes-subagent-duration sa))))
    (when (and thinking (stringp thinking) (> (length thinking) 0))
      (push (format "thinking: %s" thinking) parts))
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
         (tools (hermes-subagent-tools sa))
         (summary (hermes-subagent-summary sa))
         (dur (hermes-section--format-duration (hermes-subagent-duration sa))))
    (magit-insert-section (hermes-section-subagent-section id t)
      (magit-insert-heading
        (propertize (format "%s (%s)" goal status)
                    'face (list 'hermes-section-face-subagent bg-face)))
      (magit-insert-section-body
        (when (and thinking (stringp thinking) (> (length thinking) 0))
          (insert "thinking: "
                  (hermes-section--fontify-org thinking)
                  "\n"))
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

(defun hermes-section--insert-assistant-body (msg bg-face heading)
  (hermes-section--insert-full-text msg bg-face heading)
  (let* ((segs (or (hermes-message-segments msg) []))
         (sas  (or (hermes-message-subagents msg) []))
         (any-child
          (or (> (length sas) 0)
              (catch 'yes
                (dotimes (i (length segs))
                  (when (memq (hermes-segment-type (aref segs i))
                              '(reasoning tool))
                    (throw 'yes t)))
                nil))))
    (when any-child
      (insert "───\n"))
    (dotimes (i (length segs))
      (let* ((seg (aref segs i))
             (type (hermes-segment-type seg))
             (c (hermes-segment-content seg)))
        (pcase type
          ('reasoning
           (hermes-section--insert-reasoning-child seg bg-face))
          ('tool
           (when (hermes-tool-p c)
             (hermes-section--insert-tool-child c bg-face)))
          (_ nil))))
    (dotimes (i (length sas))
      (hermes-section--insert-subagent-child (aref sas i) bg-face))))

;;;; Insert turn

(defun hermes-section--insert-turn (msg)
  "Insert MSG as a magit section at point."
  (let* ((kind  (hermes-message-kind msg))
         (class (hermes-section--turn-class kind))
         (head-face (hermes-section--head-face kind))
         (bg-face (hermes-section--bg-face kind))
         (heading (hermes-section--heading-text msg))
         (id    (or (hermes-message-id msg)
                    (format "anon-%d" (sxhash-equal msg))))
         (hide  (eq kind 'user)))
    (magit-insert-section ((eval class) id hide)
      (magit-insert-heading
        (propertize heading 'face (list head-face bg-face)))
      (magit-insert-section-body
        (pcase kind
          ('user      (hermes-section--insert-user-body msg bg-face heading))
          ('assistant (hermes-section--insert-assistant-body msg bg-face heading))
          (_          (hermes-section--insert-system-body msg bg-face heading)))
        (unless (bolp) (insert "\n"))
        (insert "\n")))))

;;;; Refresh pipeline

(defun hermes-section--rebuild (state)
  "Erase the current buffer and rebuild sections from STATE."
  (let ((inhibit-read-only t)
        (turns (hermes-state-turns state)))
    (setq hermes-section--turns-snapshot turns)
    (save-excursion
      (erase-buffer)
      (magit-insert-section (hermes-section-turn-section nil)
        (if (zerop (length turns))
            (insert "(No messages yet)\n")
          (seq-doseq (msg turns)
            (hermes-section--insert-turn msg)))))
    (when magit-root-section
      (magit-section-show magit-root-section))))

(defun hermes-section--refresh (_old new)
  "Rebuild the conversation buffer when `turns' changes.
Routes to the conversation buffer for the currently dispatched
session via `hermes--on-session-buffer'."
  (hermes--on-session-buffer hermes-section--buffers
    (unless (eq (hermes-state-turns new)
                hermes-section--turns-snapshot)
      (hermes-section--rebuild new))))

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
