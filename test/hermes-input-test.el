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
  "Return non-nil if the current buffer contains a `** TEXT … :user:' heading."
  (save-excursion
    (goto-char (point-min))
    (re-search-forward (format "^\\*\\* %s.*:user:" (regexp-quote text)) nil t)))

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
    (hermes-input-send "hi")
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
    (hermes-input-send "and?")
    (should-not (hermes-input-test--buffer-has-user-heading-p "and?"))
    (should (null hermes-input-test--rpc-calls))
    (should (equal '("and?") (hermes-state-queue hermes--state)))))

(ert-deftest hermes-input-test/send-busy-multiple-keeps-fifo ()
  "Three messages sent while busy stay queued in arrival order."
  (hermes-input-test--with-buffer
    (hermes-input-test--set-stream)
    (hermes-input-send "one")
    (hermes-input-send "two")
    (hermes-input-send "three")
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
    (hermes-input-send "queued")
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
    (hermes-input-send "a")
    (hermes-input-send "b")
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

(ert-deftest hermes-input-test/seed-prepended-and-flag-cleared-on-send ()
  "Idle `prompt.submit' picks up the seed, prefixes the wire text, and
clears the one-shot flag."
  (cl-letf (((symbol-function 'hermes--parse-buffer-messages)
             (lambda () (vector (hermes-input-test--mk-user "hi")))))
    (hermes-input-test--with-buffer
      (setq hermes--pending-history-seed t)
      (hermes-input-send "hello")
      (should-not hermes--pending-history-seed)
      (let* ((call (car hermes-input-test--rpc-calls))
             (wire (plist-get (cdr call) :text)))
        (should (equal "prompt.submit" (car call)))
        (should (stringp wire))
        (should (string-match-p "User: hi" wire))
        (should (string-match-p "Current: hello\\'" wire))))))

(ert-deftest hermes-input-test/slash-command-does-not-consume-seed ()
  "Slash commands take the `slash.exec' path and must leave the flag
armed so the next real prompt still gets seeded."
  (hermes-input-test--with-buffer
    (setq hermes--pending-history-seed t)
    (hermes-input-send "/clear")
    (should hermes--pending-history-seed)
    (let ((call (car hermes-input-test--rpc-calls)))
      (should (equal "slash.exec" (car call))))))

(ert-deftest hermes-input-test/no-seed-no-prefix ()
  "When the flag is nil, `prompt.submit' carries the user's text verbatim."
  (hermes-input-test--with-buffer
    (setq hermes--pending-history-seed nil)
    (hermes-input-send "hello")
    (let* ((call (car hermes-input-test--rpc-calls))
           (wire (plist-get (cdr call) :text)))
      (should (equal "prompt.submit" (car call)))
      (should (equal "hello" wire)))))

(provide 'hermes-input-test)
;;; hermes-input-test.el ends here
