# PLAN: hermes-section inline input area

## 1. Motivation

Currently, the section viewer requires `M-x hermes-send` (minibuffer) or
the bench for user input.  A conversation viewer should have a built-in
prompt line at the bottom — like the classical TUI or the bench, but
integrated directly into the section buffer.

## 2. Constraint: magit-section does `erase-buffer` on rebuild

Every commit triggers `hermes-section--rebuild` → `erase-buffer` + full
section tree re-insertion.  No content can survive across rebuilds except
state stored outside the buffer.

**Solution:** re-insert the input area at `(point-max)` after every
rebuild.  The input text lives in a buffer-local variable that survives
`erase-buffer`.  To the user, the input area is always at the bottom.

## 3. Visual layout

```
● 100 · Assistant · deepseek-v4-flash · 14:52
  Sure, 2+2 is 4.

> █                              ← editable input area
```

- Fixed at buffer bottom (always `(point-max)`)
- `>` prompt prefix, followed by the input text
- One editable field (not multi-line in v1; use `C-c C-l` for composer)
- Same width as the section content above
- No background tint (neutral)

After send: input clears, prompt reappears empty.  After rebuild: same
content restored, cursor position preserved.

## 4. Implementation

### 4.1 Buffer-local state

```elisp
(defvar-local hermes-section--input-text ""
  "Current text in the section-buffer input area.
Survives erase-buffer because it's buffer-local, not buffer content.")
```

### 4.2 Input area insertion

```elisp
(defun hermes-section--insert-input-area ()
  "Insert the editable input area at point (always point-max after rebuild)."
  (let ((start (point)))
    (insert "> ")
    (let ((field-start (point)))
      (insert hermes-section--input-text)
      (put-text-property field-start (point) 'field 'hermes-section-input)
      (insert "\n"))))
```

Called from `--rebuild` and `--stream-commit` after the section tree is
built and point is at `(point-max)`.

### 4.3 Send on RET

```elisp
(defun hermes-section-send ()
  "Send the input area content to the session."
  (interactive)
  (let ((text (hermes-section--input-text)))
    (unless (string-empty-p text)
      (hermes-send text hermes--current-session-id)
      (setq hermes-section--input-text ""))))
```

Bound to `RET` in the mode keymap.  The `field` text property ensures
RET only fires when point is inside the input area — elsewhere it falls
through to `hermes-section-inspect-turn-at-point`.

### 4.4 Interrupt

```elisp
(define-key m (kbd "C-c C-k") #'hermes-interrupt-current-session)
```

Same binding as bench/org.  Bound in `hermes-section-mode-map` (already
present at line 851).

### 4.5 History

Shared with `hermes-input.el`'s history ring.  On send, push the text
to `hermes-state-history` (same as `hermes-send` already does via
`hermes--state-slot-write`).  Readline history (M-p / M-n) reuses the
existing `hermes-input.el` completion mechanism via `completion-at-point`.

### 4.6 Keymap

Add to `hermes-section-mode-map`:

```elisp
(define-key m (kbd "RET") #'hermes-section-send)
```

`RET` only fires when point is in the `hermes-section-input` field
(via `field` text property).  Existing `RET` binding for
`hermes-section-inspect-turn-at-point` stays for non-input regions.

### 4.7 Focus on open

When the section buffer is opened or gets focus, auto-move point to
the input area.  `C-c C-i` (same as bench) also jumps to the input area.

## 5. Integration with rebuild

`--rebuild` appends after the section tree:

```elisp
(defun hermes-section--rebuild (state)
  ...
  (erase-buffer)
  (magit-insert-section (hermes-section-turn-section nil) ...)
  (when magit-root-section
    (magit-section-show magit-root-section))
  (goto-char (point-max))
  (hermes-section--insert-input-area)
  (goto-char (point-max)))
```

`--stream-commit` → `--rebuild` → input area re-inserted.

`--stream-commit` calls `--rebuild-keeping-tail` which calls `--rebuild`.
Input text survives because it's in a buffer-local variable, not in the
erased buffer content.

## 6. Edge cases

| Case | Handling |
|------|----------|
| Empty input, press RET | No-op |
| Input text contains newlines | Not possible (single-line field); use `C-c C-l` for composer |
| Buffer not focused | Input area is passive; no auto-focus steal |
| Streaming in progress | Input area present but send is a no-op (state is busy) |
| Slash commands | `completion-at-point` from hermes-input.el |

## 7. Scope

`hermes-section.el` only.  One buffer-local variable, two new functions
(`--insert-input-area`, `hermes-section-send`), one keybinding addition,
two call-site amendments (`--rebuild`, `--stream-commit`).  ~20 new lines.
