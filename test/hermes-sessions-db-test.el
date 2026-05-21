;;; hermes-sessions-db-test.el --- ERT tests for hermes-sessions-db.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-sessions-db)

;;;; Helpers

(defun hermes-sessions-db-test--ht (&rest pairs)
  "Build a string-keyed hash-table from PAIRS (KEY VALUE ...)."
  (let ((h (make-hash-table :test 'equal)))
    (cl-loop for (k v) on pairs by #'cddr
             do (puthash k v h))
    h))

;;;; Mode setup

(ert-deftest hermes-sessions-db-test/mode-inherits-tabulated ()
  (with-temp-buffer
    (hermes-sessions-db-mode)
    (should (derived-mode-p 'tabulated-list-mode))))

(ert-deftest hermes-sessions-db-test/keymap-bindings ()
  (should (eq #'hermes-sessions-db-pick
              (lookup-key hermes-sessions-db-mode-map (kbd "RET"))))
  (should (eq #'hermes-sessions-db-delete
              (lookup-key hermes-sessions-db-mode-map (kbd "d"))))
  (should (eq #'hermes-sessions-db-refresh
              (lookup-key hermes-sessions-db-mode-map (kbd "g"))))
  (should (eq #'hermes-sessions-db-toggle-cwd-filter
              (lookup-key hermes-sessions-db-mode-map (kbd "c"))))
  (should (eq #'hermes-sessions-db-jump-to-live
              (lookup-key hermes-sessions-db-mode-map (kbd "l")))))

;;;; Row → entry conversion

(ert-deftest hermes-sessions-db-test/row-to-entry-hashtable ()
  (let* ((row (hermes-sessions-db-test--ht
               "id" "abcdef1234567890"
               "title" "Refactor renderer"
               "message_count" 7
               "source" "tui"
               "started_at" 1716285000))
         (entry (hermes-sessions-db--row->entry row))
         (vec   (cadr entry)))
    (should (equal (car entry) "abcdef1234567890"))
    (should (equal (aref vec 0) "abcdef12"))
    (should (string-match-p "Refactor renderer" (aref vec 1)))
    (should (equal (aref vec 2) "7"))
    (should (equal (aref vec 3) "tui"))
    (should (string-match-p "^[0-9]\\{4\\}-" (aref vec 4)))))

(ert-deftest hermes-sessions-db-test/row-to-entry-defaults ()
  (let* ((row (hermes-sessions-db-test--ht "id" "x"))
         (entry (hermes-sessions-db--row->entry row))
         (vec (cadr entry)))
    (should (equal (aref vec 0) "x"))
    (should (equal (aref vec 1) ""))
    (should (equal (aref vec 2) "0"))
    (should (equal (aref vec 3) "—"))
    (should (equal (aref vec 4) "—"))))

;;;; DB → Org renderer

(ert-deftest hermes-sessions-db-test/render-empty-messages ()
  (let ((out (hermes--db-messages-to-org nil "SID42")))
    (should (string-match-p "^\\* Hermes session :hermes:" out))
    (should (string-match-p ":HERMES_SESSION: SID42" out))))

(ert-deftest hermes-sessions-db-test/render-user-assistant-pair ()
  (let* ((msgs (list (hermes-sessions-db-test--ht "role" "user"     "text" "hello")
                     (hermes-sessions-db-test--ht "role" "assistant" "text" "hi there")))
         (out (hermes--db-messages-to-org msgs "S")))
    (should (string-match-p "\\*\\* User\n:PROPERTIES:\n:HERMES_KIND: USER\n:END:\nhello" out))
    (should (string-match-p "\\*\\* Assistant\n:PROPERTIES:\n:HERMES_KIND: ASSISTANT\n:END:\nhi there" out))))

(ert-deftest hermes-sessions-db-test/render-accepts-content-key ()
  ;; Defensive: some shapes use `content' instead of `text'.
  (let* ((msgs (list (hermes-sessions-db-test--ht "role" "user" "content" "yo")))
         (out (hermes--db-messages-to-org msgs "S")))
    (should (string-match-p ":HERMES_KIND: USER\n:END:\nyo" out))))

(ert-deftest hermes-sessions-db-test/render-tool-as-assistant-child ()
  (let* ((msgs (list (hermes-sessions-db-test--ht "role" "assistant" "text" "let me check")
                     (hermes-sessions-db-test--ht "role" "tool" "name" "grep" "context" "pattern: foo")))
         (out (hermes--db-messages-to-org msgs "S")))
    (should (string-match-p "\\*\\*\\* Tool (grep)" out))
    (should (string-match-p ":TOOL_NAME: grep" out))
    (should (string-match-p "pattern: foo" out))))

(ert-deftest hermes-sessions-db-test/render-orphan-tool-without-assistant ()
  ;; A tool message before any assistant — should still render (as top-level **).
  (let* ((msgs (list (hermes-sessions-db-test--ht "role" "tool" "name" "x" "context" "y")))
         (out (hermes--db-messages-to-org msgs "S")))
    (should (string-match-p "^\\*\\*\\* Tool (x)" out))))

(ert-deftest hermes-sessions-db-test/render-accepts-vector ()
  (let* ((msgs (vector (hermes-sessions-db-test--ht "role" "user" "text" "v")))
         (out (hermes--db-messages-to-org msgs "S")))
    (should (string-match-p ":HERMES_KIND: USER\n:END:\nv" out))))

(ert-deftest hermes-sessions-db-test/render-to-buffer-inserts-and-rewinds ()
  (with-temp-buffer
    (insert "stale content")
    (hermes--render-db-messages-to-buffer
     (list (hermes-sessions-db-test--ht "role" "user" "text" "fresh"))
     "SID")
    (should (eq (point) (point-min)))
    (should (string-match-p ":HERMES_SESSION: SID" (buffer-string)))
    (should-not (string-match-p "stale content" (buffer-string)))))

;;;; Body-only renderer (Phase 4 integration helper)

(ert-deftest hermes-sessions-db-test/body-renderer-no-container ()
  (let* ((msgs (list (hermes-sessions-db-test--ht "role" "user" "text" "ping")))
         (out (hermes--db-messages-to-org-body msgs)))
    (should-not (string-match-p "^\\* Hermes session" out))
    (should-not (string-match-p ":HERMES_SESSION:" out))
    (should (string-match-p ":HERMES_KIND: USER" out))
    (should (string-match-p "^\\*\\* User" out))))

(ert-deftest hermes-sessions-db-test/body-renderer-empty ()
  (should (equal "" (hermes--db-messages-to-org-body nil))))

(provide 'hermes-sessions-db-test)
;;; hermes-sessions-db-test.el ends here
