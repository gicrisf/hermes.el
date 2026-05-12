;;; hermes-state-test.el --- ERT tests for the reducer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)

;;;; Helpers

(defun hermes-test--ht (&rest kvs)
  "Build a hash-table from KVS, a flat plist-style list of \"key\" \"value\"."
  (let ((h (make-hash-table :test 'equal)))
    (while kvs
      (puthash (pop kvs) (pop kvs) h))
    h))

(defun hermes-test--reduce* (state &rest msgs)
  "Fold STATE through MSGS via `hermes--reduce'."
  (dolist (m msgs state) (setq state (hermes--reduce state m))))

(defun hermes-test--last-msg (state)
  "Return the last `hermes-message' in STATE."
  (let ((v (hermes-state-messages state)))
    (aref v (1- (length v)))))

;;;; Connection transitions

(ert-deftest hermes-state-test/initial ()
  (let ((s (hermes--reduce nil '(:noop))))
    (should (eq 'disconnected (hermes-state-connection s)))
    (should (null (hermes-state-stream s)))
    (should (equal [] (hermes-state-messages s)))))

(ert-deftest hermes-state-test/connection-transitions ()
  (let* ((s0 (hermes--reduce nil '(:connecting)))
         (s1 (hermes--reduce s0 '(:connected)))
         (s2 (hermes--reduce s1 '(:disconnected))))
    (should (eq 'connecting   (hermes-state-connection s0)))
    (should (eq 'connected    (hermes-state-connection s1)))
    (should (eq 'disconnected (hermes-state-connection s2)))))

;;;; gateway.ready / session.info

(ert-deftest hermes-state-test/gateway-ready-sets-connected-and-skin ()
  (let* ((p (hermes-test--ht "skin" "default"))
         (s (hermes--reduce nil (cons "gateway.ready" p))))
    (should (eq 'connected (hermes-state-connection s)))
    (should (equal "default" (hermes-state-skin s)))))

(ert-deftest hermes-state-test/session-info-stores-id-and-info ()
  (let* ((p (hermes-test--ht "session_id" "abc" "model" "opus"))
         (s (hermes--reduce nil (cons "session.info" p))))
    (should (equal "abc" (hermes-state-session-id s)))
    (should (equal "opus" (gethash "model" (hermes-state-session-info s))))))

(ert-deftest hermes-state-test/session-info-merges-on-re-emit ()
  ;; Mirrors createGatewayEventHandler.ts:279-292: spread, don't replace.
  (let* ((p1 (hermes-test--ht "session_id" "abc" "model" "opus" "cwd" "/tmp"))
         (s1 (hermes--reduce nil (cons "session.info" p1)))
         (p2 (hermes-test--ht "model" "sonnet"))
         (s2 (hermes--reduce s1 (cons "session.info" p2)))
         (info (hermes-state-session-info s2)))
    (should (equal "sonnet" (gethash "model" info)))
    (should (equal "/tmp"   (gethash "cwd"   info)))
    (should (equal "abc"    (hermes-state-session-id s2)))))

;;;; User submit (optimistic)

(ert-deftest hermes-state-test/user-submit-appends-message ()
  (let* ((s (hermes--reduce nil (cons :user-submit '(:text "hi"))))
         (m (hermes-test--last-msg s)))
    (should (= 1 (length (hermes-state-messages s))))
    (should (eq 'user (hermes-message-kind m)))
    (should (equal "hi" (hermes-message-text m)))))

;;;; Stream lifecycle

(ert-deftest hermes-state-test/message-start-creates-empty-stream ()
  (let ((s (hermes--reduce nil (cons "message.start" nil))))
    (should (hermes-stream-p (hermes-state-stream s)))
    (should (equal "" (hermes-stream-text (hermes-state-stream s))))
    (should (equal "" (hermes-stream-thinking (hermes-state-stream s))))
    (should (equal "" (hermes-stream-reasoning (hermes-state-stream s))))))

(ert-deftest hermes-state-test/message-start-discards-in-flight ()
  ;; Edge case #1: turnController.ts:746-757 silently discards.
  (let* ((s1 (hermes--reduce nil (cons "message.start" nil)))
         (s2 (hermes--reduce s1 (cons "message.delta"
                                      (hermes-test--ht "text" "stale"))))
         (s3 (hermes--reduce s2 (cons "message.start" nil))))
    (should (equal "" (hermes-stream-text (hermes-state-stream s3))))))

(ert-deftest hermes-state-test/message-delta-accumulates ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "message.delta"
                                      (hermes-test--ht "text" "Hello"))))
         (s2 (hermes--reduce s1 (cons "message.delta"
                                      (hermes-test--ht "text" " world")))))
    (should (equal "Hello world"
                   (hermes-stream-text (hermes-state-stream s2))))))

(ert-deftest hermes-state-test/thinking-and-reasoning-accumulate ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "thinking.delta"
                                      (hermes-test--ht "text" "think "))))
         (s2 (hermes--reduce s1 (cons "thinking.delta"
                                      (hermes-test--ht "text" "more"))))
         (s3 (hermes--reduce s2 (cons "reasoning.delta"
                                      (hermes-test--ht "text" "why")))))
    (should (equal "think more"
                   (hermes-stream-thinking (hermes-state-stream s3))))
    (should (equal "why"
                   (hermes-stream-reasoning (hermes-state-stream s3))))))

(ert-deftest hermes-state-test/message-complete-commits-and-clears ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hi"))
             (cons "message.complete" nil)))
         (m (hermes-test--last-msg s)))
    (should (null (hermes-state-stream s)))
    (should (eq 'assistant (hermes-message-kind m)))
    (should (equal "Hi" (hermes-message-text m)))))

(ert-deftest hermes-state-test/message-complete-without-stream-is-noop ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "message.complete" nil))))
    (should (eq s0 s1))))

;;;; Errors

(ert-deftest hermes-state-test/error-event-appends-system-message ()
  (let* ((s (hermes--reduce nil
                            (cons "error"
                                  (hermes-test--ht "message" "boom"))))
         (m (hermes-test--last-msg s)))
    (should (eq 'system (hermes-message-kind m)))
    (should (equal "boom" (hermes-message-text m)))))

;;;; Purity — old state is never mutated

(ert-deftest hermes-state-test/reducer-is-pure ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s0-snapshot (hermes-stream-text (hermes-state-stream s0)))
         (_  (hermes--reduce s0 (cons "message.delta"
                                      (hermes-test--ht "text" "leak?")))))
    (should (equal s0-snapshot
                   (hermes-stream-text (hermes-state-stream s0))))))

(ert-deftest hermes-state-test/reducer-returns-same-state-for-unknown-type ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "voice.transcript" nil))))
    (should (eq s0 s1))))

;;;; End-to-end fold

(ert-deftest hermes-state-test/full-turn-end-to-end ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "gateway.ready" (hermes-test--ht "skin" "default"))
             (cons "session.info"
                   (hermes-test--ht "session_id" "abc" "model" "opus"))
             (cons :user-submit '(:text "say hi"))
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hello"))
             (cons "message.delta" (hermes-test--ht "text" " world"))
             (cons "message.complete" nil))))
    (should (eq 'connected (hermes-state-connection s)))
    (should (equal "abc" (hermes-state-session-id s)))
    (should (= 2 (length (hermes-state-messages s))))
    (should (eq 'user      (hermes-message-kind (aref (hermes-state-messages s) 0))))
    (should (eq 'assistant (hermes-message-kind (aref (hermes-state-messages s) 1))))
    (should (equal "Hello world"
                   (hermes-message-text (aref (hermes-state-messages s) 1))))
    (should (null (hermes-state-stream s)))))

;;;; UI reducer

(ert-deftest hermes-state-test/ui-status-update ()
  (let* ((s (hermes--ui-reduce nil
                               (cons "status.update"
                                     (hermes-test--ht "kind" "info"
                                                      "text" "Working…")))))
    (should (equal "Working…" (hermes-ui-state-status-text s)))
    (should (equal "info"     (hermes-ui-state-status-kind s)))))

(ert-deftest hermes-state-test/ui-message-start-and-complete ()
  (let* ((s1 (hermes--ui-reduce nil (cons "message.start" nil)))
         (s2 (hermes--ui-reduce s1 (cons "message.complete" nil))))
    (should (equal "Responding…" (hermes-ui-state-status-text s1)))
    (should (null (hermes-ui-state-status-text s2)))))

(provide 'hermes-state-test)
;;; hermes-state-test.el ends here
