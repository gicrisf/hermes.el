;;; hermes-rpc.el --- JSON-RPC stdio transport to the Hermes TUI gateway -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Version: 0.1.0
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Spawns `python -m tui_gateway.entry' as a subprocess and speaks
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

(defcustom hermes-rpc-python "python3"
  "Python executable used to launch the gateway."
  :type 'string :group 'hermes)

(defcustom hermes-rpc-gateway-module "tui_gateway.entry"
  "Python module name passed as `python -m <module>'."
  :type 'string :group 'hermes)

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

(defvar hermes-rpc-connection-functions nil
  "Hook of (STATE) where STATE is one of `connecting', `connected', `disconnected'.")

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
         (process-environment (append hermes-rpc-env process-environment))
         (stderr-buf (generate-new-buffer " *hermes-rpc-stderr*"))
         (proc (make-process
                :name "hermes-rpc"
                :command (list hermes-rpc-python "-m" hermes-rpc-gateway-module)
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
    (when stderr-pipe
      (set-process-filter stderr-pipe #'hermes-rpc--stderr-filter))
    (setq hermes-rpc--stderr-buffer stderr-buf
          hermes-rpc--process proc)
    (run-hook-with-args 'hermes-rpc-connection-functions 'connecting)
    proc))

;;;###autoload
(defun hermes-rpc-stop ()
  "Terminate the gateway subprocess."
  (interactive)
  (when (and hermes-rpc--process
             (process-live-p hermes-rpc--process))
    (delete-process hermes-rpc--process))
  (setq hermes-rpc--process nil))

(defun hermes-rpc-live-p ()
  "Return non-nil if the gateway process is alive."
  (and hermes-rpc--process (process-live-p hermes-rpc--process)))

;;;; Outgoing

(defun hermes-rpc-request (method params &optional callback)
  "Send a JSON-RPC request for METHOD with PARAMS (a plist or alist).
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives.  Exactly one of RESULT / ERROR is non-nil."
  (unless (hermes-rpc-live-p)
    (error "Hermes gateway is not running"))
  (let* ((id (cl-incf hermes-rpc--next-id))
         (frame (list :jsonrpc "2.0"
                      :id id
                      :method method
                      :params (or params (make-hash-table)))))
    (when callback
      (puthash id callback hermes-rpc--pending))
    (hermes-rpc--send frame)
    id))

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
      (when type
        (run-hook-with-args 'hermes-rpc-event-functions type sid payload))))
   (t
    (message "hermes-rpc: unrecognised frame: %S" frame))))

;;;; Sentinel and stderr

(defvar hermes-rpc--stderr-tail ""
  "Pending stderr bytes that have not yet been split on newline.")

(defun hermes-rpc--stderr-filter (_proc chunk)
  "Stderr filter: split CHUNK on newline, run each line through the hook."
  (setq hermes-rpc--stderr-tail (concat hermes-rpc--stderr-tail chunk))
  (let ((lines (split-string hermes-rpc--stderr-tail "\n")))
    (setq hermes-rpc--stderr-tail (car (last lines)))
    (dolist (line (butlast lines))
      (unless (string-empty-p line)
        (run-hook-with-args 'hermes-rpc-stderr-functions line)))))

(defun hermes-rpc--sentinel (proc event)
  "Handle subprocess lifecycle: signal disconnection."
  (when (memq (process-status proc) '(exit signal closed))
    (unless (string-empty-p hermes-rpc--stderr-tail)
      (run-hook-with-args 'hermes-rpc-stderr-functions
                          hermes-rpc--stderr-tail)
      (setq hermes-rpc--stderr-tail ""))
    (setq hermes-rpc--process nil)
    (run-hook-with-args 'hermes-rpc-connection-functions 'disconnected)
    (message "hermes-rpc: gateway %s" (string-trim event))))

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
