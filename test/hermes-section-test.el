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

;;;; message-text

(ert-deftest hermes-section-test/message-text-concatenates-text-and-reasoning ()
  (let ((m (make-hermes-message
            :kind 'assistant
            :segments
            (vector
             (make-hermes-segment :type 'reasoning :content "think." :id "r")
             (make-hermes-segment :type 'text      :content "say."   :id "t")
             (make-hermes-segment :type 'tool      :content nil      :id "x")))))
    (should (equal "think.say." (hermes-section--message-text m)))))

(ert-deftest hermes-section-test/message-text-empty ()
  (let ((m (make-hermes-message :kind 'user :segments []))) ;; nothing
    (should (equal "(empty)" (hermes-section--message-text m)))))

;;;; excerpt

(ert-deftest hermes-section-test/excerpt-trims-and-truncates ()
  (should (equal "hello world"
                 (hermes-section--excerpt "  hello\n\nworld " 80)))
  (should (equal "abc…"
                 (hermes-section--excerpt "abcdef" 3))))

;;;; format-body

(ert-deftest hermes-section-test/format-body-strips-org-artifacts ()
  (let* ((src (concat
               ":PROPERTIES:\n:HERMES_KIND: USER\n:END:\n"
               "#+TITLE: x\n"
               "#+begin_src elisp\n(+ 1 2)\n#+end_src\n"
               "Hello.\n"))
         (out (hermes-section--format-body src)))
    (should-not (string-match-p ":PROPERTIES:" out))
    (should-not (string-match-p "#\\+TITLE:" out))
    (should-not (string-match-p "#\\+begin_src" out))
    (should (string-match-p "(\\+ 1 2)" out))
    (should (string-match-p "Hello\\." out))))

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
        (should (string-match-p "U: hello there" s))
        (should (string-match-p "A: hi back" s))))))

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
  (hermes-section--message-text msg))

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
