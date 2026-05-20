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

(declare-function hermes-state-session-id "hermes-state" (state))
(declare-function make-hermes-state "hermes-state" (&rest _))
(declare-function hermes--plist-to-message "hermes-state" (plist))
(declare-function hermes--extract-raw-drawer "hermes-render" (&optional pos))
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

(defun hermes--parse-subtree-messages ()
  "Parse `:HERMES_RAW:' drawers under the heading at point into a vector
of `hermes-message' structs.  Scope is the current Org subtree only,
and the container heading itself is skipped — `hermes--extract-raw-drawer'
treats the next drawer inside the subtree as the heading's own, so the
container would otherwise vacuum up its first child's drawer."
  (let (messages)
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (org-back-to-heading t)
        (let ((container-level (org-current-level)))
          (org-map-entries
           (lambda ()
             (when (> (org-current-level) container-level)
               (let ((raw (save-excursion (hermes--extract-raw-drawer))))
                 (when raw
                   (push (hermes--plist-to-message raw) messages)))))
           nil 'tree))))
    (vconcat (nreverse messages))))

(declare-function hermes-minor-mode "hermes-mode" (&optional arg))
(declare-function hermes-bench-ensure "hermes-bench" (parent))

(defun hermes--rebuild-session-state (sid marker)
  "Build a fresh `hermes-state' for SID and register it under MARKER.
The state atom holds only ephemeral data (stream / queue / pending);
committed history already lives in the Org subtree as `:HERMES_RAW:'
drawers, so there's nothing to seed.  Mirroring to `hermes--state'
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
