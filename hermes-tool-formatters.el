;;; hermes-tool-formatters.el --- Per-tool body formatters -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A registry of pure formatters that translate a `hermes-tool' into the
;; org-mode body that follows its heading.  Each formatter is
;;
;;   (hermes-tool) -> plist  (:summary STRING :body STRING :fold BOOLEAN
;;                            :args STRING-OR-NIL)
;;
;; `:summary' is the org heading text.  `:args' is the comint tier-2
;; arguments line — nil when the tool has no meaningful argument
;; display (the generic fallback, or tools missing context).
;;
;; The dispatcher in `hermes-render.el' picks the first formatter whose
;; regexp matches the tool name and assembles the final block with the
;; heading + property drawer.

;;; Code:

(require 'cl-lib)
(require 'hermes-state)

;;;; Registry

(defvar hermes-tool-formatters nil
  "Alist of (NAME-REGEXP . FORMATTER-FN), first match wins.")

(defun hermes-tool--register (regexp fn)
  "Append (REGEXP . FN) to `hermes-tool-formatters'."
  (setq hermes-tool-formatters
        (append (cl-remove regexp hermes-tool-formatters
                           :key #'car :test #'equal)
                (list (cons regexp fn)))))

(defun hermes-tool--lookup (name)
  "Return the formatter registered for NAME, or the generic fallback."
  (or (cl-some (lambda (pair)
                 (when (string-match-p (car pair) name) (cdr pair)))
               hermes-tool-formatters)
      #'hermes-tool-format-generic))

;;;; Helpers

(defun hermes-tool--parse-context (context)
  "Parse CONTEXT (a string from `tool.start') into an alist.
Tries JSON first, then a loose `k=v' / `k: v' fallback.  Returns nil on
failure.  Keys are downcased symbols, values are strings."
  (when (and context (stringp context) (not (string-empty-p context)))
    (or (ignore-errors
          (let* ((parsed (json-parse-string context
                                            :object-type 'alist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object nil)))
            (and (listp parsed) parsed)))
        (let (acc)
          (dolist (line (split-string context "[\n,]+" t " \t"))
            (when (string-match "\\`[ \t]*\\([A-Za-z_][A-Za-z0-9_-]*\\)[ \t]*[:=][ \t]*\\(.*?\\)[ \t]*\\'"
                                line)
              (push (cons (intern (downcase (match-string 1 line)))
                          (match-string 2 line))
                    acc)))
          (nreverse acc)))))

(defun hermes-tool--ctx-get (ctx &rest keys)
  "Return the first non-empty value in CTX for any of KEYS (symbols)."
  (catch 'found
    (dolist (k keys)
      (let ((v (cdr (assq k ctx))))
        (when (and v (stringp v) (not (string-empty-p v)))
          (throw 'found v))
        (when (and v (not (stringp v)))
          (throw 'found (format "%s" v)))))
    nil))

(defun hermes-tool--primary-arg (tool ctx &rest keys)
  "Return the primary-arg string for TOOL, or nil.
Looks up KEYS in parsed CTX first; falls back to TOOL's raw
`hermes-tool-context' (the gateway's bare preview string from
`build_tool_preview' in `tui_gateway/server.py').  Returns nil when
neither yields a non-empty string."
  (let ((from-ctx (apply #'hermes-tool--ctx-get ctx keys)))
    (cond
     ((and from-ctx (not (string-empty-p from-ctx))) from-ctx)
     (t (let ((raw (hermes-tool-context tool)))
          (and raw (stringp raw) (not (string-empty-p raw)) raw))))))

(defun hermes-tool--truncate (s n)
  "Truncate string S to N chars, single-line, ellipsis if cut."
  (let ((s1 (replace-regexp-in-string "[\n\r]+" " " (or s ""))))
    (if (> (length s1) n)
        (concat (substring s1 0 (max 0 (- n 1))) "…")
      s1)))

(defun hermes-tool--lang-from-path (path)
  "Guess an org src-block language from PATH's extension."
  (let* ((ext (and path (downcase (or (file-name-extension path) "")))))
    (pcase ext
      ((or "el" "elisp") "emacs-lisp")
      ("py" "python")
      ("js" "js") ("mjs" "js") ("cjs" "js")
      ("ts" "typescript") ("tsx" "tsx") ("jsx" "jsx")
      ("rs" "rust")
      ("go" "go")
      ("rb" "ruby")
      ("sh" "bash") ("bash" "bash") ("zsh" "bash")
      ("c" "c") ("h" "c")
      ("cpp" "cpp") ("cc" "cpp") ("hpp" "cpp")
      ("java" "java")
      ("kt" "kotlin")
      ("swift" "swift")
      ("php" "php")
      ("md" "markdown") ("markdown" "markdown")
      ("json" "json")
      ("yaml" "yaml") ("yml" "yaml")
      ("toml" "toml")
      ("html" "html") ("htm" "html")
      ("css" "css")
      ("sql" "sql")
      ("" nil)
      (_ ext))))

(defun hermes-tool--src-block (lang content)
  "Wrap CONTENT in `#+begin_src LANG' or example if LANG is nil."
  (if (and lang (not (string-empty-p lang)))
      (format "#+begin_src %s\n%s\n#+end_src\n" lang
              (or content ""))
    (format "#+begin_example\n%s\n#+end_example\n" (or content ""))))

(defun hermes-tool--example (content)
  "Wrap CONTENT in `#+begin_example' (no-op if empty)."
  (if (and content (not (string-empty-p content)))
      (format "#+begin_example\n%s\n#+end_example\n" content)
    ""))

(defun hermes-tool--context-block (tool)
  "Return a `#+name'd example block carrying TOOL's raw context string,
or the empty string when no context is set.  Body-canonical: the
parser re-reads this via `hermes--extract-named-block'.  Unlike
preview/output blocks, the `#+name' marker is emitted unconditionally
(no terminal-status gate) because context is static, set once at
`tool.start' and never updated."
  (let ((ctx (hermes-tool-context tool)))
    (if (and ctx (stringp ctx) (not (string-empty-p ctx)))
        (concat (format "#+name: hermes-tool-%s-context\n"
                        (hermes--slug-for-name (hermes-tool-id tool)))
                (hermes-tool--example ctx))
      "")))

(defun hermes-tool--running-or-complete (tool body-complete body-running)
  "Choose body fragment by TOOL status."
  (pcase (hermes-tool-status tool)
    ('complete body-complete)
    ('error    body-complete)
    (_         body-running)))

(defun hermes-tool--format-todos-table (tool todos)
  "Render TODOS as a `#+name'd Org table for TOOL.  Returns nil when
TODOS is empty.

The table has four columns: `[X|-|space]` (visual sugar), the
verbatim gateway `status` string, `id`, and `content`.  Column 2
preserves all gateway statuses (including `pending` and any others
the gateway might introduce); the parser reads it verbatim and
ignores column 1.

Body-canonical: the parser re-reads this via
`hermes--extract-named-table' + `hermes--parse-todos-table'."
  (when todos
    (let ((slug (hermes--slug-for-name (hermes-tool-id tool)))
          (rows (mapconcat
                 (lambda (todo)
                   (let* ((content (or (hermes--get todo "content") ""))
                          (status  (or (hermes--get todo "status") ""))
                          (id      (or (hermes--get todo "id") ""))
                          (check   (pcase status
                                     ("completed"   "X")
                                     ("in_progress" "-")
                                     (_             " "))))
                     (format "| [%s] | %s | %s | %s |"
                             check status id content)))
                 todos "\n")))
      (concat (format "#+name: hermes-tool-%s-todos\n" slug)
              rows "\n"))))

(defun hermes-tool--maybe-name (tool field-suffix block)
  "Prefix BLOCK with `#+name: hermes-tool-<slug>-FIELD-SUFFIX' when TOOL's
status is terminal (`complete' or `error'); otherwise return BLOCK
unchanged.  BLOCK is the rendered Org block string (already wrapped
with `#+begin_…' / `#+end_…').  Returns BLOCK verbatim when it is
empty or nil.  The `#+name' line is placed immediately before the
`#+begin_' line with no intervening whitespace — the parser's
`hermes--extract-named-block' relies on this adjacency."
  (if (and block (not (string-empty-p block))
           (memq (hermes-tool-status tool) '(complete error)))
      (concat (format "#+name: hermes-tool-%s-%s\n"
                      (hermes--slug-for-name (hermes-tool-id tool))
                      field-suffix)
              block)
    block))

(defun hermes-tool--strip-name-markers (s)
  "Strip `#+name: hermes-tool-…' lines from S — body-canonical noise in comint."
  (if (and s (stringp s))
      (replace-regexp-in-string "^#\\+name: hermes-tool-[^\n]*\n" "" s)
    (or s "")))

(defun hermes-tool--body-comint-default (err out)
  "Common comint body: error block, else output block, else empty.
Used by formatters whose `:body-comint' is just the error/output payload
with the context block and `#+name:' markers stripped."
  (cond
   (err (hermes-tool--example err))
   (out (hermes-tool--example out))
   (t "")))

(defun hermes-tool--output-or-preview (tool)
  "Return OUTPUT if present, else PREVIEW, else nil."
  (or (and (hermes-tool-output tool)
           (not (string-empty-p (hermes-tool-output tool)))
           (hermes-tool-output tool))
      (and (hermes-tool-preview tool)
           (not (string-empty-p (hermes-tool-preview tool)))
           (hermes-tool-preview tool))))

;;;; Generic fallback formatter

(defun hermes-tool-format-generic (tool)
  "Default formatter.  Mirrors the legacy layout but without status-in-heading."
  (let* ((name    (or (hermes-tool-name tool) "tool"))
         (err     (hermes-tool-error tool))
         (out     (hermes-tool--output-or-preview tool))
         (diff    (hermes-tool-inline-diff tool))
         (todos   (hermes-tool-todos tool))
         (body
          (concat
           (hermes-tool--context-block tool)
           (cond
            (err (hermes-tool--maybe-name tool "error" (hermes-tool--example err)))
            (out (hermes-tool--maybe-name tool "output" (hermes-tool--example out)))
            (t ""))
           (when diff
             (hermes-tool--maybe-name
              tool "inline-diff"
              (format "#+begin_src diff\n%s\n#+end_src\n" diff)))
           (hermes-tool--format-todos-table tool todos))))
    (list :summary name :body body :fold nil :args nil
          :body-comint
          (concat
           (cond
            (err (hermes-tool--example err))
            (out (hermes-tool--example out))
            (t ""))
           (when diff
             (format "#+begin_src diff\n%s\n#+end_src\n" diff))
           (hermes-tool--strip-name-markers
            (or (hermes-tool--format-todos-table tool todos) ""))))))

;;;; Bash

(defun hermes-tool--parse-terminal-output (raw)
  "Unwrap a gateway terminal envelope {output,exit_code,error} from RAW.
Returns a cons (TEXT . EXIT-CODE) where TEXT is the human-readable
output (possibly with an `[exit code: N]' suffix) and EXIT-CODE is the
parsed integer or nil.  Falls back to (RAW . nil) when RAW is not a
JSON object of the expected shape."
  (or (ignore-errors
        (when (and raw (stringp raw)
                   (string-match-p "\\`[[:space:]]*{" raw))
          (let* ((obj (json-parse-string raw :object-type 'alist
                                         :null-object nil
                                         :false-object nil))
                 (out  (alist-get 'output obj))
                 (exit (alist-get 'exit_code obj))
                 (err  (alist-get 'error obj))
                 (text (cond
                        ((and err (stringp err) (not (string-empty-p err))) err)
                        ((stringp out) out)
                        (t ""))))
            (cons (if (and (numberp exit) (not (zerop exit)))
                      (concat (string-trim-right text)
                              (format "\n[exit code: %d]" exit))
                    text)
                  exit))))
      (cons raw nil)))

(defun hermes-tool-format-bash (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (cmd (hermes-tool--primary-arg tool ctx 'command 'cmd 'script))
         (err (hermes-tool-error tool))
         (out (hermes-tool--output-or-preview tool))
         (lang (cond
                ((and cmd (string-match-p "\\`#!.*python" cmd)) "python")
                ((and cmd (string-match-p "\\`#!.*\\(node\\|deno\\)" cmd)) "js")
                (t "bash")))
         (summary (and cmd (concat "$ " (hermes-tool--truncate cmd 72))))
         (args summary)
         (clean-out (car (hermes-tool--parse-terminal-output out))))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (when (and cmd (not (string-empty-p cmd)))
                   (hermes-tool--src-block lang cmd))
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint (concat
                        (when (and cmd (not (string-empty-p cmd)))
                          (hermes-tool--src-block lang cmd))
                        (cond
                         (err (hermes-tool--example err))
                         ((and clean-out (not (string-empty-p clean-out)))
                          (hermes-tool--example clean-out))
                         (t "")))
          :fold nil
          :args args)))

;;;; Read

(defun hermes-tool--parse-read-output (raw)
  "Unwrap a gateway read_file envelope from RAW.
Returns clean file content with line-number prefixes stripped, or RAW
unchanged when parsing fails."
  (or (ignore-errors
        (when (and raw (stringp raw)
                   (string-match-p "\\`[[:space:]]*{" raw))
          (let* ((obj (json-parse-string raw :object-type 'alist
                                         :null-object nil
                                         :false-object nil))
                 (content (alist-get 'content obj)))
            (when (and content (stringp content))
              (replace-regexp-in-string
               "^[[:space:]]*[0-9]+|" "" content)))))
      raw))

(defun hermes-tool-format-read (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (hermes-tool--primary-arg tool ctx 'file_path 'path 'file))
         (offset (hermes-tool--ctx-get ctx 'offset))
         (limit  (hermes-tool--ctx-get ctx 'limit))
         (range (cond
                 ((and offset limit)
                  (format ":%s-%s" offset
                          (ignore-errors
                            (+ (string-to-number offset)
                               (string-to-number limit)))))
                 (offset (format ":%s" offset))
                 (t "")))
         (summary (and path (format "Read %s%s"
                                    (hermes-tool--truncate path 60) range)))
         (args (and path (concat (hermes-tool--truncate path 60) range)))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--src-block
                          (hermes-tool--lang-from-path (or path "")) out)))
                  (t "")))
          :body-comint
          (cond
           (err (hermes-tool--example err))
           (out (hermes-tool--src-block
                 (hermes-tool--lang-from-path (or path ""))
                 (hermes-tool--parse-read-output out)))
           (t ""))
          :fold (eq (hermes-tool-status tool) 'complete)
          :args args)))

;;;; Edit / Write

(defun hermes-tool-format-edit (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (hermes-tool--primary-arg tool ctx 'file_path 'path 'file))
         (name (or (hermes-tool-name tool) "Edit"))
         (diff (hermes-tool-inline-diff tool))
         (out  (hermes-tool--output-or-preview tool))
         (err  (hermes-tool-error tool))
         (summary (and path (format "%s %s" name
                                    (hermes-tool--truncate path 70))))
         (args (and path (hermes-tool--truncate path 70))))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (diff (hermes-tool--maybe-name
                         tool "inline-diff"
                         (format "#+begin_src diff\n%s\n#+end_src\n" diff)))
                  ((and (string-equal-ignore-case name "write_file") out)
                   (hermes-tool--maybe-name
                    tool "output"
                    (hermes-tool--src-block
                     (hermes-tool--lang-from-path (or path "")) out)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint
          (cond
           (err (hermes-tool--example err))
           (diff (format "#+begin_src diff\n%s\n#+end_src\n" diff))
           ((and (string-equal-ignore-case name "write_file") out)
            (hermes-tool--src-block
             (hermes-tool--lang-from-path (or path "")) out))
           (out (hermes-tool--example out))
           (t ""))
          :fold nil
          :args args)))

;;;; Grep / Glob

(defun hermes-tool-format-grep (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (name (or (hermes-tool-name tool) "Grep"))
         (pattern (or (hermes-tool--primary-arg
                       tool ctx 'pattern 'query 'regex) ""))
         (glob    (or (hermes-tool--ctx-get ctx 'file_glob) ""))
         (path (or (hermes-tool--ctx-get ctx 'path 'dir 'directory) ""))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool))
         (n-matches
          (and out (let ((lines (split-string out "\n" t)))
                     (length lines))))
         (summary
          (cond
           ((and (not (string-empty-p glob)) (not (string-empty-p path)))
            (format "%s %s in %s%s" name
                    glob
                    (hermes-tool--truncate path 40)
                    (if n-matches (format " (%d)" n-matches) "")))
           ((not (string-empty-p glob))
            (format "%s %s%s" name glob
                    (if n-matches (format " (%d)" n-matches) "")))
           ((and (not (string-empty-p pattern)) (not (string-empty-p path)))
            (format "%s \"%s\" in %s%s" name
                    (hermes-tool--truncate pattern 30)
                    (hermes-tool--truncate path 30)
                    (if n-matches (format " (%d)" n-matches) "")))
           ((not (string-empty-p pattern))
            (format "%s \"%s\"%s" name
                    (hermes-tool--truncate pattern 50)
                    (if n-matches (format " (%d)" n-matches) "")))
           (t nil)))
         (args
          (cond
           ((and (not (string-empty-p glob)) (not (string-empty-p path)))
            (format "%s in %s" glob (hermes-tool--truncate path 40)))
           ((not (string-empty-p glob)) glob)
           ((and (not (string-empty-p pattern)) (not (string-empty-p path)))
            (format "\"%s\" in %s"
                    (hermes-tool--truncate pattern 30)
                    (hermes-tool--truncate path 30)))
           ((not (string-empty-p pattern))
            (format "\"%s\"" (hermes-tool--truncate pattern 50)))
           (t nil))))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint (cond
                        (err (hermes-tool--example err))
                        (out (hermes-tool--example
                              (hermes-tool--format-grep-output out)))
                        (t ""))
          :fold (eq (hermes-tool-status tool) 'complete)
          :args args)))

(defun hermes-tool--format-grep-output (raw)
  "Format grep RAW output (gateway JSON envelope) as `path:line: content' lines.
Falls back to RAW when parsing fails."
  (or (ignore-errors
        (when (and raw (stringp raw)
                   (string-match-p "\\`[[:space:]]*{" raw))
          (let* ((obj (json-parse-string raw :object-type 'alist
                                         :array-type 'list
                                         :null-object nil
                                         :false-object nil))
                 (matches (alist-get 'matches obj))
                 (total (alist-get 'total_count obj))
                 (lines (mapconcat
                         (lambda (m)
                           (format "%s:%s: %s"
                                   (or (alist-get 'path m) "?")
                                   (or (alist-get 'line m) "?")
                                   (string-trim (or (alist-get 'content m) ""))))
                         matches "\n")))
            (if (and total (numberp total))
                (concat lines (format "\n[%d match%s]"
                                      total (if (= total 1) "" "es")))
              lines))))
      raw))

;;;; LS

(defun hermes-tool-format-ls (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (hermes-tool--primary-arg tool ctx 'path 'dir 'directory))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary (and path (format "LS %s" (hermes-tool--truncate path 72)))
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint (hermes-tool--body-comint-default err out)
          :fold (eq (hermes-tool-status tool) 'complete)
          :args (and path (hermes-tool--truncate path 72)))))

;;;; TodoWrite

(defun hermes-tool-format-todos (tool)
  (let* ((todos (hermes-tool-todos tool))
         (total (length todos))
         (done  (cl-count-if (lambda (td) (hermes--get td "done")) todos))
         (summary (if (> total 0)
                      (format "Todos (%d/%d done)" done total)
                    "Todos"))
         (args (when (> total 0)
                 (format "%d of %d complete" done total))))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (or (hermes-tool--format-todos-table tool todos) ""))
          :body-comint
          (hermes-tool--strip-name-markers
           (or (hermes-tool--format-todos-table tool todos) ""))
          :fold nil
          :args args)))

;;;; WebFetch / WebSearch

(defun hermes-tool-format-web (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (url-raw (let ((v (cdr (assq 'urls ctx))))
                    (or (hermes-tool--ctx-get ctx 'url) v)))
         (url (cond
               ((and url-raw (stringp url-raw)) url-raw)
               ((and url-raw (consp url-raw) (stringp (car url-raw))) (car url-raw))
               (t nil)))
         (q   (hermes-tool--ctx-get ctx 'query 'q))
         ;; Gateway's bare-preview fallback: classify by content.
         (bare (and (not url) (not q)
                    (let ((c (hermes-tool-context tool)))
                      (and c (stringp c) (not (string-empty-p c)) c))))
         (url (or url (and bare (string-prefix-p "http" bare) bare)))
         (q   (or q (and bare (not (string-prefix-p "http" bare)) bare)))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool))
         (summary
          (cond
           (url (format "Fetch %s" (hermes-tool--truncate url 70)))
           (q   (format "Search \"%s\"" (hermes-tool--truncate q 60)))
           (t   nil)))
         (args
          (cond
           (url (hermes-tool--truncate url 70))
           (q   (format "\"%s\"" (hermes-tool--truncate q 60)))
           (t   nil))))
    (list :summary summary
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint (hermes-tool--body-comint-default err out)
          :fold (eq (hermes-tool-status tool) 'complete)
          :args args)))

;;;; Task / Agent

(defun hermes-tool-format-agent (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (desc (hermes-tool--primary-arg
                tool ctx 'description 'subagent_type 'goal))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary (and desc (format "Agent: %s"
                                     (hermes-tool--truncate desc 70)))
          :body (concat
                 (hermes-tool--context-block tool)
                 (cond
                  (err (hermes-tool--maybe-name tool "error"
                         (hermes-tool--example err)))
                  (out (hermes-tool--maybe-name tool "output"
                         (hermes-tool--example out)))
                  (t "")))
          :body-comint (hermes-tool--body-comint-default err out)
          :fold (eq (hermes-tool-status tool) 'complete)
          :args (and desc (hermes-tool--truncate desc 70)))))

;;;; Registration

(hermes-tool--register "\\`\\(terminal\\|process\\|execute_code\\)\\'"
                       #'hermes-tool-format-bash)
(hermes-tool--register "\\`read_file\\'"     #'hermes-tool-format-read)
(hermes-tool--register "\\`\\(write_file\\|patch\\)\\'"
                       #'hermes-tool-format-edit)
(hermes-tool--register "\\`search_files\\'"  #'hermes-tool-format-grep)
(hermes-tool--register "\\`ls\\'"            #'hermes-tool-format-ls)
(hermes-tool--register "\\`todo\\'"          #'hermes-tool-format-todos)
(hermes-tool--register "\\`\\(web_search\\|web_extract\\)\\'"
                       #'hermes-tool-format-web)
(hermes-tool--register "\\`delegate_task\\'" #'hermes-tool-format-agent)

(provide 'hermes-tool-formatters)
;;; hermes-tool-formatters.el ends here
