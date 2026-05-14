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
(require 'ansi-color)

(defcustom hermes-history-max 200
  "Maximum number of past inputs retained in `hermes-state-history'."
  :type 'integer :group 'hermes)

;;;; Persistent state — mirrored in the Org buffer

(cl-defstruct (hermes-segment (:copier hermes-segment-copy))
  type        ; 'text | 'thinking | 'reasoning | 'tool | 'system
  content     ; string for text/thinking/reasoning/system; hermes-tool for tool segments
  id)         ; unique segment id (for stable updates)

(cl-defstruct (hermes-tool (:copier hermes-tool-copy))
  id name
  status      ; 'generating | 'running | 'complete | 'error
  context     ; tool args preview from tool.start
  preview     ; live preview from tool.progress
  inline-diff ; diff output from tool.complete
  todos       ; list of plists (:text :done) from tool.complete
  output error duration)

(cl-defstruct (hermes-subagent (:copier hermes-subagent-copy))
  id          ; string — subagent_id from gateway
  goal        ; string — delegation goal
  status      ; 'queued | 'running | 'complete | 'error
  thinking    ; string — accumulated thinking text
  tools       ; vector of plists (:name :args :timestamp)
  notes       ; vector of strings — progress notes
  summary     ; string — final result summary
  duration)   ; number — duration in seconds

(cl-defstruct (hermes-message (:copier hermes-message-copy))
  kind        ; 'user | 'assistant | 'system
  text        ; DEPRECATED: derive from segments
  thinking    ; DEPRECATED: derive from segments
  reasoning   ; DEPRECATED: derive from segments
  tools       ; DEPRECATED: derive from segments
  segments    ; vector of hermes-segment
  usage timestamp
  subagents)  ; vector of hermes-subagent

(cl-defstruct (hermes-stream (:copier hermes-stream-copy))
  segments    ; vector of hermes-segment, ordered by arrival
  tools       ; DEPRECATED: kept for backward compat
  subagents)  ; vector of hermes-subagent

(cl-defstruct (hermes-pending (:copier hermes-pending-copy))
  kind        ; 'approval | 'clarify | 'secret | 'sudo
  request-id payload)

(cl-defstruct (hermes-state (:copier hermes-state-copy))
  connection         ; 'disconnected | 'connecting | 'connected
  session-id
  session-info       ; hash-table or nil
  usage              ; hash-table or nil — accumulated tokens/cost
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

(defvar hermes--segment-counter 0
  "Monotonic counter for segment IDs.")

(defun hermes--next-segment-id ()
  "Return a fresh segment ID string."
  (format "seg-%d" (cl-incf hermes--segment-counter)))

;;;; Segment helpers

(defun hermes--last-segment (stream)
  "Return the last segment in STREAM, or nil."
  (let ((segs (hermes-stream-segments stream)))
    (when (> (length segs) 0)
      (aref segs (1- (length segs))))))

(defun hermes--append-segment (stream seg)
  "Return a new stream with SEG appended to segments."
  (hermes--with-copy stream hermes-stream-copy s
    (setf (hermes-stream-segments s)
          (hermes--vector-append (hermes-stream-segments stream) seg))))

(defun hermes--update-last-segment (stream updater)
  "Return a new stream with the last segment replaced by (UPDATER last-seg)."
  (let* ((segs (hermes-stream-segments stream))
         (n (length segs)))
    (if (= n 0)
        stream
      (let* ((last-idx (1- n))
             (old-seg (aref segs last-idx))
             (new-seg (funcall updater old-seg))
             (new-segs (copy-sequence segs)))
        (aset new-segs last-idx new-seg)
        (hermes--with-copy stream hermes-stream-copy s
          (setf (hermes-stream-segments s) new-segs))))))

(defun hermes--find-tool-segment-index (segments tool-id)
  "Return index of tool segment with matching TOOL-ID, or nil."
  (cl-position-if
   (lambda (seg)
     (and (eq 'tool (hermes-segment-type seg))
          (let ((tool (hermes-segment-content seg)))
            (and (hermes-tool-p tool)
                 (equal tool-id (hermes-tool-id tool))))))
   segments))

(defun hermes--find-subagent (subagents id)
  "Return index of subagent with matching ID in SUBAGENTS vector, or nil."
  (cl-position-if
   (lambda (sa)
     (and (hermes-subagent-p sa)
          (equal id (hermes-subagent-id sa))))
   subagents))

(defun hermes--segments-derive-deprecated (segments)
  "Derive deprecated slots from SEGMENTS.
Returns a plist with :text :thinking :reasoning :tools."
  (let (text-parts thinking-parts reasoning-parts tools-vec)
    (dotimes (i (length segments))
      (let ((seg (aref segments i)))
        (pcase (hermes-segment-type seg)
          ('text (push (hermes-segment-content seg) text-parts))
          ('thinking (push (hermes-segment-content seg) thinking-parts))
          ('reasoning (push (hermes-segment-content seg) reasoning-parts))
          ('tool (push (hermes-segment-content seg) tools-vec)))))
    (list :text (apply #'concat (nreverse text-parts))
          :thinking (apply #'concat (nreverse thinking-parts))
          :reasoning (apply #'concat (nreverse reasoning-parts))
          :tools (vconcat (nreverse tools-vec)))))

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
      ;; --- Internal actions ----------------------------------------------
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
       (let ((text (plist-get p :text)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message :kind 'user
                                       :text text
                                       :timestamp (current-time)))
                 (hermes-state-history s)
                 (let ((h (cons text (hermes-state-history state))))
                   (if (> (length h) hermes-history-max)
                       (cl-subseq h 0 hermes-history-max)
                     h))))))
      (:enqueue
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-queue s)
               (append (hermes-state-queue state)
                       (list (plist-get p :text))))))
      (:dequeue
       (let ((q (hermes-state-queue state)))
         (if (null q)
             state
           (hermes--with-copy state hermes-state-copy s
             (setf (hermes-state-queue s) (cdr q))))))
      (:slash-catalog
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-slash-catalog s) (plist-get p :catalog))))
      ;; --- Gateway lifecycle ---------------------------------------------
      ("gateway.ready"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-connection s) 'connected
               (hermes-state-skin s) (or (hermes--get p "skin") p))))
      ("skin.changed"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-skin s) p)))
      ("session.info"
       (hermes--with-copy state hermes-state-copy s
         (when (hash-table-p p)
           (let ((sid (hermes--get p "session_id"))
                 (merged (or (hermes-state-session-info state)
                             (make-hash-table :test 'equal)))
                 (usage-payload (hermes--get p "usage")))
             (maphash (lambda (k v) (puthash k v merged)) p)
             (setf (hermes-state-session-info s) merged)
             (when sid (setf (hermes-state-session-id s) sid))
             (when usage-payload
               (let ((u (or (hermes-state-usage state)
                            (make-hash-table :test 'equal))))
                 (cond
                  ((hash-table-p usage-payload)
                   (maphash (lambda (k v) (puthash k v u)) usage-payload))
                  ((listp usage-payload)
                   (dolist (kv usage-payload)
                     (when (consp kv)
                       (puthash (car kv) (cdr kv) u)))))
                 (setf (hermes-state-usage s) u)))))))
      ;; --- Message stream ------------------------------------------------
      ("message.start"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-stream s)
               (make-hermes-stream :segments [] :tools []))))
      ("message.delta"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (chunk (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (if (and last (eq 'text (hermes-segment-type last)))
                     (hermes--update-last-segment old-stream
                       (lambda (seg)
                         (hermes--with-copy seg hermes-segment-copy ns
                           (setf (hermes-segment-content ns)
                                 (concat (hermes-segment-content seg) chunk)))))
                   (hermes--append-segment old-stream
                     (make-hermes-segment :type 'text :content chunk
                                          :id (hermes--next-segment-id))))))))
      ("thinking.delta"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (chunk (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (if (and last (eq 'thinking (hermes-segment-type last)))
                     (hermes--update-last-segment old-stream
                       (lambda (seg)
                         (hermes--with-copy seg hermes-segment-copy ns
                           (setf (hermes-segment-content ns)
                                 (concat (hermes-segment-content seg) chunk)))))
                   (hermes--append-segment old-stream
                     (make-hermes-segment :type 'thinking :content chunk
                                          :id (hermes--next-segment-id))))))))
      ("reasoning.available"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (text (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (if (and last (eq 'reasoning (hermes-segment-type last)))
                     (hermes--update-last-segment old-stream
                       (lambda (seg)
                         (hermes--with-copy seg hermes-segment-copy ns
                           (setf (hermes-segment-content ns) text))))
                   (hermes--append-segment old-stream
                     (make-hermes-segment :type 'reasoning :content text
                                          :id (hermes--next-segment-id))))))))
      ("reasoning.delta"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (chunk (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-stream s)
                 (if (and last (eq 'reasoning (hermes-segment-type last)))
                     (hermes--update-last-segment old-stream
                       (lambda (seg)
                         (hermes--with-copy seg hermes-segment-copy ns
                           (setf (hermes-segment-content ns)
                                 (concat (hermes-segment-content seg) chunk)))))
                   (hermes--append-segment old-stream
                     (make-hermes-segment :type 'reasoning :content chunk
                                          :id (hermes--next-segment-id))))))))
      ("message.complete"
       (let ((str (hermes-state-stream state)))
         (if (null str)
             state
           (let* ((sent (hermes--get p "tokens_sent"))
                  (received (hermes--get p "tokens_received"))
                  (msg-usage (make-hash-table :test 'equal))
                  (segs (hermes-stream-segments str))
                  (deprecated (hermes--segments-derive-deprecated segs))
                   (msg (make-hermes-message
                         :kind 'assistant
                         :segments segs
                         :text (plist-get deprecated :text)
                         :thinking (plist-get deprecated :thinking)
                         :reasoning (plist-get deprecated :reasoning)
                         :tools (plist-get deprecated :tools)
                         :subagents (or (hermes-stream-subagents str) [])
                         :usage msg-usage
                         :timestamp (current-time)))
                  (acc-usage (or (hermes-state-usage state)
                                 (make-hash-table :test 'equal))))
             (when sent
               (puthash "tokens_sent" (+ (or (gethash "tokens_sent" acc-usage) 0) sent)
                        acc-usage))
             (when received
               (puthash "tokens_received" (+ (or (gethash "tokens_received" acc-usage) 0)
                                             received)
                        acc-usage))
              (hermes--with-copy state hermes-state-copy s
                (setf (hermes-state-messages s)
                      (hermes--vector-append (hermes-state-messages state) msg)
                      (hermes-state-usage s) acc-usage
                      (hermes-state-stream s) nil))))))
       ;; --- Subagents -----------------------------------------------------
       ("subagent.spawn_requested"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (goal (hermes--get p "goal")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if idx
                  state
                (let ((sa (make-hermes-subagent :id sid :goal goal
                                                :status 'queued
                                                :tools [] :notes [])))
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns)
                                  (hermes--vector-append subagents sa)))))))))))
       ("subagent.start"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (goal (hermes--get p "goal")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if idx
                  (let* ((old-sa (aref subagents idx))
                         (new-sa (hermes--with-copy old-sa hermes-subagent-copy sa
                                   (setf (hermes-subagent-status sa) 'running
                                         (hermes-subagent-goal sa) (or goal ""))))
                         (new-sas (copy-sequence subagents)))
                    (aset new-sas idx new-sa)
                    (hermes--with-copy state hermes-state-copy s
                      (setf (hermes-state-stream s)
                            (hermes--with-copy str hermes-stream-copy ns
                              (setf (hermes-stream-subagents ns) new-sas)))))
                (let ((sa (make-hermes-subagent :id sid :goal (or goal "")
                                                :status 'running
                                                :tools [] :notes [])))
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns)
                                  (hermes--vector-append subagents sa)))))))))))
       ("subagent.thinking"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (text (or (hermes--get p "text") "")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if (null idx)
                  state
                (let* ((old-sa (aref subagents idx))
                       (new-sa (hermes--with-copy old-sa hermes-subagent-copy sa
                                 (setf (hermes-subagent-thinking sa)
                                       (concat (hermes-subagent-thinking old-sa) text))))
                       (new-sas (copy-sequence subagents)))
                  (aset new-sas idx new-sa)
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns) new-sas))))))))))
       ("subagent.tool"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (tname (hermes--get p "tool_name"))
              (args (hermes--get p "args")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if (null idx)
                  state
                (let* ((old-sa (aref subagents idx))
                       (new-tool (list :name tname :args args
                                      :timestamp (current-time)))
                       (new-sa (hermes--with-copy old-sa hermes-subagent-copy sa
                                 (setf (hermes-subagent-tools sa)
                                       (hermes--vector-append
                                        (hermes-subagent-tools old-sa) new-tool))))
                       (new-sas (copy-sequence subagents)))
                  (aset new-sas idx new-sa)
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns) new-sas))))))))))
       ("subagent.progress"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (note (hermes--get p "note")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if (null idx)
                  state
                (let* ((old-sa (aref subagents idx))
                       (new-sa (hermes--with-copy old-sa hermes-subagent-copy sa
                                 (setf (hermes-subagent-notes sa)
                                       (hermes--vector-append
                                        (hermes-subagent-notes old-sa) note))))
                       (new-sas (copy-sequence subagents)))
                  (aset new-sas idx new-sa)
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns) new-sas))))))))))
       ("subagent.complete"
        (let ((str (hermes-state-stream state))
              (sid (hermes--get p "subagent_id"))
              (status (hermes--get p "status"))
              (summary (hermes--get p "summary"))
              (dur (hermes--get p "duration_s")))
          (if (or (null str) (null sid))
              state
            (let* ((subagents (or (hermes-stream-subagents str) []))
                   (idx (hermes--find-subagent subagents sid)))
              (if (null idx)
                  state
                (let* ((old-sa (aref subagents idx))
                       (status-kw (cond ((equal status "error") 'error)
                                        ((equal status "complete") 'complete)
                                        (t (or status 'complete))))
                       (new-sa (hermes--with-copy old-sa hermes-subagent-copy sa
                                 (setf (hermes-subagent-status sa) status-kw
                                       (hermes-subagent-summary sa) summary
                                       (hermes-subagent-duration sa) dur)))
                       (new-sas (copy-sequence subagents)))
                  (aset new-sas idx new-sa)
                  (hermes--with-copy state hermes-state-copy s
                    (setf (hermes-state-stream s)
                          (hermes--with-copy str hermes-stream-copy ns
                            (setf (hermes-stream-subagents ns) new-sas))))))))))
       ;; --- Tools ---------------------------------------------------------
      ("tool.generating"
       (let ((str (hermes-state-stream state))
             (tid (or (hermes--get p "tool_id")
                      (hermes--get p "id")
                      (hermes--get p "name")))
             (tname (hermes--get p "name")))
         (if (or (null str) (null tid))
             state
           (let* ((segs (hermes-stream-segments str))
                  (already (hermes--find-tool-segment-index segs tid)))
             (if already
                 state
               (let ((tool (make-hermes-tool :id tid :name tname
                                             :status 'generating)))
                 (hermes--with-copy state hermes-state-copy s
                   (setf (hermes-state-stream s)
                         (hermes--append-segment str
                           (make-hermes-segment :type 'tool :content tool
                                                :id (hermes--next-segment-id)))))))))))
      ("tool.start"
       (let ((str (hermes-state-stream state))
             (tid (hermes--get p "tool_id"))
             (ctx (hermes--get p "context")))
         (if (or (null str) (null tid))
             state
           (let* ((segs (hermes-stream-segments str))
                  (idx (hermes--find-tool-segment-index segs tid)))
             (if (null idx)
                 state
               (let* ((old-seg (aref segs idx))
                      (old-tool (hermes-segment-content old-seg))
                      (new-tool (hermes--with-copy old-tool hermes-tool-copy nt
                                 (setf (hermes-tool-status nt) 'running
                                       (hermes-tool-context nt) ctx)))
                      (new-seg (hermes--with-copy old-seg hermes-segment-copy ns
                                (setf (hermes-segment-content ns) new-tool)))
                      (new-segs (copy-sequence segs)))
                 (aset new-segs idx new-seg)
                 (hermes--with-copy state hermes-state-copy s
                   (setf (hermes-state-stream s)
                         (hermes--with-copy str hermes-stream-copy ns
                           (setf (hermes-stream-segments ns) new-segs))))))))))
      ("tool.progress"
       (let ((str (hermes-state-stream state))
             (tid (hermes--get p "tool_id"))
             (preview (hermes--get p "preview")))
         (if (or (null str) (null tid))
             state
           (let* ((segs (hermes-stream-segments str))
                  (idx (hermes--find-tool-segment-index segs tid)))
             (if (null idx)
                 state
               (let* ((old-seg (aref segs idx))
                      (old-tool (hermes-segment-content old-seg))
                      (new-tool (hermes--with-copy old-tool hermes-tool-copy nt
                                  (setf (hermes-tool-preview nt) preview)))
                      (new-seg (hermes--with-copy old-seg hermes-segment-copy ns
                                 (setf (hermes-segment-content ns) new-tool)))
                      (new-segs (copy-sequence segs)))
                 (aset new-segs idx new-seg)
                 (hermes--with-copy state hermes-state-copy s
                   (setf (hermes-state-stream s)
                         (hermes--with-copy str hermes-stream-copy ns
                           (setf (hermes-stream-segments ns) new-segs))))))))))
      ("tool.complete"
       (let* ((str (hermes-state-stream state))
              (tid (or (hermes--get p "tool_id")
                       (hermes--get p "id")
                       (hermes--get p "name")
                       (and str
                            (let ((segs (hermes-stream-segments str)))
                              (and (> (length segs) 0)
                                   (let ((last-seg (aref segs (1- (length segs)))))
                                     (and (eq 'tool (hermes-segment-type last-seg))
                                          (hermes-tool-id (hermes-segment-content last-seg)))))))))
              (inline-diff (hermes--get p "inline_diff"))
              (todos-raw (hermes--get p "todos"))
              (output (hermes--get p "output"))
              (err    (hermes--get p "error"))
              (dur    (hermes--get p "duration_s")))
         (if (or (null str) (null tid))
             state
           (let* ((segs (hermes-stream-segments str))
                  (tname (hermes--get p "name"))
                  (idx (cl-position-if
                        (lambda (seg)
                          (and (eq 'tool (hermes-segment-type seg))
                               (let ((tl (hermes-segment-content seg)))
                                 (or (equal tid (hermes-tool-id tl))
                                     (and tname (equal tname (hermes-tool-name tl)))))))
                        segs)))
             (if (null idx)
                 state
               (let* ((old-seg (aref segs idx))
                      (old-tool (hermes-segment-content old-seg))
                      (new-tool (hermes--with-copy old-tool hermes-tool-copy nt
                                 (setf (hermes-tool-status nt)
                                       (if err 'error 'complete)
                                       (hermes-tool-output nt) output
                                       (hermes-tool-error nt) err
                                       (hermes-tool-duration nt) dur
                                       (hermes-tool-inline-diff nt) inline-diff
                                       (hermes-tool-todos nt) todos-raw)))
                      (new-seg (hermes--with-copy old-seg hermes-segment-copy ns
                                (setf (hermes-segment-content ns) new-tool)))
                      (new-segs (copy-sequence segs)))
                 (aset new-segs idx new-seg)
                 (hermes--with-copy state hermes-state-copy s
                   (setf (hermes-state-stream s)
                         (hermes--with-copy str hermes-stream-copy ns
                           (setf (hermes-stream-segments ns) new-segs))))))))))
      ;; --- Blocking prompts ----------------------------------------------
      ("approval.request"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-pending s)
               (make-hermes-pending :kind 'approval
                                    :request-id (hermes--get p "request_id")
                                    :payload p))))
      ("clarify.request"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-pending s)
               (make-hermes-pending :kind 'clarify
                                    :request-id (hermes--get p "request_id")
                                    :payload p))))
      ("sudo.request"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-pending s)
               (make-hermes-pending :kind 'sudo
                                    :request-id (hermes--get p "request_id")
                                    :payload p))))
      ("secret.request"
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-pending s)
               (make-hermes-pending :kind 'secret
                                    :request-id (hermes--get p "request_id")
                                    :payload p))))
      (:system-message
       (let ((text (plist-get p :text)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message :kind 'system :text text
                                       :timestamp (current-time)))))))
      (:pending-clear
       (if (hermes-state-pending state)
           (hermes--with-copy state hermes-state-copy s
             (setf (hermes-state-pending s) nil))
         state))
      ;; --- Errors --------------------------------------------------------
      ("error"
       (let ((text (ansi-color-apply
                    (or (hermes--get p "message") "(unknown error)")))
             (str (hermes-state-stream state)))
         (if (null str)
             (hermes--with-copy state hermes-state-copy s
               (setf (hermes-state-messages s)
                     (hermes--vector-append
                      (hermes-state-messages state)
                      (make-hermes-message :kind 'system :text text
                                           :timestamp (current-time)))))
           (let* ((segs (hermes-stream-segments str))
                  (deprecated (hermes--segments-derive-deprecated segs))
                   (msg (make-hermes-message
                         :kind 'assistant
                         :segments segs
                         :text (plist-get deprecated :text)
                         :thinking (plist-get deprecated :thinking)
                         :reasoning (plist-get deprecated :reasoning)
                         :tools (plist-get deprecated :tools)
                         :subagents (or (hermes-stream-subagents str) [])
                         :usage nil
                         :timestamp (current-time))))
             (hermes--with-copy state hermes-state-copy s
               (setf (hermes-state-messages s)
                     (hermes--vector-append
                      (hermes--vector-append (hermes-state-messages state) msg)
                      (make-hermes-message :kind 'system :text text
                                           :timestamp (current-time)))
                     (hermes-state-stream s) nil))))))
      ;; --- Gateway diagnostics -------------------------------------------
      ("gateway.stderr"
       (let ((line (hermes--get p "line")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message
                   :kind 'system
                   :text (format "[stderr] %s"
                                 (substring line 0 (min 120 (length line))))
                   :timestamp (current-time)))))))
      ("gateway.protocol_error"
       (let ((preview (hermes--get p "preview")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message
                   :kind 'system
                   :text (format "[protocol noise] %s" preview)
                   :timestamp (current-time)))))))
      ("gateway.start_timeout"
       (let ((lines (hermes--get p "lines")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message
                   :kind 'system
                   :text (concat "[gateway start timeout]\n"
                                 (mapconcat (lambda (l) (format "  %s" l))
                                            lines "\n"))
                   :timestamp (current-time)))))))
      ;; --- Background / review -------------------------------------------
      ("background.complete"
       (let ((tid (hermes--get p "task_id"))
             (text (hermes--get p "text")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message
                   :kind 'system
                   :text (format "[bg %s] %s" (or tid "?") (or text ""))
                   :timestamp (current-time)))))))
      ("review.summary"
       (let ((text (hermes--get p "text")))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-messages s)
                 (hermes--vector-append
                  (hermes-state-messages state)
                  (make-hermes-message
                   :kind 'system
                   :text (format "[review] %s" (or text ""))
                   :timestamp (current-time)))))))
      ;; --- Pass-through --------------------------------------------------
      (_ state))))

