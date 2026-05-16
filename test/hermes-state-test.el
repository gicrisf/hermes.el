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

(defun hermes-test--last-pending (state)
  "Return the last `hermes-message' pushed into pending-turns."
  (let ((v (hermes-state-pending-turns state)))
    (and (vectorp v) (> (length v) 0)
         (aref v (1- (length v))))))

(defun hermes-test--seg-text (msg)
  "Concatenate text-segment content from MSG."
  (let ((segs (hermes-message-segments msg))
        parts)
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let ((s (aref segs i)))
          (when (eq 'text (hermes-segment-type s))
            (push (or (hermes-segment-content s) "") parts)))))
    (apply #'concat (nreverse parts))))

;;;; Connection transitions

(ert-deftest hermes-state-test/initial ()
  (let ((s (hermes--reduce nil '(:noop))))
    (should (eq 'disconnected (hermes-state-connection s)))
    (should (null (hermes-state-stream s)))
    (should (equal [] (hermes-state-pending-turns s)))))

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
  (let* ((p1 (hermes-test--ht "session_id" "abc" "model" "opus" "cwd" "/tmp"))
         (s1 (hermes--reduce nil (cons "session.info" p1)))
         (p2 (hermes-test--ht "model" "sonnet"))
         (s2 (hermes--reduce s1 (cons "session.info" p2)))
         (info (hermes-state-session-info s2)))
    (should (equal "sonnet" (gethash "model" info)))
    (should (equal "/tmp"   (gethash "cwd"   info)))
    (should (equal "abc"    (hermes-state-session-id s2)))))

(ert-deftest hermes-state-test/session-info-merges-usage ()
  (let* ((p (hermes-test--ht "usage" (hermes-test--ht "tokens_sent" 100)))
         (s (hermes--reduce nil (cons "session.info" p)))
         (usage (hermes-state-usage s)))
    (should (hash-table-p usage))
    (should (= 100 (gethash "tokens_sent" usage)))))

;;;; User submit (optimistic) — pushes to pending-turns

(ert-deftest hermes-state-test/user-submit-pushes-pending-turn ()
  (let* ((s (hermes--reduce nil (cons :user-submit '(:text "hi"))))
         (m (hermes-test--last-pending s)))
    (should (= 1 (length (hermes-state-pending-turns s))))
    (should (eq 'user (hermes-message-kind m)))
    (should (equal "hi" (hermes-test--seg-text m)))))

(ert-deftest hermes-state-test/pending-turns-clear ()
  (let* ((s0 (hermes--reduce nil (cons :user-submit '(:text "hi"))))
         (s1 (hermes--reduce s0 '(:pending-turns-clear))))
    (should (equal [] (hermes-state-pending-turns s1)))))

;;;; Stream lifecycle

(ert-deftest hermes-state-test/message-start-creates-empty-stream ()
  (let ((s (hermes--reduce nil (cons "message.start" nil))))
    (should (hermes-stream-p (hermes-state-stream s)))
    (let ((segs (hermes-stream-segments (hermes-state-stream s))))
      (should (vectorp segs))
      (should (= 0 (length segs))))))

(ert-deftest hermes-state-test/message-start-discards-in-flight ()
  (let* ((s1 (hermes--reduce nil (cons "message.start" nil)))
         (s2 (hermes--reduce s1 (cons "message.delta"
                                      (hermes-test--ht "text" "stale"))))
         (s3 (hermes--reduce s2 (cons "message.start" nil))))
    (should (= 0 (length (hermes-stream-segments (hermes-state-stream s3)))))))

(ert-deftest hermes-state-test/message-delta-accumulates ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "message.delta"
                                      (hermes-test--ht "text" "Hello"))))
         (s2 (hermes--reduce s1 (cons "message.delta"
                                      (hermes-test--ht "text" " world")))))
    (let* ((segs (hermes-stream-segments (hermes-state-stream s2)))
           (seg (aref segs 0)))
      (should (= 1 (length segs)))
      (should (eq 'text (hermes-segment-type seg)))
      (should (equal "Hello world" (hermes-segment-content seg))))))

(ert-deftest hermes-state-test/thinking-and-reasoning-accumulate ()
  "Reasoning deltas still accumulate as a stream segment.
Thinking deltas no longer touch the persistent stream — see UI reducer tests."
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "reasoning.delta"
                                      (hermes-test--ht "text" "why")))))
    (let ((segs (hermes-stream-segments (hermes-state-stream s1))))
      (should (= 1 (length segs)))
      (should (eq 'reasoning (hermes-segment-type (aref segs 0))))
      (should (equal "why" (hermes-segment-content (aref segs 0)))))))

(ert-deftest hermes-state-test/thinking-delta-does-not-touch-persistent-stream ()
  "thinking.delta is UI-only; the persistent reducer ignores it."
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "thinking.delta"
                                      (hermes-test--ht "text" "hmm")))))
    (should (equal s0 s1))))

(ert-deftest hermes-state-test/reasoning-delta-suppressed-when-duplicate-of-text ()
  "A `reasoning.delta' whose payload equals the prior text segment is dropped."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hello"))
             (cons "reasoning.delta" (hermes-test--ht "text" "Hello"))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))
    (should (equal "Hello" (hermes-segment-content (aref segs 0))))))

(ert-deftest hermes-state-test/reasoning-delta-suppressed-when-duplicate-of-reasoning ()
  "A `reasoning.delta' identical to the prior reasoning segment is dropped."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "reasoning.delta" (hermes-test--ht "text" "A"))
             (cons "reasoning.delta" (hermes-test--ht "text" "A"))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))
    (should (eq 'reasoning (hermes-segment-type (aref segs 0))))
    (should (equal "A" (hermes-segment-content (aref segs 0))))))

