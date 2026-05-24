;;; hermes-comint-test.el --- ERT tests for the comint viewer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)
(require 'hermes-comint)
(require 'hermes)
(load (expand-file-name "hermes-test-helpers.el"
                        (file-name-directory
                         (or load-file-name buffer-file-name))))

(defvar hermes-comint-test--counter 0)

(defun hermes-comint-test--fresh-sid ()
  (format "comint-test-%d" (cl-incf hermes-comint-test--counter)))

(defun hermes-comint-test--make-buffer (sid &optional state)
  "Create a hermes-comint-mode buffer for SID, registering STATE if given.
Returns the buffer."
  (when state (puthash sid state hermes--sessions))
  (let* ((name (format "*hermes-comint-test:%s*" sid))
         (buf  (get-buffer-create name)))
    (with-current-buffer buf
      (hermes-comint-mode)
      (setq-local hermes--current-session-id sid)
      (puthash sid buf hermes-comint--buffers)
      (when state (hermes-comint--load-from-state state)))
    buf))

(defmacro hermes-comint-test--with-buffer (buf-var sid-var state &rest body)
  "Bind BUF-VAR and SID-VAR around a fresh comint buffer for STATE."
  (declare (indent 3))
  `(let* ((,sid-var (hermes-comint-test--fresh-sid))
          (,buf-var (hermes-comint-test--make-buffer ,sid-var ,state)))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p ,buf-var) (kill-buffer ,buf-var))
       (remhash ,sid-var hermes--sessions)
       (remhash ,sid-var hermes-comint--buffers))))

(defun hermes-comint-test--committed-text ()
  "Return committed-output substring [point-min, output-end)."
  (buffer-substring-no-properties
   (point-min) (marker-position hermes-comint--output-end)))

;;;; Buffer setup

(ert-deftest hermes-comint-test/setup-establishes-markers ()
  "After mode activation, output-end and prompt-start are well-formed."
  (hermes-comint-test--with-buffer buf sid (make-hermes-state :session-id sid)
    (with-current-buffer buf
      (should (markerp hermes-comint--output-end))
      (should (markerp hermes-comint--prompt-start))
      (should (= 1 (marker-position hermes-comint--output-end)))
      ;; Pending region is empty initially: output-end == prompt-start.
      (should (= (marker-position hermes-comint--output-end)
                 (marker-position hermes-comint--prompt-start)))
      ;; Prompt is at point-max area.
      (should (string-prefix-p hermes-comint--prompt-string
                               (buffer-substring-no-properties
                                (marker-position hermes-comint--prompt-start)
                                (point-max)))))))

;;;; Turn insertion — kinds and segments

(ert-deftest hermes-comint-test/insert-user-turn ()
  "User turn renders heading + body in the committed region."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (msg (make-hermes-message
               :kind 'user
               :segments (vector (make-hermes-segment
                                  :type 'text :content "Hello world"))
               :timestamp (current-time)))
         (state (make-hermes-state
                 :session-id sid
                 :turns (vector msg))))
    (hermes-comint-test--with-buffer buf sid state
      (with-current-buffer buf
        (let ((committed (hermes-comint-test--committed-text)))
          (should (string-match-p "User" committed))
          (should (string-match-p "Hello world" committed)))))))

(ert-deftest hermes-comint-test/insert-assistant-turn-with-all-segments ()
  "Assistant turn renders reasoning, text, and tool blocks in natural order."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (tool (make-hermes-tool :id "t1" :name "write_file"
                                 :status 'complete :summary "wrote foo"))
         (msg (make-hermes-message
               :kind 'assistant
               :segments (vector
                          (make-hermes-segment
                           :type 'reasoning :content "thinking step" :id "r1")
                          (make-hermes-segment
                           :type 'text :content "Here is the answer." :id "t1")
                          (make-hermes-segment
                           :type 'tool :content tool :id "tool1"))
               :timestamp (current-time)))
         (state (make-hermes-state :session-id sid :turns (vector msg))))
    (hermes-comint-test--with-buffer buf sid state
      (with-current-buffer buf
        (let ((c (hermes-comint-test--committed-text)))
          (should (string-match-p "Assistant" c))
          (should (string-match-p "thinking step" c))
          (should (string-match-p "Here is the answer" c))
          (should (string-match-p "write_file" c))
          (should (string-match-p "wrote foo" c))
          (should (< (string-match-p "thinking step" c)
                     (string-match-p "Here is the answer" c)))
          (should (< (string-match-p "Here is the answer" c)
                     (string-match-p "write_file" c))))))))

(ert-deftest hermes-comint-test/insert-system-turn ()
  (let* ((sid (hermes-comint-test--fresh-sid))
         (msg (make-hermes-message
               :kind 'system
               :segments (vector (make-hermes-segment
                                  :type 'text :content "system note"))
               :timestamp (current-time)))
         (state (make-hermes-state :session-id sid :turns (vector msg))))
    (hermes-comint-test--with-buffer buf sid state
      (with-current-buffer buf
        (let ((c (hermes-comint-test--committed-text)))
          (should (string-match-p "System" c))
          (should (string-match-p "system note" c)))))))

;;;; Append-only refresh

(ert-deftest hermes-comint-test/append-only-on-new-turn ()
  "A second refresh appends just the new turn, not a full rebuild."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (m1 (make-hermes-message
              :kind 'user
              :segments (vector (make-hermes-segment :type 'text :content "one"))
              :timestamp (current-time)))
         (s1 (make-hermes-state :session-id sid :turns (vector m1))))
    (hermes-comint-test--with-buffer buf sid s1
      (with-current-buffer buf
        (let* ((after-first (hermes-comint-test--committed-text))
               (m2 (make-hermes-message
                    :kind 'user
                    :segments (vector (make-hermes-segment
                                       :type 'text :content "two"))
                    :timestamp (current-time)))
               (s2 (make-hermes-state :session-id sid
                                      :turns (vector m1 m2))))
          (hermes-comint--append-new-turns s2)
          (let ((after-second (hermes-comint-test--committed-text)))
            (should (string-prefix-p after-first after-second))
            (should (string-match-p "two" after-second))))))))

;;;; Streaming lifecycle

(ert-deftest hermes-comint-test/stream-begin-paints-pending-region ()
  "Stream begin inserts in-flight content into [output-end, prompt-start)."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (initial (make-hermes-state :session-id sid))
         (stream (make-hermes-stream
                  :segments (vector (make-hermes-segment
                                     :type 'text :content "streaming…")))))
    (hermes-comint-test--with-buffer buf sid initial
      (with-current-buffer buf
        (let ((new (make-hermes-state :session-id sid :stream stream)))
          (hermes-comint--stream-begin new)
          (should hermes-comint--stream-active)
          (let ((pending (buffer-substring-no-properties
                          (marker-position hermes-comint--output-end)
                          (marker-position hermes-comint--prompt-start))))
            (should (string-match-p "streaming" pending))))))))

(ert-deftest hermes-comint-test/stream-commit-seals-into-committed ()
  "Stream commit promotes the in-flight turn into the committed region."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (initial (make-hermes-state :session-id sid))
         (stream (make-hermes-stream
                  :segments (vector (make-hermes-segment
                                     :type 'text :content "in flight")))))
    (hermes-comint-test--with-buffer buf sid initial
      (with-current-buffer buf
        (hermes-comint--stream-begin
         (make-hermes-state :session-id sid :stream stream))
        ;; Reducer would push the final message into turns before clearing
        ;; the stream — simulate that.
        (let* ((final (make-hermes-message
                       :kind 'assistant
                       :segments (vector (make-hermes-segment
                                          :type 'text :content "final answer"))
                       :timestamp (current-time)))
               (committed (make-hermes-state :session-id sid
                                             :turns (vector final))))
          (hermes-comint--stream-commit committed)
          (should-not hermes-comint--stream-active)
          ;; Pending region is empty: output-end caught up to prompt-start.
          (should (= (marker-position hermes-comint--output-end)
                     (marker-position hermes-comint--prompt-start)))
          (let ((c (hermes-comint-test--committed-text)))
            (should (string-match-p "final answer" c))))))))

(ert-deftest hermes-comint-test/full-send-cycle-no-duplicate-assistant ()
  "Full hook-driven dispatch — user submit → stream begin → delta → complete.
Reproduces the dup-rendering bug seen when sending from the comint buffer."
  (let* ((sid     (hermes-comint-test--fresh-sid))
         (initial (make-hermes-state :session-id sid))
         (user    (make-hermes-message
                   :kind 'user
                   :segments (vector (make-hermes-segment
                                      :type 'text :content "hi"))
                   :timestamp (current-time)))
         (stream0 (make-hermes-stream :segments []))
         (stream1 (make-hermes-stream
                   :segments (vector (make-hermes-segment
                                      :type 'text :content "Hey."))))
         (final   (make-hermes-message
                   :kind 'assistant
                   :segments (vector (make-hermes-segment
                                      :type 'text :content "Hey."))
                   :timestamp (current-time)))
         (s1 (make-hermes-state :session-id sid :turns (vector user)))
         (s2 (make-hermes-state :session-id sid :turns (vector user)
                                :stream stream0))
         (s3 (make-hermes-state :session-id sid :turns (vector user)
                                :stream stream1))
         (s4 (make-hermes-state :session-id sid
                                :turns (vector user final))))
    (hermes-comint-test--with-buffer buf sid initial
      (with-current-buffer buf
        (let ((hermes--current-session-id sid))
          ;; user-submit
          (puthash sid s1 hermes--sessions)
          (hermes-comint--refresh initial s1)
          ;; message.start
          (puthash sid s2 hermes--sessions)
          (hermes-comint--refresh s1 s2)
          ;; message.delta
          (puthash sid s3 hermes--sessions)
          (hermes-comint--refresh s2 s3)
          ;; message.complete
          (puthash sid s4 hermes--sessions)
          (hermes-comint--refresh s3 s4))
        (let* ((c (buffer-substring-no-properties (point-min) (point-max)))
               (count (cl-count-if
                       (lambda (s) (string-match-p "Assistant" s))
                       (split-string c "\n"))))
          (should (= 1 count)))))))

(ert-deftest hermes-comint-test/reentrant-pending-clear-no-duplicate ()
  "Inner re-entrant firing before outer `message.complete' does not dup the assistant.
Reproduces the observed bug: another subscriber dispatches an
event (e.g. `:pending-turns-clear') from inside the hook chain for
`message.complete'.  The hook then fires recursively in B→C order
*before* the outer A→B firing reaches the comint subscriber.  With the
live-state projection, both invocations converge to the same buffer."
  (let* ((sid     (hermes-comint-test--fresh-sid))
         (initial (make-hermes-state :session-id sid))
         (user    (make-hermes-message
                   :kind 'user
                   :segments (vector (make-hermes-segment
                                      :type 'text :content "hi"))
                   :timestamp (current-time)))
         (stream0 (make-hermes-stream :segments []))
         (final   (make-hermes-message
                   :kind 'assistant
                   :segments (vector (make-hermes-segment
                                      :type 'reasoning :content "match the energy")
                                     (make-hermes-segment
                                      :type 'text :content "Hey."))
                   :timestamp (current-time)))
         ;; A: turns=[user], stream=inflight.   (before message.complete)
         ;; B: turns=[user, assistant], stream=nil.   (after message.complete)
         ;; C: turns=[user, assistant], stream=nil.   (after :pending-turns-clear)
         (sA (make-hermes-state :session-id sid :turns (vector user)
                                :stream stream0))
         (sB (make-hermes-state :session-id sid :turns (vector user final)))
         (sC (make-hermes-state :session-id sid :turns (vector user final))))
    (hermes-comint-test--with-buffer buf sid initial
      (with-current-buffer buf
        (let ((hermes--current-session-id sid))
          ;; Get the buffer into the streaming lifecycle (mirrors what
          ;; message.start did).
          (puthash sid sA hermes--sessions)
          (hermes-comint--refresh initial sA)
          (should hermes-comint--stream-active)
          ;; Outer dispatch reduces A→B and writes B to the slot.
          (puthash sid sB hermes--sessions)
          ;; Now another subscriber runs first, dispatches its inner
          ;; event (B→C), the inner hook fires synchronously, and the
          ;; comint subscriber sees the inner firing BEFORE the outer
          ;; one reaches it.
          (puthash sid sC hermes--sessions)
          (hermes-comint--refresh sB sC)    ; inner firing (B → C)
          (hermes-comint--refresh sA sB))   ; outer firing resumes (A → B)
        ;; Exactly one assistant heading in the buffer.
        (let* ((c (buffer-substring-no-properties (point-min) (point-max)))
               (n (cl-count-if (lambda (s) (string-match-p "Assistant" s))
                               (split-string c "\n"))))
          (should (= 1 n)))
        ;; Pending region empty: commit ran exactly once and snapshot is current.
        (should-not hermes-comint--stream-active)
        (should (= (marker-position hermes-comint--output-end)
                   (marker-position hermes-comint--prompt-start)))))))

;;;; Header line

(ert-deftest hermes-comint-test/header-line-bg-running ()
  (let* ((bt (make-hermes-bg-task :task-id "1" :prompt "p"
                                  :status 'running :created-at "now"))
         (state (make-hermes-state :bg-tasks (vector bt))))
    (should (string-match-p "bg: 1 running"
                            (hermes-comint--format-header-line state)))))

(ert-deftest hermes-comint-test/header-line-bg-complete ()
  (let* ((bt (make-hermes-bg-task :task-id "7" :prompt "p"
                                  :status 'complete :created-at "now"))
         (state (make-hermes-state :bg-tasks (vector bt))))
    (should (string-match-p "bg #7 complete"
                            (hermes-comint--format-header-line state)))))

(ert-deftest hermes-comint-test/header-line-nil-on-empty-state ()
  (should-not (hermes-comint--format-header-line
               (make-hermes-state))))

;;;; Prompt area — text in/out, read-only invariants

(ert-deftest hermes-comint-test/prompt-text-roundtrip ()
  "Typing after prompt prefix is readable + clearable."
  (hermes-comint-test--with-buffer buf sid (make-hermes-state :session-id sid)
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "user typed this")
      (should (equal "user typed this" (hermes-comint--prompt-text)))
      (hermes-comint--clear-prompt)
      (should (equal "" (hermes-comint--prompt-text))))))

(ert-deftest hermes-comint-test/committed-region-is-read-only ()
  "Inserted committed turns carry read-only property."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (msg (make-hermes-message
               :kind 'user
               :segments (vector (make-hermes-segment :type 'text :content "x"))
               :timestamp (current-time)))
         (state (make-hermes-state :session-id sid :turns (vector msg))))
    (hermes-comint-test--with-buffer buf sid state
      (with-current-buffer buf
        (let ((mid (/ (+ (point-min)
                         (marker-position hermes-comint--output-end))
                      2)))
          (should (get-text-property mid 'read-only)))))))

;;;; Open + registry round-trip

(ert-deftest hermes-comint-test/open-registers-and-loads-state ()
  "hermes-comint--open creates a buffer, registers it, loads turns."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (msg (make-hermes-message
               :kind 'user
               :segments (vector (make-hermes-segment
                                  :type 'text :content "hi from open"))
               :timestamp (current-time)))
         (state (make-hermes-state :session-id sid :turns (vector msg))))
    (puthash sid state hermes--sessions)
    (unwind-protect
        (let ((buf (save-window-excursion (hermes-comint--open sid))))
          (should (buffer-live-p buf))
          (should (eq buf (gethash sid hermes-comint--buffers)))
          (with-current-buffer buf
            (should (derived-mode-p 'hermes-comint-mode))
            (should (equal sid hermes--current-session-id))
            (should (string-match-p "hi from open"
                                    (hermes-comint-test--committed-text))))
          (kill-buffer buf))
      (remhash sid hermes--sessions)
      (remhash sid hermes-comint--buffers))))

(ert-deftest hermes-comint-test/detach-removes-from-registry ()
  "Killing the buffer removes the registry entry."
  (let* ((sid (hermes-comint-test--fresh-sid))
         (state (make-hermes-state :session-id sid)))
    (puthash sid state hermes--sessions)
    (unwind-protect
        (let ((buf (save-window-excursion (hermes-comint--open sid))))
          (should (gethash sid hermes-comint--buffers))
          (kill-buffer buf)
          (should-not (gethash sid hermes-comint--buffers)))
      (remhash sid hermes--sessions)
      (remhash sid hermes-comint--buffers))))

;;;; Mode-line formatter

(ert-deftest hermes-comint-test/mode-line-nil-on-empty ()
  "Empty state returns the empty string."
  (should (equal "" (hermes-comint--format-mode-line nil nil))))

(ert-deftest hermes-comint-test/mode-line-basic ()
  "Connection dot and session info appear in the formatted string."
  (let* ((sid "abc12345xyz")
         (state (make-hermes-state :session-id sid :connection 'connected)))
    (let ((s (hermes-comint--format-mode-line state sid)))
      (should (string-match-p "●" s))
      (should (string-match-p "session abc12345 ready" s)))))

(ert-deftest hermes-comint-test/mode-line-model ()
  "Model name (from session-info) appears in the formatted string."
  (let* ((sid "s1")
         (info (let ((h (make-hash-table :test 'equal)))
                 (puthash "model" "claude-opus-4-7" h) h))
         (state (make-hermes-state :session-id sid
                                   :connection 'connected
                                   :session-info info)))
    (should (string-match-p "claude-opus-4-7"
                            (hermes-comint--format-mode-line state sid)))))

(ert-deftest hermes-comint-test/mode-line-streaming-status ()
  "Streaming text from session-scoped UI state appears in the mode-line."
  (hermes-test--reset-global-state)
  (let* ((sid "s2")
         (state (make-hermes-state :session-id sid :connection 'connected))
         (ui    (make-hermes-ui-state :status-text "Thinking…")))
    (puthash sid ui hermes--ui-states)
    (should (string-match-p "Thinking…"
                            (hermes-comint--format-mode-line state sid)))))

(ert-deftest hermes-comint-test/mode-line-usage ()
  "Token counts appear in the formatted string."
  (let* ((sid "s3")
         (usage (let ((h (make-hash-table :test 'equal)))
                  (puthash "tokens_sent" 100 h)
                  (puthash "tokens_received" 250 h) h))
         (state (make-hermes-state :session-id sid
                                   :connection 'connected
                                   :usage usage)))
    (should (string-match-p "(350 tokens)"
                            (hermes-comint--format-mode-line state sid)))))

(ert-deftest hermes-comint-test/mode-line-queue ()
  "Queue length appears in the formatted string."
  (let* ((sid "s4")
         (state (make-hermes-state :session-id sid
                                   :connection 'connected
                                   :queue '("a" "b" "c"))))
    (should (string-match-p "queue: 3"
                             (hermes-comint--format-mode-line state sid)))))

;;;; Image insertion

(ert-deftest hermes-comint-test/image-fallback-terminal ()
  "On terminal, image segment produces [image: name] placeholder before text."
  (let* ((msg (make-hermes-message
               :kind 'user
               :segments (vector
                          (make-hermes-segment
                           :type 'image
                           :content (list :path "/tmp/test.png" :name "test.png"))
                          (make-hermes-segment
                           :type 'text :content "Hello"))
               :timestamp (current-time))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'display-graphic-p) (lambda (&optional _) nil)))
        (hermes-comint--insert-user-body msg))
      (let ((text (buffer-string)))
        (should (string-match-p "\\[image:" text))
        (should (string-match-p "test\\.png" text))
        (should (string-match-p "Hello" text))
        (should (< (string-match-p "\\[image:" text)
                   (string-match-p "Hello" text)))))))

(provide 'hermes-comint-test)
;;; hermes-comint-test.el ends here
