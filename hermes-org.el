;;; hermes-org.el --- Heading-scoped session helpers -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai

;;; Commentary:

;; Helpers for embedding Hermes sessions in arbitrary Org buffers.  A
;; session container is any Org heading tagged `:hermes:' that carries
;; (or will carry) a `:HERMES_SESSION:' property.  This file owns the
;; read-side lookups — finding the session a point is sitting in,
;; managing the per-buffer registry.  Dispatch and rendering hooks land
;; in Phase 2 slices B and C.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'hermes-state)

(declare-function hermes-state-session-id "hermes-state" (state))
(declare-function make-hermes-state "hermes-state" (&rest _))
(declare-function hermes--plist-to-message "hermes-state" (plist))
(declare-function hermes--extract-meta-drawer "hermes-render" (&optional pos))
(declare-function hermes--next-segment-id "hermes-state" ())
(declare-function make-hermes-segment "hermes-state" (&rest _))
(declare-function make-hermes-message "hermes-state" (&rest _))
(declare-function make-hermes-tool "hermes-state" (&rest _))
(declare-function hermes--plist-to-subagent "hermes-state" (p))
(declare-function hermes-rpc-request "hermes-rpc" (method params callback))
(declare-function hermes-rpc-live-p "hermes-rpc" ())
(declare-function hermes-rpc-start "hermes-rpc" ())
(declare-function hermes--install-hooks "hermes-mode" ())
(declare-function hermes-input--send-1 "hermes-input" (text))
(defvar hermes--state)
(defvar hermes-minor-mode)
(defvar hermes--container-level)
(defvar hermes--last-gateway-ready)
(defvar hermes--session-buffers)

;;;; Buffer-local registries