(ert-deftest hermes-state-test/reasoning-delta-kept-when-different ()
  "A genuinely-different `reasoning.delta' is appended as its own segment."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hello"))
             (cons "reasoning.delta" (hermes-test--ht "text" "Because..."))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 2 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))
    (should (eq 'reasoning (hermes-segment-type (aref segs 1))))))

(ert-deftest hermes-state-test/reasoning-delta-trimmed-match-suppresses ()
  "Whitespace-only differences still count as duplicates and are dropped."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hello"))
             (cons "reasoning.delta" (hermes-test--ht "text" " Hello "))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))))

(ert-deftest hermes-state-test/reasoning-available-suppressed-when-duplicate ()
  "`reasoning.available' is also guarded against duplicating prior text."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hello"))
             (cons "reasoning.available" (hermes-test--ht "text" "Hello"))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))))

(ert-deftest hermes-state-test/message-complete-commits-and-clears ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Hi"))
             (cons "message.complete" nil)))
         (m (hermes-test--last-pending s)))
    (should (null (hermes-state-stream s)))
    (should (eq 'assistant (hermes-message-kind m)))
    (should (equal "Hi" (hermes-test--seg-text m)))))

(ert-deftest hermes-state-test/message-complete-accumulates-usage ()
  (let* ((s1 (hermes-test--reduce*
              nil
              (cons "message.start" nil)
              (cons "message.delta" (hermes-test--ht "text" "one"))
              (cons "message.complete" (hermes-test--ht "tokens_sent" 10
                                                        "tokens_received" 20))))
         (s2 (hermes-test--reduce*
              s1
              (cons "message.start" nil)
              (cons "message.delta" (hermes-test--ht "text" "two"))
              (cons "message.complete" (hermes-test--ht "tokens_sent" 5
                                                        "tokens_received" 15))))
         (usage (hermes-state-usage s2)))
    (should (= 15 (gethash "tokens_sent" usage)))
    (should (= 35 (gethash "tokens_received" usage)))))

(ert-deftest hermes-state-test/message-complete-without-stream-is-noop ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "message.complete" nil))))
    (should (eq s0 s1))))

;;;; Errors

