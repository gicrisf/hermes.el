;;; hermes-notifications.el --- Desktop notifications for Hermes  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Optional notification support for Hermes.  Loads the built-in
;; `notifications' library and hooks into state changes to alert the
;; user when a turn finishes or a blocking prompt appears while they
;; are editing in another buffer.
;;
;; Usage: `(require 'hermes-notifications)' after `hermes-mode' is loaded.
;;
;; Known limitation: gateway `background.complete' events are not
;; currently tracked in the state atom, so only turn completion and
;; blocking prompts are surfaced.

;;; Code:

(require 'notifications)
(require 'hermes-state)

(defgroup hermes-notifications nil
  "Desktop notifications for Hermes."
  :group 'hermes)

(defcustom hermes-notifications-enabled t
  "Whether Hermes notifications are active."
  :type 'boolean :group 'hermes-notifications)

(defun hermes-notify--buffer-visible-p (buf)
  "Return non-nil if BUF is visible in any window on any frame."
  (and (buffer-live-p buf)
       (get-buffer-window buf 'visible)))

(defun hermes-notify--maybe-notify (title body)
  "Send a desktop notification with TITLE and BODY if appropriate.
Does nothing if the current Hermes buffer is visible or if
`hermes-notifications-enabled' is nil."
  (when (and hermes-notifications-enabled
             (not (hermes-notify--buffer-visible-p (current-buffer))))
    (notifications-notify :title title :body body)))

(defun hermes-notify--pending-kind (pending)
  "Return the kind symbol of PENDING (a `hermes-pending' struct), or nil."
  (and pending (hermes-pending-p pending) (hermes-pending-kind pending)))

(defun hermes-notify--on-state-change (old new)
  "Watch state transitions and fire notifications.
Both OLD and NEW are `hermes-state' structs; OLD may be nil at init."
  ;; Turn completion: stream went from non-nil to nil.
  (when (and old new
             (hermes-state-stream old)
             (null (hermes-state-stream new)))
    (hermes-notify--maybe-notify "Hermes" "Turn completed."))
  ;; Blocking prompt: pending went from nil to non-nil.
  (let ((old-pending (and old (hermes-state-pending old)))
        (new-pending (and new (hermes-state-pending new))))
    (when (and new-pending (null old-pending))
      (let ((kind (hermes-notify--pending-kind new-pending)))
        (hermes-notify--maybe-notify
         "Hermes"
         (pcase kind
           ('approval "Approval required")
           ('clarify  "Clarification required")
           ('sudo     "Sudo password required")
           ('secret   "Secret required")
           (_         "Action required")))))))

(add-hook 'hermes-state-change-hook #'hermes-notify--on-state-change)

(provide 'hermes-notifications)
;;; hermes-notifications.el ends here
