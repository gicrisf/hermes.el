# PLAN 21: Replace `hermes-bench.el` with comint-backed bench buffers

## Motivation

`hermes-bench.el` (606 lines) and `hermes-comint.el` (848 lines) duplicate
the same input-surface machinery — motion whitelist, `pre-command-hook`
auto-jump, prompt management, input extraction/clearing, send/interrupt/
compose dispatch — using custom `text-mode` code while comint already
provides all of this (history ring, field-based prompts, proper readline).

The bench was the original input surface.  The comint viewer came later
and independently re-implemented the same primitives on a better
foundation.  Instead of having two modes that do the same thing, make
the bench mode simply a `hermes-comint-mode` buffer flagged with
`hermes-comint--bench-p`.

The *public API* keeps the "bench" name: `hermes-bench-ensure`,
`hermes-bench-active-p`, `hermes-bench-focus`, `hermes--bench-buffers`.
Zero call-site changes in integration files.  The implementation inside
`hermes-bench.el` is replaced by comint equivalents in `hermes-comint.el`.

## Central design: `hermes-comint--bench-p`

A single buffer-local boolean flag on `hermes-comint-mode`:

```elisp
(defvar-local hermes-comint--bench-p nil
  "When non-nil, this comint buffer acts as a bench.
Only the current ephemeral turn is rendered (user prompt + stream);
committed history lives in the paired org buffer.  On stream commit
the ephemeral region clears — no turns are accumulated locally.")
```

| `hermes-comint--bench-p` | `load-from-state` | `append-new-turns` | Stream commit | Meaning |
|--------------------------|-------------------|---------------------|---------------|---------|
| nil (default, full viewer) | Loads all `turns` | Appends new turns | Advances `output-end`; turn becomes committed locally | Standalone conversation viewer |
| t (bench) | No-op | No-op | Deletes ephemeral region; turn only lives in org | Input sidebar paired with org buffer |

There is no third mode — when `bench-p` is t and no stream is active
and no user prompt is pending, the ephemeral area above the prompt is
empty, which IS an input-only surface.  No separate nil flag needed.

## Ephemeral rendering flow (bench mode)

```
Buffer layout after setup:
┌─────────────────────────────────────────────────────┐
│ [empty — output-end = point-min]                    │
├─────────────────────────────────────────────────────┤
│ > █                                        ← prompt │
└─────────────────────────────────────────────────────┘

Send:
  1. Read input text, push to comint-input-ring
  2. Store input in hermes-comint--current-user-prompt (buffer-local)
  3. Clear [output-end, prompt-start)         ← wipe old ephemeral
  4. Insert formatted user heading at output-end:
     ┌─────────────────────────────────────────────────────┐
     │ > User · 14:52                             ← output │
     │ what is 2+2?                                       │
     │                                                    │
     ├─────────────────────────────────────────────────────┤
     │ > █                                        ← prompt │
     └─────────────────────────────────────────────────────┘
  5. hermes-comint--apply-output-props on user block (read-only, field output)
  6. Clear input area (= delete text after prompt prefix)
  7. hermes-send

First stream tick (stream-begin):
  paint-stream deletes [output-end, prompt-start) and re-inserts
  user heading + steer + status + in-flight assistant turn atomically:
     ┌─────────────────────────────────────────────────────┐
     │ > User · 14:52                             ← output │
     │ what is 2+2?                                       │
     │                                                    │
     │ Let me think about this carefully...                │
     │                                                    │
     │ 2+2 is 4.                                          │
     ├─────────────────────────────────────────────────────┤
     │ > █                                        ← prompt │
     └─────────────────────────────────────────────────────┘

Stream update ticks:
  paint-stream deletes [output-end, prompt-start) and re-inserts
  user heading + steer + status + latest stream content.
  (Same atomic rebuild as the first tick.)

Stream commit (bench-p branch):
  1. Cancel throttle timer
  2. Delete [output-end, prompt-start)          ← clear ephemeral
  3. Clear steer messages, clear status message
  4. Do NOT clear user-prompt (harmless; gets overwritten on next send)
  5. Do NOT advance output-end; do NOT update turns-snapshot

After commit:
┌─────────────────────────────────────────────────────┐
│ [empty — ready for next send]                       │
├─────────────────────────────────────────────────────┤
│ > █                                        ← prompt │
└─────────────────────────────────────────────────────┘
```

