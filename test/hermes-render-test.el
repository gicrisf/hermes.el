;;; hermes-render-test.el --- ERT tests for the streaming renderer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-render)

(defun hermes-render-test--setup ()
  "Initialise an in-flight stream in the current buffer.
Inserts a minimal `** assistant :hermes:' heading and returns the
position right after the heading line."
  (insert "** assistant :hermes:\n")
  (setq hermes--stream-headline-marker (copy-marker 1))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (setq hermes--stream-content-start (copy-marker (point)))
  (set-marker-insertion-type hermes--stream-content-start nil)
  (setq hermes--stream-stable-end (copy-marker (point)))
  (setq hermes--stream-end        (copy-marker (point)))
  (set-marker-insertion-type hermes--stream-stable-end nil)
  (set-marker-insertion-type hermes--stream-end        t)
  (setq hermes--stream-tool-markers nil)
  (point))

(defun hermes-render-test--body ()
  "Return the text after the `** assistant :hermes:' heading line."
  (save-excursion
    (goto-char (marker-position hermes--stream-headline-marker))
    (forward-line 1)
    (buffer-substring-no-properties (point) (point-max))))

(ert-deftest hermes-render-test/single-paragraph-roundtrip ()
  ;; A single paragraph never crosses a `\\n\\n' boundary; all text lives
  ;; in the unstable region and gets rewritten on each delta.
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "Hi")
    (hermes--rewrite-stream "Hi there")
    (should (equal "** assistant :hermes:\nHi there"
                   (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest hermes-render-test/stable-advance-preserves-prose ()
  ;; Regression: when a `\\n\\n' boundary advances, the stable prefix must
  ;; remain in the buffer, not be deleted along with the unstable suffix.
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "Hi there\n\nNew")
    (should (equal "Hi there\n\nNew" (hermes-render-test--body)))
    ;; Stable marker advanced past the stable chunk.
    (should (= (marker-position hermes--stream-stable-end)
               (+ (marker-position hermes--stream-headline-marker)
                  (length "** assistant :hermes:\nHi there\n\n"))))))

(ert-deftest hermes-render-test/multiple-stable-advances ()
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "First.\n\nSecond.")
    (hermes--rewrite-stream "First.\n\nSecond para finished.\n\nThird.")
    (should (equal "First.\n\nSecond para finished.\n\nThird."
                   (hermes-render-test--body)))))

(ert-deftest hermes-render-test/fenced-block-stays-unstable ()
  ;; The stable boundary tracker should not split inside a fence — even if
  ;; a `\\n\\n' appears between the open and close fences.
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "Code:\n\n```python\n\nprint(1)\n```\n")
    (should (equal "Code:\n\n```python\n\nprint(1)\n```\n"
                   (hermes-render-test--body)))))

(ert-deftest hermes-render-test/stable-boundary-finds-last-blank-line ()
  ;; Plain unit test for the boundary helper.
  (should (= 0 (hermes--stable-boundary "no blank lines here")))
  (should (= 5 (hermes--stable-boundary "abc\n\ndef")))
  (should (= 10 (hermes--stable-boundary "abc\n\ndef\n\nghi"))))

(ert-deftest hermes-render-test/stable-boundary-skips-fence ()
  ;; A `\\n\\n' inside a fence does not count.
  (should (= 0 (hermes--stable-boundary "```\n\nfoo\n"))))

(ert-deftest hermes-render-test/stable-chunks-converted-to-org ()
  ;; Stable chunks pass through hermes-md-to-org on insert.
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "I am **strong**.\n\nNext.")
    (should (equal "I am *strong*.\n\nNext."
                   (hermes-render-test--body)))))

(ert-deftest hermes-render-test/commit-flushes-unstable-tail ()
  ;; The residual unstable tail must be converted when the stream commits.
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--rewrite-stream "Hi.\n\nA `code` example")
    ;; "A `code` example" is still unstable here.
    (should (string-match-p "`code`" (hermes-render-test--body)))
    (hermes--stream-commit)
    ;; The markdown got cooked into Org, and the raw backticks are gone.
    (should (string-match-p "A ~code~ example"
                             (buffer-substring-no-properties
                              (point-min) (point-max))))
    (should-not (string-match-p "`code`"
                                 (buffer-substring-no-properties
                                  (point-min) (point-max))))))

(ert-deftest hermes-render-test/thinking-block-inserted-before-text ()
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--update-thinking-block "hmm" nil)
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "#\\+begin_example Thinking\nhmm\n#\\+end_example" body))
      ;; The block sits before the (empty) text region, followed by blank line.
      (should (string-match-p "#\\+end_example\n\n\\'" body)))))

(ert-deftest hermes-render-test/thinking-block-updated-on-change ()
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--update-thinking-block "hmm" nil)
    (hermes--update-thinking-block "hmm maybe" nil)
    (should (string-match-p
             "#\\+begin_example Thinking\nhmm maybe\n#\\+end_example"
             (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest hermes-render-test/thinking-block-removed-when-empty ()
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--update-thinking-block "hmm" nil)
    (hermes--update-thinking-block nil nil)
    (should-not (string-match-p
                 "Thinking"
                 (buffer-substring-no-properties (point-min) (point-max))))))

(ert-deftest hermes-render-test/thinking-and-reasoning-separate-blocks ()
  (with-temp-buffer
    (hermes-render-test--setup)
    (hermes--update-thinking-block "think" "reason")
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "#\\+begin_example Thinking\nthink\n#\\+end_example" body))
      (should (string-match-p "#\\+begin_example Reasoning\nreason\n#\\+end_example" body)))))

(provide 'hermes-render-test)
;;; hermes-render-test.el ends here
