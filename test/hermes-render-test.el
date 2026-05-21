;;; hermes-render-test.el --- ERT tests for the segmented renderer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)
(require 'hermes-render)
(require 'hermes-mode)

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

(ert-deftest hermes-render-test/format-thinking-segment-is-invisible ()
  "Thinking segments render to the empty string (UI-only via header line)."
  (let ((result (hermes--format-segment
                 (make-hermes-segment :type 'thinking :content "hmm" :id "s1"))))
    (should (equal "" result))))

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
          (s2 (make-hermes-segment :type 'reasoning :content "because" :id "s2"))
          (s3 (make-hermes-segment :type 'text :content "World")))
      (hermes--render-stream-segments (vector s1 s2 s3)))
    (let ((body (hermes-render-test--body)))
      (should (string-match-p "Hello" body))
      (should (string-match-p "because" body))
      (should (string-match-p "World" body))
      (should (< (string-match "Hello" body)
                 (string-match "because" body)))
      (should (< (string-match "because" body)
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

(ert-deftest hermes-render-test/reasoning-renders-block-thinking-hidden ()
  "Reasoning produces a `*** Reasoning' heading; thinking segments do not render."
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'thinking :content "think" :id "s1")
             (make-hermes-segment :type 'reasoning :content "reason" :id "s2")))
    (let ((body (hermes-render-test--body)))
      (should-not (string-match-p "^\\*\\*\\* Thinking" body))
      (should-not (string-match-p "think" body))
      (should (string-match-p "^\\*\\*\\* Reasoning" body))
      (should (string-match-p "reason" body)))))

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

;;;; Content-first headings — helpers

(ert-deftest hermes-render-test/model-short-name-strips-provider-and-suffix ()
  (should (equal "deepseek-v4-flash"
                 (hermes--model-short-name "deepseek/deepseek-v4-flash:free")))
  (should (equal "claude-sonnet-4-6"
                 (hermes--model-short-name "anthropic/claude-sonnet-4-6")))
  (should (equal "gpt-5"
                 (hermes--model-short-name "gpt-5")))
  (should (equal "gpt-5"
                 (hermes--model-short-name "gpt-5:turbo")))
  (should (null (hermes--model-short-name nil)))
  (should (null (hermes--model-short-name ""))))

(ert-deftest hermes-render-test/heading-excerpt-truncation ()
  (let* ((s (make-string 80 ?x))
         (out (hermes--heading-excerpt s)))
    (should (= 60 (length out)))
    (should (string-suffix-p "..." out))))

(ert-deftest hermes-render-test/heading-excerpt-skips-blank-lines ()
  (should (equal "Hello" (hermes--heading-excerpt "\n\nHello\nworld"))))

(ert-deftest hermes-render-test/heading-excerpt-empty ()
  (should (equal "(empty)" (hermes--heading-excerpt "")))
  (should (equal "(empty)" (hermes--heading-excerpt "   \n\n\t")))
  (should (equal "(empty)" (hermes--heading-excerpt nil))))

(ert-deftest hermes-render-test/heading-excerpt-trims-internal-line ()
  (should (equal "Hi there"
                 (hermes--heading-excerpt "   Hi there   \nrest"))))

(ert-deftest hermes-render-test/tag-spacer-keeps-line-under-target ()
  (let* ((heading "** Hey there.")
         (tags ":hermes:deepseek-v4:")
         (spacer (hermes--tag-spacer heading tags))
         (line (format "%s %s %s" heading spacer tags)))
    ;; Spacer is at least one space, and the assembled line lands close
    ;; to (but no longer than) the target column.
    (should (>= (length spacer) 1))
    (should (<= (length line) 78))))

(ert-deftest hermes-render-test/tag-spacer-single-space-on-overflow ()
  (let* ((heading (concat "** " (make-string 80 ?x)))
         (tags ":hermes:"))
    (should (equal " " (hermes--tag-spacer heading tags)))))

;;;; Compact tool heading

(ert-deftest hermes-render-test/tool-heading-includes-gateway-summary ()
  "Tool heading appends gateway-provided summary after `— '."
  (let* ((tool (make-hermes-tool :id "t1" :name "web_search"
                                 :status 'complete
                                 :summary "Did 3 searches"
                                 :duration 1.4))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "— Did 3 searches" result))
    (should (string-match-p "(1.4s)" result))))

(ert-deftest hermes-render-test/tool-heading-without-summary ()
  "Tool heading omits the `— ' separator when no gateway summary."
  (let* ((tool (make-hermes-tool :id "t1" :name "web_search"
                                 :status 'complete :duration 0.2))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "^\\*\\*\\* DONE web_search" result))
    (should-not (string-match-p "—" result))))

(ert-deftest hermes-render-test/tool-heading-error-indicator ()
  "Heading carries an `[error]' indicator when the tool errored."
  (let* ((tool (make-hermes-tool :id "t1" :name "Bash"
                                 :status 'error :error "boom"
                                 :duration 0.1))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "\\[error\\]" result))))

(ert-deftest hermes-render-test/tool-heading-diff-indicator ()
  "Heading carries a `[diff]' indicator when inline-diff is present."
  (let* ((tool (make-hermes-tool :id "t1" :name "Write"
                                 :status 'complete
                                 :inline-diff "- old\n+ new"))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "\\[diff\\]" result))))

(ert-deftest hermes-render-test/tool-diff-ansi-stripped ()
  "ANSI escape sequences in `inline-diff' are stripped before rendering."
  (let* ((tool (make-hermes-tool :id "t1" :name "Write"
                                 :status 'complete
                                 :inline-diff "\e[32m+ new\e[0m\n\e[31m- old\e[0m"))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "#\\+begin_src diff" result))
    (should (string-match-p "^\\+ new$" result))
    (should (string-match-p "^- old$" result))
    (should-not (string-match-p "\e\\[" result))
    (should-not (string-match-p "\033\\[" result))))

(ert-deftest hermes-render-test/tool-heading-todo-indicator ()
  "Heading carries a `[N todo]' indicator counting the todos list."
  (let* ((tool (make-hermes-tool :id "t1" :name "TodoWrite"
                                 :status 'complete
                                 :todos '((:text "a") (:text "b") (:text "c"))))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    (should (string-match-p "\\[3 todo\\]" result))))

(ert-deftest hermes-render-test/tool-empty-body-when-no-content ()
  "Tool with no output/error/diff/todos emits no body content after the
property drawer — just heading + drawer."
  (let* ((tool (make-hermes-tool :id "t1" :name "web_search"
                                 :status 'complete
                                 :summary "Did 3 searches"
                                 :duration 1.4))
         (result (hermes--format-segment
                  (make-hermes-segment :type 'tool :content tool :id "s1"))))
    ;; No `#+begin_example' (would indicate raw body content).
    (should-not (string-match-p "#\\+begin_example" result))
    ;; No diff src block either.
    (should-not (string-match-p "#\\+begin_src diff" result))))

;;;; Reasoning fold lifecycle

(defun hermes-render-test--invisible-at (pos)
  "Return non-nil if POS is covered by an org-fold invisibility overlay."
  (cl-some (lambda (o)
             (memq (overlay-get o 'invisible)
                   '(outline org-fold-outline)))
           (overlays-at pos)))

(ert-deftest hermes-render-test/reasoning-visible-during-streaming ()
  "Reasoning blocks are NOT folded while the stream is live."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'reasoning :content "thinking out loud"
                                  :id "r1")))
    (goto-char (marker-position hermes--stream-segments-start))
    (should (re-search-forward "^\\*\\*\\* Reasoning" nil t))
    ;; Body line below the heading must not be invisible.
    (forward-line 1)
    ;; Skip the properties drawer to the body line.
    (while (and (not (eobp))
                (looking-at "^[ \t]*:"))
      (forward-line 1))
    (should-not (hermes-render-test--invisible-at (point)))))

(ert-deftest hermes-render-test/reasoning-folded-after-commit ()
  "After stream-commit, reasoning blocks are collapsed."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'reasoning :content "because reasons"
                                  :id "r1")))
    (let ((reasoning-pos
           (save-excursion
             (goto-char (marker-position hermes--stream-segments-start))
             (re-search-forward "^\\*\\*\\* Reasoning" nil t)
             (line-end-position))))
      (hermes--stream-commit)
      ;; The position just past the Reasoning heading line should be hidden
      ;; by an outline fold overlay.
      (should (hermes-render-test--invisible-at reasoning-pos)))))

;;;; Meta drawer I/O

(ert-deftest hermes-render-test/meta-drawer-insert-and-extract ()
  "Insert a :HERMES_META: drawer for a turn with metadata and read it back."
  (with-temp-buffer
    (org-mode)
    (let* ((tool (make-hermes-tool :id "t1" :name "ls" :status 'complete
                                   :output "a\nb" :duration 0.5))
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "Hello" :id "s1")
                                   (make-hermes-segment
                                    :type 'tool :content tool :id "s2"))
                 :timestamp "2024-01-15T10:00:00+0000")))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (let ((plist (hermes--extract-meta-drawer)))
      (should plist)
      (let ((tcs (plist-get plist :tool-calls)))
        (should (and (vectorp tcs) (= 1 (length tcs))))
        (should (equal "t1" (plist-get (aref tcs 0) :id)))
        (should (equal "ls" (plist-get (aref tcs 0) :name)))))))

(ert-deftest hermes-render-test/meta-drawer-drops-nil-tool-fields ()
  "Tool plist in :tool-calls omits nil-valued slots."
  (with-temp-buffer
    (org-mode)
    (let* ((tool (make-hermes-tool :id "t1" :name "ls" :status 'complete
                                   :duration 0.1))   ; output / context / etc. nil
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'tool :content tool :id "s1")))))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (let* ((plist (hermes--extract-meta-drawer))
           (tc (aref (plist-get plist :tool-calls) 0)))
      (should-not (plist-member tc :output))
      (should-not (plist-member tc :context))
      (should-not (plist-member tc :error))
      (should-not (plist-member tc :preview))
      (should (equal "t1" (plist-get tc :id)))
      (should (equal 'complete (plist-get tc :status))))))

(ert-deftest hermes-render-test/meta-drawer-drops-zeroed-usage ()
  "Usage with all-zero counters is dropped; meta drawer omitted if it's
the only field."
  (with-temp-buffer
    (org-mode)
    (let* ((usage (let ((h (make-hash-table :test 'equal)))
                    (puthash "input" 0 h)
                    (puthash "output" 0 h)
                    (puthash "total" 0 h)
                    (puthash "model" "deepseek-v4-flash" h)
                    (puthash "cost_status" "unknown" h)
                    h))
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "hi" :id "s1"))
                 :usage usage)))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (should-not (re-search-forward "^:HERMES_META:" nil t))))

(ert-deftest hermes-render-test/meta-drawer-keeps-nonzero-usage ()
  "Usage with at least one non-zero counter is kept; zeros, nils, and
framing keys (:model, :cost_status, :context_max) are stripped."
  (with-temp-buffer
    (org-mode)
    (let* ((usage (let ((h (make-hash-table :test 'equal)))
                    (puthash "input" 0 h)
                    (puthash "output" 42 h)
                    (puthash "total" 42 h)
                    (puthash "model" "m1" h)
                    (puthash "context_max" 1000000 h)
                    h))
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "hi" :id "s1"))
                 :usage usage)))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (should (re-search-forward "^:HERMES_META:" nil t))
    (goto-char (point-min))
    (let* ((plist (hermes--extract-meta-drawer))
           (u (plist-get plist :usage)))
      (should (= 42 (plist-get u :output)))
      (should (= 42 (plist-get u :total)))
      (should-not (plist-member u :input))
      (should-not (plist-member u :model))
      (should-not (plist-member u :context_max)))))

(ert-deftest hermes-render-test/stream-commit-uses-per-turn-usage-not-cumulative ()
  "Regression: the META drawer must carry the just-completed turn's
token deltas, not `hermes-state-usage' (the running session total)."
  (with-temp-buffer
    (hermes-mode)
    ;; Pre-seed session-cumulative usage as if a prior turn ran.
    (setq hermes--state
          (hermes--with-copy hermes--state hermes-state-copy s
            (let ((acc (make-hash-table :test 'equal)))
              (puthash "tokens_sent" 999 acc)
              (puthash "tokens_received" 999 acc)
              (setf (hermes-state-usage s) acc))))
    ;; Stream begins.
    (let* ((old hermes--state)
           (stream (make-hermes-stream
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "Hi" :id "s1"))))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-stream s) stream))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; message.complete with per-turn deltas of 7/3.
    (hermes-dispatch (cons "message.complete"
                           (let ((h (make-hash-table :test 'equal)))
                             (puthash "tokens_sent" 7 h)
                             (puthash "tokens_received" 3 h)
                             h)))
    (let* ((plist (save-excursion
                    (goto-char (point-min))
                    (hermes--extract-meta-drawer)))
           (u (and plist (plist-get plist :usage))))
      (should u)
      (should (= 7 (plist-get u :tokens_sent)))
      (should (= 3 (plist-get u :tokens_received)))
      ;; Session-cumulative is still tracked separately and not in the drawer.
      (should (= 1006 (gethash "tokens_sent" (hermes-state-usage hermes--state)))))))

(ert-deftest hermes-render-test/meta-drawer-drops-framing-only-usage ()
  "Usage carrying only framing (model, context_max, cost_status) and
zero counters is treated as empty; meta drawer is omitted entirely."
  (with-temp-buffer
    (org-mode)
    (let* ((usage (let ((h (make-hash-table :test 'equal)))
                    (puthash "input" 0 h)
                    (puthash "output" 0 h)
                    (puthash "total" 0 h)
                    (puthash "context_used" 0 h)
                    (puthash "model" "deepseek-v4-flash" h)
                    (puthash "context_max" 1000000 h)
                    (puthash "cost_status" "unknown" h)
                    h))
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "hi" :id "s1"))
                 :usage usage)))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (should-not (re-search-forward "^:HERMES_META:" nil t))))

(ert-deftest hermes-render-test/meta-drawer-omitted-when-empty ()
  "A text-only turn with no tools / images / subagents / usage gets no drawer."
  (with-temp-buffer
    (org-mode)
    (let ((msg (make-hermes-message
                :kind 'user
                :segments (vector (make-hermes-segment
                                   :type 'text :content "Hello" :id "s1"))
                :timestamp "2024-01-15T10:00:00+0000")))
      (insert "* user: hi\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (should-not (re-search-forward "^:HERMES_META:" nil t))))

(ert-deftest hermes-render-test/stream-commit-meta-drawer ()
  "After stream-commit on a turn that produces tool segments, the buffer
contains a :HERMES_META: drawer with the tool-calls."
  (with-temp-buffer
    (hermes-mode)
    (let* ((tool (make-hermes-tool :id "t1" :name "ls" :status 'complete
                                   :output "out" :duration 0.1))
           (stream (make-hermes-stream
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "Hi" :id "s1")
                                      (make-hermes-segment
                                       :type 'tool :content tool :id "s2"))))
           (old hermes--state)
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-stream s) stream))))
      (setq hermes--state new)
      (hermes--render old new))
    (let* ((old hermes--state)
           (stream (hermes-state-stream old))
           (msg (hermes--message-from-stream stream nil))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg)
                        (hermes-state-stream s) nil))))
      (setq hermes--state new)
      (hermes--render old new))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^:HERMES_META:" body))
      (should (string-match-p ":tool-calls" body))
      (should (string-match-p "\"t1\"" body)))))

(ert-deftest hermes-render-test/meta-drawer-auto-folded ()
  "After insertion, the meta drawer body is hidden by org folding/overlays."
  (with-temp-buffer
    (org-mode)
    (let* ((tool (make-hermes-tool :id "t1" :name "ls" :status 'complete
                                   :output "x" :duration 0.1))
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'tool :content tool :id "s1")))))
      (insert "* assistant\n")
      (hermes--insert-meta-drawer msg))
    (goto-char (point-min))
    (should (re-search-forward "^:HERMES_META:" nil t))
    (let* ((body-start (1+ (line-end-position)))
           (body-end (save-excursion
                       (re-search-forward "^:END:" nil t)
                       (line-beginning-position)))
           (any-invis nil))
      (save-excursion
        (goto-char body-start)
        (while (< (point) body-end)
          (when (or (get-text-property (point) 'invisible)
                    (cl-some (lambda (o) (overlay-get o 'invisible))
                             (overlays-at (point))))
            (setq any-invis t))
          (forward-char 1)))
      (should any-invis))))

(ert-deftest hermes-render-test/pending-turns-drained-correctly ()
  "Render writes pending-turn messages into the buffer and dispatches a clear."
  (with-temp-buffer
    (hermes-mode)
    (let* ((msg (make-hermes-message
                 :kind 'user
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "ping" :id "s1"))
                 :timestamp "2024-01-15T10:00:00+0000"))
           (old hermes--state)
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s)
                        (vector msg)))))
      ;; Mirror how the state-change hook is invoked: state is swapped
      ;; first, then the renderer runs.  The renderer's own dispatch
      ;; of :pending-turns-clear then operates on the swapped state.
      (setq hermes--state new)
      (hermes--render old new))
    ;; Buffer now contains a `** U: ping' heading with the body.
    ;; Text-only user turn → no :HERMES_META: drawer (intentional).
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^\\*\\* U: ping" body))
      (should (string-match-p ":HERMES_KIND: USER" body))
      (should-not (string-match-p ":HERMES_RAW:" body)))
    ;; And pending-turns was cleared by the dispatched :pending-turns-clear.
    (should (equal [] (hermes-state-pending-turns hermes--state)))))

;;;; Pending-turns drain vs stream-commit interaction

(defun hermes-render-test--count (re)
  "Count occurrences of regexp RE in current buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((n 0))
      (while (re-search-forward re nil t) (cl-incf n))
      n)))

(ert-deftest hermes-render-test/assistant-complete-no-duplicate ()
  "message.complete must not produce a duplicate `** assistant' heading.
The reducer pushes the assistant msg to pending-turns AND clears the
stream in the same step.  The renderer must seal the streaming turn
via stream-commit and skip the assistant in the drain, leaving exactly
one assistant subtree."
  (with-temp-buffer
    (hermes-mode)
    ;; Stage 1: stream begins and accumulates text.
    (let* ((old hermes--state)
           (stream (make-hermes-stream
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "Hello"
                                       :id "s1"))))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-stream s) stream))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; Stage 2: message.complete fires — assistant msg pushed to
    ;; pending-turns AND stream cleared, atomically.
    (let* ((old hermes--state)
           (stream (hermes-state-stream old))
           (msg (hermes--message-from-stream stream nil))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg)
                        (hermes-state-stream s) nil))))
      (setq hermes--state new)
      (hermes--render old new))
    (should (= 1 (hermes-render-test--count "^\\*\\* ")))
    ;; Only the session container heading carries the `:hermes:' tag now;
    ;; the assistant turn uses an `A:' prefix instead.
    (should (= 1 (hermes-render-test--count ":hermes:")))
    (should (= 1 (hermes-render-test--count "^\\*\\* A: ")))
    ;; Text-only assistant turn → no :HERMES_META: drawer.
    (should (= 0 (hermes-render-test--count "^:HERMES_META:")))
    (should (= 0 (hermes-render-test--count "^:HERMES_RAW:")))
    (should (equal [] (hermes-state-pending-turns hermes--state)))))

(ert-deftest hermes-render-test/error-with-stream-no-duplicate ()
  "Error path pushes [assistant, system] and clears stream.
After render: one assistant subtree, one system heading, system appears
  *after* the assistant turn, and each subtree owns exactly one meta drawer."
  (with-temp-buffer
    (hermes-mode)
    ;; Stage 1: stream begins.
    (let* ((old hermes--state)
           (stream (make-hermes-stream
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "partial"
                                       :id "s1"))))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-stream s) stream))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; Stage 2: error — [assistant, system] pushed, stream cleared.
    (let* ((old hermes--state)
           (stream (hermes-state-stream old))
           (amsg (hermes--message-from-stream stream nil))
           (sysmsg (make-hermes-message
                    :kind 'system
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "boom"
                                       :id "sys1"))
                    :timestamp (current-time)))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector amsg sysmsg)
                        (hermes-state-stream s) nil))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; Two level-2 headings now: the assistant turn and the system turn
    ;; (both are siblings under the level-1 session container).
    (should (= 2 (hermes-render-test--count "^\\*\\* ")))
    ;; Only the session container heading carries the `:hermes:' tag now.
    (should (= 1 (hermes-render-test--count ":hermes:")))
    (should (= 1 (hermes-render-test--count "^\\*\\* A: ")))
    (should (= 1 (hermes-render-test--count "^\\*\\* S: ")))
    ;; Text-only turns → no :HERMES_META: drawers.
    (should (= 0 (hermes-render-test--count "^:HERMES_META:")))
    (should (= 0 (hermes-render-test--count "^:HERMES_RAW:")))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (< (string-match "^\\*\\* A: " body)
                 (string-match "^\\*\\* S: " body))))))

(ert-deftest hermes-render-test/pending-turns-assistant-skipped ()
  "Drain with only an assistant in pending-turns inserts nothing,
but still clears the vector via :pending-turns-clear."
  (with-temp-buffer
    (hermes-mode)
    (let* ((old hermes--state)
           (msg (make-hermes-message
                 :kind 'assistant
                 :segments (vector (make-hermes-segment
                                    :type 'text :content "x" :id "s1"))
                 :timestamp (current-time)))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg)))))
      (setq hermes--state new)
      (hermes--render old new))
    (should (= 0 (hermes-render-test--count "^\\*\\* ")))
    (should (equal [] (hermes-state-pending-turns hermes--state)))))

;;;; Queue drain ordering — see PLAN.md "Debug: Queue Drain Corrupts Buffer Structure"

(require 'hermes-input)

(ert-deftest hermes-render-test/queue-drain-order-correct ()
  "Realistic reproduction: user enqueues while busy, then `message.complete'
fires.  The dequeued user heading must land *after* the assistant
subtree has been fully committed (heading + body), not interleaved."
  (cl-letf (((symbol-function 'hermes-rpc-request)
             (lambda (&rest _) nil))
            ((symbol-function 'hermes-rpc-live-p)
             (lambda () t)))
    (with-temp-buffer
      (hermes-mode)
      ;; Stage 1 — session id + initial user msg (idle path).
      (setq hermes--state
            (hermes--with-copy hermes--state hermes-state-copy s
              (setf (hermes-state-session-id s) "sess-1")))
      (hermes-input-send "hi")
      ;; Stage 2 — stream begins, accumulates one chunk.
      (hermes-dispatch (cons "message.start" nil))
      (hermes-dispatch (cons "message.delta"
                             (let ((h (make-hash-table :test 'equal)))
                               (puthash "text" "Hello" h)
                               h)))
      ;; Stage 3 — user types "next" while busy → silently queued.
      (hermes-input-send "next")
      (should (equal '("next") (hermes-state-queue hermes--state)))
      ;; Stage 4 — message.complete: stream-commit, then drain hook fires
      ;; and dequeues + sends "next" (which renders as a `* user:' heading).
      (hermes-dispatch (cons "message.complete" nil))
      ;; Inspect buffer.  Expected order: assistant heading appears
      ;; before the dequeued user heading; assistant's response body
      ;; (the streamed "Hello") sits between them.
      (let* ((body (buffer-substring-no-properties (point-min) (point-max)))
             (assist-head (string-match "^\\*\\* A: " body))
             (user-next (string-match "^\\*\\* U: next" body))
             (resp-body (and assist-head
                             (string-match "Hello" body assist-head))))
        (should assist-head)
        (should user-next)
        (should resp-body)
        (should (< assist-head resp-body))
        (should (< resp-body user-next))))))

;;;; Relative turn levels

(ert-deftest hermes-render-test/turn-level-follows-container ()
  "Turn headings are rendered one level below `hermes--container-level'.
With the default container at level 1, both user turns and the
assistant stream heading are level 2.  Bump the container to level 3
and they shift to level 4."
  (dolist (clevel '(1 3))
    (with-temp-buffer
      (hermes-mode)
      ;; Override the container level the major mode just set.  In real
      ;; life this happens once at mode entry; here we simulate a deeper
      ;; container.  We do NOT rewrite the buffer's existing container
      ;; heading — the test only cares about what subsequent inserts use.
      (setq-local hermes--container-level clevel)
      (let* ((msg (make-hermes-message
                   :kind 'user
                   :segments (vector (make-hermes-segment
                                      :type 'text :content "hello" :id "s1"))
                   :timestamp "2024-01-15T10:00:00+0000"))
             (old hermes--state)
             (new (hermes--with-copy hermes--state hermes-state-copy s
                    (setf (hermes-state-pending-turns s) (vector msg)))))
        (setq hermes--state new)
        (hermes--render old new))
      (let* ((body (buffer-substring-no-properties (point-min) (point-max)))
             (expected-stars (make-string (1+ clevel) ?*)))
        (should (string-match-p
                 (format "^%s U: hello" (regexp-quote expected-stars))
                 body))))))

;;;; Stream paint throttling (Phase 1)

(defun hermes-render-test--apply-stream (stream)
  "Push STREAM into `hermes--state' and run the renderer with old/new diff."
  (let* ((old hermes--state)
         (new (hermes--with-copy hermes--state hermes-state-copy s
                (setf (hermes-state-stream s) stream))))
    (setq hermes--state new)
    (hermes--render old new)))

(ert-deftest hermes-render-test/throttle-defers-subsequent-deltas ()
  "First true delta paints inline and arms the cooldown; deltas arriving
during cooldown stash a pending snapshot instead of painting.
(`stream-begin' is always immediate and does not arm the timer.)"
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 60))      ; effectively never fires
      ;; stream-begin path — immediate, no timer.
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "Hi" :id "s1"))))
      (should (null hermes--stream-render-timer))
      ;; First real delta — paints inline AND arms cooldown.
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "Hi!" :id "s1"))))
      (should (timerp hermes--stream-render-timer))
      (should (null hermes--stream-render-pending))
      (let ((tick (buffer-modified-tick)))
        ;; Three rapid follow-up deltas during cooldown — none paint.
        (dolist (txt '("Hi there" "Hi there." "Hi there.."))
          (hermes-render-test--apply-stream
           (make-hermes-stream
            :segments (vector (make-hermes-segment
                               :type 'text :content txt :id "s1")))))
        (should (= tick (buffer-modified-tick)))
        (should hermes--stream-render-pending)
        (should (eq hermes--stream-render-pending
                    (hermes-state-stream hermes--state)))))
    ;; Cancel the far-future timer so it can't fire into the dead buffer.
    (hermes--stream-flush-cancel)))

(ert-deftest hermes-render-test/throttle-disabled-paints-every-delta ()
  "Throttle = 0 reproduces the legacy behaviour: every delta paints, no timer."
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 0))
      ;; stream-begin
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "a" :id "s1"))))
      (should (null hermes--stream-render-timer))
      ;; Two deltas back-to-back, both paint, no timer ever arms.
      (let ((tick (buffer-modified-tick)))
        (hermes-render-test--apply-stream
         (make-hermes-stream
          :segments (vector (make-hermes-segment
                             :type 'text :content "ab" :id "s1"))))
        (should (> (buffer-modified-tick) tick))
        (should (null hermes--stream-render-timer))
        (let ((tick2 (buffer-modified-tick)))
          (hermes-render-test--apply-stream
           (make-hermes-stream
            :segments (vector (make-hermes-segment
                               :type 'text :content "abc" :id "s1"))))
          (should (> (buffer-modified-tick) tick2))
          (should (null hermes--stream-render-timer)))))))

(ert-deftest hermes-render-test/throttle-commit-flushes-pending ()
  "stream-commit must paint pending segments synchronously before tearing
down the bench, so the final tokens never get dropped."
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 60))
      ;; First delta paints "Hi" inline and arms the cooldown.
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "Hi" :id "s1"))))
      ;; Second delta is deferred ("Hi world" stays in pending).
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "Hi world" :id "s1"))))
      ;; Commit: stream → nil with a pending assistant in pending-turns.
      (let* ((old hermes--state)
             (stream (hermes-state-stream old))
             (msg (hermes--message-from-stream stream nil))
             (new (hermes--with-copy hermes--state hermes-state-copy s
                    (setf (hermes-state-pending-turns s) (vector msg)
                          (hermes-state-stream s) nil))))
        (setq hermes--state new)
        (hermes--render old new))
      ;; Buffer must contain the latest text, timer must be gone.
      (should (null hermes--stream-render-timer))
      (should (null hermes--stream-render-pending))
      (should (string-match-p "Hi world"
                              (buffer-substring-no-properties
                               (point-min) (point-max)))))))

(ert-deftest hermes-render-test/throttle-cancelled-on-minor-mode-off ()
  "Disabling the minor mode cancels any in-flight throttle timer."
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 60))
      ;; stream-begin then a real delta to arm the timer.
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "x" :id "s1"))))
      (hermes-render-test--apply-stream
       (make-hermes-stream
        :segments (vector (make-hermes-segment
                           :type 'text :content "xy" :id "s1"))))
      (should (timerp hermes--stream-render-timer))
      (hermes-minor-mode -1)
      (should (null hermes--stream-render-timer))
      (should (null hermes--stream-render-pending)))))

;;;; Incremental segment rendering (Phase 2)

(ert-deftest hermes-render-test/incremental-noop-on-identical-segments ()
  "Re-rendering the exact same segments must not touch the buffer."
  (with-temp-buffer
    (hermes--stream-begin)
    (let ((segs (vector (make-hermes-segment
                         :type 'text :content "hello" :id "s1"))))
      (hermes--render-stream-segments segs)
      (let ((tick (buffer-modified-tick)))
        (hermes--render-stream-segments segs)
        (should (= tick (buffer-modified-tick)))))
    (should (= 1 (length hermes--stream-segments-snapshot)))))

(ert-deftest hermes-render-test/incremental-preserves-prior-segments ()
  "Appending a new segment must NOT re-insert the prior ones.
We prove this by tagging a character inside segment 0's text with a
buffer-local text property and verifying that property survives the
second render."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "first" :id "s1")))
    ;; Tag a position inside the rendered first segment.
    (let ((tag-pos (save-excursion
                     (goto-char (marker-position hermes--stream-segments-start))
                     (search-forward "first")
                     (1- (point)))))
      (put-text-property tag-pos (1+ tag-pos) 'hermes-test-tag t)
      ;; Render again with an additional segment appended.
      (hermes--render-stream-segments
       (vector (make-hermes-segment :type 'text :content "first" :id "s1")
               (make-hermes-segment :type 'reasoning :content "why" :id "s2")))
      ;; Tag must still be at its original position — segment 0 was not
      ;; re-inserted.
      (should (get-text-property tag-pos 'hermes-test-tag))
      (should (= 2 (length hermes--stream-segments-snapshot))))))

(ert-deftest hermes-render-test/incremental-replaces-grown-segment ()
  "When a text segment grows, only that segment's region is rewritten.
The snapshot length must match the new content."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "Hi" :id "s1")))
    (let ((snap-before (aref hermes--stream-segments-snapshot 0)))
      (hermes--render-stream-segments
       (vector (make-hermes-segment :type 'text :content "Hi there" :id "s1")))
      (let ((snap-after (aref hermes--stream-segments-snapshot 0)))
        (should (> (plist-get snap-after :length)
                   (plist-get snap-before :length)))
        (should (equal "s1" (plist-get snap-after :id)))
        (should (eq 'text (plist-get snap-after :type)))))
    (let ((body (buffer-substring-no-properties
                 (marker-position hermes--stream-segments-start)
                 (marker-position hermes--stream-segments-end))))
      (should (string-match-p "Hi there" body)))))

(ert-deftest hermes-render-test/incremental-truncates-orphan-segments ()
  "Shrinking the segment vector deletes the trailing region."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "keep" :id "s1")
             (make-hermes-segment :type 'reasoning :content "drop" :id "s2")))
    (should (= 2 (length hermes--stream-segments-snapshot)))
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "keep" :id "s1")))
    (should (= 1 (length hermes--stream-segments-snapshot)))
    (let ((body (buffer-substring-no-properties
                 (marker-position hermes--stream-segments-start)
                 (marker-position hermes--stream-segments-end))))
      (should (string-match-p "keep" body))
      (should-not (string-match-p "drop" body)))))

(ert-deftest hermes-render-test/incremental-fallback-on-id-mismatch ()
  "Differing ids at the same slot trigger the fallback rebuild; the new
content must end up in the buffer and the snapshot."
  (with-temp-buffer
    (org-mode)
    (hermes--stream-begin)
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "alpha" :id "a")
             (make-hermes-segment :type 'text :content "beta" :id "b")))
    ;; Same id at index 0, but index 1 swaps id.  Fallback rebuild
    ;; from index 1 should drop "beta" and insert "gamma".
    (hermes--render-stream-segments
     (vector (make-hermes-segment :type 'text :content "alpha" :id "a")
             (make-hermes-segment :type 'text :content "gamma" :id "c")))
    (should (equal "c" (plist-get (aref hermes--stream-segments-snapshot 1)
                                  :id)))
    (let ((body (buffer-substring-no-properties
                 (marker-position hermes--stream-segments-start)
                 (marker-position hermes--stream-segments-end))))
      (should (string-match-p "alpha" body))
      (should (string-match-p "gamma" body))
      (should-not (string-match-p "beta" body)))))

;;;; Adaptive throttle (Phase 3)

(ert-deftest hermes-render-test/adaptive-interval-steps-up ()
  "Interval grows with rendered text size."
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 0))
      ;; No snapshot → 0 chars → smallest step (25 Hz).
      (should (= 0.04 (hermes--adaptive-throttle-interval)))
      (setq hermes--stream-segments-snapshot
            (vector (list :length 500)))
      (should (= 0.04 (hermes--adaptive-throttle-interval)))
      (setq hermes--stream-segments-snapshot
            (vector (list :length 3000)))
      (should (= 0.20 (hermes--adaptive-throttle-interval)))
      (setq hermes--stream-segments-snapshot
            (vector (list :length 8000)))
      (should (= 1.00 (hermes--adaptive-throttle-interval)))
      (setq hermes--stream-segments-snapshot
            (vector (list :length 15000)))
      (should (= 2.00 (hermes--adaptive-throttle-interval))))))

(ert-deftest hermes-render-test/adaptive-floor-respects-custom-variable ()
  "`hermes-render-stream-throttle' acts as a minimum interval."
  (with-temp-buffer
    (hermes-mode)
    (let ((hermes-render-stream-throttle 1.0))
      (setq hermes--stream-segments-snapshot
            (vector (list :length 100)))
      (should (= 1.0 (hermes--adaptive-throttle-interval)))
      ;; 50k chars would step to 2.0, but the floor pins it to 1.0.
      ;; (Floor is a *minimum*, not a *maximum* — so 2.0 wins here.)
      ;; The plan's expectation is that floor=1.0 yields 1.0 for huge
      ;; text because 1.0 > stepped(50k)?  No: stepped(50k) = 2.0 > 1.0,
      ;; so max = 2.0.  Test the documented semantics: floor is a lower
      ;; bound, not a cap.
      (setq hermes--stream-segments-snapshot
            (vector (list :length 50000)))
      (should (= 2.0 (hermes--adaptive-throttle-interval))))))

(ert-deftest hermes-render-test/commit-refreshes-committed-region ()
  "After stream-commit, the committed assistant region must receive
indent + drawer-hide + fold passes.  Regression: previously
`hermes--finalize-assistant-heading' and the drawer insert ran inside
`with-silent-modifications', stripping `line-prefix' from the
rewritten heading and leaving any drawer body visible.

Uses a tool segment to force a :HERMES_META: drawer (text-only turns
omit the drawer entirely under v2)."
  (with-temp-buffer
    (hermes-mode)
    (org-indent-mode 1)
    ;; Stage 1: stream begins with text + a tool segment so we get a meta drawer.
    (let* ((old hermes--state)
           (tool (make-hermes-tool :id "t1" :name "ls" :status 'complete
                                   :output "out" :duration 0.1))
           (stream (make-hermes-stream
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "Hello" :id "s1")
                                      (make-hermes-segment
                                       :type 'tool :content tool :id "s2"))))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-stream s) stream))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; Stage 2: commit (message.complete).
    (let* ((old hermes--state)
           (stream (hermes-state-stream old))
           (msg (hermes--message-from-stream stream nil))
           (new (hermes--with-copy hermes--state hermes-state-copy s
                  (setf (hermes-state-pending-turns s) (vector msg)
                        (hermes-state-stream s) nil))))
      (setq hermes--state new)
      (hermes--render old new))
    ;; The :HERMES_META: drawer body should be hidden (invisible overlay).
    (goto-char (point-min))
    (should (re-search-forward "^:HERMES_META:" nil t))
    (let ((drawer-invis nil))
      (save-excursion
        (forward-line 1)
        (setq drawer-invis
              (or (get-text-property (point) 'invisible)
                  (cl-some (lambda (o) (overlay-get o 'invisible))
                           (overlays-at (point))))))
      (should drawer-invis))
    ;; The assistant heading line should have a `line-prefix' property,
    ;; proving `org-indent-add-properties' ran on the rewritten heading.
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\* " nil t))
    (should (get-text-property (line-beginning-position) 'line-prefix))))

;;;; Tail-following windows after commit

(ert-deftest hermes-render-test/window-follows-tail-on-stream-commit ()
  "A window pinned to `point-max' advances after non-bench `stream-commit'."
  (let ((buf (generate-new-buffer " *hermes-render-test-window*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (hermes-mode)
            ;; Stage 1 — stream begins.
            (let* ((old hermes--state)
                   (stream (make-hermes-stream
                            :segments (vector (make-hermes-segment
                                               :type 'text :content "Hello"
                                               :id "s1"))))
                   (new (hermes--with-copy hermes--state hermes-state-copy s
                          (setf (hermes-state-stream s) stream))))
              (setq hermes--state new)
              (hermes--render old new))
            ;; Pin the window to point-max and remember it.
            (let ((win (selected-window))
                  (pre-pmax (point-max)))
              (set-window-point win pre-pmax)
              (should (= (window-point win) pre-pmax))
              ;; Stage 2 — message.complete: stream cleared, no pending-turn
              ;; (assistant commit goes through `hermes--stream-commit',
              ;; which sets `committed-region').
              (let* ((old hermes--state)
                     (new (hermes--with-copy hermes--state hermes-state-copy s
                            (setf (hermes-state-stream s) nil))))
                (setq hermes--state new)
                (hermes--render old new))
              (should (> (point-max) pre-pmax))
              (should (= (window-point win) (point-max))))))
      (kill-buffer buf))))

(ert-deftest hermes-render-test/window-not-followed-when-scrolled-up ()
  "If `window-point' is above the tail, the renderer leaves it alone."
  (let ((buf (generate-new-buffer " *hermes-render-test-window-scrolled*")))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (hermes-mode)
            (let* ((old hermes--state)
                   (stream (make-hermes-stream
                            :segments (vector (make-hermes-segment
                                               :type 'text :content "Hello"
                                               :id "s1"))))
                   (new (hermes--with-copy hermes--state hermes-state-copy s
                          (setf (hermes-state-stream s) stream))))
              (setq hermes--state new)
              (hermes--render old new))
            (let* ((win (selected-window))
                   (parked (point-min)))
              (set-window-point win parked)
              (let* ((old hermes--state)
                     (new (hermes--with-copy hermes--state hermes-state-copy s
                            (setf (hermes-state-stream s) nil))))
                (setq hermes--state new)
                (hermes--render old new))
              (should (= (window-point win) parked)))))
      (kill-buffer buf))))

;;;; Image segment formatting

(ert-deftest hermes-render-test/format-image-segment-existing-file ()
  "Existing file → Org `[[file:...]]' link."
  (let* ((tmp (make-temp-file "hermes-img" nil ".png"))
         (seg (make-hermes-segment
               :type 'image
               :content (list :path tmp :name (file-name-nondirectory tmp))
               :id "s1")))
    (unwind-protect
        (let ((out (hermes--format-segment seg)))
          (should (string-match-p (regexp-quote (format "[[file:%s]]" tmp)) out)))
      (delete-file tmp))))

(ert-deftest hermes-render-test/format-image-segment-missing-file ()
  "Missing path → placeholder including the file name."
  (let* ((seg (make-hermes-segment
               :type 'image
               :content (list :path "/nonexistent/cat.png" :name "cat.png")
               :id "s1"))
         (out (hermes--format-segment seg)))
    (should (string-match-p "image: cat.png (not found)" out))))

(ert-deftest hermes-render-test/format-image-segment-nil-path ()
  "Nil path (deserialised after file vanished) → placeholder uses :name."
  (let* ((seg (make-hermes-segment
               :type 'image
               :content (list :path nil :name "ghost.png")
               :id "s1"))
         (out (hermes--format-segment seg)))
    (should (string-match-p "image: ghost.png (not found)" out))))

(require 'hermes-bg)

(ert-deftest hermes-render-test/bg-task-buffer-created-on-complete ()
  "`hermes--render-bg-task' creates a `*hermes-bg:sid:tid*' buffer with
the expected heading, properties, body, and `:HERMES_META:' drawer."
  (let* ((task (make-hermes-bg-task
                :task-id "t42" :prompt "analyze logs"
                :status 'complete :result "found 3 errors"
                :created-at "2026-05-21T00:00:00+0000"
                :completed-at "2026-05-21T00:00:01+0000"))
         (buf-name "*hermes-bg:sid1:t42*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (hermes--render-bg-task "sid1" task)
    (let ((buf (get-buffer buf-name)))
      (should (buffer-live-p buf))
      (with-current-buffer buf
        (should (derived-mode-p 'hermes-bg-mode))
        (let ((text (buffer-string)))
          (should (string-match-p "^\\* Background: analyze logs" text))
          (should (string-match-p ":HERMES_TASK_ID: t42" text))
          (should (string-match-p ":HERMES_STATUS: complete" text))
          (should (string-match-p "found 3 errors" text))
          (should (string-match-p ":HERMES_META:" text))
          (should (string-match-p ":task-id \"t42\"" text))))
      (kill-buffer buf))))

(ert-deftest hermes-render-test/bg-task-buffer-error-uses-example-block ()
  (let* ((task (make-hermes-bg-task
                :task-id "tE" :prompt "boom"
                :status 'error :error "exploded"
                :created-at "x" :completed-at "y"))
         (buf-name "*hermes-bg:s:tE*"))
    (when (get-buffer buf-name) (kill-buffer buf-name))
    (hermes--render-bg-task "s" task)
    (with-current-buffer buf-name
      (let ((text (buffer-string)))
        (should (string-match-p ":HERMES_STATUS: error" text))
        (should (string-match-p "#\\+begin_example Error" text))
        (should (string-match-p "exploded" text))))
    (kill-buffer buf-name)))

(provide 'hermes-render-test)
;;; hermes-render-test.el ends here
