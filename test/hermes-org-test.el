;;; hermes-org-test.el --- ERT tests for hermes-org.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'hermes-org)

(defmacro hermes-org-test--with-buffer (body &rest rest)
  "Run REST in a temp Org buffer pre-loaded with BODY."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert ,body)
     (goto-char (point-min))
     ,@rest))

;;;; hermes--session-at-point

(ert-deftest hermes-org-test/session-at-point-finds-container ()
  "Point inside a `:hermes:'-tagged subtree returns its session id."
  (hermes-org-test--with-buffer
   "* Research chat :hermes:
:PROPERTIES:
:HERMES_SESSION: sess-abc
:END:
** Question :user:
some text
"
   (re-search-forward "some text")
   (should (equal "sess-abc" (hermes--session-at-point)))))

(ert-deftest hermes-org-test/session-at-point-nil-when-outside ()
  "Point in a normal heading (no `:hermes:' ancestor) returns nil."
  (hermes-org-test--with-buffer
   "* Normal heading
just notes, no session
* Project X notes :project:
also no session
"
   (re-search-forward "just notes")
   (should (null (hermes--session-at-point)))
   (re-search-forward "also no session")
   (should (null (hermes--session-at-point)))))

(ert-deftest hermes-org-test/session-at-point-nil-when-property-missing ()
  "A `:hermes:'-tagged heading without `:HERMES_SESSION:' returns nil.
The container exists but the gateway hasn't assigned an id yet."
  (hermes-org-test--with-buffer
   "* Fresh chat :hermes:
no id yet
"
   (re-search-forward "no id yet")
   (should (null (hermes--session-at-point)))))

(ert-deftest hermes-org-test/session-at-point-disambiguates-siblings ()
  "Two sibling sessions: point in each subtree returns the right id."
  (hermes-org-test--with-buffer
   "* Coding help :hermes:
:PROPERTIES:
:HERMES_SESSION: code-1
:END:
** Q1 :user:
coding question

* Writing help :hermes:
:PROPERTIES:
:HERMES_SESSION: write-1
:END:
** Q1 :user:
writing question
"
   (re-search-forward "coding question")
   (should (equal "code-1" (hermes--session-at-point)))
   (re-search-forward "writing question")
   (should (equal "write-1" (hermes--session-at-point)))))

(ert-deftest hermes-org-test/session-at-point-walks-up-from-deep-child ()
  "Point under a nested non-hermes child still resolves via ancestor walk."
  (hermes-org-test--with-buffer
   "* Container :hermes:
:PROPERTIES:
:HERMES_SESSION: deep-1
:END:
** Turn :user:
*** Reasoning
deep inside the reasoning subtree
"
   (re-search-forward "deep inside")
   (should (equal "deep-1" (hermes--session-at-point)))))

;;;; registry helpers

(ert-deftest hermes-org-test/ensure-registries-creates-hashes ()
  "First call lazily creates both buffer-local hash tables."
  (with-temp-buffer
    (should (null hermes--buffer-sessions))
    (should (null hermes--session-markers))
    (hermes--ensure-registries)
    (should (hash-table-p hermes--buffer-sessions))
    (should (hash-table-p hermes--session-markers))))

