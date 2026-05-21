;;; hermes-mode.el --- Org-derived major mode and session entry point -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `hermes-mode' is the major mode for a conversation buffer.  It derives
;; from `org-mode' so headlines, folding, properties and links work for
;; free.  The buffer's textual history is read-only; input happens via
;; `hermes-send' (minibuffer prompt) bound to `C-c C-i'.
;;
;; `hermes' is the entrypoint: start the gateway, create a session, open
;; a buffer.

;;; Code:

(require 'org)
(require 'hermes-rpc)
(require 'hermes-events)
(require 'hermes-state)
(require 'hermes-render)
(require 'hermes-prompts)
(require 'hermes-input)
(require 'hermes-sessions)
(require 'hermes-skin)
(require 'hermes-compose)
(require 'hermes-org)
(require 'hermes-bench)
(require 'hermes-config)
(require 'hermes-image)
(require 'hermes-project)

;;;; Routing: filter event → buffer

(defvar hermes--session-buffers (make-hash-table :test 'equal)
  "Map of session-id → conversation buffer.")

(defvar hermes--last-gateway-ready nil
  "Most recent `gateway.ready' payload, cached for replay into new buffers.
The event broadcasts to every existing session buffer when it arrives, but
the first session is typically created AFTER `gateway.ready' lands — so
without this cache, the very first buffer would never see the skin.")

(defun hermes--lookup-buffer (session-id)
  "Return the buffer for SESSION-ID, or nil."
  (let ((buf (gethash session-id hermes--session-buffers)))
    (and (buffer-live-p buf) buf)))

;;;; Event routing — installed once on the RPC layer

(defun hermes--route-event (type session-id payload)
  "Dispatch event TYPE/PAYLOAD into the session buffer's atoms."
  (when (or (equal type "gateway.ready") (equal type "skin.changed"))
    (setq hermes--last-gateway-ready payload))
  (let ((buf (and session-id (not (string-empty-p session-id))
                  (hermes--lookup-buffer session-id))))
    ;; Some events arrive before we know the session id (gateway.ready,
    ;; skin.changed) — broadcast those to every existing Hermes buffer.
     (cond
      (buf (with-current-buffer buf
             (hermes-dispatch (cons type payload) session-id)
             (hermes-ui-dispatch (cons type payload) session-id)))
      ((or (null session-id) (string-empty-p session-id))
       (hermes--broadcast-dispatch type payload)))))

(defun hermes--route-connection (state)
  "Broadcast a connection state change into every Hermes buffer."
  ;; Clear the cached `gateway.ready' payload so that the *next* time we
  ;; reconnect we wait for a fresh one before firing `session.create'.
  (when (eq state 'disconnected)
    (setq hermes--last-gateway-ready nil))
  (maphash (lambda (_sid b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (hermes-dispatch
                  (list (pcase state
                          ('connecting   :connecting)
                          ('connected    :connected)
                          ('disconnected :disconnected)
                          (_             :disconnected)))))))
           hermes--session-buffers))

(defun hermes--broadcast-dispatch (type payload)
  "Dispatch TYPE + PAYLOAD to every active Hermes buffer."
  (maphash (lambda (_sid b)
             (when (buffer-live-p b)
               (with-current-buffer b
                 (hermes-dispatch (cons type payload))
                 (hermes-ui-dispatch (cons type payload)))))
           hermes--session-buffers))

(defun hermes--route-stderr (line)
  "Broadcast a `gateway.stderr' event with LINE to all Hermes buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "line" line ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.stderr" payload)))

(defun hermes--route-protocol-error (preview)
  "Broadcast a `gateway.protocol_error' event with PREVIEW to all buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "preview" preview ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.protocol_error" payload)))

