;;; hermes-bg-test.el --- ERT tests for hermes-bg.el -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-state)
(require 'hermes-bg)

(ert-deftest hermes-bg-test/mode-is-org-derived ()
  (with-temp-buffer
    (hermes-bg-mode)
    (should (derived-mode-p 'org-mode))
    (should buffer-read-only)))

(ert-deftest hermes-bg-test/list-mode-inherits-tabulated ()
  (with-temp-buffer
    (hermes-bg-list-mode)
    (should (derived-mode-p 'tabulated-list-mode))))

(ert-deftest hermes-bg-test/list-mode-keymap-has-RET-and-k ()
  (should (eq #'hermes-bg-list-visit-task
              (lookup-key hermes-bg-list-mode-map (kbd "RET"))))
  (should (eq #'hermes-bg-list-kill-task
              (lookup-key hermes-bg-list-mode-map (kbd "k")))))

(ert-deftest hermes-bg-test/kill-all-removes-matching-buffers ()
  (let ((b1 (get-buffer-create "*hermes-bg:abc:1*"))
        (b2 (get-buffer-create "*hermes-bg:abc:2*"))
        (b3 (get-buffer-create "*hermes-bg:xyz:1*")))
    (with-current-buffer b1 (hermes-bg-mode))
    (with-current-buffer b2 (hermes-bg-mode))
    (with-current-buffer b3 (hermes-bg-mode))
    (hermes-bg-kill-all "abc")
    (should-not (buffer-live-p b1))
    (should-not (buffer-live-p b2))
    (should (buffer-live-p b3))
    (kill-buffer b3)))

(provide 'hermes-bg-test)
;;; hermes-bg-test.el ends here
