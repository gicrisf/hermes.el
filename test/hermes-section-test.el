;;; hermes-section-test.el --- ERT tests for the magit conversation viewer -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)
(require 'hermes-state)
(require 'hermes-section)
(require 'hermes-test-helpers)

;;;; Fixtures

(defun hermes-section-test--text-seg (s)
  (make-hermes-segment :type 'text :content s :id (format "seg-%s" (sxhash-equal s))))

(defun hermes-section-test--user-msg (id s)
  (make-hermes-message
   :kind 'user
   :id id
   :segments (vector (hermes-section-test--text-seg s))
   :timestamp (current-time)
   :subagents []))

(defun hermes-section-test--assistant-msg (id s)
  (make-hermes-message
   :kind 'assistant
   :id id
   :segments (vector (hermes-section-test--text-seg s))
   :timestamp (current-time)
   :subagents []))

;;;; body-text / heading-text

(ert-deftest hermes-section-test/body-text-joins-text-segments-only ()
  (let ((m (make-hermes-message
            :kind 'assistant
            :segments
            (vector
             (make-hermes-segment :type 'reasoning :content "think." :id "r")
             (make-hermes-segment :type 'text      :content "say."   :id "t")
             (make-hermes-segment :type 'tool      :content nil      :id "x")))))
    ;; Reasoning is rendered as a child section, not joined into body text.
    (should (equal "say." (hermes-section--body-text m)))))

(ert-deftest hermes-section-test/body-text-empty ()
  (let ((m (make-hermes-message :kind 'user :segments [])))
    (should (equal "" (hermes-section--body-text m)))))

(ert-deftest hermes-section-test/heading-text-first-non-blank-line ()
  (let ((m (make-hermes-message
            :kind 'assistant
            :segments
            (vector
             (make-hermes-segment :type 'text
                                  :content "\n\nfirst line\nsecond"
                                  :id "t")))))
    (should (equal "first line" (hermes-section--heading-text m)))))

(ert-deftest hermes-section-test/heading-text-empty-user ()
  (let ((m (make-hermes-message :kind 'user :segments [])))
    (should (equal "(empty)" (hermes-section--heading-text m)))))

(ert-deftest hermes-section-test/heading-text-tool-only-assistant ()
  (let* ((tool (make-hermes-tool :id "t1" :name "calc" :status 'complete))
         (m (make-hermes-message
             :kind 'assistant
             :segments (vector (make-hermes-segment :type 'tool
                                                    :content tool :id "s")))))
    (should (equal "(tool-only turn)" (hermes-section--heading-text m)))))

;;;; tool-body / subagent-body

(ert-deftest hermes-section-test/tool-body-result-precedence ()
  (let ((t1 (make-hermes-tool :id "1" :name "x" :status 'complete
                              :context "ctx" :output "out" :summary "sum"
                              :duration 0.3)))
    (should (equal "input: ctx\nresult: out (0.3s)\n"
                   (hermes-section--tool-body t1))))
  (let ((t2 (make-hermes-tool :id "2" :name "x" :status 'complete
                              :context "ctx" :summary "sum"
                              :duration 0.3)))
    (should (equal "input: ctx\nresult: sum (0.3s)\n"
                   (hermes-section--tool-body t2))))
  (let ((t3 (make-hermes-tool :id "3" :name "x" :status 'complete
                              :context "ctx" :duration 0.3)))
    (should (equal "input: ctx\nresult: (no result) (0.3s)\n"
                   (hermes-section--tool-body t3)))))

(ert-deftest hermes-section-test/tool-body-error ()
  (let ((t1 (make-hermes-tool :id "1" :name "x" :status 'error
                              :context "ctx" :error "boom"
                              :duration 0.5)))
    (should (equal "input: ctx\nerror: boom (0.5s)\n"
                   (hermes-section--tool-body t1)))))

(ert-deftest hermes-section-test/tool-body-no-context ()
  (let ((t1 (make-hermes-tool :id "1" :name "x" :status 'complete
                              :output "out")))
    (should (equal "input: (no input)\nresult: out\n"
                   (hermes-section--tool-body t1)))))

;;;; org-mode fontification (plan 10)

(ert-deftest hermes-section-test/fontify-org-applies-font-lock-face ()
  ;; Bold markdown is converted to Org via hermes-md-to-org, then
  ;; org-mode fontifies the result.  Some character gains font-lock-face.
  (let* ((out (hermes-section--fontify-org "hello **world**"))
         (found nil))
    (let ((i 0) (n (length out)))
      (while (< i n)
        (when (get-text-property i 'font-lock-face out)
          (setq found t))
        (setq i (1+ i))))
    (should found)
    ;; Plain face should be cleared in favor of font-lock-face.
    (let ((i 0) (n (length out)) (face-leaked nil))
      (while (< i n)
        (when (get-text-property i 'face out)
          (setq face-leaked t))
        (setq i (1+ i)))
      (should-not face-leaked))))

(ert-deftest hermes-section-test/fontify-org-empty-noop ()
  (should (equal "" (hermes-section--fontify-org "")))
  (should (equal "" (hermes-section--fontify-org nil))))

(ert-deftest hermes-section-test/subagent-body-omits-empties ()
  (let ((sa (make-hermes-subagent
             :id "s" :goal "g" :status 'complete
             :thinking "" :tools [] :summary "ok" :duration 1.2)))
    (should (equal "result: ok (1.2s)\n"
                   (hermes-section--subagent-body sa)))))

;;;; insert-turn + rebuild

(ert-deftest hermes-section-test/rebuild-empty ()
  (hermes-test--reset-global-state)
  (with-temp-buffer
    (let ((hermes--current-session-id "s1"))
      (hermes-section-mode)
      (setq-local hermes--current-session-id "s1")
      (let ((st (make-hermes-state)))
        (hermes--state-slot-write "s1" st)
        (hermes-section--rebuild st))
      (should (string-match-p "No messages yet" (buffer-string))))))

(ert-deftest hermes-section-test/rebuild-shows-turns ()
  (hermes-test--reset-global-state)
  (with-temp-buffer
    (let ((hermes--current-session-id "s1"))
      (hermes-section-mode)
      (setq-local hermes--current-session-id "s1")
      (let* ((u (hermes-section-test--user-msg "msg-1" "hello there"))
             (a (hermes-section-test--assistant-msg "msg-2" "hi back"))
             (st (make-hermes-state :turns (vector u a))))
        (hermes--state-slot-write "s1" st)
        (hermes-section--rebuild st))
      (let ((s (buffer-string)))
        (should (string-match-p "hello there" s))
        (should (string-match-p "hi back" s))))))

;;;; refresh routing via global hook

(ert-deftest hermes-section-test/refresh-routes-via-current-session ()
  (hermes-test--reset-global-state)
  (let ((buf (generate-new-buffer "*hermes-conv-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hermes-section-mode)
            (setq-local hermes--current-session-id "s1")
            (puthash "s1" buf hermes-section--buffers))
          ;; Initial state: 0 turns
          (let ((st0 (make-hermes-state)))
            (hermes--state-slot-write "s1" st0))
          ;; Append a turn via the reducer's push path
          (let* ((hermes--current-session-id "s1")
                 (u (hermes-section-test--user-msg "msg-1" "first prompt")))
            (let* ((old (hermes--state-slot-read "s1"))
                   (new (make-hermes-state :turns (vector u))))
              (hermes--state-slot-write "s1" new)
              ;; Simulate a dispatch firing
              (run-hook-with-args 'hermes-state-change-hook old new)))
          (with-current-buffer buf
            (should (string-match-p "first prompt" (buffer-string)))))
      (kill-buffer buf))))

;;;; export round-trip (content present in file)

(ert-deftest hermes-section-test/export-writes-org-file ()
  (hermes-test--reset-global-state)
  (let* ((tmp (make-temp-file "hermes-export-" nil ".org"))
         (buf (generate-new-buffer "*hermes-conv-export*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (hermes-section-mode)
            (setq-local hermes--current-session-id "s1"))
          (let* ((u (hermes-section-test--user-msg "msg-1" "ping"))
                 (a (hermes-section-test--assistant-msg "msg-2" "pong"))
                 (st (make-hermes-state :turns (vector u a))))
            (hermes--state-slot-write "s1" st))
          (with-current-buffer buf
            (hermes-section-export tmp))
          (let ((contents (with-temp-buffer
                            (insert-file-contents tmp)
                            (buffer-string))))
            (should (string-match-p "\\* User" contents))
            (should (string-match-p "ping" contents))
            (should (string-match-p "\\* Assistant" contents))
            (should (string-match-p "pong" contents))))
      (kill-buffer buf)
      (ignore-errors (delete-file tmp)))))

;;;; :turns-load round-trip (the reducer hook used by fork)

(ert-deftest hermes-section-test/turns-load-overwrites ()
  (hermes-test--reset-global-state)
  (let* ((u (hermes-section-test--user-msg "msg-x" "x"))
         (st0 (make-hermes-state :turns (vector u)))
         (v (vector
             (hermes-section-test--user-msg "n1" "loaded"))))
    (hermes--state-slot-write "abc" st0)
    (let ((hermes--current-session-id "abc"))
      (hermes-dispatch (cons :turns-load (list :turns v)) "abc"))
    (let* ((st (hermes--state-slot-read "abc"))
           (turns (hermes-state-turns st)))
      (should (= 1 (length turns)))
      (should (equal "loaded"
                     (hermes-section-test--text-of (aref turns 0)))))))

(defun hermes-section-test--text-of (msg)
  (hermes-section--body-text msg))

;;;; Session lookup helpers

(ert-deftest hermes-section-test/most-recent-session-id ()
  (hermes-test--reset-global-state)
  (let* ((older (encode-time 0 0 12 1 1 2020))
         (newer (encode-time 0 0 12 1 1 2025))
         (mu (make-hermes-message :kind 'user :id "a" :segments []
                                   :timestamp older))
         (mn (make-hermes-message :kind 'user :id "b" :segments []
                                   :timestamp newer)))
    (hermes--state-slot-write "old" (make-hermes-state :turns (vector mu)))
    (hermes--state-slot-write "new" (make-hermes-state :turns (vector mn)))
    (should (equal "new" (hermes--most-recent-session-id)))
    (should (hermes--session-exists-p))))

(provide 'hermes-section-test)
;;; hermes-section-test.el ends here
