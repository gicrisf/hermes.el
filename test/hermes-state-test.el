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

(ert-deftest hermes-state-test/message-to-plist-omits-text-key ()
  "v2: `hermes--message-to-plist' no longer emits the legacy `:text' key.
Text content is derivable from `:segments'."
  (let* ((msg (make-hermes-message
               :kind 'user
               :segments (vector (make-hermes-segment
                                  :type 'text :content "hi" :id "s1"))))
         (p (hermes--message-to-plist msg)))
    (should (plist-member p :segments))
    (should-not (plist-member p :text))))

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

(ert-deftest hermes-state-test/reasoning-delta-truncated-echo-suppressed ()
  "A reasoning.delta that is a truncated prefix of the prior text segment
must be treated as a duplicate and suppressed."
  (let* ((text-seg (make-hermes-segment
                    :type 'text
                    :content "In the high valleys... Stormrider's boldness was not the reckless..."
                    :id "seg-11"))
         (stream (make-hermes-stream :segments (vector text-seg)))
         (truncated-echo
          "In the high valleys... Stormrider's boldness was not the reckl"))
    (should (hermes--reasoning-duplicate-p truncated-echo stream))))

(ert-deftest hermes-state-test/reasoning-delta-suppressed-across-tool-gap ()
  "Dedup skips over interleaved tool segments to find the prior text.
A `text → tool → reasoning' sequence where reasoning echoes the text
should still suppress the reasoning segment."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "Fair point"))
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "search_files"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1" "duration_s" 0.1))
             (cons "reasoning.delta" (hermes-test--ht "text" "Fair point"))))
         (segs (hermes-stream-segments (hermes-state-stream s))))
    (should (= 2 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))
    (should (eq 'tool (hermes-segment-type (aref segs 1))))))

(ert-deftest hermes-state-test/reasoning-delta-suppressed-with-whitespace-variation ()
  "Whitespace normalization: `\\n\\n' vs space, tab vs space all collapse."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta"
                   (hermes-test--ht "text" "Hello\n\nworld\tagain"))
             (cons "reasoning.delta"
                   (hermes-test--ht "text" "  Hello world again  "))))
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

(ert-deftest hermes-state-test/message-complete-attaches-per-turn-usage ()
  "Each pending assistant message carries the per-turn token counts from
the `message.complete' event, NOT the running session total.  Regression
guard: previously msg-usage was an empty hash table, leaking the
session-cumulative `hermes-state-usage' into every drawer."
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
         (p1 (hermes-state-pending-turns s1))
         (p2 (hermes-state-pending-turns s2))
         (m1-usage (hermes-message-usage (aref p1 (1- (length p1)))))
         (m2-usage (hermes-message-usage (aref p2 (1- (length p2))))))
    (should (= 10 (gethash "tokens_sent" m1-usage)))
    (should (= 20 (gethash "tokens_received" m1-usage)))
    (should (= 5 (gethash "tokens_sent" m2-usage)))
    (should (= 15 (gethash "tokens_received" m2-usage)))
    ;; Session-wide cumulative still accumulates as before.
    (should (= 15 (gethash "tokens_sent" (hermes-state-usage s2))))
    (should (= 35 (gethash "tokens_received" (hermes-state-usage s2))))))

(ert-deftest hermes-state-test/message-complete-without-stream-is-noop ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "message.complete" nil))))
    (should (eq s0 s1))))

;;;; Errors

(defun hermes-test--log-text ()
  "Return the full text of the *hermes-log* buffer."
  (with-current-buffer (hermes--log-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun hermes-test--clear-log ()
  "Reset *hermes-log* between tests."
  (let ((b (get-buffer "*hermes-log*")))
    (when b
      (with-current-buffer b
        (let ((inhibit-read-only t))
          (erase-buffer))))))

(ert-deftest hermes-state-test/error-event-logs-and-sets-status ()
  "Without a stream, `error' produces no pending message; it logs and
the UI reducer sets the header-line status."
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "error"
                                      (hermes-test--ht "message" "boom"))))
         (ui (hermes--ui-reduce nil (cons "error"
                                          (hermes-test--ht "message" "boom")))))
    (should (eq s0 s1))
    (should (string-match-p "boom" (hermes-test--log-text)))
    (should (string-match-p "boom" (hermes-ui-state-status-text ui)))))

