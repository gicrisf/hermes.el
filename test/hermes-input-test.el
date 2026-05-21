;;; hermes-input-test.el --- Tests for the input queue + drain -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'hermes-state)
(require 'hermes-input)
(require 'hermes-mode)

(defvar hermes-input-test--rpc-calls nil
  "Captured (METHOD . PARAMS) pairs from stubbed `hermes-rpc-request'.")

(defun hermes-input-test--stub-rpc (method params &optional _cb)
  (push (cons method params) hermes-input-test--rpc-calls))

(defmacro hermes-input-test--with-buffer (&rest body)
  "Run BODY in a fresh Hermes buffer with RPC stubbed and a session id set."
  (declare (indent 0))
  `(let ((hermes-input-test--rpc-calls nil))
     (cl-letf (((symbol-function 'hermes-rpc-request)
                #'hermes-input-test--stub-rpc)
               ((symbol-function 'hermes-rpc-live-p)
                (lambda () t)))
       (with-temp-buffer
         (hermes-mode)
         (hermes-dispatch (cons "session.ready"
                                (let ((h (make-hash-table :test 'equal)))
                                  (puthash "session_id" "sess-1" h)
                                  h)))
         (setq hermes--state
               (hermes--with-copy hermes--state hermes-state-copy s
                 (setf (hermes-state-session-id s) "sess-1")))
         ,@body))))

(defun hermes-input-test--buffer-has-user-heading-p (text)
  "Return non-nil if the current buffer contains a `** U: TEXT …' heading."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (format "^\\*\\* U: %s" (regexp-quote text)) nil t)))

(defun hermes-input-test--set-stream ()
  "Simulate an in-flight stream on the current buffer's state."
  (setq hermes--state
        (hermes--with-copy hermes--state hermes-state-copy s
          (setf (hermes-state-stream s)
                (make-hermes-stream :segments [] :tools [])))))

;;;; Idle path

(ert-deftest hermes-input-test/send-idle-commits-immediately ()
  "When no stream is in flight, the user message appears in the buffer
and `prompt.submit' is sent right away."
  (hermes-input-test--with-buffer
    (hermes-send "hi")
    (should (hermes-input-test--buffer-has-user-heading-p "hi"))
    (should (= 1 (length hermes-input-test--rpc-calls)))
    (should (equal "prompt.submit"
                   (car (car hermes-input-test--rpc-calls))))
    (should (null (hermes-state-queue hermes--state)))))

;;;; Busy path — invisible queue, no optimistic commit

(ert-deftest hermes-input-test/send-busy-queues-only ()
  "While streaming: message enters the queue but is NOT rendered, and
no RPC is sent yet."
  (hermes-input-test--with-buffer
    (hermes-input-test--set-stream)
    (hermes-send "and?")
    (should-not (hermes-input-test--buffer-has-user-heading-p "and?"))
    (should (null hermes-input-test--rpc-calls))
    (should (equal '("and?") (hermes-state-queue hermes--state)))))

(ert-deftest hermes-input-test/send-busy-multiple-keeps-fifo ()
  "Three messages sent while busy stay queued in arrival order."
  (hermes-input-test--with-buffer
    (hermes-input-test--set-stream)
    (hermes-send "one")
    (hermes-send "two")
    (hermes-send "three")
    (should-not (hermes-input-test--buffer-has-user-heading-p "one"))
    (should-not (hermes-input-test--buffer-has-user-heading-p "two"))
    (should-not (hermes-input-test--buffer-has-user-heading-p "three"))
    (should (null hermes-input-test--rpc-calls))
    (should (equal '("one" "two" "three")
                   (hermes-state-queue hermes--state)))))

;;;; Drain — turn ends, head of queue is displayed + sent

(ert-deftest hermes-input-test/drain-sends-queued-head ()
  "When the stream transitions to nil with a non-empty queue, the head
is rendered, removed from the queue, and submitted via RPC."
  (hermes-input-test--with-buffer
    (hermes-input-test--set-stream)
    (hermes-send "queued")
    (let ((old hermes--state))
      (setq hermes--state
            (hermes--with-copy hermes--state hermes-state-copy s
              (setf (hermes-state-stream s) nil)))
      (hermes-input--drain old hermes--state))
    (should (hermes-input-test--buffer-has-user-heading-p "queued"))
    (should (null (hermes-state-queue hermes--state)))
    (should (= 1 (length hermes-input-test--rpc-calls)))
    (should (equal "prompt.submit"
                   (car (car hermes-input-test--rpc-calls))))))

(ert-deftest hermes-input-test/drain-fifo-order ()
  "Each `message.complete' drains one item; oldest first."
  (hermes-input-test--with-buffer
    (hermes-input-test--set-stream)
    (hermes-send "a")
    (hermes-send "b")
    ;; Tick 1: stream → nil.
    (let ((old hermes--state))
      (setq hermes--state
            (hermes--with-copy hermes--state hermes-state-copy s
              (setf (hermes-state-stream s) nil)))
      (hermes-input--drain old hermes--state))
    (should (equal '("b") (hermes-state-queue hermes--state)))
    (should (hermes-input-test--buffer-has-user-heading-p "a"))
    (should-not (hermes-input-test--buffer-has-user-heading-p "b"))
    ;; Tick 2: a new stream starts and clears, draining "b".
    (hermes-input-test--set-stream)
    (let ((old hermes--state))
      (setq hermes--state
            (hermes--with-copy hermes--state hermes-state-copy s
              (setf (hermes-state-stream s) nil)))
      (hermes-input--drain old hermes--state))
    (should (null (hermes-state-queue hermes--state)))
    (should (hermes-input-test--buffer-has-user-heading-p "b"))))

;;;; History seed

(defun hermes-input-test--mk-user (text)
  (make-hermes-message
   :kind 'user
   :segments (vector (make-hermes-segment :type 'text :content text :id "s"))
   :timestamp "2026-05-17T00:00:00+0000"))

(ert-deftest hermes-input-test/build-history-truncates-to-last-n ()
  "`hermes--build-history-text' caps to the last N turns and notes truncation."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda ()
               (vector (hermes-input-test--mk-user "turn 0")
                       (hermes-input-test--mk-user "turn 1")
                       (hermes-input-test--mk-user "turn 2")
                       (hermes-input-test--mk-user "turn 3")
                       (hermes-input-test--mk-user "turn 4")))))
    (let* ((hermes-history-seed-max-turns 2)
           (text (hermes--build-history-text)))
      (should text)
      (should (string-match-p "last 2 turns of 5" text))
      (should (string-match-p "turn 3" text))
      (should (string-match-p "turn 4" text))
      (should-not (string-match-p "turn 0" text))
      (should-not (string-match-p "turn 1" text))
      (should-not (string-match-p "turn 2" text))
      (should (string-match-p "Current: \\'" text)))))

(ert-deftest hermes-input-test/build-history-nil-when-empty ()
  "Builder returns nil when the buffer has no committed turns."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda () [])))
    (should-not (hermes--build-history-text))))