(defun hermes--route-start-timeout (lines)
  "Broadcast a `gateway.start_timeout' event with LINES to all buffers."
  (let ((payload (let ((ht (make-hash-table :test #'equal)))
                   (puthash "lines" lines ht)
                   ht)))
    (hermes--broadcast-dispatch "gateway.start_timeout" payload)))

(defun hermes--install-hooks ()
  "Wire RPC hooks once.  Truly idempotent — removes before adding."
  (remove-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (remove-hook 'hermes-rpc-event-functions #'hermes-sessions--refresh-if-open)
  (remove-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (remove-hook 'hermes-rpc-connection-functions #'hermes-sessions--refresh-if-open)
  (remove-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (remove-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (remove-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout)
  (add-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (add-hook 'hermes-rpc-event-functions #'hermes-sessions--refresh-if-open)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (add-hook 'hermes-rpc-connection-functions #'hermes-sessions--refresh-if-open)
  (add-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (add-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (add-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout))

;;;; Major mode

(defvar hermes-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-i") #'hermes-send-or-focus-bench)
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt)
    (define-key m (kbd "C-c C-v") #'hermes-view-log)
    (define-key m (kbd "C-c C-m") #'hermes-set-model)
    (define-key m (kbd "C-c C-f") #'hermes-toggle-fast)
    (define-key m (kbd "C-c C-a") #'hermes-image-attach-file)
    m)
  "Keymap for `hermes-mode'.")

(with-eval-after-load 'which-key
  (when (fboundp 'which-key-add-keymap-based-replacements)
    (which-key-add-keymap-based-replacements hermes-mode-map
      "C-c C-i" "Send / focus bench"
      "C-c C-l" "Compose multi-line"
      "C-c C-k" "Interrupt session"
      "C-c C-v" "View log"
      "C-c C-m" "Set model"
      "C-c C-f" "Toggle fast mode"
      "C-c C-a" "Attach image file")))

(defun hermes-minor-mode--on ()
  "Setup for `hermes-minor-mode': org-local config, hooks, header-line.
Idempotent — safe to run when already armed.  In Phase 1 the major mode
creates the state atom before enabling the minor mode; if no state is
present (Phase 2: arbitrary Org buffers), one is created here."
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq-local org-todo-keywords
              '((sequence "RUNNING(r)" "|" "DONE(d)" "ERROR(e)")))
  (setq-local org-todo-keyword-faces
              '(("RUNNING" . hermes-tool-running-face)
                ("DONE"    . hermes-tool-done-face)
                ("ERROR"   . hermes-tool-error-face)))
  (unless (and (boundp 'hermes--state) hermes--state)
    (hermes-state-init))
  ;; Ensure RPC event hooks are wired so events for sessions hosted in
  ;; this buffer route through `hermes--route-event'.  Idempotent.
  (hermes--install-hooks)
  (add-hook 'org-cycle-hook #'hermes--remember-cycle nil t)
  ;; Order matters: `hermes--render' MUST run before `hermes-input--drain'.
  ;; If drain runs first, it dispatches `:user-submit' for the queued
  ;; head; the recursive render inserts that user heading at point-max
  ;; with stream already nil → `stream-commit' won't have fired yet, so
  ;; when the outer render finally runs, `bench-end' has been rear-
     ;; advanced past the user content and the assistant turn lands
  ;; at the end of the buffer.  `add-hook' with nil APPEND *prepends*,
  ;; reversing insertion order — so we explicitly append.
  (add-hook 'hermes-state-change-hook    #'hermes--render        t t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  t t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   t t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     t t)
  (add-hook 'hermes-state-change-hook    #'hermes--mode-line-update t t)
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     t t)
  ;; Drop pending throttle timer on buffer kill so it can't fire into a
  ;; dead buffer.
  (add-hook 'kill-buffer-hook            #'hermes--stream-flush-cancel nil t)
  ;; Move Hermes status from the top header-line to the bottom mode-line.
  ;; Use a self-contained format that preserves basic mode-line elements
  ;; alongside the Hermes status segment.
  (setq-local mode-line-format
              '("%e"
                mode-line-modified
                " "
                mode-line-buffer-identification
                "  "
                (:eval hermes--mode-line-status)
                (:eval (let* ((label (if (derived-mode-p 'hermes-mode) "Hermes-Org"))
                             (text  (concat " " label)))
                          (concat
                           (propertize " " 'display
                                       (list 'space :align-to
                                             (list '- 'right (length text))))
                           (propertize label 'face 'mode-line-emphasis))))))
  (setq header-line-format nil)
  (hermes--mode-line-update hermes--state))

(defun hermes-minor-mode--off ()
  "Teardown for `hermes-minor-mode': removes hooks, clears header-line."
  (remove-hook 'org-cycle-hook #'hermes--remember-cycle t)
  (remove-hook 'hermes-state-change-hook #'hermes--render t)
  (remove-hook 'hermes-state-change-hook #'hermes-prompts-watch t)
  (remove-hook 'hermes-state-change-hook #'hermes-input--drain t)
  (remove-hook 'hermes-state-change-hook #'hermes-skin-watch t)
  (remove-hook 'hermes-state-change-hook #'hermes--mode-line-update t)
  (remove-hook 'hermes-ui-state-change-hook #'hermes--render-ui t)
  (remove-hook 'kill-buffer-hook #'hermes--stream-flush-cancel t)
  (hermes--stream-flush-cancel)
  (kill-local-variable 'mode-line-format)
  (setq header-line-format nil))

;;;###autoload
(define-minor-mode hermes-minor-mode
  "Minor mode for Hermes presentation in Org buffers.
Provides streaming render, auto-fold, header-line, and key bindings.
When enabled in the dedicated `*hermes*' buffer, it is the full
presentation layer.  When enabled in arbitrary Org buffers (Phase 2),
it renders a heading-scoped session into that subtree."
  :init-value nil
  :lighter " Hermes"
  :keymap hermes-mode-map
  (if hermes-minor-mode
      (hermes-minor-mode--on)
    (hermes-minor-mode--off)))

(define-derived-mode hermes-mode org-mode "Hermes"
  "Major mode for a dedicated Hermes conversation buffer.
Thin wrapper: enables `org-mode', turns on `hermes-minor-mode' (which
owns all presentation logic), initialises session state, and inserts
the session container heading."
  (hermes-state-init)
  (hermes-minor-mode 1)
  (setq-local hermes--container-level 1)
  (save-excursion
    (goto-char (point-min))
    (insert (concat (make-string hermes--container-level ?*)
                    " Hermes session :hermes:\n"))))

(defun hermes-send-or-focus-bench ()
  "If the bench is active, focus its input; otherwise call `hermes-send'."
  (interactive)
  (let ((bench (and (derived-mode-p 'hermes-mode)
                    (hermes-bench-active-p))))
    (cond
     ((and bench (get-buffer-window bench))
      (select-window (get-buffer-window bench))
      (goto-char (point-max)))
     (bench
      (hermes-bench-ensure (current-buffer))
      (let ((w (get-buffer-window bench)))
        (when (window-live-p w)
          (select-window w)
          (goto-char (point-max)))))
     (t (call-interactively #'hermes-send)))))

;;;; Public entry points

(defun hermes--do-session-create (callback)
  "Internal: send `session.create' and wire its response to CALLBACK."
  ;; Capture the project root from the caller's buffer *before* the
  ;; async response, when `default-directory' still points at whatever
  ;; the user was visiting.
  (let ((detected-cwd (ignore-errors (hermes-project-detect-cwd))))
    (hermes-rpc-request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error
         (message "hermes: session.create failed: %S" error)
         (when callback (funcall callback nil)))
        (result
         (let* ((sid (gethash "session_id" result))
                (buf (generate-new-buffer (format "*hermes:%s*" sid))))
           (puthash sid buf hermes--session-buffers)
           (with-current-buffer buf
             (hermes-mode)
              (setf (hermes-state-session-id hermes--state) sid)
              (when detected-cwd
                (setf (hermes-state-cwd hermes--state) detected-cwd))
              (save-excursion
                (goto-char (point-min))
                (when (org-at-heading-p)
                  (org-set-property "HERMES_SESSION" sid)
                  (when detected-cwd
                    (org-set-property "HERMES_CWD"
                                      (abbreviate-file-name detected-cwd)))))
           ;; Register the session in the buffer-local registry so the
           ;; slice-B dispatcher can resolve `session-id' → state.  The
           ;; marker tracks the container heading at point-min.
           (hermes--register-session
            sid hermes--state
            (save-excursion (goto-char (point-min)) (copy-marker (point) nil)))
           (when hermes--last-gateway-ready
             (hermes-dispatch
              (cons "gateway.ready" hermes--last-gateway-ready)))
           (hermes-input-fetch-catalog))
         (when callback (funcall callback buf)))))))))

(defun hermes-new-session (&optional callback)
  "Start the gateway (if needed), create a session, and prepare its buffer.
The buffer is registered in `hermes--session-buffers' but NOT popped to the
user; that's the caller's job.  CALLBACK, if non-nil, is called with the new
buffer (or nil on error) once `session.create' resolves.

If the gateway is still warming up, the request is queued by the transport
(`hermes-rpc--pending-frames') and flushed when `gateway.ready' arrives —
no special-casing required here.

This is the building block dashboards use to spawn sessions in the
background; for the user-facing entry that also pops the buffer, see
`hermes'."
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (hermes--do-session-create callback))

(defun hermes--live-session-buffers ()
  "Return live session buffers, most-recently-touched first."
  (let (acc)
    (maphash (lambda (_sid b) (when (buffer-live-p b) (push b acc)))
             hermes--session-buffers)
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))

(defun hermes--primary-session-buffer ()
  "Return the most-recently-active live session buffer, or nil."
  (car (hermes--live-session-buffers)))

;;;###autoload
(defun hermes ()
  "Context-aware entry point — never sends a prompt.
- In a `hermes-mode' buffer: ensure the bench is visible and focus its
  input area.
- In a generic `org-mode' buffer: create a Hermes session heading as a
  direct child of the heading at/above point.
- Everywhere else: pop the most-recently-touched live session, or
  create a fresh one if none exists."
  (interactive)
  (cond
   ((derived-mode-p 'hermes-mode)
    (hermes-bench-ensure (current-buffer))
    (let* ((bench (hermes-bench-active-p))
           (win   (and bench (get-buffer-window bench))))
      (when (window-live-p win)
        (select-window win)
        (goto-char (point-max)))))
   ((derived-mode-p 'org-mode)
    (let* ((marker (hermes--container-marker-at-point))
           (sid    (and marker (hermes--session-at-point)))
           (state  (and sid (hermes--lookup-session-state sid))))
      (cond
       (state
        (hermes-bench-ensure (current-buffer))
        (let* ((bench (hermes-bench-active-p))
               (win   (and bench (get-buffer-window bench))))
          (when (window-live-p win)
            (select-window win)
            (goto-char (point-max)))))
       (sid
        (hermes--handle-stale-heading sid marker))
       (t
        (hermes--create-session-under-heading)))))
   (t
    ;; No auto-resume from gateway DB here by design: the org buffer is the
    ;; canonical history.  To resume a DB session, open its `.org' file and
    ;; run `M-x hermes' inside the `:hermes:' subtree — the stale-heading
    ;; prompt (`hermes--handle-stale-heading') offers load-from-org,
    ;; resume-from-DB, and branch-from-DB.  Or use the DB browser:
    ;; `M-x hermes-sessions-db'.
    (let ((buf (hermes--primary-session-buffer)))
      (if buf
          (progn
            (pop-to-buffer-same-window buf)
            (hermes-bench-ensure buf)
            (hermes--focus-bench-input buf))
        (hermes-new-session
         (lambda (b)
           (when (buffer-live-p b)
             (pop-to-buffer-same-window b)
             (hermes-bench-ensure b)
             (hermes--focus-bench-input b)))))))))

(defun hermes--focus-bench-input (buf)
  "Select the bench window for BUF and move point to its input end."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (let* ((bench (hermes-bench-active-p))
             (win   (and bench (get-buffer-window bench))))
        (when (window-live-p win)
          (select-window win)
          (goto-char (point-max)))))))

(defalias 'hermes-send #'hermes-input-send
  "Queue-aware submission entry; see `hermes-input-send'.")

(defun hermes-reconnect ()
  "Restart the gateway (if needed) and bind the current buffer to a fresh session.
Used after the gateway subprocess has died.  The old session id is removed
from `hermes--session-buffers' once the new one is bound; the buffer is
renamed accordingly; the slash-command catalog is re-fetched; and any
queued input is drained."
  (interactive)
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let ((buf (current-buffer)))
    (hermes-rpc-request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: reconnect session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let ((old-sid (hermes-state-session-id hermes--state)))
                 (when (and old-sid (not (equal old-sid sid)))
                   (remhash old-sid hermes--session-buffers)
                   (when (hash-table-p hermes--buffer-sessions)
                     (remhash old-sid hermes--buffer-sessions))
                   (when (hash-table-p hermes--session-markers)
                     (remhash old-sid hermes--session-markers))))
               (puthash sid buf hermes--session-buffers)
               (setf (hermes-state-session-id hermes--state) sid)
               (hermes--register-session
                sid hermes--state
                (save-excursion (goto-char (point-min)) (copy-marker (point) nil)))
               (rename-buffer (generate-new-buffer-name
                               (format "*hermes:%s*" sid)))
               (when hermes--last-gateway-ready
                 (hermes-dispatch
                  (cons "gateway.ready" hermes--last-gateway-ready)))
               (hermes-input-fetch-catalog)
               (hermes-input--drain-after-reconnect)
               (message "hermes: reconnected as %s" sid))))))))))

(defun hermes-interrupt ()
  "Send `session.interrupt' for the Hermes session at point.
In the dedicated `*hermes*' buffer this is always the buffer's
session; in an arbitrary Org buffer with `hermes-minor-mode' enabled,
it resolves to the `:hermes:' container containing point."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (sid (car target)))
    (unless target
      (user-error "No Hermes session at point"))
    (unless sid (user-error "No session id assigned yet"))
    (hermes-rpc-request "session.interrupt"
                        (list :session_id sid)
                        (lambda (_r e)
                          (when e (message "hermes: interrupt error: %S" e))))
    ;; Drop any pending attachments — they were tied to the cancelled turn.
    (hermes-dispatch '(:attachments-clear) sid)))

(defun hermes--create-session-under-heading ()
  "Insert a Hermes session heading as a child of the heading at/above point.
Used by `hermes' when invoked from a generic `org-mode' buffer.  The
heading is added at the end of the parent's subtree so existing body
text is never split.  `hermes--container-level' is set buffer-locally
so turn insertion follows the relative depth."
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (unless (bound-and-true-p hermes-minor-mode)
    (hermes-minor-mode 1))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let* ((insert-pos nil)
         (container-level
          (save-excursion
            (if (ignore-errors (org-back-to-heading t))
                (let ((lvl (1+ (org-current-level))))
                  (org-end-of-subtree t t)
                  (setq insert-pos (point))
                  lvl)
              (goto-char (point-max))
              (setq insert-pos (point))
              1)))
         (buf (current-buffer)))
    (goto-char insert-pos)
    (unless (bolp) (insert "\n"))
    (let* ((heading-pos (point))
           (_ (insert (format "%s Hermes session :hermes:\n"
                              (make-string container-level ?*))))
           (marker (copy-marker heading-pos nil)))
      (setq-local hermes--container-level container-level)
      (hermes-rpc-request
       "session.create" '(:cols 100)
       (lambda (result error)
         (cond
          (error
           (message "hermes: session.create failed: %S" error))
          (result
           (let ((sid (gethash "session_id" result)))
             (when (and sid (buffer-live-p buf))
               (with-current-buffer buf
                 (save-excursion
                   (goto-char (marker-position marker))
                   (when (org-at-heading-p)
                     (org-set-property "HERMES_SESSION" sid)))
                 (let ((state (make-hermes-state :session-id sid
                                                 :connection 'connected)))
                   (hermes--register-session sid state marker)
                   (setq hermes--state state))
                 (puthash sid buf hermes--session-buffers)
                 (when hermes--last-gateway-ready
                   (hermes-dispatch
                    (cons "gateway.ready" hermes--last-gateway-ready)
                    sid))
                 (message "hermes: session %s ready" sid)))))))))))

(defun hermes-view-log ()
  "Pop to the *hermes-log* diagnostic buffer."
  (interactive)
  (pop-to-buffer (hermes--log-buffer)))

;;;; Buffer parsing — read canonical history back from the Org buffer

(defun hermes--buffer-message-count ()
  "Count committed turns in the current buffer.
A turn is a heading one level below the session container carrying a
recognized `:HERMES_KIND:' property.  The container itself and any
deeper sub-headings (reasoning/response/tools) are skipped."
  (let ((count 0)
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (and (= turn-level (org-current-level))
                    (let ((k (org-entry-get (point) "HERMES_KIND")))
                      (member k '("USER" "ASSISTANT" "SYSTEM"))))
           (cl-incf count)))
       nil nil 'file))
    count))

(defun hermes--parse-buffer-messages ()
  "Walk the buffer and return a vector of `hermes-message' structs.
Derives each turn from its visible Org structure: heading properties
for metadata and usage, body text + `#+attr_org:'/`#+attr_hermes:'
lines for content (including images), child SUBAGENT headings for
subagents."
  (let (messages
        (turn-level (1+ hermes--container-level)))
    (when (derived-mode-p 'org-mode)
      (org-map-entries
       (lambda ()
         (when (= turn-level (org-current-level))
           (let ((msg (hermes--parse-turn-at-point)))
             (when msg
               (push msg messages)))))
       nil nil 'file))
    (vconcat (nreverse messages))))

(defun hermes-load-org ()
  "Create a fresh gateway session bound to the current buffer.
The gateway does not accept a history parameter, so conversation
context is restored via the history seed on the first outgoing
prompt (see `hermes--build-history-text')."
  (interactive)
  (unless (derived-mode-p 'hermes-mode)
    (user-error "Not in a Hermes buffer"))
  (let* ((history (hermes--parse-buffer-messages)))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes-rpc-request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: load-org session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when sid
             (setf (hermes-state-session-id hermes--state) sid)
             (puthash sid (current-buffer) hermes--session-buffers)
             (hermes--register-session
              sid hermes--state
              (save-excursion
                (goto-char (point-min)) (copy-marker (point) nil)))
             ;; Reset the seed stamp so the next prompt restores context.
             (setq hermes--seeded-session-id nil)
             (message "hermes: loaded org as %s (%d turns parsed)"
                      sid (length history))))))))))

;;;; Debug inspectors

(defun hermes-inspect-turn ()
  "Pretty-print the parsed turn at point into a temp buffer.
Shows the parsed `hermes-message' struct as reconstructed by
`hermes--parse-turn-at-point' from the visible Org structure."
  (interactive)
  (let ((msg (save-excursion
               (when (derived-mode-p 'org-mode)
                 (ignore-errors (org-back-to-heading t)))
               (hermes--parse-turn-at-point))))
    (unless msg
      (user-error "No Hermes turn at point"))
    (let ((buf (get-buffer-create "*Hermes Turn Inspector*")))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (emacs-lisp-mode)
          (insert ";; Parsed hermes-message:\n")
          (pp (hermes--message-to-plist msg) (current-buffer))
          (goto-char (point-min)))
        (setq buffer-read-only t))
      (display-buffer buf))))

(defun hermes-debug-state ()
  "Pop a buffer inspecting the live `hermes--state' atom."
  (interactive)
  (unless (and (boundp 'hermes--state) hermes--state)
    (user-error "No Hermes state in this buffer"))
  (let* ((st hermes--state)
         (data `(:session-id    ,(hermes-state-session-id st)
                 :connection    ,(hermes-state-connection st)
                 :stream        ,(and (hermes-state-stream st) t)
                 :queue-length  ,(length (hermes-state-queue st))
                 :pending       ,(hermes-state-pending st)
                 :history-len   ,(length (hermes-state-history st))
                 :slash-catalog ,(and (hermes-state-slash-catalog st) t)
                 :session-info  ,(hermes-state-session-info st)
                 :usage         ,(hermes-state-usage st)
                 :busy-mode     ,(hermes-state-busy-mode st)))
         (buf (get-buffer-create "*Hermes State Inspector*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp data (current-buffer))
        (goto-char (point-min)))
      (setq buffer-read-only t))
    (display-buffer buf)))

(declare-function hermes-bg--list-for-sid "hermes-bg" (sid))

;;;###autoload
(defun hermes-bg-list ()
  "Pop a tabulated list of background tasks for the current session."
  (interactive)
  (let ((sid (and (boundp 'hermes--state)
                  hermes--state
                  (hermes-state-session-id hermes--state))))
    (if sid
        (progn (require 'hermes-bg)
               (hermes-bg--list-for-sid sid))
      (user-error "No active Hermes session in this buffer"))))

(provide 'hermes-mode)
;;; hermes-mode.el ends here
