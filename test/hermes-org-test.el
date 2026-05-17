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
  "Insert a container + one turn with a `:HERMES_RAW:' drawer for TEXT
and return a marker at the container heading."
  (insert (format "* Resumed chat :hermes:
:PROPERTIES:
:HERMES_SESSION: resumed-1
:END:
** %s :user:
%s
:HERMES_RAW:
(:kind user :text \"%s\" :segments [(:type text :content \"%s\" :id \"s1\")] :subagents [] :usage nil :timestamp \"2024-01-15T10:00:00+0000\")
:END:
" text text text text))
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^\\* Resumed chat")
    (beginning-of-line)
    (copy-marker (point) nil)))

(ert-deftest hermes-org-test/parse-subtree-messages-collects-drawer-content ()
  "`hermes--parse-subtree-messages' returns one message per `:HERMES_RAW:'
drawer in the current heading's subtree."
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

(provide 'hermes-org-test)
;;; hermes-org-test.el ends here
