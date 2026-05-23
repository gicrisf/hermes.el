# PLAN: hermes-section org-mode syntax highlighting

## 1. Motivation

Plan 08 gave the hermes-section viewer typed child sections and background
tinting.  Body text (assistant response, reasoning, tool output) is raw
markdown — readable, but visually flat.  `**bold**`, ```` ```python ````,
`` `code` `` all render as literal characters.

The Org renderer already has a pipeline that converts raw markdown to
Org syntax via `hermes-md-to-org`, then relies on `org-mode` font-lock
to render it.  This plan reuses that exact same pipeline for the section
viewer via the temp-buffer pattern (same mechanism Magit's
`git-commit-propertize-diff` uses for diffs).  The result: both viewers
show the same rendered text, fontified by the same engine.

## 2. Mechanism

```
raw markdown text (from segment content)
    → hermes-md-to-org (same conversion as the Org renderer)
    → with-temp-buffer
    → insert converted Org text
    → (org-mode)
    → font-lock-ensure
    → walk text props: face → font-lock-face
    → buffer-string (with properties)
    → insert into hermes-section buffer
```

`magit-section-mode` disables syntactic font-locking (`font-lock-defaults`
= `(nil t)`), so the `face` text property is ignored.  `font-lock-face` is
the escape hatch — it renders regardless of font-lock state.  Converting
`face` → `font-lock-face` is the standard Magit convention.

`org-mode` font-lock handles all Org syntax: `*bold*`, `/italic/`,
`~code~`, `[[url][text]]`, `#+begin_src python` (with
`org-src-fontify-natively` set to `t` for language-specific code
highlighting).  This is the same engine that renders the Org buffer.

## 3. Background tint interaction

**Body text drops the background tint.**  The heading line keeps the
bg-face (warm/cool band).  Body text has no background — only
`font-lock-face` from org-mode fontification.  This is a design choice
for simplicity and visual clarity: composing bg-face under
font-lock-face is technically possible but adds property-composition
complexity for marginal gain.  The heading band alone identifies the
writer.  Lateral fringe indicators (colored bars like diff-mode's
`+`/`-`) are deferred to a future plan.

**What changes from Plan 08:** body-insertion paths (`--insert-user-body`,
`--insert-lines`, reasoning/tool/subagent child body inserters) stop
applying bg-face.  Only the `magit-insert-heading` propertize call keeps
it.  The `---` / `───` separators and metadata lines (timestamp, model,
tokens, image placeholders) are body text and also lose the tint — they
render as plain default-background text alongside the fontified content.

## 4. What gets highlighted

**Body text only — never the heading.**  The heading line stays un-fontified
(Org markup characters in a single-line magit heading would look odd).

| Text location | Highlighted? |
|--------------|-------------|
| Assistant turn body (response text) | Yes |
| Reasoning child body | Yes |
| Tool `output` field | No — plain text; tool output is often code/JSON/command output, not markdown.  `hermes-md-to-org` rewrites characters (`*.py` → italic, underscores, backticks) which would mutate the displayed text vs what the tool actually returned.  Debugging integrity over aesthetics. |
| Tool `summary` field | No — same rationale as output |
| Tool `context` field | No — free-form gateway summary string, not markdown-bearing |
| User turn body | Yes |
| System turn body | Yes |
| Section headings (first-line labels) | No (also keep bg tint) |
| Subagent thinking/summary | Yes |

## 5. New function

```elisp
(defun hermes-section--fontify-org (text)
  "Return TEXT with font-lock-face properties from org-mode.
Pipes through `hermes-md-to-org' first, then fontifies via org-mode in a
temp buffer, converting face properties to font-lock-face (magit convention
for rendering in magit-section-mode where font-lock is off)."
  (with-temp-buffer
    (insert (hermes-md-to-org text))
    ;; org-src-fontify-natively must be let-bound BEFORE org-mode init,
    ;; since org-mode reads it when building org-font-lock-keywords.
    (let ((org-src-fontify-natively t))
      (delay-mode-hooks (org-mode))
      (font-lock-ensure))
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
`hermes-section--fontify-org`.  Body text does NOT carry the bg-face
— only `font-lock-face` from org-mode.  The heading line alone provides
the background tint distinguishing the writer.

```elisp
;; Assistant body — no bg-face, only org-mode font-lock
(insert (hermes-section--fontify-org
         (hermes-section--body-text msg)))

;; Reasoning child body
(insert (hermes-section--fontify-org c))

;; Tool body — plain text, no fontification
(insert (format "input: %s\n" context))
(insert (format "result: %s  (%.1fs)\n"
                (or output summary "(no result)")
                duration))

;; Subagent thinking/summary
(insert (hermes-section--fontify-org thinking))
(insert (hermes-section--fontify-org summary))
```

The heading line keeps bg tint, no fontification:

```elisp
;; Heading — bg tint, no font-lock
(magit-insert-heading
  (propertize (hermes-section--heading-text msg)
              'face (list heading-face bg-face)))
```

## 7. Dependency

No new dependency.  `hermes-md-to-org` is already required by
`hermes-render.el` and available project-wide.  `org-mode` is already
a project dependency.

## 8. Performance

Org-mode initialization is heavyweight even with `delay-mode-hooks`
(org-element, org-link, font-lock setup).  Cold first call: ~50–200ms.
Subsequent calls are faster (autoload caches), and the conversion runs
once per turn commit (not per delta tick), so it's off the hot path.

Worst case: a `g` refresh rebuilding 50 turns × multiple fontifiable
fields.  Should still complete within a few seconds — acceptable for a
manual refresh.

If profiling shows it stings: reuse a single hidden org-mode buffer
instead of `with-temp-buffer` per call (insert, fontify, extract,
erase).  Deferred to implementation — measure first.

## 9. Edge cases

| Case | Handling |
|------|----------|
| Empty text | No-op (empty string passes through) |
| `hermes-md-to-org` text mutation | Converts markdown characters (`**bold**` → `*bold*`, fenced code → `#+begin_src`, etc.), not just adds colors.  Applied only to fields known to be LLM-generated markdown (assistant body, reasoning, subagent thinking).  Tool output/summary/context are rendered plain to preserve what the tool actually returned. |
| Very long code blocks | Handled by `org-src-fontify-natively` |
| Text already contains Org markup (fork-from-org) | Since we run through `hermes-md-to-org`, raw Org markup in the segment will be double-encoded (Org `*bold*` → markdown interpreted literally).  Acceptable — fork-from-org is an edge path. |
| `delay-mode-hooks` suppressing font-lock setup | `org-mode` enables font-lock in its body, not via `run-mode-hooks`.  Trust-but-verify during implementation — if `font-lock-ensure` produces no faces, drop the `delay-mode-hooks` wrapper. |

## 10. Scope

`hermes-section.el` only.  One new function.  No new dependencies.
No Org renderer changes.  No state layer changes.  No tool formatters
dependency.
