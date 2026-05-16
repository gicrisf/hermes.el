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

;;;; Raw drawer I/O

(ert-deftest hermes-render-test/raw-drawer-insert-and-extract ()
  "Insert a :HERMES_RAW: drawer and read the plist back."
  (with-temp-buffer
    (org-mode)
    (let ((msg (make-hermes-message
                :kind 'user
                :segments (vector (make-hermes-segment
                                   :type 'text :content "Hello" :id "s1"))
                :timestamp "2024-01-15T10:00:00+0000")))
      (insert "* user: hi\n")
      (hermes--insert-raw-drawer msg))
    (goto-char (point-min))
    (let ((plist (hermes--extract-raw-drawer)))
      (should plist)
      (should (eq 'user (plist-get plist :kind)))
      (should (equal "Hello" (plist-get plist :text))))))

(ert-deftest hermes-render-test/raw-drawer-auto-folded ()
  "After insertion, the drawer body is hidden by org folding/overlays."
  (with-temp-buffer
    (org-mode)
    (let ((msg (make-hermes-message
                :kind 'user
                :segments (vector (make-hermes-segment
                                   :type 'text :content "x" :id "s1")))))
      (insert "* user: hi\n")
      (hermes--insert-raw-drawer msg))
    ;; Either an org-fold invisibility region covers the drawer body, or
    ;; the body line carries an invisible text/overlay property.  Look
    ;; for any invisible coverage somewhere between :HERMES_RAW: and :END:.
    (goto-char (point-min))
    (should (re-search-forward "^:HERMES_RAW:" nil t))
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
    ;; Buffer now contains a `* ping :user:' heading with the body.
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (string-match-p "^\\*\\* ping " body))
      (should (string-match-p ":user:" body))
      (should (string-match-p ":HERMES_RAW:" body)))
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
one assistant subtree with exactly one :HERMES_RAW: drawer."
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
    ;; Two `:hermes:' tags now: the session container heading + the assistant turn.
    (should (= 2 (hermes-render-test--count ":hermes:")))
    (should (= 1 (hermes-render-test--count "^:HERMES_RAW:")))
    (should (equal [] (hermes-state-pending-turns hermes--state)))))

(ert-deftest hermes-render-test/error-with-stream-no-duplicate ()
  "Error path pushes [assistant, system] and clears stream.
After render: one assistant subtree, one system heading, system appears
*after* the assistant turn, and each subtree owns exactly one raw drawer."
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
    ;; Container heading + assistant turn both carry the `:hermes:' tag.
    (should (= 2 (hermes-render-test--count ":hermes:")))
    (should (= 1 (hermes-render-test--count ":system:")))
    (should (= 2 (hermes-render-test--count "^:HERMES_RAW:")))
    (let ((body (buffer-substring-no-properties (point-min) (point-max))))
      (should (< (string-match "^\\*\\* " body)
                 (string-match ":system:" body))))))

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
fires.  The assistant raw drawer must land *before* the dequeued user
heading — i.e. inside the assistant subtree, not after it."
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
      ;; Inspect buffer.  Expected order: assistant heading → assistant
      ;; raw drawer → user heading for "next" → user raw drawer for "next".
      (let* ((body (buffer-substring-no-properties (point-min) (point-max)))
             ;; All turns are level-2 siblings under the level-1 session
             ;; container.  The assistant heading is the only `**' line
             ;; carrying `:hermes:'; the user turns carry `:user:'.
             (assist-head (string-match "^\\*\\* .*:hermes:" body))
             (user-next (string-match "^\\*\\* next " body))
             ;; Find the *assistant's* raw drawer: the first :HERMES_RAW:
             ;; that appears after the assistant heading.
             (raw-after-assistant
              (and assist-head
                   (string-match ":HERMES_RAW:" body assist-head))))
        (should assist-head)
        (should user-next)
        (should raw-after-assistant)
        ;; The assistant's raw drawer must sit *between* its heading and
        ;; the dequeued user heading.  If the drawer slid past `user-next',
        ;; we have the corruption described in PLAN.md.
        (should (< assist-head raw-after-assistant))
        (should (< raw-after-assistant user-next))))))

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
                 (format "^%s hello " (regexp-quote expected-stars))
                 body))))))

(provide 'hermes-render-test)
;;; hermes-render-test.el ends here