### Paint-stream contract (bench mode)

Bench-mode `paint-stream` renders EVERYTHING above the prompt in a
single atomic repaint: user heading → steer lines → status line →
assistant turn.  This is the same model the old bench used pre-2b0101d
(`hermes-bench--paint-ephemeral` rebuilt from scratch on every tick).
Full-viewer `paint-stream` is unchanged — it renders only the assistant
turn (no user heading prepended).

This means `paint-stream` in bench mode reads three buffer-local
variables that survive across stream ticks:

```elisp
(defvar-local hermes-comint--current-user-prompt nil
  "Last user prompt text, preserved across stream ticks.
Set on send; read by paint-stream; cleared on send for next prompt.")
(defvar-local hermes-comint--steer-messages nil
  "List of [steer] strings.  Cleared on stream commit.")
(defvar-local hermes-comint--status-message nil
  "Transient status plist (:text :error-p).  Rendered above the prompt.
Set by hermes-bench-show-status; cleared on stream commit.")
```

## Status surfaces — what goes where

| Content | Surface | Rationale |
|---------|---------|-----------|
| Bg task counters | `header-line-format` | Session-level, always visible. Full comint already does this via `hermes-comint--format-header-line`. |
| Attachment count | `header-line-format` | Session-level. Same as above. |
| Steer messages | Ephemeral region (paint-stream) | Turn-specific; valid only for the current in-flight turn. |
| Transient status (config/cmd feedback) | Ephemeral region (paint-stream) | One-shot feedback from `hermes-bench-show-status`. |
| Slash-command feedback (errors) `hermes-bench-show-status(sid text :error-p)` would also go to the ephemeral region, appearing after the user heading and before the stream content. |  |  |

No separator line — comint uses field-based prompt detection.  The
bench's `hermes-bench-separator` defcustom is dropped.

## History ring

The current bench has no input history ring.  Switching to
`comint-input-ring` (M-p / M-n) is a net-new feature.  The ring starts
fresh per bench buffer — no seeding from `hermes-state-history` (which
is the minibuffer input history, a different concern).  Seeding could
be added later as an enhancement: on bench setup, push entries from
`hermes-state-history` into the comint ring in reverse order.

## Splash banner

