;;; hermes-config.el --- Gateway config + tools RPC wrappers -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Thin wrappers around `config.get', `config.set', `toolsets.list',
;; and `tools.configure', plus a handful of high-value interactive
;; commands (`hermes-set-model', `hermes-toggle-fast',
;; `hermes-toggle-reasoning', `hermes-toggle-yolo',
;; `hermes-set-personality', `hermes-set-skin',
;; `hermes-toolsets-toggle').
;;
;; All commands operate on the session targeted by
;; `hermes--resolve-session-target' — i.e. the current `hermes-mode'
;; buffer or the `:hermes:' container around point in an Org buffer
;; with `hermes-minor-mode' enabled.

;;; Code:

(require 'cl-lib)
(require 'hermes-rpc)
(require 'hermes-state)
(require 'hermes-org)

(declare-function hermes--model-short-name "hermes-render" (slug))

;;;; Target resolution

(defun hermes--config-resolve-target ()
  "Return the session id for the current target, or signal `user-error'."
  (let* ((target (hermes--resolve-session-target))
         (sid    (car target)))
    (unless target
      (user-error "No Hermes session at point"))
    (unless sid
      (user-error "No session id assigned yet"))
    sid))

;;;; Generic building blocks

(defun hermes-config-get (key &optional callback)
  "Send `config.get' for KEY against the current session.
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives."
  (let ((sid (hermes--config-resolve-target)))
    (hermes-rpc-request
     "config.get"
     (list :key key :session_id sid)
     (or callback (lambda (_r _e) nil)))))

(defun hermes-config-set (key value &optional callback)
  "Send `config.set' for KEY → VALUE against the current session.
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives."
  (let ((sid (hermes--config-resolve-target)))
    (hermes-rpc-request
     "config.set"
     (list :key key :value value :session_id sid)
     (or callback (lambda (_r _e) nil)))))

;;;; Provider cache (for `hermes-set-model')

(defvar-local hermes-config--last-providers nil
  "Cached hash table from the last `config.get provider' call.
Buffer-local on the parent session buffer.  Cleared on explicit
prefix arg to `hermes-set-model'.")

(defun hermes-config--fetch-providers (callback)
  "Fetch provider info via `config.get provider' and pass to CALLBACK.
CALLBACK is called as (RESULT ERROR).  If `hermes-config--last-providers'
already holds a result, the cached value is used and no RPC is sent.
On a successful gateway response, the result is cached for future calls."
  (if hermes-config--last-providers
      (funcall callback hermes-config--last-providers nil)
    (let ((buf (current-buffer)))
      (hermes-config-get
       "provider"
       (lambda (result error)
         (when (and result (buffer-live-p buf))
           (with-current-buffer buf
             (setq hermes-config--last-providers result)))
         (funcall callback result error))))))

;;;; Model helper

(defun hermes-set-model (&optional refresh)
  "Set the model for the current session.
With prefix arg REFRESH, re-fetch the provider list before prompting.
Aborts with `user-error' if a stream is in flight."
  (interactive "P")
  (let* ((target (hermes--resolve-session-target))
         (_ (unless target (user-error "No Hermes session at point")))
         (state (cdr target)))
    (when (and state (hermes-state-stream state))
      (user-error "Cannot switch models mid-turn — run M-x hermes-interrupt first"))
    (when (or refresh (null hermes-config--last-providers))
      (setq hermes-config--last-providers nil))
    (let ((buf (current-buffer)))
      (hermes-config--fetch-providers
       (lambda (result error)
         (cond
          (error (message "hermes: config.get provider failed: %S" error))
          (result
           (when (buffer-live-p buf)
             (with-current-buffer buf
               (hermes--set-model-prompt result))))))))))

(defun hermes--provider-candidate (p)
  "Render a provider dict P as a completion candidate string.
Returns a string of the form `id (label)' when both fields are
available, falling back to whichever is present."
  (let ((id    (and (hash-table-p p) (gethash "id" p)))
        (label (and (hash-table-p p) (gethash "label" p))))
    (cond
     ((and id label (not (equal id label))) (format "%s (%s)" id label))
     (id    id)
     (label label)
     ((stringp p) p)
     (t     (format "%s" p)))))

(defun hermes--candidate-provider-id (candidate)
  "Extract the provider id from CANDIDATE (`id' or `id (label)')."
  (when (stringp candidate)
    (car (split-string candidate " " t))))

(defun hermes--set-model-prompt (result)
  "Prompt for a model given the provider RESULT hash, then issue `config.set'."
  (let* ((current   (gethash "model" result))
         (providers (gethash "providers" result))
         (raw       (cond ((vectorp providers) (append providers nil))
                          ((listp providers)   providers)
                          (t nil)))
         (candidates (mapcar #'hermes--provider-candidate raw))
         (_ (when (null candidates)
              (message "hermes: no providers returned — enter a model slug manually")))
         (initial   (hermes--model-short-name current))
         (prompt    (format "Model (current %s): " (or current "—")))
         (raw-choice (completing-read prompt candidates nil nil initial))
         (provider-id (when (member raw-choice candidates)
                        (hermes--candidate-provider-id raw-choice)))
         (choice (cond
                  ;; Picked a provider candidate: prompt for full slug,
                  ;; pre-filling `provider/'.
                  (provider-id
                   (read-string (format "Model slug for %s: " provider-id)
                                (concat provider-id "/")))
                  (t raw-choice))))
    (when (and choice (not (string-empty-p (string-trim choice))))
      (hermes-config-set
       "model" choice
       (lambda (r e)
         (cond
          (e (message "hermes: model switch error: %S" e))
          (r (message "hermes: model → %s%s"
                      (gethash "value" r)
                      (let ((w (gethash "warning" r)))
                        (if (and w (not (string-empty-p w)))
                            (format " (%s)" w) ""))))))))))

;;;; Steer (mid-turn injection)

(declare-function hermes-bench-active-p "hermes-bench" (&optional parent))
(declare-function hermes-bench-add-steer "hermes-bench" (parent text))

(defun hermes-steer (text)
  "Send TEXT as a steer message to the current session's in-flight turn.
Safe mid-turn: the gateway threads the message into the running turn
without interrupting it.  If a bench is paired with the target buffer,
the message is also shown above its reasoning zone."
  (interactive (list (read-string "Steer: ")))
  (let ((sid    (hermes--config-resolve-target))
        (parent (current-buffer))
        (trimmed (string-trim (or text ""))))
    (when (string-empty-p trimmed)
      (user-error "Empty steer message"))
    (when (fboundp 'hermes-bench-add-steer)
      (hermes-bench-add-steer parent trimmed))
    (hermes-rpc-request
     "session.steer"
     (list :session_id sid :text trimmed)
     (lambda (r e)
       (cond
        (e (message "hermes: steer error: %S" e))
        ((equal (and (hash-table-p r) (gethash "status" r)) "rejected")
         (message "hermes: steer rejected"))
        (t (message "hermes: steer queued")))))))

;;;; Toggle helpers

(defun hermes-toggle-fast ()
  "Toggle fast mode for the current session."
  (interactive)
  (hermes-config-set
   "fast" "toggle"
   (lambda (r e)
     (if e (message "hermes: fast toggle error: %S" e)
       (message "hermes: fast mode → %s" (gethash "value" r))))))

(defconst hermes--reasoning-cycle
  '("hide" "show" "low" "medium" "high")
  "Order used by `hermes-toggle-reasoning' when cycling.")

(defun hermes-toggle-reasoning (&optional pick)
  "Cycle reasoning effort/visibility.
With prefix arg PICK, choose explicitly via `completing-read'."
  (interactive "P")
  (hermes-config-get
   "reasoning"
   (lambda (r e)
     (cond
      (e (message "hermes: reasoning get error: %S" e))
      (r
       (let* ((effort  (gethash "value"   r))
              (display (gethash "display" r))
              ;; If hidden, the next step is to show; otherwise rotate
              ;; through low/medium/high.  Prefix arg overrides.
              (next
               (cond
                (pick
                 (completing-read "Reasoning: " hermes--reasoning-cycle nil t))
                ((equal display "hide") "show")
                (t (let* ((all '("low" "medium" "high"))
                          (tail (cdr (member effort all))))
                     (or (car tail) (car all)))))))
         (hermes-config-set
          "reasoning" next
          (lambda (r2 e2)
            (if e2 (message "hermes: reasoning set error: %S" e2)
              (message "hermes: reasoning → %s" (gethash "value" r2)))))))))))

(defun hermes-toggle-yolo ()
  "Toggle YOLO (auto-approve) mode for the current session."
  (interactive)
  (hermes-config-set
   "yolo" "toggle"
   (lambda (r e)
     (if e (message "hermes: yolo toggle error: %S" e)
       (message "hermes: yolo → %s"
                (if (equal (gethash "value" r) "1") "on" "off"))))))

;;;; Skin / personality helpers

(defun hermes-set-personality (personality)
  "Set the active personality to PERSONALITY (free-form string)."
  (interactive (list (read-string "Personality: " nil nil "default")))
  (hermes-config-set
   "personality" personality
   (lambda (r e)
     (if e (message "hermes: personality error: %S" e)
       (message "hermes: personality → %s%s"
                (gethash "value" r)
                (if (gethash "history_reset" r) " (history reset)" ""))))))

(defun hermes-set-skin (skin)
  "Set the display skin to SKIN (free-form string)."
  (interactive (list (read-string "Skin: " nil nil "default")))
  (hermes-config-set
   "skin" skin
   (lambda (r e)
     (if e (message "hermes: skin error: %S" e)
       (message "hermes: skin → %s" (gethash "value" r))))))

;;;; Toolsets

(defun hermes-toolsets-toggle ()
  "Enable or disable toolsets for the current session.
Fetches the toolset list via `toolsets.list', lets the user pick names
with `completing-read-multiple', then prompts for an action and issues
`tools.configure'."
  (interactive)
  (let ((sid (hermes--config-resolve-target)))
    (hermes-rpc-request
     "toolsets.list" (list :session_id sid)
     (lambda (result error)
       (cond
        (error (message "hermes: toolsets.list error: %S" error))
        (result
         (let* ((raw   (gethash "toolsets" result))
                (items (cond ((vectorp raw) (append raw nil))
                             ((listp raw)   raw)
                             (t nil)))
                (candidates
                 (mapcar
                  (lambda (ts)
                    (let* ((name    (gethash "name" ts))
                           (enabled (gethash "enabled" ts))
                           (count   (gethash "tool_count" ts)))
                      (format "%s%s [%s]"
                              name
                              (if enabled " (on)" "")
                              (or count "?"))))
                  items))
                (name-of (lambda (cand)
                           (car (split-string cand " " t)))))
           (unless items
             (user-error "hermes: no toolsets returned"))
           (let* ((picked (completing-read-multiple
                           "Toolsets (comma-separated): "
                           candidates nil t))
                  (names  (mapcar name-of picked))
                  (action (and names
                               (completing-read
                                "Action: " '("enable" "disable") nil t))))
             (when (and names action)
               (hermes-rpc-request
                "tools.configure"
                (list :session_id sid
                      :action     action
                      :names      (vconcat names))
                (lambda (r2 e2)
                  (cond
                   (e2 (message "hermes: tools.configure error: %S" e2))
                   (r2 (message "hermes: toolsets %sd: %s"
                                action
                                (mapconcat #'identity
                                           (append (gethash "changed" r2) nil)
                                           ", ")))))))))))))))

(provide 'hermes-config)
;;; hermes-config.el ends here
