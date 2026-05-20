;;; hermes-rpc.el --- JSON-RPC stdio transport to the Hermes TUI gateway -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Version: 0.1.0
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Spawns the Hermes gateway as a subprocess and speaks
;; newline-delimited JSON-RPC 2.0 over stdio.
;;
;; - Outgoing requests get an auto-incrementing integer id and a callback
;;   in the pending map; the callback fires when the matching response
;;   arrives (responses may interleave for long handlers — see
;;   `hermes-rpc-long-handlers').
;; - Incoming notifications (method = "event") are routed to
;;   `hermes-rpc-event-functions'.
;; - The subprocess's stderr is collected into a separate buffer and
;;   surfaced through `hermes-rpc-stderr-functions'.
;; - JSON-RPC error frames go to the request's callback with an error
;;   plist; orphaned parse failures go to `hermes-rpc-protocol-error-functions'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'hermes-events)

;;;; User options

(defgroup hermes nil
  "Emacs client for the Hermes AI agent."
  :group 'tools
  :prefix "hermes-")

(defcustom hermes-rpc-python
  (or (getenv "HERMES_DEV_PYTHON") "python3")
  "Python executable used to launch the gateway.
During development the Nix shell sets `HERMES_DEV_PYTHON' to the
project-local venv interpreter; that value is picked up automatically."
  :type 'string :group 'hermes)

(defcustom hermes-rpc-gateway-module "tui_gateway.entry"
  "Python module name passed as `python -m <module>'.
Only used when `hermes-rpc-command' is nil."
  :type 'string :group 'hermes)

(defcustom hermes-rpc-command nil
  "Override the full gateway spawn command as a list of strings.
If nil, falls back to
  (list hermes-rpc-python \"-m\" hermes-rpc-gateway-module)."
  :type '(choice (const nil) (repeat string))
  :group 'hermes)

(defcustom hermes-rpc-cwd nil
  "Working directory for the gateway subprocess.
If nil, inherits Emacs's `default-directory' at spawn time."
  :type '(choice (const nil) directory) :group 'hermes)

(defcustom hermes-rpc-env nil
  "Extra environment variables for the gateway, each as \"VAR=VAL\"."
  :type '(repeat string) :group 'hermes)

;;;; State

(defvar hermes-rpc--process nil
  "The single gateway subprocess, or nil when disconnected.")

(defvar hermes-rpc--stderr-buffer nil
  "Buffer collecting the gateway's stderr output.")

(defvar hermes-rpc--stdout-buffer ""
  "Pending stdout bytes that have not yet been split on newline.")

(defvar hermes-rpc--next-id 0
  "Monotonic counter for outgoing JSON-RPC ids.")

