# PLAN 02: Mode simplification — minor mode only

## Goal

Remove `hermes-mode` (derived major mode from `org-mode`) and rename
`hermes-minor-mode` to `hermes-org-minor-mode`.  The org buffer stays a
plain `org-mode` buffer; Hermes integration is a minor mode like gptel's
`gptel-mode`.

## Why

Plan 01 moved state to a global `hermes--sessions` table.  With state
decoupled from any particular buffer, a derived major mode for Hermes is
unnecessary.  The current code proves this already: `hermes-mode` is a
thin shell that does nothing except:

```elisp
(define-derived-mode hermes-mode org-mode "Hermes"
  (hermes-state-init)                     ;; now global, not buffer-local
  (hermes-minor-mode 1)                   ;; minor mode does all the work
  (setq-local hermes--container-level 1)
  (insert (concat (make-string hermes--container-level ?*)
                  " Hermes session :hermes:\n")))
```

`hermes-minor-mode` (the existing minor mode) owns the hooks, renderer,
keybindings, and mode-line.  There's no reason the major mode needs to
derive from `org-mode` — the user can just be in `org-mode` with the
minor mode active.  This is the gptel pattern.

The rename reflects that it only works in `org-mode` buffers (it uses
`org-map-entries`, `org-element-at-point`, Org properties, and drawers).

## What changes

### 1. Remove `hermes-mode` (derived major mode)

Delete the `(define-derived-mode hermes-mode org-mode ...)` form
(`hermes-mode.el` lines 267-278).  The symbol `hermes-mode` no longer
exists as a major mode.

Extract the container-heading insertion into a helper, called by the
entry point and DB-resume path (not by the minor mode itself):

```elisp
(defun hermes--ensure-container ()
  "Insert a Hermes session container heading at point-min if absent.
Called by the `hermes' entry point and DB-resume installer before
activating `hermes-org-minor-mode', which requires the heading to
already exist."
  (save-excursion
    (goto-char (point-min))
    (unless (hermes--container-heading-at-point-min-p)
      (insert (concat (make-string hermes--container-level ?*)
                      " Hermes session :hermes:\n")))))
```

This replaces the inline insertion currently at `hermes-mode.el` lines
274-278.

### 2. Rename `hermes-minor-mode` → `hermes-org-minor-mode`

Global search-and-replace across all `.el` files:

| From | To |
|------|-----|
| `hermes-minor-mode` (command name) | `hermes-org-minor-mode` |
| `hermes-minor-mode` (internal variable) | `hermes-org-minor-mode` |
| `hermes-minor-mode--on` | `hermes-org-minor-mode--on` |
| `hermes-minor-mode--off` | `hermes-org-minor-mode--off` |

The minor mode definition becomes:

```elisp
(define-minor-mode hermes-org-minor-mode
  "Minor mode for Hermes presentation in Org buffers.
Provides streaming render, auto-fold, header-line, and key bindings.
Works in any `org-mode' buffer with a `:hermes:' container heading."
  :init-value nil
  :lighter " Hermes"
  :keymap hermes-org-minor-mode-map
  (if hermes-org-minor-mode
      (hermes-org-minor-mode--on)
    (hermes-org-minor-mode--off)))
