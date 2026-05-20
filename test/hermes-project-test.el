;;; hermes-project-test.el --- ERT tests for hermes-project -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'hermes-state)
(require 'hermes-project)
(require 'hermes-input)

;;;; Helpers

(defmacro hermes-project-test--with-tmp-project (var &rest body)
  "Create a temp git project, bind its root to VAR, run BODY, then clean up."
  (declare (indent 1))
  `(let* ((,var (file-name-as-directory (make-temp-file "hermes-proj-" t))))
     (unwind-protect
         (progn
           (let ((default-directory ,var))
             (call-process "git" nil nil nil "init" "-q"))
           ;; Seed two tracked files and one modified one.
           (with-temp-file (expand-file-name "a.el" ,var) (insert "(provide 'a)"))
           (with-temp-file (expand-file-name "b.el" ,var) (insert "(provide 'b)"))
           ,@body)
       (delete-directory ,var t))))

;;;; detect-cwd

(ert-deftest hermes-project-test/detect-cwd-in-git-repo ()
  (hermes-project-test--with-tmp-project root
    (let* ((default-directory root)
           (detected (hermes-project-detect-cwd)))
      (should detected)
      (should (file-equal-p detected root)))))

(ert-deftest hermes-project-test/detect-cwd-honors-arg ()
  (hermes-project-test--with-tmp-project root
    (let ((detected (hermes-project-detect-cwd root)))
      (should detected)
      (should (file-equal-p detected root)))))

;;;; build-context

(ert-deftest hermes-project-test/build-context-nil-without-cwd ()
  (let ((hermes--state (make-hermes-state)))
    (should (null (hermes-project--build-context hermes--state)))))

(ert-deftest hermes-project-test/build-context-respects-max-files ()
  (hermes-project-test--with-tmp-project root
    ;; Add several files so the cap matters.
    (dotimes (i 25)
      (with-temp-file (expand-file-name (format "f%02d.el" i) root)
        (insert ";; stub")))
    (let* ((default-directory root)
           (st (make-hermes-state :cwd root))
           (hermes--state st)
           (hermes-project-context-max-files 3)
           (ctx (hermes-project--build-context st)))
      (should (stringp ctx))
      ;; Body has at most 3 lines starting with " ".
      (let ((file-lines
             (cl-count-if (lambda (l) (string-prefix-p " " l))
                          (split-string ctx "\n"))))
        (should (<= file-lines 3))))))

(ert-deftest hermes-project-test/build-context-respects-max-chars ()
  (hermes-project-test--with-tmp-project root
    (let* ((default-directory root)
           (st (make-hermes-state :cwd root))
           (hermes--state st)
           (hermes-project-context-max-chars 50)
           (ctx (hermes-project--build-context st)))
      (when ctx
        (should (<= (length ctx) 60)))))) ; allow small slack for "Current: " suffix

;;;; wire-prefix

(defun hermes-project-test--make-state-with-sid (sid &optional cwd)
  (make-hermes-state :session-id sid :cwd cwd))

(ert-deftest hermes-project-test/wire-prefix-adds-context-on-first-prompt ()
  (hermes-project-test--with-tmp-project root
    (let* ((default-directory root)
           (sid "session-1")
           (hermes--state (hermes-project-test--make-state-with-sid sid root))
           (hermes--seeded-session-id nil)
           (hermes-project-auto-context nil)
           (out (hermes-input--wire-prefix "hello")))
      (should (string-match-p "Project context" out))
      ;; The seed-prefix stamps the session id as a side effect.
      (should (equal sid hermes--seeded-session-id)))))

(ert-deftest hermes-project-test/wire-prefix-skips-context-on-second-prompt ()
  (hermes-project-test--with-tmp-project root
    (let* ((default-directory root)
           (sid "session-1")
           (hermes--state (hermes-project-test--make-state-with-sid sid root))
           (hermes--seeded-session-id sid) ; already seeded
           (hermes-project-auto-context nil)
           (out (hermes-input--wire-prefix "hello")))
      (should-not (string-match-p "Project context" out))
      (should (equal "hello" out)))))

(ert-deftest hermes-project-test/wire-prefix-adds-context-when-auto-context-on ()
  (hermes-project-test--with-tmp-project root
    (let* ((default-directory root)
           (sid "session-1")
           (hermes--state (hermes-project-test--make-state-with-sid sid root))
           (hermes--seeded-session-id sid) ; already seeded → not first prompt
           (hermes-project-auto-context t)
           (out (hermes-input--wire-prefix "hello")))
      (should (string-match-p "Project context" out)))))

(provide 'hermes-project-test)
;;; hermes-project-test.el ends here
