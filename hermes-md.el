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

(defun hermes-md-to-org (s)
  "Return Org-syntax version of markdown string S.  Best-effort, single-pass."
  (if (or (null s) (string-empty-p s))
      (or s "")
    (with-temp-buffer
      (insert s)
      (hermes-md--convert-fences)
      (hermes-md--convert-tables)
      (hermes-md--convert-headings)
      (hermes-md--inline-bold)
      (hermes-md--inline-code)
      (hermes-md--inline-links)
      (hermes-md--inline-italics-star)
      (hermes-md--inline-italics-underscore)
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
  "Replace ```lang…``` blocks with Org src/example blocks; mark bodies protected."
  (goto-char (point-min))
  (while (re-search-forward "^```\\([^\n]*\\)$" nil t)
    (let* ((lang (string-trim (or (match-string 1) "")))
           (open-beg (match-beginning 0))
           (open-end (match-end 0))
           (header (if (string-empty-p lang)
                       "#+begin_example"
                     (format "#+begin_src %s" lang)))
           (footer (if (string-empty-p lang) "#+end_example" "#+end_src")))
      (delete-region open-beg open-end)
      (goto-char open-beg)
      (insert header)
      (let ((body-start (point)))
        (if (re-search-forward "^```[ \t]*$" nil t)
            (let ((close-beg (match-beginning 0))
                  (close-end (match-end 0)))
              (delete-region close-beg close-end)
              (goto-char close-beg)
              (insert footer)
              (put-text-property body-start (point)
                                 'hermes-md-protected t))
          ;; No closing fence — leave header in place and stop.
          (goto-char (point-max)))))))

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
  "Demote ATX headings (#, ##, …) to Org subheadlines (**, ***, …)."
  (goto-char (point-min))
  (while (re-search-forward "^\\(#+\\)[ \t]+" nil t)
    (unless (hermes-md--protected-p (match-beginning 0))
      (let ((n (length (match-string 1))))
        (replace-match (concat (make-string (1+ n) ?*) " ") t t)))))

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

(provide 'hermes-md)
;;; hermes-md.el ends here
