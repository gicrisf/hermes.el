;;; hermes-render.el --- Segmented renderer for the Hermes Org buffer -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Two render hooks, one per atom.  `hermes--render' inspects which slots
;; changed and dispatches to a sub-renderer.  Each sub-renderer touches
;; only the region it owns: the streaming sentinel for in-flight text, an
;; append at point-max for committed messages, the header-line for
;; session-info.  All edits run inside `with-silent-modifications' and
;; `save-excursion' so the buffer never goes dirty and point doesn't jump.
;;
;; Segmented rendering: state stores a vector of typed segments (text,
;; thinking, reasoning, tool).  The renderer does a full replace of the
;; segment region on every stream update (Option A from the plan), keeping
;; the implementation simple.  Markers track the segment region boundaries.

;;; Code:

(require 'cl-lib)
(require 'org-id)
(require 'hermes-state)
(require 'hermes-skin)
(require 'hermes-md)
(require 'hermes-tool-formatters)

;;;; Buffer-local markers for the in-flight region

(defvar-local hermes--ui-line ""
  "Right-hand status text driven by the ephemeral state.")

(defvar-local hermes--stream-headline-marker nil
  "Marker at the start of the in-flight `** assistant' headline.")

(defvar-local hermes--stream-segments-start nil
  "Marker: start of the rendered segment region (after property drawer).")

(defvar-local hermes--stream-segments-end nil
  "Marker: end of the rendered segment region.")

(defvar-local hermes--stream-subagents-marker nil
  "Marker at the start of the subagent block region in the stream.")

;; The bench is the live (in-flight) assistant turn region.  Renderers
;; mutate inside the bench every stream tick; everything outside is
;; frozen — never touched after the previous turn committed.  The
;; markers below are the single source of truth for that boundary; the
;; older segment / subagent markers remain as interior bounds used by
;; the segment-region delete+reinsert.
(defvar-local hermes--bench-start nil
  "Marker at the start of the live assistant turn.  nil between turns.")

(defvar-local hermes--bench-end nil
  "Marker at the end of the live region.  Rear-advancing.  nil between turns.")

(defvar-local hermes--bench-overlay nil
  "Overlay tinting the bench so the user can see the live region.")

;;;; Top-level dispatch

