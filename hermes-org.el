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
Populated by `hermes-send' when the user targets a heading whose
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
headings and the property drawer.  Point must be on a heading."
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
                            (t (forward-line 1))))
                         subtree-end))
                     subtree-end)))
        (when (> end start)
          (let ((s (string-trim (buffer-substring-no-properties start end))))
            (and (not (string-empty-p s)) s)))))))

(defun hermes--parse-turn-body-text ()
  "Return the body text under a turn heading at point.
Excludes child headings and the :PROPERTIES: drawer."
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
                            (t (forward-line 1))))
                         turn-end))
                     turn-end)))
        (when (> end start)
          (let ((s (string-trim (buffer-substring-no-properties start end))))
            (and (not (string-empty-p s)) s)))))))

(defun hermes--read-usage-properties ()
  "Read usage counters from the heading at point.
Returns a keyword plist or nil if no `HERMES_USAGE_*' properties
are present.  Decodes numeric strings (including scientific
notation); non-numeric values are kept as strings.  Property
names lose their `HERMES_USAGE_' prefix and are downcased."
  (let ((props (org-entry-properties (point) 'standard))
        (acc nil))
    (dolist (p props)
      (let ((name (car p))
            (val (cdr p)))
        (when (and (stringp name)
                   (string-prefix-p "HERMES_USAGE_" name))
          (let* ((raw-key (downcase (substring name (length "HERMES_USAGE_"))))
                 (kw (intern (concat ":" raw-key)))
                 (decoded (cond
                           ((null val) nil)
                           ((string-match-p
                             "\\`-?[0-9]+\\.?[0-9]*\\(?:[eE][-+]?[0-9]+\\)?\\'"
                             val)
                            (string-to-number val))
                           (t val))))
            (push kw acc)
            (push decoded acc)))))
    (when acc (nreverse acc))))

(defun hermes--parse-attr-line (text)
  "Parse a `:key val :key val …' attribute string into a plist.
Quoted strings are unquoted; numeric tokens become numbers; bare
non-numeric tokens become symbols.  Returns nil when TEXT has no
recognizable pairs.  No `read'/eval — safe on user-edited buffers."
  (let ((result nil)
        (pos 0))
    (while (string-match
            "[ \t]*\\(:[^ \t]+\\)[ \t]+\\(\"[^\"]*\"\\|[^ \t]+\\)" text pos)
      (let* ((k (intern (match-string 1 text)))
             (raw (match-string 2 text))
             (v (cond
                 ((string-match-p "\\`\"" raw)
                  (substring raw 1 -1))
                 ((string-match-p "\\`-?[0-9]+\\(\\.[0-9]+\\)?\\'" raw)
                  (string-to-number raw))
                 (t (intern raw)))))
        (setq result (plist-put result k v))
        (setq pos (match-end 0))))
    result))

