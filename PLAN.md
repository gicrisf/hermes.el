# Plan: Quick Wins — which-key, Notifications, Debug Inspector, Completion Metadata

## Scope

Implement the four quick-win integrations from `docs/16-integration-roadmap.md`:

1. **which-key discovery** for bench, major mode, and transient maps.
2. **Desktop notifications** for background events and blocking prompts.
3. **Debug inspector** commands for raw drawers and live state.
4. **Rich completion metadata** for model selection.

**Constraint:** No new hard dependencies. `which-key` is a soft dependency (wrapped in `with-eval-after-load`). Notifications use the built-in `notifications` library (Emacs 24.1+). The other two use only built-in Emacs features.

---

## 1. which-key Discovery

### What

Register human-readable descriptions for `hermes-bench-mode-map`, `hermes-mode-map`, and the transient popup so `which-key` displays "Interrupt session" instead of just the command name.

### Where to change

#### `hermes-bench.el`

After the `defvar hermes-bench-mode-map` block (around line 159), add:

```elisp
(with-eval-after-load 'which-key
  (which-key-add-keymap-based-replacements hermes-bench-mode-map
    "C-c C-c" "Send prompt"
    "C-c C-k" "Interrupt session"
    "C-c C-l" "Compose multi-line"
    "C-c C-s" "Steer mid-turn"))
```

**Rationale:** `which-key-add-keymap-based-replacements` is the canonical API. It is idempotent and safe to call multiple times.

#### `hermes-mode.el`

After the `defvar hermes-mode-map` block (around line 137), add:

```elisp
(with-eval-after-load 'which-key
  (which-key-add-keymap-based-replacements hermes-mode-map
    "C-c C-i" "Send / focus bench"
    "C-c C-l" "Compose multi-line"
    "C-c C-k" "Interrupt session"
    "C-c C-v" "View log"
    "C-c C-m" "Set model"
    "C-c C-f" "Toggle fast mode"))
```

#### `hermes-transient.el`

After the `transient-define-prefix hermes-transient` block, add:

```elisp
(with-eval-after-load 'which-key
  (which-key-add-keymap-based-replacements hermes-transient-map
    "C-c C-t" "Hermes command popup"))
```

Wait — transient prefixes do not use traditional keymaps in the same way. The correct approach for transient is to set the `:description` property on each suffix, which `transient-define-prefix` already does via the string argument (e.g. `"Send / focus bench"`). `which-key` does not apply to transient popups because they are not prefix keys in the traditional sense.

**Correction:** Only add which-key replacements to `hermes-bench-mode-map` and `hermes-mode-map`. The transient popup already has descriptions built into its definition.

### Testing

1. Load `which-key-mode`.
2. Open a Hermes session.
3. Press `C-c` in the main buffer and pause — `which-key` should show descriptions.
4. Move focus to the bench, press `C-c` and pause — descriptions should appear.
5. Verify no errors if `which-key` is not installed.

---

## 2. Desktop Notifications

### What

Surface `background.complete`, blocking prompts (approval/clarify/sudo/secret), and `review.summary` via `notifications-notify` when the user is in another buffer.

### New file: `hermes-notifications.el`

