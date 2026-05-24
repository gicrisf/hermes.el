;;; hermes-sessions-test.el --- ERT tests for hermes-sessions.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-sessions)

;;;; Helpers

(defun hermes-sessions-test--ht (&rest pairs)
  "Build a string-keyed hash-table from PAIRS (KEY VALUE ...)."
  (let ((h (make-hash-table :test 'equal)))
    (cl-loop for (k v) on pairs by #'cddr
             do (puthash k v h))
    h))

;;;; Field accessors

(ert-deftest hermes-sessions-test/field-hashtable ()
  (let ((h (hermes-sessions-test--ht "id" "abc" "n" 7)))
    (should (equal "abc" (hermes--sessions-field h "id")))
    (should (equal 7 (hermes--sessions-field h "n")))
    (should (null (hermes--sessions-field h "missing")))))

(ert-deftest hermes-sessions-test/field-alist ()
  (let ((a '(("id" . "abc") ("n" . 7))))
    (should (equal "abc" (hermes--sessions-field a "id")))
    (should (equal 7 (hermes--sessions-field a "n")))))

(ert-deftest hermes-sessions-test/short-sid ()
  (should (equal "abcdef01" (hermes--sessions-short-sid "abcdef0123456789")))
  (should (equal "short" (hermes--sessions-short-sid "short")))
  (should (equal "?" (hermes--sessions-short-sid nil))))

(ert-deftest hermes-sessions-test/format-time-cases ()
  (should (equal "—" (hermes--sessions-format-time nil)))
  (should (equal "—" (hermes--sessions-format-time "")))
  (should (string-match-p "^[0-9]\\{4\\}-"
                          (hermes--sessions-format-time 1716285000))))

;;;; Stored row coercion

(ert-deftest hermes-sessions-test/rows-from-vector ()
  (let* ((row (hermes-sessions-test--ht "id" "x"))
         (out (hermes--stored-rows-from-result (vector row))))
    (should (equal (list row) out))))

(ert-deftest hermes-sessions-test/rows-from-list ()
  (let* ((row (hermes-sessions-test--ht "id" "x"))
         (out (hermes--stored-rows-from-result (list row))))
    (should (equal (list row) out))))

(ert-deftest hermes-sessions-test/rows-from-sessions-hash ()
  (let* ((row (hermes-sessions-test--ht "id" "x"))
         (wrap (hermes-sessions-test--ht "sessions" (vector row)))
         (out (hermes--stored-rows-from-result wrap)))
    (should (equal (list row) out))))

;;;; Background-task filter (bg_*)

(ert-deftest hermes-sessions-test/background-row-detected ()
  (should (hermes--stored-row-background-p
           (hermes-sessions-test--ht "id" "bg_20260521_abcd")))
  (should-not (hermes--stored-row-background-p
               (hermes-sessions-test--ht "id" "20260521_HHMMSS_xxx")))
  (should-not (hermes--stored-row-background-p
               (hermes-sessions-test--ht "id" nil))))

(ert-deftest hermes-sessions-test/rows-filter-out-bg ()
  (let* ((user-row (hermes-sessions-test--ht "id" "20260521_a"))
         (bg-row   (hermes-sessions-test--ht "id" "bg_20260521_b"))
         (out (hermes--stored-rows-from-result (list user-row bg-row))))
    (should (equal (list user-row) out))))

(ert-deftest hermes-sessions-test/resume-from-db-refuses-bg ()
  (should-error (hermes-resume-from-db "bg_20260521_c") :type 'user-error))

(ert-deftest hermes-sessions-test/branch-from-db-refuses-bg ()
  (should-error (hermes-branch-from-db "bg_20260521_c") :type 'user-error))

;;;; Annotations

(ert-deftest hermes-sessions-test/stored-annot-uses-title ()
  (let* ((row (hermes-sessions-test--ht
               "title" "Refactor renderer"
               "message_count" 7
               "source" "tui"
               "started_at" 1716285000))
         (out (hermes--stored-annot row)))
    (should (string-match-p "Refactor renderer" out))
    (should (string-match-p "tui" out))
    (should (string-match-p "7 msgs" out))))

(ert-deftest hermes-sessions-test/stored-annot-defaults-to-preview ()
  (let* ((row (hermes-sessions-test--ht "preview" "hello world"))
         (out (hermes--stored-annot row)))
    (should (string-match-p "hello world" out))
    (should (string-match-p "0 msgs" out))))

;;;; Body renderer

(ert-deftest hermes-sessions-test/render-empty ()
  (should (equal "" (hermes--db-messages-to-org-body nil))))

(ert-deftest hermes-sessions-test/render-user-assistant ()
  (let* ((msgs (list (hermes-sessions-test--ht "role" "user"      "text" "hello")
                     (hermes-sessions-test--ht "role" "assistant" "text" "hi there")))
         (out (hermes--db-messages-to-org-body msgs)))
    (should (string-match-p "\\*\\* User\n:PROPERTIES:\n:HERMES_KIND: USER\n:END:\nhello" out))
    (should (string-match-p "\\*\\* Assistant\n:PROPERTIES:\n:HERMES_KIND: ASSISTANT\n:END:\nhi there" out))))

(ert-deftest hermes-sessions-test/render-content-fallback ()
  (let* ((msgs (list (hermes-sessions-test--ht "role" "user" "content" "yo")))
         (out (hermes--db-messages-to-org-body msgs)))
    (should (string-match-p ":HERMES_KIND: USER\n:END:\nyo" out))))

(ert-deftest hermes-sessions-test/render-tool-as-assistant-child ()
  (let* ((msgs (list (hermes-sessions-test--ht "role" "assistant" "text" "let me check")
                     (hermes-sessions-test--ht "role" "tool" "name" "grep" "context" "pattern: foo")))
         (out (hermes--db-messages-to-org-body msgs)))
    (should (string-match-p "\\*\\*\\* Tool (grep)" out))
    (should (string-match-p ":TOOL_NAME: grep" out))
    (should (string-match-p "pattern: foo" out))))

(ert-deftest hermes-sessions-test/render-accepts-vector ()
  (let* ((msgs (vector (hermes-sessions-test--ht "role" "user" "text" "v")))
         (out (hermes--db-messages-to-org-body msgs)))
    (should (string-match-p ":HERMES_KIND: USER\n:END:\nv" out))))

(ert-deftest hermes-sessions-test/render-with-container ()
  (let ((out (hermes--db-messages-to-org nil "SID42")))
    (should (string-match-p "^\\* Hermes session :hermes:" out))
    (should (string-match-p ":HERMES_SESSION: SID42" out))))

(ert-deftest hermes-sessions-test/render-to-buffer-erases-and-rewinds ()
  (with-temp-buffer
    (insert "stale content")
    (hermes--render-db-messages-to-buffer
     (list (hermes-sessions-test--ht "role" "user" "text" "fresh"))
     "SID")
    (should (eq (point) (point-min)))
    (should (string-match-p ":HERMES_SESSION: SID" (buffer-string)))
    (should-not (string-match-p "stale content" (buffer-string)))))

;;;; Parent SID slot + annotation

(ert-deftest hermes-sessions-test/parent-sid-slot-default-nil ()
  (let ((s (make-hermes-state)))
    (should (null (hermes-state-parent-sid s)))))

(ert-deftest hermes-sessions-test/parent-sid-slot-settable ()
  (let ((s (make-hermes-state)))
    (setf (hermes-state-parent-sid s) "parent-123")
    (should (equal "parent-123" (hermes-state-parent-sid s)))))

(ert-deftest hermes-sessions-test/current-annot-shows-parent-arrow ()
  (hermes-test--reset-global-state)
  (with-temp-buffer
    (puthash "child-1" (current-buffer) hermes--org-buffers)
    (hermes--state-slot-write
     "child-1"
     (make-hermes-state :session-id "child-1" :parent-sid "parentXX"))
    (cl-letf (((symbol-function 'hermes--buffer-message-count) (lambda () 3)))
      (let ((out (hermes--current-annot (current-buffer))))
        (should (string-match-p "←parentXX" out))))))

(ert-deftest hermes-sessions-test/current-annot-shows-title-bracket ()
  (hermes-test--reset-global-state)
  (with-temp-buffer
    (puthash "s1" (current-buffer) hermes--org-buffers)
    (let ((info (hermes-sessions-test--ht "model" "claude" "title" "My chat")))
      (hermes--state-slot-write
       "s1"
       (make-hermes-state :session-id "s1" :session-info info)))
    (cl-letf (((symbol-function 'hermes--buffer-message-count) (lambda () 0)))
      (let ((out (hermes--current-annot (current-buffer))))
        (should (string-match-p "\\[My chat\\]" out))))))

(ert-deftest hermes-sessions-test/current-annot-omits-empty-title-and-parent ()
  (hermes-test--reset-global-state)
  (with-temp-buffer
    (puthash "s1" (current-buffer) hermes--org-buffers)
    (hermes--state-slot-write "s1" (make-hermes-state :session-id "s1"))
    (cl-letf (((symbol-function 'hermes--buffer-message-count) (lambda () 0)))
      (let ((out (hermes--current-annot (current-buffer))))
        (should-not (string-match-p "\\[" out))
        (should-not (string-match-p "←" out))))))

;;;; Public commands exist

(ert-deftest hermes-sessions-test/public-commands-defined ()
  (should (fboundp 'hermes-current-sessions))
  (should (fboundp 'hermes-stored-resume))
  (should (fboundp 'hermes-stored-branch))
  (should (fboundp 'hermes-stored-delete))
  (should (fboundp 'hermes-stored-export-as-json))
  (should (fboundp 'hermes-resume-from-db))
  (should (fboundp 'hermes-branch-from-db))
  (should (commandp 'hermes-current-sessions))
  (should (commandp 'hermes-stored-resume))
  ;; Internal helpers must not be M-x-callable — users always pick
  ;; from a list via the hermes-stored-* commands.
  (should-not (commandp 'hermes-resume-from-db))
  (should-not (commandp 'hermes-branch-from-db)))

(provide 'hermes-sessions-test)
;;; hermes-sessions-test.el ends here
