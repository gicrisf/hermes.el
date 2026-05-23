;;; hermes-mode.el --- Hermes minor mode and session entry point -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;;; Commentary:

;; `hermes-org-minor-mode' is the minor mode that turns an `org-mode'
;; buffer into a Hermes conversation surface.  It owns the streaming
;; renderer, keybindings, mode-line, and hook wiring.  Activation
;; requires a `:hermes:' container heading at point-min; the entry
;; point and DB-resume path create it.
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

(defvar hermes--last-gateway-ready nil
  "Most recent `gateway.ready' payload, cached for replay into new buffers.
The event broadcasts to every existing session when it arrives, but the
first session is typically created AFTER `gateway.ready' lands — so
without this cache, the very first session would never see the skin.")

(defun hermes--lookup-buffer (session-id)
  "Return the org buffer registered for SESSION-ID, or nil."
  (let ((buf (gethash session-id hermes--org-buffers)))
    (and (buffer-live-p buf) buf)))

(defun hermes--org-detach ()
  "Remove the current buffer from `hermes--org-buffers'.
Run on `kill-buffer-hook' for Hermes-aware buffers.  Leaves the
session state in `hermes--sessions' untouched so it survives until
explicit close.  Kills the paired bench when the last viewer goes."
  (let ((buf (current-buffer))
        (drops nil))
    (maphash (lambda (sid b) (when (eq b buf) (push sid drops)))
             hermes--org-buffers)
    (dolist (sid drops)
      (remhash sid hermes--org-buffers)
      (hermes--maybe-kill-bench sid))))

;;;; Event routing — installed once on the RPC layer

