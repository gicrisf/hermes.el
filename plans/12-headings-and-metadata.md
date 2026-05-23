# PLAN: user-turn cleanup + timestamps + word wrap

## 1. Motivation

Six issues with the current hermes-section viewer (two already resolved):

**A. Unfold user turns.**  With numbered headings (`#1 · User`), there's
no reason to auto-collapse user messages — the heading is always a short
label.  Collapsed user turns hide the question text behind an extra TAB
press with no benefit.

**B. Strip user body metadata.**  The `---` separator and metadata lines
(timestamp, model, tokens) in the user body add visual noise.  The model
is already in the assistant heading; the timestamp is moving into the
heading; tokens are internal detail.

**C. HH:MM in all headings.**  Every turn has a timestamp — it should
appear in the heading for temporal orientation through the conversation.

**D. Subtle heading faces.**  The heading is a label, not the content.
The bg tint already distinguishes writers.  Turn-level heading faces
lose their semantic face inheritance and become subdued.

**E. `face` → `font-lock-face` bug.**  `magit-section-mode` sets
`font-lock-defaults` to `(nil t)` — the `t` means it only renders the
`font-lock-face` text property and ignores plain `face`.  Every heading
uses `'face` instead of `'font-lock-face`, so nothing renders.

**F. Word wrapping.**  `magit-section-mode` inherits from `special-mode`,
which truncates lines at the window edge.  Response text and tool output
should wrap naturally like in org-mode.  Fix: enable `visual-line-mode`
in `hermes-section-mode` setup.

## 2. Heading format

| Turn kind | Format |
|-----------|--------|
| User | `"#1 · User · 14:32"` |
| Assistant (with text) | `"#2 · Assistant · deepseek-v4-flash · 14:32"` |
| Assistant (tool-only) | `"#2 · Assistant · (tool-only) · 14:32"` |
| System | unreachable — `turns` excludes system messages |

Timestamp parsed from `hermes-message.timestamp` (ISO 8601 string) via
`(format-time-string " · %H:%M" (date-to-time ts))` inside `ignore-errors`
to guard against malformed timestamps from older or fork-imported messages.
No `HH:MM` appended when timestamp is nil or unparseable.

## 3. Unfold user turns

The fold is set at `hermes-section--insert-turn` (line 490) via a
kind-based branch:

```elisp
(hide (eq kind 'user))
```

Drop the branch — all turn sections stay expanded:

```elisp
;; Replace (hide (eq kind 'user)) with:
(hide nil)
```

## 4. Strip user body metadata

`hermes-section--insert-user-body` (line 289) currently inserts full text,
then optionally a `---` separator followed by timestamp, model, tokens,
and images.  After this plan:

```elisp
(defun hermes-section--insert-user-body (msg bg-face)
  (hermes-section--insert-full-text msg bg-face)
  (let ((imgs (hermes-section--image-lines msg)))
    (when imgs
      (hermes-section--insert-lines imgs bg-face))))
```

The `heading` parameter was already dropped in Plan 11 §2.3.  Only images
remain in the body.

## 5. HH:MM in headings

`hermes-section--heading-text` (Plan 11 §2.3) gains a timestamp suffix:

```elisp
(defun hermes-section--heading-text (msg index)
  "Return turn-number heading for MSG at 1-based INDEX."
  (let* ((kind (hermes-message-kind msg))
         (ts   (hermes-message-timestamp msg))
         (time (and ts
                     (ignore-errors
                       (format-time-string "%H:%M" (date-to-time ts))))))
    (pcase kind
      ('user (concat (format "#%d · User" index)
                     (and time (concat " · " time))))
      ('assistant
       (let ((has-text (hermes-section--has-segment-type-p msg 'text)))
         (concat
          (if has-text
              (format "#%d · Assistant · %s" index
                      (or (hermes-section--session-model
                           hermes--current-session-id)
                          "?"))
            (format "#%d · Assistant · (tool-only)" index))
          (and time (concat " · " time)))))
      (_ (concat (format "#%d · System" index)
                 (and time (concat " · " time)))))))
```

## 6. Subtle heading faces  ✓ done (no code change needed)

Turn-level heading faces already use `:inherit default :weight normal
:height 0.9` (lines 33–43).

## 7. Bug fix: `face` → `font-lock-face`  ✓ done (no code change needed)

All six call sites already use `'font-lock-face`.

## 8. Word wrapping

`magit-section-mode` inherits from `special-mode`, defaulting to line
truncation.  Enable `visual-line-mode` in `hermes-section-mode` so
response text and tool output wrap at the window margin:

```elisp
(visual-line-mode 1)
```

## 9. Scope

`hermes-section.el` only.  Remaining changes:
- `hermes-section--insert-turn` line 490: drop `(hide (eq kind 'user))`
- `hermes-section--insert-user-body`: drop metadata block
- `hermes-section--heading-text`: append ` · HH:MM` timestamp
- `hermes-section-mode` setup: `(visual-line-mode 1)`

**Test impact:** user body assertions lose metadata lines.  Heading-text
assertions gain ` · HH:MM` suffix.  `eldev test` will catch all.