(defvar hermes-rpc--pending (make-hash-table :test 'eql)
  "Map of outgoing request id → callback function (RESULT ERROR).")

(defvar hermes-rpc-event-functions nil
  "Hook of (TYPE SESSION-ID PAYLOAD) called for every incoming event.
TYPE is a string from `hermes-events-incoming'.  PAYLOAD is a hash table.")

(defvar hermes-rpc-stderr-functions nil
  "Hook of (LINE) called for each stderr line from the gateway.")

(defvar hermes-rpc-protocol-error-functions nil
  "Hook of (PREVIEW) called when a stdout line fails to parse as JSON.")

(defvar hermes-rpc-start-timeout-functions nil
  "Hook of (LINES) called when the gateway exits before sending `gateway.ready'.
LINES is a list of the last non-empty stderr strings.")

(defvar hermes-rpc-connection-functions nil
  "Hook of (STATE) where STATE is one of `connecting', `connected', `disconnected'.")

(defvar hermes-rpc--state 'down
  "Gateway lifecycle state machine.  One of:

  `down'      no subprocess running
  `starting'  subprocess spawned, awaiting the `gateway.ready' event
  `ready'     gateway has greeted us; requests are flushed immediately

`hermes-rpc-request' buffers outgoing frames in
`hermes-rpc--pending-frames' while in `starting' and dispatches them in
order on the `down' → `ready' transition.  The sentinel resets the state
back to `down' (and drops any still-pending frames) when the process
dies.")

(defvar hermes-rpc--pending-frames nil
  "FIFO list of frames waiting to be sent once the gateway is ready.
Each element is the JSON-RPC frame plist as produced by
`hermes-rpc-request'.  Drained by `hermes-rpc--flush-pending'.")

;;;; Process lifecycle

;;;###autoload
(defun hermes-rpc-start ()
  "Spawn the gateway subprocess.  No-op if one is already running."
  (interactive)
  (when (and hermes-rpc--process
             (process-live-p hermes-rpc--process))
    (user-error "Hermes gateway already running (pid %d)"
                (process-id hermes-rpc--process)))
  (setq hermes-rpc--stdout-buffer ""
        hermes-rpc--next-id 0)
  (clrhash hermes-rpc--pending)
  (let* ((default-directory (or hermes-rpc-cwd default-directory))
         (cmd (or hermes-rpc-command
                  (list hermes-rpc-python "-m" hermes-rpc-gateway-module)))
         (process-environment (append hermes-rpc-env process-environment))
         (stderr-buf (generate-new-buffer " *hermes-rpc-stderr*"))
         (proc (make-process
                :name "hermes-rpc"
                :command cmd
                :buffer nil
                :stderr stderr-buf
                :connection-type 'pipe
                :coding 'utf-8
                :noquery t
                :filter #'hermes-rpc--filter
                :sentinel #'hermes-rpc--sentinel))
         ;; `:stderr BUFFER' creates an internal pipe-process; attach a
         ;; filter to surface lines in real time.
         (stderr-pipe (get-buffer-process stderr-buf)))
    (message "hermes-rpc: spawning %S" cmd)
    (when stderr-pipe
      (set-process-filter stderr-pipe #'hermes-rpc--stderr-filter))
    (setq hermes-rpc--stderr-buffer stderr-buf
          hermes-rpc--process proc
          hermes-rpc--state 'starting
          hermes-rpc--pending-frames nil)
    (run-hook-with-args 'hermes-rpc-connection-functions 'connecting)
    proc))

;;;###autoload
(defun hermes-rpc-stop ()
  "Terminate the gateway subprocess."
  (interactive)
  (when (and hermes-rpc--process
             (process-live-p hermes-rpc--process))
    (delete-process hermes-rpc--process))
  (setq hermes-rpc--process nil
        hermes-rpc--state 'down
        hermes-rpc--pending-frames nil))

(defun hermes-rpc-live-p ()
  "Return non-nil if the gateway process is alive."
  (and hermes-rpc--process (process-live-p hermes-rpc--process)))

;;;; Outgoing

(defun hermes-rpc-request (method params &optional callback)
  "Send a JSON-RPC request for METHOD with PARAMS (a plist or alist).
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives.  Exactly one of RESULT / ERROR is non-nil.

If the gateway is `starting' (process spawned but no `gateway.ready'
event yet), the frame is buffered in `hermes-rpc--pending-frames' and
sent in order when the gateway transitions to `ready'.  The Python
gateway drops requests that arrive before its handlers are installed,
so this queue is the only thing keeping the first request from being
lost."
  (unless (hermes-rpc-live-p)
    (error "Hermes gateway is not running"))
  (let* ((id (cl-incf hermes-rpc--next-id))
         (frame (list :jsonrpc "2.0"
                      :id id
                      :method method
                      :params (or params (make-hash-table)))))
    (when callback
      (puthash id callback hermes-rpc--pending))
    (pcase hermes-rpc--state
      ('ready    (hermes-rpc--send frame))
      ('starting (setq hermes-rpc--pending-frames
                       (append hermes-rpc--pending-frames (list frame))))
      (_ ;; 'down — process should be alive per `hermes-rpc-live-p' above,
       ;; so this is an inconsistency.  Surface it loudly.
       (error "hermes-rpc: process alive but state is %s" hermes-rpc--state)))
    id))

(defun hermes-rpc--flush-pending ()
  "Send every frame buffered while the gateway was `starting'."
  (let ((frames hermes-rpc--pending-frames))
    (setq hermes-rpc--pending-frames nil)
    (dolist (f frames) (hermes-rpc--send f))))

(defun hermes-rpc--send (frame)
  "Encode FRAME as JSON, append newline, write to gateway stdin."
  (let ((json (json-serialize frame
                              :null-object :null
                              :false-object :false)))
    (process-send-string hermes-rpc--process (concat json "\n"))))

;;;; Incoming

(defun hermes-rpc--filter (_proc chunk)
  "Process filter: accumulate CHUNK, split on newline, dispatch each frame."
  (setq hermes-rpc--stdout-buffer
        (concat hermes-rpc--stdout-buffer chunk))
  (let ((lines (split-string hermes-rpc--stdout-buffer "\n")))
    (setq hermes-rpc--stdout-buffer (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (hermes-rpc--dispatch-line line)))))

(defun hermes-rpc--dispatch-line (line)
  "Parse LINE as JSON and route it to the right handler."
  (condition-case err
      (let ((frame (json-parse-string line :object-type 'hash-table
                                      :null-object nil
                                      :false-object nil)))
        (hermes-rpc--dispatch-frame frame))
    (json-parse-error
     (run-hook-with-args 'hermes-rpc-protocol-error-functions
                         (substring line 0 (min 200 (length line))))
     (message "hermes-rpc: bad JSON (%s)" (error-message-string err)))))

(defun hermes-rpc--dispatch-frame (frame)
  "Route FRAME (a hash-table) to a request callback or an event handler."
  (cond
   ;; Response to a request we sent
   ((gethash "id" frame)
    (let* ((id (gethash "id" frame))
           (cb (gethash id hermes-rpc--pending)))
      (when cb
        (remhash id hermes-rpc--pending)
        (let ((result (gethash "result" frame))
              (error  (gethash "error"  frame)))
          (condition-case err
              (funcall cb result error)
            (error (message "hermes-rpc: callback failed: %s"
                            (error-message-string err))))))))
   ;; Server-initiated notification (event)
   ((equal (gethash "method" frame) "event")
    (let* ((params  (gethash "params" frame))
           (type    (and params (gethash "type" params)))
           (sid     (and params (gethash "session_id" params)))
           (payload (and params (gethash "payload" params))))
      ;; `gateway.ready' is the transition that lets us send buffered
      ;; frames.  Do this BEFORE the user-facing hook so subscribers see
      ;; an already-ready state.
      (when (and (equal type "gateway.ready")
                 (eq hermes-rpc--state 'starting))
        (setq hermes-rpc--state 'ready)
        (hermes-rpc--flush-pending))
      (when type
        (run-hook-with-args 'hermes-rpc-event-functions type sid payload))))
   (t
    (message "hermes-rpc: unrecognised frame: %S" frame))))

;;;; Sentinel and stderr

(defvar hermes-rpc--stderr-tail ""
  "Pending stderr bytes that have not yet been split on newline.")

(defun hermes-rpc--stderr-filter (_proc chunk)
  "Stderr filter: split CHUNK on newline, store in buffer and run hook."
  (setq hermes-rpc--stderr-tail (concat hermes-rpc--stderr-tail chunk))
  (let ((lines (split-string hermes-rpc--stderr-tail "\n")))
    (setq hermes-rpc--stderr-tail (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (when (buffer-live-p hermes-rpc--stderr-buffer)
          (with-current-buffer hermes-rpc--stderr-buffer
            (goto-char (point-max))
            (insert line "\n")))
        (run-hook-with-args 'hermes-rpc-stderr-functions line)))))

(defun hermes-rpc--sentinel (proc event)
  "Handle subprocess lifecycle: signal disconnection."
  (when (memq (process-status proc) '(exit signal closed))
    ;; If the gateway never reached `ready', treat it as a start timeout.
    (when (eq hermes-rpc--state 'starting)
      (let ((tail-lines nil)
            (count 0)
            (ev (string-trim event)))
        ;; Give the stderr filter a moment to catch up (fast-failing
        ;; processes often emit stderr after the sentinel fires).
        (sit-for 0 100)
        (when (buffer-live-p hermes-rpc--stderr-buffer)
          (with-current-buffer hermes-rpc--stderr-buffer
            (goto-char (point-max))
            (while (and (< count 8) (not (bobp)))
              (beginning-of-line)
              (when (> (point) 1)
                (let ((line (buffer-substring (point) (line-end-position))))
                  (setq line (string-trim line))
                  (unless (string-empty-p line)
                    (push line tail-lines)
                    (setq count (1+ count)))))
              (forward-line -1))))
        ;; Include any trailing bytes the filter hasn't flushed yet.
        (unless (string-empty-p hermes-rpc--stderr-tail)
          (push hermes-rpc--stderr-tail tail-lines)
          (setq hermes-rpc--stderr-tail ""))
        (message "hermes-rpc: gateway failed to start (%s)" ev)
        (if tail-lines
            (progn
              (message "stderr:")
              (dolist (l tail-lines) (message "  %s" l))
              (when (cl-some (lambda (l) (string-match-p "ModuleNotFoundError" l))
                             tail-lines)
                (message "→ Is the Hermes agent installed?")))
          (message "stderr: (empty)"))
        (run-hook-with-args 'hermes-rpc-start-timeout-functions tail-lines)))
    (setq hermes-rpc--process nil
          hermes-rpc--state 'down
          hermes-rpc--pending-frames nil)
    (run-hook-with-args 'hermes-rpc-connection-functions 'disconnected)))

;;;; Smoke test

(defun hermes-rpc--test-log (fmt &rest args)
  "Append a formatted line to *hermes-log*."
  (let ((buf (get-buffer-create "*hermes-log*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode) (special-mode))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (apply #'format fmt args) "\n")))))

(defun hermes-rpc--test-on-prompt (result error)
  (hermes-rpc--test-log "[ok] prompt.submit → r=%S e=%S" result error))

(defun hermes-rpc--test-on-session (result _error)
  (let ((sid (and result (gethash "session_id" result))))
    (hermes-rpc--test-log "[ok] session.create → %s" sid)
    (when sid
      (hermes-rpc-request "prompt.submit"
                          (list :session_id sid :text "say hi in five words")
                          #'hermes-rpc--test-on-prompt))))

(defun hermes-rpc--test-on-event (type sid payload)
  (hermes-rpc--test-log "[event] %-22s sid=%s payload=%S" type sid payload)
  (when (equal type "gateway.ready")
    (hermes-rpc-request "session.create" '(:cols 80)
                        #'hermes-rpc--test-on-session)))

;;;###autoload
(defun hermes-rpc-test ()
  "Spawn the gateway, dump every event to *hermes-log*, send a tiny prompt."
  (interactive)
  (with-current-buffer (get-buffer-create "*hermes-log*")
    (let ((inhibit-read-only t)) (erase-buffer))
    (unless (derived-mode-p 'special-mode) (special-mode)))
  (setq hermes-rpc-event-functions nil
        hermes-rpc-stderr-functions nil
        hermes-rpc-connection-functions nil
        hermes-rpc-protocol-error-functions nil)
  (add-hook 'hermes-rpc-connection-functions
            (lambda (state) (hermes-rpc--test-log "[conn] %s" state)))
  (add-hook 'hermes-rpc-stderr-functions
            (lambda (line) (hermes-rpc--test-log "[stderr] %s" line)))
  (add-hook 'hermes-rpc-protocol-error-functions
            (lambda (preview) (hermes-rpc--test-log "[bad-json] %s" preview)))
  (add-hook 'hermes-rpc-event-functions #'hermes-rpc--test-on-event)
  (hermes-rpc-start)
  (pop-to-buffer "*hermes-log*"))

(provide 'hermes-rpc)
;;; hermes-rpc.el ends here