(ert-deftest hermes-state-test/error-event-appends-system-message ()
  (let* ((s (hermes--reduce nil
                            (cons "error"
                                  (hermes-test--ht "message" "boom"))))
         (m (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind m)))
    (should (equal "boom" (hermes-test--seg-text m)))))

;;;; Purity — old state is never mutated

(ert-deftest hermes-state-test/reducer-is-pure ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s0-snapshot (length (hermes-stream-segments (hermes-state-stream s0))))
         (_  (hermes--reduce s0 (cons "message.delta"
                                      (hermes-test--ht "text" "leak?")))))
    (should (= s0-snapshot
               (length (hermes-stream-segments (hermes-state-stream s0)))))))

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
    (should (= 2 (length (hermes-state-pending-turns s))))
    (should (eq 'user
                (hermes-message-kind (aref (hermes-state-pending-turns s) 0))))
    (should (eq 'assistant
                (hermes-message-kind (aref (hermes-state-pending-turns s) 1))))
    (should (equal "Hello world"
                   (hermes-test--seg-text
                    (aref (hermes-state-pending-turns s) 1))))
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

(ert-deftest hermes-state-test/ui-thinking-delta-accumulates-and-sets-status ()
  "thinking.delta chunks concatenate into thinking-text and status-text."
  (let* ((s1 (hermes--ui-reduce nil
                                (cons "thinking.delta"
                                      (hermes-test--ht "text" "synthesizing"))))
         (s2 (hermes--ui-reduce s1
                                (cons "thinking.delta"
                                      (hermes-test--ht "text" "…")))))
    (should (equal "synthesizing" (hermes-ui-state-thinking-text s1)))
    (should (equal "synthesizing" (hermes-ui-state-status-text s1)))
    (should (equal "synthesizing…" (hermes-ui-state-thinking-text s2)))
    (should (equal "synthesizing…" (hermes-ui-state-status-text s2)))))

(ert-deftest hermes-state-test/ui-status-update-resets-thinking-text ()
  "After status.update, a fresh thinking.delta starts from scratch."
  (let* ((s1 (hermes--ui-reduce nil
                                (cons "thinking.delta"
                                      (hermes-test--ht "text" "old"))))
         (s2 (hermes--ui-reduce s1
                                (cons "status.update"
                                      (hermes-test--ht "kind" "info"
                                                       "text" "Running bash…"))))
         (s3 (hermes--ui-reduce s2
                                (cons "thinking.delta"
                                      (hermes-test--ht "text" "new")))))
    (should (null (hermes-ui-state-thinking-text s2)))
    (should (equal "Running bash…" (hermes-ui-state-status-text s2)))
    (should (equal "new" (hermes-ui-state-thinking-text s3)))
    (should (equal "new" (hermes-ui-state-status-text s3)))))

;;;; Tools

(ert-deftest hermes-state-test/tool-generating-adds-to-stream ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))
    (should (eq 'tool (hermes-segment-type (aref segs 0))))
    (let ((tool (hermes-segment-content (aref segs 0))))
      (should (equal "t1" (hermes-tool-id tool)))
      (should (equal "bash" (hermes-tool-name tool)))
      (should (eq 'generating (hermes-tool-status tool))))))

(ert-deftest hermes-state-test/tool-generating-without-stream-dropped ()
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
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 1 (length segs)))))

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
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
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
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
    (should (eq 'error (hermes-tool-status tool)))
    (should (equal "kaboom" (hermes-tool-error tool)))))

(ert-deftest hermes-state-test/tool-complete-without-matching-tool-noop ()
  (let* ((s0 (hermes--reduce nil (cons "message.start" nil)))
         (s1 (hermes--reduce s0 (cons "tool.complete"
                                      (hermes-test--ht "tool_id" "ghost"
                                                       "output" "?")))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/tool-progress-updates-persistent-preview ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "bash"))
             (cons "tool.progress"
                   (hermes-test--ht "tool_id" "t1" "preview" "ls /tmp"))))
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
    (should (equal "ls /tmp" (hermes-tool-preview tool)))))

