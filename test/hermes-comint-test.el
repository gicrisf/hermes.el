;;; hermes-comint-test.el --- ERT tests for the comint viewer -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)
(require 'hermes-comint)
(require 'hermes-mode)
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
  "Assistant turn renders reasoning, text, and tool blocks."
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
          (should (string-match-p "Reasoning" c))
          (should (string-match-p "thinking step" c))
          (should (string-match-p "Here is the answer" c))
          (should (string-match-p "write_file" c))
          (should (string-match-p "wrote foo" c)))))))

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

(provide 'hermes-comint-test)
;;; hermes-comint-test.el ends here
