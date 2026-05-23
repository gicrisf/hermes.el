# PLAN: hermes-section tool completeness (feat. Org formatter reuse)

## 1. Motivation

The section viewer's tool body was simplified — `input:` / `result:` only.
The Org renderer additionally showed context blocks, inline diffs, todos
tables, error blocks, and source blocks — all via `hermes-tool-formatters.el`.

Rather than building parallel plain-text formatters, this plan reuses the
EXACT same Org formatting engine.  The tool body in the section viewer is
now the fontified Org output from the same per-tool formatters the Org
renderer calls.

## 2. Design: reuse the formatters, fontify the output

### 2.1 The problem with building parallel formatters

The naive approach (Plan 14 v1 draft) was: write a plain-text todos table
renderer, a diff fontification pass, and manual `input:`/`result:` lines
in `hermes-section--insert-tool-child`.  This would duplicate the
column-mapping logic, the summary-generation logic, and the block-wrapping
logic already present in `hermes-tool-formatters.el`.

### 2.2 The solution: delegate entirely

`hermes-tool-formatters.el` defines a registry of `(tool-name → formatter-fn)`
functions.  Each returns a plist:

```elisp
(:summary STRING   ;; heading summary, e.g. "$ ls -la" or "Todos (3/5 done)"
 :body    STRING   ;; full Org markup body (context, output, diff, todos, error)
 :fold    BOOLEAN) ;; whether to auto-collapse on commit
```

The section viewer calls `hermes-tool--lookup` to get the formatter,
invokes it, and uses `:summary` for the heading and `:body` for the body.
The body — already valid Org markup — is fontified through a new
`hermes-section--fontify-as-org` function that handles Org tables,
source blocks, and all standard Org font-lock.

## 3. Implementation

### 3.1 New function: `hermes-section--fontify-as-org`

```elisp
(defun hermes-section--fontify-as-org (text)
  "Return TEXT (already valid Org) fontified with font-lock-face properties.
Enables org-mode in a temp buffer with org-src-fontify-natively
so embedded source blocks (e.g. #+begin_src diff) are fontified
by their language modes.  Converts face → font-lock-face for
magit-section-mode compatibility."
  (if (or (null text) (string-empty-p text))
      (or text "")
    (with-temp-buffer
      (insert text)
      (let ((org-src-fontify-natively t))
        (delay-mode-hooks (org-mode))
        ;; Align named hermes-tool tables before fontifying.
        ;; Matches the Org renderer's post-pass table alignment.
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward
                  "^#\\+name: hermes-tool-[^ \t\r\n]+[ \t]*$" nil t)
            (forward-line 1)
            (when (looking-at "^[ \t]*|")
              (ignore-errors (org-table-align)))))
        (font-lock-ensure))
      ;; Convert face → font-lock-face
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
      (buffer-string))))
```

Key details:
- `org-src-fontify-natively t` — let-bound before `org-mode` init so
  `#+begin_src diff` blocks get diff-mode fontification (colored +/-).
- `org-table-align` — pre-align named hermes-tool tables so the
  `| Status | Content | ID |` bodies render at proper column widths.
- `delay-mode-hooks` — prevents org-mode hooks from touching UI state
  in the temp buffer.
- `face` → `font-lock-face` — standard magit convention for rendering
  in a buffer where font-lock is disabled.

### 3.2 Refactored: `hermes-section--fontify-org`

Previously a monolithic function that converted markdown→Org and
fontified.  Now a thin two-line wrapper:

```elisp
(defun hermes-section--fontify-org (text)
  "Convert TEXT from markdown to Org and fontify."
  (hermes-section--fontify-as-org (hermes-md-to-org (or text ""))))
```

### 3.3 Refactored: `hermes-section--insert-tool-child`

Before — manual extraction of `context`, `output`, `summary`, `error`,
`inline-diff`, `todos` fields with hardcoded `input:`/`result:` lines.

After — delegates entirely to the formatter:

```elisp
(defun hermes-section--insert-tool-child (tool bg-face)
  (let* ((id         (or (hermes-tool-id tool) ...))
         (kw         (hermes-section--tool-status-keyword tool))
         (name       (or (hermes-tool-name tool) "tool"))
         (dur        (hermes-section--format-duration (hermes-tool-duration tool)))
         (status     (hermes-tool-status tool))
         (hide       (memq status '(complete error)))
         (formatter  (hermes-tool--lookup name))
         (parts      (and formatter (funcall formatter tool)))
         (fmt-summary (or (plist-get parts :summary) name))
         (gw-summary  (when-let ((s (hermes-tool-summary tool)))
                        (unless (string-empty-p s)
                          (format " — %s" s))))
         (body       (or (plist-get parts :body) "")))
    (magit-insert-section (hermes-section-tool-section id hide)
      (magit-insert-heading
        (propertize (car kw) 'font-lock-face (list (cdr kw) bg-face))
        (propertize (format " %s%s%s" fmt-summary dur (or gw-summary ""))
                    'font-lock-face (list 'hermes-section-face-tool bg-face)))
      (magit-insert-section-body
        (when (and body (> (length body) 0))
          (insert (hermes-section--fontify-as-org body))
          (unless (bolp) (insert "\n")))))))
```

## 4. What each formatter produces (→ what the section viewer shows)

Since the section viewer now delegates to the full formatter, every
tool type gets its complete Org markup body fontified:

| Tool | Formatter | Body contents |
|------|-----------|--------------|
| Bash | `hermes-tool-format-bash` | Context `#+begin_example` + `#+begin_src sh` output |
| Read | `hermes-tool-format-read` | Context `#+begin_example` + `#+begin_src <lang>` output |
| Write/Edit/MultiEdit | `hermes-tool-format-edit` | Context `#+begin_example` + named inline-diff block |
| Grep/Glob | `hermes-tool-format-grep` | Context `#+begin_example` + `#+begin_example` output |
| LS | `hermes-tool-format-ls` | Context `#+begin_example` + `#+begin_example` output |
| TodoWrite | `hermes-tool-format-todos` | Context `#+begin_example` + named `| [X] \| status \| id \| content \|` table |
| WebFetch/Search | `hermes-tool-format-web` | Context `#+begin_example` + `#+begin_example` output |
| Task/Agent | `hermes-tool-format-agent` | Context `#+begin_example` + `#+begin_example` output |
| Fallback | `hermes-tool-format-generic` | Context `#+begin_example` + output/error blocks |

All `#+begin_src diff` blocks get diff-mode fontification inside org-src
(red `-`, green `+`, blue `@@`).  All named tables are auto-aligned.
All `#+begin_example` blocks get org-block face.  The visual output
matches the Org buffer exactly.

## 5. Scope

`hermes-section.el` only.  Changes:

- New: `hermes-section--fontify-as-org` — fontifies already-valid Org text
- Refactored: `hermes-section--fontify-org` — thin wrapper around `--fontify-as-org`
- Refactored: `hermes-section--insert-tool-child` — delegates to formatter registry
- Removed: old manual `input:`/`result:`/`error:` extraction logic
- Removed: `hermes-section--tool-body` test helper (obsolete)

No new dependencies.  No Org renderer changes.  No state layer changes.
Tests: 406/406 green.