```elisp
;;; hermes-notifications.el --- Desktop notifications for Hermes  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Optional notification support for Hermes.  Loads the built-in
;; `notifications' library and hooks into state changes to alert the
;; user when background tasks finish or a blocking prompt appears
;; while they are editing in another buffer.
;;
;; Usage: (require 'hermes-notifications)

;;; Code:

(require 'notifications)
(require 'hermes-mode)

(defcustom hermes-notifications-enabled t
  "Whether Hermes notifications are active."
  :type 'boolean :group 'hermes)

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

(defun hermes-notify--on-state-change (old new)
  "Watch state transitions and fire notifications."
  ;; Background task completion
  (when (and old
             (hermes-state-stream old)
             (null (hermes-state-stream new))
             (hermes-state-background-p new))
    (hermes-notify--maybe-notify
     "Hermes" "Background task completed."))
  ;; Blocking prompt appeared
  (when (and new
             (hermes-state-pending new)
             (not (and old (hermes-state-pending old))))
    (let ((prompt-type (hermes-state-pending-type new)))
      (hermes-notify--maybe-notify
       "Hermes"
       (format "Blocking prompt: %s" (or prompt-type "action required"))))))

(add-hook 'hermes-state-change-hook #'hermes-notify--on-state-change)

(provide 'hermes-notifications)
;;; hermes-notifications.el ends here
```

### Wait — check the state struct

The plan assumes `hermes-state-background-p` and `hermes-state-pending-type` exist. I need to verify the actual struct definition in `hermes-state.el`.

Looking at `hermes-state.el` (from previous reads), the struct is `hermes-state` with fields including `session-id`, `connection`, `stream`, `queue`, `pending`, `history`, `slash-catalog`, `session-info`, `usage`, `busy-mode`.

There is NO `background-p` field. Background tasks are not currently tracked in the state atom. The `background.complete` event exists in `hermes-events.el` but may not be wired in the reducer.

**Correction:** The notification logic must work with what actually exists:

1. **Stream completion** — when `(hermes-state-stream old)` is non-nil and `(hermes-state-stream new)` is nil, a turn finished. If the user is in another buffer, notify "Turn completed".
2. **Blocking prompts** — `hermes-state-pending` holds a plist like `(:type "approval" …)`. When it transitions from nil to non-nil, notify.
3. **Background events** — if `background.complete` is not wired in the reducer, we cannot notify on it yet. Document this as a known limitation.

Revised implementation:

```elisp
(defun hermes-notify--on-state-change (old new)
  "Watch state transitions and fire notifications."
  ;; Turn completed
  (when (and old new
             (hermes-state-stream old)
             (null (hermes-state-stream new)))
    (hermes-notify--maybe-notify "Hermes" "Turn completed."))
  ;; Blocking prompt appeared
  (when (and new (hermes-state-pending new)
             (or (null old)
                 (null (hermes-state-pending old))))
    (let ((type (plist-get (hermes-state-pending new) :type)))
      (hermes-notify--maybe-notify
       "Hermes"
       (pcase type
         ("approval" "Approval required")
         ("clarify"  "Clarification required")
         ("sudo"     "Sudo password required")
         ("secret"   "Secret required")
         (_          "Action required"))))))
```

### Documentation update

Add to `AGENTS.md` under a new "Optional integrations" section:

```markdown
### Desktop notifications

For users who want notifications when turns complete or blocking
prompts appear while editing elsewhere:

```elisp
(require 'hermes-notifications)
```

Notifications are sent via the built-in `notifications` library
(DBus on Linux, Notification Center on macOS).  They only fire
when the Hermes buffer is not visible.
```

### Testing

1. Start a Hermes session, send a prompt.
2. Switch to another buffer before the turn completes.
3. Verify a notification appears.
4. Trigger an approval prompt (e.g. a tool that requires approval).
5. Switch to another buffer, verify a notification appears.
6. Kill `hermes-notifications.el`, verify no errors remain.

---

## 3. Debug Inspector

### What

Two commands:
- `hermes-inspect-turn` — pretty-print the `:HERMES_RAW:` drawer at point.
- `hermes-debug-state` — pop a buffer showing the live `hermes--state` atom.

### Where to add

Add both commands to `hermes-mode.el` (they are general debugging utilities) or create a new `hermes-debug.el`. Given the small size, adding to `hermes-mode.el` is fine, but a separate file keeps core cleaner. Let's add to `hermes-mode.el` to avoid another file for just two commands.

#### `hermes-inspect-turn`

This uses `hermes--extract-raw-drawer` from `hermes-render.el`. I need to check its signature.

From previous reads, `hermes--extract-raw-drawer` is declared in `hermes-mode.el` (line 543 uses it in `hermes--parse-buffer-messages`). It takes an optional POS argument.

```elisp
(defun hermes-inspect-turn ()
  "Pretty-print the `:HERMES_RAW:' drawer at point into a temp buffer."
  (interactive)
  (let ((raw (save-excursion (hermes--extract-raw-drawer))))
    (unless raw
      (user-error "No :HERMES_RAW: drawer at point"))
    (with-current-buffer (get-buffer-create "*Hermes Turn Inspector*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp raw (current-buffer)))
      (setq buffer-read-only t)
      (goto-char (point-min))
      (display-buffer (current-buffer)))))
```

#### `hermes-debug-state`

This needs to walk the `hermes--state` struct. The struct is defined in `hermes-state.el` with constructor `make-hermes-state` and accessors. There is no built-in "convert struct to plist" function visible from the reads, but we can manually extract fields.

Looking at `hermes-state.el` from previous reads, there are serializers like `hermes--message-to-plist`. The struct definition uses `cl-defstruct`.

For `cl-defstruct`, we can use `cl-struct-slot-info` or just manually list the accessors. The struct fields are: `session-id`, `connection`, `stream`, `queue`, `pending`, `history`, `slash-catalog`, `session-info`, `usage`, `busy-mode`.

```elisp
(defun hermes-debug-state ()
  "Pop a buffer inspecting the live `hermes--state' atom."
  (interactive)
  (unless (and (boundp 'hermes--state) hermes--state)
    (user-error "No Hermes state in this buffer"))
  (let* ((st hermes--state)
         (data `(:session-id   ,(hermes-state-session-id st)
                 :connection   ,(hermes-state-connection st)
                 :stream       ,(and (hermes-state-stream st) t)
                 :queue-length ,(length (hermes-state-queue st))
                 :pending      ,(hermes-state-pending st)
                 :history-len  ,(length (hermes-state-history st))
                 :slash-catalog ,(and (hermes-state-slash-catalog st) t)
                 :session-info ,(hermes-state-session-info st)
                 :usage        ,(hermes-state-usage st)
                 :busy-mode    ,(hermes-state-busy-mode st))))
    (with-current-buffer (get-buffer-create "*Hermes State Inspector*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacs-lisp-mode)
        (pp data (current-buffer)))
      (setq buffer-read-only t)
      (goto-char (point-min))
      (display-buffer (current-buffer)))))
```

Note: For `stream`, we only show `t` or `nil` because printing the full `hermes-stream` struct would be verbose. Similarly for `slash-catalog`.

#### Binding the commands

Add entries to `hermes-mode-map`? Or leave them as `M-x` only? Debug commands are typically `M-x` only to avoid polluting the keymap. Let's leave them unbound by default but mention them in documentation.

### Documentation update

Add to `AGENTS.md` in the Usage section:

```markdown
### Debugging

- `M-x hermes-inspect-turn` — pretty-print the `:HERMES_RAW:` drawer
  at point into a temporary buffer.
- `M-x hermes-debug-state` — inspect the live state atom for the
  current session.
```

### Testing

1. Open a Hermes buffer with committed turns.
2. Place point on a turn heading, `M-x hermes-inspect-turn`.
3. Verify a buffer pops with a pretty-printed plist.
4. `M-x hermes-debug-state` — verify the state buffer shows correct values.
5. Test in a fresh buffer with no state — should error gracefully.

---

## 4. Rich Completion Metadata for Model Selection

### What

Enhance `hermes-set-model` so its completion table carries `:annotation-function` metadata, and optionally a category for `marginalia`.

### Where to change

#### `hermes-config.el`

The relevant function is `hermes--set-model-prompt` (around line 130).

Current code builds a flat string list `candidates` and passes it to `completing-read`. We need to change this to an annotation-capable completion table.

```elisp
(defun hermes--set-model-prompt (result)
  "Prompt for a model given the provider RESULT hash, then issue `config.set'.
Completion candidates are annotated with provider labels."
  (let* ((current   (gethash "model" result))
         (providers (gethash "providers" result))
         (raw       (cond ((vectorp providers) (append providers nil))
                          ((listp providers)   providers)
                          (t nil)))
         (table
          (lambda (string pred action)
            (if (eq action 'metadata)
                '(metadata
                  (category . hermes-model)
                  (annotation-function
                   . (lambda (cand)
                       (let* ((id (hermes--candidate-provider-id cand))
                              (p (cl-find-if
                                  (lambda (pp)
                                    (equal id (and (hash-table-p pp)
                                                   (gethash "id" pp))))
                                  raw))
                              (label (and (hash-table-p p)
                                          (gethash "label" p))))
                         (and label (concat "  — " label))))))
              (complete-with-action action
                (mapcar #'hermes--provider-candidate raw)
                string pred))))
         (_ (when (null raw)
              (message "hermes: no providers returned — enter a model slug manually")))
         (initial   (hermes--model-short-name current))
         (prompt    (format "Model (current %s): " (or current "—")))
         (raw-choice (completing-read prompt table nil nil initial))
         ...))
```

Wait — the lambda inside `metadata` needs to be a proper function, not a lambda embedded in data (byte-compiler may complain). Better to define a helper:

```elisp
(defun hermes--model-annotation (cand providers)
  "Return annotation string for CAND given the PROVIDERS list."
  (let* ((id (hermes--candidate-provider-id cand))
         (p (cl-find-if
             (lambda (pp)
               (equal id (and (hash-table-p pp) (gethash "id" pp))))
             providers))
         (label (and (hash-table-p p) (gethash "label" p))))
    (and label (concat "  — " label))))
```

Then in `hermes--set-model-prompt`:

```elisp
(let* (...
       (candidates (mapcar #'hermes--provider-candidate raw))
       (table
        (lambda (string pred action)
          (if (eq action 'metadata)
              `(metadata
                (category . hermes-model)
                (annotation-function
                 . ,(lambda (cand)
                      (hermes--model-annotation cand raw))))
            (complete-with-action action candidates string pred))))
       ...)
  ...)
```

Actually, embedding a closure in metadata can cause issues. A cleaner approach is to build a hash table mapping candidate strings to annotations, then use a plain function:

```elisp
(defun hermes--model-annotation-function (cand table)
  "Return annotation for CAND from TABLE (hash of cand → label)."
  (gethash cand table))

;; In hermes--set-model-prompt:
(let* ((annotations (make-hash-table :test 'equal))
       (_ (dolist (p raw)
            (let ((cand (hermes--provider-candidate p))
                  (label (and (hash-table-p p) (gethash "label" p))))
              (when label (puthash cand (concat "  — " label) annotations)))))
       (table
        (lambda (string pred action)
          (if (eq action 'metadata)
              '(metadata
                (category . hermes-model)
                (annotation-function . hermes--model-annotation-function))
            (complete-with-action action candidates string pred))))
       ...)
  ;; But hermes--model-annotation-function needs access to annotations.
  ;; Use dynamic binding or a closure variable.
)
```

Actually, the simplest correct approach is to use a let-bound closure with a named helper that accesses a dynamically bound variable:

```elisp
(defvar hermes--model-annotation-table nil
  "Dynamically bound hash table for model completion annotations.")

(defun hermes--model-annotation (cand)
  "Return annotation for CAND from `hermes--model-annotation-table'."
  (when hermes--model-annotation-table
    (gethash cand hermes--model-annotation-table)))
```

Then in `hermes--set-model-prompt`:

```elisp
(let* ((...)
       (hermes--model-annotation-table (make-hash-table :test 'equal))
       (_ (dolist (p raw)
            (let ((cand (hermes--provider-candidate p))
                  (label (and (hash-table-p p) (gethash "label" p))))
              (when label
                (puthash cand (concat "  — " label) hermes--model-annotation-table)))))
       (table
        (lambda (string pred action)
          (if (eq action 'metadata)
              '(metadata
                (category . hermes-model)
                (annotation-function . hermes--model-annotation))
            (complete-with-action action candidates string pred))))
       ...)
  ...)
```

This is clean and byte-compiler safe.

### Documentation update

No `AGENTS.md` update needed for this one — it is a transparent UX improvement.

### Testing

1. `M-x hermes-set-model`.
2. Type a few characters.
3. Verify annotations appear (e.g. "openrouter (OpenRouter) — OpenRouter").
4. Test with `marginalia-mode` enabled — verify custom annotations appear.
5. Test without `marginalia` — standard `completing-read` should still work.

---

## Files to change

| File | Action | Approx lines |
|------|--------|-------------|
| `hermes-bench.el` | Add `which-key` replacements after `defvar hermes-bench-mode-map` | +8 |
| `hermes-mode.el` | Add `which-key` replacements after `defvar hermes-mode-map` | +10 |
| `hermes-notifications.el` | **Create** — notification hooks | ~35 |
| `hermes-mode.el` | Add `hermes-inspect-turn` and `hermes-debug-state` commands | ~40 |
| `hermes-config.el` | Add annotation helper vars/functions; enhance `hermes--set-model-prompt` | ~25 |
| `AGENTS.md` | Document notifications and debug commands | +20 |

## Testing checklist

- [ ] `eldev test` passes with no new warnings.
- [ ] `which-key` descriptions appear in bench and main buffer.
- [ ] No errors if `which-key` is not installed.
- [ ] Notification fires on turn completion when buffer is hidden.
- [ ] Notification fires on blocking prompt when buffer is hidden.
- [ ] `hermes-inspect-turn` pretty-prints a drawer correctly.
- [ ] `hermes-debug-state` shows state fields correctly.
- [ ] `hermes-set-model` shows annotations in completion.
- [ ] All new code follows existing indentation and naming conventions.
