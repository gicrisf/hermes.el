# PLAN 25: Inline image rendering in comint/bench via `insert-image`

## Motivation

The org buffer renders user-attached images as `#+attr_org:` + `[[file:PATH]]`
org links with `org-display-inline-images`.  The comint/bench area currently
shows `[image: name]` plain-text placeholders (`hermes-comint--image-lines`,
line 141–155 of `hermes-comint.el`).  The image segment plist carries
`:path`, `:name`, `:width`, `:height`, `:token-estimate` — enough to render
real images.

Since plan 24 moved all status to the bench, the comint/bench is the primary
UI surface.  Visual parity with the org buffer for images is a natural next
step.

## Goal

Render attached images inline in the comint/bench area using Emacs'
`create-image` + `insert-image` (native image display, no org dependency).
On terminal or non-graphical displays, fall back to the existing `[image:
name]` text placeholder.

No org syntax (`#+attr_org:`, `[[file:...]]`) in the comint buffer — just
the rendered image.

Clickability: `RET` on a rendered image visits the file via `find-file`,
matching the affordance of org's `[[file:PATH]]` links.  A `keymap` text
property on the image span maps `RET` → `find-file PATH`.

## Approach: `create-image` + `insert-image`

`create-image` and `insert-image` are Emacs built-ins (available since
Emacs 23, no external dependency).  They insert an image as a `display`
text property — works in any buffer, any major mode.  The image data is
read from the file path in the segment plist.

Scaling reuses `hermes--image-display-dims` from `hermes-org-render.el`
(line 938) — no duplication, no new file.  A `declare-function` in
`hermes-comint.el` references it:

    (declare-function hermes--image-display-dims "hermes-org-render" (width height))

## Design

### Image insertion functions

`hermes-comint--insert-image-segment` (singular, takes one segment):
```elisp
(defun hermes-comint--insert-image-segment (seg)
  "Insert the image described by segment SEG as an inline image.
SEG's content is a plist with :path, :name, :width, :height, :token-estimate.
On graphical displays, renders via `insert-image' with dimensions capped at
`hermes-image-display-max-dim'.  On terminals or when the file is missing,
falls back to `[image: name]' placeholder text.
A `keymap' property on the image span binds RET to `find-file' on PATH."
  (let* ((c    (hermes-segment-content seg))
         (path (and (listp c) (plist-get c :path)))
         (name (or (and (listp c) (plist-get c :name))
                   (and path (file-name-nondirectory path))
                   "image")))
    (if (and (display-graphic-p) path (file-readable-p path))
        (let* ((w    (and (listp c) (plist-get c :width)))
               (h    (and (listp c) (plist-get c :height)))
               (dims (hermes--image-display-dims w h))
               (img  (apply #'create-image path nil nil
                            (if dims
                                (list :width (car dims) :height (cdr dims))
                              nil))))
          (insert-image img (or name path))
          (put-text-property (1- (point)) (point) 'keymap
                             (let ((km (make-sparse-keymap))
                                   (p path))
                               (define-key km (kbd "RET")
                                 (lambda () (interactive) (find-file p)))
                               km))
          (insert "\n"))
      (insert (format "[image: %s]\n" name)))))
