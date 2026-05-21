;;; hermes-sessions-db.el --- Tabulated browser for DB-persisted Hermes sessions -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A `tabulated-list-mode' buffer (`*Hermes DB Sessions*') listing every
;; session persisted in the gateway's SQLite database (`~/.hermes/state.db').
;;
;; The live sidebar (`hermes-sessions') shows sessions currently loaded into
;; Emacs.  This buffer shows the broader set of sessions known to the gateway
;; — including ones created by the TUI, CLI, or other clients.
;;
;; Keys:
;;   g  refresh (calls `session.list')
;;   c  toggle CWD filter (only sessions whose cwd matches current project)
;;   l  jump to the live sessions sidebar
;;   d  delete the session at point (with confirmation)
;;   s  save the session at point to a JSON file
;;   RET, r, b are stubbed pending Phase 4 (resume / branch renderer).

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)
(require 'hermes-rpc)
(require 'hermes-project)

(defconst hermes-sessions-db-buffer-name "*Hermes DB Sessions*")

(defvar-local hermes-sessions-db--cwd-filter nil
  "When non-nil, filter listing to sessions matching the current project cwd.")

(defvar-local hermes-sessions-db--entries nil
  "Last fetched entries, cached so `tabulated-list-entries' is sync.")

;;;; Helpers

(defun hermes-sessions-db--short-sid (sid)
  "Return the first 8 chars of SID for display."
  (if (and (stringp sid) (> (length sid) 8))
      (substring sid 0 8)
    (or sid "?")))

(defun hermes-sessions-db--format-started (started)
  "Format STARTED (epoch seconds or ISO string) for display, or \"—\"."
  (cond
   ((null started) "—")
   ((numberp started)
    (format-time-string "%Y-%m-%d %H:%M" (seconds-to-time started)))
   ((stringp started)
    (if (string-empty-p started) "—" started))
   (t "—")))

(defun hermes-sessions-db--field (row key)
  "Return KEY from ROW (a hash-table or alist)."
  (cond
   ((hash-table-p row) (gethash key row))
   ((listp row) (or (cdr (assoc key row))
                    (cdr (assoc (intern key) row))))))

(defun hermes-sessions-db--row->entry (row)
  "Convert a server row hashtable ROW into a tabulated-list entry."
  (let* ((id     (hermes-sessions-db--field row "id"))
         (title  (or (hermes-sessions-db--field row "title")
                     (hermes-sessions-db--field row "preview")
                     ""))
         (msgs   (or (hermes-sessions-db--field row "message_count") 0))
         (source (or (hermes-sessions-db--field row "source") "—"))
         (started (hermes-sessions-db--field row "started_at")))
    (list id
          (vector (hermes-sessions-db--short-sid id)
                  (truncate-string-to-width (format "%s" title) 40 nil nil "…")
                  (number-to-string msgs)
                  (format "%s" source)
                  (hermes-sessions-db--format-started started)))))

(defun hermes-sessions-db--entries-fn ()
  "Return the cached entries for `tabulated-list-entries'."
  hermes-sessions-db--entries)

;;;; Fetch

(defun hermes-sessions-db--fetch (&optional then)
  "Call `session.list' and refresh the buffer.
THEN, if non-nil, is invoked with no args after the print completes."
  (let ((buf (current-buffer))
        (params (let ((p '()))
                  (when hermes-sessions-db--cwd-filter
                    (when-let ((cwd (ignore-errors (hermes-project-detect-cwd))))
                      (setq p (plist-put p :cwd cwd))))
                  p)))
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes-rpc-request
     "session.list" params
     (lambda (result error)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (cond
            (error
             (message "hermes: session.list error: %S" error))
            (t
             (let* ((rows (cond
                           ((vectorp result) (append result nil))
                           ((listp result) result)
                           ((hash-table-p result)
                            (let ((sessions (gethash "sessions" result)))
                              (cond ((vectorp sessions) (append sessions nil))
                                    ((listp sessions) sessions)
                                    (t nil))))
                           (t nil)))
                    (entries (mapcar #'hermes-sessions-db--row->entry rows)))
               (setq hermes-sessions-db--entries entries)
               (let ((pt (point)))
                 (tabulated-list-print t)
                 (goto-char (min pt (point-max))))
               (when then (funcall then))))))))))
  nil)

(defun hermes-sessions-db--refresh-if-open (&rest _ignore)
  "Refresh the DB browser if it is visible.  Cheap no-op otherwise."
  (let ((buf (get-buffer hermes-sessions-db-buffer-name)))
    (when (and (buffer-live-p buf) (get-buffer-window buf t))
      (with-current-buffer buf
        (hermes-sessions-db--fetch)))))

;;;; DB → Org rendering (Phase 3)
;;
;; The gateway returns messages already flattened by `_history_to_messages':
;;   {role: "user",      text|content: "..."}
;;   {role: "assistant", text|content: "..."}
;;   {role: "tool",      name: "...", context: "..."}
;;
;; `tool_call_id`, full tool arguments, reasoning, subagents, images, usage,
;; and timestamps are NOT surfaced by the gateway in this method.  The render
;; is intentionally lossy — see PLAN_SUPPORT_GATEWAY_DB_SESSIONS.md Decision 3.

(defun hermes--db-msg-field (msg key)
  "Return KEY from MSG (hash-table or alist), or nil."
  (cond
   ((hash-table-p msg) (gethash key msg))
   ((listp msg) (or (cdr (assoc key msg))
                    (cdr (assoc (intern key) msg))))))

(defun hermes--db-msg-text (msg)
  "Return the display text of MSG, preferring `text', then `content'."
  (or (hermes--db-msg-field msg "text")
      (hermes--db-msg-field msg "content")
      ""))

(defun hermes--db-msg-role (msg)
  "Return MSG's role as a string, or empty."
  (or (hermes--db-msg-field msg "role") ""))

(defun hermes--db-messages-to-org (messages sid)
  "Render MESSAGES (list/vector of hashtables) for SID as an org string.

Format:

  * Hermes session :hermes:
  :PROPERTIES:
  :HERMES_SESSION: <sid>
  :END:

  ** User
  :PROPERTIES:
  :HERMES_KIND: USER
  :END:
  <body>

  ** Assistant
  :PROPERTIES:
  :HERMES_KIND: ASSISTANT
  :END:
  <body>

  *** Tool (<name>)
  :PROPERTIES:
  :HERMES_KIND: TOOL
  :TOOL_NAME: <name>
  :END:
  <context>"
  (let ((msgs (cond
               ((vectorp messages) (append messages nil))
               ((listp messages) messages)
               (t nil)))
        (parts (list (format "* Hermes session :hermes:\n:PROPERTIES:\n:HERMES_SESSION: %s\n:END:\n"
                             (or sid ""))))
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
           ;; Unknown role: skip with a comment so the user knows something
           ;; was filtered.  Defensive — gateway shouldn't emit other roles.
           (push (format "\n# skipped role: %s\n" role) parts)))))
    (mapconcat #'identity (nreverse parts) "")))

(defun hermes--render-db-messages-to-buffer (messages sid)
  "Insert the org rendering of MESSAGES (for SID) into the current buffer.
Erases the buffer first.  Returns no useful value."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (hermes--db-messages-to-org messages sid))
    (goto-char (point-min))))

;;;; Mode

(defvar hermes-sessions-db-mode-map
  (let ((m (make-sparse-keymap)))
    (set-keymap-parent m tabulated-list-mode-map)
    (define-key m (kbd "RET") #'hermes-sessions-db-pick)
    (define-key m (kbd "r")   #'hermes-sessions-db-resume)
    (define-key m (kbd "b")   #'hermes-sessions-db-branch)
    (define-key m (kbd "d")   #'hermes-sessions-db-delete)
    (define-key m (kbd "s")   #'hermes-sessions-db-save)
    (define-key m (kbd "g")   #'hermes-sessions-db-refresh)
    (define-key m (kbd "c")   #'hermes-sessions-db-toggle-cwd-filter)
    (define-key m (kbd "l")   #'hermes-sessions-db-jump-to-live)
    m)
  "Keymap for `hermes-sessions-db-mode'.")

(define-derived-mode hermes-sessions-db-mode tabulated-list-mode "HermesDB"
  "Major mode for browsing gateway-DB-persisted Hermes sessions."
  (setq tabulated-list-format
        [("SID"     10 t)
         ("Title"   42 t)
         ("Msgs"     5 (lambda (a b)
                         (< (string-to-number (aref (cadr a) 2))
                            (string-to-number (aref (cadr b) 2)))))
         ("Source"   8 t)
         ("Started"  0 t)])
  (setq tabulated-list-padding 1)
  (setq tabulated-list-entries #'hermes-sessions-db--entries-fn)
  (tabulated-list-init-header))

;;;; Commands

(defun hermes-sessions-db--sid-at-point ()
  "Return the DB session id at point, or signal."
  (or (tabulated-list-get-id)
      (user-error "No session on this line")))

(defun hermes-sessions-db-refresh ()
  "Re-fetch the session list from the gateway."
  (interactive)
  (hermes-sessions-db--fetch))

(defun hermes-sessions-db-toggle-cwd-filter ()
  "Toggle filtering by current project's cwd."
  (interactive)
  (setq hermes-sessions-db--cwd-filter
        (not hermes-sessions-db--cwd-filter))
  (message "hermes: cwd filter %s"
           (if hermes-sessions-db--cwd-filter "on" "off"))
  (hermes-sessions-db--fetch))

(defun hermes-sessions-db-jump-to-live ()
  "Open the live sessions sidebar."
  (interactive)
  (if (fboundp 'hermes-sessions)
      (call-interactively #'hermes-sessions)
    (user-error "hermes-sessions is not loaded")))

(defun hermes-sessions-db-pick ()
  "Prompt the user to choose an action for the session at point."
  (interactive)
  (let* ((sid (hermes-sessions-db--sid-at-point))
         (choice (read-char-choice
                  (format "Session %s — [r]esume / [b]ranch / [d]elete / [s]ave / [q]uit: "
                          (hermes-sessions-db--short-sid sid))
                  '(?r ?b ?d ?s ?q))))
    (pcase choice
      (?r (hermes-sessions-db-resume))
      (?b (hermes-sessions-db-branch))
      (?d (hermes-sessions-db-delete))
      (?s (hermes-sessions-db-save))
      (?q (message "Cancelled")))))

(defun hermes-sessions-db-resume ()
  "Resume the DB session at point into a fresh buffer.
Wired in Phase 4 (`hermes-resume-from-db')."
  (interactive)
  (let ((sid (hermes-sessions-db--sid-at-point)))
    (if (fboundp 'hermes-resume-from-db)
        (hermes-resume-from-db sid)
      (user-error "hermes-resume-from-db not yet implemented (Phase 4): %s"
                  (hermes-sessions-db--short-sid sid)))))

(defun hermes-sessions-db-branch ()
  "Branch the DB session at point into a new session.
Wired in Phase 4 (`hermes-branch-from-db')."
  (interactive)
  (let ((sid (hermes-sessions-db--sid-at-point)))
    (if (fboundp 'hermes-branch-from-db)
        (hermes-branch-from-db sid)
      (user-error "hermes-branch-from-db not yet implemented (Phase 4): %s"
                  (hermes-sessions-db--short-sid sid)))))

(defun hermes-sessions-db-delete ()
  "Delete the DB session at point.  Confirms first."
  (interactive)
  (let* ((sid (hermes-sessions-db--sid-at-point))
         (short (hermes-sessions-db--short-sid sid)))
    (unless (yes-or-no-p (format "Delete session %s from gateway DB? " short))
      (user-error "Cancelled"))
    (hermes-rpc-request
     "session.delete" (list :session_id sid)
     (lambda (_result error)
       (cond
        (error (message "hermes: session.delete error: %S" error))
        (t
         (message "hermes: deleted %s" short)
         (hermes-sessions-db--refresh-if-open)))))))

(defun hermes-sessions-db-save ()
  "Export the DB session at point to a JSON file via `session.save'."
  (interactive)
  (let* ((sid (hermes-sessions-db--sid-at-point))
         (short (hermes-sessions-db--short-sid sid)))
    (hermes-rpc-request
     "session.save" (list :session_id sid)
     (lambda (result error)
       (cond
        (error (message "hermes: session.save error: %S" error))
        (t
         (let ((file (and (hash-table-p result) (gethash "file" result))))
           (message "hermes: saved %s → %s" short (or file "?")))))))))

;;;###autoload
(defun hermes-sessions-db ()
  "Open the gateway DB session browser."
  (interactive)
  (let ((buf (get-buffer-create hermes-sessions-db-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'hermes-sessions-db-mode)
        (hermes-sessions-db-mode))
      (hermes-sessions-db--fetch))
    (pop-to-buffer buf
                   '(display-buffer-in-side-window
                     (side . right)
                     (window-width . 60)))))

(provide 'hermes-sessions-db)
;;; hermes-sessions-db.el ends here