(defun hermes--parse-body-segments (text)
  "Split TEXT into a list of (TYPE . CONTENT) pairs.
TYPE is `text or `image.  CONTENT is a string for text, a plist for
image (with :path plus any of :width :height :name :token-estimate).
Adjacent text lines collapse into one segment joined by newlines.
Looks back up to two lines from each `[[file:PATH]]' link for
`#+attr_org:'/`#+attr_hermes:' attributes."
  (let (segs)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (while (not (eobp))
        (cond
         ((looking-at "^#\\+attr_\\(?:org\\|hermes\\):")
          (forward-line 1))
         ((looking-at "\\[\\[file:\\([^]]+\\)\\]\\]")
          (let ((path (match-string-no-properties 1))
                (img nil))
            ;; Walk back over attr lines.  attr_hermes is read first
            ;; (immediately above the link) and provides canonical
            ;; metadata; attr_org is read second (one above) and only
            ;; fills keys attr_hermes did not set — so display-only
            ;; dimensions from attr_org cannot overwrite real ones.
            (save-excursion
              (dotimes (_ 2)
                (when (zerop (forward-line -1))
                  (when (looking-at
                         "^#\\+attr_\\(?:org\\|hermes\\):[ \t]*\\(.*\\)$")
                    (let ((plist (hermes--parse-attr-line
                                  (match-string-no-properties 1))))
                      (while plist
                        (let ((k (car plist)) (v (cadr plist)))
                          (unless (plist-member img k)
                            (setq img (plist-put img k v))))
                        (setq plist (cddr plist))))))))
            (setq img (plist-put img :path path))
            (push (cons 'image img) segs))
          (forward-line 1))
         (t
          (push (cons 'text (buffer-substring-no-properties
                             (line-beginning-position)
                             (line-end-position)))
                segs)
          (forward-line 1)))))
    (let (collapsed)
      (dolist (seg (nreverse segs))
        (if (and collapsed
                 (eq 'text (caar collapsed))
                 (eq 'text (car seg)))
            (setcdr (car collapsed)
                    (concat (cdar collapsed) "\n" (cdr seg)))
          (push seg collapsed)))
      (nreverse collapsed))))

(defun hermes--split-subagent-heading (text)
  "Return (GOAL . STATUS) from \"goal (status)\" headline TEXT.
STATUS is nil if no trailing parenthesized status is found."
  (if (string-match "^\\(.+?\\)[ \t]+(\\([^)]+\\))$" text)
      (cons (string-trim (match-string 1 text))
            (intern (match-string 2 text)))
    (cons text nil)))

(defun hermes--extract-labeled-block (text label)
  "Find #+begin_example LABEL in TEXT and return its content.
LABEL is e.g. \"Thinking\".  Returns nil if absent."
  (when (and text label)
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((case-fold-search t)
            (pattern (format "^#\\+begin_example %s[ \t]*$"
                             (regexp-quote label))))
        (when (re-search-forward pattern nil t)
          (let ((start (line-end-position)))
            (when (re-search-forward "^#\\+end_example[ \t]*$" nil t)
              (string-trim (buffer-substring-no-properties
                            start (line-beginning-position))))))))))

(defun hermes--extract-unlabeled-block (text type)
  "Find a plain #+begin_TYPE block in TEXT with no label.
Returns its content.  Matches #+begin_TYPE lines where the optional
label is nil (e.g. #+begin_example Thinking is skipped)."
  (when text
    (with-temp-buffer
      (insert text)
      (goto-char (point-min))
      (let ((case-fold-search t)
            (re (format "^#\\+begin_%s\\(?:[ \t]+\\(\\S-+\\)\\)?[ \t]*$"
                        type)))
        (catch 'found
          (while (re-search-forward re nil t)
            (when (null (match-string 1))
              (let ((start (line-end-position)))
                (when (re-search-forward (format "^#\\+end_%s[ \t]*$" type) nil t)
                  (throw 'found (string-trim (buffer-substring-no-properties
                                              start (line-beginning-position))))))))
          nil)))))

(defun hermes--parse-subagent-body (heading-text body id)
  "Reconstruct a `hermes-subagent' from visible heading + body.
HEADING-TEXT is the stripped headline (e.g. \"fix bugs (running…)\").
BODY is the heading body string.  ID is the subagent id property.

Contract: the formatter groups tools before notes as separate bullet
blocks; if the reducer ever interleaves them, round-trip will silently
reorder into tools-then-notes."
  (when id
    (let* ((goal-and-status (hermes--split-subagent-heading heading-text))
           (goal (car goal-and-status))
           (status (or (cdr goal-and-status) 'queued))
           (thinking nil)
           (tools [])
           (notes [])
           (summary nil)
           (duration nil))
      (when body
        (setq thinking (hermes--extract-labeled-block body "Thinking"))
        (let ((tool-items nil) (note-items nil))
          (dolist (line (split-string body "\n" t))
            (when (string-match "^[ \t]*-[ \t]+\\(.*\\)$" line)
              (let ((rest (match-string 1 line)))
                (if (string-match "^\\([^ ]+\\)(\\(.*\\))$" rest)
                    (push (list :name (match-string 1 rest)
                                :args (match-string 2 rest))
                          tool-items)
                  (push (string-trim rest) note-items)))))
          (setq tools (vconcat (nreverse tool-items)))
          (setq notes (vconcat (nreverse note-items))))
        (let ((raw (hermes--extract-unlabeled-block body "example")))
          (when raw
            (when (string-match "\\(.*\\) (\\([0-9.]+\\)s)\\s-*$" raw)
              (setq summary (string-trim (match-string 1 raw)))
              (setq duration (ignore-errors (read (match-string 2 raw))))))))
      (make-hermes-subagent
       :id id :goal goal :status status
       :thinking thinking
       :tools tools :notes notes
       :summary summary :duration duration))))

(declare-function make-hermes-subagent "hermes-state" (&rest _))

(defun hermes--parse-turn-at-point ()
  "Parse the turn heading at point into a `hermes-message' struct.
Derives text segments from visible buffer structure (USER/SYSTEM body,
or assistant child Response/Reasoning headings).  Reads usage from
`HERMES_USAGE_*' heading properties.  Subagents and images are parsed
from visible buffer structure (child SUBAGENT headings; `#+attr_*:' +
`[[file:…]]' lines in user/system bodies).  Returns nil if point is
not on a recognized turn heading."
  (when (and (derived-mode-p 'org-mode)
             (org-at-heading-p))
    (let* ((kind-prop (org-entry-get (point) "HERMES_KIND"))
           (kind (pcase kind-prop
                   ("USER" 'user)
                   ("ASSISTANT" 'assistant)
                   ("SYSTEM" 'system)
                   (_ nil)))
           (timestamp (org-entry-get (point) "HERMES_TIMESTAMP"))
           (segs ())
           (subagents ()))
      (when kind
        (cond
         ((memq kind '(user system))
          (let* ((body (hermes--parse-turn-body-text))
                 (parts (and body (hermes--parse-body-segments body))))
            (dolist (part parts)
              (pcase (car part)
                ('text
                 (let ((s (cdr part)))
                   (when (and s (not (string-empty-p (string-trim s))))
                     (push (make-hermes-segment
                            :type 'text :content s
                            :id (hermes--next-segment-id))
                           segs))))
                ('image
                 (push (make-hermes-segment
                        :type 'image :content (cdr part)
                        :id (hermes--next-segment-id))
                       segs))))))
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
                                 ;; The heading alone is the sole source of
                                 ;; truth for a tool segment.  :inline-diff /
                                 ;; :output / :error / :context are
                                 ;; body-canonical in #+name'd blocks; :todos
                                 ;; is body-canonical in a #+name'd Org table;
                                 ;; :summary and :name/:status/:duration live
                                 ;; in heading properties.  :preview is
                                 ;; ephemeral and nil on resume.  The parser
                                  ;; does not read :tool-calls from
                                  ;; any meta drawer — all tool data is
                                  ;; body-canonical or property-canonical.
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
                                             :context (and slug
                                                           (hermes--extract-named-block
                                                            body
                                                            (format "hermes-tool-%s-context" slug)))
                                             :preview nil
                                             :inline-diff (and terminal-p slug
                                                               (hermes--extract-named-block
                                                                body
                                                                (format "hermes-tool-%s-inline-diff" slug)))
                                             :todos (let ((table (and slug
                                                                       (hermes--extract-named-table
                                                                        body
                                                                        (format "hermes-tool-%s-todos" slug)))))
                                                      (and table (hermes--parse-todos-table table)))
                                             :summary (let ((s (org-entry-get (point) "TOOL_SUMMARY")))
                                                        (and s (hermes--strip-ansi s)))
                                             :error (and (eq status 'error) slug
                                                         (hermes--extract-named-block
                                                          body
                                                          (format "hermes-tool-%s-error" slug))))
                                   :id (hermes--next-segment-id))
                                  segs)))
                         ((equal child-kind "SUBAGENT")
                          (let* ((id (org-entry-get (point) "ID"))
                                 (heading-text (org-get-heading t t t t))
                                 (body (hermes--parse-heading-body))
                                 (sa (hermes--parse-subagent-body heading-text body id)))
                            (when sa
                              (push sa subagents))))
                         (t nil))))
                    (unless (and (outline-next-heading)
                                 (< (point) turn-end))
                      (setq continue nil))))))
            (ignore turn-pos)))
         (t nil))
        (make-hermes-message
         :kind kind
         :segments (vconcat (nreverse segs))
         :usage (save-excursion (hermes--read-usage-properties))
         :subagents (vconcat (nreverse subagents))
         :timestamp timestamp)))))

(defun hermes--parse-subtree-messages ()
  "Parse turn headings under the container at point into a vector of
`hermes-message' structs.  Scope is the current Org subtree only; the
container heading itself is skipped.  Derives text, subagents, images,
and usage from visible buffer structure."
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
plus heading properties, so there's nothing to seed.  Mirroring to `hermes--state'
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

(defun hermes--short-sid (sid)
  "Return the first 8 chars of SID for prompt display."
  (if (and (stringp sid) (> (length sid) 8))
      (substring sid 0 8)
    (or sid "?")))

(defun hermes--prompt-stale-heading (sid)
  "Prompt the user how to handle the stale SID heading.
Returns one of the symbols `load-org', `resume-db', `branch-db', or nil
when the user cancels.  Default (RET) is `load-org' — the snapshot path."
  (let ((c (read-char-choice
            (format "Stale session %s — [1] load from org / [2] resume from DB / [3] branch from DB / [q]uit (default 1): "
                    (hermes--short-sid sid))
            '(?1 ?2 ?3 ?q ?\r ?\n))))
    (pcase c
      ((or ?1 ?\r ?\n) 'load-org)
      (?2 'resume-db)
      (?3 'branch-db)
      (?q nil))))

(declare-function hermes-resume-from-db "hermes-sessions" (sid))
(declare-function hermes-branch-from-db "hermes-sessions" (sid))

(defun hermes--handle-stale-heading (sid marker)
  "Dispatch the user's choice for the stale SID heading at MARKER.
MARKER pinpoints the container heading in the current buffer.  Action
options:
- `load-org'  → `hermes--create-fresh-session' (current buffer; the
                 history seed will fire on the next prompt).
- `resume-db' → `hermes-resume-from-db' (opens a new buffer with the
                 gateway's stored history; current buffer untouched).
- `branch-db' → `hermes-branch-from-db' (forks the DB session, opens
                 the branched copy in a new buffer)."
  (pcase (hermes--prompt-stale-heading sid)
    ('load-org   (hermes--create-fresh-session sid marker))
    ('resume-db  (require 'hermes-sessions)
                 (hermes-resume-from-db sid))
    ('branch-db  (require 'hermes-sessions)
                 (hermes-branch-from-db sid))
    (_           (message "Cancelled"))))

(provide 'hermes-org)
;;; hermes-org.el ends here