(ert-deftest hermes-state-test/tool-complete-stores-inline-diff ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "edit"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1"
                                    "inline_diff" "- old\n+ new"))))
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
    (should (equal "- old\n+ new" (hermes-tool-inline-diff tool)))))

(ert-deftest hermes-state-test/tool-complete-stores-todos ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "todo"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1"
                                    "todos" '(("text" . "fix bug") ("done" . t))))))
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
    (should (equal '(("text" . "fix bug") ("done" . t))
                   (hermes-tool-todos tool)))))

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
         (msg (hermes-test--last-pending s))
         (segs (hermes-message-segments msg))
         (tool-seg (cl-find-if (lambda (s) (eq 'tool (hermes-segment-type s)))
                                segs)))
    (should (null (hermes-state-stream s)))
    (should (eq 'assistant (hermes-message-kind msg)))
    (should tool-seg)
    (should (eq 'complete (hermes-tool-status (hermes-segment-content tool-seg))))))

;;;; Subagents

(ert-deftest hermes-state-test/subagent-spawn-creates-queued ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "fix bugs"))))
         (str (hermes-state-stream s))
         (sas (hermes-stream-subagents str)))
    (should (= 1 (length sas)))
    (let ((sa (aref sas 0)))
      (should (equal "sa1" (hermes-subagent-id sa)))
      (should (equal "fix bugs" (hermes-subagent-goal sa)))
      (should (eq 'queued (hermes-subagent-status sa)))
      (should (equal [] (hermes-subagent-tools sa)))
      (should (equal [] (hermes-subagent-notes sa))))))

(ert-deftest hermes-state-test/subagent-start-transitions-running ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "fix"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "fix"))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0)))
    (should (eq 'running (hermes-subagent-status sa)))))

(ert-deftest hermes-state-test/subagent-thinking-accumulates ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.thinking"
                   (hermes-test--ht "subagent_id" "sa1" "text" "hmm "))
             (cons "subagent.thinking"
                   (hermes-test--ht "subagent_id" "sa1" "text" "maybe"))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0)))
    (should (equal "hmm maybe" (hermes-subagent-thinking sa)))))

(ert-deftest hermes-state-test/subagent-tool-appends ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.tool"
                   (hermes-test--ht "subagent_id" "sa1"
                                    "tool_name" "bash" "args" "ls"))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0))
         (tools (hermes-subagent-tools sa)))
    (should (= 1 (length tools)))
    (should (equal "bash" (plist-get (aref tools 0) :name)))
    (should (equal "ls" (plist-get (aref tools 0) :args)))))

(ert-deftest hermes-state-test/subagent-progress-appends ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.progress"
                   (hermes-test--ht "subagent_id" "sa1" "note" "searching"))
             (cons "subagent.progress"
                   (hermes-test--ht "subagent_id" "sa1" "note" "found"))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0))
         (notes (hermes-subagent-notes sa)))
    (should (= 2 (length notes)))
    (should (equal "searching" (aref notes 0)))
    (should (equal "found" (aref notes 1)))))

(ert-deftest hermes-state-test/subagent-complete-finalizes ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.thinking"
                   (hermes-test--ht "subagent_id" "sa1" "text" "done"))
             (cons "subagent.complete"
                   (hermes-test--ht "subagent_id" "sa1"
                                    "status" "complete"
                                    "summary" "all good"
                                    "duration_s" 1.5))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0)))
    (should (eq 'complete (hermes-subagent-status sa)))
    (should (equal "all good" (hermes-subagent-summary sa)))
    (should (equal 1.5 (hermes-subagent-duration sa)))
    (should (equal "done" (hermes-subagent-thinking sa)))))