```

### 3. Rename keymap: `hermes-mode-map` → `hermes-org-minor-mode-map`

The minor mode's `:keymap` slot (`hermes-mode.el:262`) auto-generates the
keymap variable from the mode name.  After the rename, the auto-generated
name becomes `hermes-org-minor-mode-map`.  Three files reference the old
name:

| File | Line | Change |
|------|------|--------|
| `hermes-mode.el` | 149,163 | Rename `(defvar hermes-mode-map …)` and which-key to `(defvar hermes-org-minor-mode-map …)` |
| `hermes-transient.el` | 12,117 | Rename in comment + `(define-key hermes-mode-map …)` → `(define-key hermes-org-minor-mode-map …)` |
| `hermes-evil.el` | 28 | `(evil-define-key 'normal hermes-mode-map …)` → `(evil-define-key 'normal hermes-org-minor-mode-map …)` |

`hermes-doom.el` has no direct keymap references — just `(require
'hermes-mode)` which still works (the file exists, renamed variables
don't affect require).

### 4. Replace `derived-mode-p 'hermes-mode` checks

10 occurrences across 5 files.  Each becomes a `hermes-org-minor-mode`
variable check:

| File | Line | Before | After |
|------|------|--------|-------|
| `hermes-mode.el` | 223 | `(if (derived-mode-p 'hermes-mode) "Hermes-Org")` | Removed — see §5 |
| `hermes-mode.el` | 286 | `(and (derived-mode-p 'hermes-mode) …)` | `(and hermes-org-minor-mode …)` |
| `hermes-mode.el` | 382 | `((derived-mode-p 'hermes-mode) …)` | `(hermes-org-minor-mode …)` |
| `hermes-mode.el` | 455 | `(unless (derived-mode-p 'hermes-mode) …)` | `(unless hermes-org-minor-mode …)` |
| `hermes-mode.el` | 624 | `(unless (derived-mode-p 'hermes-mode) …)` | `(unless hermes-org-minor-mode …)` |
| `hermes-org.el` | 177 | `((derived-mode-p 'hermes-mode) …)` | `(hermes-org-minor-mode …)` |
| `hermes-org.el` | 704 | `(unless (or (derived-mode-p 'hermes-mode) …)` | `(unless (or hermes-org-minor-mode …)` |
| `hermes-image.el` | 117 | `(unless (or (derived-mode-p 'hermes-mode) …)` | `(unless (or hermes-org-minor-mode …)` |
| `hermes-input.el` | 371 | `(unless (or (derived-mode-p 'hermes-mode) …)` | `(unless (or hermes-org-minor-mode …)` |
| `hermes-compose.el` | 39 | `(unless (derived-mode-p 'hermes-mode) …)` | `(unless hermes-org-minor-mode …)` |

### 5. Remove redundant mode-line label

The mode-line format (`hermes-mode.el` lines 216-229) currently has a
right-aligned "Hermes-Org" label that only appears in the derived major
mode.  Inside `hermes-org-minor-mode--on`, the minor mode variable is
always t, so the conditional `(if hermes-org-minor-mode "Hermes-Org")`
collapses to always-true — dead code.

The `:lighter " Hermes"` already handles the mode-line indicator.
Remove the right-aligned label segment (lines 223-229):

```elisp
(setq-local mode-line-format
            '("%e"
              mode-line-modified
              " "
              mode-line-buffer-identification
              "  "
              (:eval hermes--mode-line-status)))
```

### 6. Fix `hermes-sessions.el:359` — the DB resume site

The function that installs a resumed/branched session from the DB
currently calls `(hermes-mode)` to create the buffer.  After plan 02:

```elisp
;; Before (hermes-sessions.el:358-359):
(with-current-buffer buf
  (hermes-mode)

;; After:
(with-current-buffer buf
  (org-mode)
  (hermes--ensure-container)
  (hermes-org-minor-mode 1)
  ;; ... rest of state setup unchanged ...
```

Container must exist before the minor mode activates — it checks for it.
The entry point and DB-resume path create it; the minor mode reads it.

### 7. Update `hermes-org-minor-mode--on` for plain org buffers

The minor mode must NOT modify the buffer — it is a pure activation.
This follows gptel's pattern: `gptel-mode` activates keybindings and
hooks, reads existing Org properties, but never inserts content.

The `:hermes:` container heading is the "Hermes session exists here"
signal.  The minor mode requires it to be present; the entry point and
DB-resume path create it.

```elisp
(defun hermes-org-minor-mode--on ()
  "Activate Hermes integration in the current org-mode buffer.
Requires a `:hermes:' container heading at point-min."
  (unless (derived-mode-p 'org-mode)
    (error "hermes-org-minor-mode requires org-mode"))
  (unless (hermes--container-heading-at-point-min-p)
    (error "No Hermes session heading found — use M-x hermes to create one"))
  (setq-local hermes--container-level 1)
  ;; …existing hook and config setup unchanged…
  )
```

`hermes--container-heading-at-point-min-p` is a simple predicate:

```elisp
(defun hermes--container-heading-at-point-min-p ()
  "Return non-nil when point-min holds a `:hermes:' container heading."
  (save-excursion
    (goto-char (point-min))
    (and (looking-at-p "\\*+ Hermes session")
         (save-excursion
           (re-search-forward ":hermes:" (line-end-position) t)))))
```

### 8. `M-x hermes` entry point

Keeps working.  Several paths:

```elisp
(defun hermes ()
  "Context-aware entry point — never sends a prompt."
  (interactive)
  (cond
   ;; Already in an org buffer with the minor mode active → focus bench
   (hermes-org-minor-mode
    (hermes-bench-ensure (current-buffer))
    (let* ((bench (hermes-bench-active-p))
           (win   (and bench (get-buffer-window bench))))
      (when (window-live-p win)
        (select-window win)
        (goto-char (point-max)))))
   ;; In a plain org-mode buffer → insert container, then activate
   ((derived-mode-p 'org-mode)
    (hermes--ensure-container)
    (hermes-org-minor-mode 1)
    (hermes-bench-ensure (current-buffer))
    (hermes-bench-focus))
   ;; Elsewhere → create a fresh org buffer with minor mode + bench
   (t
    (hermes--install-hooks)
    (unless (hermes-rpc-live-p) (hermes-rpc-start))
    (hermes--do-session-create
     (lambda (buf)
       (when buf
         (pop-to-buffer buf)
         (hermes-bench-ensure buf)))))))
```

### 9. Update test files

18 test sites across 4 files call `(hermes-mode)`.  These need to become
`(org-mode)` + `(hermes--ensure-container)` + `(hermes-org-minor-mode 1)`.

| File | Sites | Pattern |
|------|-------|---------|
| `test/hermes-render-test.el` | 16 | `(hermes-mode)` → `(org-mode)` + `(hermes--ensure-container)` + `(hermes-org-minor-mode 1)` |
| `test/hermes-org-test.el` | 1 | Same |
| `test/hermes-input-test.el` | 1 | Same |
| `test/hermes-bench-test.el` | 1 | Same + `(hermes--register-session …)` |

The bench test helper (`hermes-bench-test--make-parent`, lines 14-24)
needs the most attention — it creates a buffer, calls `(hermes-mode)`,
then registers a session:

```elisp
;; Before:
(defun hermes-bench-test--make-parent ()
  (let* ((sid …)
         (buf (generate-new-buffer …)))
    (with-current-buffer buf
      (hermes-mode)
      (hermes--register-session sid state marker))
    buf))

;; After:
(defun hermes-bench-test--make-parent ()
  (let* ((sid …)
         (buf (generate-new-buffer …)))
    (with-current-buffer buf
      (org-mode)
      (hermes--ensure-container)
      (hermes-org-minor-mode 1)
      (hermes--register-session
       sid (make-hermes-state :session-id sid :connection 'connected)
       (copy-marker (point-min) nil)))
    buf))
```

Also replace any `(setq hermes-minor-mode t)` with `(setq hermes-org-minor-mode t)`.

### 10. Update `declare-function` references

15 declarations point to `"hermes-mode"` as the source file.  The file
`hermes-mode.el` still exists, so most declarations don't need changing.
One exception:

| File | Line | Change |
|------|------|--------|
| `hermes-sessions.el` | 37 | Remove `(declare-function hermes-mode "hermes-mode" ())` — the function no longer exists |

The remaining 14 declarations stay as-is because the functions they point
to still live in `hermes-mode.el`.

### 11. Transient: update commentary

`hermes-transient.el` line 12 comment references `hermes-mode-map` —
update to `hermes-org-minor-mode-map`.  Line 27-28 commentary mentions
`hermes-mode' buffers` — update to `hermes-org-minor-mode' org-mode
buffers`.  Line 116 `with-eval-after-load 'hermes-mode` stays (the file
name hasn't changed).

## What the user sees

| Before | After |
|--------|-------|
| `M-x hermes` or `M-x hermes-minor-mode` | `M-x hermes` or `M-x hermes-org-minor-mode` |
| Modeline: `… Hermes-Org` (right-aligned) | Modeline: `… Hermes` (:lighter, no right-aligned label) |
| Major mode: `Hermes` (derived from Org) | Major mode: `Org` (plain) |
| Must use `hermes-mode` to get Hermes features | Any org buffer: `M-x hermes-org-minor-mode` |
| Bench appears when `hermes-mode` is active | Bench appears when `hermes-org-minor-mode` is active |

The Org streaming, keybindings, and bench behaviour are identical.

## Files touched

| File | Change |
|------|--------|
| `hermes-mode.el` | Remove `define-derived-mode hermes-mode`. Rename `hermes-minor-mode` → `hermes-org-minor-mode`. Rename `hermes-minor-mode--on` → `hermes-org-minor-mode--on`. Rename `hermes-mode-map` → `hermes-org-minor-mode-map`. Replace `derived-mode-p 'hermes-mode` → `hermes-org-minor-mode`. Remove redundant mode-line label segment. Add `hermes--ensure-container`, `hermes--container-heading-at-point-min-p`. Update `hermes` entry point. |
| `hermes-org.el` | Replace `derived-mode-p`. Rename references. |
| `hermes-sessions.el` | Replace `(hermes-mode)` call with `org-mode` + minor mode + `hermes--ensure-container`. Remove `declare-function hermes-mode`. |
| `hermes-image.el` | Replace `derived-mode-p`. |
| `hermes-input.el` | Replace `derived-mode-p`. |
| `hermes-compose.el` | Replace `derived-mode-p`. |
| `hermes-transient.el` | Rename keymap reference. Update commentary. |
| `hermes-evil.el` | Rename keymap reference. |
| `hermes-doom.el` | No keymap changes. Verify `(require 'hermes-mode)` still works (file exists). |
| `hermes-render.el` | Update comments/docstrings mentioning the major mode. |
| `hermes-bench.el` | Update comments. Bench attaches via minor mode check. |
| `hermes-bg.el` | `declare-function` stays (file exists). |
| `hermes-project.el` | `declare-function` stays. |
| `hermes-notifications.el` | `declare-function` stays. |
| `hermes-config.el` | `declare-function` stays. |
| `test/hermes-render-test.el` | 16 `(hermes-mode)` → `org-mode` + `hermes--ensure-container` + `hermes-org-minor-mode 1`. |
| `test/hermes-org-test.el` | 1 `(hermes-mode)` + rename references. |
| `test/hermes-input-test.el` | 1 `(hermes-mode)` + rename `hermes-minor-mode` → `hermes-org-minor-mode`. |
| `test/hermes-bench-test.el` | 1 `(hermes-mode)` + rename + `hermes--ensure-container`. Rewrite `hermes-bench-test--make-parent` helper. |

## What this plan does NOT cover

- No magit-section viewer (plan 03)
- No `turns` slot in `hermes-state` (plan 03)
- No `id` slot in `hermes-message` (plan 03)
- No streaming changes — org renderer stays as-is
- No import/export (plan 03)
- No bench refactoring beyond what plan 01 forces