(ert-deftest hermes-state-test/error-with-stream-commits-assistant-only ()
  "Mid-stream `error' commits the partial assistant turn (no system msg)
and writes the error text to the log."
  (hermes-test--clear-log)
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "message.delta" (hermes-test--ht "text" "partial"))
             (cons "error" (hermes-test--ht "message" "kaboom"))))
         (turns (hermes-state-pending-turns s)))
    (should (= 1 (length turns)))
    (should (eq 'assistant (hermes-message-kind (aref turns 0))))
    (should (null (hermes-state-stream s)))
    (should (string-match-p "kaboom" (hermes-test--log-text)))))

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

(ert-deftest hermes-state-test/tool-complete-stores-summary ()
  "Gateway-provided `summary' is extracted into the tool struct."
  (let* ((s (hermes-test--reduce*
             nil
             (cons "message.start" nil)
             (cons "tool.generating"
                   (hermes-test--ht "tool_id" "t1" "name" "web_search"))
             (cons "tool.complete"
                   (hermes-test--ht "tool_id" "t1"
                                    "summary" "Did 3 searches"
                                    "duration_s" 1.4))))
         (seg (aref (hermes-stream-segments (hermes-state-stream s)) 0))
         (tool (hermes-segment-content seg)))
    (should (equal "Did 3 searches" (hermes-tool-summary tool)))))

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

(ert-deftest hermes-state-test/gateway-stderr-logs-to-buffer ()
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "gateway.stderr"
                                      (hermes-test--ht "line" "some warning")))))
    (should (eq s0 s1))
    (should (string-match-p "\\[stderr\\] some warning" (hermes-test--log-text)))))

(ert-deftest hermes-state-test/gateway-stderr-clips-in-log-buffer ()
  "Long stderr lines are clipped to 120 chars in the log."
  (hermes-test--clear-log)
  (let ((long-line (make-string 200 ?x)))
    (hermes--reduce nil (cons "gateway.stderr"
                              (hermes-test--ht "line" long-line)))
    ;; Log line is "[HH:MM:SS] [stderr] <clipped>"; ensure the clipped
    ;; payload is exactly 120 x's, not 200.
    (let ((log (hermes-test--log-text)))
      (should (string-match-p (format "\\[stderr\\] x\\{120\\}\n" ) log))
      (should-not (string-match-p "x\\{121\\}" log)))))

(ert-deftest hermes-state-test/gateway-protocol-error-logs-and-sets-status ()
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "gateway.protocol_error"
                                      (hermes-test--ht "preview" "not json"))))
         (ui (hermes--ui-reduce nil (cons "gateway.protocol_error" nil))))
    (should (eq s0 s1))
    (should (string-match-p "\\[protocol noise\\] not json" (hermes-test--log-text)))
    (should (string-match-p "Protocol noise" (hermes-ui-state-status-text ui)))))

(ert-deftest hermes-state-test/gateway-start-timeout-logs-and-sets-status ()
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "gateway.start_timeout"
                                      (hermes-test--ht "lines" '("err1" "err2")))))
         (ui (hermes--ui-reduce nil (cons "gateway.start_timeout" nil)))
         (log (hermes-test--log-text)))
    (should (eq s0 s1))
    (should (string-match-p "\\[gateway start timeout\\]" log))
    (should (string-match-p "err1" log))
    (should (string-match-p "err2" log))
    (should (string-match-p "failed to start" (hermes-ui-state-status-text ui)))))

(ert-deftest hermes-state-test/background-start-creates-running-task ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0
                             (cons :background-start
                                   (list :task-id "t1" :prompt "hello"))))
         (tasks (hermes-state-bg-tasks s1)))
    (should (vectorp tasks))
    (should (= 1 (length tasks)))
    (let ((task (aref tasks 0)))
      (should (equal "t1" (hermes-bg-task-task-id task)))
      (should (equal "hello" (hermes-bg-task-prompt task)))
      (should (eq 'running (hermes-bg-task-status task)))
      (should (null (hermes-bg-task-buffer-name task)))
      (should (stringp (hermes-bg-task-created-at task))))))

(ert-deftest hermes-state-test/background-start-deduplicates ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons :background-start
                                      (list :task-id "t1" :prompt "a"))))
         (s2 (hermes--reduce s1 (cons :background-start
                                      (list :task-id "t1" :prompt "b")))))
    (should (eq s1 s2))
    (should (= 1 (length (hermes-state-bg-tasks s2))))))

