;;; hermes-comint.el --- comint-based inline-input conversation viewer  -*- lexical-binding: t; -*-

;; Package-Requires: ((emacs "27.1"))

;;; Commentary:
;;
;; Third viewer for Hermes sessions: a `comint-mode'-derived buffer with
;; read-only output history above a writable prompt at the bottom.
;; Projects from the same `turns' state as the org and section viewers,
;; subscribes to the same `hermes-state-change-hook'.  No process — output
;; is inserted manually from state diffs.
;;
;; See plans/23-comint-viewer.md.

;;; Code:

(require 'cl-lib)
(require 'comint)
(require 'org)
(require 'ring)
(require 'hermes-state)
(require 'hermes-md)
(require 'hermes-tool-formatters)

(declare-function hermes-send "hermes-input" (text))
(declare-function hermes-compose "hermes-compose" ())
(declare-function hermes-interrupt-current-session "hermes-mode" ())
(declare-function hermes--maybe-kill-bench "hermes-state" (sid))
(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes-new-session "hermes-mode" (&optional callback))
(declare-function hermes-rpc-live-p "hermes-rpc" ())
(declare-function hermes-rpc-start "hermes-rpc" ())

;;; Faces — turn headings

(defface hermes-comint-face-user
  '((t :weight normal))
  "Face for user turn heading text.")

(defface hermes-comint-face-assistant
  '((t :weight normal))
  "Face for assistant turn heading text.")

(defface hermes-comint-face-system
  '((t :weight normal))
  "Face for system turn heading text.")

;;; Faces — child headings

(defface hermes-comint-face-reasoning
  '((t :inherit (italic font-lock-comment-face)))
  "Face for reasoning child heading.")

(defface hermes-comint-face-tool
  '((t :inherit font-lock-keyword-face))
  "Face for tool child heading base.")

(defface hermes-comint-face-tool-done
  '((t :inherit font-lock-doc-face))
  "Face for tool DONE status keyword.")

(defface hermes-comint-face-tool-error
  '((t :inherit font-lock-error-face))
  "Face for tool ERROR status keyword.")

(defface hermes-comint-face-tool-running
  '((t :inherit font-lock-warning-face))
  "Face for tool RUNNING status keyword.")

(defface hermes-comint-face-subagent
  '((t :inherit font-lock-builtin-face :weight bold))
  "Face for subagent child heading.")

;;; Message accessors (pure, from hermes-state structs)

(defun hermes-comint--text-segments (msg)
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

(defun hermes-comint--body-text (msg)
  "Return MSG's raw text-segment content joined with newlines."
  (mapconcat #'identity (hermes-comint--text-segments msg) "\n"))

(defun hermes-comint--has-segment-type-p (msg type)
  "Return non-nil if MSG has a segment of TYPE."
  (let ((segs (hermes-message-segments msg))
        (found nil))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (when (eq type (hermes-segment-type (aref segs i)))
          (setq found t))))
    found))

(defun hermes-comint--image-lines (msg)
  "Return list of `[image: name]' strings for image segments in MSG."
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

;;; Turn metadata helpers

(defun hermes-comint--head-face (kind)
  "Return the heading face symbol for turn KIND."
  (pcase kind
    ('user      'hermes-comint-face-user)
    ('assistant 'hermes-comint-face-assistant)
    (_          'hermes-comint-face-system)))

(defun hermes-comint--session-model (sid)
  "Return the model name string for session SID, or nil."
  (let* ((state (and sid (hermes--state-slot-read sid)))
         (info  (and state (hermes-state-session-info state))))
    (and (hash-table-p info) (gethash "model" info))))

(defun hermes-comint--heading-text (msg index)
  "Return turn-number heading string for MSG at 1-based INDEX."
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
        (if (hermes-comint--has-segment-type-p msg 'text)
            (format "● %d · Assistant · %s" index
                    (or (hermes-comint--session-model
                         hermes--current-session-id)
                        "?"))
          (format "● %d · Assistant · (tool-only)" index))
        (and time (concat " · " time))))
      (_ (concat (format "#%d · System" index)
                 (and time (concat " · " time)))))))