No splash.  The splash was removed in plan 20 ("extreme simplification
of the bench").  The AGENTS.md text mentioning it is stale and already
updated in this plan's AGENTS.md section below.

## Public API — kept, reimplemented in `hermes-comint.el`

| Function | Old location | New location | Change |
|----------|-------------|--------------|--------|
| `hermes-bench-ensure(sid)` | `hermes-bench.el` | `hermes-comint.el` | Creates `hermes-comint-mode` buffer with `bench-p = t`, displays as bottom side-window. Buffer name stays `*hermes-bench:<sid>*`. |
| `hermes-bench-active-p(&optional buf-or-sid)` | `hermes-bench.el` | `hermes-comint.el` | Looks up `hermes--bench-buffers`, checks `buffer-live-p`. |
| `hermes-bench-focus()` | `hermes-mode.el` | `hermes-mode.el` (stays) | Implementation changes: finds bench via `hermes--bench-buffers`, selects its window, goes to point-max. Falls back to `hermes-send` if no bench. |
| `hermes-bench-show-status(sid text &optional error-p)` | `hermes-bench.el` | `hermes-comint.el` | Sets `hermes-comint--status-message`, triggers repaint so the status appears in the ephemeral region. |
| `hermes-bench-add-steer(sid text)` | `hermes-bench.el` | `hermes-comint.el` | Appends to `hermes-comint--steer-messages` + triggers repaint. |
| `hermes-bench-hide(sid)` | `hermes-bench.el` | `hermes-comint.el` | Kills bench window + buffer, removes from registry. |
| `hermes-bench-bg-list()` | `hermes-bench.el` | `hermes-comint.el` | Pops bg-task list for bench's session. |
| `hermes--maybe-kill-bench(sid)` | `hermes-state.el` | `hermes-state.el` (stays) | Unchanged logic. |
| `hermes--bench-buffers` | `hermes-state.el` | `hermes-state.el` (stays) | Unchanged. |

## File-by-file changes

### 1. `hermes-comint.el` — Add bench support (~160 new/changed lines)

**New buffer-local variables:**
```elisp
(defvar-local hermes-comint--bench-p nil
  "When non-nil, this comint buffer acts as a bench.")
(defvar-local hermes-comint--current-user-prompt nil
  "Last user prompt text, preserved across stream ticks.")
(defvar-local hermes-comint--steer-messages nil
  "List of [steer] strings shown in ephemeral area.")
(defvar-local hermes-comint--status-message nil
  "Transient status plist (:text :error-p).")
(defvar-local hermes-comint--bg-cookie nil
  "face-remap cookie for skin background (bench mode).")
```

**Faces moved from bench (keep exact names):**
- `hermes-bench-buffer-face` — still named `hermes-bench-buffer-face`
- `hermes-bench-status-face` — for `hermes-comint--status-message` when `error-p`

Faces dropped (comint has equivalents):
- `hermes-bench-prompt-face` — comint uses `comint-highlight-prompt`
- `hermes-bench-separator-face` — no separator
- `hermes-bench-attachment-face` — attachments in header-line use shadow
- `hermes-bench-hl-line-face` — comint can use `hl-line` directly

**Defcustoms moved from bench (keep exact names):**
- `hermes-bench-height` — side-window height, used in `hermes-bench-ensure`
- `hermes-bench-background-color` — skin override

Defcustoms dropped:
- `hermes-bench-prompt` → comint uses `hermes-comint--prompt-string`
- `hermes-bench-separator` → no separator

**New ephemeral rendering helpers (identical to old bench equivalents):**

| Function | Purpose |
|----------|---------|
| `hermes-comint-bench--insert-user-heading(text)` | Inserts `> User · HH:MM\n<fontified body>\n\n` with output-props |
| `hermes-comint-bench--insert-steer-lines()` | Inserts `[steer] <msg>\n` lines in `hermes-bench-status-face` |
| `hermes-comint-bench--insert-status-line()` | Inserts single status line from `hermes-comint--status-message` |
| `hermes-comint-bench--clear-ephemeral()` | Deletes `[output-end, prompt-start)` |

**Key function: bench-mode paint-stream modification**

In `hermes-comint--paint-stream`, after deleting `[output-end, prompt-start)`
and before inserting the assistant turn, prepend bench ephemeral content:

```elisp
(when hermes-comint--bench-p
  (when hermes-comint--current-user-prompt
    (hermes-comint-bench--insert-user-heading
     hermes-comint--current-user-prompt))
  (when hermes-comint--steer-messages
    (hermes-comint-bench--insert-steer-lines))
  (when hermes-comint--status-message
    (hermes-comint-bench--insert-status-line)))
```

**New public functions (replacing bench.el):**

| Function | Notes |
|----------|-------|
| `hermes-bench-ensure(sid)` | Creates/looks up `*hermes-bench:<sid>*`, enables `hermes-comint-mode` with `bench-p = t`, displays as bottom side-window via `display-buffer-in-side-window` with `(side . bottom) (slot . 0) (window-height . hermes-bench-height)`, applies skin bg, registers in `hermes--bench-buffers`. If buffer already exists and is live, re-displays window if hidden. |
| `hermes-bench-active-p(&optional buf-or-sid)` | Resolves bench from session-id (hash lookup) or buffer context (walk `hermes--bench-buffers`). Returns live buffer or nil. |
| `hermes-bench-hide(sid)` | Deletes bench window(s) for sid, kills buffer, removes from `hermes--bench-buffers`. |
| `hermes-bench-show-status(sid text &optional error-p)` | Finds bench for sid, sets `hermes-comint--status-message`, calls `hermes-comint--paint-stream` to repaint immediately with the status line visible. |
| `hermes-bench-add-steer(sid text)` | Finds bench for sid, appends text to `hermes-comint--steer-messages`, calls `hermes-comint--paint-stream` to repaint. |
| `hermes-bench-bg-list()` | Reads `hermes--current-session-id` from bench buffer, calls `hermes-bg--list-for-sid`. |

**Skin background (identical to current bench):**
```elisp
(defun hermes-comint-bench--effective-bg (skin)
  (or hermes-bench-background-color
      (and (hash-table-p skin) (gethash "ui_bench" skin))
      (face-background 'hermes-bench-buffer-face nil 'default)))

(defun hermes-comint-bench--apply-bg (&optional skin)
  (when hermes-comint--bg-cookie
    (face-remap-remove-relative hermes-comint--bg-cookie)
    (setq hermes-comint--bg-cookie nil))
  (let ((bg (hermes-comint-bench--effective-bg skin)))
    (setq hermes-comint--bg-cookie
          (face-remap-add-relative
           'default `(:background ,bg :extend t)))))

