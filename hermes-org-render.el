;;; hermes-org-render.el --- Segmented renderer for the Hermes Org buffer -*- lexical-binding: t; -*-

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

(declare-function hermes-bench-active-p "hermes-comint" (&optional parent))

;;;; Buffer-local markers for the in-flight region

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

;;;; Stream paint throttling
;;
;; The reducer applies every `message.delta' / `reasoning.delta' to
;; `(hermes--current-state)' synchronously, but the buffer paint is rate-limited so
;; high-frequency token streams (>25 Hz) don't saturate the UI thread.
;; The first delta after a cooldown gap paints immediately and starts a
;; cooldown timer; deltas arriving while the timer is active stash their
;; snapshot in `hermes--stream-render-pending' and the timer flushes the
;; latest snapshot when it fires.  Lifecycle transitions (stream-begin,
;; stream-commit, error) always paint synchronously — see `hermes--render'.

(defcustom hermes-image-display-max-dim 600
  "Maximum pixel size for the longest side of a displayed image.
Inline images larger than this are scaled down for display via
`#+attr_org:' while their real dimensions remain canonical in
`#+attr_hermes:'.  Set to nil to disable display scaling (images
will then either honor `#+attr_org:' from the buffer or fall back
to the window width)."
  :type '(choice (integer :tag "Pixels") (const :tag "Disable" nil))
  :group 'hermes)

