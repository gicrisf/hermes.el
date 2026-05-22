;;; hermes-state.el --- TEA-style state + reducer for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Two buffer-local atoms per session: `hermes--state' (ephemeral; the
;; canonical history lives in the Org buffer) and `hermes--ui-state'
;; (ephemeral).  Mutations go through `hermes-dispatch' /
;; `hermes-ui-dispatch', which call a pure reducer and swap the var
;; atomically, then run a change hook for the renderer to subscribe to.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)

(defcustom hermes-history-max 200
  "Maximum number of past inputs retained in `hermes-state-history'."
  :type 'integer :group 'hermes)

(defcustom hermes-log-max-lines 1000
  "Maximum number of lines retained in the *hermes-log* buffer."
  :type 'integer :group 'hermes)

;;;; Diagnostic log buffer

(defun hermes--log-buffer ()
  "Return (creating if needed) the *hermes-log* buffer."
  (or (get-buffer "*hermes-log*")
      (with-current-buffer (get-buffer-create "*hermes-log*")
        (special-mode)
        (setq-local truncate-lines nil)
        (current-buffer))))

(defun hermes--log-write (fmt &rest args)
  "Append a timestamped line to *hermes-log*, capped at `hermes-log-max-lines'."
  (let ((line (apply #'format fmt args))
        (ts (format-time-string "%H:%M:%S")))
    (with-current-buffer (hermes--log-buffer)
      (let ((inhibit-read-only t)
            (was-at-tail (= (point) (point-max))))
        (save-excursion
          (goto-char (point-max))
          (insert (format "[%s] %s\n" ts line))
          ;; Cap: drop oldest lines if we exceed the limit.
          (let ((excess (- (count-lines (point-min) (point-max))
                           hermes-log-max-lines)))
            (when (> excess 0)
              (goto-char (point-min))
              (forward-line excess)
              (delete-region (point-min) (point)))))
        (when was-at-tail
          (goto-char (point-max))
          (dolist (w (get-buffer-window-list (current-buffer) nil t))
            (set-window-point w (point-max))))))))

;;;; Structs

(cl-defstruct (hermes-segment (:copier hermes-segment-copy))
  type        ; 'text | 'reasoning | 'tool | 'system | 'image
  content     ; string for text/reasoning/system; hermes-tool for tool; image plist for image
  id)         ; unique segment id (for stable updates)

(cl-defstruct (hermes-tool (:copier hermes-tool-copy))
  id name
  status      ; 'generating | 'running | 'complete | 'error
  context     ; tool args preview from tool.start
  preview     ; live preview from tool.progress
  inline-diff ; diff output from tool.complete
  todos       ; list of hash-tables with "content" "status" "id" — from
              ; tool.complete (and defensively tool.start/tool.progress
              ; when the gateway forwards them earlier)
  output      ; string or nil (raw tool result text — rarely populated)
  summary     ; string or nil (human summary from gateway, e.g. "Did 3 searches")
  error duration)

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
  stream             ; hermes-stream or nil (in-flight only)
  pending            ; hermes-pending or nil
  (pending-turns []) ; vector of hermes-message structs awaiting buffer insert
  slash-catalog
  (queue nil)
  (history nil)
  skin
  busy-mode          ; string from gateway `busy' config: "queue" | "steer" | "interrupt" | nil
  (cwd nil)          ; string or nil — detected project root (local tracking only;
                     ; gateway-side cwd is process-global, set at session.create)
  (attachments nil)  ; list of plists (:attach-id :path :name :width :height :token-estimate :status)
                     ; client-side MIRROR of gateway's session["attached_images"] — never authoritative.
                     ; :attach-id is a client-generated identifier used to match RPC callbacks back to
                     ; their optimistic placeholder entry.  :status is 'pending | 'attached | 'error.
  (bg-tasks [])      ; vector of hermes-bg-task — background prompt tasks for this session
  (parent-sid nil))  ; string or nil — sid of the session this one was branched from
                     ; (set from `session.branch' response; informational only).

(cl-defstruct (hermes-bg-task (:copier hermes-bg-task-copy))
  task-id          ; string — gateway-assigned task id
  prompt           ; string — original user prompt (sans /bg prefix)
  status           ; symbol: 'running | 'complete | 'error
  buffer-name      ; string or nil — name of the rendered *hermes-bg:…* buffer
  result           ; string or nil — final response text
  error            ; string or nil — error message
  created-at       ; string — ISO-8601 timestamp
  completed-at)    ; string or nil — ISO-8601 timestamp

;;;; Ephemeral UI state — never persisted to the buffer

(cl-defstruct (hermes-ui-state (:copier hermes-ui-state-copy))
  status-text status-kind
  spinner-frame
  (tool-previews nil)   ; alist tool-id → preview string
  thinking-text)        ; accumulated thinking.delta text for current turn

;;;; Atoms and dispatchers

(defvar-local hermes--state nil
  "Current persistent state (a `hermes-state').
In a multi-session buffer this mirrors the most recently dispatched
session's slot in `hermes--buffer-sessions' — kept in sync so older
code reading `hermes--state' directly still sees coherent values
during the slice-B transition.")

(defvar-local hermes--ui-state nil
  "Current ephemeral UI state (a `hermes-ui-state').")

(defvar hermes--current-session-id nil
  "Session id of the dispatch currently in progress, or nil.
Dynamically bound around `hermes-dispatch' / `hermes-ui-dispatch'
calls by the event router.  Hook handlers consult it to discover
which session a change applies to.")

(defvar hermes-state-change-hook nil
  "Hook of (OLD NEW) called after `hermes--state' is swapped.
Both arguments are `hermes-state' structs; OLD may be nil at init.
The active session id is available via `hermes--current-session-id'.")

(defvar hermes-ui-state-change-hook nil
  "Hook of (OLD NEW) called after `hermes--ui-state' is swapped.")

(defun hermes-state-init ()
  "Initialise the buffer-local atoms.  Safe to call on an existing buffer."
  (unless hermes--state
    (setq hermes--state (make-hermes-state :connection 'disconnected)))
  (unless hermes--ui-state
    (setq hermes--ui-state (make-hermes-ui-state))))

(defun hermes--state-slot-read (session-id)
  "Return the persistent state for SESSION-ID, or `hermes--state' as fallback.
Resolves to the per-session registry entry when SESSION-ID is non-nil
and `hermes--buffer-sessions' carries a struct for it; otherwise
hands back the buffer-local `hermes--state'."
  (or (and session-id
           (boundp 'hermes--buffer-sessions)
           (hash-table-p hermes--buffer-sessions)
           (gethash session-id hermes--buffer-sessions))
      hermes--state))

(defun hermes--state-slot-write (session-id new-state)
  "Persist NEW-STATE under SESSION-ID and mirror to `hermes--state'.
When SESSION-ID is non-nil and present in `hermes--buffer-sessions',
that entry is replaced.  The buffer-local `hermes--state' is always
updated.  Additionally, if NEW-STATE carries a session-id that differs
from SESSION-ID, the registry entry for that active session is also
updated — this prevents stale data when global events (e.g.
`gateway.ready') update `hermes--state' without touching the registry."
  (when (and session-id
             (boundp 'hermes--buffer-sessions)
             (hash-table-p hermes--buffer-sessions)
             (gethash session-id hermes--buffer-sessions))
    (puthash session-id new-state hermes--buffer-sessions))
  (let ((active-sid (and new-state (hermes-state-session-id new-state))))
    (when (and active-sid
               (not (equal active-sid session-id))
               (boundp 'hermes--buffer-sessions)
               (hash-table-p hermes--buffer-sessions)
               (gethash active-sid hermes--buffer-sessions))
      (puthash active-sid new-state hermes--buffer-sessions)))
  (setq hermes--state new-state))

(defun hermes-dispatch (msg &optional session-id)
  "Reduce MSG into the persistent state and notify subscribers.
If SESSION-ID is provided and present in `hermes--buffer-sessions',
the reduction targets that session's slot; otherwise it targets the
buffer-local `hermes--state'.  `hermes--current-session-id' is bound
to SESSION-ID for the duration so hook handlers can see which
session changed."
  (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
         (old (hermes--state-slot-read hermes--current-session-id))
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (hermes--state-slot-write hermes--current-session-id new)
      (run-hook-with-args 'hermes-state-change-hook old new))))

(defun hermes-ui-dispatch (msg &optional session-id)
  "Reduce MSG into the ephemeral state and notify subscribers.
SESSION-ID is accepted for symmetry with `hermes-dispatch' and bound
into `hermes--current-session-id' for the hook run; the ephemeral
state itself remains buffer-local in slice B."
  (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
         (old hermes--ui-state)
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

(defun hermes--strip-ansi (string)
  "Remove ANSI escape sequences from STRING.
Returns nil for nil input, the filtered string otherwise.
Empty strings are preserved as empty strings."
  (and string (ansi-color-filter-apply string)))

(defun hermes--slug-for-name (id)
  "Sanitize ID into a single token safe for use as an Org #+name value.
Replaces any character outside [A-Za-z0-9_-] with `-'.  Returns nil for
nil input.  Used to derive collision-resistant block names from tool IDs
when emitting body-canonical fields (see `hermes--extract-named-block')."
  (and id (replace-regexp-in-string "[^A-Za-z0-9_-]" "-" id)))

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

(defun hermes--normalize-for-dedup (s)
  "Collapse all runs of whitespace in S to single spaces and trim.
Used so dedup ignores cosmetic whitespace differences (tab vs space,
`\\n\\n' vs two spaces, leading/trailing padding)."
  (replace-regexp-in-string "[ \t\n\r]+" " " (string-trim (or s ""))))

(defun hermes--reasoning-duplicate-p (chunk stream)
  "Return t if CHUNK duplicates the most recent text/reasoning segment in STREAM.
Gateways occasionally emit a `reasoning.delta' whose payload is identical
or a truncated prefix of the response text — likely a model echo.  Tool
segments between the echo and the original text are skipped, so a tool
call interleaved between the assistant's response and the echo doesn't
defeat dedup.  Comparison is whitespace-normalized and uses prefix
containment so truncated echoes are caught."
  (let* ((segs (and stream (hermes-stream-segments stream)))
         (norm-chunk (hermes--normalize-for-dedup chunk))
         (target nil))
    (when segs
      (let ((i (1- (length segs))))
        (while (and (>= i 0) (not target))
          (let ((seg (aref segs i)))
            (when (memq (hermes-segment-type seg) '(text reasoning))
              (setq target seg)))
          (setq i (1- i)))))
    (when target
      (let ((norm-target (hermes--normalize-for-dedup
                          (hermes-segment-content target))))
        (or (string-prefix-p norm-target norm-chunk)
            (string-prefix-p norm-chunk norm-target))))))

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

;;;; Pending-turns helper

(defun hermes--push-pending (state msg)
  "Return a new STATE with MSG pushed onto `pending-turns'."
  (hermes--with-copy state hermes-state-copy s
    (setf (hermes-state-pending-turns s)
          (hermes--vector-append (hermes-state-pending-turns state) msg))))

;;;; Serialization — struct ↔ plist

(defun hermes--hash-to-plist (h)
  "Convert hash-table H to a flat plist with keyword keys."
  (let (acc)
    (maphash
     (lambda (k v)
       (let ((kw (cond ((keywordp k) k)
                       ((symbolp k) (intern (concat ":" (symbol-name k))))
                       ((stringp k) (intern (concat ":" k)))
                       (t (intern (format ":%s" k))))))
         (push (hermes--to-plist v) acc)
         (push kw acc)))
     h)
    acc))

(defun hermes--to-plist (val)
  "Walk VAL: structs → plists, hash-tables → plists, vectors/lists element-wise."
  (cond
   ((null val) nil)
   ((hermes-segment-p val) (hermes--segment-to-plist val))
   ((hermes-tool-p val) (hermes--tool-to-plist val))
   ((hermes-subagent-p val) (hermes--subagent-to-plist val))
   ((hermes-message-p val) (hermes--message-to-plist val))
   ((hash-table-p val) (hermes--hash-to-plist val))
   ((vectorp val) (apply #'vector (mapcar #'hermes--to-plist (append val nil))))
   ((and (consp val) (not (consp (cdr val))))
    ;; cons cell
    (cons (hermes--to-plist (car val)) (hermes--to-plist (cdr val))))
   ((listp val) (mapcar #'hermes--to-plist val))
   (t val)))

(defun hermes--tool-to-plist (tool)
  "Serialize a `hermes-tool' TOOL to a plist."
  (list :id (hermes-tool-id tool)
        :name (hermes-tool-name tool)
        :status (hermes-tool-status tool)
        :context (hermes-tool-context tool)
        :preview (hermes-tool-preview tool)
        :inline-diff (hermes-tool-inline-diff tool)
        :todos (hermes--to-plist (hermes-tool-todos tool))
        :output (hermes-tool-output tool)
        :summary (hermes-tool-summary tool)
        :error (hermes-tool-error tool)
        :duration (hermes-tool-duration tool)))

(defun hermes--plist-to-tool (p)
  "Reconstruct a `hermes-tool' from plist P."
  (make-hermes-tool
   :id (plist-get p :id)
   :name (plist-get p :name)
   :status (plist-get p :status)
   :context (plist-get p :context)
   :preview (plist-get p :preview)
   :inline-diff (plist-get p :inline-diff)
   :todos (plist-get p :todos)
   :output (plist-get p :output)
   :summary (plist-get p :summary)
   :error (plist-get p :error)
   :duration (plist-get p :duration)))

(defun hermes--segment-to-plist (seg)
  "Serialize a `hermes-segment' SEG to a plist."
  (let ((type (hermes-segment-type seg))
        (content (hermes-segment-content seg)))
    (list :type type
          :content (cond
                    ((eq type 'tool)
                     (and (hermes-tool-p content)
                          (hermes--tool-to-plist content)))
                    ((eq type 'image)
                     ;; Persist only the small, file-system-derivable fields.
                     ;; No base64 payload, no token estimate (model-specific).
                     (list :path  (plist-get content :path)
                           :name  (plist-get content :name)
                           :width (plist-get content :width)
                           :height (plist-get content :height)))
                    (t content))
          :id (hermes-segment-id seg))))

(defun hermes--plist-to-segment (p)
  "Reconstruct a `hermes-segment' from plist P."
  (let* ((type (plist-get p :type))
         (raw (plist-get p :content))
         (content (cond
                   ((and (eq type 'tool) (listp raw) raw)
                    (hermes--plist-to-tool raw))
                   ((eq type 'image)
                    ;; Image content stays a plist — no struct wrapper.
                    ;; A nil :path means the referenced file is gone; the
                    ;; renderer shows a placeholder in that case.
                    raw)
                   (t raw))))
    (make-hermes-segment :type type :content content :id (plist-get p :id))))

(defun hermes--subagent-to-plist (sa)
  "Serialize a `hermes-subagent' SA to a plist."
  (list :id (hermes-subagent-id sa)
        :goal (hermes-subagent-goal sa)
        :status (hermes-subagent-status sa)
        :thinking (hermes-subagent-thinking sa)
        :tools (hermes--to-plist (hermes-subagent-tools sa))
        :notes (hermes-subagent-notes sa)
        :summary (hermes-subagent-summary sa)
        :duration (hermes-subagent-duration sa)))

(defun hermes--plist-to-subagent (p)
  "Reconstruct a `hermes-subagent' from plist P."
  (make-hermes-subagent
   :id (plist-get p :id)
   :goal (plist-get p :goal)
   :status (plist-get p :status)
   :thinking (plist-get p :thinking)
   :tools (or (plist-get p :tools) [])
   :notes (or (plist-get p :notes) [])
   :summary (plist-get p :summary)
   :duration (plist-get p :duration)))

(defun hermes--message-text (msg)
  "Concatenate the text-segment content of MSG into a single string."
  (let ((segs (hermes-message-segments msg))
        parts)
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let ((s (aref segs i)))
          (when (eq 'text (hermes-segment-type s))
            (push (or (hermes-segment-content s) "") parts)))))
    (apply #'concat (nreverse parts))))

(defun hermes--message-to-plist (msg)
  "Serialize a `hermes-message' MSG to a printable plist.
Handles nested `hermes-segment', `hermes-tool', `hermes-subagent', and
hash-tables (usage)."
  (let* ((segs (or (hermes-message-segments msg) []))
         (seg-plists (apply #'vector
                            (mapcar #'hermes--segment-to-plist
                                    (append segs nil))))
         (sas (or (hermes-message-subagents msg) []))
         (sa-plists (apply #'vector
                           (mapcar #'hermes--subagent-to-plist
                                   (append sas nil))))
         (usage (hermes-message-usage msg))
         (usage-plist (cond ((null usage) nil)
                            ((hash-table-p usage) (hermes--hash-to-plist usage))
                            (t usage)))
         (ts (hermes-message-timestamp msg))
         (ts-str (cond ((stringp ts) ts)
                       ((null ts) nil)
                       (t (format-time-string "%Y-%m-%dT%H:%M:%S%z" ts)))))
    (list :kind (hermes-message-kind msg)
          :segments seg-plists
          :subagents sa-plists
          :usage usage-plist
          :timestamp ts-str)))

(defun hermes--plist-to-message (plist)
  "Reconstruct a `hermes-message' from PLIST.
Inverse of `hermes--message-to-plist'."
  (let* ((segs-raw (plist-get plist :segments))
         (segs (cond ((vectorp segs-raw)
                      (apply #'vector
                             (mapcar #'hermes--plist-to-segment
                                     (append segs-raw nil))))
                     ((listp segs-raw)
                      (apply #'vector
                             (mapcar #'hermes--plist-to-segment segs-raw)))
                     (t [])))
         (sas-raw (plist-get plist :subagents))
         (sas (cond ((vectorp sas-raw)
                     (apply #'vector
                            (mapcar #'hermes--plist-to-subagent
                                    (append sas-raw nil))))
                    ((listp sas-raw)
                     (apply #'vector
                            (mapcar #'hermes--plist-to-subagent sas-raw)))
                    (t []))))
    (make-hermes-message
     :kind (plist-get plist :kind)
     :segments segs
     :subagents sas
     :usage (plist-get plist :usage)
     :timestamp (plist-get plist :timestamp))))

(defun hermes--struct-to-plist (struct)
  "Convert STRUCT (a cl-defstruct instance) to a plist.
Dispatches by struct type for the known hermes-* structs."
  (cond
   ((hermes-message-p struct) (hermes--message-to-plist struct))
   ((hermes-segment-p struct) (hermes--segment-to-plist struct))
   ((hermes-tool-p struct) (hermes--tool-to-plist struct))
   ((hermes-subagent-p struct) (hermes--subagent-to-plist struct))
   (t (error "hermes--struct-to-plist: unsupported %S" struct))))

(defun hermes--plist-to-struct (plist constructor &optional _slot-specs)
  "Reconstruct a struct from PLIST using CONSTRUCTOR.
CONSTRUCTOR may be a symbol naming one of the known hermes-* makers, in
which case dispatch routes to the correct typed reconstructor."
  (pcase constructor
    ('make-hermes-message  (hermes--plist-to-message plist))
    ('make-hermes-segment  (hermes--plist-to-segment plist))
    ('make-hermes-tool     (hermes--plist-to-tool plist))
    ('make-hermes-subagent (hermes--plist-to-subagent plist))
    (_ (apply constructor plist))))

;;;; Build a hermes-message from an in-flight stream

(defun hermes--strip-surrounding-blank-lines (s)
  "Return S with leading and trailing whitespace-only newlines removed.
Internal blank lines (paragraph breaks) are preserved."
  (let ((s (or s "")))
    (when (string-match "\\`\\(?:[ \t]*\n\\)+" s)
      (setq s (substring s (match-end 0))))
    (when (string-match "\\(?:\n[ \t]*\\)+\\'" s)
      (setq s (substring s 0 (match-beginning 0))))
    s))

(defun hermes--normalize-segments (segs)
  "Return a copy of SEGS with text/reasoning content blank-line-normalized.
Strips leading and trailing whitespace-only newlines on `text' and
`reasoning' segments so committed buffer rendering does not get blank
lines between a heading's `:END:' and the body or between body and the
next heading.  Other segment types (`tool', `image', `system') are
untouched — their bodies are structured."
  (if (not (vectorp segs))
      segs
    (let* ((n (length segs))
           (out (make-vector n nil)))
      (dotimes (i n)
        (let ((seg (aref segs i)))
          (aset out i
                (if (memq (hermes-segment-type seg) '(text reasoning))
                    (hermes--with-copy seg hermes-segment-copy ns
                      (setf (hermes-segment-content ns)
                            (hermes--strip-surrounding-blank-lines
                             (hermes-segment-content seg))))
                  seg))))
      out)))

(defun hermes--message-from-stream (stream usage)
  "Build an assistant `hermes-message' from STREAM and USAGE."
  (make-hermes-message
   :kind 'assistant
   :segments (hermes--normalize-segments
              (or (hermes-stream-segments stream) []))
   :subagents (or (hermes-stream-subagents stream) [])
   :usage usage
   :timestamp (current-time)))

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
       (let* ((text (plist-get p :text))
              ;; Pull successfully-attached images from the state mirror;
              ;; drop any still-pending or errored entries (we don't know
              ;; whether the gateway received them in time).
              (attached (cl-remove-if-not
                         (lambda (a) (eq 'attached (plist-get a :status)))
                         (hermes-state-attachments state)))
              (image-segs (mapcar
                           (lambda (a)
                             (make-hermes-segment
                              :type 'image
                              :content (list :path  (plist-get a :path)
                                             :name  (plist-get a :name)
                                             :width (plist-get a :width)
                                             :height (plist-get a :height)
                                             :token-estimate (plist-get a :token-estimate))
                              :id (hermes--next-segment-id)))
                           attached))
              (text-seg (make-hermes-segment
                         :type 'text :content text
                         :id (hermes--next-segment-id)))
              (segs (apply #'vector (append image-segs (list text-seg))))
              (msg (make-hermes-message
                    :kind 'user
                    :segments segs
                    :timestamp (current-time)))
              (s1 (hermes--push-pending state msg)))
         (hermes--with-copy s1 hermes-state-copy s
           (setf (hermes-state-history s)
                 (let ((h (cons text (hermes-state-history state))))
                   (if (> (length h) hermes-history-max)
                       (cl-subseq h 0 hermes-history-max)
                     h)))
           ;; Clear the whole attachments slot — including pending/errored
           ;; entries.  Pending attachments that race past the send are the
           ;; documented divergence trade-off (see PLAN.md §6.5).
           (setf (hermes-state-attachments s) nil))))
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
      (:attachment-add
       ;; PAYLOAD plist contains :attach-id and any of :path :name :width
       ;; :height :token-estimate :status.  Pushes a new entry (oldest-first
       ;; ordering preserved by appending at the tail).
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-attachments s)
               (append (hermes-state-attachments state) (list p)))))
      (:attachment-update
       ;; Merge PAYLOAD into the entry whose :attach-id matches.
       (let* ((aid (plist-get p :attach-id))
              (atts (hermes-state-attachments state))
              (updated
               (mapcar
                (lambda (a)
                  (if (equal aid (plist-get a :attach-id))
                      (let ((merged (copy-sequence a))
                            (kv p))
                        (while kv
                          (setq merged (plist-put merged (car kv) (cadr kv))
                                kv (cddr kv)))
                        merged)
                    a))
                atts)))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-attachments s) updated))))
      (:attachment-remove
       (let* ((aid (plist-get p :attach-id))
              (filtered (cl-remove-if (lambda (a) (equal aid (plist-get a :attach-id)))
                                      (hermes-state-attachments state))))
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-attachments s) filtered))))
      (:attachments-clear
       (if (null (hermes-state-attachments state))
           state
         (hermes--with-copy state hermes-state-copy s
           (setf (hermes-state-attachments s) nil))))
      (:slash-catalog
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-slash-catalog s) (plist-get p :catalog))))
      (:set-cwd
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-cwd s) (plist-get p :cwd))))
      (:pending-turns-clear
       (hermes--with-copy state hermes-state-copy s
         (setf (hermes-state-pending-turns s) [])))
      ;; --- Background tasks (client-side synthetic events) ---------------
      (:background-start
       (let* ((tid (plist-get p :task-id))
              (prompt (plist-get p :prompt))
              (bg-tasks (or (hermes-state-bg-tasks state) []))
              (existing (cl-find-if (lambda (bt)
                                      (equal tid (hermes-bg-task-task-id bt)))
                                    (append bg-tasks nil))))
         (if existing
             state
           (let ((new-task (make-hermes-bg-task
                            :task-id tid
                            :prompt prompt
                            :status 'running
                            :created-at (format-time-string "%Y-%m-%dT%H:%M:%S%z"))))
             (hermes--with-copy state hermes-state-copy s
               (setf (hermes-state-bg-tasks s)
                     (vconcat bg-tasks (vector new-task))))))))
      (:bg-rendered
       (let* ((tid (plist-get p :task-id))
              (bname (plist-get p :buffer-name))
              (bg-tasks (hermes-state-bg-tasks state))
              (existing (and (vectorp bg-tasks)
                             (cl-find-if (lambda (bt)
                                           (equal tid (hermes-bg-task-task-id bt)))
                                         (append bg-tasks nil)))))
         (if (and existing bname)
             (let ((updated (hermes-bg-task-copy existing)))
               (setf (hermes-bg-task-buffer-name updated) bname)
               (let ((new-vec (vconcat
                               (cl-remove-if (lambda (bt)
                                               (equal tid (hermes-bg-task-task-id bt)))
                                             (append bg-tasks nil))
                               (vector updated))))
                 (hermes--with-copy state hermes-state-copy s
                   (setf (hermes-state-bg-tasks s) new-vec))))
           state)))
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
             (let ((busy (hermes--get p "busy")))
               (when (and busy (stringp busy) (not (string-empty-p busy)))
                 (setf (hermes-state-busy-mode s) busy)))
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
      ("reasoning.available"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (text (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (if (hermes--reasoning-duplicate-p text old-stream)
             state
           (hermes--with-copy state hermes-state-copy s
             (setf (hermes-state-stream s)
                   (if (and last (eq 'reasoning (hermes-segment-type last)))
                       (hermes--update-last-segment old-stream
                         (lambda (seg)
                           (hermes--with-copy seg hermes-segment-copy ns
                             (setf (hermes-segment-content ns) text))))
                     (hermes--append-segment old-stream
                       (make-hermes-segment :type 'reasoning :content text
                                            :id (hermes--next-segment-id)))))))))
      ("reasoning.delta"
       (let* ((old-stream (or (hermes-state-stream state)
                              (make-hermes-stream :segments [] :tools [])))
              (chunk (or (hermes--get p "text") ""))
              (last (hermes--last-segment old-stream)))
         (if (hermes--reasoning-duplicate-p chunk old-stream)
             state
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
                                            :id (hermes--next-segment-id)))))))))
      ("message.complete"
       (let ((str (hermes-state-stream state)))
         (if (null str)
             state
           (let* ((sent (hermes--get p "tokens_sent"))
                  (received (hermes--get p "tokens_received"))
                  ;; Per-turn usage attached to the message itself.  Carries
                  ;; only the deltas from this turn, not the session total.
                  (msg-usage (make-hash-table :test 'equal))
                  (_ (progn
                       (when sent     (puthash "tokens_sent" sent msg-usage))
                       (when received (puthash "tokens_received" received msg-usage))))
                  (msg (hermes--message-from-stream str msg-usage))
                  ;; Cumulative session-wide counter lives in state.
                  (acc-usage (or (hermes-state-usage state)
                                 (make-hash-table :test 'equal))))
             (when sent
               (puthash "tokens_sent" (+ (or (gethash "tokens_sent" acc-usage) 0) sent)
                        acc-usage))
             (when received
               (puthash "tokens_received" (+ (or (gethash "tokens_received" acc-usage) 0)
                                             received)
                        acc-usage))
             (let ((s1 (hermes--push-pending state msg)))
               (hermes--with-copy s1 hermes-state-copy s
                 (setf (hermes-state-usage s) acc-usage
                       (hermes-state-stream s) nil)))))))
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
             (ctx (hermes--strip-ansi (hermes--get p "context")))
             (todos-raw (hermes--get p "todos")))
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
                                        (hermes-tool-context nt) ctx)
                                  (when todos-raw
                                    (setf (hermes-tool-todos nt) todos-raw))))
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
             (preview (hermes--strip-ansi (hermes--get p "preview")))
             (todos-raw (hermes--get p "todos")))
         (if (or (null str) (null tid))
             state
           (let* ((segs (hermes-stream-segments str))
                  (idx (hermes--find-tool-segment-index segs tid)))
             (if (null idx)
                 state
               (let* ((old-seg (aref segs idx))
                      (old-tool (hermes-segment-content old-seg))
                      (new-tool (hermes--with-copy old-tool hermes-tool-copy nt
                                  (setf (hermes-tool-preview nt) preview)
                                  (when todos-raw
                                    (setf (hermes-tool-todos nt) todos-raw))))
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
              (inline-diff (hermes--strip-ansi (hermes--get p "inline_diff")))
              (todos-raw (hermes--get p "todos"))
              (output (hermes--strip-ansi (hermes--get p "output")))
              (summary (hermes--strip-ansi (hermes--get p "summary")))
              (err    (hermes--strip-ansi (hermes--get p "error")))
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
                                        (hermes-tool-summary nt) summary
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
       (let* ((text (plist-get p :text))
              (msg (make-hermes-message
                    :kind 'system
                    :segments (vector
                               (make-hermes-segment
                                :type 'text :content text
                                :id (hermes--next-segment-id)))
                    :timestamp (current-time))))
         (hermes--push-pending state msg)))
      (:pending-clear
       (if (hermes-state-pending state)
           (hermes--with-copy state hermes-state-copy s
             (setf (hermes-state-pending s) nil))
         state))
      ;; --- Errors --------------------------------------------------------
      ;; Diagnostics never enter the Org buffer.  They go to *hermes-log*
      ;; for inspection; the header-line status (set by the UI reducer)
      ;; surfaces transient signals.  When an `error' arrives mid-stream,
      ;; we still commit the partial assistant turn — losing it would
      ;; silently drop work the user can see on screen.
      ("error"
       (let ((text (ansi-color-apply
                    (or (hermes--get p "message") "(unknown error)")))
             (str (hermes-state-stream state)))
         (hermes--log-write "%s" text)
         (if (null str)
             state
           (let* ((amsg (hermes--message-from-stream str nil))
                  (s1 (hermes--push-pending state amsg)))
             (hermes--with-copy s1 hermes-state-copy s
               (setf (hermes-state-stream s) nil))))))
      ;; --- Gateway diagnostics -------------------------------------------
      ("gateway.stderr"
       (let* ((line (or (hermes--get p "line") ""))
              (clipped (substring line 0 (min 120 (length line)))))
         (hermes--log-write "[stderr] %s" clipped)
         state))
      ("gateway.protocol_error"
       (let ((preview (hermes--get p "preview")))
         (hermes--log-write "[protocol noise] %s" (or preview ""))
         state))
      ("gateway.start_timeout"
       (let ((lines (hermes--get p "lines")))
         (hermes--log-write "[gateway start timeout]")
         (dolist (l (append lines nil))
           (hermes--log-write "  %s" l))
         state))
      ;; --- Background / review -------------------------------------------
      ("background.complete"
       (let* ((tid (hermes--get p "task_id"))
              (txt (hermes--get p "text"))
              (err (hermes--get p "error"))
              (bg-tasks (hermes-state-bg-tasks state))
              (existing (and (vectorp bg-tasks)
                             (cl-find-if (lambda (bt)
                                           (equal tid (hermes-bg-task-task-id bt)))
                                         (append bg-tasks nil)))))
         (hermes--log-write "[bg %s] %s" (or tid "?") (or txt err ""))
         (cond
          (existing
           (let ((updated (hermes-bg-task-copy existing)))
             (setf (hermes-bg-task-status updated) (if err 'error 'complete)
                   (hermes-bg-task-result updated) txt
                   (hermes-bg-task-error updated) err
                   (hermes-bg-task-completed-at updated)
                   (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
             (let ((new-vec (vconcat
                             (cl-remove-if (lambda (bt)
                                             (equal tid (hermes-bg-task-task-id bt)))
                                           (append bg-tasks nil))
                             (vector updated))))
               (hermes--with-copy state hermes-state-copy s
                 (setf (hermes-state-bg-tasks s) new-vec)))))
          (t
           (let* ((now (format-time-string "%Y-%m-%dT%H:%M:%S%z"))
                  (new-task (make-hermes-bg-task
                             :task-id tid
                             :prompt (or txt "")
                             :status (if err 'error 'complete)
                             :result txt
                             :error err
                             :created-at now
                             :completed-at now)))
             (hermes--with-copy state hermes-state-copy s
               (setf (hermes-state-bg-tasks s)
                     (vconcat (or bg-tasks []) (vector new-task)))))))))
      ("review.summary"
       (let ((txt (hermes--get p "text")))
         (hermes--log-write "[review] %s" (or txt ""))
         state))
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
               (hermes-ui-state-status-kind s) (hermes--get p "kind")
               (hermes-ui-state-thinking-text s) nil)))
      ("thinking.delta"
       (let* ((chunk (or (hermes--get p "text") ""))
              (acc (concat (or (hermes-ui-state-thinking-text state) "") chunk)))
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-thinking-text s) acc
                 (hermes-ui-state-status-text s) acc))))
      ("message.start"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) "Responding…"
               (hermes-ui-state-thinking-text s) nil)))
      ("message.complete"
       (hermes--with-copy state hermes-ui-state-copy s
         (setf (hermes-ui-state-status-text s) nil
               (hermes-ui-state-tool-previews s) nil
               (hermes-ui-state-thinking-text s) nil)))
       ("tool.generating"
        (let ((name (hermes--get p "name")))
          (hermes--with-copy state hermes-ui-state-copy s
            (setf (hermes-ui-state-status-text s)
                  (format "Running %s…" (or name "tool"))
                  (hermes-ui-state-thinking-text s) nil))))
       ("tool.start"
        (let ((name (hermes--get p "name")))
          (hermes--with-copy state hermes-ui-state-copy s
            (setf (hermes-ui-state-status-text s)
                  (format "Running %s…" (or name "tool"))
                  (hermes-ui-state-thinking-text s) nil))))
       ("tool.progress"
        (let ((tid (hermes--get p "tool_id"))
              (preview (hermes--strip-ansi (hermes--get p "preview"))))
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
                             "subagent"))
                   (hermes-ui-state-thinking-text s) nil))))
        ("subagent.complete"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s) nil
                 (hermes-ui-state-thinking-text s) nil)))
         ("error"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s)
                 (or (hermes--get p "message") "(error)")
                 (hermes-ui-state-tool-previews s) nil
                 (hermes-ui-state-thinking-text s) nil)))
        ("gateway.start_timeout"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s)
                 "Gateway failed to start (see chat buffer)"
                 (hermes-ui-state-thinking-text s) nil)))
        ("gateway.protocol_error"
         (hermes--with-copy state hermes-ui-state-copy s
           (setf (hermes-ui-state-status-text s)
                 "Protocol noise from gateway (see chat buffer)"
                 (hermes-ui-state-thinking-text s) nil)))
        (_ state))))

(provide 'hermes-state)
;;; hermes-state.el ends here
