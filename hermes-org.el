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
(defvar hermes--state)
(defvar hermes-minor-mode)

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
  "Non-nil if point is on a heading tagged `:hermes:'.
The heading need not yet carry a `:HERMES_SESSION:' property — a
freshly-inserted container is recognised before the gateway has
assigned it an id."
  (and (derived-mode-p 'org-mode)
       (org-at-heading-p)
       (member "hermes" (org-get-tags nil t))))

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
Returns nil when no session is reachable."
  (cond
   ((derived-mode-p 'hermes-mode)
    (and (boundp 'hermes--state) hermes--state
         (cons (hermes-state-session-id hermes--state) hermes--state)))
   ((bound-and-true-p hermes-minor-mode)
    (let* ((sid (hermes--session-at-point))
           (state (and sid (hermes--lookup-session-state sid))))
      (and sid state (cons sid state))))))

(provide 'hermes-org)
;;; hermes-org.el ends here
