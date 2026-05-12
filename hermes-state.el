;;; hermes-state.el --- TEA-style state + reducer for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Two buffer-local atoms per session: `hermes--state' (persistent, mirrored
;; in the Org buffer) and `hermes--ui-state' (ephemeral).  Mutations go
;; through `hermes-dispatch' / `hermes-ui-dispatch', which call a pure
;; reducer and swap the var atomically, then run a change hook for the
;; renderer to subscribe to.

;;; Code:

(require 'cl-lib)

;;;; Persistent state — mirrored in the Org buffer

(cl-defstruct (hermes-tool (:copier hermes-tool-copy))
  id name
  status      ; 'generating | 'running | 'complete | 'error
  output error duration)

(cl-defstruct (hermes-message (:copier hermes-message-copy))
  kind        ; 'user | 'assistant | 'system
  text        ; raw markdown for assistant / plain for user / status text
  tools       ; vector of hermes-tool (the trail)
  usage timestamp)

(cl-defstruct (hermes-stream (:copier hermes-stream-copy))
  text thinking reasoning
  tools)

(cl-defstruct (hermes-pending (:copier hermes-pending-copy))
  kind        ; 'approval | 'clarify | 'secret | 'sudo
  request-id payload)

(cl-defstruct (hermes-state (:copier hermes-state-copy))
  connection         ; 'disconnected | 'connecting | 'connected
  session-id
  session-info       ; hash-table or nil
  (messages [])      ; vector — COMMITTED only
  stream             ; hermes-stream or nil
  pending            ; hermes-pending or nil
  slash-catalog
  (queue nil)
  (history nil)
  skin)

;;;; Ephemeral UI state — never persisted to the buffer

(cl-defstruct (hermes-ui-state (:copier hermes-ui-state-copy))
  status-text status-kind
  spinner-frame
  (tool-previews nil))  ; alist tool-id → preview string

;;;; Atoms and dispatchers

(defvar-local hermes--state nil
  "Current persistent state (a `hermes-state').")

(defvar-local hermes--ui-state nil
  "Current ephemeral UI state (a `hermes-ui-state').")

(defvar hermes-state-change-hook nil
  "Hook of (OLD NEW) called after `hermes--state' is swapped.
Both arguments are `hermes-state' structs; OLD may be nil at init.")

(defvar hermes-ui-state-change-hook nil
  "Hook of (OLD NEW) called after `hermes--ui-state' is swapped.")

(defun hermes-state-init ()
  "Initialise the buffer-local atoms.  Safe to call on an existing buffer."
  (unless hermes--state
    (setq hermes--state (make-hermes-state :connection 'disconnected)))
  (unless hermes--ui-state
    (setq hermes--ui-state (make-hermes-ui-state))))

(defun hermes-dispatch (msg)
  "Reduce MSG into the persistent state and notify subscribers."
  (let* ((old hermes--state)
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (setq hermes--state new)
      (run-hook-with-args 'hermes-state-change-hook old new))))

(defun hermes-ui-dispatch (msg)
  "Reduce MSG into the ephemeral state and notify subscribers."
  (let* ((old hermes--ui-state)
         (new (hermes--ui-reduce old msg)))
    (unless (eq old new)
      (setq hermes--ui-state new)
      (run-hook-with-args 'hermes-ui-state-change-hook old new))))

;;;; Reducer helpers

(defun hermes--get (payload key)
  "Read KEY from PAYLOAD which may be a hash-table, alist or plist."
  (cond ((hash-table-p payload) (gethash key payload))
        ((and (consp payload) (consp (car payload)))
         (alist-get key payload nil nil #'equal))
        (t (plist-get payload key))))

(defmacro hermes--with-copy (struct copier place &rest body)
  "Bind PLACE to a fresh shallow copy of STRUCT and run BODY for side effects.
BODY is expected to `setf' slots on PLACE.  Returns PLACE."
  (declare (indent 3))
  `(let ((,place (,copier ,struct)))
     ,@body
     ,place))

(defun hermes--vector-append (vec elt)
  "Return a new vector that is VEC with ELT pushed onto the end."
  (vconcat vec (vector elt)))

;;;; Persistent reducer
;;
;; MSG is (TYPE . PAYLOAD).  TYPE is a string for gateway events
;; (e.g. "message.delta") or a keyword for client actions
;; (e.g. :user-submit, :connected).  PAYLOAD is a hash-table or plist.

(defun hermes--reduce (state msg)
  "Pure: produce a new `hermes-state' from STATE and MSG."
  (unless state (setq state (make-hermes-state :connection 'disconnected)))
  (let ((type (car msg))
        (p    (cdr msg)))
    (pcase type
      ;;; --- Internal actions ----------------------------------------------
      (:connecting
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-connection s) 'connecting)))
      (:connected
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-connection s) 'connected)))
      (:disconnected
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-connection s) 'disconnected)))
      (:user-submit
       ;; Optimistic commit (mirrors useSubmission.ts:87-149).
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-messages s)
               (hermes--vector-append
                (hermes-state-messages state)
                (make-hermes-message :kind 'user
                                     :text (plist-get p :text)
                                     :timestamp (current-time))))))
      ;;; --- Gateway lifecycle ---------------------------------------------
      ("gateway.ready"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-connection s) 'connected
               (hermes-state-skin s) (hermes--get p "skin"))))
      ("session.info"
       ;; Merge into existing (createGatewayEventHandler.ts:279-292).
       (hermes--with-copy state hermes-state-copy s
         (when (hash-table-p p)
           (let ((sid (hermes--get p "session_id"))
                 (merged (or (hermes-state-session-info state)
                             (make-hash-table :test 'equal))))
             (maphash (lambda (k v) (puthash k v merged)) p)
             (setf (hermes-state-session-info s) merged)
             (when sid (setf (hermes-state-session-id s) sid))))))
      ;;; --- Message stream ------------------------------------------------
      ("message.start"
       ;; Discard any in-flight stream silently (turnController.ts:746-757).
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-stream s)
               (make-hermes-stream :text "" :thinking "" :reasoning ""
                                   :tools []))))
      ("message.delta"
       (let ((old-stream (or (hermes-state-stream state)
                             (make-hermes-stream :text "" :thinking ""
                                                 :reasoning "" :tools [])))
             (chunk (or (hermes--get p "text") "")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (hermes--with-copy old-stream hermes-stream-copy ns
                   (setf (hermes-stream-text ns)
                         (concat (hermes-stream-text old-stream) chunk)))))))
      ("thinking.delta"
       (let ((old-stream (or (hermes-state-stream state)
                             (make-hermes-stream :text "" :thinking ""
                                                 :reasoning "" :tools [])))
             (chunk (or (hermes--get p "text") "")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (hermes--with-copy old-stream hermes-stream-copy ns
                   (setf (hermes-stream-thinking ns)
                         (concat (hermes-stream-thinking old-stream)
                                 chunk)))))))
      ("reasoning.delta"
       (let ((old-stream (or (hermes-state-stream state)
                             (make-hermes-stream :text "" :thinking ""
                                                 :reasoning "" :tools [])))
             (chunk (or (hermes--get p "text") "")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (hermes--with-copy old-stream hermes-stream-copy ns
                   (setf (hermes-stream-reasoning ns)
                         (concat (hermes-stream-reasoning old-stream)
                                 chunk)))))))
      ("message.complete"
       ;; Commit stream → messages.
       (let ((str (hermes-state-stream state)))
         (if (null str)
             state                      ; nothing to commit
           (let ((msg (make-hermes-message
                       :kind 'assistant
                       :text (hermes-stream-text str)
                       :tools (hermes-stream-tools str)
                       :usage p
                       :timestamp (current-time))))
             (hermes--with-copy state hermes-state-copy s
               (setf (hermes-state-messages s)
                     (hermes--vector-append (hermes-state-messages state) msg)
                     (hermes-state-stream s) nil))))))
      ;;; --- Errors --------------------------------------------------------
      ("error"
       (let ((text (or (hermes--get p "message") "(unknown error)")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message :kind 'system :text text
                                       :timestamp (current-time)))))))
      ;;; --- Pass-through (no-op for M2) -----------------------------------
      (_ state))))

;;;; UI reducer (minimal for M2)

(defun hermes--ui-reduce (state msg)
  "Pure: produce a new `hermes-ui-state' from STATE and MSG."
  (unless state (setq state (make-hermes-ui-state)))
  (let ((type (car msg))
        (p    (cdr msg)))
    (pcase type
      ("status.update"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) (hermes--get p "text")
               (hermes-ui-state-status-kind s) (hermes--get p "kind"))))
      ("message.start"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) "Responding…")))
      ("message.complete"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) nil)))
      (_ state))))

(provide 'hermes-state)
;;; hermes-state.el ends here