(defun hermes--route-event (type session-id payload)
  "Dispatch event TYPE/PAYLOAD into the session's state slot."
  (when (or (equal type "gateway.ready") (equal type "skin.changed"))
    (setq hermes--last-gateway-ready payload))
  (cond
   ((and session-id (not (string-empty-p session-id)))
    ;; Per-session dispatch — writes to the global slot keyed by sid.
    ;; `with-current-buffer' is still required for the buffer-local
    ;; UI state.
    (let ((buf (hermes--lookup-buffer session-id)))
      (if (buffer-live-p buf)
          (with-current-buffer buf
            (hermes-dispatch (cons type payload) session-id)
            (hermes-ui-dispatch (cons type payload) session-id))
        (hermes-dispatch (cons type payload) session-id))))
   (t
    ;; Pre-session events (gateway.ready, skin.changed, etc.) update the
    ;; process-wide state slot and broadcast UI to every live buffer.
    (hermes--broadcast-dispatch type payload))))

(defun hermes--route-connection (state)
  "Broadcast a connection state change to every known session."
  ;; Clear the cached `gateway.ready' payload so that the *next* time we
  ;; reconnect we wait for a fresh one before firing `session.create'.
  (when (eq state 'disconnected)
    (setq hermes--last-gateway-ready nil))
  (let ((msg (list (pcase state
                     ('connecting   :connecting)
                     ('connected    :connected)
                     ('disconnected :disconnected)
                     (_             :disconnected)))))
    ;; Update process-wide state for sessionless observers.
    (hermes-dispatch msg)
    ;; And every per-session slot, so each viewer's mode-line updates.
    (maphash (lambda (sid _state)
               (hermes-dispatch msg sid))
             hermes--sessions)))

(defun hermes--broadcast-dispatch (type payload)
  "Dispatch TYPE + PAYLOAD to the global slot and every active session."
  ;; Global slot first — sessionless observers (e.g. nascent buffers).
  (hermes-dispatch (cons type payload))
  ;; Per-session: write into each session's slot and update its UI.
  (maphash (lambda (sid _state)
             (hermes-dispatch (cons type payload) sid)
             (let ((buf (hermes--lookup-buffer sid)))
               (when (buffer-live-p buf)
                 (with-current-buffer buf
                   (hermes-ui-dispatch (cons type payload) sid)))))
           hermes--sessions))

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
  (remove-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (remove-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (remove-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (remove-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout)
  (add-hook 'hermes-rpc-event-functions #'hermes--route-event)
  (add-hook 'hermes-rpc-connection-functions #'hermes--route-connection)
  (add-hook 'hermes-rpc-stderr-functions #'hermes--route-stderr)
  (add-hook 'hermes-rpc-protocol-error-functions #'hermes--route-protocol-error)
  (add-hook 'hermes-rpc-start-timeout-functions #'hermes--route-start-timeout))

;;;; Container heading helpers

(defun hermes--container-heading-in-buffer-p ()
  "Return non-nil when the buffer holds at least one `:hermes:'-tagged heading."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\\*+ .*:hermes:" nil t)))

(defun hermes--ensure-container ()
  "Insert a Hermes session container heading at point-min if absent.
Called by the `hermes' entry point and the DB-resume installer before
activating `hermes-org-minor-mode', which requires a container to
exist somewhere in the buffer."
  (save-excursion
    (goto-char (point-min))
    (unless (hermes--container-heading-in-buffer-p)
      (insert (concat (make-string (or (bound-and-true-p hermes--container-level) 1)
                                   ?*)
                      " Hermes session :hermes:\n")))))

;;;; Minor mode

(defvar hermes-org-minor-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-i") #'hermes-bench-focus)
    (define-key m (kbd "C-c C-l") #'hermes-compose)
    (define-key m (kbd "C-c C-k") #'hermes-interrupt-current-session)
    (define-key m (kbd "C-c C-v") #'hermes-view-log)
    (define-key m (kbd "C-c C-m") #'hermes-set-model)
    (define-key m (kbd "C-c C-f") #'hermes-toggle-fast)
    (define-key m (kbd "C-c C-a") #'hermes-image-attach-file)
    m)
  "Keymap for `hermes-org-minor-mode'.")

(with-eval-after-load 'which-key
  (when (fboundp 'which-key-add-keymap-based-replacements)
    (which-key-add-keymap-based-replacements hermes-org-minor-mode-map
      "C-c C-i" "Focus bench"
      "C-c C-l" "Compose multi-line"
      "C-c C-k" "Interrupt session"
      "C-c C-v" "View log"
      "C-c C-m" "Set model"
      "C-c C-f" "Toggle fast mode"
      "C-c C-a" "Attach image file")))

(defun hermes-org-minor-mode--on ()
  "Setup for `hermes-org-minor-mode': org-local config, hooks, mode-line.
Requires a `:hermes:' container heading at point-min — the entry point
and DB-resume installer create it before activation.  Idempotent: safe
to run when already armed."
  (unless (derived-mode-p 'org-mode)
    (error "hermes-org-minor-mode requires org-mode"))
  (unless (hermes--container-heading-in-buffer-p)
    (error "No Hermes session heading found — use M-x hermes to create one"))
  (setq-local hermes--container-level 1)
  (setq-local org-startup-folded nil)
  (setq-local org-hide-leading-stars t)
  (setq-local org-todo-keywords
              '((sequence "RUNNING(r)" "|" "DONE(d)" "ERROR(e)")))
  (setq-local org-todo-keyword-faces
              '(("RUNNING" . hermes-tool-running-face)
                ("DONE"    . hermes-tool-done-face)
                ("ERROR"   . hermes-tool-error-face)))
  (hermes-state-init)
  ;; Ensure RPC event hooks are wired so events for sessions hosted in
  ;; this buffer route through `hermes--route-event'.  Idempotent.
  (hermes--install-hooks)
  (add-hook 'org-cycle-hook #'hermes--remember-cycle nil t)
  ;; Order matters: `hermes--render' MUST run before `hermes-input--drain'.
  ;; If drain runs first, it dispatches `:user-submit' for the queued
  ;; head; the recursive render inserts that user heading at point-max
  ;; with stream already nil → `stream-commit' won't have fired yet, so
  ;; when the outer render finally runs, `bench-end' has been rear-
  ;; advanced past the user content and the assistant turn lands at the
  ;; end of the buffer.  These hooks are GLOBAL (no LOCAL flag) — each
  ;; subscriber discovers its target buffer via `hermes--org-buffers'.
  (add-hook 'hermes-state-change-hook    #'hermes--render        t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     t)
  (add-hook 'hermes-state-change-hook    #'hermes--mode-line-update t)
  ;; UI state remains buffer-local, so its hook stays LOCAL.
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     t t)
  ;; Drop pending throttle timer on buffer kill so it can't fire into a
  ;; dead buffer.
  (add-hook 'kill-buffer-hook            #'hermes--stream-flush-cancel nil t)
  ;; Detach this buffer from the global viewer registry when killed.  The
  ;; session state itself stays in `hermes--sessions' — it carries data
  ;; (reasoning, tool args, subagents) the gateway DB doesn't preserve,
  ;; so explicit close is required to discard it.
  (add-hook 'kill-buffer-hook            #'hermes--org-detach nil t)
  ;; Move Hermes status from the top header-line to the bottom mode-line.
  ;; The `:lighter " Hermes"' handles the right-side indicator.
  (setq-local mode-line-format
              '("%e"
                mode-line-modified
                " "
                mode-line-buffer-identification
                "  "
                (:eval hermes--mode-line-status)))
  (setq header-line-format nil)
  ;; Initial paint of the mode-line for this buffer.
  (let* ((sid (catch 'found
                (maphash (lambda (k b)
                           (when (eq b (current-buffer))
                             (throw 'found k)))
                         hermes--org-buffers)
                nil))
         (state (hermes--state-slot-read sid)))
    (hermes--mode-line-update nil state)))

(defun hermes-org-minor-mode--off ()
  "Teardown for `hermes-org-minor-mode': remove buffer-local hooks, clear header.
The global state-change-hook subscribers are intentionally left in
place — they are global and shared by every Hermes buffer; removing
them here would tear down other live viewers."
  (remove-hook 'org-cycle-hook #'hermes--remember-cycle t)
  (remove-hook 'hermes-ui-state-change-hook #'hermes--render-ui t)
  (remove-hook 'kill-buffer-hook #'hermes--stream-flush-cancel t)
  (hermes--stream-flush-cancel)
  (kill-local-variable 'mode-line-format)
  (setq header-line-format nil))

;;;###autoload
(define-minor-mode hermes-org-minor-mode
  "Minor mode for Hermes presentation in Org buffers.
Provides streaming render, auto-fold, mode-line, and key bindings.
Works in any `org-mode' buffer with a `:hermes:' container heading at
point-min."
  :init-value nil
  :lighter " Hermes"
  :keymap hermes-org-minor-mode-map
  (if hermes-org-minor-mode
      (hermes-org-minor-mode--on)
    (hermes-org-minor-mode--off)))

(defun hermes-bench-focus ()
  "Move cursor to the bench input zone for the current Hermes buffer.
If the bench window is hidden, redisplay it first.  When no bench is
attached to the buffer, fall back to `hermes-send' for a minibuffer
prompt."
  (interactive)
  (let ((bench (and hermes-org-minor-mode
                    (hermes-bench-active-p))))
    (cond
     ((and bench (get-buffer-window bench))
      (select-window (get-buffer-window bench))
      (goto-char (point-max)))
     (bench
      (when-let ((sid (hermes--buffer-sid (current-buffer))))
        (hermes-bench-ensure sid))
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
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error
         (message "hermes: session.create failed: %S" error)
         (when callback (funcall callback nil)))
        (result
         (let* ((sid (gethash "session_id" result))
                (buf (generate-new-buffer (format "*hermes:%s*" sid))))
           (with-current-buffer buf
             (org-mode)
             (hermes--ensure-container)
             (hermes-org-minor-mode 1)
             (let ((state (make-hermes-state :connection 'connected
                                             :session-id sid
                                             :cwd detected-cwd)))
               (hermes--register-session
                sid state
                (save-excursion (goto-char (point-min))
                                (copy-marker (point) nil))))
             (save-excursion
               (goto-char (point-min))
               (when (org-at-heading-p)
                 (org-set-property "HERMES_SESSION" sid)
                 (when detected-cwd
                   (org-set-property "HERMES_CWD"
                                     (abbreviate-file-name detected-cwd)))))
             (when hermes--last-gateway-ready
               (hermes-dispatch
                (cons "gateway.ready" hermes--last-gateway-ready)
                sid))
             (hermes-input-fetch-catalog))
           (when callback (funcall callback buf)))))))))

(defun hermes-new-session (&optional callback)
  "Start the gateway (if needed), create a session, and prepare its buffer.
The buffer is registered in `hermes--org-buffers' but NOT popped to the
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
             hermes--org-buffers)
    (sort acc (lambda (a b) (> (buffer-modified-tick a)
                               (buffer-modified-tick b))))))

(defun hermes--primary-session-buffer ()
  "Return the most-recently-active live session buffer, or nil."
  (car (hermes--live-session-buffers)))

;;;###autoload
(defun hermes ()
  "Context-aware entry point — never sends a prompt.
- In an org-mode buffer with `hermes-org-minor-mode' active: ensure the
  bench is visible and focus its input area.
- In a generic `org-mode' buffer: create a Hermes session heading as a
  direct child of the heading at/above point.
- Everywhere else: pop the most-recently-touched live session, or
  create a fresh one if none exists."
  (interactive)
  (cond
   (hermes-org-minor-mode
    (when-let ((sid (hermes--buffer-sid (current-buffer))))
      (hermes-bench-ensure sid))
    (let* ((bench (hermes-bench-active-p))
           (win   (and bench (get-buffer-window bench))))
      (when (window-live-p win)
        (select-window win)
        (goto-char (point-max)))))
   ((derived-mode-p 'org-mode)
    ;; Ancestor walk wins when point is inside a `:hermes:' subtree so
    ;; that multi-session buffers route deterministically.  When the
    ;; walk fails (point above all containers, or in a sibling subtree),
    ;; fall back to a buffer-wide scan — picks the unique container or
    ;; prompts when several exist.  See `hermes--any-container-in-buffer'.
    (let* ((marker (or (hermes--container-marker-at-point)
                       (hermes--any-container-in-buffer)))
           (sid    (and marker
                        (save-excursion
                          (goto-char marker)
                          (or (hermes--session-at-point)
                              (hermes--session-id-at-heading)))))
           (state  (and sid (hermes--lookup-session-state sid))))
      (cond
       (state
        (when (marker-position marker) (goto-char marker))
        (when-let ((s (hermes--buffer-sid (current-buffer))))
          (hermes-bench-ensure s))
        (let* ((bench (hermes-bench-active-p))
               (win   (and bench (get-buffer-window bench))))
          (when (window-live-p win)
            (select-window win)
            (goto-char (point-max)))))
       (sid
        (when (marker-position marker) (goto-char marker))
        (hermes--handle-stale-heading sid marker))
       (t
        (hermes--create-session-under-heading)))))
   (t
    ;; No auto-resume from gateway DB here by design: the org buffer is the
    ;; canonical history.  To resume a DB session, open its `.org' file and
    ;; run `M-x hermes' inside the `:hermes:' subtree — the stale-heading
    ;; prompt (`hermes--handle-stale-heading') offers load-from-org,
    ;; resume-from-DB, and branch-from-DB.  To browse DB sessions
    ;; directly, use `M-x hermes-stored-resume' (and friends), or
    ;; `M-x hermes-current-sessions' to switch among live sessions.
    (let ((buf (hermes--primary-session-buffer)))
      (if buf
          (progn
            (pop-to-buffer-same-window buf)
            (when-let ((sid (hermes--buffer-sid buf)))
              (hermes-bench-ensure sid))
            (hermes--focus-bench-input buf))
        (hermes-new-session
         (lambda (b)
           (when (buffer-live-p b)
             (pop-to-buffer-same-window b)
             (when-let ((sid (hermes--buffer-sid b)))
               (hermes-bench-ensure sid))
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

(defun hermes-reconnect ()
  "Restart the gateway (if needed) and bind the current buffer to a fresh session.
Used after the gateway subprocess has died.  The old session id is removed
from `hermes--org-buffers' once the new one is bound; the buffer is
renamed accordingly; the slash-command catalog is re-fetched; and any
queued input is drained."
  (interactive)
  (unless hermes-org-minor-mode
    (user-error "Not in a Hermes buffer"))
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let ((buf (current-buffer)))
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: reconnect session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (let* ((old-sid (catch 'found
                                 (maphash (lambda (k b)
                                            (when (eq b buf)
                                              (throw 'found k)))
                                          hermes--org-buffers)
                                 nil))
                      (old-state (and old-sid (hermes--state-slot-read old-sid))))
                 (when (and old-sid (not (equal old-sid sid)))
                   (remhash old-sid hermes--org-buffers)
                   (remhash old-sid hermes--sessions)
                   (remhash old-sid hermes--session-markers))
                 (let ((state (or (and old-state
                                       (let ((s (hermes-state-copy old-state)))
                                         (setf (hermes-state-session-id s) sid)
                                         s))
                                  (make-hermes-state :connection 'connected
                                                     :session-id sid))))
                   (hermes--register-session
                    sid state
                    (save-excursion (goto-char (point-min))
                                    (copy-marker (point) nil)))))
               (rename-buffer (generate-new-buffer-name
                               (format "*hermes:%s*" sid)))
               (when hermes--last-gateway-ready
                 (hermes-dispatch
                  (cons "gateway.ready" hermes--last-gateway-ready)
                  sid))
               (hermes-input-fetch-catalog)
               (hermes-input--drain-after-reconnect)
               (message "hermes: reconnected as %s" sid))))))))))

(defun hermes-interrupt-current-session ()
  "Send `session.interrupt' for the Hermes session at point.
In an Org buffer with `hermes-org-minor-mode' enabled, it resolves to
the `:hermes:' container containing point."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (sid (car target)))
    (unless target
      (user-error "No Hermes session at point"))
    (unless sid (user-error "No session id assigned yet"))
    (hermes--request "session.interrupt"
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
      (unless hermes-org-minor-mode
        (hermes-org-minor-mode 1)
        (setq-local hermes--container-level container-level))
      (hermes--request
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
                   (hermes--register-session sid state marker))
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

(defun hermes-reload-from-org ()
  "Reload the current Org buffer into a fresh gateway session.
A new `session.create' is issued; the buffer's existing visible
conversation is replayed to the new session via the history seed on
the first outgoing prompt (see `hermes--build-history-text').  The
gateway does not accept a history parameter on session creation, so
this is the only way to re-attach an Org snapshot to a live session."
  (interactive)
  (unless hermes-org-minor-mode
    (user-error "Not in a Hermes buffer"))
  (let* ((history (hermes--parse-buffer-messages)))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes--request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error (message "hermes: load-org session.create failed: %S" error))
        (result
         (let ((sid (gethash "session_id" result)))
           (when sid
             (let ((state (make-hermes-state :session-id sid
                                             :connection 'connected)))
               (hermes--register-session
                sid state
                (save-excursion
                  (goto-char (point-min)) (copy-marker (point) nil))))
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
  "Pop a buffer inspecting the active session's state struct."
  (interactive)
  (let* ((target (hermes--resolve-session-target))
         (st (and target (cdr target))))
    (unless st (user-error "No Hermes state for this buffer"))
    (hermes--debug-state-pop st)))

(defun hermes--debug-state-pop (st)
  "Render ST in a popup buffer."
  (let* ((_ st)
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
  (let* ((target (hermes--resolve-session-target))
         (sid (car target)))
    (if sid
        (progn (require 'hermes-bg)
               (hermes-bg--list-for-sid sid))
      (user-error "No active Hermes session in this buffer"))))

(provide 'hermes-mode)
;;; hermes-mode.el ends here
