;;; hermes-render-test.el --- ERT tests for the segmented renderer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)
(require 'hermes-render)

(defun hermes-render-test--setup ()
  "Initialise an in-flight stream in the current buffer.
Inserts a minimal `** assistant :hermes:' heading and returns the
position right after the heading line."
  (insert "** assistant :hermes:\n")
  (setq hermes--stream-headline-marker (copy-marker 1))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (setq hermes--stream-segments-start (copy-marker (point)))
  (set-marker-insertion-type hermes--stream-segments-start nil)
  (setq hermes--stream-segments-end (copy-marker (point)))
  (set-marker-insertion-type hermes--stream-segments-end t)
  (point))

(defun hermes-render-test--body ()
  "Return the text after the `** assistant :hermes:' heading line."
  (save-excursion
    (goto-char (marker-position hermes--stream-headline-marker))
    (forward-line 1)
    (buffer-substring-no-properties (point) (point-max))))

;;;; Format segment tests

(ert-deftest hermes-render-test/format-text-segment ()
  "Text segments are converted from markdown to Org."
  (let ((result (hermes--format-segment
                 (make-hermes-segment :type 'text :content "I am **strong**."))))
    (should (string-match-p "I am \\*strong\\*" result))))

(ert-deftest hermes-render-test/format-thinking-segment ()
  "Thinking segments are rendered as `*** Thinking' headings."
  (let ((result (hermes--format-segment
                 (make-hermes-segment :type 'thinking :content "hmm" :id "s1"))))
    (should (string-match-p "^\\*\\*\\* Thinking" result))
    (should (string-match-p ":HERMES_KIND: thinking" result))
    (should (string-match-p "hmm" result))))

(ert-deftest hermes-render-test/format-reasoning-segment ()
  "Reasoning segments are rendered as `*** Reasoning' headings."
  (let ((result (hermes--format-segment
                 (make-hermes-segment :type 'reasoning :content "because" :id "s2"))))
    (should (string-match-p "^\\*\\*\\* Reasoning" result))
    (should (string-match-p ":HERMES_KIND: reasoning" result))
    (should (string-match-p "because" result))))

(ert-deftest hermes-render-test/format-tool-segment ()
  "Tool segments are rendered as sub-headlines with a TODO keyword."
  (let* ((tool (make-hermes-tool :id "t1" :name "Bash"
                                 :status 'complete :output "done"))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s3"))))
    (should (string-match-p "^\\*\\*\\* DONE " result))
    (should (string-match-p "done" result))))

(ert-deftest hermes-render-test/format-system-segment ()
  "System segments are rendered as comment blocks."
  (let ((result (hermes--format-segment
                 (make-hermes-segment :type 'system :content "note"))))
    (should (string-match-p "#\\+begin_comment" result))
    (should (string-match-p "note" result))
    (should (string-match-p "#\\+end_comment" result))))

;;;; Stream rendering tests

(ert-deftest hermes-render-test/single-text-segment ()
  "A single text segment renders under a `*** Response' heading."
  (with-temp-buffer
    (hermes-render-test--setup)
    (let ((seg (make-hermes-segment :type 'text :content "Hi there")))
      (hermes--render-stream-segments (vector seg)))
    (let ((body (hermes-render-test--body)))
      (should (string-match-p "^\\*\\*\\* Response" body))
      (should (string-match-p "Hi there" body)))))

(ert-deftest hermes-render-test/multiple-segments-ordered ()
  "Segments render in arrival order."
  (with-temp-buffer
    (hermes-render-test--setup)
    (let ((s1 (make-hermes-segment :type 'text :content "Hello"))
          (s2 (make-hermes-segment :type 'thinking :content "hmm"))
          (s3 (make-hermes-segment :type 'text :content "World")))
      (hermes--render-stream-segments (vector s1 s2 s3)))
    (let ((body (hermes-render-test--body)))
      (should (string-match-p "Hello" body))
      (should (string-match-p "hmm" body))
      (should (string-match-p "World" body))
      ;; Hello (text → Response) precedes hmm (thinking → Thinking heading).
      (should (< (string-match "Hello" body)
                 (string-match "hmm" body)))
      (should (< (string-match "hmm" body)
                 (string-match "World" body))))))

(ert-deftest hermes-render-test/segment-update-rewrites ()
  "Updating segments rewrites the region in place."
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "Old")))
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "New content")))
    (let ((body (hermes-render-test--body)))
      (should (string-match-p "New content" body))
      (should-not (string-match-p "Old" body)))))

(ert-deftest hermes-render-test/text-segment-markdown-to-org ()
  "Text segments are converted from markdown to Org."
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "I am **strong**.")))
    (should (string-match-p "I am \\*strong\\*."
                            (hermes-render-test--body)))))

(ert-deftest hermes-render-test/stream-update-renders-segments ()
  "hermes--stream-update renders segments from stream."
  (with-temp-buffer
    (hermes--stream-begin)
    (let* ((stream (make-hermes-stream
                    :segments (vector (make-hermes-segment :type 'text :content "Hi")))))
      (hermes--stream-update nil stream))
    (should (string-match-p "Hi"
                            (buffer-substring-no-properties
                             (point-min) (point-max))))))

(ert-deftest hermes-render-test/thinking-and-reasoning-separate-blocks ()
  "thinking and reasoning segments produce separate `*** ' headings."
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'thinking :content "think" :id "s1")
             (make-hermes-segment :type 'reasoning :content "reason" :id "s2")))
    (let ((body (hermes-render-test--body)))
      (should (string-match-p "^\\*\\*\\* Thinking" body))
      (should (string-match-p "think" body))
      (should (string-match-p "^\\*\\*\\* Reasoning" body))
      (should (string-match-p "reason" body))
      (should (< (string-match "Thinking" body)
                 (string-match "Reasoning" body))))))

;;;; Subagent formatting

(ert-deftest hermes-render-test/subagent-block-renders-headline ()
  "Subagent headline includes goal and status."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix bugs" :status 'running))
         (result (hermes--format-subagent sa)))
    (should (string-match (regexp-quote "**** fix bugs (running…)") result))))

(ert-deftest hermes-render-test/subagent-block-includes-id ()
  "Subagent property drawer includes ID."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'running))
         (result (hermes--format-subagent sa)))
    (should (string-match-p ":ID:       sa1" result))))

(ert-deftest hermes-render-test/subagent-block-includes-thinking ()
  "Thinking text wrapped in example block."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'running
                                   :thinking "searching for root cause"))
         (result (hermes--format-subagent sa)))
    (should (string-match-p "#\\+begin_example Thinking" result))
    (should (string-match-p "searching for root cause" result))
    (should (string-match-p "#\\+end_example" result))))

(ert-deftest hermes-render-test/subagent-block-includes-tools ()
  "Tool list formatted as bullets with name and args."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'running
                                   :tools (vector (list :name "bash" :args "ls"))))
         (result (hermes--format-subagent sa)))
    (should (string-match (regexp-quote "- bash(ls)") result))))

(ert-deftest hermes-render-test/subagent-block-includes-notes ()
  "Notes list formatted as bullets."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'running
                                   :notes ["searching" "found"]))
         (result (hermes--format-subagent sa)))
    (should (string-match (regexp-quote "- searching") result))
    (should (string-match (regexp-quote "- found") result))))

(ert-deftest hermes-render-test/subagent-block-includes-summary ()
  "Complete subagent shows summary and duration."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'complete
                                   :summary "all fixed" :duration 2.5))
         (result (hermes--format-subagent sa)))
    (should (string-match-p "#\\+begin_example" result))
    (should (string-match-p "all fixed" result))
    (should (string-match-p "2.5s" result))))

(ert-deftest hermes-render-test/subagent-block-error-shows-summary ()
  "Error subagent also shows summary and duration."
  (let* ((sa (make-hermes-subagent :id "sa1" :goal "fix" :status 'error
                                   :summary "kaboom" :duration 1.0))
         (result (hermes--format-subagent sa)))
    (should (string-match-p "kaboom" result))
    (should (string-match-p "1.0s" result))))

(ert-deftest hermes-render-test/subagent-blocks-empty-for-empty-vec ()
  "Empty subagents vector produces empty string."
  (should (equal "" (hermes--format-subagents-block [])))
  (should (equal "" (hermes--format-subagents-block nil))))

(ert-deftest hermes-render-test/subagent-blocks-insert-after-tools ()
  "In stream, subagents appear after segment blocks."
  (with-temp-buffer
    (hermes--stream-begin)
    (let* ((stream (make-hermes-stream
                    :segments (vector (make-hermes-segment :type 'text :content "Hello"))
                    :subagents (vector (make-hermes-subagent
                                        :id "sa1" :goal "fix" :status 'running)))))
      (hermes--stream-update nil stream))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match (regexp-quote "Hello") body))
      (should (string-match (regexp-quote "**** fix (running…)") body))
      ;; subagent headline should appear after text segment
      (should (> (string-match (regexp-quote "**** fix (running…)") body)
                 (string-match (regexp-quote "Hello") body))))))

(ert-deftest hermes-render-test/subagent-update-rewrites ()
  "Updating subagents rewrites in place."
  (with-temp-buffer
    (hermes--stream-begin)
    (let* ((s1 (make-hermes-stream
                :segments []
                :subagents (vector (make-hermes-subagent
                                    :id "sa1" :goal "step1" :status 'running))))
           (s2 (make-hermes-stream
                :segments []
                :subagents (vector (make-hermes-subagent
                                    :id "sa2" :goal "step2" :status 'complete)))))
      (hermes--stream-update nil s1)
      (hermes--stream-update s1 s2))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match (regexp-quote "step2") body))
      (should-not (string-match (regexp-quote "step1") body)))))

;;;; Bench region

(defun hermes-render-test--bench-overlay ()
  "Return the bench overlay in the current buffer, or nil."
  (cl-find-if (lambda (o) (overlay-get o 'hermes-bench))
              (overlays-in (point-min) (point-max))))

(ert-deftest hermes-render-test/bench-overlay-spans-live-region ()
  "After `stream-begin' an overlay tagged `hermes-bench' covers the bench."
  (with-temp-buffer
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "live" :id "s1")))
    (let ((ov (hermes-render-test--bench-overlay)))
      (should ov)
      (should (= (overlay-start ov)
                 (marker-position hermes--bench-start)))
      (should (= (overlay-end ov)
                 (marker-position hermes--bench-end)))
      (should (eq (overlay-get ov 'face) 'hermes-bench-face)))))

(ert-deftest hermes-render-test/bench-overlay-removed-on-commit ()
  "After `stream-commit' no bench overlay remains."
  (with-temp-buffer
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "live" :id "s1")))
    (should (hermes-render-test--bench-overlay))
    (hermes--stream-commit)
    (should-not (hermes-render-test--bench-overlay))
    (should (null hermes--bench-start))
    (should (null hermes--bench-end))))

(ert-deftest hermes-render-test/bench-markers-cleared-on-commit ()
  "All stream + bench markers nulled on commit."
  (with-temp-buffer
    (hermes--stream-begin)
    (hermes--stream-commit)
    (dolist (m (list hermes--bench-start
                     hermes--bench-end
                     hermes--stream-segments-start
                     hermes--stream-segments-end
                     hermes--stream-headline-marker))
      (should (null m)))))

(provide 'hermes-render-test)
;;; hermes-render-test.el ends here
