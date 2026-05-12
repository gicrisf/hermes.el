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

;;;; Tools

(ert-deftest hermes-state-test/tool-generating-adds-to-stream ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))))
         (tools (hermes-stream-tools (hermes-state-stream s))))
    (should (= 1 (length tools)))
    (should (equal "t1"   (hermes-tool-id (aref tools 0))))
    (should (equal "bash" (hermes-tool-name (aref tools 0))))
    (should (eq 'generating (hermes-tool-status (aref tools 0))))))

(ert-deftest hermes-state-test/tool-generating-without-stream-dropped ()
  ;; Edge case #2: tool events with no stream are dropped (turnController.ts:620).
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "tool.generating"
                                      (hermes-test--ht "tool_id" "t1"
                                                       "name" "bash")))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/tool-generating-deduplicates ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))))
         (tools (hermes-stream-tools (hermes-state-stream s))))
    (should (= 1 (length tools)))))

(ert-deftest hermes-state-test/tool-complete-updates-status ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1"
                                    "output" "file1\nfile2"
                                    "duration_s" 2.3))))
         (tool (aref (hermes-stream-tools (hermes-state-stream s)) 0)))
    (should (eq 'complete (hermes-tool-status tool)))
    (should (equal "file1\nfile2" (hermes-tool-output tool)))
    (should (equal 2.3 (hermes-tool-duration tool)))))

(ert-deftest hermes-state-test/tool-complete-with-error-marks-error ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1" "error" "kaboom"))))
         (tool (aref (hermes-stream-tools (hermes-state-stream s)) 0)))
    (should (eq 'error (hermes-tool-status tool)))
    (should (equal "kaboom" (hermes-tool-error tool)))))

(ert-deftest hermes-state-test/tool-complete-without-matching-tool-noop ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "tool.complete"
                                      (hermes-test--ht "tool_id" "ghost"
                                                       "output" "?")))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/tools-commit-with-message ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "ok"))
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1" "output" "done"))
             (cons "message.complete" nil)))
         (msg (hermes-test--last-msg s)))
    (should (null (hermes-state-stream s)))
    (should (eq 'assistant (hermes-message-kind msg)))
    (should (= 1 (length (hermes-message-tools msg))))
    (should (eq 'complete (hermes-tool-status (aref (hermes-message-tools msg) 0))))))

;;;; Blocking prompts

(ert-deftest hermes-state-test/approval-request-sets-pending ()
  (let* ((s (hermes--reduce nil
                            (cons "approval.request"
                                  (hermes-test--ht "request_id" "r1"
                                                   "command" "ls"))))
         (pend (hermes-state-pending s)))
    (should (hermes-pending-p pend))
    (should (eq 'approval (hermes-pending-kind pend)))
    (should (equal "r1" (hermes-pending-request-id pend)))))

(ert-deftest hermes-state-test/second-pending-replaces-first ()
  ;; Edge case #3: single overlay slot (createGatewayEventHandler.ts:519).
  (let* ((s1 (hermes--reduce nil
                             (cons "approval.request"
                                   (hermes-test--ht "request_id" "r1"))))
         (s2 (hermes--reduce s1
                             (cons "clarify.request"
                                   (hermes-test--ht "request_id" "r2"
                                                    "question" "?"))))
         (pend (hermes-state-pending s2)))
    (should (eq 'clarify (hermes-pending-kind pend)))
    (should (equal "r2" (hermes-pending-request-id pend)))))

(ert-deftest hermes-state-test/pending-clear-resets-slot ()
  (let* ((s1 (hermes--reduce nil
                             (cons "approval.request"
                                   (hermes-test--ht "request_id" "r1"))))
         (s2 (hermes--reduce s1 '(:pending-clear))))
    (should (null (hermes-state-pending s2)))))

(ert-deftest hermes-state-test/pending-clear-when-empty-is-noop ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 '(:pending-clear))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/sudo-and-secret-request-set-pending ()
  (let* ((s1 (hermes--reduce nil
                             (cons "sudo.request"
                                   (hermes-test--ht "request_id" "s1"))))
         (s2 (hermes--reduce nil
                             (cons "secret.request"
                                   (hermes-test--ht "request_id" "s2"
                                                    "env_var" "OPENAI_KEY")))))
    (should (eq 'sudo   (hermes-pending-kind (hermes-state-pending s1))))
    (should (eq 'secret (hermes-pending-kind (hermes-state-pending s2))))))

;;;; UI reducer for tools

(ert-deftest hermes-state-test/ui-tool-progress-updates-preview ()
  (let* ((s1 (hermes--ui-reduce nil
                                (cons "tool.progress"
                                      (hermes-test--ht "tool_id" "t1"
                                                       "preview" "ls /tmp"))))
         (s2 (hermes--ui-reduce s1
                                (cons "tool.progress"
                                      (hermes-test--ht "tool_id" "t1"
                                                       "preview" "ls /var")))))
    (should (equal "ls /var"
                   (alist-get "t1" (hermes-ui-state-tool-previews s2)
                              nil nil #'equal)))))

(ert-deftest hermes-state-test/ui-tool-complete-clears-preview ()
  (let* ((s1 (hermes--ui-reduce nil
                                (cons "tool.progress"
                                      (hermes-test--ht "tool_id" "t1"
                                                       "preview" "ls"))))
         (s2 (hermes--ui-reduce s1
                                (cons "tool.complete"
                                      (hermes-test--ht "tool_id" "t1")))))
    (should (null (alist-get "t1" (hermes-ui-state-tool-previews s2)
                             nil nil #'equal)))))

(ert-deftest hermes-state-test/ui-tool-generating-sets-status ()
  (let ((s (hermes--ui-reduce nil
                              (cons "tool.generating"
                                    (hermes-test--ht "tool_id" "t1"
                                                     "name" "bash")))))
    (should (equal "Running bash…" (hermes-ui-state-status-text s)))))

(provide 'hermes-state-test)
;;; hermes-state-test.el ends here