(defun hermes-comint-bench--refresh-bg-all (_skin)
  (dolist (buf (hash-table-values hermes--bench-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf (hermes-comint-bench--apply-bg)))))
(add-hook 'hermes-skin-applied-hook #'hermes-comint-bench--refresh-bg-all)
```

**Modified existing functions:**

| Function | Change |
|----------|--------|
| `hermes-comint--setup` | Bench mode: use `hermes-comint-bench--detach` as `kill-buffer-hook`; add CAPF for slash-completion; add bench keybindings (`C-c C-a`, `C-c C-v`, `C-c C-b`); skip `load-from-state`. Full mode: unchanged. |
| `hermes-comint--load-from-state` | `(when hermes-comint--bench-p (cl-return nil))` at top |
| `hermes-comint--append-new-turns` | `(when hermes-comint--bench-p (cl-return nil))` at top |
| `hermes-comint-send` | Bench mode: store `input` in `hermes-comint--current-user-prompt`, wipe old ephemeral, insert user heading, clear input, dispatch. Full mode: unchanged. History ring push is shared (both modes). |
| `hermes-comint--paint-stream` | Bench mode: after `delete-region` and before `insert-turn`, prepend user heading + steer + status (see snippet above). Full mode: unchanged — renders only the assistant turn. |
| `hermes-comint--stream-commit` | Bench branch: cancel timer, `delete-region` ephemeral, `(setq hermes-comint--steer-messages nil)`, `(setq hermes-comint--status-message nil)`. Return. Do NOT advance output-end, do NOT update turns-snapshot. Full mode: unchanged. |
| `hermes-comint--refresh` | Gated: `append-new-turns` only when `(not bench-p)`. Header-line refresh always runs (both modes). |
| `hermes-comint--detach` | Bench mode: calls `hermes-comint-bench--detach` instead (skips `hermes--maybe-kill-bench` call — bench handles its own registry cleanup). Full mode: unchanged (calls `hermes--maybe-kill-bench`). |

**New bench detach:**
```elisp
(defun hermes-comint-bench--detach ()
  "Remove this bench buffer from hermes--bench-buffers on kill."
  (hermes-comint--stream-cancel-timer)
  (when (and hermes--current-session-id hermes-comint--bench-p)
    (remhash hermes--current-session-id hermes--bench-buffers)))
