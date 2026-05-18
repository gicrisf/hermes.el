# Plan: Optional Transient UI for Hermes

## Background

Hermes currently exposes all commands as plain `M-x` interactive functions with key bindings in `hermes-mode-map` (for major mode buffers) and in `doom-hermes.el` (for Doom Emacs leader prefixes). This works well for vanilla Emacs and for Doom, but many modern Emacs distributions (Doom, Spacemacs, and increasingly vanilla setups with Magit) ship **Transient** (the Magit popup library). Users of these configurations expect a discoverable, grouped, transient-style command menu rather than scattered key chords.

The constraint is strict: **the core package must remain dependency-free outside Emacs 27+**. Transient must not appear in any `Package-Requires` header, must not be `require`d from core files, and must fail gracefully when absent.

## Problem

There is no discoverable, grouped UI for Hermes commands. Users must either:
- Memorise `C-c C-*` chords in `hermes-mode` buffers.
- Know the exact `M-x` command names.
- Install Doom-specific bindings (which only helps Doom users).

A Transient popup would solve discoverability, but adding it to the core would violate the dependency-free goal.

## Design Goals

1. **Zero core dependencies.** Transient is never loaded by `hermes-mode.el`, never appears in `Package-Requires`, and never breaks a vanilla install.
2. **Opt-in, separate file.** Follow the exact same pattern as `doom-hermes.el`: a standalone `hermes-transient.el` that users manually load or require.
3. **Context-sensitive global menu.** Invoking the transient from anywhere shows:  
   - *Always*: session creation, session list, skills (reload/list/search/install), view log.  
   - *Only when a session is reachable*: send/compose/interrupt/steer, config toggles, skills uninstall.
4. **Skills work without a session.** Reload, list, search, and install are global gateway operations; they must be callable even when no `hermes-mode` buffer exists. The transient auto-starts the gateway for these commands.
5. **Doom integration.** `doom-hermes.el` binds the transient under the existing `SPC h` leader prefix when `hermes-transient` is available.
6. **No new hard key bindings in core.** The optional file may add `C-c C-t` to `hermes-mode-map`, but only when `hermes-transient.el` is actually loaded.

## Architecture

### The pattern: `doom-hermes.el` as precedent

`doom-hermes.el` already solves the "optional extra" problem:
- It is **not** loaded by `hermes-mode.el`.
- It `(require 'hermes-mode)` because anyone loading it already uses Hermes.
- It assumes Doom-specific features (`doom-leader-map`, `evil`) exist because the user opted in.

`hermes-transient.el` will follow this exact pattern:
- File lives in the repo root.
- Not loaded by any core file.
- `(require 'transient)` at the top (safe because only users who have Transient will load this file).
- `(require 'hermes-mode)` to pull in the command namespace.

### Context-sensitivity mechanism

Transient supports the `:if` keyword on both **groups** and **individual suffixes**. We define a single predicate:

```elisp
(defun hermes-transient--in-session-p ()
  "Non-nil when the current buffer has a reachable Hermes session target."
  (and (fboundp 'hermes--resolve-session-target)
       (hermes--resolve-session-target)))
```

This returns non-nil in:
- `hermes-mode` buffers with an assigned session.
- `hermes-minor-mode` Org buffers inside a `:hermes:` container.
- `hermes-bench-mode` buffers (resolved via `hermes-bench--parent-buffer`).

Groups that carry `:if hermes-transient--in-session-p` are hidden entirely when the predicate is nil. Individual suffixes (e.g. skills uninstall) can also carry `:if` for finer control.

### Gateway auto-start for session-less skills

Four skills commands do not need a session but **do** need a live gateway process:

| Command | Needs gateway? | Needs session? |
|---------|---------------|----------------|
| `hermes-skills-reload` | Yes | No |
| `hermes-skills-list` | Yes | No |
| `hermes-skills-search` | Yes | No |
| `hermes-skills-install` | Yes | No |
| `hermes-skills-uninstall` | Yes | **Yes** |