(defcustom hermes-render-stream-throttle 0.04
  "Floor (minimum seconds) between consecutive stream re-renders.
Acts as a lower bound on the *adaptive* interval computed by
`hermes--adaptive-throttle-interval', which steps up as the bench
grows:

  < 1,000 chars  → 0.04s (25 Hz)
  < 5,000 chars  → 0.20s (5 Hz)
  < 10,000 chars → 1.00s (1 Hz)
  ≥ 10,000 chars → 2.00s (0.5 Hz)

The effective interval is `(max hermes-render-stream-throttle
adaptive-step)'.  Set this to 0 to disable the floor and let the
adaptive table run unconstrained at the small-bench end; set it to a
large value (e.g. 1.0) to force a fixed cap regardless of bench size.
A value greater than or equal to 2.0 effectively disables stepping."
  :type 'number
  :group 'hermes)

(defvar-local hermes--stream-render-pending nil
  "Latest stream snapshot waiting to be painted, or nil.
Set by `hermes--render' when throttling a stream delta;
consumed by `hermes--stream-flush'.")

(defvar-local hermes--stream-render-timer nil
  "Active `run-with-timer' for the next stream flush, or nil.")

(defvar-local hermes--stream-segments-snapshot nil
  "Vector of (:id ID :type TYPE :length LEN) plists mirroring the
segments currently painted into the buffer.  Used by
`hermes--render-stream-segments' to diff against incoming segments and
replace only the changed range — typically just the last (growing) text
segment.  Cleared on `stream-commit'.")

;;;; Relative heading levels

(defvar-local hermes--container-level 1
  "Org level of the session container heading in this buffer.
Turns are rendered as direct children (`container-level + 1') and the
assistant's reasoning/response/tools sub-headings as grandchildren
(`container-level + 2').  Set once by the major mode (Phase 1: always 1,
since the container lives at point-min).  Phase 2 will derive this from
the `:hermes:'-tagged ancestor of the session's anchor.")

(defun hermes--stars (depth-offset)
  "Return a string of `*' for a heading nested DEPTH-OFFSET below the container.
DEPTH-OFFSET 1 → turn level; 2 → reasoning/response/tool level;
3 → subagent level."
  (make-string (+ hermes--container-level depth-offset) ?*))

;;;; Per-session insertion anchor

(defun hermes--session-insert-point ()
  "Return the position where new content for the active session belongs.
Resolves `hermes--current-session-id' (bound by `hermes-dispatch')
through `hermes--session-markers' to find the session's container
heading, then walks to the end of its Org subtree.  Falls back to
`point-max' when no marker is registered for the session, which is
the single-session-per-buffer case (e.g. the dedicated `*hermes*'
buffer) where the container's subtree spans the whole buffer."
  (let* ((sid (and (boundp 'hermes--current-session-id)
                   hermes--current-session-id))
         (marker (and sid
                      (boundp 'hermes--session-markers)
                      (hash-table-p hermes--session-markers)
                      (gethash sid hermes--session-markers))))
    (if (and (markerp marker) (marker-position marker)
             (derived-mode-p 'org-mode))
        (save-excursion
          (goto-char (marker-position marker))
          (if (org-at-heading-p)
              (progn (org-end-of-subtree t t) (point))
            (point-max)))
      (point-max))))

;;;; Top-level dispatch

(defun hermes--render (old new)
  "Dispatch wrapper: route to the org buffer for the active session.
The state-change-hook is global; this resolves
`hermes--current-session-id' through `hermes--org-buffers' and runs
`hermes--render-1' inside the target buffer.  Falls back to the
current buffer when it is itself a Hermes buffer (direct-call paths
such as tests, or in-buffer dispatch loops)."
  (let* ((sid hermes--current-session-id)
         (buf (and sid (gethash sid hermes--org-buffers))))
    (cond
     ((buffer-live-p buf)
      ;; Rebind the dynamic sid *inside* the target buffer.  `let' creates
      ;; a buffer-local binding; if `hermes--current-session-id' is
      ;; buffer-local in the caller (bench / section), the outer let
      ;; doesn't reach this buffer.  Without this rebind, recursive
      ;; dispatches from render-1 (e.g. `:pending-turns-clear') would
      ;; resolve to nil and write to the global state slot.
      (with-current-buffer buf
        (let ((hermes--current-session-id sid))
          (hermes--render-1 old new))))
     ((bound-and-true-p hermes-org-minor-mode)
      (hermes--render-1 old new)))))

(defun hermes--render-1 (old new)
  "Diff OLD vs NEW (both `hermes-state') and update the current buffer."
  ;; Two scopes for post-passes:
  ;;   * msg-append-start  → start of just-inserted user/system message(s).
  ;;   * bench-touched-p   → bench markers/content changed this tick.
  ;; Splitting them keeps the renderer from re-processing frozen turns
  ;; just because point-max moved — the user's manual fold state above
  ;; the bench survives forever.
  (let ((msg-append-start nil)
        (bench-touched-p nil)
        (committed-region nil)
        (drain-pending nil)
        ;; Structural change → reset the org-element cache at the end.
        ;; Streaming chunks (`stream-update') don't qualify: they reshape
        ;; only the current assistant turn, and resetting on every token
        ;; defeats the cache for the whole buffer.
        (structural-change nil)
        (old-stream-snapshot (and old (hermes-state-stream old)))
        ;; Capture windows whose point sits at `point-max' before the
        ;; paint, so we can keep them pinned to the tail after a
        ;; committed insert.  Done outside `with-silent-modifications'
        ;; so the snapshot reflects the user's current view.
        (old-point-max (point-max))
        (tail-windows nil))
    (dolist (win (get-buffer-window-list (current-buffer) nil t))
      (when (= (window-point win) old-point-max)
        (push win tail-windows)))
    (with-silent-modifications
      (save-excursion
        ;; 1. Stream lifecycle runs FIRST.  When `message.complete' or the
        ;; error path fires, the reducer pushes the assistant msg onto
        ;; pending-turns AND clears the stream in the same step.  If the
        ;; drain ran first, inserting a user/system message at point-max
        ;; would rear-advance `hermes--bench-end' past the new text, and
         ;; `stream-commit' would then write the assistant's usage
         ;; properties into the wrong subtree.  Sealing the stream first
         ;; keeps the bench-anchored writes contained.
        (let* ((os old-stream-snapshot)
               (ns (hermes-state-stream new))
               ;; Paint only if this org buffer is visible (plan 17).
               (target-visible (hermes--buffer-visible-p (current-buffer))))
          (cond ((and (null os) ns)
                 ;; Stream-begin: always run (structural setup must happen
                 ;; even when the target is hidden — see plan 17 §5).
                 (hermes--stream-flush-cancel)
                 (setq structural-change t bench-touched-p t)
                 (hermes--stream-begin))
                ((and os (null ns))
                 ;; Stream-commit: the in-flight region is frozen in
                 ;; place rather than rebuilt from state, so any deltas
                 ;; skipped due to throttle stash OR visibility must be
                 ;; painted synchronously first.
                 (hermes--stream-update nil os)
                 (hermes--stream-flush-cancel)
                 (setq structural-change t bench-touched-p t)
                 (setq committed-region (hermes--stream-commit os)))
                ((not (eq os ns))
                 (cond
                  ;; Throttling disabled — always paint if visible.
                  ((zerop hermes-render-stream-throttle)
                   (when target-visible
                     (setq bench-touched-p t)
                     (hermes--stream-update os ns)))
                  ;; Cooldown idle — paint now (if visible) and arm cooldown.
                  ;; Skip the cooldown arm when invisible: the next delta
                  ;; will re-enter this same branch.  Catchup at commit
                  ;; ensures the final state lands in the buffer.
                  ((null hermes--stream-render-timer)
                   (when target-visible
                     (setq bench-touched-p t)
                     (hermes--stream-update os ns)
                     (hermes--stream-flush-reschedule)))
                  ;; Within cooldown — stash for the timer to flush.
                  (t
                   (setq hermes--stream-render-pending ns))))))
        ;; 2. Drain pending-turns vector into the buffer.  Assistant
        ;; messages are skipped: they're committed in-place by
        ;; `stream-commit' above, and re-inserting here would create a
        ;; duplicate `** assistant' heading at point-max.
        (let ((turns (hermes-state-pending-turns new)))
          (when (and (vectorp turns) (> (length turns) 0))
            (setq drain-pending t)
            (let ((any-inserted nil)
                  (start (point-max)))
              (dotimes (i (length turns))
                (let ((msg (aref turns i)))
                  (unless (eq 'assistant (hermes-message-kind msg))
                    (unless any-inserted
                      (setq msg-append-start start
                            structural-change t
                            any-inserted t))
                    (hermes--insert-committed-turn msg)))))))))
    ;; Clear pending-turns once they've been written to the buffer.
    ;; TEA violation (view-dispatches-mutation): this re-entrant
    ;; dispatch fires the full hook chain synchronously *before* the
    ;; outer dispatch's hook iteration completes.  Comint guards against
    ;; this by reading live state in `hermes-comint--refresh' (F2);
    ;; defense-in-depth fix at source would be `run-at-time 0 …'.
    (when drain-pending
      (hermes-dispatch '(:pending-turns-clear)))
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
                                (marker-position hermes--bench-end)))
      ;; Refresh the assistant region just sealed by `stream-commit'.
      ;; The heading was rewritten and usage properties written inside
      ;; `with-silent-modifications', which strips/skips the org-indent
      ;; `line-prefix' properties and `hermes--hide-drawers' pass.
      (when committed-region
        (hermes--refresh-region (car committed-region)
                                (cdr committed-region)))
      ;; Follow point-max for windows that were pinned to the tail
      ;; before the paint.  Only fires on committed inserts (bench
      ;; commit, pending-turn drain, or non-bench stream-commit); in-
      ;; flight stream deltas don't advance windows so a user who
      ;; scrolled up to read earlier content stays put.
      (when (or msg-append-start committed-region)
        (let ((new-point-max (point-max)))
          (dolist (win tail-windows)
            (when (window-live-p win)
              (set-window-point win new-point-max))))))
    ;; 4. Background tasks: any complete/error task without a buffer-name
    ;; gets its dedicated *hermes-bg:<sid>:<tid>* buffer created and
    ;; populated.  The render fn dispatches :bg-rendered back through
    ;; `hermes-dispatch' so the buffer-name lands in state cleanly.
    (let ((sid (and new (hermes-state-session-id new)))
          (bg-tasks (and new (hermes-state-bg-tasks new))))
      (when (vectorp bg-tasks)
        (dotimes (i (length bg-tasks))
          (let ((task (aref bg-tasks i)))
            (when (and (memq (hermes-bg-task-status task) '(complete error))
                       (null (hermes-bg-task-buffer-name task)))
              (hermes--render-bg-task sid task))))))))

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
    (hermes--hide-drawers start end)
    ;; Align named Hermes todo tables in the region.  `with-silent-
    ;; modifications' suppresses Org's auto-align hooks, so we run an
    ;; explicit pass here.  Scope is targeted to our `hermes-tool-…'
    ;; namespace via the `#+name' line so we never touch user tables.
    ;; END is captured as a marker because `org-table-align' inserts
    ;; whitespace and would otherwise leave the bound stale across
    ;; multiple tables in the same region.
    (when (derived-mode-p 'org-mode)
      (let ((end-marker (copy-marker end)))
        (unwind-protect
            (save-excursion
              (goto-char start)
              (while (re-search-forward
                      "^#\\+name: hermes-tool-[^ \t\r\n]+[ \t]*$"
                      end-marker t)
                (forward-line 1)
                (when (looking-at "^[ \t]*|")
                  (ignore-errors (org-table-align)))))
          (set-marker end-marker nil))))
    ;; Render inline images for any `[[file:...]]' links in the region.
    ;; `(NUMBER)' tells Org: honor `#+attr_org: :width …' when present,
    ;; else cap at the window width so oversized images don't blow the
    ;; buffer geometry.  A bare number would override the attr line.
    (when (and (derived-mode-p 'org-mode)
               (fboundp 'org-display-inline-images)
               (display-graphic-p))
      (let ((org-image-actual-width (list (window-width nil t))))
        (ignore-errors
          (org-display-inline-images nil t start end))))))

;;;; Committed messages

(defun hermes--message-text-for-display (msg)
  "Extract concatenated text from MSG's text segments for headline preview."
  (let ((segs (hermes-message-segments msg))
        parts)
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let ((s (aref segs i)))
          (when (eq 'text (hermes-segment-type s))
            (push (or (hermes-segment-content s) "") parts)))))
    (apply #'concat (nreverse parts))))

(defun hermes--usage-key-to-property (key)
  "Return heading property name for usage KEY.
KEY is a string or keyword.  Normalizes known counter aliases to a
canonical property; unknown keys passthrough with `HERMES_USAGE_'
prefix.  If two aliases of the same counter arrive in one payload,
the second `org-entry-put' overwrites — last write wins."
  (let ((s (cond ((keywordp key) (substring (symbol-name key) 1))
                 ((stringp key) key)
                 (t (format "%s" key)))))
    (pcase s
      ((or "tokens_sent" "prompt_tokens")
       "HERMES_USAGE_TOKENS_SENT")
      ((or "tokens_received" "completion_tokens")
       "HERMES_USAGE_TOKENS_RECEIVED")
      ("cost" "HERMES_USAGE_COST")
      ("cache_hit_tokens" "HERMES_USAGE_CACHE_HIT_TOKENS")
      (_ (format "HERMES_USAGE_%s" (upcase s))))))

(defun hermes--write-usage-properties (usage)
  "Write usage counters as heading properties at point.
USAGE is a plist, hash-table, or nil.  Normalizes known keys,
passthroughs unknown keys with `HERMES_USAGE_' prefix.  Skips nil
and zero numerics; framing keys (`:model', `:cost_status',
`:context_max') are dropped (model lives in `HERMES_MODEL').
Returns t if any property was written."
  (when usage
    (let ((plist (cond ((hash-table-p usage)
                        (hermes--hash-to-plist usage))
                       ((listp usage) usage)
                       (t nil)))
          (written nil))
      (while plist
        (let* ((k (car plist))
               (v (cadr plist))
               (s (cond ((keywordp k) (substring (symbol-name k) 1))
                        ((stringp k) k)
                        (t (format "%s" k))))
               (drop (member s '("model" "cost_status" "context_max")))
               (prop-name (and (not drop)
                               (hermes--usage-key-to-property k)))
               (prop-val (cond ((null v) nil)
                               ((and (numberp v) (zerop v)) nil)
                               ((numberp v) (number-to-string v))
                               (t (format "%s" v)))))
          (when (and prop-name prop-val)
            (org-entry-put (point) prop-name prop-val)
            (setq written t)))
        (setq plist (cddr plist)))
      written)))

(defun hermes--insert-committed-turn (msg)
  "Insert a committed MSG into the buffer at point-max.
For user/system: calls `hermes--insert-turn-headline'.
For assistant: empty-response edge case — creates a minimal `** assistant'
subtree and writes usage as heading properties."
  (pcase (hermes-message-kind msg)
    ('user      (hermes--insert-turn-headline msg 'hermes-user-face))
    ('system    (hermes--insert-turn-headline msg 'hermes-system-face))
    ('assistant
     (let* ((info    (hermes-state-session-info (hermes--current-state)))
            (model   (and (hash-table-p info) (gethash "model" info)))
            (sid     (or (hermes-state-session-id (hermes--current-state)) ""))
            (text    (hermes--message-text-for-display msg))
            (excerpt (concat "A: " (hermes--heading-excerpt text)))
            (tags    (hermes--turn-tags 'assistant model))
            (heading (format "%s %s" (hermes--stars 1) excerpt)))
       (goto-char (hermes--session-insert-point))
       (unless (bolp) (insert "\n"))
       (let ((turn-start (point))
             (hb (point)))
         (if (string-empty-p tags)
             (insert heading "\n")
           (insert (format "%s %s %s\n"
                           heading (hermes--tag-spacer heading tags) tags)))
         (hermes--face-overlay hb (1- (point)) 'hermes-assistant-face)
         (hermes--insert-properties
          `(("HERMES_KIND"      . "ASSISTANT")
            ("HERMES_SESSION"   . ,sid)
            ("HERMES_MODEL"     . ,model)
            ("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
         (when (derived-mode-p 'org-mode)
           (org-element-cache-reset)
           (save-excursion
             (goto-char hb)
             (ignore-errors (org-id-get-create))))
         (save-excursion
           (goto-char hb)
           (hermes--write-usage-properties (hermes-message-usage msg)))
         (goto-char (hermes--session-insert-point))
         (let ((segs (hermes-message-segments msg)))
           (when (vectorp segs)
             (dotimes (i (length segs))
               (let ((block (hermes--segment-block (aref segs i))))
                 (unless (string-empty-p block)
                   (insert block))))))
         (let ((sas (hermes-message-subagents msg)))
           (when (vectorp sas)
             (let ((sa-str (hermes--format-subagents-block sas)))
               (unless (string-empty-p sa-str)
                 (insert sa-str)))))
         (hermes--fold-reasoning-in-region turn-start (point)))))))

(defun hermes--insert-turn-headline (msg face)
  "Insert a turn heading for user or system MSG.
The heading is one level below the session container, so user, system,
and assistant turns are all siblings."
  (let* ((kind     (hermes-message-kind msg))
         (text     (hermes--message-text-for-display msg))
         (prefix   (pcase kind
                     ('user      "U: ")
                     ('system    "S: ")
                     ('assistant "A: ")
                     (_          "")))
         (excerpt  (concat prefix (hermes--heading-excerpt text)))
         (heading  (format "%s %s" (hermes--stars 1) excerpt))
         (tags     (hermes--turn-tags kind))
         (sid      (or (hermes-state-session-id (hermes--current-state)) ""))
         (info     (hermes-state-session-info (hermes--current-state)))
         (model    (and (hash-table-p info) (gethash "model" info))))
    (goto-char (hermes--session-insert-point))
    (unless (bolp) (insert "\n"))
    (let ((hb (point)))
      (if (string-empty-p tags)
          (insert heading "\n")
        (insert (format "%s %s %s\n" heading (hermes--tag-spacer heading tags) tags)))
      (hermes--face-overlay hb (1- (point)) face)
      (hermes--insert-properties
       `(("HERMES_KIND"      . ,(upcase (symbol-name kind)))
         ("HERMES_SESSION"   . ,sid)
         ("HERMES_MODEL"     . ,model)
         ("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
      (when (derived-mode-p 'org-mode)
        ;; Local cache reset before `org-id-get-create' parses: the cache
        ;; is stale here because `with-silent-modifications' suppressed
        ;; `after-change-functions' across the streamed turn.
        (org-element-cache-reset)
        (goto-char hb)
        (ignore-errors (org-id-get-create))
        (save-excursion
          (goto-char hb)
          (hermes--write-usage-properties (hermes-message-usage msg)))
        (goto-char (hermes--session-insert-point)))
      ;; Insert image segments first (matching the reducer's
      ;; [image…, text] ordering for user turns), then the joined text.
      (let ((segs (hermes-message-segments msg)))
        (when (vectorp segs)
          (dotimes (i (length segs))
            (let ((seg (aref segs i)))
              (when (eq 'image (hermes-segment-type seg))
                (let ((block (hermes--segment-block seg)))
                  (unless (string-empty-p block)
                    (insert block))))))))
      (when (and text (not (string-empty-p text)))
        (insert text)
        (unless (eq (char-before) ?\n) (insert "\n"))))))

;; NB: outline-fold repair for the just-inserted region now lives in
;; `hermes--refresh-region', invoked from `hermes--render' after
;; `with-silent-modifications' has exited.

(defun hermes--tag-spacer (heading tags)
  "Return spaces so HEADING + space + spacer + space + TAGS aligns near col 75.
TAGS is the full tag string including surrounding colons, e.g.
`:hermes:deepseek-v4:'.  Falls back to a single space when the heading
plus tags already overflow the target width.  Returns the empty string
when TAGS is empty — turn headings now express their kind via a U:/S:/A:
prefix in HEADING and don't carry trailing tags."
  (if (or (null tags) (string-empty-p tags))
      ""
    (let* ((target 75)
           (used   (+ (string-width heading) 2 (string-width tags)))
           (pad    (- target used)))
      (if (> pad 0) (make-string pad ?\s) " "))))

(defun hermes--model-short-name (slug)
  "Extract a short model name from SLUG.
For `deepseek/deepseek-v4-flash:free' returns `deepseek-v4-flash'.
Strips provider prefix (anything up to `/') and version suffix
(anything from `:' onward)."
  (when (and slug (stringp slug) (not (string-empty-p slug)))
    (let* ((sans-provider (if (string-match "/" slug)
                              (substring slug (1+ (match-beginning 0)))
                            slug))
           (sans-suffix (if (string-match ":" sans-provider)
                            (substring sans-provider 0 (match-beginning 0))
                          sans-provider)))
      sans-suffix)))

(defun hermes--heading-excerpt (text)
  "Return a heading-friendly excerpt from TEXT.
Skips leading blank lines, takes the first non-empty line, collapses
internal whitespace, and truncates to 60 chars with an ellipsis.
Returns `(empty)' when TEXT has no visible content."
  (let* ((trimmed (string-trim (or text "")))
         (first   (catch 'found
                    (dolist (line (split-string trimmed "\n"))
                      (let ((s (string-trim line)))
                        (unless (string-empty-p s)
                          (throw 'found s))))
                    "")))
    (cond
     ((string-empty-p first) "(empty)")
     ((> (length first) 60) (concat (substring first 0 57) "..."))
     (t first))))

(defun hermes--turn-tags (_kind &optional _model)
  "Return the tag string for a turn.
Previously returned `:user:', `:system:', or `:hermes:'.  Now always
returns the empty string — turn kinds are expressed via the `U:' /
`S:' / `A:' prefix in the heading text instead."
  "")

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

(declare-function hermes-bg-mode "hermes-bg")
(declare-function hermes-md-to-org "hermes-md" (text))

(defun hermes--render-bg-task (sid task)
  "Create and populate a background task buffer for TASK in session SID.
Dispatches a synthetic `:bg-rendered' message (deferred via
`run-at-time' to break re-entrancy with the calling render hook) so
the reducer records the buffer name in state.  SID is captured in the
deferred closure because `hermes-dispatch' reads
`hermes--current-session-id' dynamically — the dynamic binding is
gone by the time the timer fires."
  (require 'hermes-bg)
  (require 'hermes-md)
  (let* ((tid    (hermes-bg-task-task-id task))
         (prompt (or (hermes-bg-task-prompt task) ""))
         (result (hermes-bg-task-result task))
         (err    (hermes-bg-task-error task))
         (buf-name (format "*hermes-bg:%s:%s*" (or sid "?") tid))
         (buf (get-buffer-create buf-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'hermes-bg-mode)
        (hermes-bg-mode))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "* Background: %s\n\n" prompt))
        (insert ":PROPERTIES:\n")
        (insert (format ":HERMES_TASK_ID: %s\n" tid))
        (insert (format ":HERMES_STATUS: %s\n" (if err "error" "complete")))
        (insert ":END:\n\n")
        (if err
            (insert (format "#+begin_example Error\n%s\n#+end_example\n" err))
          (insert (hermes-md-to-org (or result "")))
          (unless (eq (char-before) ?\n) (insert "\n")))
        (goto-char (point-min))))
    (let ((sid-capture sid)
          (tid-capture tid)
          (bname buf-name))
      (run-at-time 0 nil
                   (lambda ()
                     (hermes-dispatch
                      (list :bg-rendered
                            :task-id tid-capture
                            :buffer-name bname)
                      sid-capture))))))

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
folded `*** Reasoning' subtree."
  (if (or (null content) (string-empty-p content))
      ""
    (let ((body (hermes-md-to-org content)))
      (if (string-empty-p body)
          ""
        (concat (hermes--stars 2) " Response\n"
                ":PROPERTIES:\n:HERMES_KIND: RESPONSE\n:END:\n"
                body
                (if (string-suffix-p "\n" body) "" "\n"))))))

(defun hermes--format-cot-block (label content fold-id)
  "Return an Org level-3 heading for chain-of-thought CONTENT.
LABEL is the visible heading text (\"Reasoning\").  FOLD-ID is the segment
id used to remember user expansion across re-renders.  Headings are tagged
with the `hermes-reasoning-fold' text property so the renderer can collapse
them on insertion."
  (if (or (null content) (string-empty-p content))
      ""
    (let* ((heading (format "%s %s" (hermes--stars 2) label))
           (heading-line
            (concat (propertize heading
                                'hermes-reasoning-fold t
                                'hermes-fold-id fold-id)
                    "\n"))
           (props ":PROPERTIES:\n:HERMES_KIND: REASONING\n:END:\n")
           (body content))
      (if (or (null body) (string-empty-p body))
          ""
        (concat heading-line props body
                (if (string-suffix-p "\n" body) "" "\n"))))))

(defun hermes--strip-trailing-newlines (s)
  "Return S with all trailing newlines removed."
  (if (string-match "\n+\\'" s)
      (substring s 0 (match-beginning 0))
    s))

(defun hermes--join-blocks (parts)
  "Join PARTS with exactly one newline between each, terminated by one newline.
Empty parts are skipped.  Trailing newlines on each part are normalized
so callers can mix part strings that do and do not already end in \\n
without producing blank-line gaps."
  (let ((trimmed (delq nil
                       (mapcar (lambda (p)
                                 (let ((s (hermes--strip-trailing-newlines (or p ""))))
                                   (and (> (length s) 0) s)))
                               parts))))
    (if (null trimmed)
        ""
      (concat (mapconcat #'identity trimmed "\n") "\n"))))

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
    (push (format "%s %s (%s)\n:PROPERTIES:\n:HERMES_KIND: SUBAGENT\n:ID:       %s\n:END:\n"
                  (hermes--stars 3) goal status-label id) parts)
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
    (hermes--join-blocks (nreverse parts))))

(defun hermes--format-subagents-block (subagents)
  "Return an Org block string for all SUBAGENTS, or empty string if none."
  (if (not (and (vectorp subagents) (> (length subagents) 0)))
      ""
    (let (parts)
      (dotimes (i (length subagents))
        (let ((formatted (hermes--format-subagent (aref subagents i))))
          (when (> (length formatted) 0)
            (push formatted parts))))
      (hermes--join-blocks (nreverse parts)))))

(defun hermes--update-subagent-views (subagents)
  "Replace the subagent block region in the stream buffer."
  (let ((formatted (hermes--format-subagents-block subagents)))
    (cond ((and (string-empty-p formatted)
                (markerp hermes--stream-subagents-marker)
                (marker-position hermes--stream-subagents-marker))
           ;; Delete from the start of the subagent block (segments-end)
           ;; rather than from `subagents-marker', which has rear-advanced
           ;; past prior subagent insertions.
           (let ((boundary
                  (if (and (markerp hermes--stream-segments-end)
                           (marker-position hermes--stream-segments-end))
                      (marker-position hermes--stream-segments-end)
                    (marker-position hermes--stream-subagents-marker))))
             (delete-region boundary (point-max)))
           (set-marker hermes--stream-subagents-marker nil))
          ((not (string-empty-p formatted))
           ;; Prefer `stream-segments-end' as the boundary: it is the
           ;; structural start of the subagent block.  The dedicated
           ;; `subagents-marker' has insertion-type t and rear-advances
           ;; past prior subagent text, so it no longer marks the start
           ;; once anything has been inserted.
           (let ((boundary
                  (cond
                   ((and (markerp hermes--stream-segments-end)
                         (marker-position hermes--stream-segments-end))
                    (marker-position hermes--stream-segments-end))
                   ((and (markerp hermes--stream-subagents-marker)
                         (marker-position hermes--stream-subagents-marker))
                    (marker-position hermes--stream-subagents-marker))
                   (t (point-max)))))
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
  "Return an alist of org PROPERTY entries for TOOL.
Includes HERMES_KIND, TOOL_ID, TOOL_NAME, TOOL_STATUS, TOOL_DURATION,
and TOOL_SUMMARY (gateway-provided human summary).
Duration is stored at full float precision; the human-readable (0.1s)
in the heading text is rounded for display only."
  (let ((dur     (hermes-tool-duration tool))
        (tid     (hermes-tool-id tool))
        (name    (hermes-tool-name tool))
        (status  (hermes-tool-status tool))
        (summary (hermes-tool-summary tool))
        (acc nil))
    (push (cons "HERMES_KIND" "TOOL") acc)
    (when tid     (push (cons "TOOL_ID"       (format "%s" tid))    acc))
    (when name    (push (cons "TOOL_NAME"     (format "%s" name))   acc))
    (when status  (push (cons "TOOL_STATUS"   (format "%s" status)) acc))
    (when dur     (push (cons "TOOL_DURATION" (format "%s" dur))    acc))
    (when summary (push (cons "TOOL_SUMMARY"  summary)              acc))
    (nreverse acc)))

(defun hermes--format-property-drawer (props)
  "Render PROPS (an alist) as an org PROPERTIES drawer, or empty string."
  (if (null props) ""
    (concat ":PROPERTIES:\n"
            (mapconcat (lambda (kv)
                         (format ":%s: %s" (car kv) (cdr kv)))
                       props "\n")
            "\n:END:\n")))

(defun hermes--tool-heading-string (tool keyword formatter-summary)
  "Build a compact heading string for TOOL with status KEYWORD.
FORMATTER-SUMMARY is the per-tool formatter's `:summary' (e.g. `$ ls').
Appends the gateway-provided summary, duration, and indicators for
foldable content (diff, todos, error)."
  (let* ((gw-summary (hermes-tool-summary tool))
         (duration   (hermes-tool-duration tool))
         (has-diff   (hermes-tool-inline-diff tool))
         (todos      (hermes-tool-todos tool))
         (err        (hermes-tool-error tool))
         (indicators nil)
         (head (concat (hermes--stars 2) " " keyword " " formatter-summary)))
    (when (and gw-summary (not (string-empty-p gw-summary)))
      (setq head (concat head " — " gw-summary)))
    (when duration
      (setq head (concat head (format " (%.1fs)" duration))))
    (when has-diff (push "[diff]" indicators))
    (when (and todos (> (length todos) 0))
      (push (format "[%d todo]" (length todos)) indicators))
    (when err (push "[error]" indicators))
    (when indicators
      (setq head (concat head " "
                         (mapconcat #'identity (nreverse indicators) " "))))
    head))

(defun hermes--format-tool (tool)
  "Return an Org block string for a single TOOL.
Heading uses an org TODO keyword for status, plus gateway summary,
duration, and indicators; body is produced by a per-tool formatter
from `hermes-tool-formatters' and only inserted when non-empty."
  (let* ((name      (or (hermes-tool-name tool) "tool"))
         (status    (hermes-tool-status tool))
         (keyword   (hermes--tool-status-keyword status))
         (formatter (hermes-tool--lookup name))
         (parts     (funcall formatter tool))
         (fmt-sum   (or (plist-get parts :summary) name))
         (body      (or (plist-get parts :body) ""))
         (fold-p    (and (eq status 'complete) (plist-get parts :fold)))
         (props     (hermes--tool-properties tool))
         (heading   (hermes--tool-heading-string tool keyword fmt-sum))
         ;; Tag the heading line with a text property so the renderer can
         ;; fold it after insertion without re-parsing org structure.
         (heading-line
          (if fold-p
              (concat
               (propertize heading 'hermes-fold t
                           'hermes-fold-id (hermes-tool-id tool))
               "\n")
            (concat heading "\n")))
         (drawer    (hermes--format-property-drawer props))
         (has-body  (and body (not (string-empty-p body))))
         (out (concat heading-line
                      drawer
                      (if has-body body ""))))
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
      ('reasoning (hermes--format-cot-block "Reasoning" content sid))
      ('tool (hermes--format-tool content))
      ('system (format "#+begin_comment\n%s\n#+end_comment\n" content))
      ('image (hermes--format-image-segment content))
      (_ ""))))

(defun hermes--image-display-dims (width height)
  "Return (W . H) display dimensions for an image of natural size WIDTH x HEIGHT.
Longest side is capped at `hermes-image-display-max-dim' (aspect
ratio preserved).  Returns natural dims when already within the
cap.  Returns nil when WIDTH or HEIGHT is missing/invalid."
  (when (and (integerp width) (integerp height) (> width 0) (> height 0))
    (let ((max-dim hermes-image-display-max-dim))
      (cond
       ((null max-dim) (cons width height))
       (t (let ((longest (max width height)))
            (if (<= longest max-dim)
                (cons width height)
              (let ((scale (/ (float max-dim) longest)))
                (cons (round (* width scale))
                      (round (* height scale)))))))))))

(defun hermes--format-attr-line (keyword plist)
  "Return `#+attr_KEYWORD: :k1 v1 :k2 v2\\n' for the non-nil entries of PLIST.
Strings are printed with `prin1' (so they keep their quotes); numbers
and symbols are formatted with %S.  Returns the empty string when
PLIST has no non-nil values."
  (let (parts)
    (while plist
      (let ((k (car plist)) (v (cadr plist)))
        (when v
          (push (format "%s %s" k
                        (cond ((stringp v) (prin1-to-string v))
                              (t (format "%S" v))))
                parts)))
      (setq plist (cddr plist)))
    (if (null parts) ""
      (format "#+attr_%s: %s\n" keyword
              (mapconcat #'identity (nreverse parts) " ")))))

(defun hermes--format-image-segment (content)
  "Return an Org `file:' link (or placeholder) for image segment CONTENT.
Precedes the link with two attr lines:
- #+attr_org:    :width / :height  — *display* dimensions (scaled down
  so longest side ≤ `hermes-image-display-max-dim'; Org honors these).
- #+attr_hermes: :name / :width / :height / :token-estimate — canonical
  metadata (real pixel dimensions; Hermes-private namespace).

When real dimensions are unknown, attr_org is omitted (the window-width
fallback in `org-image-actual-width' applies).  attr_hermes is emitted
whenever any of its fields are non-nil.  The path is used verbatim — no
expansion or canonicalization."
  (let* ((path    (and (listp content) (plist-get content :path)))
         (name    (and (listp content) (plist-get content :name)))
         (width   (and (listp content) (plist-get content :width)))
         (height  (and (listp content) (plist-get content :height)))
         (tokens  (and (listp content) (plist-get content :token-estimate)))
         (display (hermes--image-display-dims width height))
         (label   (or (and path (file-name-nondirectory path)) name "image")))
    (cond
     ((and path (file-readable-p path))
      (concat (if display
                  (hermes--format-attr-line
                   "org" (list :width (car display) :height (cdr display)))
                "")
              (hermes--format-attr-line "hermes"
                                        (list :name name
                                              :width width :height height
                                              :token-estimate tokens))
              (format "[[file:%s]]\n" path)))
     (t (format "[image: %s (not found)]\n" label)))))

(defun hermes--segment-block (seg)
  "Return the buffer bytes for SEG: formatted text + trailing blank line.
Each block ends with exactly two newlines so adjacent blocks are
separated by one blank line in the rendered Org buffer.  Empty-format
segments (e.g. `thinking') return the empty string and contribute
zero bytes."
  (let ((s (hermes--format-segment seg)))
    (cond ((string-empty-p s) "")
          ((string-suffix-p "\n\n" s) s)
          ((string-suffix-p "\n" s) (concat s "\n"))
          (t (concat s "\n\n")))))

(defun hermes--snapshot-total-length (snapshot)
  "Sum the :length fields of SNAPSHOT (a vector of plists)."
  (let ((total 0))
    (dotimes (i (length snapshot))
      (setq total (+ total (plist-get (aref snapshot i) :length))))
    total))

(defun hermes--render-stream-segments (segments)
  "Render SEGMENTS into the bench, mutating only what changed.
Diffs against `hermes--stream-segments-snapshot' (a parallel vector of
\(:id :type :length) plists).  Per-segment positions are recomputed on
the fly from `hermes--stream-segments-start' plus cumulative lengths,
which makes per-segment markers unnecessary — buffer text below the
bench is frozen, so the boundaries are deterministic.

Three branches per segment slot:
  1. Same id+type and content unchanged → skip (O(1)).
  2. Same id+type but content differs → in-place replace (O(new size)).
  3. id/type mismatch → fall back to delete + reinsert from this slot on.

For the common `message.delta' case (one growing text segment), only
branch 2 fires for one segment, and the per-paint cost drops from
O(total bench text) to O(delta size)."
  (unless (and (markerp hermes--stream-segments-start)
               (markerp hermes--stream-segments-end))
    (setq hermes--stream-segments-start (point-marker)
          hermes--stream-segments-end (point-marker))
    (set-marker-insertion-type hermes--stream-segments-start nil)
    (set-marker-insertion-type hermes--stream-segments-end t))
  (let* ((start-pos (marker-position hermes--stream-segments-start))
         (snapshot (or hermes--stream-segments-snapshot []))
         (n-old (length snapshot))
         (n-new (length segments))
         (pos start-pos)
         (i 0)
         (diverged nil))
    ;; 1. Walk the common prefix, replacing in place where content differs.
    (while (and (not diverged) (< i n-old) (< i n-new))
      (let* ((old (aref snapshot i))
             (seg (aref segments i))
             (old-id   (plist-get old :id))
             (old-type (plist-get old :type))
             (old-len  (plist-get old :length))
             (new-id   (hermes-segment-id seg))
             (new-type (hermes-segment-type seg)))
        (if (not (and (equal old-id new-id) (eq old-type new-type)))
            (setq diverged t)
          (let* ((new-text (hermes--segment-block seg))
                 (new-len (length new-text)))
            ;; TEA: view reads its own output.  Storing `:text' in the
            ;; snapshot entries would let us compare without touching
            ;; the buffer.
            (unless (and (= old-len new-len)
                         (string= new-text
                                  (buffer-substring-no-properties
                                   pos (+ pos old-len))))
              (save-excursion
                (goto-char pos)
                (delete-region pos (+ pos old-len))
                (insert new-text))
              (aset snapshot i (list :id new-id :type new-type
                                     :length new-len)))
            (setq pos (+ pos new-len)
                  i (1+ i))))))
    (cond
     (diverged
      ;; Rebuild from segments[i..] — delete tail, reinsert.
      (delete-region pos (marker-position hermes--stream-segments-end))
      (let ((rebuilt (substring snapshot 0 i)))
        (save-excursion
          (goto-char pos)
          (while (< i n-new)
            (let* ((seg (aref segments i))
                   (text (hermes--segment-block seg)))
              (insert text)
              (setq rebuilt
                    (vconcat rebuilt
                             (vector (list :id (hermes-segment-id seg)
                                           :type (hermes-segment-type seg)
                                           :length (length text))))))
            (setq i (1+ i))))
        (setq snapshot rebuilt)))
     ((< i n-old)
      ;; Old vector longer — truncate trailing segments.
      (delete-region pos (marker-position hermes--stream-segments-end))
      (setq snapshot (substring snapshot 0 i)))
     ((< i n-new)
      ;; New vector longer — append remainder.
      (save-excursion
        (goto-char pos)
        (let ((extra (make-vector (- n-new i) nil))
              (k 0))
          (while (< i n-new)
            (let* ((seg (aref segments i))
                   (text (hermes--segment-block seg)))
              (insert text)
              (aset extra k (list :id (hermes-segment-id seg)
                                  :type (hermes-segment-type seg)
                                  :length (length text))))
            (setq i (1+ i) k (1+ k)))
          (setq snapshot (vconcat snapshot extra))))))
    (setq hermes--stream-segments-snapshot snapshot)
    ;; Re-anchor the end marker.  insertion-type t keeps it aligned with
    ;; the tail through inserts, but a pure-shrink pass may have left it
    ;; ahead of where the snapshot now ends.
    (set-marker hermes--stream-segments-end
                (+ start-pos (hermes--snapshot-total-length snapshot)))
    (hermes--apply-stream-folds start-pos
                                (marker-position hermes--stream-segments-end))
    (hermes--bench-sync)))

(defvar-local hermes--unfolded-ids nil
  "Set (list) of fold-ids the user has manually expanded; never re-folded.
Covers tool blocks and chain-of-thought (thinking/reasoning) blocks.")

(defun hermes--remember-cycle (state)
  "Org cycle hook: record the fold-id when the user expands a folded block.
STATE is one of `folded', `children', `subtree', `all', etc."
  (when (memq state '(children subtree all))
    (let ((fid (save-excursion
                 (beginning-of-line)
                 (get-text-property (point) 'hermes-fold-id))))
      (when (and fid (not (member fid hermes--unfolded-ids)))
        (push fid hermes--unfolded-ids)))))

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

(defun hermes--apply-stream-folds (start end)
  "Hide tool subtrees marked with `hermes-fold' between START and END.
Reasoning blocks are intentionally left visible during streaming so the
user can watch the thought process build in real-time; they get folded
on commit by `hermes--fold-reasoning-in-region'.
Skips ids in `hermes--unfolded-ids'."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char start)
      (let (pos)
        (while (and (< (point) end)
                    (setq pos (text-property-any (point) end 'hermes-fold t)))
          (goto-char pos)
          (let ((fid (get-text-property pos 'hermes-fold-id)))
            (unless (and fid (member fid hermes--unfolded-ids))
              (ignore-errors
                (if (fboundp 'org-fold-hide-subtree)
                    (org-fold-hide-subtree)
                  (outline-hide-subtree)))))
          ;; Move past this heading line so we don't loop forever.
          (forward-line 1))))))

(defun hermes--fold-reasoning-in-region (start end)
  "Fold all reasoning subtrees marked with `hermes-reasoning-fold' between
START and END.  Called from `hermes--stream-commit' to collapse reasoning
blocks after the assistant turn is sealed.
Skips ids in `hermes--unfolded-ids'."
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char start)
      (let (pos)
        (while (and (< (point) end)
                    (setq pos (text-property-any
                               (point) end 'hermes-reasoning-fold t)))
          (goto-char pos)
          (let ((fid (get-text-property pos 'hermes-fold-id)))
            (unless (and fid (member fid hermes--unfolded-ids))
              (ignore-errors
                (if (fboundp 'org-fold-hide-subtree)
                    (org-fold-hide-subtree)
                  (outline-hide-subtree)))))
          (forward-line 1))))))

;;;; Stream lifecycle

(defun hermes--stream-begin ()
  "Insert a `** assistant' headline with a property drawer and prepare markers.
Also opens a bench overlay tinting the live region."
  (goto-char (hermes--session-insert-point))
  (unless (bolp) (insert "\n"))
  ;; Bench-start anchors here; bench-end advances with insertion so it
  ;; tracks the growing live region.
  (setq hermes--bench-start (copy-marker (point) nil)
        hermes--bench-end   (copy-marker (point) t))
  (setq hermes--stream-headline-marker (point-marker))
  (set-marker-insertion-type hermes--stream-headline-marker nil)
  (let* ((info    (let ((st (hermes--current-state)))
                    (and st (hermes-state-session-info st))))
         (model   (and (hash-table-p info) (gethash "model" info)))
         (short   (or (hermes--model-short-name model) ""))
         (prefix  (if (string-empty-p short) "A:" (concat "A: " short)))
         (heading (format "%s %s" (hermes--stars 1) prefix))
         (hb      (point)))
    (insert heading "\n")
    (hermes--face-overlay hb (1- (point)) 'hermes-assistant-face))
  (hermes--insert-properties
   `(("HERMES_KIND"      . "ASSISTANT")
     ("HERMES_TIMESTAMP" . ,(hermes--now-iso))))
  (when (derived-mode-p 'org-mode)
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  (setq hermes--stream-segments-start (point-marker)
        hermes--stream-segments-end   (point-marker))
  (set-marker-insertion-type hermes--stream-segments-start nil)
  (set-marker-insertion-type hermes--stream-segments-end   t)
  (setq hermes--stream-segments-snapshot nil)
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

(defun hermes--finalize-assistant-heading (msg)
  "Rewrite the in-flight assistant heading to show a response excerpt.
MSG is the committed `hermes-message'.  Replaces the line at
`hermes--stream-headline-marker' with `** <excerpt> :hermes:<model>:'."
  (when (and (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (let* ((text     (hermes--message-text-for-display msg))
           (excerpt  (concat "A: " (hermes--heading-excerpt text)))
           (info     (let ((st (hermes--current-state)))
                       (and st (hermes-state-session-info st))))
           (model    (and (hash-table-p info) (gethash "model" info)))
           (tags     (hermes--turn-tags 'assistant model))
           (heading  (format "%s %s" (hermes--stars 1) excerpt))
           (spacer   (hermes--tag-spacer heading tags)))
      (save-excursion
        (goto-char (marker-position hermes--stream-headline-marker))
        (let ((line-beg (line-beginning-position))
              (line-end (line-end-position)))
          ;; Drop any existing headline face overlay covering the old line
          ;; so the new line gets a fresh, correctly-sized one.
          (dolist (ov (overlays-in line-beg (1+ line-end)))
            (when (overlay-get ov 'hermes-headline)
              (delete-overlay ov)))
          (delete-region line-beg line-end)
          (let ((hb (point)))
            (if (string-empty-p tags)
                (insert heading)
              (insert (format "%s %s %s" heading spacer tags)))
            (hermes--face-overlay hb (point) 'hermes-assistant-face)))))))

(defun hermes--stream-commit (&optional old-stream)
  "Stream finished: stamp Org :ID:s on the trail, drop markers and bench.
If OLD-STREAM is non-nil, write `HERMES_USAGE_*' properties on the
`** assistant' heading describing the just-completed message.
Returns a cons (START . END) of the committed region for post-commit
refresh by the caller, or nil if no bench was active."
  ;; Defensive: ensure no throttled paint can fire after the bench is gone.
  (hermes--stream-flush-cancel)
  (when (and (derived-mode-p 'org-mode)
             (markerp hermes--stream-headline-marker)
             (marker-position hermes--stream-headline-marker))
    (save-excursion
      (goto-char hermes--stream-headline-marker)
      (ignore-errors (org-id-get-create))))
  ;; Write usage properties on the assistant heading before tearing
  ;; down the markers — we still need bench-end to know where.
  (when (and old-stream
             (hermes-stream-p old-stream)
             (markerp hermes--bench-end)
             (marker-position hermes--bench-end))
    (let* ((per-turn-usage
            ;; Per-turn token deltas live on the assistant message the
            ;; reducer just pushed to pending-turns (message.complete).
            ;; Session-cumulative `hermes-state-usage' would leak the
            ;; running total into every drawer; avoid that.
            (let ((tt (let ((st (hermes--current-state)))
                        (and st (hermes-state-pending-turns st)))))
              (when (and (vectorp tt) (> (length tt) 0))
                (let ((last (aref tt (1- (length tt)))))
                  (when (eq 'assistant (hermes-message-kind last))
                    (hermes-message-usage last))))))
           (msg (hermes--message-from-stream old-stream per-turn-usage)))
      (save-excursion
        (goto-char (marker-position hermes--bench-start))
        (hermes--write-usage-properties (hermes-message-usage msg)))
      ;; Rewrite the assistant heading from `** <model>' placeholder
      ;; into `** <response excerpt> :hermes:<model>:'.
      (hermes--finalize-assistant-heading msg)))
  ;; Collapse reasoning subtrees now that the turn is sealed.  During
  ;; streaming they were left visible so the user could watch the
  ;; thought process build; once committed the buffer should show only
  ;; the assistant response with reasoning hidden behind `*** Reasoning'.
  (when (and (markerp hermes--bench-start)
             (marker-position hermes--bench-start)
             (markerp hermes--bench-end)
             (marker-position hermes--bench-end))
    (hermes--fold-reasoning-in-region
     (marker-position hermes--bench-start)
     (marker-position hermes--bench-end)))
  ;; Tear down the bench: tint disappears, markers freed, the region
  ;; below is now frozen.  Any folds the user opens in this region from
  ;; here on persist trivially because nothing re-applies fold passes
  ;; outside a bench.
  (when (overlayp hermes--bench-overlay)
    (delete-overlay hermes--bench-overlay))
  (setq hermes--bench-overlay nil)
  ;; Snapshot the committed region before clearing markers, so the
  ;; caller can run `hermes--refresh-region' on it (after the silent
  ;; block exits) to restore `line-prefix' on the rewritten heading and
      ;; collapse the just-finalized assistant subtree.
  (let ((committed-start (and (markerp hermes--bench-start)
                              (marker-position hermes--bench-start)))
        (committed-end   (and (markerp hermes--bench-end)
                              (marker-position hermes--bench-end))))
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
          hermes--stream-segments-snapshot nil
          hermes--unfolded-ids nil)
    (when (and committed-start committed-end)
      (cons committed-start committed-end))))

(defun hermes--stream-flush-cancel ()
  "Cancel any pending stream-flush timer and clear the accumulator.
Safe to call from any context — does not paint."
  (when (timerp hermes--stream-render-timer)
    (cancel-timer hermes--stream-render-timer))
  (setq hermes--stream-render-timer nil
        hermes--stream-render-pending nil))

(defun hermes--adaptive-throttle-interval ()
  "Cooldown interval in seconds, scaled by the bench size.
Returns `(max hermes-render-stream-throttle stepped)' where `stepped'
follows the table in `hermes-render-stream-throttle's docstring.
\"Bench size\" is the total `:length' across
`hermes--stream-segments-snapshot' — i.e. the byte count actually
painted into the buffer.  Falls back to 0 chars (smallest step) when
the snapshot is nil, so the first paint after `stream-begin' uses the
floor."
  (let ((len (if hermes--stream-segments-snapshot
                 (hermes--snapshot-total-length
                  hermes--stream-segments-snapshot)
               0)))
    (max hermes-render-stream-throttle
         (cond ((< len 1000)  0.04)
               ((< len 5000)  0.20)
               ((< len 10000) 1.00)
               (t             2.00)))))

(defun hermes--stream-flush-reschedule ()
  "Arm the cooldown timer using the adaptive interval."
  (when (timerp hermes--stream-render-timer)
    (cancel-timer hermes--stream-render-timer))
  (setq hermes--stream-render-timer
        (run-with-timer (hermes--adaptive-throttle-interval) nil
                        #'hermes--stream-flush (current-buffer))))

(defun hermes--stream-flush (buf)
  "Timer callback: paint `hermes--stream-render-pending' into BUF.
If no snapshot is pending, simply clears the timer slot.  When a paint
happens, re-arms the cooldown so further deltas continue to throttle."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (setq hermes--stream-render-timer nil)
      (let* ((ns hermes--stream-render-pending)
             (target-visible (hermes--buffer-visible-p (current-buffer))))
        (setq hermes--stream-render-pending nil)
        (when (and ns
                   target-visible
                   (hermes--current-state)
                   (eq ns (hermes-state-stream (hermes--current-state)))
                   (markerp hermes--bench-start)
                   (marker-position hermes--bench-start))
          (with-silent-modifications
            (save-excursion
              (hermes--stream-update nil ns)))
          (when (derived-mode-p 'org-mode)
            (org-element-cache-reset)
            (when (and (markerp hermes--bench-start)
                       (marker-position hermes--bench-start)
                       (markerp hermes--bench-end)
                       (marker-position hermes--bench-end))
              (hermes--refresh-region
               (marker-position hermes--bench-start)
               (marker-position hermes--bench-end))))
          ;; Re-arm cooldown so subsequent rapid deltas continue to throttle.
          (hermes--stream-flush-reschedule))))))

(defun hermes--stream-update (_old-stream new-stream)
  "Reflect _OLD-STREAM → NEW-STREAM into the buffer."
  (when (or (null hermes--stream-segments-start)
            (null hermes--stream-segments-end))
    (hermes--stream-begin))
  (let ((new-segs (hermes-stream-segments new-stream)))
    (when (vectorp new-segs)
      (hermes--render-stream-segments new-segs)))
  (when (vectorp (hermes-stream-subagents new-stream))
    (hermes--update-subagent-views (hermes-stream-subagents new-stream))))

(provide 'hermes-org-render)
;;; hermes-org-render.el ends here
