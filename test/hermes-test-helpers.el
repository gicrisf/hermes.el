;;; hermes-test-helpers.el --- Shared helpers for Hermes tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Bridges the test-suite onto the global state layer.  Tests that
;; predate the global refactor referenced `hermes--state' as a
;; buffer-local atom; these helpers expose the equivalent through the
;; global slot keyed by `hermes--current-session-id'.

;;; Code:

(require 'hermes-state)

(defun hermes-test--reset-global-state ()
  "Reset every global Hermes hash table.  Call from test setup."
  (setq hermes--sessions (make-hash-table :test 'equal))
  (setq hermes--org-buffers (make-hash-table :test 'equal))
  (setq hermes--bench-buffers (make-hash-table :test 'equal))
  (setq hermes-comint--buffers (make-hash-table :test 'equal))
  (setq hermes--session-markers (make-hash-table :test 'equal))
  (setq hermes--global-state (make-hermes-state :connection 'disconnected)))

(defun hermes-test--cur ()
  "Return the persistent state for the active context.
Uses `hermes--current-state' so callers in a Hermes-aware buffer
without a dynamic `hermes--current-session-id' still resolve to the
buffer's registered session."
  (hermes--current-state))

(defun hermes-test--set-cur (val)
  "Setf-target for `hermes-test--cur'.
Resolves the active session id the same way as `hermes--current-state'."
  (hermes--state-slot-write (hermes--current-sid) val))

(gv-define-simple-setter hermes-test--cur hermes-test--set-cur)

(provide 'hermes-test-helpers)
;;; hermes-test-helpers.el ends here