(ert-deftest hermes-input-test/seed-prepended-and-sid-stamped-on-send ()
  "An idle `prompt.submit' against an un-seeded session prefixes the
wire text with history and stamps `hermes--seeded-session-id'."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda () (vector (hermes-input-test--mk-user "hi"))))
            ((symbol-function 'hermes--buffer-message-count)
             (lambda () 1)))
    (hermes-input-test--with-buffer
      (setq hermes--seeded-session-id nil)
      (hermes-send "hello")
      (should (equal "sess-1" hermes--seeded-session-id))
      (let* ((call (car hermes-input-test--rpc-calls))
             (wire (plist-get (cdr call) :text)))
        (should (equal "prompt.submit" (car call)))
        (should (stringp wire))
        (should (string-match-p "User: hi" wire))
        (should (string-match-p "Current: hello\\'" wire))))))

(ert-deftest hermes-input-test/seed-skipped-after-sid-already-stamped ()
  "When `hermes--seeded-session-id' already matches the current session,
the wire text is verbatim — no second seeding."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda () (vector (hermes-input-test--mk-user "hi"))))
            ((symbol-function 'hermes--buffer-message-count)
             (lambda () 1)))
    (hermes-input-test--with-buffer
      (setq hermes--seeded-session-id "sess-1")
      (hermes-send "hello")
      (let* ((call (car hermes-input-test--rpc-calls))
             (wire (plist-get (cdr call) :text)))
        (should (equal "prompt.submit" (car call)))
        (should (equal "hello" wire))))))

(ert-deftest hermes-input-test/slash-command-leaves-sid-unstamped ()
  "Slash commands take the `slash.exec' path and never touch
`hermes--seeded-session-id', so the next real prompt still seeds."
  (hermes-input-test--with-buffer
    (setq hermes--seeded-session-id nil)
    (hermes-send "/clear")
    (should (null hermes--seeded-session-id))
    (let ((call (car hermes-input-test--rpc-calls)))
      (should (equal "slash.exec" (car call))))))

(ert-deftest hermes-input-test/empty-buffer-stamps-sid-without-prefix ()
  "Un-seeded session against a buffer with no committed turns: no
prefix is added, but the sid is stamped so we don't re-check on
every send for the lifetime of the session."
  (cl-letf (((symbol-function 'hermes--buffer-message-count)
             (lambda () 0)))
    (hermes-input-test--with-buffer
      (setq hermes--seeded-session-id nil)
      (hermes-send "hello")
      (should (equal "sess-1" hermes--seeded-session-id))
      (let* ((call (car hermes-input-test--rpc-calls))
             (wire (plist-get (cdr call) :text)))
        (should (equal "prompt.submit" (car call)))
        (should (equal "hello" wire))))))

(ert-deftest hermes-input-test/drain-after-reconnect-seeds-once ()
  "Post-reconnect drain submits the queued head with the seed prefix
when the new session hasn't been stamped yet, and stamps it."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda () (vector (hermes-input-test--mk-user "hi"))))
            ((symbol-function 'hermes--buffer-message-count)
             (lambda () 1)))
    (hermes-input-test--with-buffer
      (setq hermes--seeded-session-id nil
            hermes--state
            (hermes--with-copy hermes--state hermes-state-copy s
              (setf (hermes-state-queue s) '("queued-1"))))
      (hermes-input--drain-after-reconnect)
      (should (equal "sess-1" hermes--seeded-session-id))
      (let* ((call (car hermes-input-test--rpc-calls))
             (wire (plist-get (cdr call) :text)))
        (should (equal "prompt.submit" (car call)))
        (should (string-match-p "User: hi" wire))
        (should (string-match-p "Current: queued-1\\'" wire))))))

;;;; CAPF metadata

(defun hermes-input-test--fake-catalog ()
  "Return a fake slash catalog hash with one entry."
  (let ((h (make-hash-table :test 'equal)))
    (puthash "pairs" (vector (vector "/clear" "Clear conversation history")) h)
    h))

(ert-deftest hermes-input-test/capf-returns-doc-buffer-function ()
  "`hermes-input--slash-complete' returns a plist with `:company-doc-buffer'."
  (let* ((catalog (hermes-input-test--fake-catalog))
         (result (hermes-input--slash-complete 1 5 catalog)))
    (should result)
    (should (functionp (plist-get (nthcdr 3 result) :company-doc-buffer)))
    (should (functionp (plist-get (nthcdr 3 result) :annotation-function)))
    (should (member "/clear" (nth 2 result)))))