(defvar-local hermes--buffer-sessions nil
  "Hash table mapping session_id (string) → `hermes-state' struct.
Populated by Phase 2 slice B as the dispatcher learns about sessions
hosted in this buffer.  Nil until the buffer hosts at least one
session.")

(defvar-local hermes--session-markers nil
  "Hash table mapping session_id (string) → marker at the session's
container heading.  Markers track edits to surrounding text so the
renderer can always find the correct subtree.")

(defun hermes--ensure-registries ()
  "Create the per-buffer session/marker hash tables if absent."
  (unless (hash-table-p hermes--buffer-sessions)
    (setq hermes--buffer-sessions (make-hash-table :test 'equal)))
  (unless (hash-table-p hermes--session-markers)
    (setq hermes--session-markers (make-hash-table :test 'equal))))

;;;; Lookups

(defun hermes--heading-is-container-p ()
  "Non-nil if point is on a Hermes session container heading.
Recognises both the `:hermes:' tag and the `HERMES_SESSION' property,
so restored files (which may have lost the tag) and freshly-inserted
headings (which may not yet have the property) both work."
  (and (derived-mode-p 'org-mode)
       (org-at-heading-p)
       (or (member "hermes" (org-get-tags nil t))
           (org-entry-get (point) "HERMES_SESSION"))))

(defun hermes--session-id-at-heading ()
  "Return the `:HERMES_SESSION:' property of the heading at point, or nil."
  (when (org-at-heading-p)
    (org-entry-get (point) "HERMES_SESSION")))

(defun hermes--session-at-point ()
  "Return the session_id of the Hermes container containing point, or nil.
Walks up the heading hierarchy looking for the nearest ancestor (or
the heading at point itself) tagged `:hermes:' and carrying a
`:HERMES_SESSION:' property.  Returns nil if no such container is
found — including when the container exists but has no session id
yet (a freshly-inserted heading awaiting `session.create')."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (let ((found nil))
        ;; Move to the nearest heading at or above point.
        (unless (org-at-heading-p)
          (ignore-errors (org-back-to-heading t)))
        (catch 'done
          (while (org-at-heading-p)
            (when (hermes--heading-is-container-p)
              (let ((sid (hermes--session-id-at-heading)))
                (when sid
                  (setq found sid)
                  (throw 'done nil))))
            (unless (ignore-errors (org-up-heading-safe))
              (throw 'done nil))))
        found))))

(defun hermes--container-marker-at-point ()
  "Return a marker at the nearest enclosing `:hermes:'-tagged heading.
Returns nil if no such ancestor exists."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (unless (org-at-heading-p)
        (ignore-errors (org-back-to-heading t)))
      (catch 'done
        (while (org-at-heading-p)
          (when (hermes--heading-is-container-p)
            (throw 'done (copy-marker (point) nil)))
          (unless (ignore-errors (org-up-heading-safe))
            (throw 'done nil)))))))

;;;; Registry mutators (used by slice B)

(defun hermes--register-session (session-id state marker)
  "Record SESSION-ID → STATE / MARKER in the buffer-local registries."
  (hermes--ensure-registries)
  (puthash session-id state hermes--buffer-sessions)
  (puthash session-id marker hermes--session-markers))

(defun hermes--lookup-session-state (session-id)
  "Return the per-session `hermes-state' struct for SESSION-ID, or nil."
  (and (hash-table-p hermes--buffer-sessions)
       (gethash session-id hermes--buffer-sessions)))

(defun hermes--lookup-session-marker (session-id)
  "Return the marker for SESSION-ID's container heading, or nil."
  (and (hash-table-p hermes--session-markers)
       (gethash session-id hermes--session-markers)))

;;;; User-facing session resolution

(defun hermes--resolve-session-target ()
  "Return (SID . STATE) for the active session of the current buffer.
- In a `hermes-mode' (primary) buffer, returns the buffer-local
  `hermes--state' as the active session.
- In an arbitrary Org buffer with `hermes-minor-mode' enabled, walks
  up from point to find the enclosing `:hermes:' container and looks
  the corresponding state up in `hermes--buffer-sessions'.
- In a `hermes-bench-mode' buffer, delegates to the paired parent
  buffer so commands invoked from the bench resolve against the
  parent's session.
Returns nil when no session is reachable."
  (cond
   ((derived-mode-p 'hermes-mode)
    (and (boundp 'hermes--state) hermes--state
         (cons (hermes-state-session-id hermes--state) hermes--state)))
   ((bound-and-true-p hermes-minor-mode)
    (let* ((sid (hermes--session-at-point))
           (state (and sid (hermes--lookup-session-state sid))))
      ;; Return (sid . nil) for the *stale* case — the heading carries
      ;; a `:HERMES_SESSION:' but the in-memory registry has no entry
      ;; (e.g. file just reopened).  The caller distinguishes that
      ;; from "no container at all" (nil return) so it can trigger
      ;; an on-demand resume.
      (and sid (cons sid state))))
   ((and (boundp 'hermes-bench--parent-buffer)
         hermes-bench--parent-buffer
         (buffer-live-p hermes-bench--parent-buffer))
    (with-current-buffer hermes-bench--parent-buffer
      (hermes--resolve-session-target)))))

;;;; Resume / rehydration

(defvar hermes--pre-send-queue nil
  "Alist of (SESSION-ID . TEXT) waiting for a stale session to resume.
Populated by `hermes-input-send' when the user targets a heading whose
`:HERMES_SESSION:' has no active in-memory state.  `hermes--drain-pre-send-queue'
flushes the matching entry once resume / fresh-create completes.")

(defun hermes--extract-named-block (text name)
  "Find an Org block labelled NAME in TEXT and return its unwrapped content.
TEXT is the body of an Org heading (a string).  NAME is the value
expected after `#+name:', e.g. \"hermes-tool-write_file-inline-diff\".

Scans for a `#+name: NAME' line, reads the wrapper type (`src',
`example', ...) from the immediately following `#+begin_TYPE' line,
and returns the content up to the matching `#+end_TYPE' line, with
surrounding whitespace trimmed.  Returns nil if NAME is absent or
the wrapper is malformed.  Note: a literal `#+end_TYPE' line embedded
in the block content will terminate extraction early — this is the
standard text-inside-block boundary problem and is accepted."
  (when (and text name)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((case-fold-search t)
            (pattern (format "^#\\+name: %s[ \t]*$" (regexp-quote name))))
        (when (re-search-forward pattern nil t)
          (forward-line 1)
          (when (looking-at "^#\\+begin_\\([a-zA-Z][a-zA-Z0-9_-]*\\)")
            (let ((type (match-string 1))
                  (start (line-end-position)))
              (when (re-search-forward
                     (format "^#\\+end_%s[ \t]*$" (regexp-quote type))
                     nil t)
                (let ((content (buffer-substring-no-properties
                                (1+ start) (line-beginning-position))))
                  (string-trim content))))))))))

(defun hermes--extract-named-table (text name)
  "Find the Org table labelled NAME in TEXT and return its raw text.
TEXT is the body of an Org heading (string).  NAME is the value
expected after `#+name:'.  The line immediately after the `#+name'
must begin with `|' (no blank line between).  Returns the table
text — pipe-prefixed rows joined by newlines — with trailing
whitespace trimmed.  Returns nil if NAME is absent or the line
after it is not a table row.

Companion to `hermes--extract-named-block': blocks (`#+begin_…')
extract through the block helper; bare named tables extract here."
  (when (and text name)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((case-fold-search t)
            (pattern (format "^#\\+name: %s[ \t]*$" (regexp-quote name))))
        (when (re-search-forward pattern nil t)
          (forward-line 1)
          (when (looking-at "^[ \t]*|")
            (let ((start (line-beginning-position))
                  (end (save-excursion
                         (while (and (not (eobp))
                                     (looking-at "^[ \t]*|"))
                           (forward-line 1))
                         (point))))
              (when (> end start)
                (string-trim-right
                 (buffer-substring-no-properties start end))))))))))

(defun hermes--parse-todos-table (text)
  "Parse an Org table in TEXT into a list of hash-tables.
Each row must match `| [X|space|-] | status | id | content |'.
Returns hash-tables with string keys \"status\", \"id\", \"content\",
matching the gateway shape.  The checkbox column (1) is ignored;
column 2 is read verbatim as the canonical status string — this
preserves `pending', `in_progress', `completed' (or any other
status string the gateway introduces) without normalization.
Returns nil for nil input or when no rows match."
  (when text
    (let ((items nil)
          (re (concat "^[ \t]*"
                      "| *\\[\\([Xx -]\\)\\] *"
                      "| *\\([^|]+?\\) *"
                      "| *\\([^|]*?\\) *"
                      "| *\\(.*?\\) *"
                      "|[ \t]*$")))
      (dolist (line (split-string text "\n" t))
        (when (string-match re line)
          (let ((ht (make-hash-table :test 'equal)))
            (puthash "status"  (match-string 2 line) ht)
            (puthash "id"      (match-string 3 line) ht)
            (puthash "content" (match-string 4 line) ht)
            (push ht items))))
      (nreverse items))))

(defun hermes--parse-heading-body ()
  "Return the body text of the Org heading at point, excluding child
headings, the property drawer, and any sibling `:HERMES_META:' drawer.
Point must be on a heading."
  (save-excursion
    (let ((subtree-end (save-excursion (org-end-of-subtree t t))))
      (forward-line 1)
      (when (looking-at "^:PROPERTIES:")
        (re-search-forward "^:END:" nil t)
        (forward-line 1))
      (let ((start (point))
            (end (or (save-excursion
                       (catch 'stop
                         (while (< (point) subtree-end)
                           (cond
                            ((org-at-heading-p) (throw 'stop (point)))
                            ((looking-at "^:HERMES_META:") (throw 'stop (point)))
                            (t (forward-line 1))))
                         subtree-end))
                     subtree-end)))
        (when (> end start)
          (let ((s (string-trim (buffer-substring-no-properties start end))))
            (and (not (string-empty-p s)) s)))))))

(defun hermes--parse-turn-body-text ()
  "Return the body text under a turn heading at point.
Excludes child headings, :PROPERTIES:, and :HERMES_META: drawers."
  (save-excursion
    (let ((turn-end (save-excursion (org-end-of-subtree t t))))
      (forward-line 1)
      (when (looking-at "^:PROPERTIES:")
        (re-search-forward "^:END:" nil t)
        (forward-line 1))
      (let ((start (point))
            (end (or (save-excursion
                       (catch 'stop
                         (while (< (point) turn-end)
                           (cond
                            ((org-at-heading-p) (throw 'stop (point)))
                            ((looking-at "^:HERMES_META:") (throw 'stop (point)))
                            (t (forward-line 1))))
                         turn-end))
                     turn-end)))
        (when (> end start)
          (let ((s (string-trim (buffer-substring-no-properties start end))))
            (and (not (string-empty-p s)) s)))))))

(defun hermes--parse-turn-at-point ()
  "Parse the turn heading at point into a `hermes-message' struct.
Derives text segments from visible buffer structure (USER/SYSTEM body,
or assistant child Response/Reasoning headings).  Reads tool segments,
usage, images, and subagents from the :HERMES_META: drawer.  Returns
nil if point is not on a recognized turn heading."
  (when (and (derived-mode-p 'org-mode)
             (org-at-heading-p))
    (let* ((kind-prop (org-entry-get (point) "HERMES_KIND"))
           (kind (pcase kind-prop
                   ("USER" 'user)
                   ("ASSISTANT" 'assistant)
                   ("SYSTEM" 'system)
                   (_ nil)))
           (timestamp (org-entry-get (point) "HERMES_TIMESTAMP"))
           (meta (save-excursion (hermes--extract-meta-drawer)))
           (segs ()))
      (when kind
        (cond
         ((memq kind '(user system))
          (let ((text (hermes--parse-turn-body-text)))
            (when text
              (push (make-hermes-segment :type 'text :content text
                                         :id (hermes--next-segment-id))
                    segs))))
         ((eq kind 'assistant)
          (let ((turn-pos (point))
                (turn-end (save-excursion (org-end-of-subtree t t))))
            (save-excursion
              (when (ignore-errors (org-goto-first-child))
                (let ((continue t))
                  (while continue
                    (when (and (org-at-heading-p) (< (point) turn-end))
                      (let ((child-kind (org-entry-get (point) "HERMES_KIND")))
                        (cond
                         ((equal child-kind "RESPONSE")
                          (let ((text (hermes--parse-heading-body)))
                            (when text
                              (push (make-hermes-segment :type 'text
                                                         :content text
                                                         :id (hermes--next-segment-id))
                                    segs))))
                         ((equal child-kind "REASONING")
                          (let ((text (hermes--parse-heading-body)))
                            (when text
                              (push (make-hermes-segment :type 'reasoning
                                                         :content text
                                                         :id (hermes--next-segment-id))
                                    segs))))
                         ((equal child-kind "TOOL")
                          (let* ((tool-id (org-entry-get (point) "TOOL_ID"))
                                 (name (or (org-entry-get (point) "TOOL_NAME")
                                           "tool"))
                                 (status-str (or (org-entry-get (point) "TOOL_STATUS")
                                                 "complete"))
                                 (status (intern status-str))
                                 (dur-str (org-entry-get (point) "TOOL_DURATION"))
                                 (duration (and dur-str
                                                (ignore-errors (read dur-str))))
                                 ;; Meta is optional enrichment; the heading
                                 ;; alone is sufficient for a tool segment.
                                 ;; :inline-diff, :output, and :error are
                                 ;; body-canonical at terminal status — they
                                 ;; live in the heading body as #+name'd
                                 ;; blocks.  Clean break: no meta fallback.
                                 (tcs (plist-get meta :tool-calls))
                                 (tc (and tcs tool-id
                                          (cl-find-if
                                           (lambda (x)
                                             (equal tool-id (plist-get x :id)))
                                           (append tcs nil))))
                                 (body (hermes--parse-heading-body))
                                 (slug (hermes--slug-for-name tool-id))
                                 (terminal-p (memq status '(complete error))))
                            (push (make-hermes-segment
                                   :type 'tool
                                   :content (make-hermes-tool
                                             :id tool-id
                                             :name name
                                             :status status
                                             :duration duration
                                             :output (and terminal-p slug
                                                          (hermes--extract-named-block
                                                           body
                                                           (format "hermes-tool-%s-output" slug)))
                                             :context (hermes--strip-ansi (plist-get tc :context))
                                             :preview (hermes--strip-ansi (plist-get tc :preview))
                                             :inline-diff (and terminal-p slug
                                                               (hermes--extract-named-block
                                                                body
                                                                (format "hermes-tool-%s-inline-diff" slug)))
                                             :todos (let ((table (and slug
                                                                       (hermes--extract-named-table
                                                                        body
                                                                        (format "hermes-tool-%s-todos" slug)))))
                                                      (and table (hermes--parse-todos-table table)))
                                             :summary (hermes--strip-ansi (plist-get tc :summary))
                                             :error (and (eq status 'error) slug
                                                         (hermes--extract-named-block
                                                          body
                                                          (format "hermes-tool-%s-error" slug))))
                                   :id (hermes--next-segment-id))
                                  segs)))
                         (t nil))))
                    (unless (and (outline-next-heading)
                                 (< (point) turn-end))
                      (setq continue nil))))))
            (ignore turn-pos)))
         (t nil))
        (let* ((sa-raw (plist-get meta :subagents))
               (subagents
                (cond
                 ((vectorp sa-raw)
                  (apply #'vector
                         (mapcar #'hermes--plist-to-subagent
                                 (append sa-raw nil))))
                 ((listp sa-raw)
                  (apply #'vector
                         (mapcar #'hermes--plist-to-subagent sa-raw)))
                 (t []))))
          (make-hermes-message
           :kind kind
           :segments (vconcat (nreverse segs))
           :usage (plist-get meta :usage)
           :subagents subagents
           :timestamp timestamp))))))

(defun hermes--parse-subtree-messages ()
  "Parse turn headings under the container at point into a vector of
`hermes-message' structs.  Scope is the current Org subtree only; the
container heading itself is skipped.  Derives text from visible buffer
structure, reads metadata from :HERMES_META: drawers."
  (let (messages)
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (org-back-to-heading t)
        (let ((container-level (org-current-level)))
          (org-map-entries
           (lambda ()
             (when (= (org-current-level) (1+ container-level))
               (let ((msg (hermes--parse-turn-at-point)))
                 (when msg
                   (push msg messages)))))
           nil 'tree))))
    (vconcat (nreverse messages))))

(declare-function hermes-minor-mode "hermes-mode" (&optional arg))
(declare-function hermes-bench-ensure "hermes-bench" (parent))

(defun hermes--rebuild-session-state (sid marker)
  "Build a fresh `hermes-state' for SID and register it under MARKER.
The state atom holds only ephemeral data (stream / queue / pending);
committed history already lives in the Org subtree as visible text
plus `:HERMES_META:' drawers, so there's nothing to seed.  Mirroring to `hermes--state'
keeps single-session readers coherent.  Also ensures `hermes-minor-mode'
is on and the bench is visible so the user can interact with the
resumed session.  Returns the new state."
  (let* ((cwd-prop (save-excursion
                     (goto-char (marker-position marker))
                     (when (org-at-heading-p)
                       (let ((v (org-entry-get (point) "HERMES_CWD")))
                         (and v (not (string-empty-p v))
                              (expand-file-name v))))))
         (state (make-hermes-state :session-id sid
                                   :connection 'connected
                                   :cwd cwd-prop)))
    (hermes--register-session sid state marker)
    (setq hermes--state state)
    (unless (or (derived-mode-p 'hermes-mode)
                (bound-and-true-p hermes-minor-mode))
      (hermes-minor-mode 1))
    (unless noninteractive
      (hermes-bench-ensure (current-buffer)))
    state))

(defun hermes--drain-pre-send-queue (sid)
  "Submit any text queued under SID via `hermes-input--send-1'.
Called from resume / fresh-create callbacks; safe to call when no
entry exists.  The submission runs with `hermes--current-session-id'
bound so dispatch routes correctly."
  (let ((entry (assoc sid hermes--pre-send-queue)))
    (when entry
      (setq hermes--pre-send-queue
            (assq-delete-all (car entry) hermes--pre-send-queue))
      (let* ((state (hermes--lookup-session-state sid))
             (hermes--current-session-id sid))
        (when state
          (if (eq state hermes--state)
              (hermes-input--send-1 (cdr entry))
            (let ((hermes--state state))
              (hermes-input--send-1 (cdr entry)))))))))

(defun hermes--create-fresh-session (old-sid marker)
  "Create a brand-new gateway session to replace the unresumable OLD-SID.
The container heading at MARKER gets its `:HERMES_SESSION:' rewritten
to the new id, registries re-keyed, and any pre-send queue entries
keyed by OLD-SID are drained against the new session."
  (let ((buf (current-buffer))
        (marker-pos (marker-position marker)))
    (hermes-rpc-request
     "session.create" '(:cols 100)
     (lambda (result error)
       (cond
        (error
         (message "hermes: session.create failed: %S" error))
        (result
         (let ((new-sid (gethash "session_id" result)))
           (when (and new-sid (buffer-live-p buf))
             (with-current-buffer buf
               (save-excursion
                 (goto-char marker-pos)
                 (when (org-at-heading-p)
                   (org-set-property "HERMES_SESSION" new-sid)))
               (let ((fresh-marker (save-excursion
                                     (goto-char marker-pos)
                                     (copy-marker (point) nil))))
                 (hermes--rebuild-session-state new-sid fresh-marker))
               (when (boundp 'hermes--session-buffers)
                 (puthash new-sid buf hermes--session-buffers))
               ;; Move the queued text from old-sid → new-sid before draining.
               (let ((entry (assoc old-sid hermes--pre-send-queue)))
                 (when entry
                   (setq hermes--pre-send-queue
                         (assq-delete-all old-sid hermes--pre-send-queue))
                   (push (cons new-sid (cdr entry)) hermes--pre-send-queue)))
               (hermes--drain-pre-send-queue new-sid)
               (message "hermes: replaced stale %s with fresh %s"
                        old-sid new-sid))))))))))

(defun hermes--resume-heading-session (sid)
  "Attempt `session.resume' for SID; fall back to a fresh session on error.
On success the in-memory state is rebuilt from the heading's drawers
and any pre-send queue entry is drained.  On failure a new session is
created via `hermes--create-fresh-session', which also drains."
  (let ((marker (hermes--container-marker-at-point))
        (buf (current-buffer)))
    (unless (and marker (marker-position marker))
      (user-error "No container marker for session %s" sid))
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p)
      (hermes-rpc-start))
    (hermes-rpc-request
     "session.resume" (list :session_id sid)
     (lambda (_result error)
       (when (buffer-live-p buf)
         (with-current-buffer buf
           (cond
            (error
             (message "hermes: resume %s failed (%S) — creating fresh session"
                      sid error)
             (hermes--create-fresh-session sid marker))
            (t
             (hermes--rebuild-session-state sid marker)
             (when (and (boundp 'hermes--session-buffers)
                        (hash-table-p hermes--session-buffers))
               (puthash sid buf hermes--session-buffers))
             (hermes--drain-pre-send-queue sid)
             (message "hermes: resumed session %s" sid)))))))))

(provide 'hermes-org)
;;; hermes-org.el ends here