(ert-deftest hermes-state-test/background-complete-updates-task ()
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons :background-start
                                      (list :task-id "t1" :prompt "hello"))))
         (s2 (hermes--reduce s1 (cons "background.complete"
                                      (hermes-test--ht "task_id" "t1"
                                                       "text" "done"))))
         (tasks (hermes-state-bg-tasks s2)))
    (should (= 1 (length tasks)))
    (let ((task (aref tasks 0)))
      (should (eq 'complete (hermes-bg-task-status task)))
      (should (equal "done" (hermes-bg-task-result task)))
      (should (null (hermes-bg-task-error task)))
      (should (stringp (hermes-bg-task-completed-at task))))
    (should (string-match-p "\\[bg t1\\] done" (hermes-test--log-text)))))

(ert-deftest hermes-state-test/background-complete-creates-task-if-missing ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "background.complete"
                                      (hermes-test--ht "task_id" "t99"
                                                       "text" "orphan"))))
         (tasks (hermes-state-bg-tasks s1)))
    (should (= 1 (length tasks)))
    (let ((task (aref tasks 0)))
      (should (equal "t99" (hermes-bg-task-task-id task)))
      (should (eq 'complete (hermes-bg-task-status task)))
      (should (equal "orphan" (hermes-bg-task-result task))))))

(ert-deftest hermes-state-test/background-error-marks-error-status ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons :background-start
                                      (list :task-id "tE" :prompt "boom"))))
         (s2 (hermes--reduce s1 (cons "background.complete"
                                      (hermes-test--ht "task_id" "tE"
                                                       "error" "kaboom"))))
         (task (aref (hermes-state-bg-tasks s2) 0)))
    (should (eq 'error (hermes-bg-task-status task)))
    (should (equal "kaboom" (hermes-bg-task-error task)))))

(ert-deftest hermes-state-test/bg-rendered-records-buffer-name ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons :background-start
                                      (list :task-id "t1" :prompt "x"))))
         (s2 (hermes--reduce s1 (cons :bg-rendered
                                      (list :task-id "t1"
                                            :buffer-name "*hermes-bg:s:t1*"))))
         (task (aref (hermes-state-bg-tasks s2) 0)))
    (should (equal "*hermes-bg:s:t1*" (hermes-bg-task-buffer-name task)))))

(ert-deftest hermes-state-test/bg-rendered-noop-when-task-missing ()
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons :bg-rendered
                                      (list :task-id "ghost"
                                            :buffer-name "*x*")))))
    (should (eq s0 s1))))

(ert-deftest hermes-state-test/review-summary-logs-to-buffer ()
  (hermes-test--clear-log)
  (let* ((s0 (hermes--reduce nil '(:connected)))
         (s1 (hermes--reduce s0 (cons "review.summary"
                                      (hermes-test--ht "text" "looks good")))))
    (should (eq s0 s1))
    (should (string-match-p "\\[review\\] looks good" (hermes-test--log-text)))))

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
                :output "OK" :summary "Read 1 file" :error nil :duration 0.5))
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
    (should (equal "Read 1 file" (hermes-tool-summary rt-tool)))
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

;;;; Image attachments (PLAN.md: image.attach / clipboard.paste)

