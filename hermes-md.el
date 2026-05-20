;;; hermes-md.el --- Best-effort markdown → Org conversion -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; `hermes-md-to-org' converts a chunk of markdown to Org syntax.  It is
;; designed to run on a STABLE chunk — text that has crossed a `\n\n'
;; boundary outside fenced code — so block constructs (fences, tables,
;; headings) are fully contained.  Anything it doesn't recognise falls
;; through as-is.
;;
;; The pipeline:
;;   1. Convert fenced code blocks (``` … ```) to #+begin_src / #+begin_example.
;;      The body of every fence is marked with a `hermes-md-protected'
;;      text property so subsequent passes leave it alone.
;;   2. Convert table separator rows `|---|---|' to `|---+---|'.
;;   3. Demote ATX headings (# → **, ## → ***, …) so they live inside the
;;      assistant's `*' headline.
;;   4. Inline rewrites: **bold** → *bold*, `code` → ~code~, [l](u) → [[u][l]],
;;      *em*/_em_ → /em/.
;;
;; Failure mode is benign: a missing close-fence leaves the open fence
;; in the output as plain text; an unmatchable inline pattern stays raw.

;;; Code:

(require 'subr-x)
(require 'ansi-color)

(defun hermes-md-to-org (s)
  "Return Org-syntax version of markdown string S.  Best-effort, single-pass."
  (if (or (null s) (string-empty-p s))
      (or s "")
    (with-temp-buffer
      (insert s)
      (hermes-md--convert-fences)
      (hermes-md--convert-bullets)
      (hermes-md--convert-tables)
      (hermes-md--convert-headings)
      (hermes-md--inline-bold)
      (hermes-md--inline-code)
      (hermes-md--inline-links)
      (hermes-md--inline-italics-star)
      (hermes-md--inline-italics-underscore)
      (hermes-md--guardrail-escape-headings)
      (remove-text-properties (point-min) (point-max)
                              '(hermes-md-protected nil))
      (buffer-string))))

;;;; Helpers

(defsubst hermes-md--protected-p (pos)
  "Non-nil if POS lies inside a fenced code body (per text property)."
  (get-text-property pos 'hermes-md-protected))

(defun hermes-md--inline-replace (regexp replacement)
  "Replace REGEXP with REPLACEMENT, skipping any match that overlaps a
protected region.  `text-property-any' scans the entire match range so
bold-protected interior asterisks shield single-`*' italic patterns."
  (goto-char (point-min))
  (while (re-search-forward regexp nil t)
    (unless (text-property-any (match-beginning 0) (match-end 0)
                               'hermes-md-protected t)
      (replace-match replacement t nil))))

;;;; Fences

(defun hermes-md--convert-fences ()
  "Replace fenced code blocks with Org src/example blocks; mark bodies protected.
Tick-counting opener (≥3 ticks, tolerant of leading whitespace), closer
requiring at least the same tick count (CommonMark rule, enables nesting),
and auto-close on EOF for unmatched openers.  Tick-counting pattern adapted
from `gptel--stream-convert-markdown->org' in gptel-org.el (karthink/gptel)."
  (goto-char (point-min))
  (while (re-search-forward "^[ \t]*\\(`\\{3,\\}\\)\\([^\n]*\\)$" nil t)
    (let* ((tick-count (length (match-string 1)))
           (lang (string-trim (or (match-string 2) "")))
           (open-beg (match-beginning 0))
           (open-end (match-end 0))
           (header (if (string-empty-p lang)
                       "#+begin_example"
                     (format "#+begin_src %s" lang)))
           (footer (if (string-empty-p lang) "#+end_example" "#+end_src"))
           (close-regexp (format "^[ \t]*`\\{%d,\\}[ \t]*$" tick-count)))
      (delete-region open-beg open-end)
      (goto-char open-beg)
      (insert header)
      (let ((body-start (point)))
        (if (re-search-forward close-regexp nil t)
            (let ((close-beg (match-beginning 0))
                  (close-end (match-end 0)))
              (delete-region close-beg close-end)
              (goto-char close-beg)
              (ansi-color-filter-region body-start (point))
              (insert footer)
              (put-text-property body-start (point)
                                 'hermes-md-protected t))
          ;; No closing fence — auto-close at EOF so the Org buffer
          ;; structure is never left dangling.
          (goto-char (point-max))
          (unless (bolp) (insert "\n"))
          (ansi-color-filter-region body-start (point))
          (insert footer "\n")
          (put-text-property body-start (point)
                             'hermes-md-protected t))))))

;;;; Bullets

(defun hermes-md--convert-bullets ()
  "Convert markdown bullet markers (`*' or `+' followed by whitespace) to `-'.
Single-star bullets only; `**' is not a bullet.  Skips protected (fenced)
regions.  Pattern adapted from `gptel--stream-convert-markdown->org' in
gptel-org.el (karthink/gptel)."
  (goto-char (point-min))
  (while (re-search-forward "^\\([ \t]*\\)\\([*+]\\)\\([ \t]\\)" nil t)
    (unless (hermes-md--protected-p (match-beginning 0))
      (replace-match "\\1-\\3" t nil))))

;;;; Tables

(defun hermes-md--convert-tables ()
  "Convert markdown table separators (|---|---|) to Org form (|---+---|)."
  (goto-char (point-min))
  (while (re-search-forward "^|\\([-:| \t]+\\)|[ \t]*$" nil t)
    (when (and (not (hermes-md--protected-p (match-beginning 0)))
               (string-match-p "---" (match-string 1)))
      (let ((lb (line-beginning-position))
            (le (line-end-position)))
        (save-excursion
          (save-restriction
            (narrow-to-region lb le)
            (goto-char (point-min))
            (forward-char 1)
            ;; Replace every internal `|' with `+', leaving the outer ones.
            (while (and (< (point) (1- (point-max)))
                        (search-forward "|" (1- (point-max)) t))
              (replace-match "+" t t))))))))

;;;; Headings

(defun hermes-md--convert-headings ()
  "Demote ATX headings (#, ##, …) to Org subheadlines.
`#' becomes `****' so md headings nest inside the assistant turn's
`*** Response' heading rather than colliding with it as a sibling."
  (goto-char (point-min))
  (while (re-search-forward "^\\(#+\\)[ \t]+" nil t)
    (unless (hermes-md--protected-p (match-beginning 0))
      (let ((n (length (match-string 1))))
        (replace-match (concat (make-string (+ 3 n) ?*) " ") t t)))))

;;;; Inline

(defun hermes-md--inline-bold ()
  "Convert **bold** to *bold*.
The replacement is marked `hermes-md-protected' so the italic pass —
which would otherwise see `*bold*' and rewrite it to /bold/ — leaves
it alone."
  (goto-char (point-min))
  (while (re-search-forward "\\*\\*\\([^*\n][^*\n]*?\\)\\*\\*" nil t)
    (unless (hermes-md--protected-p (match-beginning 0))
      (let ((inner (match-string 1))
            (beg (match-beginning 0)))
        (replace-match (concat "*" inner "*") t t)
        (put-text-property beg (+ beg (length inner) 2)
                           'hermes-md-protected t)))))

(defun hermes-md--inline-code ()
  "Convert `code` to ~code~."
  (hermes-md--inline-replace
   "`\\([^`\n]+\\)`" "~\\1~"))

(defun hermes-md--inline-links ()
  "Convert [label](url) to [[url][label]]."
  (hermes-md--inline-replace
   "\\[\\([^][\n]+\\)\\](\\([^()\n]+\\))" "[[\\2][\\1]]"))

(defun hermes-md--inline-italics-star ()
  "Convert *em* to /em/.  Runs after `hermes-md--inline-bold' so any
remaining `*…*' should be italic."
  (hermes-md--inline-replace
   "\\(^\\|[^*]\\)\\*\\([^* \t\n][^*\n]*?[^* \t\n]\\|[^* \t\n]\\)\\*\\($\\|[^*]\\)"
   "\\1/\\2/\\3"))

(defun hermes-md--inline-italics-underscore ()
  "Convert _em_ to /em/ at word boundaries (skipping snake_case)."
  (hermes-md--inline-replace
   "\\(^\\|[^[:alnum:]_]\\)_\\([^_\n]+?\\)_\\($\\|[^[:alnum:]_]\\)"
   "\\1/\\2/\\3"))

;;;; Guardrail

(defun hermes-md--guardrail-escape-headings ()
  "Escape accidental 1–3 star Org headings produced by raw LLM output.
Single-star bullets have already been rewritten to `-' by
`hermes-md--convert-bullets'; intentional headings from `#' demotion are
4+ stars.  Anything left at 1–3 stars + space at BOL is accidental — prefix
with a leading space so Org renders it as literal text instead of a heading."
  (goto-char (point-min))
  (while (re-search-forward "^\\(\\*\\{1,3\\}\\)\\([ \t]\\)" nil t)
    (unless (hermes-md--protected-p (match-beginning 0))
      (replace-match " \\1\\2" t nil))))

(provide 'hermes-md)
;;; hermes-md.el ends here