```

`hermes-comint--insert-image-segments` (plural, iterates over a message):
```elisp
(defun hermes-comint--insert-image-segments (msg)
  "Insert inline images for all image segments in MSG.
Images come first (matching the org buffer's [image…, text] ordering)."
  (let ((segs (hermes-message-segments msg)))
    (when (vectorp segs)
      (dotimes (i (length segs))
        (let ((seg (aref segs i)))
          (when (eq 'image (hermes-segment-type seg))
            (hermes-comint--insert-image-segment seg)))))))
```

### Image ordering: images before text

The org buffer inserts image segments first, then text (comment at
`hermes-org-render.el:538`: "Insert image segments first (matching the
reducer's [image…, text] ordering for user turns)").

The comint buffer currently does the opposite — text first
(`hermes-comint--insert-full-text`), then `[image: name]` placeholders
after.  This plan fixes the ordering to match.

## Changes by file

### `hermes-comint.el`

1. **Add `declare-function`** for `hermes--image-display-dims` from
   `hermes-org-render` (alongside the existing declare-function block).

2. **Replace `hermes-comint--image-lines`** (lines 141–155) with:
   - `hermes-comint--insert-image-segment` — per-segment image renderer
     (calls `hermes--image-display-dims` from hermes-org-render).
   - `hermes-comint--insert-image-segments` — iterate over all image
     segments in a message.

3. **Fix image ordering in `hermes-comint--insert-user-body`** (lines 414–417):

   Before (text first, images after):
   ```elisp
   (defun hermes-comint--insert-user-body (msg)
     (hermes-comint--insert-full-text msg)
     (dolist (line (hermes-comint--image-lines msg))
       (insert line "\n")))
   ```

   After (images first, text after — matching org buffer):
   ```elisp
   (defun hermes-comint--insert-user-body (msg)
     (hermes-comint--insert-image-segments msg)
     (hermes-comint--insert-full-text msg))
   ```

4. **No change to `hermes-comint--insert-assistant-body`**:
   per review — don't design for hypothetical future requirements.
   Add image handling when assistants actually emit image segments.

5. **No change to bench ephemeral prelude**: the bench renders only
   in-flight ephemeral content (user prompt text, steer, status,
   assistant stream).  It never shows committed turns — images are
   committed-only.  This change affects non-bench comint buffers
   (full viewer / comint-only mode).

6. **No change to streaming** (`hermes-comint--paint-stream`,
   `hermes-comint--stream-update`, etc.): streaming goes through
   `hermes-comint--insert-turn` → body inserters.  Images in committed
   turns render when appended via `hermes-comint--append-new-turns`
   in the full viewer.

### Tests

7. **Add tests** in `test/hermes-comint-test.el`:
   - `hermes-comint-test/image-fallback-terminal` — with
     `display-graphic-p` let-bound to nil, output contains
     `[image: name]\n` before the user text (verifies fallback path
     and the ordering fix).

   Scaling tests are not needed — `hermes--image-display-dims` is not
   duplicated and already tested in `test/hermes-org-render-test.el`.

## Files touched

| File | Lines changed | Nature |
|------|---------------|--------|
| `hermes-comint.el` | ~+40 / −15 | Replace `hermes-comint--image-lines`, add insert-image-segment(s), fix ordering in user body, add declare-function, add keymap |
| `test/hermes-comint-test.el` | ~+15 / −0 | Fallback-path test verifying ordering and [image: name] output |

## Edge cases

- **Terminal/non-graphical display**: `display-graphic-p` returns nil →
  fallback to `[image: name]` text.  Same behavior as today.

- **File not found / not readable**: `file-readable-p` returns nil →
  fallback to `[image: name]` text.

- **Missing dimensions**: `hermes--image-display-dims` returns nil →
  `create-image` is called without `:width`/`:height`, using natural
  size.  Gateway always provides dimensions for attached images, so
  this is a defensive fallback.

- **Very large images**: scaling caps the longest side at
  `hermes-image-display-max-dim` (default 600px).

- **Multiple images in one turn**: each `insert-image` call inserts a
  newline after the image.  Multiple images stack vertically.

- **Bench never renders committed turns**: `hermes-comint--bench-p = t`
  only shows ephemeral in-flight content.  Committed user/assistant
  turns (including images) live in the paired org buffer.  This change
  affects non-bench comint buffers only (full viewer / comint-only mode).

- **Clickability**: `RET` on a rendered image opens the file via
  `find-file`.  Available on images only — terminal fallback text
  has no special keybinding.

## Not in scope

- Rendering images during streaming (images are committed, not streamed).
- Org-syntax `#+attr_org:` / `[[file:...]]` in the comint buffer.
- SVG, PDF, or other non-raster image formats (handled by Emacs'
  `create-image` transparently if support is compiled in).
- Image pasting from clipboard — that's `hermes-image.el` territory.
- Assistant-body image pass — added when assistants emit image segments.