(ert-deftest hermes-org-test/register-and-lookup-roundtrip ()
  "`hermes--register-session' makes state + marker retrievable by id."
  (with-temp-buffer
    (org-mode)
    (insert "* Session :hermes:\n")
    (goto-char (point-min))
    (let ((marker (copy-marker (point) nil))
          (state 'placeholder-state))
      (hermes--register-session "sid-1" state marker)
      (should (eq state (hermes--lookup-session-state "sid-1")))
      (should (eq marker (hermes--lookup-session-marker "sid-1")))
      (should (null (hermes--lookup-session-state "sid-missing"))))))

;;;; Dispatch routing by session id (slice B)

(require 'hermes-state)

(ert-deftest hermes-org-test/dispatch-without-session-id-targets-buffer-local ()
  "Calling `hermes-dispatch' with no session-id mutates `hermes--state'."
  (with-temp-buffer
    (hermes-state-init)
    (let ((before hermes--state))
      (hermes-dispatch (cons "session.info"
                              (let ((h (make-hash-table :test 'equal)))
                                (puthash "session_id" "sid-x" h)
                                h)))
      (should-not (eq before hermes--state))
      (should (equal "sid-x" (hermes-state-session-id hermes--state))))))

(ert-deftest hermes-org-test/dispatch-with-session-id-updates-registry-slot ()
  "When the session is registered, dispatch updates the hash entry in place."
  (with-temp-buffer
    (hermes-state-init)
    (let ((initial hermes--state))
      (hermes--register-session "sid-A" initial
                                (copy-marker (point-min) nil))
      ;; A dispatch carrying the session id must refresh both the
      ;; registry slot and the mirrored `hermes--state'.
      (hermes-dispatch (cons "session.info"
                              (let ((h (make-hash-table :test 'equal)))
                                (puthash "session_id" "sid-A" h)
                                (puthash "model" "opus" h)
                                h))
                       "sid-A")
      (let ((stored (hermes--lookup-session-state "sid-A")))
        (should-not (eq initial stored))
        (should (equal "sid-A" (hermes-state-session-id stored)))
        (should (eq stored hermes--state))))))

(ert-deftest hermes-org-test/dispatch-binds-current-session-id-for-hooks ()
  "Hooks fired during dispatch see `hermes--current-session-id' bound."
  (with-temp-buffer
    (hermes-state-init)
    (hermes--register-session "sid-B" hermes--state
                              (copy-marker (point-min) nil))
    (let* ((seen nil)
           (probe (lambda (_o _n) (push hermes--current-session-id seen))))
      (add-hook 'hermes-state-change-hook probe nil t)
      (unwind-protect
          (hermes-dispatch (cons "session.info"
                                  (let ((h (make-hash-table :test 'equal)))
                                    (puthash "session_id" "sid-B" h)
                                    (puthash "model" "opus" h)
                                    h))
                           "sid-B")
        (remove-hook 'hermes-state-change-hook probe t))
      (should (equal '("sid-B") seen)))))

;;;; Subtree-scoped rendering (slice C)

(require 'hermes-render)

(defun hermes-org-test--two-session-buffer ()
  "Insert a buffer with two `:hermes:' container subtrees and seed
the registry with marker + state entries for each.  Returns nothing
\(state is on the current buffer)."
  (insert "* Coding help :hermes:
:PROPERTIES:
:HERMES_SESSION: code-1
:END:

* Writing help :hermes:
:PROPERTIES:
:HERMES_SESSION: write-1
:END:
")
  (let ((code-marker (save-excursion
                       (goto-char (point-min))
                       (re-search-forward "^\\* Coding help")
                       (beginning-of-line)
                       (copy-marker (point) nil)))
        (write-marker (save-excursion
                        (goto-char (point-min))
                        (re-search-forward "^\\* Writing help")
                        (beginning-of-line)
                        (copy-marker (point) nil))))
    (hermes--register-session "code-1"
                              (make-hermes-state :session-id "code-1")
                              code-marker)
    (hermes--register-session "write-1"
                              (make-hermes-state :session-id "write-1")
                              write-marker)))

(ert-deftest hermes-org-test/render-targets-correct-session-subtree ()
  "A user turn rendered under session `code-1' must land inside the
`Coding help' subtree, not after `Writing help'."
  (with-temp-buffer
    (org-mode)
    (hermes-org-test--two-session-buffer)
    ;; Activate hermes--state via slot-read of code-1 and emit a pending
    ;; user turn for it.  Dispatching with the session id binds
    ;; `hermes--current-session-id', so the renderer's insert helper
    ;; resolves to the code-1 subtree end.
    (let* ((sid "code-1")
           (state (hermes--lookup-session-state sid))
           (msg (make-hermes-message
                 :kind 'user
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "reduce?" :id "s1"))
                 :timestamp "2024-01-15T10:00:00+0000"))
           (new (hermes--with-copy state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg))))
           ;; Mirror what `hermes-dispatch' does manually so we can drive
           ;; the renderer directly without going through the full event
           ;; pipeline.
           (hermes--current-session-id sid))
      (setq hermes--state new)
      (puthash sid new hermes--buffer-sessions)
      (hermes--render state new))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      ;; The new turn must appear between the two container headings,
      ;; i.e. before `* Writing help'.
      (should (string-match-p "Coding help.*reduce\\?" (replace-regexp-in-string "\n" " " body)))
      (let ((reduce-pos (string-match "reduce\\?" body))
            (writing-pos (string-match "^\\* Writing help" body)))
        (should reduce-pos)
        (should writing-pos)
        (should (< reduce-pos writing-pos))))))

;;;; Session resolution at point (slice D)

(ert-deftest hermes-org-test/resolve-session-target-finds-state-by-point ()
  "In an Org buffer with two registered sessions, `hermes--resolve-session-target'
returns the (sid . state) pair for whichever container contains point."
  (with-temp-buffer
    (org-mode)
    (hermes-minor-mode 1)
    (hermes-org-test--two-session-buffer)
    (goto-char (point-min))
    (re-search-forward "Coding help")
    (let ((res (hermes--resolve-session-target)))
      (should res)
      (should (equal "code-1" (car res)))
      (should (eq (hermes--lookup-session-state "code-1") (cdr res))))
    (goto-char (point-min))
    (re-search-forward "Writing help")
    (let ((res (hermes--resolve-session-target)))
      (should res)
      (should (equal "write-1" (car res))))))

(ert-deftest hermes-org-test/resolve-session-target-nil-without-container ()
  "Outside any `:hermes:' subtree the resolver returns nil."
  (with-temp-buffer
    (org-mode)
    (hermes-minor-mode 1)
    (insert "* Plain heading\nnot a hermes container\n")
    (re-search-backward "not a hermes")
    (should (null (hermes--resolve-session-target)))))

;;;; Resume / rehydration

(require 'hermes-render)
(require 'hermes-input)

(defun hermes-org-test--seed-subtree-with-drawer (text)
  "Insert a container + one v2-format USER turn for TEXT.
Returns a marker at the container heading."
  (insert (format "* Resumed chat :hermes:
:PROPERTIES:
:HERMES_SESSION: resumed-1
:END:
** U: %s
:PROPERTIES:
:HERMES_KIND: USER
:HERMES_TIMESTAMP: 2024-01-15T10:00:00+0000
:END:
%s
" text text))
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\\* Resumed chat")
    (beginning-of-line)
    (copy-marker (point) nil)))

(ert-deftest hermes-org-test/parse-subtree-messages-collects-drawer-content ()
  "`hermes--parse-subtree-messages' returns one message per turn heading
\(recognized via `:HERMES_KIND:`) in the current heading's subtree."
  (with-temp-buffer
    (org-mode)
    (let ((marker (hermes-org-test--seed-subtree-with-drawer "hi there")))
      (goto-char (marker-position marker))
      (let ((msgs (hermes--parse-subtree-messages)))
        (should (= 1 (length msgs)))
        (should (eq 'user (hermes-message-kind (aref msgs 0))))))))

(ert-deftest hermes-org-test/parse-subtree-messages-scoped-to-subtree ()
  "A turn in a different container subtree must NOT be collected."
  (with-temp-buffer
    (org-mode)
    (let ((marker (hermes-org-test--seed-subtree-with-drawer "first")))
      ;; Append a SECOND container with its own drawer — parser must
      ;; not bleed across the subtree boundary.
      (goto-char (point-max))
      (insert "\n")
      (hermes-org-test--seed-subtree-with-drawer "second")
      (goto-char (marker-position marker))
      (let ((msgs (hermes--parse-subtree-messages)))
        (should (= 1 (length msgs)))))))

(ert-deftest hermes-org-test/rebuild-session-state-survives-user-submit ()
  "Regression: a rebuilt state must accept a `:user-submit' dispatch
without crashing.  The earlier version seeded `:history' with a vector
of message structs, which the reducer's `(cons text history)' +
`(length …)' chain blew up on as soon as a queued send drained."
  (with-temp-buffer
    (org-mode)
    (let* ((marker (hermes-org-test--seed-subtree-with-drawer "seed"))
           (state (hermes--rebuild-session-state "resumed-1" marker)))
      ;; `history' must be a proper list — not a vector or dotted pair.
      (should (listp (hermes-state-history state)))
      ;; And dispatching :user-submit (which conses text onto history
      ;; and asks for its length) must succeed.
      (hermes-dispatch (cons :user-submit (list :text "after resume")))
      (should (member "after resume" (hermes-state-history hermes--state))))))

(ert-deftest hermes-org-test/rebuild-session-state-registers-and-mirrors ()
  "`hermes--rebuild-session-state' registers the new state under SID
and assigns it to `hermes--state'."
  (with-temp-buffer
    (org-mode)
    (let* ((marker (hermes-org-test--seed-subtree-with-drawer "hello"))
           (state (hermes--rebuild-session-state "resumed-1" marker)))
      (should (eq state hermes--state))
      (should (eq state (hermes--lookup-session-state "resumed-1")))
      (should (equal "resumed-1" (hermes-state-session-id state))))))

(ert-deftest hermes-org-test/resolve-target-returns-stale-pair-for-known-heading ()
  "When the heading carries a `:HERMES_SESSION:' but the registry has
no entry, the resolver returns (sid . nil) so the caller can resume."
  (with-temp-buffer
    (org-mode)
    (hermes-minor-mode 1)
    (insert "* Stale :hermes:
:PROPERTIES:
:HERMES_SESSION: cold-sid
:END:
inside
")
    (re-search-backward "inside")
    (let ((res (hermes--resolve-session-target)))
      (should res)
      (should (equal "cold-sid" (car res)))
      (should (null (cdr res))))))

(ert-deftest hermes-org-test/drain-pre-send-queue-submits-and-clears ()
  "Queued text under SID is submitted via `hermes-input--send-1' and
removed from the alist."
  (with-temp-buffer
    (org-mode)
    (let* ((marker (hermes-org-test--seed-subtree-with-drawer "seed"))
           (state (hermes--rebuild-session-state "resumed-1" marker))
           (submitted nil)
           (hermes--pre-send-queue (list (cons "resumed-1" "queued msg"))))
      (cl-letf (((symbol-function 'hermes-input--send-1)
                 (lambda (text) (push text submitted))))
        (hermes--drain-pre-send-queue "resumed-1"))
      (should (equal '("queued msg") submitted))
      (should (null (assoc "resumed-1" hermes--pre-send-queue)))
      ;; State and registry untouched.
      (should (eq state (hermes--lookup-session-state "resumed-1"))))))

(ert-deftest hermes-org-test/drain-pre-send-queue-noop-when-no-entry ()
  "Calling drain with no entry for SID is a silent no-op."
  (with-temp-buffer
    (org-mode)
    (let ((called nil)
          (hermes--pre-send-queue nil))
      (cl-letf (((symbol-function 'hermes-input--send-1)
                 (lambda (_t) (setq called t))))
        (hermes--drain-pre-send-queue "ghost-sid"))
      (should-not called))))

;;;; v2 parser: hermes--parse-turn-at-point

(require 'hermes-state)
(require 'hermes-render)

(defun hermes-org-test--at-first-turn ()
  "Move point to the first level-2 turn heading.  Assumes the buffer is
loaded with a `* container :hermes:' + `** turn' shape."
  (goto-char (point-min))
  (re-search-forward "^\\*\\* "))

(ert-deftest hermes-org-test/parse-turn-user ()
  "USER turn: kind, timestamp, single text segment from body."
  (hermes-org-test--with-buffer
   "* chat :hermes:
:PROPERTIES:
:HERMES_SESSION: s1
:END:
** U: hello there
:PROPERTIES:
:HERMES_KIND: USER
:HERMES_TIMESTAMP: 2026-05-21T10:00:00+0200
:END:
hello there
"
   (hermes-org-test--at-first-turn)
   (let ((msg (hermes--parse-turn-at-point)))
     (should msg)
     (should (eq 'user (hermes-message-kind msg)))
     (should (equal "2026-05-21T10:00:00+0200" (hermes-message-timestamp msg)))
     (let ((segs (hermes-message-segments msg)))
       (should (= 1 (length segs)))
       (should (eq 'text (hermes-segment-type (aref segs 0))))
       (should (equal "hello there"
                      (hermes-segment-content (aref segs 0))))))))

(ert-deftest hermes-org-test/parse-turn-system ()
  "SYSTEM turn: kind, body text."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** S: boom
:PROPERTIES:
:HERMES_KIND: SYSTEM
:END:
gateway connection lost
"
   (hermes-org-test--at-first-turn)
   (let ((msg (hermes--parse-turn-at-point)))
     (should msg)
     (should (eq 'system (hermes-message-kind msg)))
     (should (equal "gateway connection lost"
                    (hermes-segment-content
                     (aref (hermes-message-segments msg) 0)))))))

(ert-deftest hermes-org-test/parse-turn-assistant ()
  "ASSISTANT turn: Response + Reasoning body text + Tool from meta drawer,
preserving buffer order."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** A: here
:PROPERTIES:
:HERMES_KIND: ASSISTANT
:HERMES_MODEL: m1
:END:
*** Reasoning
:PROPERTIES:
:HERMES_KIND: REASONING
:END:
thinking it through
*** DONE ls (0.5s)
:PROPERTIES:
:HERMES_KIND: TOOL
:TOOL_ID: t1
:END:
listing display
*** Response
:PROPERTIES:
:HERMES_KIND: RESPONSE
:END:
the answer
:HERMES_META:
(:usage nil :tool-calls [(:id \"t1\" :name \"ls\" :status complete :output \"a\\nb\" :duration 0.5)] :images [] :subagents [])
:END:
"
   (hermes-org-test--at-first-turn)
   (let ((msg (hermes--parse-turn-at-point)))
     (should msg)
     (should (eq 'assistant (hermes-message-kind msg)))
     (let ((segs (hermes-message-segments msg)))
       (should (= 3 (length segs)))
       ;; Buffer order: Reasoning, Tool, Response.
       (should (eq 'reasoning (hermes-segment-type (aref segs 0))))
       (should (eq 'tool (hermes-segment-type (aref segs 1))))
       (should (eq 'text (hermes-segment-type (aref segs 2))))
       (should (equal "thinking it through"
                      (hermes-segment-content (aref segs 0))))
       (let ((tool (hermes-segment-content (aref segs 1))))
         (should (hermes-tool-p tool))
         (should (equal "t1" (hermes-tool-id tool)))
         (should (equal "ls" (hermes-tool-name tool)))
         (should (equal "a\nb" (hermes-tool-output tool))))
       (should (equal "the answer"
                      (hermes-segment-content (aref segs 2))))))))

(ert-deftest hermes-org-test/parse-turn-images ()
  "USER turn with images: meta drawer carries the images array."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** U: see this
:PROPERTIES:
:HERMES_KIND: USER
:END:
see this
:HERMES_META:
(:usage nil :tool-calls [] :images [(:path \"/tmp/x.png\" :width 100 :height 50)] :subagents [])
:END:
"
   (hermes-org-test--at-first-turn)
   (let* ((meta (save-excursion (hermes--extract-meta-drawer)))
          (imgs (plist-get meta :images)))
     (should (and (vectorp imgs) (= 1 (length imgs))))
     (should (equal "/tmp/x.png" (plist-get (aref imgs 0) :path))))))

(ert-deftest hermes-org-test/parse-turn-no-meta ()
  "Turn without a :HERMES_META: drawer parses with nil usage and empty subagents."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** U: hi
:PROPERTIES:
:HERMES_KIND: USER
:END:
hi
"
   (hermes-org-test--at-first-turn)
   (let ((msg (hermes--parse-turn-at-point)))
     (should msg)
     (should (null (hermes-message-usage msg)))
     (should (equal [] (hermes-message-subagents msg))))))

(ert-deftest hermes-org-test/parse-turn-edited-text ()
  "If the user edits the Response body, the parser returns the edited text."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** A: x
:PROPERTIES:
:HERMES_KIND: ASSISTANT
:END:
*** Response
:PROPERTIES:
:HERMES_KIND: RESPONSE
:END:
EDITED BY USER
"
   (hermes-org-test--at-first-turn)
   (let* ((msg (hermes--parse-turn-at-point))
          (text (hermes-segment-content
                 (aref (hermes-message-segments msg) 0))))
     (should (equal "EDITED BY USER" text)))))

(ert-deftest hermes-org-test/parse-turn-child-kinds ()
  "Child headings are dispatched by :HERMES_KIND:, not by heading string.
Unknown / missing kinds (e.g. SUBAGENT, plain headings) are skipped."
  (hermes-org-test--with-buffer
   "* chat :hermes:
** A: x
:PROPERTIES:
:HERMES_KIND: ASSISTANT
:END:
*** Foo
:PROPERTIES:
:HERMES_KIND: SUBAGENT
:END:
ignored
*** Response
:PROPERTIES:
:HERMES_KIND: RESPONSE
:END:
visible answer
"
   (hermes-org-test--at-first-turn)
   (let ((msg (hermes--parse-turn-at-point)))
     (should msg)
     (should (= 1 (length (hermes-message-segments msg))))
     (should (equal "visible answer"
                    (hermes-segment-content
                     (aref (hermes-message-segments msg) 0)))))))

(ert-deftest hermes-org-test/parse-subtree-roundtrip-after-renderer ()
  "End-to-end: insert a committed turn via the renderer, then parse it
back via `hermes--parse-turn-at-point' and verify kind + text."
  (require 'hermes-render)
  (require 'hermes-mode)
  (with-temp-buffer
    (hermes-mode)
    (let* ((msg (make-hermes-message
                 :kind 'user
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "ping" :id "s1"))
                 :timestamp "2026-05-21T10:00:00+0200"))
           (old hermes--state)
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg)))))
      (setq hermes--state new)
      (hermes--render old new))
    (let* ((msgs (hermes--parse-buffer-messages))
           (parsed (and (> (length msgs) 0) (aref msgs 0))))
      (should parsed)
      (should (eq 'user (hermes-message-kind parsed)))
      (should (equal "ping"
                     (hermes-segment-content
                      (aref (hermes-message-segments parsed) 0)))))))

;;;; v1→v2 migration

(require 'hermes-migrate)

(defvar hermes--container-level)

(defun hermes-org-test--seed-v1-buffer (raw-body)
  "Insert a container + one v1 USER turn with RAW-BODY in its drawer.
Returns nothing; leaves point at point-min."
  (let ((hermes--container-level 1))
    (erase-buffer)
    (org-mode)
    (insert "* old chat :hermes:
:PROPERTIES:
:HERMES_SESSION: s1
:END:
** U: legacy
" raw-body "
")
    (goto-char (point-min))))

(ert-deftest hermes-org-test/migrate-v1-to-v2-text-only ()
  "Text-only USER turn → properties set, no meta drawer (empty meta)."
  (with-temp-buffer
    (hermes-org-test--seed-v1-buffer
     ":HERMES_RAW:
(:kind user :text \"hi\" :segments [(:type text :content \"hi\" :id \"s1\")] :subagents [] :usage nil :timestamp \"2024-01-15T10:00:00+0000\")
:END:")
    (let ((hermes--container-level 1))
      (hermes-migrate-v1-to-v2))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p ":HERMES_RAW:" body))
      (should-not (string-match-p ":HERMES_META:" body))
      (should (string-match-p ":HERMES_KIND: USER" body))
      (should (string-match-p ":HERMES_TIMESTAMP: 2024-01-15T10:00:00\\+0000" body)))))

(ert-deftest hermes-org-test/migrate-v1-to-v2-with-tools ()
  "Tool segments → meta drawer carries tool-calls."
  (with-temp-buffer
    (hermes-org-test--seed-v1-buffer
     ":HERMES_RAW:
(:kind assistant :segments [(:type tool :content (:id \"t1\" :name \"ls\" :status complete :output \"a\\nb\" :duration 0.5) :id \"sg1\")] :subagents [] :usage nil :timestamp nil)
:END:")
    (let ((hermes--container-level 1))
      (hermes-migrate-v1-to-v2))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p ":HERMES_RAW:" body))
      (should (string-match-p ":HERMES_META:" body))
      (should (string-match-p ":HERMES_KIND: ASSISTANT" body))
      (should (string-match-p ":tool-calls" body))
      (should (string-match-p "\"t1\"" body)))))

(ert-deftest hermes-org-test/migrate-v1-to-v2-with-images ()
  "Image segments → meta drawer carries images array."
  (with-temp-buffer
    (hermes-org-test--seed-v1-buffer
     ":HERMES_RAW:
(:kind user :segments [(:type image :content (:path \"/tmp/x.png\" :name \"x.png\" :width 100 :height 50) :id \"img1\")] :subagents [] :usage nil :timestamp nil)
:END:")
    (let ((hermes--container-level 1))
      (hermes-migrate-v1-to-v2))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p ":HERMES_RAW:" body))
      (should (string-match-p ":HERMES_META:" body))
      (should (string-match-p ":images" body))
      (should (string-match-p "/tmp/x.png" body)))))

(ert-deftest hermes-org-test/migrate-v1-to-v2-with-subagents ()
  "Subagents → meta drawer carries subagents array."
  (with-temp-buffer
    (hermes-org-test--seed-v1-buffer
     ":HERMES_RAW:
(:kind assistant :segments [] :subagents [(:id \"sa1\" :goal \"analyze\" :status complete :thinking nil :tools [] :notes [] :summary \"done\" :duration 1.0)] :usage nil :timestamp nil)
:END:")
    (let ((hermes--container-level 1))
      (hermes-migrate-v1-to-v2))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should-not (string-match-p ":HERMES_RAW:" body))
      (should (string-match-p ":HERMES_META:" body))
      (should (string-match-p ":subagents" body))
      (should (string-match-p "\"sa1\"" body)))))

(ert-deftest hermes-org-test/migrate-v1-to-v2-idempotent ()
  "Running the migration on an already-migrated buffer is a no-op."
  (with-temp-buffer
    (hermes-org-test--seed-v1-buffer
     ":HERMES_RAW:
(:kind assistant :segments [(:type tool :content (:id \"t1\" :name \"ls\" :status complete :output \"x\" :duration 0.1) :id \"sg1\")] :subagents [] :usage nil :timestamp nil)
:END:")
    (let ((hermes--container-level 1))
      (let ((n1 (hermes-migrate-v1-to-v2)))
        (should (= 1 n1)))
      (let ((after-first (buffer-substring-no-properties (point-min) (point-max)))
            (n2 (hermes-migrate-v1-to-v2)))
        (should (= 0 n2))
        ;; Buffer unchanged on second pass.
        (should (equal after-first
                       (buffer-substring-no-properties (point-min) (point-max))))))))

(provide 'hermes-org-test)
;;; hermes-org-test.el ends here