(ert-deftest hermes-input-test/doc-buffer-contains-description ()
  "Doc buffer contains the candidate name and description."
  (let* ((catalog (hermes-input-test--fake-catalog))
         (buf (hermes-input--slash-doc-buffer "/clear" catalog)))
    (should (bufferp buf))
    (should (equal " *hermes-slash-doc*" (buffer-name buf)))
    (with-current-buffer buf
      (should (string-match-p "/clear" (buffer-string)))
      (should (string-match-p "Clear conversation history" (buffer-string))))))

(ert-deftest hermes-input-test/doc-buffer-nil-for-unknown ()
  "Doc buffer is nil for unknown candidate."
  (let ((catalog (hermes-input-test--fake-catalog)))
    (should-not (hermes-input--slash-doc-buffer "/nonexistent" catalog))))

(ert-deftest hermes-input-test/minibuffer-capf-still-works ()
  "Minibuffer CAPF still produces candidates + annotation."
  (let ((hermes-input--catalog-from-minibuffer (hermes-input-test--fake-catalog)))
    (with-temp-buffer
      (insert "/cle")
      (let ((result (hermes-input-completion-at-point)))
        (should result)
        (should (member "/clear" (nth 2 result)))
        (let ((ann (plist-get (nthcdr 3 result) :annotation-function)))
          (should (functionp ann))
          (should (equal " — Clear conversation history"
                         (funcall ann "/clear"))))))))

;;;; Session-management slash interception

(ert-deftest hermes-input-test/session-slash-regex-matches ()
  (should (string-match hermes-input--session-slash-re "/resume"))
  (should (string-match hermes-input--session-slash-re "/sessions"))
  (should (string-match hermes-input--session-slash-re "/delete"))
  (should (string-match hermes-input--session-slash-re "/resume my-project"))
  (should-not (string-match hermes-input--session-slash-re "/title hello"))
  (should-not (string-match hermes-input--session-slash-re "/save"))
  (should-not (string-match hermes-input--session-slash-re "/branch"))
  (should-not (string-match hermes-input--session-slash-re "/clear"))
  (should-not (string-match hermes-input--session-slash-re "/resumesomething")))

(ert-deftest hermes-input-test/try-session-slash-dispatches ()
  (let ((called nil))
    (cl-letf (((symbol-function 'call-interactively)
               (lambda (cmd) (push cmd called))))
      (should (hermes-input--try-session-slash "/resume"))
      (should (hermes-input--try-session-slash "/sessions"))
      (should (hermes-input--try-session-slash "/delete"))
      (should-not (hermes-input--try-session-slash "/title hi"))
      (should (equal '(hermes-stored-delete
                       hermes-current-sessions
                       hermes-stored-resume)
                     called)))))

(ert-deftest hermes-input-test/intercepted-slash-skips-slash-exec ()
  "`/resume' must NOT reach `slash.exec' — the picker handles it locally."
  (hermes-input-test--with-buffer
    (cl-letf (((symbol-function 'call-interactively)
               (lambda (_cmd) nil)))
      (hermes-send "/resume"))
    (should (null hermes-input-test--rpc-calls))))

(ert-deftest hermes-input-test/non-intercepted-slash-still-goes-to-server ()
  "`/title hello' is server-side — must hit `slash.exec' as usual."
  (hermes-input-test--with-buffer
    (hermes-send "/title hello")
    (let ((call (car hermes-input-test--rpc-calls)))
      (should (equal "slash.exec" (car call)))
      (should (equal "title hello" (plist-get (cdr call) :command))))))

(provide 'hermes-input-test)
;;; hermes-input-test.el ends here
