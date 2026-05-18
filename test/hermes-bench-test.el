;;; hermes-bench-test.el --- ERT tests for bench resolution utilities -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-mode)
(require 'hermes-bench)

(defun hermes-bench-test--make-parent ()
  "Return a fresh parent buffer in `hermes-mode'."
  (let ((buf (generate-new-buffer " *hermes-bench-test-parent*")))
    (with-current-buffer buf (hermes-mode))
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

(provide 'hermes-bench-test)
;;; hermes-bench-test.el ends here