The existing commands do not auto-start the gateway; they error with "Hermes gateway is not running". The transient provides thin wrappers that start the gateway when needed:

```elisp
(defun hermes-transient--ensure-gateway ()
  "Start the gateway if it is not already running."
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start)))

(defun hermes-transient--skills-reload ()
  "Run `hermes-skills-reload', starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (hermes-skills-reload))

;; ... analogous wrappers for list, search, install
```

These wrappers are **interactive** and exist only inside `hermes-transient.el`. The original commands in `hermes-config.el` are untouched.

### Key binding philosophy

- **No default binding in core.** `hermes-mode-map` remains unchanged in `hermes-mode.el`.
- **Auto-binding in the optional file.** Inside `hermes-transient.el`, after `hermes-transient` is defined:
  ```elisp
  (with-eval-after-load 'hermes-mode
    (define-key hermes-mode-map (kbd "C-c C-t") #'hermes-transient))
  ```
  This means a user who loads `hermes-transient.el` gets `C-c C-t` in Hermes buffers for free, but a vanilla user who never loads the file sees no change and no missing-function errors.

---

## File: `hermes-transient.el` (full specification)

### Header

```elisp
;;; hermes-transient.el --- Optional Transient UI for Hermes  -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; Optional Transient popup for Hermes commands.  This file is NOT loaded
;; by `hermes-mode.el'.  Users who have Transient installed (Doom, Magit,
;; etc.) should add `(require 'hermes-transient)' to their init.
;;
;; When loaded, this file binds `C-c C-t' in `hermes-mode-map' to the
;; main transient prefix.  In Doom, `doom-hermes.el' additionally binds
;; it under the `SPC h' leader.

;;; Code:

(require 'transient)
(require 'hermes-mode)
```

### Predicates

```elisp
(defun hermes-transient--in-session-p ()
  "Non-nil when the current buffer has a reachable Hermes session target.
Returns nil in arbitrary buffers, in `hermes-mode' buffers before
`session.create' resolves, and in Org buffers outside a `:hermes:'
container."
  (and (fboundp 'hermes--resolve-session-target)
       (hermes--resolve-session-target)))
```

No additional predicates are needed. Transient's built-in `:if` is sufficient.

### Gateway helper

```elisp
(defun hermes-transient--ensure-gateway ()
  "Start the Hermes gateway if it is not currently running.
Idempotent: safe to call when the gateway is already up."
  (unless (hermes-rpc-live-p)
    (hermes-rpc-start)))
```

### Thin wrappers for session-less skills

```elisp
(defun hermes-transient--skills-reload ()
  "Reload skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (hermes-skills-reload))

(defun hermes-transient--skills-list ()
  "List skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (hermes-skills-list))

(defun hermes-transient--skills-search ()
  "Search skills, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (call-interactively #'hermes-skills-search))

(defun hermes-transient--skills-install ()
  "Install a skill, auto-starting the gateway if necessary."
  (interactive)
  (hermes-transient--ensure-gateway)
  (call-interactively #'hermes-skills-install))
```

`hermes-skills-uninstall` does **not** get a wrapper because it requires a session (via `hermes--config-resolve-target`), which implies the gateway is already running. It is invoked directly in the transient with an `:if` condition.

### The transient prefix

```elisp
;;;###autoload
(transient-define-prefix hermes-transient ()
  "Hermes command dispatch popup.
Shows session commands always; input, config, and session-scoped
skills commands only when a Hermes session is reachable."
  ["Session"
   ("o" "Open / create session" hermes)
   ("n" "New session" hermes-new-session)
   ("l" "Session list" hermes-sessions)]

  ["Input" :if hermes-transient--in-session-p
   ("i" "Send / focus bench" hermes-send-or-focus-bench)
   ("c" "Compose" hermes-compose)
   ("k" "Interrupt" hermes-interrupt)
   ("S" "Steer" hermes-steer)]

  ["Config" :if hermes-transient--in-session-p
   ("m" "Model" hermes-set-model)
   ("f" "Fast mode" hermes-toggle-fast)
   ("r" "Reasoning" hermes-toggle-reasoning)
   ("y" "YOLO" hermes-toggle-yolo)
   ("p" "Personality" hermes-set-personality)
   ("s" "Skin" hermes-set-skin)
   ("t" "Toolsets" hermes-toolsets-toggle)]

  ["Skills"
   ("R" "Reload" hermes-transient--skills-reload)
   ("L" "List" hermes-transient--skills-list)
   ("/" "Search" hermes-transient--skills-search)
   ("I" "Install" hermes-transient--skills-install)
   ("U" "Uninstall" hermes-skills-uninstall :if hermes-transient--in-session-p)]

  ["Misc"
   ("v" "View log" hermes-view-log)])
```

**Key layout rationale:**
- Lowercase letters favour mnemonics that match existing `C-c C-*` bindings (`i` for input, `c` for compose, `k` for interrupt, `m` for model, `f` for fast, `r` for reasoning, `y` for yolo, `t` for toolsets, `v` for view log).
- Capital letters are used for less frequent or secondary commands (`S` for steer, `R`/`L`/`I`/`U` for skills) to avoid shadowing the lowercase mnemonics.
- `/` is used for search because it is visually evocative and does not conflict with any existing Hermes binding.

### Post-define hook (optional auto-binding)

```elisp
;;;###autoload
(with-eval-after-load 'hermes-mode
  (define-key hermes-mode-map (kbd "C-c C-t") #'hermes-transient))

(provide 'hermes-transient)
;;; hermes-transient.el ends here
```

---

## File: `doom-hermes.el` (changes)

Add a soft require and a leader binding **after** the existing `(require 'hermes-mode)` line:

```elisp
(require 'hermes-mode)
(require 'hermes-transient nil t)   ; soft: no error if user lacks transient
```

Inside the existing `(when (bound-and-true-p doom-leader-map) ...)` block, add:

```elisp
(when (fboundp 'hermes-transient)
  (define-key hermes-leader-map (kbd ".") #'hermes-transient))
```

This makes the transient available as `SPC h .` in Doom, mirroring Magit's convention of using `.` for the main dispatch popup.

**Rationale for `SPC h .`:**
- `SPC h` is already the Hermes leader prefix in Doom.
- `.` is the standard Magit/Transient "dispatch" key (e.g. `magit-dispatch` is often bound to `.`).
- It does not conflict with any existing `SPC h *` binding in `doom-hermes.el`.

---

## Documentation

### `AGENTS.md` update

Add a new section after the Doom Emacs integration block:

```markdown
### Transient popup (optional)

For users with Transient installed (Doom, Spacemacs, or Magit users):

```elisp
(require 'hermes-transient)
```

This binds `C-c C-t` in `hermes-mode` buffers to a grouped popup menu.
The popup is context-sensitive: session-level commands (send, config,
steer, skills uninstall) are hidden when no Hermes session is active.
Skills reload/list/search/install are always available and will auto-start
the gateway if needed.
```

Also update the "Doom Emacs keybindings" table to include:

| Key | Action |
|-----|--------|
| `SPC h .` | Transient command popup |

### Inline comments

- Every wrapper function must carry a docstring explaining *why* it exists (gateway auto-start).
- `hermes-transient--in-session-p` must explain the three buffer types it handles.
- The `transient-define-prefix` form should have a comment block above it explaining the `:if` group semantics.

---

## Files to change

| File | Action | Lines |
|------|--------|-------|
| `hermes-transient.el` | **Create** — full specification above | ~90 |
| `doom-hermes.el` | **Edit** — add soft require + `SPC h .` binding | +4 |
| `AGENTS.md` | **Edit** — document the optional file and new Doom key | +~15 |

**No core files are modified.** `hermes-mode.el`, `hermes-config.el`, `hermes-input.el`, and all other core files remain untouched.

---

## Testing

### 1. Core still works without transient

```bash
eldev test
```

Expected: all existing tests pass (191/191 or current count). There must be zero new warnings or byte-compile errors.

### 2. Vanilla Emacs without transient

```elisp
(add-to-list 'load-path "~/Projects/emacs-hermes")
(require 'hermes-mode)
M-x hermes
```

Expected: `C-c C-t` is unbound or does nothing. No `transient` feature errors. `M-x hermes-send` still works via minibuffer.

### 3. With transient loaded

```elisp
(require 'hermes-transient)
M-x hermes
;; In the hermes buffer, press C-c C-t
```

Expected: popup appears. Session group is visible. Input and Config groups are visible because a session is active. Skills group is visible. Pressing `n` from a random non-Hermes buffer should still offer `New session`.

### 4. Context sensitivity from a non-Hermes buffer

```elisp
;; From *scratch*, run:
M-x hermes-transient
```

Expected: only Session, Skills (reload/list/search/install), and Misc groups appear. Input, Config, and Uninstall are hidden.

### 5. Skills without a session

```elisp
;; Kill all hermes buffers. Ensure gateway is down.
M-x hermes-transient
;; Press R (Reload)
```

Expected: gateway starts automatically. Skills reload succeeds. No session is created.

### 6. Doom leader binding

In a Doom environment with `doom-hermes.el` loaded:

```
SPC h .
```

Expected: same popup as `C-c C-t`.

---

## Appendix A: Command availability matrix

| Command | Transient key | Needs session? | Needs gateway? | Wrapper? |
|---------|--------------|----------------|----------------|----------|
| `hermes` | `o` | No (creates one) | Auto-started by command | No |
| `hermes-new-session` | `n` | No (creates one) | Auto-started by command | No |
| `hermes-sessions` | `l` | No | No | No |
| `hermes-send-or-focus-bench` | `i` | **Yes** | Yes | No |
| `hermes-compose` | `c` | **Yes** | Yes | No |
| `hermes-interrupt` | `k` | **Yes** | Yes | No |
| `hermes-steer` | `S` | **Yes** | Yes | No |
| `hermes-set-model` | `m` | **Yes** | Yes | No |
| `hermes-toggle-fast` | `f` | **Yes** | Yes | No |
| `hermes-toggle-reasoning` | `r` | **Yes** | Yes | No |
| `hermes-toggle-yolo` | `y` | **Yes** | Yes | No |
| `hermes-set-personality` | `p` | **Yes** | Yes | No |
| `hermes-set-skin` | `s` | **Yes** | Yes | No |
| `hermes-toolsets-toggle` | `t` | **Yes** | Yes | No |
| `hermes-skills-reload` | `R` | No | **Yes** | **Yes** (auto-start) |
| `hermes-skills-list` | `L` | No | **Yes** | **Yes** (auto-start) |
| `hermes-skills-search` | `/` | No | **Yes** | **Yes** (auto-start) |
| `hermes-skills-install` | `I` | No | **Yes** | **Yes** (auto-start) |
| `hermes-skills-uninstall` | `U` | **Yes** | Yes | No |
| `hermes-view-log` | `v` | No | No | No |

## Appendix B: Why no `hermes-mode-map` binding in core

Binding `C-c C-t` directly inside `hermes-mode.el` would create a forward reference to an autoloaded function that lives in an optional file. While Emacs handles this gracefully at runtime, it creates a subtle expectation: users might press `C-c C-t` before loading `hermes-transient.el` and see a "command attempted to use minibuffer while in minibuffer"-style error or a void-function error if the autoload is missing.

By keeping the binding inside `hermes-transient.el` itself (wrapped in `with-eval-after-load`), we guarantee:
- The key only exists when the file is loaded.
- The function is defined before the key is bound.
- Core byte-compilation never sees `transient` symbols.

This is the same reason `doom-hermes.el` does not bind keys inside `hermes-mode.el`.