(ert-deftest hermes-state-test/subagent-complete-with-error ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.complete"
                   (hermes-test--ht "subagent_id" "sa1"
                                    "status" "error"
                                    "summary" "failed"))))
         (sa (aref (hermes-stream-subagents (hermes-state-stream s)) 0)))
    (should (eq 'error (hermes-subagent-status sa)))))

(ert-deftest hermes-state-test/subagent-commit-with-message ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "ok"))
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "x"))
             (cons "subagent.start"
                   (hermes-test--ht "subagent_id" "sa1"))
             (cons "subagent.complete"
                   (hermes-test--ht "subagent_id" "sa1"
                                    "status" "complete"
                                    "summary" "done"))
             (cons "message.complete" nil)))
         (msg (hermes-test--last-pending s)))
    (should (null (hermes-state-stream s)))
    (should (eq 'assistant (hermes-message-kind msg)))
    (let ((sas (hermes-message-subagents msg)))
      (should (= 1 (length sas)))
      (should (eq 'complete (hermes-subagent-status (aref sas 0)))))))

(ert-deftest hermes-state-test/subagent-dedupes-spawn ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "first"))
             (cons "subagent.spawn_requested"
                   (hermes-test--ht "subagent_id" "sa1" "goal" "second"))))
         (sas (hermes-stream-subagents (hermes-state-stream s))))
    (should (= 1 (length sas)))
    (should (equal "first" (hermes-subagent-goal (aref sas 0))))))