(defun hermes-comint--tool-status-keyword (tool)
  "Return (KEYWORD . FACE) for TOOL's status."
  (pcase (hermes-tool-status tool)
    ('complete   (cons "DONE"    'hermes-comint-face-tool-done))
    ('error      (cons "ERROR"   'hermes-comint-face-tool-error))
    ('running    (cons "RUNNING" 'hermes-comint-face-tool-running))
    ('generating (cons "RUNNING" 'hermes-comint-face-tool-running))
    (_           (cons "..."     'hermes-comint-face-tool-running))))

(defun hermes-comint--format-duration (dur)
  "Return DUR formatted as a duration string, or \"\"."
  (cond ((null dur) "")
        ((numberp dur) (format " (%.1fs)" dur))
        (t (format " (%s)" dur))))

;;; Fontification pipeline

(defun hermes-comint--fontify-as-org (text)
  "Return TEXT fontified with `font-lock-face' properties.
Enables `org-mode' in a temp buffer with `org-src-fontify-natively'
for source-block highlighting.  Aligns named hermes-tool tables before
fontifying.  Converts the resulting `face' properties to `font-lock-face'
so colors render in `comint-mode' buffers where syntactic font-locking
may be disabled."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert text)
      (let ((org-src-fontify-natively t))
        (delay-mode-hooks (org-mode))
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward
                  "^#\\+name: hermes-tool-[^ \t\r\n]+[ \t]*$" nil t)
            (vertical-motion 1)
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

(defun hermes-comint--fontify-org (text)
  "Convert TEXT from markdown to Org and fontify.
Runs through `hermes-md-to-org' then `hermes-comint--fontify-as-org'."
  (hermes-comint--fontify-as-org (hermes-md-to-org (or text ""))))

;;;; Buffer-local state

(defvar-local hermes-comint--output-end nil
  "Marker at the end of committed output.
Region `[point-min, output-end)' is read-only committed turns;
`[output-end, prompt-start)' is the pending streaming region.
Insertion-type nil — we advance it explicitly after committed inserts.")

(defvar-local hermes-comint--prompt-start nil
  "Marker at the start of the `> ' prompt prefix.
Region `[prompt-start, point-max)' is the prompt prefix + writable input.
Insertion-type t — advances naturally when content is inserted at its
position (pending stream growing before the prompt).")

(defvar-local hermes-comint--turns-snapshot nil
  "Last-seen `turns' vector for eq-based change detection.")

(defvar-local hermes-comint--stream-timer nil
  "Throttle cooldown timer for streaming repaints.")

(defvar-local hermes-comint--stream-pending nil
  "Latest un-flushed state snapshot waiting for the cooldown.")

(defvar-local hermes-comint--stream-active nil
  "Non-nil while a streaming region is open.")

;;;; Constants

(defconst hermes-comint--prompt-string "> "
  "Prompt prefix string shown at the bottom of the buffer.")

;;;; Mode setup

(defun hermes-comint--apply-output-props (start end)
  "Mark region [START, END) as committed output: field `output', read-only."
  (add-text-properties
   start end
   '(field output
     read-only t
     front-sticky (read-only)
     rear-nonsticky (field read-only font-lock-face))))

(defun hermes-comint--insert-prompt ()
  "Insert the `> ' prompt at point-max and set `prompt-start'.
Also pads the user input area so typed characters do NOT inherit the
read-only property from the prompt prefix."
  (let ((inhibit-read-only t))
    (goto-char (point-max))
    (let ((start (point)))
      (insert hermes-comint--prompt-string)
      ;; The prompt prefix itself: field 'input, read-only.
      ;; `rear-nonsticky '(read-only)' is critical — it makes user-typed
      ;; text inherit `field 'input' (so RET/field navigation works) but
      ;; NOT `read-only' (so typing actually succeeds).
      (add-text-properties
       start (point)
       (list 'field 'input
             'read-only t
             'front-sticky t
             'rear-nonsticky '(read-only face font-lock-face)
             'font-lock-face 'comint-highlight-prompt))
      (setq hermes-comint--prompt-start (copy-marker start t)))))

(defun hermes-comint--setup ()
  "Initialize buffer-local state and insert the initial prompt line."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (setq hermes-comint--turns-snapshot nil)
    (setq hermes-comint--stream-active nil)
    (setq hermes-comint--stream-timer nil)
    (setq hermes-comint--stream-pending nil)
    ;; output-end starts at point-min; advances as committed turns arrive.
    (setq hermes-comint--output-end (copy-marker (point-min) nil))
    (hermes-comint--insert-prompt))
  (add-hook 'hermes-state-change-hook #'hermes-comint--refresh t)
  (add-hook 'kill-buffer-hook #'hermes-comint--detach nil t))

;;;; Helpers — body insertion

(defun hermes-comint--insert-full-text (msg)
  "Insert MSG body text fontified as Org."
  (let ((text (hermes-comint--body-text msg)))
    (unless (string-empty-p text)
      (insert (hermes-comint--fontify-org
               (concat text (unless (string-suffix-p "\n" text) "\n")))))))

(defun hermes-comint--insert-user-body (msg)
  (hermes-comint--insert-full-text msg)
  (dolist (line (hermes-comint--image-lines msg))
    (insert line "\n")))

(defun hermes-comint--insert-system-body (msg)
  (hermes-comint--insert-full-text msg))

(defun hermes-comint--insert-reasoning-block (seg)
  (let ((c (or (hermes-segment-content seg) "")))
    (insert (propertize "--- Reasoning ---\n"
                        'font-lock-face 'hermes-comint-face-reasoning))
    (insert (propertize
             (hermes-comint--fontify-org
              (concat c (if (or (string-empty-p c)
                                (string-suffix-p "\n" c))
                            "" "\n")))
             'font-lock-face 'hermes-comint-face-reasoning))))

(defun hermes-comint--insert-tool-block (tool)
  (let* ((kw (hermes-comint--tool-status-keyword tool))
         (name (or (hermes-tool-name tool) "tool"))
         (dur (hermes-comint--format-duration (hermes-tool-duration tool)))
         (formatter (hermes-tool--lookup name))
         (parts (and formatter (funcall formatter tool)))
         (fmt-summary (or (plist-get parts :summary) name))
         (gw-summary (let ((s (hermes-tool-summary tool)))
                       (if (and s (> (length s) 0)) (format " — %s" s) "")))
         (body (or (plist-get parts :body) "")))
    (insert (propertize (car kw) 'font-lock-face (cdr kw))
            (propertize (format " %s%s%s\n" fmt-summary dur gw-summary)
                        'font-lock-face 'hermes-comint-face-tool))
    (when (and body (> (length body) 0))
      (insert (hermes-comint--fontify-as-org body))
      (unless (bolp) (insert "\n")))))

(defun hermes-comint--insert-subagent-block (sa)
  (let* ((goal (or (hermes-subagent-goal sa) "subagent"))
         (status (or (hermes-subagent-status sa) 'queued))
         (thinking (hermes-subagent-thinking sa))
         (notes (hermes-subagent-notes sa))
         (tools (hermes-subagent-tools sa))
         (summary (hermes-subagent-summary sa))
         (dur (hermes-comint--format-duration (hermes-subagent-duration sa))))
    (insert (propertize (format "Subagent: %s (%s)\n" goal status)
                        'font-lock-face 'hermes-comint-face-subagent))
    (when (and thinking (stringp thinking) (> (length thinking) 0))
      (insert "  thinking: "
              (hermes-comint--fontify-org thinking)
              (if (string-suffix-p "\n" thinking) "" "\n")))
    (when (and (vectorp notes) (> (length notes) 0))
      (insert "  notes:\n")
      (dotimes (i (length notes))
        (insert (format "    - %s\n" (aref notes i)))))
    (when (and (vectorp tools) (> (length tools) 0))
      (insert "  tools:\n")
      (dotimes (i (length tools))
        (let* ((tp (aref tools i))
               (n  (and (listp tp) (or (plist-get tp :name)
                                       (plist-get tp 'name))))
               (a  (and (listp tp) (or (plist-get tp :args)
                                       (plist-get tp 'args)))))
          (insert (format "    - %s%s\n" (or n "tool")
                          (if a (format "(%s)" a) ""))))))
    (when (and (memq status '(complete error)) summary)
      (insert "  result: "
              (hermes-comint--fontify-org summary)
              (if (string-suffix-p "\n" summary) "" "\n")
              (if (string-empty-p dur) "" (format "%s\n" dur))))))

(defun hermes-comint--insert-assistant-body (msg)
  (let* ((segs (or (hermes-message-segments msg) []))
         (sas  (or (hermes-message-subagents msg) [])))
    ;; Pass 1: reasoning blocks
    (dotimes (i (length segs))
      (let ((seg (aref segs i)))
        (when (eq 'reasoning (hermes-segment-type seg))
          (hermes-comint--insert-reasoning-block seg))))
    ;; Pass 2: response text
    (hermes-comint--insert-full-text msg)
    ;; Pass 3: tool blocks
    (dotimes (i (length segs))
      (let ((seg (aref segs i)))
        (when (eq 'tool (hermes-segment-type seg))
          (let ((c (hermes-segment-content seg)))
            (when (hermes-tool-p c)
              (hermes-comint--insert-tool-block c))))))
    ;; Pass 4: subagent blocks
    (dotimes (i (length sas))
      (hermes-comint--insert-subagent-block (aref sas i)))))

;;;; Turn insertion

(defun hermes-comint--insert-turn (msg index)
  "Insert MSG at point as a flat block with field `output' + read-only.
Caller is responsible for positioning point and for advancing
`output-end' or `prompt-start' as appropriate."
  (let* ((kind (hermes-message-kind msg))
         (start (point)))
    (insert (propertize
             (concat (hermes-comint--heading-text msg index) "\n")
             'font-lock-face (hermes-comint--head-face kind)))
    (pcase kind
      ('user      (hermes-comint--insert-user-body msg))
      ('assistant (hermes-comint--insert-assistant-body msg))
      (_          (hermes-comint--insert-system-body msg)))
    (unless (bolp) (insert "\n"))
    (insert "\n")
    (hermes-comint--apply-output-props start (point))))

;;;; State refresh dispatch

(defun hermes-comint--refresh (old new)
  "Dispatch state diffs.  Subscriber on `hermes-state-change-hook'."
  (hermes--on-session-buffer hermes-comint--buffers
    (let ((old-stream (and old (hermes-state-stream old)))
          (new-stream (hermes-state-stream new)))
      (cond
       ;; Stream began.
       ((and (null old-stream) new-stream)
        (hermes-comint--stream-begin new))
       ;; Stream ended → commit pending region.
       ((and old-stream (null new-stream))
        (hermes-comint--stream-commit new))
       ;; Stream delta → throttled repaint.
       ((and old-stream new-stream (not (eq old-stream new-stream)))
        (hermes-comint--stream-update new))
       ;; New committed turn(s) with no active stream.
       ((not (eq (hermes-state-turns new)
                 hermes-comint--turns-snapshot))
        (hermes-comint--append-new-turns new))
       ;; Otherwise: refresh header-line (bg / attachments may have changed).
       (t
        (hermes-comint--refresh-header-line new))))
    (hermes-comint--refresh-header-line new)))

;;;; Committed appends

(defun hermes-comint--append-new-turns (state)
  "Append turns from STATE not yet visible in the buffer."
  (let* ((inhibit-read-only t)
         (turns (hermes-state-turns state))
         (start-idx (if hermes-comint--turns-snapshot
                        (length hermes-comint--turns-snapshot)
                      0))
         (total (length turns)))
    (when (> total start-idx)
      (save-excursion
        (goto-char (marker-position hermes-comint--output-end))
        (cl-loop for i from start-idx below total
                 do (hermes-comint--insert-turn (aref turns i) (1+ i)))
        (set-marker hermes-comint--output-end (point))))
    (setq hermes-comint--turns-snapshot turns)))

;;;; Streaming

(defun hermes-comint--paint-stream (state)
  "Replace the pending region with the current in-flight turn."
  (let* ((inhibit-read-only t)
         (stream (hermes-state-stream state))
         (turns  (hermes-state-turns state))
         (index  (1+ (length turns)))
         (msg    (hermes--message-from-stream stream nil)))
    (when stream
      (let ((out-end (marker-position hermes-comint--output-end))
            (pr-start (marker-position hermes-comint--prompt-start)))
        (delete-region out-end pr-start)
        (save-excursion
          (goto-char (marker-position hermes-comint--output-end))
          (hermes-comint--insert-turn msg index))))
    (hermes-comint--ensure-prompt-visible)))

(defun hermes-comint--stream-begin (state)
  "Open a streaming region at output-end and paint the initial turn."
  (setq hermes-comint--stream-active t)
  (hermes-comint--paint-stream state))

(defun hermes-comint--stream-update (state)
  "Throttled repaint of the streaming region."
  (cond
   ((not (hermes--buffer-visible-p (current-buffer)))
    nil)
   ((null hermes-comint--stream-timer)
    (hermes-comint--paint-stream state)
    (setq hermes-comint--stream-timer
          (run-with-timer 0.04 nil
                          #'hermes-comint--stream-flush
                          (current-buffer))))
   (t
    (setq hermes-comint--stream-pending state))))

(defun hermes-comint--stream-flush (buf)
  "Timer callback: paint the latest pending snapshot into BUF."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq hermes-comint--stream-timer nil)
      (let ((ns hermes-comint--stream-pending))
        (setq hermes-comint--stream-pending nil)
        (when (and ns (hermes-state-stream ns)
                   (hermes--buffer-visible-p buf))
          (hermes-comint--paint-stream ns)
          (setq hermes-comint--stream-timer
                (run-with-timer 0.04 nil
                                #'hermes-comint--stream-flush buf)))))))

(defun hermes-comint--stream-cancel-timer ()
  (when (timerp hermes-comint--stream-timer)
    (cancel-timer hermes-comint--stream-timer))
  (setq hermes-comint--stream-timer nil
        hermes-comint--stream-pending nil))

(defun hermes-comint--stream-commit (state)
  "End streaming: pending region becomes part of committed history.
Advances `output-end' past the just-finished turn so future appends
land at the right boundary."
  (hermes-comint--stream-cancel-timer)
  (setq hermes-comint--stream-active nil)
  ;; The pending region was painted from the now-finished stream.  But
  ;; the reducer pushed the finished message into `turns' before clearing
  ;; the stream, so the turn is also present in state.  We re-paint from
  ;; the committed turn (which carries final usage / timestamps), then
  ;; advance output-end past it.
  (let* ((inhibit-read-only t)
         (turns (hermes-state-turns state))
         (out-end (marker-position hermes-comint--output-end))
         (pr-start (marker-position hermes-comint--prompt-start)))
    (delete-region out-end pr-start)
    (when (and (vectorp turns) (> (length turns) 0))
      (save-excursion
        (goto-char (marker-position hermes-comint--output-end))
        (hermes-comint--insert-turn
         (aref turns (1- (length turns)))
         (length turns))
        (set-marker hermes-comint--output-end (point))))
    (setq hermes-comint--turns-snapshot turns))
  (hermes-comint--ensure-prompt-visible))

;;;; Header-line

(defun hermes-comint--format-header-line (state)
  "Return a header-line string for STATE, or nil."
  (when state
    (let ((parts nil)
          (bg (hermes-state-bg-tasks state))
          (running 0))
      (when (vectorp bg)
        (dotimes (i (length bg))
          (when (eq 'running (hermes-bg-task-status (aref bg i)))
            (cl-incf running)))
        (cond
         ((> running 0)
          (push (format "[bg: %d running]" running) parts))
         ((> (length bg) 0)
          (catch 'done
            (dotimes (i (length bg))
              (let ((bt (aref bg (- (length bg) 1 i))))
                (when (memq (hermes-bg-task-status bt) '(complete error))
                  (push (format "[bg #%s %s]"
                                (or (hermes-bg-task-task-id bt) "?")
                                (symbol-name (hermes-bg-task-status bt)))
                        parts)
                  (throw 'done nil))))))))
      (let ((atts (hermes-state-attachments state)))
        (when atts
          (push (format "[%d attachment(s)]" (length atts)) parts)))
      (when parts
        (string-join (nreverse parts) "  ")))))

(defun hermes-comint--refresh-header-line (state)
  (setq header-line-format (hermes-comint--format-header-line state)))

;;;; Input

(defun hermes-comint--prompt-text ()
  "Return user-typed text after the `> ' prefix."
  (let* ((p (marker-position hermes-comint--prompt-start))
         (input-start (+ p (length hermes-comint--prompt-string))))
    (if (>= input-start (point-max))
        ""
      (buffer-substring-no-properties input-start (point-max)))))

(defun hermes-comint--clear-prompt ()
  "Delete user-typed text after the prompt prefix."
  (let* ((p (marker-position hermes-comint--prompt-start))
         (input-start (+ p (length hermes-comint--prompt-string)))
         (inhibit-read-only t))
    (when (< input-start (point-max))
      (delete-region input-start (point-max)))))

(defun hermes-comint-send ()
  "Send the prompt text via `hermes-send'.
Pushes to `comint-input-ring' for M-p/M-n cycling."
  (interactive)
  (let* ((text (hermes-comint--prompt-text))
         (input (string-trim text)))
    (when (string-empty-p input)
      (user-error "Nothing to send"))
    (when (or (null comint-input-ring)
              (ring-empty-p comint-input-ring)
              (not (string-equal input (ring-ref comint-input-ring 0))))
      (when (ring-p comint-input-ring)
        (ring-insert comint-input-ring input)))
    (setq comint-input-ring-index nil)
    (hermes-comint--clear-prompt)
    (hermes-send input)))

(defun hermes-comint-previous-input (arg)
  "Cycle backwards through `comint-input-ring'."
  (interactive "p")
  (unless (and (ring-p comint-input-ring)
               (not (ring-empty-p comint-input-ring)))
    (user-error "No input history"))
  (let* ((len (ring-length comint-input-ring))
         (idx (mod (+ arg (or comint-input-ring-index -1)) len)))
    (hermes-comint--clear-prompt)
    (setq comint-input-ring-index idx)
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert (ring-ref comint-input-ring idx)))))

(defun hermes-comint-next-input (arg)
  "Cycle forwards through `comint-input-ring'."
  (interactive "p")
  (hermes-comint-previous-input (- arg)))

(defun hermes-comint-interrupt ()
  "Interrupt the current session."
  (interactive)
  (call-interactively #'hermes-interrupt-current-session))

(defun hermes-comint-focus-prompt ()
  "Move point into the writable input area."
  (interactive)
  (goto-char (point-max)))

;;;; Visibility / display

(defun hermes-comint--ensure-prompt-visible ()
  "Scroll windows so the prompt is visible."
  (dolist (w (get-buffer-window-list (current-buffer) nil t))
    (when (window-live-p w)
      (with-selected-window w
        (when (< (window-point w) (marker-position hermes-comint--prompt-start))
          (set-window-point w (point-max)))))))

;;;; Load + refresh

(defun hermes-comint--load-from-state (state)
  "Populate the buffer with all committed turns from STATE.
Assumes the prompt is already inserted at point-max."
  (let* ((inhibit-read-only t)
         (turns (hermes-state-turns state))
         (total (length turns)))
    (save-excursion
      (goto-char (marker-position hermes-comint--output-end))
      (dotimes (i total)
        (hermes-comint--insert-turn (aref turns i) (1+ i)))
      (set-marker hermes-comint--output-end (point)))
    (setq hermes-comint--turns-snapshot turns)
    (hermes-comint--refresh-header-line state)))

(defun hermes-comint-refresh ()
  "Rebuild the buffer from state."
  (interactive)
  (let ((state (hermes--state-slot-read hermes--current-session-id))
        (inhibit-read-only t))
    (when state
      ;; Reset markers, wipe content (preserving the prompt at end), reload.
      (let ((pr-start (marker-position hermes-comint--prompt-start)))
        (delete-region (point-min) pr-start)
        (set-marker hermes-comint--output-end (point-min))
        (setq hermes-comint--turns-snapshot nil)
        (hermes-comint--load-from-state state))
      (goto-char (point-max)))))

;;;; Detach

(defun hermes-comint--detach ()
  "Detach this buffer from the registry on kill."
  (hermes-comint--stream-cancel-timer)
  (when (and hermes--current-session-id
             (eq (current-buffer)
                 (gethash hermes--current-session-id
                          hermes-comint--buffers)))
    (let ((sid hermes--current-session-id))
      (remhash sid hermes-comint--buffers)
      (when (fboundp 'hermes--maybe-kill-bench)
        (hermes--maybe-kill-bench sid)))))

;;;; Keymap

(defvar hermes-comint-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m comint-mode-map)
    (define-key m (kbd "RET")     #'hermes-comint-send)
    (define-key m (kbd "C-c C-c") #'hermes-comint-send)
    (define-key m (kbd "M-p")     #'hermes-comint-previous-input)
    (define-key m (kbd "M-n")     #'hermes-comint-next-input)
    (define-key m (kbd "C-c C-k") #'hermes-comint-interrupt)
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-i") #'hermes-comint-focus-prompt)
    (define-key m (kbd "C-c C-r") #'hermes-comint-refresh)
    m)
  "Keymap for `hermes-comint-mode'.")

;;;; Major mode

(define-derived-mode hermes-comint-mode comint-mode "Hermes-Comint"
  "Comint-derived conversation viewer for Hermes sessions.
Read-only output history with a writable prompt at the bottom.
Projects from the same `turns' state as the org viewer.

\\{hermes-comint-mode-map}"
  ;; Field-based prompt detection (modern default — not regexp).
  (setq-local comint-use-prompt-regexp nil)
  (setq-local comint-prompt-regexp
              (concat "^" (regexp-quote hermes-comint--prompt-string)))
  ;; History ring for M-p / M-n.
  (setq-local comint-input-ring-size 500)
  (setq-local comint-input-ring (make-ring comint-input-ring-size))
  (setq-local comint-input-ring-index nil)
  ;; No process — comint-input-sender is unused but must be bound.
  (setq-local comint-input-sender (lambda (_p _s) nil))
  (setq-local comint-eol-on-send nil)
  (setq-local comint-scroll-to-bottom-on-input t)
  (setq-local comint-move-point-for-output 'this)
  (setq-local comint-scroll-show-maximum-output t)
  (visual-line-mode 1)
  (setq-local scroll-conservatively 101)
  (setq-local scroll-margin 0)
  (hermes-comint--setup))

;;;; Session picker

(defun hermes-comint--pick-session ()
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

;;;; Open + entry point

(defun hermes-comint--open (sid)
  "Open a comint conversation buffer for session SID."
  (let* ((name (format "*hermes-comint:%s*" sid))
         (existing (gethash sid hermes-comint--buffers))
         (buf (if (buffer-live-p existing)
                  existing
                (get-buffer-create name))))
    (with-current-buffer buf
      (unless (derived-mode-p 'hermes-comint-mode)
        (hermes-comint-mode)
        (setq-local hermes--current-session-id sid)
        (puthash sid buf hermes-comint--buffers)
        (let ((state (hermes--state-slot-read sid)))
          (when state
            (hermes-comint--load-from-state state)))))
    (pop-to-buffer buf)
    (with-current-buffer buf
      (goto-char (point-max))
      (hermes-comint--ensure-prompt-visible))
    buf))

;;;###autoload
(defun hermes-comint (&optional arg)
  "Open a comint-mode conversation viewer.
With prefix ARG, always create a new session."
  (interactive "P")
  (require 'hermes-mode)
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (cond
   ((derived-mode-p 'hermes-comint-mode)
    (message "Already in a Hermes comint buffer"))
   (arg
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-comint--open
          (buffer-local-value 'hermes--current-session-id buf))))))
   ((hermes--session-exists-p)
    (let ((sid (hermes-comint--pick-session)))
      (when sid (hermes-comint--open sid))))
   (t
    (hermes-new-session
     (lambda (buf)
       (when buf
         (hermes-comint--open
          (buffer-local-value 'hermes--current-session-id buf))))))))

(provide 'hermes-comint)
;;; hermes-comint.el ends here