(defun hermes--render (old new)
  "Diff OLD vs NEW (both `hermes-state') and update the buffer."
  ;; Two scopes for post-passes:
  ;;   * msg-append-start  → start of just-inserted user/system message(s).
  ;;   * bench-touched-p   → bench markers/content changed this tick.
  ;; Splitting them keeps the renderer from re-processing frozen turns
  ;; just because point-max moved — the user's manual fold state above
  ;; the bench survives forever.
  (let ((msg-append-start nil)
        (bench-touched-p nil)
        ;; Structural change → reset the org-element cache at the end.
        ;; Streaming chunks (`stream-update') don't qualify: they reshape
        ;; only the current assistant turn, and resetting on every token
        ;; defeats the cache for the whole buffer.
        (structural-change nil))
    (with-silent-modifications
      (save-excursion
        ;; 1. Messages grew → append new tail messages.
        (let* ((old-n (length (and old (hermes-state-messages old))))
               (new-n (length (hermes-state-messages new))))
          (when (> new-n old-n)
            (setq msg-append-start (point-max)
                  structural-change t)
            (cl-loop for i from old-n below new-n
                     for msg = (aref (hermes-state-messages new) i)
                     do (hermes--render-committed-message msg))))
        ;; 2. Stream lifecycle.
        (let ((os (and old (hermes-state-stream old)))
              (ns (hermes-state-stream new)))
          (cond ((and (null os) ns)
                 (setq structural-change t bench-touched-p t)
                 (hermes--stream-begin))
                ((and os (null ns))
                 (setq structural-change t bench-touched-p t)
                 (hermes--stream-commit))
                ((not (eq os ns))
                 (setq bench-touched-p t)
                 (hermes--stream-update os ns))))
        ;; 3. Header line — session-info / connection / usage.
        (unless (and old
                      (eq (hermes-state-session-info old)
                          (hermes-state-session-info new))
                      (eq (hermes-state-connection old)
                          (hermes-state-connection new))
                      (eq (hermes-state-usage old)
                          (hermes-state-usage new)))
          (hermes--render-header new))
        ;; 4. Queue length changed → refresh header-line :eval forms.
        (unless (eq (and old (hermes-state-queue old))
                     (hermes-state-queue new))
          (force-mode-line-update))))
    (when (derived-mode-p 'org-mode)
      ;; Drop the org-element cache table whenever the bench shifted or
      ;; a committed message landed.  `with-silent-modifications'
      ;; suppresses `after-change-functions', so the cache otherwise
      ;; accumulates stale parent links and `org-element--cache: Got
      ;; empty parent while parsing' eventually fires.  The reset is
      ;; cheap — just discards tables; subsequent queries re-parse on
      ;; demand.
      (when (or structural-change bench-touched-p)
        (org-element-cache-reset))
      ;; Refresh just-appended message region (post-commit, after the
      ;; bench has been torn down — committed-message inserts and
      ;; `stream-commit' both bump point-max).
      (when msg-append-start
        (hermes--refresh-region msg-append-start (point-max)))
      ;; Refresh the live bench, if any.
      (when (and bench-touched-p
                 (markerp hermes--bench-start)
                 (marker-position hermes--bench-start)
                 (markerp hermes--bench-end)
                 (marker-position hermes--bench-end))
        (hermes--refresh-region (marker-position hermes--bench-start)
                                (marker-position hermes--bench-end))))))

(defun hermes--refresh-region (start end)
  "Run indent + drawer-hide + fold-repair passes over [START, END).
These passes do the work that `after-change-functions' would have done
were it not suppressed by `with-silent-modifications'.  Lives outside
the silent block so the org-element cache (just reset by the caller)
has a chance to repopulate cleanly."
  (when (> end start)
    ;; Clear any stale outline fold that erroneously spans into this
    ;; region — e.g. a folded `*** Reasoning' from the previous
    ;; assistant turn that would otherwise swallow the new headline
    ;; onto the ellipsis line.
    (when (fboundp 'org-fold-region)
      (ignore-errors (org-fold-region start end nil 'outline)))
    (when (and (bound-and-true-p org-indent-mode)
               (fboundp 'org-indent-add-properties))
      (ignore-errors
        (org-indent-add-properties start end)))
    (hermes--hide-drawers start end)))

(defun hermes--render-ui (_old new)
  "Re-render the header line from the ephemeral state NEW."
  (setq hermes--ui-line
        (format " %s" (or (hermes-ui-state-status-text new) "")))
  (force-mode-line-update))

;;;; Committed messages

(defun hermes--render-committed-message (msg)
  "Append MSG to the buffer.  Skip assistant messages — those are streamed."
  (pcase (hermes-message-kind msg)
    ('user      (hermes--insert-turn-headline 'user   'hermes-user-face
                                              (hermes-message-text msg)))
    ('system    (hermes--insert-turn-headline 'system 'hermes-system-face
                                              (hermes-message-text msg)))
    ('assistant nil)))

(defun hermes--insert-turn-headline (kind face text)
  "Insert a level-1 heading for a new turn (user or system message)."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (let* ((prefix   (hermes--first-line (or text "")))
         (tag      (symbol-name kind))
         (heading  (format "* %s: %s" tag prefix))
         (sid      (or (hermes-state-session-id hermes--state) ""))
         (info     (hermes-state-session-info hermes--state))
         (model    (and (hash-table-p info) (gethash "model" info)))
         (hb       (point)))
    (insert (format "%s %s\n" heading (hermes--tag-spacer heading)))
    (hermes--face-overlay hb (1- (point)) face)
    (hermes--insert-properties
     `(("HERMES_SESSION" . ,sid)
       ("HERMES_MODEL" . ,model)
       ("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
    (when (derived-mode-p 'org-mode)
      ;; Local cache reset before `org-id-get-create' parses: the cache
      ;; is stale here because `with-silent-modifications' suppressed
      ;; `after-change-functions' across the streamed turn.  Safe to do
      ;; — `insert-turn-headline' only runs on committed-message append,
      ;; not on the hot streaming path.
      (org-element-cache-reset)
      (goto-char hb)
      (ignore-errors (org-id-get-create))
      (goto-char (point-max)))
    (when (and text (not (string-empty-p text)))
      (insert text)
      (unless (eq (char-before) ?\n) (insert "\n")))))
;; NB: outline-fold repair for the just-inserted region now lives in
;; `hermes--refresh-region', invoked from `hermes--render' after
;; `with-silent-modifications' has exited.

(defun hermes--tag-spacer (heading)
  "Return enough spaces to right-align a :HERMES: tag at column 80."
  (let* ((width (string-width heading))
         (pad   (- 77 width)))
    (if (> pad 0) (make-string pad ?\s) " ")))

(defun hermes--face-overlay (beg end face)
  "Put a face overlay over the headline region [BEG, END)."
  (let ((ov (make-overlay beg end nil t nil)))
    (overlay-put ov 'face face)
    (overlay-put ov 'hermes-headline t)))

;;; Shell helpers

(defun hermes--first-line (text)
  "Return TEXT up to (but not including) the first newline."
  (let ((pos (cl-position ?\n text)))
    (if pos (substring text 0 pos) text)))

(defun hermes--now-iso ()
  "Return current time as an ISO-8601 string."
  (format-time-string "%Y-%m-%dT%H:%M:%S%z"))

(defun hermes--insert-properties (alist)
  "Insert a :PROPERTIES: drawer from ALIST ((prop . value) …) at point."
  (insert ":PROPERTIES:\n")
  (dolist (cell alist)
    (let ((prop (car cell))
          (val  (cdr cell)))
      (insert (format ":%s: %s\n" prop (or val "")))))
  (insert ":END:\n"))

;;;; Segment formatting

(defun hermes--format-response (content)
  "Return an Org level-3 heading wrapping the assistant CONTENT.
The heading is *not* tagged with `hermes-fold' so it stays expanded —
this prevents the response prose from being captured by a preceding
folded `*** Thinking' / `*** Reasoning' subtree."
  (if (or (null content) (string-empty-p content))
      ""
    (let ((body (hermes-md-to-org content)))
      (concat "*** Response\n"
              body
              (if (string-suffix-p "\n" body) "" "\n")))))

(defun hermes--format-cot-block (label content fold-id)
  "Return an Org level-3 heading for a chain-of-thought CONTENT.
LABEL is e.g. \"Thinking\" or \"Reasoning\".  FOLD-ID is the segment id
used to remember user expansion across re-renders.  Headings are tagged
with the `hermes-fold' text property so `hermes--apply-tool-folds' will
collapse them on insertion."
  (if (or (null content) (string-empty-p content))
      ""
    (let* ((kind (downcase label))
           (heading (format "*** %s" label))
           (heading-line
            (concat (propertize heading
                                'hermes-fold t
                                'hermes-fold-id fold-id)
                    "\n"))
           (props (concat ":PROPERTIES:\n"
                          (format ":HERMES_KIND: %s\n" kind)
                          ":END:\n"))
           (body (if (string-suffix-p "\n" content) content
                   (concat content "\n"))))
      (concat heading-line props body "\n"))))

(defun hermes--format-subagent (sa)
  "Return an Org subtree string for subagent SA."
  (let* ((goal (or (hermes-subagent-goal sa) "subagent"))
         (status (hermes-subagent-status sa))
         (status-label (pcase status
                         ('queued "queued")
                         ('running "running…")
                         ('complete "complete")
                         ('error "error")
                         (_ (format "%s" status))))
         (thinking (hermes-subagent-thinking sa))
         (tools (hermes-subagent-tools sa))
         (notes (hermes-subagent-notes sa))
         (summary (hermes-subagent-summary sa))
         (duration (hermes-subagent-duration sa))
         (id (hermes-subagent-id sa))
         parts)
    (push (format "**** %s (%s)\n:PROPERTIES:\n:ID:       %s\n:END:\n"
                  goal status-label id) parts)
    (when (and thinking (not (string-empty-p thinking)))
      (push (concat "#+begin_example Thinking\n"
                    thinking
                    (unless (eq (aref thinking (1- (length thinking))) ?\n) "\n")
                    "#+end_example\n") parts))
    (when (> (length tools) 0)
      (push (mapconcat
             (lambda (tool-plist)
               (format "- %s(%s)"
                       (or (plist-get tool-plist :name) "?")
                       (or (plist-get tool-plist :args) "")))
             tools "\n")
            parts))
    (when (> (length notes) 0)
      (push (mapconcat (lambda (n) (format "- %s" n)) notes "\n") parts))
    (when (memq status '(complete error))
      (push (format "#+begin_example\n%s (%ss)\n#+end_example\n"
                    (or summary "")
                    (if duration (format "%.1f" duration) "?"))
            parts))
    (mapconcat #'identity (nreverse parts) "\n")))

(defun hermes--format-subagents-block (subagents)
  "Return an Org block string for all SUBAGENTS, or empty string if none."
  (if (not (and (vectorp subagents) (> (length subagents) 0)))
      ""
    (let (parts)
      (dotimes (i (length subagents))
        (let ((formatted (hermes--format-subagent (aref subagents i))))
          (when (> (length formatted) 0)
            (push formatted parts))))
      (let ((result (mapconcat #'identity (nreverse parts) "\n")))
        (if (> (length result) 0)
            (concat result "\n")
          "")))))

(defun hermes--update-subagent-views (subagents)
  "Replace the subagent block region in the stream buffer."
  (let ((formatted (hermes--format-subagents-block subagents)))
    (cond ((and (string-empty-p formatted)
                (markerp hermes--stream-subagents-marker)
                (marker-position hermes--stream-subagents-marker))
           (delete-region hermes--stream-subagents-marker (point-max))
           (set-marker hermes--stream-subagents-marker nil))
          ((not (string-empty-p formatted))
           (let ((boundary
                  (if (and (markerp hermes--stream-subagents-marker)
                           (marker-position hermes--stream-subagents-marker))
                      (marker-position hermes--stream-subagents-marker)
                    (if (and (markerp hermes--stream-segments-end)
                             (marker-position hermes--stream-segments-end))
                        (marker-position hermes--stream-segments-end)
                      (point-max)))))
             (delete-region boundary (point-max))
             (goto-char boundary)
             (insert formatted)
             (unless (and (markerp hermes--stream-subagents-marker)
                          (marker-position hermes--stream-subagents-marker))
               (setq hermes--stream-subagents-marker (copy-marker boundary))
               (set-marker-insertion-type hermes--stream-subagents-marker nil)))))
    (hermes--bench-sync)))

(defun hermes--tool-status-keyword (status)
  "Map a tool STATUS symbol to an org TODO keyword string."
  (pcase status
    ('generating "RUNNING")
    ('running    "RUNNING")
    ('complete   "DONE")
    ('error      "ERROR")
    (_           "DONE")))

(defun hermes--tool-properties (tool)
  "Return an alist of org PROPERTY entries for TOOL."
  (let ((dur (hermes-tool-duration tool))
        (tid (hermes-tool-id tool))
        (acc nil))
    (when tid  (push (cons "TOOL_ID" (format "%s" tid)) acc))
    (when dur  (push (cons "DURATION" (format "%.1fs" dur)) acc))
    (nreverse acc)))

(defun hermes--format-property-drawer (props)
  "Render PROPS (an alist) as an org PROPERTIES drawer, or empty string."
  (if (null props) ""
    (concat ":PROPERTIES:\n"
            (mapconcat (lambda (kv)
                         (format ":%s: %s" (car kv) (cdr kv)))
                       props "\n")
            "\n:END:\n")))

(defun hermes--format-tool (tool)
  "Return an Org block string for a single TOOL.
Heading uses an org TODO keyword for status; body is produced by a
per-tool formatter from `hermes-tool-formatters'."
  (let* ((name      (or (hermes-tool-name tool) "tool"))
         (status    (hermes-tool-status tool))
         (keyword   (hermes--tool-status-keyword status))
         (formatter (hermes-tool--lookup name))
         (parts     (funcall formatter tool))
         (summary   (or (plist-get parts :summary) name))
         (body      (or (plist-get parts :body) ""))
         (fold-p    (and (eq status 'complete) (plist-get parts :fold)))
         (props     (hermes--tool-properties tool))
         (heading   (format "*** %s %s" keyword summary))
         ;; Tag the heading line with a text property so the renderer can
         ;; fold it after insertion without re-parsing org structure.
         (heading-line
          (if fold-p
              (concat
               (propertize heading 'hermes-fold t
                           'hermes-fold-id (hermes-tool-id tool))
               "\n")
            (concat heading "\n")))
         (out (concat heading-line
                      (hermes--format-property-drawer props)
                      body)))
    (if (> (length out) 0)
        (concat out (if (string-suffix-p "\n" out) "" "\n"))
      out)))

(defun hermes--format-segment (seg)
  "Return Org string for a single SEGMENT."
  (let ((type (aref seg 1))
        (content (aref seg 2))
        (sid (aref seg 3)))
    (pcase type
      ('text (hermes--format-response content))
      ('thinking (hermes--format-cot-block "Thinking" content sid))
      ('reasoning (hermes--format-cot-block "Reasoning" content sid))
      ('tool (hermes--format-tool content))
      ('system (format "#+begin_comment\n%s\n#+end_comment\n" content))
      (_ ""))))

(defun hermes--render-stream-segments (segments)
  "Render all SEGMENTS in order into the buffer."
  (unless (and (markerp hermes--stream-segments-start)
               (markerp hermes--stream-segments-end))
    (setq hermes--stream-segments-start (point-marker)
          hermes--stream-segments-end (point-marker))
    (set-marker-insertion-type hermes--stream-segments-start nil)
    (set-marker-insertion-type hermes--stream-segments-end t))
  (let ((start (marker-position hermes--stream-segments-start))
        (end (marker-position hermes--stream-segments-end)))
    (when (> end start)
      (delete-region start end))
    (goto-char start)
    (dotimes (i (length segments))
      (let ((formatted (hermes--format-segment (aref segments i))))
        (when (> (length formatted) 0)
          (unless (or (= i 0) (bolp))
            (insert "\n"))
          (insert formatted)
          (unless (bolp)
            (insert "\n")))))
    (set-marker hermes--stream-segments-end (point))
    (hermes--apply-tool-folds start (marker-position hermes--stream-segments-end))
    (hermes--bench-sync)))

(defvar-local hermes--unfolded-tool-ids nil
  "Set (list) of fold-ids the user has manually expanded; never re-folded.
Covers tool blocks and chain-of-thought (thinking/reasoning) blocks.")

(defun hermes--remember-cycle (state)
  "Org cycle hook: record the fold-id when the user expands a folded block.
STATE is one of `folded', `children', `subtree', `all', etc."
  (when (memq state '(children subtree all))
    (let ((fid (save-excursion
                 (beginning-of-line)
                 (get-text-property (point) 'hermes-fold-id))))
      (when (and fid (not (member fid hermes--unfolded-tool-ids)))
        (push fid hermes--unfolded-tool-ids)))))

(defun hermes--hide-drawers (start end)
  "Collapse every PROPERTIES drawer between START and END.
Uses plain overlays — does not touch `org-element' — so this stays
cheap to call once per render even during streaming, where
`org-fold-hide-drawer-toggle' would force a full re-parse each time."
  (when (derived-mode-p 'org-mode)
    (add-to-invisibility-spec '(org-hide-drawer . t))
    (save-excursion
      (goto-char start)
      (let ((case-fold-search t))
        (while (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
          (let ((beg (line-end-position)))
            (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
              ;; Skip if a hermes drawer overlay already covers this range.
              (unless (cl-some (lambda (o) (overlay-get o 'hermes-drawer))
                                (overlays-at beg))
                (let ((ov (make-overlay beg (line-end-position))))
                  (overlay-put ov 'invisible 'org-hide-drawer)
                  (overlay-put ov 'evaporate t)
                  (overlay-put ov 'hermes-drawer t)
                  (overlay-put ov 'isearch-open-invisible
                                (lambda (o) (delete-overlay o))))))))))))

(defun hermes--apply-tool-folds (start end)
  "Hide subtrees marked with `hermes-fold' between START and END.
Skips tools whose id is in `hermes--unfolded-tool-ids'."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char start)
      (let (pos)
        (while (and (< (point) end)
                    (setq pos (text-property-any (point) end 'hermes-fold t)))
          (goto-char pos)
          (let ((fid (get-text-property pos 'hermes-fold-id)))
            (unless (and fid (member fid hermes--unfolded-tool-ids))
              (ignore-errors
                (if (fboundp 'org-fold-hide-subtree)
                    (org-fold-hide-subtree)
                  (outline-hide-subtree)))))
          ;; Move past this heading line so we don't loop forever.
          (forward-line 1))))))

;;;; Stream lifecycle

(defun hermes--stream-begin ()
  "Insert a `** assistant' headline with a property drawer and prepare markers.
Also opens a bench overlay tinting the live region."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  ;; Bench-start anchors here; bench-end advances with insertion so it
  ;; tracks the growing live region.
  (setq hermes--bench-start (copy-marker (point) nil)
        hermes--bench-end   (copy-marker (point) t))
  (setq hermes--stream-headline-marker (point-marker))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (let ((hb (point))
        (heading "** assistant")
        (spacer  (make-string (- 74 (length "** assistant")) ?\s)))
    (insert (format "%s %s :hermes:\n" heading spacer))
    (hermes--face-overlay hb (1- (point)) 'hermes-assistant-face))
  (hermes--insert-properties
   `(("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  (setq hermes--stream-segments-start (point-marker)
        hermes--stream-segments-end   (point-marker))
  (set-marker-insertion-type hermes--stream-segments-start nil)
  (set-marker-insertion-type hermes--stream-segments-end   t)
  (setq hermes--stream-subagents-marker (copy-marker (point-marker)))
  (set-marker-insertion-type hermes--stream-subagents-marker t)
  ;; Open the bench overlay.  rear-advance so it grows with streamed
  ;; content; low priority so fontification / TODO faces sit on top.
  (hermes--bench-sync)
  (when hermes--bench-overlay (delete-overlay hermes--bench-overlay))
  (setq hermes--bench-overlay
        (make-overlay (marker-position hermes--bench-start)
                      (marker-position hermes--bench-end)
                      nil nil t))
  (overlay-put hermes--bench-overlay 'face 'hermes-bench-face)
  (overlay-put hermes--bench-overlay 'hermes-bench t)
  (overlay-put hermes--bench-overlay 'priority -50))

(defun hermes--bench-sync ()
  "Pull `hermes--bench-end' up to the tail of the live content."
  (when (and (markerp hermes--bench-end)
             (marker-position hermes--bench-end))
    (let ((tail (max (or (and (markerp hermes--stream-segments-end)
                              (marker-position hermes--stream-segments-end))
                         0)
                     (or (and (markerp hermes--stream-subagents-marker)
                              (marker-position hermes--stream-subagents-marker))
                         0)
                     (point))))
      (set-marker hermes--bench-end tail))
    (when (overlayp hermes--bench-overlay)
      (move-overlay hermes--bench-overlay
                    (marker-position hermes--bench-start)
                    (marker-position hermes--bench-end)))))

(defun hermes--stream-commit ()
  "Stream finished: stamp Org :ID:s on the trail, drop markers and bench."
  (when (and (derived-mode-p 'org-mode)
             (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  ;; Tear down the bench: tint disappears, markers freed, the region
  ;; below is now frozen.  Any folds the user opens in this region from
  ;; here on persist trivially because nothing re-applies fold passes
  ;; outside a bench.
  (when (overlayp hermes--bench-overlay)
    (delete-overlay hermes--bench-overlay))
  (setq hermes--bench-overlay nil)
  (dolist (m (list hermes--bench-start
                    hermes--bench-end
                    hermes--stream-segments-start
                    hermes--stream-segments-end
                    hermes--stream-subagents-marker
                    hermes--stream-headline-marker))
    (when (markerp m) (set-marker m nil)))
  (setq hermes--bench-start nil
        hermes--bench-end nil
        hermes--stream-segments-start nil
        hermes--stream-segments-end nil
        hermes--stream-subagents-marker nil
        hermes--stream-headline-marker nil
        hermes--unfolded-tool-ids nil))

(defun hermes--stream-update (old-stream new-stream)
  "Reflect OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-segments-start)
            (null hermes--stream-segments-end))
    (hermes--stream-begin))
  (let ((new-segs (hermes-stream-segments new-stream)))
    (when (vectorp new-segs)
      (hermes--render-stream-segments new-segs)))
  (when (vectorp (hermes-stream-subagents new-stream))
    (hermes--update-subagent-views (hermes-stream-subagents new-stream))))

;;;; Header line

(defun hermes--render-header (_state)
  "Set `header-line-format'.  Reads `hermes--state' live via :eval."
  (setq header-line-format
        (list
         " Hermes"
         '(:eval (pcase (and hermes--state
                             (hermes-state-connection hermes--state))
                   ('connected    " · ●")
                   ('connecting   " · ◐")
                   ('disconnected " · ○")
                   (_             "")))
          '(:eval
            (let* ((info (and hermes--state
                              (hermes-state-session-info hermes--state)))
                   (model (and (hash-table-p info) (gethash "model" info))))
              (if model (format " · %s" model) "")))
          '(:eval
            (let* ((usage (and hermes--state
                               (hermes-state-usage hermes--state)))
                   (sent (and usage (gethash "tokens_sent" usage)))
                   (recv (and usage (gethash "tokens_received" usage))))
              (if (or sent recv)
                  (format " · %s→%s"
                          (or sent "?") (or recv "?"))
                "")))
          '(:eval
            (let ((q (and hermes--state (hermes-state-queue hermes--state))))
              (if (and q (> (length q) 0))
                  (format " · queue: %d" (length q))
                "")))
         '(:eval (or hermes--ui-line ""))))
  (force-mode-line-update))

(provide 'hermes-render)
;;; hermes-render.el ends here