(ert-deftest hermes-state-test/subagent-without-stream-dropped ()
  (dolist (event '("subagent.spawn_requested" "subagent.start"
                   "subagent.thinking" "subagent.tool"
                   "subagent.progress" "subagent.complete"))
    (let* ((s0 (hermes--reduce nil '(:connected)))
           (s1 (hermes--reduce s0 (cons event
                                        (hermes-test--ht "subagent_id" "sa1")))))
      (should (eq s0 s1)))))

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

(ert-deftest hermes-state-test/ui-subagent-start-sets-status ()
  (let ((s (hermes--ui-reduce nil
                              (cons "subagent.start"
                                    (hermes-test--ht "subagent_id" "sa1"
                                                     "goal" "fix bugs")))))
    (should (equal "Delegating to fix bugs…" (hermes-ui-state-status-text s)))))

(ert-deftest hermes-state-test/ui-subagent-complete-clears-status ()
  (let* ((s1 (hermes--ui-reduce nil
                                (cons "subagent.start"
                                      (hermes-test--ht "subagent_id" "sa1"))))
         (s2 (hermes--ui-reduce s1
                                (cons "subagent.complete"
                                      (hermes-test--ht "subagent_id" "sa1")))))
    (should (null (hermes-ui-state-status-text s2)))))

;;;; M4 — queue, history, slash catalog

(ert-deftest hermes-state-test/enqueue-appends-in-order ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons :enqueue '(:text "a"))
             (cons :enqueue '(:text "b"))
             (cons :enqueue '(:text "c")))))
    (should (equal '("a" "b" "c") (hermes-state-queue s)))))

(ert-deftest hermes-state-test/dequeue-pops-head ()
  (let* ((s0 (hermes-test--reduce*
              nil
              (cons :enqueue '(:text "a"))
              (cons :enqueue '(:text "b"))))
         (s1 (hermes--reduce s0 '(:dequeue))))
    (should (equal '("b") (hermes-state-queue s1)))))

(ert-deftest hermes-state-test/dequeue-on-empty-is-noop ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 '(:dequeue))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/user-submit-pushes-history ()
  (let* ((s (hermes-test--reduce*
             nil
             (cons :user-submit '(:text "one"))
             (cons :user-submit '(:text "two")))))
    (should (equal '("two" "one") (hermes-state-history s)))))

(ert-deftest hermes-state-test/history-capped ()
  (let ((hermes-history-max 3)
        (s nil))
    (dolist (t* '("a" "b" "c" "d" "e"))
      (setq s (hermes--reduce s (cons :user-submit (list :text t*)))))
    (should (equal '("e" "d" "c") (hermes-state-history s)))))

(ert-deftest hermes-state-test/slash-catalog-stores-payload ()
  (let* ((cat (hermes-test--ht "pairs" [["help" "show help"]]))
         (s   (hermes--reduce nil (cons :slash-catalog (list :catalog cat)))))
    (should (eq cat (hermes-state-slash-catalog s)))))

;;;; Gateway diagnostics

(ert-deftest hermes-state-test/gateway-stderr-appends-system-message ()
  (let* ((s (hermes--reduce nil (cons "gateway.stderr"
                                      (hermes-test--ht "line" "some warning"))))
         (msg (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind msg)))
    (should (string-match-p "\\[stderr\\] some warning"
                            (hermes-test--seg-text msg)))))

(ert-deftest hermes-state-test/gateway-stderr-clips-long-line ()
  (let* ((long-line (make-string 200 ?x))
         (s (hermes--reduce nil (cons "gateway.stderr"
                                      (hermes-test--ht "line" long-line))))
         (msg (hermes-test--last-pending s)))
    (should (= 129 (length (hermes-test--seg-text msg))))))

(ert-deftest hermes-state-test/gateway-protocol-error-appends-system-message ()
  (let* ((s (hermes--reduce nil (cons "gateway.protocol_error"
                                      (hermes-test--ht "preview" "not json"))))
         (msg (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind msg)))
    (should (string-match-p "\\[protocol noise\\] not json"
                            (hermes-test--seg-text msg)))))

(ert-deftest hermes-state-test/gateway-start-timeout-appends-system-message ()
  (let* ((s (hermes--reduce nil (cons "gateway.start_timeout"
                                      (hermes-test--ht "lines" '("err1" "err2")))))
         (msg (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind msg)))
    (should (string-match-p "\\[gateway start timeout\\]"
                            (hermes-test--seg-text msg)))
    (should (string-match-p "err1" (hermes-test--seg-text msg)))
    (should (string-match-p "err2" (hermes-test--seg-text msg)))))

(ert-deftest hermes-state-test/background-complete-appends-system-message ()
  (let* ((s (hermes--reduce nil (cons "background.complete"
                                      (hermes-test--ht "task_id" "t1"
                                                       "text" "done"))))
         (msg (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind msg)))
    (should (string-match-p "\\[bg t1\\] done" (hermes-test--seg-text msg)))))

(ert-deftest hermes-state-test/review-summary-appends-system-message ()
  (let* ((s (hermes--reduce nil (cons "review.summary"
                                      (hermes-test--ht "text" "looks good"))))
         (msg (hermes-test--last-pending s)))
    (should (eq 'system (hermes-message-kind msg)))
    (should (string-match-p "\\[review\\] looks good"
                            (hermes-test--seg-text msg)))))

(ert-deftest hermes-state-test/ui-gateway-start-timeout-sets-status ()
  (let ((s (hermes--ui-reduce nil (cons "gateway.start_timeout" nil))))
    (should (string-match-p "failed to start"
                            (hermes-ui-state-status-text s)))))

(ert-deftest hermes-state-test/ui-gateway-protocol-error-sets-status ()
  (let ((s (hermes--ui-reduce nil (cons "gateway.protocol_error" nil))))
    (should (string-match-p "Protocol noise"
                            (hermes-ui-state-status-text s)))))

(ert-deftest hermes-state-test/install-hooks-is-idempotent ()
  (require 'hermes-mode)
  (hermes--install-hooks)
  (let ((after-once (length hermes-rpc-stderr-functions)))
    (hermes--install-hooks)
    (should (= (length hermes-rpc-stderr-functions) after-once))))

;;;; Round-trip serialization

(ert-deftest hermes-state-test/round-trip-text-message ()
  (let* ((msg (make-hermes-message
               :kind 'user
               :segments (vector (make-hermes-segment
                                  :type 'text :content "Hello" :id "s1"))
               :timestamp "2024-01-15T10:00:00+0000"))
         (plist (hermes--message-to-plist msg))
         (rt (hermes--plist-to-message plist)))
    (should (eq 'user (hermes-message-kind rt)))
    (should (equal "Hello"
                   (hermes-segment-content
                    (aref (hermes-message-segments rt) 0))))
    (should (equal "s1" (hermes-segment-id
                         (aref (hermes-message-segments rt) 0))))))

(ert-deftest hermes-state-test/round-trip-tool-message ()
  (let* ((tool (make-hermes-tool
                :id "t1" :name "Read" :status 'complete
                :context "{\"file\":\"x.py\"}"
                :preview nil :inline-diff "- a\n+ b"
                :todos '((:text "fix" :done t))
                :output "OK" :error nil :duration 0.5))
         (msg (make-hermes-message
               :kind 'assistant
               :segments (vector (make-hermes-segment
                                  :type 'tool :content tool :id "s2"))
               :timestamp "2024-01-15T10:00:00+0000"))
         (plist (hermes--message-to-plist msg))
         (rt (hermes--plist-to-message plist))
         (rt-tool (hermes-segment-content
                   (aref (hermes-message-segments rt) 0))))
    (should (hermes-tool-p rt-tool))
    (should (equal "t1" (hermes-tool-id rt-tool)))
    (should (eq 'complete (hermes-tool-status rt-tool)))
    (should (equal "- a\n+ b" (hermes-tool-inline-diff rt-tool)))
    (should (equal "OK" (hermes-tool-output rt-tool)))
    (should (equal 0.5 (hermes-tool-duration rt-tool)))))

(ert-deftest hermes-state-test/round-trip-subagent-message ()
  (let* ((sa (make-hermes-subagent
              :id "sa1" :goal "fix" :status 'complete
              :thinking "let me think"
              :tools (vector (list :name "bash" :args "ls"))
              :notes (vector "searching" "found")
              :summary "done" :duration 2.0))
         (msg (make-hermes-message
               :kind 'assistant
               :segments []
               :subagents (vector sa)
               :timestamp "2024-01-15T10:00:00+0000"))
         (plist (hermes--message-to-plist msg))
         (rt (hermes--plist-to-message plist))
         (rt-sa (aref (hermes-message-subagents rt) 0)))
    (should (hermes-subagent-p rt-sa))
    (should (equal "sa1" (hermes-subagent-id rt-sa)))
    (should (eq 'complete (hermes-subagent-status rt-sa)))
    (should (equal "done" (hermes-subagent-summary rt-sa)))
    (should (= 2 (length (hermes-subagent-notes rt-sa))))))

(ert-deftest hermes-state-test/round-trip-mixed-assistant-turn ()
  (let* ((tool (make-hermes-tool :id "t1" :name "Bash" :status 'complete
                                 :output "ok" :duration 0.1))
         (msg (make-hermes-message
               :kind 'assistant
               :segments (vector
                          (make-hermes-segment :type 'text
                                               :content "Result:" :id "s1")
                          (make-hermes-segment :type 'tool
                                               :content tool :id "s2"))
               :timestamp "2024-01-15T10:00:00+0000"))
         (plist (hermes--message-to-plist msg))
         (rt (hermes--plist-to-message plist))
         (segs (hermes-message-segments rt)))
    (should (= 2 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))
    (should (eq 'tool (hermes-segment-type (aref segs 1))))
    (should (hermes-tool-p (hermes-segment-content (aref segs 1))))))

(ert-deftest hermes-state-test/struct-to-plist-preserves-types ()
  (let* ((seg (make-hermes-segment :type 'text :content "hi" :id "s1"))
         (plist (hermes--struct-to-plist seg)))
    (should (eq 'text (plist-get plist :type)))
    (should (equal "hi" (plist-get plist :content)))
    (should (equal "s1" (plist-get plist :id))))
  (let* ((tool (make-hermes-tool :id "t" :name "n" :status 'running))
         (plist (hermes--struct-to-plist tool)))
    (should (eq 'running (plist-get plist :status)))
    (should (equal "t" (plist-get plist :id)))))

(provide 'hermes-state-test)
;;; hermes-state-test.el ends here