;;;; UI reducer (minimal for M2)

(defun hermes--ui-reduce (state msg)
  "Pure: produce a new `hermes-ui-state' from STATE and MSG."
  (unless state (setq state (make-hermes-ui-state)))
  (let ((type (car msg))
        (p    (cdr msg)))
    (pcase type
      ;; Debug payload: ("kind" . "thinking") ("text" . "pondering...")
      ("status.update"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) (hermes--get p "text")
               (hermes-ui-state-status-kind s) (hermes--get p "kind"))))
      ("message.start"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) "Responding…")))
      ("message.complete"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) nil
               (hermes-ui-state-tool-previews s) nil)))
       ("tool.generating"
        (let ((name (hermes--get p "name")))
          (hermes--with-copy state hermes-ui-state-copy s
            (setf (hermes-ui-state-status-text s)
                  (format "Running %s…" (or name "tool"))))))
       ("tool.start"
        (let ((name (hermes--get p "name")))
          (hermes--with-copy state hermes-ui-state-copy s
            (setf (hermes-ui-state-status-text s)
                  (format "Running %s…" (or name "tool"))))))
       ("tool.progress"
        (let ((tid (hermes--get p "tool_id"))
              (preview (hermes--get p "preview")))
          (if (null tid)
              state
            (hermes--with-copy state hermes-ui-state-copy s
              (setf (hermes-ui-state-tool-previews s)
                    (cons (cons tid preview)
                          (assoc-delete-all
                           tid (hermes-ui-state-tool-previews state))))))))
        ("tool.complete"
         (let ((tid (hermes--get p "tool_id")))
           (if (null tid)
               state
             (hermes--with-copy state hermes-ui-state-copy s
               (setf (hermes-ui-state-tool-previews s)
                     (assoc-delete-all
                      tid (hermes-ui-state-tool-previews state)))))))
        ("subagent.start"
         (let ((goal (hermes--get p "goal")))
           (hermes--with-copy state hermes-ui-state-copy s
             (setf (hermes-ui-state-status-text s)
                   (format "Delegating to %s…"
                           (if goal
                               (truncate-string-to-width goal 40 nil nil t)
                             "subagent"))))))
        ("subagent.complete"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s) nil)))
         ("error"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s) nil
                 (hermes-ui-state-tool-previews s) nil)))
        ("gateway.start_timeout"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s)
                 "Gateway failed to start (see chat buffer)")))
        ("gateway.protocol_error"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s)
                 "Protocol noise from gateway (see chat buffer)")))
        (_ state))))

(provide 'hermes-state)
;;; hermes-state.el ends here
