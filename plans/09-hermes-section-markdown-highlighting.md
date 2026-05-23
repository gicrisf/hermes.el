# PLAN: hermes-section markdown syntax highlighting

## 1. Motivation

Plan 08 gave the hermes-section viewer typed child sections and background
tinting.  Body text (assistant response, reasoning, tool output) is raw
markdown — readable, but visually flat.  `**bold**`, ```` ```python ````,
`` `code` `` all render as literal characters.

`markdown-mode` has a mature font-lock grammar that handles every markdown
construct: emphasis, inline code, fenced code blocks with language-specific
syntax highlighting, links, headings, blockquotes.  Using it as an
off-the-shelf fontifier via the temp-buffer pattern (same mechanism Magit's
`git-commit-propertize-diff` uses for diffs) gives us all of that for free.

## 2. Mechanism

```
raw markdown text
    → with-temp-buffer
    → insert text
    → (markdown-mode)
    → font-lock-ensure
    → walk text props: face → font-lock-face
    → buffer-string (with properties)
    → insert into hermes-section buffer
```

`magit-section-mode` disables syntactic font-locking (`font-lock-defaults`
= `(nil t)`), so the `face` text property is ignored.  `font-lock-face` is
the escape hatch — it renders regardless of font-lock state.  Converting
`face` → `font-lock-face` is the standard Magit convention.

## 3. Background tint interaction

**Body text drops the background tint.**  The heading line keeps the
bg-face (warm/cool band).  Body text has no background — only markdown
font-lock colors.  This is a design choice for simplicity and visual
clarity: composing bg-face under font-lock-face is technically possible
but adds property-composition complexity for marginal gain.  The heading
band alone identifies the writer.  Lateral fringe indicators (colored
bars like diff-mode's `+`/`-`) are deferred to a future plan.

**What changes from Plan 08:** body-insertion paths (`--insert-user-body`,
`--insert-lines`, reasoning/tool/subagent child body inserters) stop
applying bg-face.  Only the `magit-insert-heading` propertize call keeps
it.  The `---` / `───` separators and metadata lines (timestamp, model,
tokens, image placeholders) are body text and also lose the tint — they
render as plain default-background text alongside the markdown-highlighted
content.

## 4. What gets highlighted

**Body text only — never the heading.**  The heading line stays un-fontified
(raw markdown characters in a single-line magit heading would look odd).

| Text location | Highlighted? |
|--------------|-------------|
| Assistant turn body (response text) | Yes |
| Reasoning child body | Yes |
| Tool `output` field | Yes |
| Tool `summary` field | Yes |
| Tool `context` field | No — free-form gateway summary string, not markdown-bearing |
| User turn body | Yes |
| System turn body | Yes |
| Section headings (first-line labels) | No (also keep bg tint) |
| Subagent thinking/summary | Yes |

## 5. New function

```elisp
(defun hermes-section--fontify-markdown (text)
  "Return TEXT with font-lock-face properties from `markdown-mode'."
  (with-temp-buffer
    (insert text)
    ;; delay-mode-hooks prevents run-mode-hooks from firing hooks that
    ;; might initialize UI state in the temp buffer.  markdown-mode
    ;; sets up font-lock in its body (not via a hook), so font-lock is
    ;; still active.  Verify during implementation that deferring hooks
    ;; doesn't suppress font-lock-keywords setup.
    (delay-mode-hooks (markdown-mode))
    (font-lock-ensure)
    ;; Convert face → font-lock-face (magit convention for rendering
    ;; in magit-section-mode where font-lock is off).
    (let ((pos (point-min)))
      (while (< pos (point-max))
        (let* ((next (or (next-single-property-change
                          pos 'face nil (point-max))
                         (point-max)))
               (val (get-text-property pos 'face)))
          (when val
            (put-text-property pos next 'font-lock-face val)
            (remove-text-properties pos next '(face nil)))
          (setq pos next))))
    (buffer-string)))
```

## 6. Integration

Every text-insertion point in the section body wrappers pipes through
`hermes-section--fontify-markdown`.  Body text does NOT carry the bg-face
— only `font-lock-face` from markdown-mode.  The heading line alone
provides the background tint distinguishing the writer.

```elisp
;; Assistant body — no bg-face, only markdown font-lock
(insert (hermes-section--fontify-markdown
         (hermes-section--body-text msg)))

;; Reasoning child body
(insert (hermes-section--fontify-markdown c))

;; Tool output body
(insert (hermes-section--fontify-markdown
         (or output summary "(no result)")))

;; Subagent thinking/summary
(insert (hermes-section--fontify-markdown thinking))
(insert (hermes-section--fontify-markdown summary))
```

The heading line keeps bg tint, no fontification:

```elisp
;; Heading — bg tint, no markdown font-lock
(magit-insert-heading
  (propertize (hermes-section--heading-text msg)
              'face (list heading-face bg-face)))
```

## 7. Dependency

`markdown-mode` (MELPA).  Hard dependency — add to `Package-Requires` in
`hermes-section.el`:

```elisp
;; Package-Requires: ((emacs "27.1") (magit-section "3.0") (markdown-mode "2.6"))
```

No runtime guard.  If `markdown-mode` fails to load, the package fails
loudly (standard Emacs behavior for missing hard deps).

## 8. Performance

`font-lock-ensure` on a fresh temp buffer is fast (<1ms for typical
response sizes).  Markdown responses can be large, but the conversion is
done once per turn commit (not per delta tick), so it's off the hot path.

Worst case: a 20KB response loaded from state during rebuild.  Still
sub-10ms.  No throttle needed.

## 9. Edge cases

| Case | Handling |
|------|----------|
| Empty text | No-op (empty string passes through) |
| Very long code blocks inside markdown | Handled by `markdown-mode`'s own font-lock |
| Tool output is plain text/JSON, not markdown | Spurious markdown emphasis on stray `*`/`_`/backticks is possible.  Known limitation — acceptable for v1.  Could add per-tool opt-out or content sniffing later. |
| Text already contains Org markup (fork-from-org) | Rare.  `markdown-mode` may mis-fontify Org syntax.  Acceptable — fork-from-org is an edge path. |
| `delay-mode-hooks` suppressing font-lock setup | `markdown-mode` enables font-lock in its body, not via `run-mode-hooks`.  Trust-but-verify during implementation — if `font-lock-ensure` produces no faces, drop the `delay-mode-hooks` wrapper. |

## 10. Scope

`hermes-section.el` only.  One new function.  One new package dependency.
No Org renderer changes.  No state layer changes.  No tool formatters
dependency.