(ert-deftest hermes-state-test/attachment-add-appends-entry ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes--reduce s0 (cons :attachment-add
                                      (list :attach-id "a1" :name "cat.png"
                                            :status 'pending)))))
    (should (equal 1 (length (hermes-state-attachments s1))))
    (let ((a (car (hermes-state-attachments s1))))
      (should (equal "a1" (plist-get a :attach-id)))
      (should (equal "cat.png" (plist-get a :name)))
      (should (eq 'pending (plist-get a :status))))))

(ert-deftest hermes-state-test/attachment-update-merges-fields ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes--reduce s0 (cons :attachment-add
                                      (list :attach-id "a1" :name "cat.png"
                                            :status 'pending))))
         (s2 (hermes--reduce s1 (cons :attachment-update
                                      (list :attach-id "a1"
                                            :width 100 :height 200
                                            :status 'attached)))))
    (let ((a (car (hermes-state-attachments s2))))
      (should (eq 'attached (plist-get a :status)))
      (should (= 100 (plist-get a :width)))
      (should (= 200 (plist-get a :height)))
      (should (equal "cat.png" (plist-get a :name))))))

(ert-deftest hermes-state-test/attachment-remove-drops-entry ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes-test--reduce* s0
              (cons :attachment-add (list :attach-id "a1" :name "x"))
              (cons :attachment-add (list :attach-id "a2" :name "y"))))
         (s2 (hermes--reduce s1 (cons :attachment-remove
                                      (list :attach-id "a1")))))
    (should (= 1 (length (hermes-state-attachments s2))))
    (should (equal "a2" (plist-get (car (hermes-state-attachments s2))
                                    :attach-id)))))

(ert-deftest hermes-state-test/attachments-clear-empties-slot ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes--reduce s0 (cons :attachment-add
                                      (list :attach-id "a1" :name "x"))))
         (s2 (hermes--reduce s1 '(:attachments-clear))))
    (should (null (hermes-state-attachments s2)))))

(ert-deftest hermes-state-test/user-submit-consumes-attached-images ()
  "An `attached' attachment becomes a leading image segment; pending dropped."
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes-test--reduce* s0
              (cons :attachment-add (list :attach-id "a1"
                                          :path "/tmp/cat.png" :name "cat.png"
                                          :width 100 :height 200
                                          :token-estimate 50
                                          :status 'attached))
              (cons :attachment-add (list :attach-id "a2"
                                          :path "/tmp/dog.png" :name "dog.png"
                                          :status 'pending))
              (cons :user-submit (list :text "look"))))
         (msg (hermes-test--last-pending s1))
         (segs (hermes-message-segments msg)))
    (should (= 2 (length segs)))
    (should (eq 'image (hermes-segment-type (aref segs 0))))
    (should (eq 'text  (hermes-segment-type (aref segs 1))))
    (let ((img (hermes-segment-content (aref segs 0))))
      (should (equal "/tmp/cat.png" (plist-get img :path)))
      (should (= 100 (plist-get img :width)))
      (should (= 50  (plist-get img :token-estimate))))
    (should (null (hermes-state-attachments s1)))))

(ert-deftest hermes-state-test/user-submit-without-attachments-text-only ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes--reduce s0 (cons :user-submit (list :text "hi"))))
         (msg (hermes-test--last-pending s1))
         (segs (hermes-message-segments msg)))
    (should (= 1 (length segs)))
    (should (eq 'text (hermes-segment-type (aref segs 0))))
    (should (equal "hi" (hermes-segment-content (aref segs 0))))))

(ert-deftest hermes-state-test/image-segment-roundtrips-via-plist ()
  (let* ((content (list :path "/tmp/cat.png" :name "cat.png"
                        :width 100 :height 200 :token-estimate 50))
         (seg (make-hermes-segment :type 'image :content content :id "s1"))
         (plist (hermes--segment-to-plist seg))
         (rt (hermes--plist-to-segment plist)))
    (should (eq 'image (hermes-segment-type rt)))
    (let ((rc (hermes-segment-content rt)))
      (should (equal "/tmp/cat.png" (plist-get rc :path)))
      (should (equal "cat.png" (plist-get rc :name)))
      (should (= 100 (plist-get rc :width)))
      (should (= 200 (plist-get rc :height)))
      ;; Token estimate is intentionally NOT persisted — model-specific.
      (should (null (plist-get rc :token-estimate))))))

(ert-deftest hermes-state-test/image-segment-with-missing-path-survives ()
  (let* ((seg (make-hermes-segment :type 'image
                                   :content (list :path nil :name "ghost.png")
                                   :id "s1"))
         (rt (hermes--plist-to-segment (hermes--segment-to-plist seg))))
    (should (eq 'image (hermes-segment-type rt)))
    (should (null (plist-get (hermes-segment-content rt) :path)))
    (should (equal "ghost.png" (plist-get (hermes-segment-content rt) :name)))))

;;;; :set-cwd reducer

(ert-deftest hermes-state-test/initial-cwd-is-nil ()
  (let ((s (hermes--reduce nil '(:noop))))
    (should (null (hermes-state-cwd s)))))

(ert-deftest hermes-state-test/set-cwd-updates-field ()
  (let* ((s0 (hermes--reduce nil '(:noop)))
         (s1 (hermes--reduce s0 (cons :set-cwd (list :cwd "/tmp/project/")))))
    (should (equal "/tmp/project/" (hermes-state-cwd s1)))))

(ert-deftest hermes-state-test/set-cwd-nil-clears ()
  (let* ((s0 (hermes--reduce nil (cons :set-cwd (list :cwd "/x/"))))
         (s1 (hermes--reduce s0 (cons :set-cwd (list :cwd nil)))))
    (should (equal "/x/" (hermes-state-cwd s0)))
    (should (null (hermes-state-cwd s1)))))

(provide 'hermes-state-test)
;;; hermes-state-test.el ends here
