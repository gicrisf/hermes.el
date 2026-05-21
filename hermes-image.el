;;; hermes-image.el --- Image and clipboard attachment for Hermes -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai, multimedia
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Optional add-on: bridge to the gateway's multimodal attachment API
;; (`image.attach', `clipboard.paste', `input.detect_drop').  The Emacs
;; client never embeds image bytes — it sends paths only, and the
;; gateway reads files itself.  See PLAN.md for the full design.
;;
;; The state mirror `hermes-state-attachments' is purely a local view
;; for bench display and `:user-submit' consumption.  The gateway owns
;; the authoritative `session["attached_images"]' list.

;;; Code:

(require 'cl-lib)
(require 'hermes-rpc)
(require 'hermes-state)

(declare-function hermes-bench-active-p "hermes-bench" (&optional parent))
(declare-function hermes-bench-show-status "hermes-bench" (parent text &optional error-p))
(declare-function hermes--paint-bench "hermes-bench" ())

(defvar hermes-image--attach-counter 0
  "Monotonic counter for client-side attach ids.")

(defun hermes-image--probe-dimensions (path)
  "Return (WIDTH . HEIGHT) in pixels for image at PATH, or nil on failure.
Used as a client-side fallback when the gateway response omits
dimensions.  Requires a live display frame and a format Emacs can
decode; degrades silently otherwise."
  (when (and path (file-readable-p path) (display-images-p))
    (ignore-errors
      (let ((img (create-image path)))
        (and img (image-size img t (selected-frame)))))))

(defun hermes-image--next-attach-id ()
  "Return a fresh client-side attach id (a string).
Used to match RPC callbacks back to their optimistic placeholder
entry in `hermes-state-attachments'."
  (format "att-%d-%d"
          (cl-incf hermes-image--attach-counter)
          (random 100000)))

