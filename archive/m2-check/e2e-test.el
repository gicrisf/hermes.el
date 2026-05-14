;;; e2e-test.el --- Headless E2E test for M2 (state + render + mode)
;;;
;;; Run:  cd .. && nix-shell --run 'eldev emacs --batch -L . \
;;;          -l hermes-mode -l hermes-render -l m2-check/e2e-test.el'
;;;
;;; Expect: "=== E2E PASSED ===" in the log.

;; Auto-detect .venv/bin/python relative to project root.
;; Falls back to "python3" if no venv found.
;;
;; Uncomment to override:
;; (setq hermes-rpc-python "/path/to/venv/bin/python")

(defconst e2e--log (concat (file-name-directory load-file-name) "e2e-test.log"))
(with-temp-file e2e--log (erase-buffer))

(defmacro log! (fmt &rest args)
  `(let ((m (format ,fmt ,@args)))
     (with-temp-buffer (insert m "\n")
       (append-to-file (point-min) (point-max) e2e--log))
     (message "%s" m)))

;; ---------------------------------------------------------------------------
;; Setup — mirror M-x hermes
;; ---------------------------------------------------------------------------

(setq hermes-rpc-event-functions nil
      hermes-rpc-connection-functions nil)

(hermes--install-hooks)
(add-hook 'hermes-rpc-connection-functions (lambda (s) (log! "[conn] %s" s)))

;; Create session buffer before gateway starts so gateway.ready routes to it
(let ((buf (generate-new-buffer "*hermes-e2e*")))
  (with-current-buffer buf (hermes-mode))
  (puthash "" buf hermes--session-buffers)
  (set-buffer buf))

;; Track state changes for verification
(add-hook 'hermes-state-change-hook
          (lambda (old new)
            (let* ((msgs (hermes-state-messages new))
                   (n (length msgs))
                   (stream (hermes-state-stream new)))
              (log! "[state] conn=%s msgs=%d stream=%s"
                    (hermes-state-connection new) n
                    (if stream "live" "nil"))
              (when (and stream (> (length (hermes-stream-text stream)) 0))
                (log! "  text: %S"
                      (substring (hermes-stream-text stream) 0
                                 (min 60 (length (hermes-stream-text stream))))))
              (when (and (> n 0) (null stream))
                (let ((last (aref msgs (1- n))))
                  (log! "  msg[%d]: %s %S" (1- n) (hermes-message-kind last)
                        (substring (hermes-message-text last) 0
                                   (min 60 (length (hermes-message-text last))))))))))

;; ---------------------------------------------------------------------------
;; Run
;; ---------------------------------------------------------------------------

(log! "=== E2E Test ===")
(hermes-rpc-start)

(let ((deadline (time-add nil 60))
      (session-sent nil)
      (sid nil)
      (done nil))
  (while (and (not done) (time-less-p nil deadline) (hermes-rpc-live-p))
    (accept-process-output nil 0.3)
    (let* ((st (with-current-buffer (get-buffer "*hermes-e2e*") hermes--state))
           (conn (and st (hermes-state-connection st))))
      (cond
       ;; Phase 1: wait for connection, send session.create once
       ((null sid)
        (when (and (eq conn 'connected) (not session-sent))
          (setq session-sent t)
          (log! "--- connected, sending session.create ---")
          (hermes-rpc-request
           "session.create" '(:cols 100)
           (lambda (r e)
             (if e (log! "session.create ERROR: %S" e)
               (setq sid (gethash "session_id" r))
               ;; Re-register buffer under real session-id so events route to it
               (remhash "" hermes--session-buffers)
               (puthash sid (get-buffer "*hermes-e2e*") hermes--session-buffers)
               (with-current-buffer (get-buffer "*hermes-e2e*")
                 (setf (hermes-state-session-id hermes--state) sid))
               (log! "session: %s" sid)
               (with-current-buffer (get-buffer "*hermes-e2e*")
                 (hermes-dispatch (cons :user-submit (list :text "say hi in five words")))
                 (hermes-rpc-request
                  "prompt.submit"
                  (list :session_id sid :text "say hi in five words")
                  (lambda (r2 e2)
                    (log! "prompt.submit -> r=%S e=%S" r2 e2)))))))))
       ;; Phase 2: poll for assistant message completion
       (t
        (let* ((st2 (with-current-buffer (get-buffer "*hermes-e2e*") hermes--state))
               (msgs (hermes-state-messages st2))
               (n (length msgs)))
          (when (and (>= n 2)
                     (eq (hermes-message-kind (aref msgs (1- n))) 'assistant)
                     (null (hermes-state-stream st2)))
            (log! "=== E2E PASSED ===")
            (setq done t)))))))
  (hermes-rpc-stop)
  (log! "[done] passed=%s" done))
