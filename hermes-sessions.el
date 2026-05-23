;;; hermes-sessions.el --- Minibuffer-driven session selectors -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Lean session-management surface for Hermes.  Two axes:
;;
;;   `hermes-current-sessions' — completing-read over live, in-memory
;;     session buffers.  Pick one to switch to it.
;;
;;   `hermes-stored-resume', `hermes-stored-branch', `hermes-stored-delete',
;;   `hermes-stored-export-as-json' — completing-read over the gateway DB
;;     (`session.list').  With a prefix arg, restrict to the current
;;     project's CWD.
;;
;; Programmatic entry points used by the stale-heading prompt and other
;; callers: `hermes-resume-from-db', `hermes-branch-from-db'.
;;
;; This file also owns the DB → Org renderer (`hermes--db-messages-to-org',
;; `hermes--db-messages-to-org-body', `hermes--render-db-messages-to-buffer')
;; and the install helper (`hermes--db-install-into-buffer'), so a single
;; module covers the DB ↔ Emacs round trip.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'hermes-rpc)
(require 'hermes-state)
(require 'hermes-project)

;; hermes--org-buffers is defined in hermes-state.el
(defvar hermes--seeded-session-id)      ; defined in hermes-input.el (buffer-local)
(declare-function hermes-org-minor-mode "hermes-mode" (&optional arg))
(declare-function hermes--ensure-container "hermes-mode" ())
(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes--register-session "hermes-org" (sid state marker))
(declare-function hermes--buffer-message-count "hermes-mode" ())
(declare-function hermes-bench-ensure "hermes-bench" (parent))
(declare-function hermes--focus-bench-input "hermes-mode" (buf))

;;;; Field accessors (hash-table / alist tolerant)

(defun hermes--sessions-field (row key)
  "Return KEY from ROW (hash-table or alist)."
  (cond
   ((hash-table-p row) (gethash key row))
   ((listp row) (or (cdr (assoc key row))
                    (cdr (assoc (intern key) row))))))

(defun hermes--sessions-short-sid (sid)
  "Return the first 8 chars of SID for display."
  (if (and (stringp sid) (> (length sid) 8))
      (substring sid 0 8)
    (or sid "?")))

(defun hermes--sessions-format-time (started)
  "Format STARTED (epoch seconds or ISO string) for display, or \"—\"."
  (cond
   ((null started) "—")
   ((numberp started) (format-time-string "%Y-%m-%d %H:%M"
                                          (seconds-to-time started)))
   ((stringp started) (if (string-empty-p started) "—" started))
   (t "—")))

;;;; Current (in-memory) sessions

(defun hermes--current-status (state)
  "Return a short status string for STATE."
  (cond
   ((and state (eq (hermes-state-connection state) 'disconnected)) "dead")
   ((and state (hermes-state-pending state)) "blocked")
   ((and state (hermes-state-stream  state)) "running")
   (state "idle")
   (t "?")))

(defun hermes--current-annot (buf)
  "Build the annotation string for live session BUF.
Shows model, status, message count, title (if set via `session.title'),
parent SID (if the session was branched), and project basename."
  (with-current-buffer buf
    (let* ((st     (hermes--current-state))
           (info   (and st (hermes-state-session-info st)))
           (model  (or (and (hash-table-p info) (gethash "model" info)) "?"))
           (title  (and (hash-table-p info) (gethash "title" info)))
           (msgs   (hermes--buffer-message-count))
           (status (hermes--current-status st))
           (parent (and st (hermes-state-parent-sid st)))
           (cwd    (and st (hermes-state-cwd st))))
      (format "  %-12s  %-8s  %5d msgs%s%s%s"
              model status msgs
              (if (and title (not (string-empty-p title)))
                  (format "  [%s]" (truncate-string-to-width title 30 nil nil "…"))
                "")
              (if parent
                  (format "  ←%s" (hermes--sessions-short-sid parent))
                "")
              (if cwd (format "  %s" (file-name-nondirectory
                                      (directory-file-name cwd)))
                "")))))

(defun hermes--current-collection ()
  "Return (CANDS . ANNOT-FN) for completing-read over live sessions.
CANDS is a list of SIDs; ANNOT-FN maps a candidate to its annotation."
  (let ((annot (make-hash-table :test 'equal))
        (sids nil))
    (when (hash-table-p hermes--org-buffers)
      (maphash
       (lambda (sid buf)
         (when (buffer-live-p buf)
           (push sid sids)
           (puthash sid (hermes--current-annot buf) annot)))
       hermes--org-buffers))
    (cons (nreverse sids)
          (lambda (s) (gethash s annot)))))

;;;###autoload
(defun hermes-current-sessions ()
  "Switch to a live Hermes session selected from the minibuffer.
Annotations show model, status, message count, title (when set),
parent SID (when branched), and project basename."
  (interactive)
  (let* ((coll (hermes--current-collection))
         (cands (car coll))
         (annot (cdr coll)))
    (unless cands
      (user-error "No live Hermes sessions"))
    (let* ((completion-extra-properties (list :annotation-function annot))
           (sid (completing-read "Hermes session: " cands nil t))
           (buf (gethash sid hermes--org-buffers)))
      (if (buffer-live-p buf)
          (pop-to-buffer-same-window buf)
        (user-error "Session buffer is gone")))))

;;;; Stored (gateway DB) sessions

(defun hermes--stored-annot (row)
  "Build the annotation string for a DB session ROW."
  (let* ((title  (or (hermes--sessions-field row "title")
                     (hermes--sessions-field row "preview") ""))
         (msgs   (or (hermes--sessions-field row "message_count") 0))
         (source (or (hermes--sessions-field row "source") "—"))
         (started (hermes--sessions-field row "started_at")))
    (format "  %-40s  %-8s  %5d msgs  %s"
            (truncate-string-to-width title 40 nil ?\s "…")
            source msgs
            (hermes--sessions-format-time started))))

(defun hermes--stored-row-background-p (row)
  "Return non-nil when ROW is a background-task session.
Background tasks use SIDs of the form `bg_<timestamp><random>'.  The
gateway's `session.list' filter only excludes `source=\"tool\"', which
does not catch these — so we filter client-side as well."
  (let ((id (hermes--sessions-field row "id")))
    (and (stringp id) (string-prefix-p "bg_" id))))

(defun hermes--stored-rows-from-result (result)
  "Coerce RESULT into a list of user-facing session row hashtables.
Filters out background-task sessions (`bg_*' SIDs) — see
`hermes--stored-row-background-p'."
  (let ((rows (cond
               ((vectorp result) (append result nil))
               ((listp result) result)
               ((hash-table-p result)
                (let ((s (gethash "sessions" result)))
                  (cond ((vectorp s) (append s nil))
                        ((listp s) s)
                        (t nil))))
               (t nil))))
    (cl-remove-if #'hermes--stored-row-background-p rows)))

(defun hermes--stored-fetch (with-cwd then)
  "Call `session.list' (optionally CWD-filtered) and invoke THEN.
THEN is called as (THEN ROWS ERROR).  When WITH-CWD is non-nil, the
current project's cwd (if any) is sent as the `:cwd' parameter."
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start))
  (let ((params (when with-cwd
                  (when-let ((cwd (ignore-errors (hermes-project-detect-cwd))))
                    (list :cwd cwd)))))
    (hermes-rpc-request
     "session.list" params
     (lambda (result error)
       (funcall then (and (not error) (hermes--stored-rows-from-result result))
                error)))))

(defun hermes--stored-pick (prompt with-cwd action)
  "Fetch the stored session list and prompt the user; call ACTION on SID.
PROMPT is the completing-read prompt.  WITH-CWD enables the CWD filter.
ACTION is a function of one argument (the selected SID)."
  (message "hermes: fetching session list…")
  (hermes--stored-fetch
   with-cwd
   (lambda (rows error)
     (cond
      (error
       (let ((msg (and (hash-table-p error) (gethash "message" error))))
         (message "hermes: session.list failed: %s"
                  (or msg (format "%S" error)))))
      ((null rows)
       (message "hermes: no stored sessions%s"
                (if with-cwd " for this project" "")))
      (t
       (let ((annot (make-hash-table :test 'equal))
             (cands nil))
         (dolist (row rows)
           (when-let ((sid (hermes--sessions-field row "id")))
             (push sid cands)
             (puthash sid (hermes--stored-annot row) annot)))
         (let* ((completion-extra-properties
                 (list :annotation-function (lambda (s) (gethash s annot))))
                (sid (completing-read prompt (nreverse cands) nil t)))
           (funcall action sid))))))))

;;;###autoload
(defun hermes-stored-resume (&optional cwd-filter)
  "Resume a stored gateway-DB session into a fresh Hermes buffer.
With a prefix arg CWD-FILTER, restrict the candidate list to the
current project's CWD."
  (interactive "P")
  (hermes--stored-pick
   "Resume session: " cwd-filter
   (lambda (sid) (hermes-resume-from-db sid))))

;;;###autoload
(defun hermes-stored-branch (&optional cwd-filter)
  "Branch a stored gateway-DB session into a new session and open it.
With a prefix arg CWD-FILTER, restrict the candidate list to the
current project's CWD."
  (interactive "P")
  (hermes--stored-pick
   "Branch session: " cwd-filter
   (lambda (sid) (hermes-branch-from-db sid))))

;;;###autoload
(defun hermes-stored-delete (&optional cwd-filter)
  "Delete a stored gateway-DB session.  Confirms first.
With a prefix arg CWD-FILTER, restrict the candidate list to the
current project's CWD."
  (interactive "P")
  (hermes--stored-pick
   "Delete session: " cwd-filter
   (lambda (sid)
     (let ((short (hermes--sessions-short-sid sid)))
       (unless (yes-or-no-p (format "Delete session %s from gateway DB? " sid))
         (user-error "Cancelled"))
       (hermes-rpc-request
        "session.delete" (list :session_id sid)
        (lambda (_result error)
          (cond
           (error (message "hermes: session.delete error: %S" error))
           (t (message "hermes: deleted %s" short)))))))))

;;;###autoload
(defun hermes-stored-export-as-json (&optional cwd-filter)
  "Export a stored gateway-DB session to a JSON file via `session.save'.
With a prefix arg CWD-FILTER, restrict the candidate list to the
current project's CWD."
  (interactive "P")
  (hermes--stored-pick
   "Save session: " cwd-filter
   (lambda (sid)
     (let ((short (hermes--sessions-short-sid sid)))
       (hermes-rpc-request
        "session.save" (list :session_id sid)
        (lambda (result error)
          (cond
           (error (message "hermes: session.save error: %S" error))
           (t (let ((file (and (hash-table-p result) (gethash "file" result))))
                (message "hermes: saved %s → %s" short (or file "?")))))))))))

;;;; DB → Org rendering (used by resume/branch)
;;
;; The gateway returns messages already flattened by `_history_to_messages':
;;   {role: "user",      text|content: "..."}
;;   {role: "assistant", text|content: "..."}
;;   {role: "tool",      name: "...", context: "..."}
;;
;; `tool_call_id`, full tool arguments, reasoning, subagents, images, usage,
;; and timestamps are NOT surfaced.  The render is intentionally lossy.

(defun hermes--db-msg-field (msg key)
  "Return KEY from MSG (hash-table or alist), or nil."
  (hermes--sessions-field msg key))

(defun hermes--db-msg-text (msg)
  "Return the display text of MSG, preferring `text', then `content'."
  (or (hermes--db-msg-field msg "text")
      (hermes--db-msg-field msg "content")
      ""))

(defun hermes--db-msg-role (msg)
  "Return MSG's role as a string, or empty."
  (or (hermes--db-msg-field msg "role") ""))

(defun hermes--db-messages-to-org-body (messages)
  "Render MESSAGES (list/vector of hashtables) as the body org string.
Emits only the per-turn headings (no `* Hermes session' container).
Used when inserting into a buffer where the container has already
been created."
  (let ((msgs (cond
               ((vectorp messages) (append messages nil))
               ((listp messages) messages)
               (t nil)))
        (parts nil)
        (last-assistant-depth 2))
    (dolist (msg msgs)
      (let ((role (hermes--db-msg-role msg)))
        (pcase role
          ("user"
           (setq last-assistant-depth 2)
           (push (format "\n** User\n:PROPERTIES:\n:HERMES_KIND: USER\n:END:\n%s\n"
                         (hermes--db-msg-text msg))
                 parts))
          ("assistant"
           (setq last-assistant-depth 2)
           (push (format "\n** Assistant\n:PROPERTIES:\n:HERMES_KIND: ASSISTANT\n:END:\n%s\n"
                         (hermes--db-msg-text msg))
                 parts))
          ("tool"
           (let* ((name (or (hermes--db-msg-field msg "name") "tool"))
                  (ctx  (or (hermes--db-msg-field msg "context")
                            (hermes--db-msg-text msg)))
                  (stars (make-string (1+ last-assistant-depth) ?*)))
             (push (format "\n%s Tool (%s)\n:PROPERTIES:\n:HERMES_KIND: TOOL\n:TOOL_NAME: %s\n:END:\n%s\n"
                           stars name name ctx)
                   parts)))
          (_
           (push (format "\n# skipped role: %s\n" role) parts)))))
    (mapconcat #'identity (nreverse parts) "")))

(defun hermes--db-messages-to-org (messages sid)
  "Render MESSAGES for SID as a self-contained org string.
Includes the `* Hermes session :hermes:' container heading."
  (concat (format "* Hermes session :hermes:\n:PROPERTIES:\n:HERMES_SESSION: %s\n:END:\n"
                  (or sid ""))
          (hermes--db-messages-to-org-body messages)))

(defun hermes--render-db-messages-to-buffer (messages sid)
  "Insert the org rendering of MESSAGES (for SID) into the current buffer.
Erases the buffer first."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (hermes--db-messages-to-org messages sid))
    (goto-char (point-min))))

;;;; Resume / branch install path

(defun hermes--db-install-into-buffer (buf new-sid messages info &optional parent-sid)
  "Activate `hermes-org-minor-mode' in BUF, render MESSAGES, register NEW-SID.
INFO is the `info' hash-table from the server response (may be nil).
PARENT-SID, when non-nil, is recorded on the state's `parent-sid' slot
— set this for branch installs, leave nil for plain resume.
On return, BUF is a fully-armed Hermes session buffer with the history
seed already stamped (no re-seeding on next prompt)."
  (with-current-buffer buf
    (org-mode)
    (hermes--ensure-container)
    (hermes-org-minor-mode 1)
    (let* ((cwd (and (hash-table-p info) (gethash "cwd" info)))
           (state (make-hermes-state
                   :connection 'connected
                   :session-id new-sid
                   :cwd cwd
                   :parent-sid parent-sid
                   :session-info (and (hash-table-p info) info))))
      (when cwd
        (setq-local default-directory (file-name-as-directory cwd)))
      (save-excursion
        (goto-char (point-min))
        (when (org-at-heading-p)
          (org-set-property "HERMES_SESSION" new-sid)
          (when cwd
            (org-set-property "HERMES_CWD" (abbreviate-file-name cwd))))
        (goto-char (point-max))
        (let ((body (hermes--db-messages-to-org-body messages)))
          (unless (string-empty-p body)
            (unless (bolp) (insert "\n"))
            (insert body))))
      (hermes--register-session
       new-sid state
       (save-excursion (goto-char (point-min)) (copy-marker (point) nil))))
    (setq hermes--seeded-session-id new-sid)
    (goto-char (point-min))))

(defun hermes--db-handle-resume-response (result error orig-sid then &optional parent-sid)
  "Common handler for `session.resume' responses.
ORIG-SID is the SID the user asked to resume; the response carries a
NEW SID under `session_id'.  THEN, if non-nil, is called with BUF after
install.  PARENT-SID, when non-nil, is threaded into the install step
(branch installs only — plain resume passes nil)."
  (cond
   (error
    (let* ((code (and (hash-table-p error) (gethash "code" error)))
           (msg  (and (hash-table-p error) (gethash "message" error)))
           (not-found (eql code 4007)))
      (message "hermes: resume %s failed: %s%s"
               orig-sid
               (or msg (format "%S" error))
               (if not-found
                   " — session not in gateway DB; pick `Load from org' instead"
                 ""))))
   ((not (hash-table-p result))
    (message "hermes: resume %s: unexpected response shape" orig-sid))
   (t
    (let* ((new-sid  (gethash "session_id" result))
           (messages (gethash "messages" result))
           (info     (gethash "info" result))
           (buf      (and new-sid
                          (generate-new-buffer
                           (format "*hermes:%s*" new-sid)))))
      (cond
       ((not new-sid)
        (message "hermes: resume %s: no session_id in response" orig-sid))
       (t
        (hermes--db-install-into-buffer buf new-sid messages info parent-sid)
        (pop-to-buffer buf)
        ;; Mirror the normal `M-x hermes' entry path: ensure the bench is
        ;; visible and cursor lands in the input zone.
        (when (fboundp 'hermes-bench-ensure)
          (hermes-bench-ensure buf))
        (when (fboundp 'hermes--focus-bench-input)
          (hermes--focus-bench-input buf))
        (message "hermes: resumed %s as %s (%d msgs)"
                 (hermes--sessions-short-sid orig-sid)
                 (hermes--sessions-short-sid new-sid)
                 (length (cond ((vectorp messages) (append messages nil))
                               ((listp messages) messages)
                               (t nil))))
        (when then (funcall then buf))))))))

(defun hermes-resume-from-db (sid)
  "Resume the gateway-DB session SID into a fresh Hermes buffer.
Internal helper.  User-facing entry points are `hermes-stored-resume'
and the stale-heading prompt (`hermes--handle-stale-heading') — both
pick a SID from a list, so there is no interactive form here.

The gateway returns a NEW session id (distinct from SID); the new buffer
is named `*hermes:<new-sid>*' and its history seed is suppressed since
the gateway already has full context."
  (unless (and sid (not (string-empty-p sid)))
    (user-error "No session id given"))
  (when (string-prefix-p "bg_" sid)
    (user-error "Refusing to resume a background-task session: %s" sid))
  (unless (hermes-rpc-live-p)
    (hermes--install-hooks)
    (hermes-rpc-start))
  (hermes-rpc-request
   "session.resume" (list :session_id sid)
   (lambda (result error)
     (hermes--db-handle-resume-response result error sid nil))))

(defun hermes-branch-from-db (sid)
  "Branch the gateway-DB session SID into a new session and open it.
Internal helper.  User-facing entry points are `hermes-stored-branch'
and the stale-heading prompt — both pick a SID from a list.

Chains `session.branch' → `session.resume' so the new buffer is ready
to receive prompts."
  (unless (and sid (not (string-empty-p sid)))
    (user-error "No session id given"))
  (when (string-prefix-p "bg_" sid)
    (user-error "Refusing to branch a background-task session: %s" sid))
  (unless (hermes-rpc-live-p)
    (hermes--install-hooks)
    (hermes-rpc-start))
  (hermes-rpc-request
   "session.branch" (list :session_id sid)
   (lambda (result error)
     (cond
      (error
       (let ((msg (and (hash-table-p error) (gethash "message" error))))
         (message "hermes: branch %s failed: %s"
                  sid (or msg (format "%S" error)))))
      ((not (hash-table-p result))
       (message "hermes: branch %s: unexpected response shape" sid))
      (t
       (let ((new-sid (gethash "session_id" result))
             (parent  (or (gethash "parent" result) sid)))
         (cond
          ((not new-sid)
           (message "hermes: branch %s: no session_id in response" sid))
          (t
           (hermes-rpc-request
            "session.resume" (list :session_id new-sid)
            (lambda (r2 e2)
              (hermes--db-handle-resume-response r2 e2 new-sid nil parent)))))))))))

(provide 'hermes-sessions)
;;; hermes-sessions.el ends here