(defun hermes-image--get (h key)
  "Read KEY from H which may be a hash-table or plist/alist."
  (cond ((hash-table-p h) (gethash key h))
        ((and (consp h) (consp (car h))) (alist-get key h nil nil #'equal))
        ((listp h) (plist-get h (if (keywordp key) key (intern (concat ":" key)))))
        (t nil)))

(defun hermes-image--current-session-id ()
  "Return the active session id from the current buffer's state, or nil."
  (and hermes--state (hermes-state-session-id hermes--state)))

(defun hermes-image--normalize-path (path)
  "Expand PATH: strip `file://' prefix, expand `~', and absolutize."
  (let ((p (or path "")))
    (when (string-prefix-p "file://" p)
      (setq p (substring p (length "file://"))))
    (expand-file-name p)))

;;;; Thin RPC wrappers

(defun hermes-image--rpc-attach (session-id path callback)
  "Send `image.attach' RPC for SESSION-ID and PATH.
CALLBACK receives (RESULT ERROR)."
  (hermes-rpc-request
   "image.attach"
   (list :session_id session-id :path path)
   callback))

(defun hermes-image--rpc-clipboard-paste (session-id callback)
  "Send `clipboard.paste' RPC for SESSION-ID.
CALLBACK receives (RESULT ERROR)."
  (hermes-rpc-request
   "clipboard.paste"
   (list :session_id session-id)
   callback))

(defun hermes-image--rpc-detect-drop (session-id text callback)
  "Send `input.detect_drop' RPC for SESSION-ID with TEXT.
CALLBACK receives (RESULT ERROR)."
  (hermes-rpc-request
   "input.detect_drop"
   (list :session_id session-id :text text)
   callback))

;;;; Bench repaint

(defun hermes-image--repaint-bench (parent)
  "Trigger a bench repaint for PARENT, preserving in-flight content.
The bench reads `hermes-state-attachments' from PARENT when rendering."
  (when (and (buffer-live-p parent)
             (fboundp 'hermes-bench-active-p))
    (let ((bench (hermes-bench-active-p parent)))
      (when (buffer-live-p bench)
        (with-current-buffer bench
          (when (fboundp 'hermes-bench--repaint-preserving-stream)
            (hermes-bench--repaint-preserving-stream)))))))

;;;; Interactive commands

;;;###autoload
(defun hermes-image-attach-file (&optional file)
  "Attach an image FILE to the current Hermes session.
Interactively, prompts for a file via `read-file-name'.

The bench shows an optimistic placeholder immediately; the entry is
updated with width/height/token estimate when the gateway responds,
or removed with an error status if the gateway rejects the file."
  (interactive "fImage file: ")
  (unless (or (derived-mode-p 'hermes-mode)
              (bound-and-true-p hermes-minor-mode)
              (and (boundp 'hermes-bench--parent-buffer)
                   hermes-bench--parent-buffer))
    (user-error "Not in a Hermes buffer"))
  (let* ((parent (or (and (boundp 'hermes-bench--parent-buffer)
                          hermes-bench--parent-buffer)
                     (current-buffer)))
         (path (hermes-image--normalize-path file))
         (name (file-name-nondirectory path))
         (attach-id (hermes-image--next-attach-id)))
    (with-current-buffer parent
      (let ((sid (hermes-image--current-session-id)))
        (unless sid
          (user-error "No active Hermes session in this buffer"))
        ;; Optimistic insert.
        (hermes-dispatch
         (cons :attachment-add
               (list :attach-id attach-id
                     :path path
                     :name name
                     :status 'pending)))
        (hermes-image--repaint-bench parent)
        (hermes-image--rpc-attach
         sid path
         (lambda (result error)
           (when (buffer-live-p parent)
             (with-current-buffer parent
               (cond
                ((or error (not (eq t (and result (hermes-image--get result "attached")))))
                 (let ((msg (or (and (hash-table-p error) (gethash "message" error))
                                (and result (hermes-image--get result "message"))
                                (format "%S" error))))
                   (hermes-dispatch
                    (cons :attachment-remove (list :attach-id attach-id)))
                   (hermes-image--repaint-bench parent)
                   (when (fboundp 'hermes-bench-show-status)
                     (hermes-bench-show-status
                      parent (format "Attach failed: %s" msg) t))))
                (t
                 (let* ((rpath (or (hermes-image--get result "path") path))
                        (w (hermes-image--get result "width"))
                        (h (hermes-image--get result "height")))
                   (unless (and w h)
                     (let ((dims (hermes-image--probe-dimensions rpath)))
                       (when dims
                         (setq w (or w (car dims))
                               h (or h (cdr dims))))))
                   (hermes-dispatch
                    (cons :attachment-update
                          (list :attach-id attach-id
                                :path rpath
                                :name (or (hermes-image--get result "name") name)
                                :width w
                                :height h
                                :token-estimate (hermes-image--get result "token_estimate")
                                :status 'attached))))
                 (hermes-image--repaint-bench parent)))))))))
    attach-id))

(defun hermes-image--insert-clipboard-text-locally ()
  "Yank clipboard text into the bench input area (or current buffer)."
  (let ((text (or (and (fboundp 'gui-get-selection)
                       (ignore-errors (gui-get-selection 'CLIPBOARD 'STRING)))
                  (current-kill 0 t))))
    (when (and text (stringp text) (not (string-empty-p text)))
      (insert text)
      t)))

(defun hermes-image--clipboard-has-image-p ()
  "Return non-nil if the local clipboard probe indicates an image.
Returns `t' for definite image, `nil' for definite non-image, and the
symbol `unknown' when the probe is unavailable (terminal Emacs, missing
selection support).  Callers should treat `unknown' as \"send the RPC\"."
  (cond
   ((not (fboundp 'gui-get-selection)) 'unknown)
   ((not (display-graphic-p)) 'unknown)
   (t
    (condition-case _
        (let ((targets (gui-get-selection 'CLIPBOARD 'TARGETS)))
          (cond
           ((null targets) 'unknown)
           ((vectorp targets)
            (let ((has-image nil)
                  (has-text nil))
              (dotimes (i (length targets))
                (let ((tgt (aref targets i)))
                  (when (symbolp tgt)
                    (let ((n (symbol-name tgt)))
                      (cond
                       ((string-prefix-p "image/" n) (setq has-image t))
                       ((or (string= n "STRING")
                            (string= n "UTF8_STRING")
                            (string-prefix-p "text/" n))
                        (setq has-text t)))))))
              (cond (has-image t)
                    (has-text nil)
                    (t 'unknown))))
           (t 'unknown)))
      (error 'unknown)))))

(defun hermes-image--clipboard-fallback-yank (parent error result)
  "Fallback path when `clipboard.paste' reports no image.
Yanks clipboard text into the bench input area; otherwise shows an
error status in the bench paired with PARENT."
  (let ((bench (and (fboundp 'hermes-bench-active-p)
                    (hermes-bench-active-p parent)))
        (yanked nil))
    (if (buffer-live-p bench)
        (with-current-buffer bench
          (setq yanked (hermes-image--insert-clipboard-text-locally)))
      (setq yanked (hermes-image--insert-clipboard-text-locally)))
    (unless yanked
      (let ((msg (or (and (hash-table-p error) (gethash "message" error))
                     (and result (hermes-image--get result "message"))
                     "no image or text on clipboard")))
        (when (fboundp 'hermes-bench-show-status)
          (hermes-bench-show-status parent msg t))))))

(defun hermes-image--clipboard-paste-callback (parent attach-id result error)
  "RPC callback for `clipboard.paste' against PARENT and ATTACH-ID."
  (when (buffer-live-p parent)
    (with-current-buffer parent
      (cond
       ((and (not error)
             result
             (eq t (hermes-image--get result "attached")))
        (let* ((rpath (hermes-image--get result "path"))
               (w (hermes-image--get result "width"))
               (h (hermes-image--get result "height")))
          (unless (and w h)
            (let ((dims (hermes-image--probe-dimensions rpath)))
              (when dims
                (setq w (or w (car dims))
                      h (or h (cdr dims))))))
          (hermes-dispatch
           (cons :attachment-update
                 (list :attach-id attach-id
                       :path rpath
                       :name (or (hermes-image--get result "name") "clipboard")
                       :width w
                       :height h
                       :token-estimate (hermes-image--get result "token_estimate")
                       :status 'attached))))
        (hermes-image--repaint-bench parent))
       (t
        (hermes-dispatch
         (cons :attachment-remove (list :attach-id attach-id)))
        (hermes-image--repaint-bench parent)
        (hermes-image--clipboard-fallback-yank parent error result))))))

;;;###autoload
(defun hermes-image-clipboard-paste ()
  "Paste from the system clipboard into the current Hermes session.

If the clipboard holds an image, send `clipboard.paste' so the gateway
saves it under `~/.hermes/images/' and attaches it.  If it holds text,
yank locally into the bench input area — no RPC round-trip.

When the local probe is inconclusive (terminal Emacs, no display), the
RPC path is taken; if the gateway also reports no image, fall back to
local text yank."
  (interactive)
  (let ((parent (or (and (boundp 'hermes-bench--parent-buffer)
                         hermes-bench--parent-buffer)
                    (current-buffer))))
    (unless (buffer-live-p parent)
      (user-error "No live Hermes buffer"))
    (let ((probe (hermes-image--clipboard-has-image-p)))
      (cond
       ((null probe)
        (unless (hermes-image--insert-clipboard-text-locally)
          (message "hermes: clipboard is empty")))
       (t
        (let ((sid (with-current-buffer parent (hermes-image--current-session-id))))
          (unless sid
            (user-error "No active Hermes session in this buffer"))
          (let ((attach-id (hermes-image--next-attach-id)))
            (with-current-buffer parent
              (hermes-dispatch
               (cons :attachment-add
                     (list :attach-id attach-id
                           :name "clipboard"
                           :status 'pending)))
              (hermes-image--repaint-bench parent))
            (hermes-image--rpc-clipboard-paste
             sid
             (lambda (result error)
               (hermes-image--clipboard-paste-callback
                parent attach-id result error))))))))))

(provide 'hermes-image)
;;; hermes-image.el ends here