```

**Slash-command completion (added in bench setup):**
```elisp
(add-hook 'completion-at-point-functions
          #'hermes-comint-bench--slash-complete nil t)
```
Identical logic to current `hermes-bench-completion-at-point` but reads
prompt text via `hermes-comint--prompt-text`.

### 2. `hermes-bench.el` — Delete

Remove the entire file (606 lines).

### 3. `Eldev` — Update source list

Remove `"hermes-bench.el"` from `eldev-main-fileset`.  No new entries
needed (comint.el is already in the list).

### 4. `hermes-state.el` — One-line change

`hermes--buffer-sid` (lines 357-358): remove the `hermes-bench--session-id`
branch.  Bench buffers now use `hermes-comint-mode`, which already sets
`hermes--current-session-id` buffer-locally (set by `hermes-bench-ensure`),
so the first `or` branch catches them.

Everything else stays: `hermes--bench-buffers` registry, `hermes--maybe-kill-bench`
logic — all unchanged.  The registry still maps sid → bench buffer; the
buffers just happen to be in `hermes-comint-mode` now.

### 5. `hermes-mode.el` — Two changes

| Line | Change |
|------|--------|
| 31 | `(require 'hermes-bench)` → remove. Bench API is now in `hermes-comint.el`, loaded transitively via `hermes-state`. |
| 287-306 | `hermes-bench-focus` — implementation changes: look up bench via `hermes--bench-buffers`, select its window, go to point-max. Name stays `hermes-bench-focus`. |

All other lines — **zero changes**.  `hermes-bench-ensure`, `hermes-bench-active-p`,
`hermes--focus-bench-input` — same function names, new implementations in comint.

### 6. `hermes-render.el` — Declaration update

Line 30: change `(declare-function hermes-bench-active-p "hermes-bench" ...)` to
`(declare-function hermes-bench-active-p "hermes-comint" ...)`.

### 7. Other integration files — Zero changes

| File | Why unchanged |
|------|---------------|
| `hermes-org.el:717` | Calls `hermes-bench-ensure` — same name |
| `hermes-config.el:483` | Calls `hermes-bench-active-p` — same name |
| `hermes-image.el:99-100,214-215` | Calls `hermes-bench-active-p` — same name |
| `hermes-sessions.el:423-424` | Calls `hermes-bench-ensure` — same name |
| `hermes-evil.el` | Binds `hermes-bench-focus` — same name |
| `hermes-transient.el` | References `hermes-bench-focus` — same name |

### 8. AGENTS.md — Update bench description

Replace:

> **Bench (major mode only):** `hermes-mode` buffers display a persistent bottom
> bench — a 20-line side-window that is a pure input surface: status header
> (background tasks, pending attachments) + separator + editable prompt.

With:

> **Bench (major mode only):** `hermes-mode` buffers display a persistent bottom
> side-window — a `hermes-comint-mode` buffer with `bench-p = t` — that shows
> the current in-flight turn (user prompt, reasoning, answer) above a writable
> prompt.  The bench provides comint's history ring (M-p/M-n) and field-based
> prompt handling.  Committed turns land in the org buffer only.

## Send in bench mode (pseudocode)

```elisp
(defun hermes-comint-send ()
  (interactive)
  (let* ((text (hermes-comint--prompt-text))
         (input (string-trim text)))
    (when (string-empty-p input) (user-error "Nothing to send"))
    ;; History ring (shared path).
    (when (or (null comint-input-ring) ...)
      (ring-insert comint-input-ring input))
    (setq comint-input-ring-index nil)
    (hermes-comint--clear-prompt)
    (when hermes-comint--bench-p
      ;; Store so paint-stream can re-render it on stream ticks.
      (setq hermes-comint--current-user-prompt input)
      ;; Clear old ephemeral, show user heading immediately.
      (let ((inhibit-read-only t)
            (out-end (marker-position hermes-comint--output-end))
            (pr-start (marker-position hermes-comint--prompt-start)))
        (delete-region out-end pr-start)
        (save-excursion
          (goto-char out-end)
          (hermes-comint-bench--insert-user-heading input))))
    (hermes-send input)))
```

## Stream commit in bench mode (pseudocode)

```elisp
(defun hermes-comint--stream-commit (state)
  (hermes-comint--stream-cancel-timer)
  (setq hermes-comint--stream-active nil)
  (if hermes-comint--bench-p
      (progn
        (setq hermes-comint--steer-messages nil)
        (setq hermes-comint--status-message nil)
        (let ((inhibit-read-only t))
          (delete-region (marker-position hermes-comint--output-end)
                         (marker-position hermes-comint--prompt-start))))
    ;; Full viewer: existing commit logic (unchanged).
    (let* ((inhibit-read-only t) ...)))
  (hermes-comint--ensure-prompt-visible))
```

## Bench paint-stream (pseudocode)

```elisp
(defun hermes-comint--paint-stream (state)
  (let* ((inhibit-read-only t)
         (stream (hermes-state-stream state))
         (turns  (hermes-state-turns state))
         (index  (1+ (length turns)))
         (msg    (hermes--message-from-stream stream nil)))
    (when stream
      (let ((out-end (marker-position hermes-comint--output-end))
            (pr-start (marker-position hermes-comint--prompt-start)))
        (delete-region out-end pr-start)
        (save-excursion
          (goto-char out-end)
          ;; Bench: prepend ephemeral content (rebuilds on every tick).
          (when hermes-comint--bench-p
            (when hermes-comint--current-user-prompt
              (hermes-comint-bench--insert-user-heading
               hermes-comint--current-user-prompt))
            (when hermes-comint--steer-messages
              (hermes-comint-bench--insert-steer-lines))
            (when hermes-comint--status-message
              (hermes-comint-bench--insert-status-line)))
          ;; Assistant turn (both modes).
          (hermes-comint--insert-turn msg index))))
    (hermes-comint--ensure-prompt-visible)))
```

## Tests

### `test/hermes-bench-test.el` — Rewrite

Rewrite to test the `hermes-comint-mode` bench implementation:

- `hermes-bench-ensure` creates a `hermes-comint-mode` buffer
- Buffer has `hermes-comint--bench-p = t`
- Buffer is named `*hermes-bench:<sid>*`
- Buffer is registered in `hermes--bench-buffers`
- `hermes-bench-ensure` returns existing buffer on repeat call
- `hermes-bench-active-p` resolves from org buffer, bench buffer, and sid
- `hermes-bench-active-p` returns nil for unrelated buffers
- `hermes-bench-hide` kills window, buffer, removes from registry
- Slash-command completion works in bench prompt
- History ring (M-p/M-n) works in bench buffer

### `test/hermes-comint-test.el` — Add bench mode tests

- Bench mode: `load-from-state` is no-op
- Bench mode: `append-new-turns` is no-op
- Bench mode: send stores user prompt and inserts heading
- Bench mode: paint-stream includes user heading + stream content
- Bench mode: stream commit deletes ephemeral region, does not advance output-end
- Bench mode: steer messages cleared on commit
- Bench mode: status message cleared on commit
- Full mode still works correctly alongside bench (no cross-contamination)

### `test/hermes-test-helpers.el` — No change

`hermes--bench-buffers` is still reset to a fresh hash table on test
teardown as before.  No new registry to add.

## Scope summary

| File | Action | Lines |
|------|--------|-------|
| `hermes-bench.el` | Delete | -606 |
| `hermes-comint.el` | Add bench-p flag, ephemeral functions, paint-stream mod, skin bg, bench API, slash-complete | +~160 |
| `Eldev` | Remove `hermes-bench.el` from main fileset | -1 |
| `hermes-state.el` | Simplify `--buffer-sid` (remove bench session-id branch) | -2 |
| `hermes-mode.el` | Remove `(require 'hermes-bench)`, update `hermes-bench-focus` impl | ~±5 |
| `hermes-render.el` | `declare-function` target: `"hermes-bench"` → `"hermes-comint"` | -1 |
| `hermes-org.el` | None (same function names) | 0 |
| `hermes-config.el` | None (same function names) | 0 |
| `hermes-image.el` | None (same function names) | 0 |
| `hermes-sessions.el` | None (same function names) | 0 |
| `hermes-evil.el` | None (same function names) | 0 |
| `hermes-transient.el` | None (same function names) | 0 |
| `AGENTS.md` | Update bench description | ~-10 |
| `test/hermes-bench-test.el` | Rewrite for comint-based bench | ~±30 |
| `test/hermes-comint-test.el` | Add bench mode tests | +~50 |
| **Net** | | **~-375** |

## Sequence

| Step | Action | Verify |
|------|--------|--------|
| 1 | Add `hermes-comint--bench-p` flag, buffer-local state vars, ephemeral insertion helpers to `hermes-comint.el` | `eldev compile` |
| 2 | Modify `hermes-comint--paint-stream` with bench-mode prepend path | `eldev compile` |
| 3 | Modify `hermes-comint-send`, `hermes-comint--stream-commit` with bench branches | `eldev compile` |
| 4 | Gate `hermes-comint--load-from-state`, `hermes-comint--append-new-turns`, `hermes-comint--refresh` on `(not bench-p)` | `eldev compile` |
| 5 | Add `hermes-bench-ensure`, `hermes-bench-active-p`, `hermes-bench-hide`, `hermes-bench-show-status`, `hermes-bench-add-steer`, `hermes-bench-bg-list` to `hermes-comint.el` | `eldev compile` |
| 6 | Add skin background support (`hermes-comint-bench--apply-bg` etc.) to `hermes-comint.el` | `eldev compile` |
| 7 | Add `hermes-comint-bench--detach`, slash-complete CAPF, bench keybindings | `eldev compile` |
| 8 | Remove `hermes--buffer-sid` bench branch in `hermes-state.el` | `eldev compile` |
| 9 | Remove `(require 'hermes-bench)` from `hermes-mode.el`; update `hermes-bench-focus` | `eldev compile` |
| 10 | Update `declare-function` target in `hermes-render.el` | `eldev compile` |
| 11 | Remove `"hermes-bench.el"` from Eldev main fileset | `eldev compile` |
| 12 | Delete `hermes-bench.el` | `eldev compile` |
| 13 | Update AGENTS.md | — |
| 14 | Rewrite `test/hermes-bench-test.el`; add bench tests to `test/hermes-comint-test.el` | `eldev test` |
| 15 | Manual smoke test: `M-x hermes` → bench appears → type prompt → stream renders → commit clears → repeat | — |

## What this plan does NOT cover

- Steering via bench (`C-c C-s`) — the bench's steer keybinding is dropped.
  `hermes-bench-add-steer` only *displays* steer messages the gateway pushes.

- The section viewer — already replaced by comint in plan 01.

- `hermes-render.el` bench dispatch — already removed in plan 20
  (the "extreme simplification" commit).

- History ring seeding from `hermes-state-history` — `comint-input-ring`
  starts fresh.  Can be added later by pushing `hermes-state-history`
  entries into the ring in reverse order on bench setup.

- Separator line — comint uses field-based prompt detection (no visible
  separator needed).

- Splash banner — already removed in plan 20.

## References

| What | Where |
|------|-------|
| Current bench (606 lines, pure input) | `hermes-bench.el` |
| Old bench (910 lines, ephemeral + input) | `git show 2b0101d^:hermes-bench.el` |
| Comint mode (848 lines, full history + input) | `hermes-comint.el` |
| Bench simplification plan (plan 20) | `git show 2b0101d:plans/20-simplify-bench.md` |
| Bench integration (ensure/focus/active-p) | `hermes-mode.el:287-465` |
| State registries | `hermes-state.el:167-174` |
| `hermes--maybe-kill-bench` | `hermes-state.el:364-374` |
| `hermes--buffer-sid` | `hermes-state.el:348-362` |
| Bench tests (14 tests) | `test/hermes-bench-test.el` |
| Comint tests | `test/hermes-comint-test.el` |
| Eldev main fileset | `Eldev` line 21 |
