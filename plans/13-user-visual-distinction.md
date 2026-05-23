# PLAN: user/assistant visual distinction + heading glyphs + autoscroll

## 1. Motivation

The current background tints for user (`#f0ebe3`) and assistant
(`#e8edf3`) differ by only ~2%, making sections hard to distinguish
at a glance.  User turns should be visually distinct — they are
"special" inputs, while assistant text is the default reading surface.
On top of the bg tint, swap the numeric `#` heading prefix for a
per-kind glyph (`>` user, `●` assistant) for instant scanning.

## 2. User bg tint bump

| Face | Light theme | Dark theme |
|------|------------|------------|
| `hermes-section-bg-user` | `#fcf7ef` (warm off-white) | `#45403b` |
| `hermes-section-bg-assistant` | `#e8edf3` (unchanged) | `#2e3640` (unchanged) |

User background is a warm cream clearly lighter than the assistant
cool blue-grey.  Dark theme values are also bumped for parity.

### 2.1 `:extend t` is required

Without `:extend t`, a face's `:background` only paints the actual
heading text characters, not the rest of the screen line.  On a dark
theme the tint is then invisible.  All three bg faces (`bg-user`,
`bg-assistant`, `bg-system`) carry `:extend t`.

### 2.2 Head-faces must not `:inherit default`

`hermes-section-face-{user,assistant,system}` previously inherited
`default`.  `default`'s `:background` (= frame bg) then masked the
`bg-face`'s `:background` because face-list merging takes the first
specifier wins per-attribute.  The head-faces are now bare
(`:weight normal`), with no `:inherit`, so `bg-face` actually applies.

### 2.3 Heading propertize uses both `face` and `font-lock-face`

`magit-insert-heading` says: "If the `face` property is set anywhere
inside any of these strings, then insert all of them unchanged.
Otherwise use the `magit-section-heading` face for all inserted text."
We set both `face` and `font-lock-face` so (a) magit-section doesn't
overlay its own face and (b) rendering is correct regardless of
`font-lock-defaults`.

## 3. Heading glyphs

Replace the numeric `#N` prefix with a per-kind glyph followed by the
turn number:

| Turn kind | Format |
|-----------|--------|
| User | `"> 1 · User · 14:32"` |
| Assistant (with text) | `"● 2 · Assistant · deepseek-v4-flash · 14:32"` |
| Assistant (tool-only) | `"● 2 · Assistant · (tool-only) · 14:32"` |
| System | `"#4 · System · 14:32"` (unchanged; system turns excluded from `turns`) |

## 4. Autoscroll on turn commit

hermes-section does a full `erase-buffer` + rebuild on turn commit
(via `hermes-section--refresh`).  When the user is viewing the tail of
the conversation and a new turn arrives, they should stay at the tail.

Same pattern as the Org renderer (`hermes-render.el` lines 214–218,
336–340): snapshot which windows are at `point-max` before the rebuild,
then advance them to the new `point-max` after.

```elisp
;; In hermes-section--refresh, around the --rebuild call:
(let ((tail-windows nil))
  (dolist (win (get-buffer-window-list (current-buffer) nil t))
    (when (= (window-point win) (point-max))
      (push win tail-windows)))
  (hermes-section--rebuild new)
  (dolist (win tail-windows)
    (when (window-live-p win)
      (set-window-point win (point-max)))))
```

Only windows that were already at the tail scroll — if the user scrolled
up to read earlier content, they stay where they are.  Stream deltas are
not affected (hermes-section does not handle streaming).

## 5. Dropped: fringe indicator

An earlier revision of this plan proposed a left-fringe `filled-rectangle`
overlay on user headings, with a terminal fallback via `before-string`.
Dropped: the bg tint contrast (§2) is sufficient on its own, and the
fringe overlay's display spec never rendered reliably across themes.

## 6. Scope

`hermes-section.el` only.  Changes:
- Three `bg-*` faces gain `:extend t`; user bg values bumped.
- Three head-faces lose `:inherit default`; left as `:weight normal`.
- Heading propertize in `--insert-turn` sets both `face` and `font-lock-face`.
- `--heading-text` uses `>` (user), `●` (assistant), `#` (system) glyph prefix.
- `--refresh` snapshots tail windows and restores them to `point-max` after rebuild.

Tests updated: `heading-text-*` and `rebuild-shows-turns` assertions
match the new glyph prefixes.
