;;; hermes-bench-test.el --- ERT tests for bench resolution utilities -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-mode)
(require 'hermes-bench)
(require 'hermes-input)
(require 'hermes-state)
(load (expand-file-name "hermes-test-helpers.el"
                        (file-name-directory
                         (or load-file-name buffer-file-name))))

(defvar hermes-bench-test--counter 0)

(defun hermes-bench-test--make-parent ()
  "Return a fresh parent buffer in `hermes-mode' with a registered session."
  (let* ((sid (format "bench-test-%d" (cl-incf hermes-bench-test--counter)))
         (buf (generate-new-buffer (format " *hermes-bench-test-%s*" sid))))
    (with-current-buffer buf
      (hermes-mode)
      (hermes--register-session
       sid
       (make-hermes-state :session-id sid :connection 'connected)
       (copy-marker (point-min) nil)))
    buf))

(defmacro hermes-bench-test--with-pair (parent-var bench-var &rest body)
  "Bind PARENT-VAR and BENCH-VAR to a fresh hermes/bench pair around BODY."
  (declare (indent 2))
  `(let* ((,parent-var (hermes-bench-test--make-parent))
          (,bench-var (hermes-bench-ensure ,parent-var)))
     (unwind-protect (progn ,@body)
       (when (buffer-live-p ,bench-var) (kill-buffer ,bench-var))
       (when (buffer-live-p ,parent-var) (kill-buffer ,parent-var)))))

(ert-deftest hermes-bench-test/buffer-p-nil-for-org-buffer ()
  (hermes-bench-test--with-pair parent _bench
    (with-current-buffer parent
      (should-not (hermes-bench-buffer-p)))
    (should-not (hermes-bench-buffer-p parent))))

(ert-deftest hermes-bench-test/buffer-p-t-for-bench-buffer ()
  (hermes-bench-test--with-pair _parent bench
    (with-current-buffer bench
      (should (hermes-bench-buffer-p)))
    (should (hermes-bench-buffer-p bench))))

(ert-deftest hermes-bench-test/resolve-parent-from-bench ()
  (hermes-bench-test--with-pair parent bench
    (should (eq parent (hermes-bench-resolve-parent bench)))
    (with-current-buffer bench
      (should (eq parent (hermes-bench-resolve-parent))))))

(ert-deftest hermes-bench-test/resolve-parent-returns-self-for-org ()
  (hermes-bench-test--with-pair parent _bench
    (should (eq parent (hermes-bench-resolve-parent parent)))
    (with-current-buffer parent
      (should (eq parent (hermes-bench-resolve-parent))))))

(ert-deftest hermes-bench-test/resolve-parent-nil-for-unrelated ()
  (let ((unrelated (generate-new-buffer " *hermes-bench-test-unrelated*")))
    (unwind-protect
        (should-not (hermes-bench-resolve-parent unrelated))
      (kill-buffer unrelated))))

(ert-deftest hermes-bench-test/live-p-returns-bench-for-parent ()
  (hermes-bench-test--with-pair parent bench
    (should (eq bench (hermes-bench-live-p parent)))))

(ert-deftest hermes-bench-test/live-p-returns-bench-for-bench ()
  (hermes-bench-test--with-pair _parent bench
    (should (eq bench (hermes-bench-live-p bench)))
    (with-current-buffer bench
      (should (eq bench (hermes-bench-live-p))))))

;;;; Slash-command CAPF in the bench

(defun hermes-bench-test--seed-catalog (parent)
  "Install a fake slash catalog with `/clear' on PARENT's `(hermes-test--cur)'."
  (with-current-buffer parent
    (let ((h (make-hash-table :test 'equal)))
      (puthash "pairs"
               (vector (vector "/clear" "Clear conversation history"))
               h)
      (setf (hermes-state-slash-catalog (hermes-test--cur)) h))))

(defun hermes-bench-test--type-input (bench text)
  "Insert TEXT into BENCH's input area, point at end."
  (with-current-buffer bench
    (let ((start (hermes-bench--input-start))
          (inhibit-read-only t))
      (goto-char start)
      (delete-region start (point-max))
      (insert text))))

(ert-deftest hermes-bench-test/capf-hook-installed ()
  "Bench mode installs `hermes-bench-completion-at-point' on the CAPF hook."
  (hermes-bench-test--with-pair _parent bench
    (with-current-buffer bench
      (should (memq #'hermes-bench-completion-at-point
                    completion-at-point-functions)))))

(ert-deftest hermes-bench-test/capf-finds-slash-after-prompt ()
  "CAPF triggers when `/' immediately follows the bench prompt."
  (hermes-bench-test--with-pair parent bench
    (hermes-bench-test--seed-catalog parent)
    (hermes-bench-test--type-input bench "/cle")
    (with-current-buffer bench
      (let* ((result (hermes-bench-completion-at-point))
             (start (hermes-bench--input-start)))
        (should result)
        (should (= start (nth 0 result)))
        (should (= (point) (nth 1 result)))
        (should (member "/clear" (nth 2 result)))
        (should (functionp (plist-get (nthcdr 3 result)
                                      :company-doc-buffer)))))))

(ert-deftest hermes-bench-test/capf-nil-before-slash ()
  "CAPF returns nil when input does not start with `/'."
  (hermes-bench-test--with-pair parent bench
    (hermes-bench-test--seed-catalog parent)
    (hermes-bench-test--type-input bench "hello")
    (with-current-buffer bench
      (should-not (hermes-bench-completion-at-point)))))

(ert-deftest hermes-bench-test/capf-nil-outside-input-area ()
  "CAPF returns nil when point is in the ephemeral zone."
  (hermes-bench-test--with-pair parent bench
    (hermes-bench-test--seed-catalog parent)
    (with-current-buffer bench
      (goto-char (point-min))
      (should-not (hermes-bench-completion-at-point)))))

(provide 'hermes-bench-test)
;;; hermes-bench-test.el ends here
