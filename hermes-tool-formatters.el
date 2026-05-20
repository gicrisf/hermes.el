;;; hermes-tool-formatters.el --- Per-tool body formatters -*- lexical-binding: t; -*-

;; Author: Giovanni Crisalfi
;; Keywords: tools, ai
;; Package-Requires: ((emacs "27.1"))

;;; Commentary:

;; A registry of pure formatters that translate a `hermes-tool' into the
;; org-mode body that follows its heading.  Each formatter is
;;
;;   (hermes-tool) -> plist  (:summary STRING :body STRING :fold BOOLEAN)
;;
;; The dispatcher in `hermes-render.el' picks the first formatter whose
;; regexp matches the tool name and assembles the final block with the
;; heading + property drawer.

;;; Code:

(require 'cl-lib)
(require 'ansi-color)
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

(defun hermes-tool--strip-ansi (string)
  "Remove ANSI escape sequences from STRING.
Returns nil for nil input so callers can use `when' / `and' guards
without spuriously matching on an empty result."
  (when (and string (not (string-empty-p string)))
    (with-temp-buffer
      (insert string)
      (ansi-color-filter-region (point-min) (point-max))
      (buffer-string))))

(defun hermes-tool--running-or-complete (tool body-complete body-running)
  "Choose body fragment by TOOL status."
  (pcase (hermes-tool-status tool)
    ('complete body-complete)
    ('error    body-complete)
    (_         body-running)))

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
         (context (hermes-tool-context tool))
         (err     (hermes-tool-error tool))
         (out     (hermes-tool--output-or-preview tool))
         (diff    (hermes-tool--strip-ansi (hermes-tool-inline-diff tool)))
         (todos   (hermes-tool-todos tool))
         (body
          (concat
           (when (and (memq (hermes-tool-status tool) '(running generating))
                      context)
             (format ":CONTEXT:\n%s\n:END:\n" context))
           (cond
            (err (hermes-tool--example err))
            (out (hermes-tool--example out))
            (t ""))
           (when diff (format "#+begin_src diff\n%s\n#+end_src\n" diff))
           (when todos
             (concat ":TODOS:\n"
                     (mapconcat
                      (lambda (todo)
                        (let ((text (or (hermes--get todo "text") ""))
                              (done (hermes--get todo "done")))
                          (format "- [%s] %s" (if done "X" " ") text)))
                      todos "\n")
                     "\n:END:\n")))))
    (list :summary name :body body :fold nil)))

;;;; Bash

(defun hermes-tool-format-bash (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (cmd (or (hermes-tool--ctx-get ctx 'command 'cmd 'script) ""))
         (err (hermes-tool-error tool))
         (out (hermes-tool--output-or-preview tool))
         (lang (cond
                ((string-match-p "\\`#!.*python" cmd) "python")
                ((string-match-p "\\`#!.*\\(node\\|deno\\)" cmd) "js")
                (t "bash")))
         (summary
          (concat "$ " (hermes-tool--truncate
                        (if (string-empty-p cmd)
                            (or (hermes-tool-context tool) "") cmd)
                        72))))
    (list :summary summary
          :body (concat
                 (unless (string-empty-p cmd)
                   (hermes-tool--src-block lang cmd))
                 (cond
                  (err (hermes-tool--example err))
                  (out (hermes-tool--example out))
                  (t "")))
          :fold nil)))

;;;; Read

(defun hermes-tool-format-read (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (or (hermes-tool--ctx-get ctx 'file_path 'path 'file) ""))
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
         (summary (format "Read %s%s"
                          (hermes-tool--truncate
                           (if (string-empty-p path)
                               (or (hermes-tool-context tool) "") path)
                           60)
                          range))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary summary
          :body (cond
                 (err (hermes-tool--example err))
                 (out (hermes-tool--src-block
                       (hermes-tool--lang-from-path path) out))
                 (t ""))
          :fold (eq (hermes-tool-status tool) 'complete))))

;;;; Edit / Write

(defun hermes-tool-format-edit (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (or (hermes-tool--ctx-get ctx 'file_path 'path 'file) ""))
         (name (or (hermes-tool-name tool) "Edit"))
         (diff (hermes-tool--strip-ansi (hermes-tool-inline-diff tool)))
         (out  (hermes-tool--output-or-preview tool))
         (err  (hermes-tool-error tool))
         (summary (format "%s %s" name
                          (hermes-tool--truncate
                           (if (string-empty-p path)
                               (or (hermes-tool-context tool) "") path)
                           70))))
    (list :summary summary
          :body (concat
                 (cond
                  (err (hermes-tool--example err))
                  (diff (format "#+begin_src diff\n%s\n#+end_src\n" diff))
                  ((and (string-equal-ignore-case name "write") out)
                   (hermes-tool--src-block
                    (hermes-tool--lang-from-path path) out))
                  (out (hermes-tool--example out))
                  (t "")))
          :fold nil)))

;;;; Grep / Glob

(defun hermes-tool-format-grep (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (name (or (hermes-tool-name tool) "Grep"))
         (pattern (or (hermes-tool--ctx-get ctx 'pattern 'query 'regex) ""))
         (path (or (hermes-tool--ctx-get ctx 'path 'dir 'directory) ""))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool))
         (n-matches
          (and out (let ((lines (split-string out "\n" t)))
                     (length lines))))
         (summary
          (cond
           ((and (not (string-empty-p pattern)) (not (string-empty-p path)))
            (format "%s \"%s\" in %s%s" name
                    (hermes-tool--truncate pattern 30)
                    (hermes-tool--truncate path 30)
                    (if n-matches (format " (%d)" n-matches) "")))
           ((not (string-empty-p pattern))
            (format "%s \"%s\"%s" name
                    (hermes-tool--truncate pattern 50)
                    (if n-matches (format " (%d)" n-matches) "")))
           (t (format "%s %s" name
                      (hermes-tool--truncate
                       (or (hermes-tool-context tool) "") 60))))))
    (list :summary summary
          :body (cond
                 (err (hermes-tool--example err))
                 (out (hermes-tool--example out))
                 (t ""))
          :fold (eq (hermes-tool-status tool) 'complete))))

;;;; LS

(defun hermes-tool-format-ls (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (path (or (hermes-tool--ctx-get ctx 'path 'dir 'directory) ""))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary (format "LS %s"
                           (hermes-tool--truncate
                            (if (string-empty-p path)
                                (or (hermes-tool-context tool) "") path)
                            72))
          :body (cond
                 (err (hermes-tool--example err))
                 (out (hermes-tool--example out))
                 (t ""))
          :fold (eq (hermes-tool-status tool) 'complete))))

;;;; TodoWrite

(defun hermes-tool-format-todos (tool)
  (let* ((todos (hermes-tool-todos tool))
         (total (length todos))
         (done  (cl-count-if (lambda (td) (hermes--get td "done")) todos))
         (summary (if (> total 0)
                      (format "Todos (%d/%d done)" done total)
                    "Todos"))
         (list-body
          (when todos
            (concat
             (mapconcat
              (lambda (todo)
                (let ((text (or (hermes--get todo "text") ""))
                      (d (hermes--get todo "done")))
                  (format "- [%s] %s" (if d "X" " ") text)))
              todos "\n")
             "\n"))))
    (list :summary summary :body (or list-body "") :fold nil)))

;;;; WebFetch / WebSearch

(defun hermes-tool-format-web (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (name (or (hermes-tool-name tool) "Web"))
         (url (hermes-tool--ctx-get ctx 'url))
         (q   (hermes-tool--ctx-get ctx 'query 'q))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool))
         (summary
          (cond
           (url (format "Fetch %s" (hermes-tool--truncate url 70)))
           (q   (format "Search \"%s\"" (hermes-tool--truncate q 60)))
           (t   (format "%s %s" name
                        (hermes-tool--truncate
                         (or (hermes-tool-context tool) "") 60))))))
    (list :summary summary
          :body (cond
                 (err (hermes-tool--example err))
                 (out (hermes-tool--example out))
                 (t ""))
          :fold (eq (hermes-tool-status tool) 'complete))))

;;;; Task / Agent

(defun hermes-tool-format-agent (tool)
  (let* ((ctx (hermes-tool--parse-context (hermes-tool-context tool)))
         (desc (or (hermes-tool--ctx-get ctx 'description 'subagent_type 'goal)
                   ""))
         (out (hermes-tool--output-or-preview tool))
         (err (hermes-tool-error tool)))
    (list :summary (format "Agent: %s"
                           (hermes-tool--truncate
                            (if (string-empty-p desc)
                                (or (hermes-tool-context tool) "") desc)
                            70))
          :body (cond
                 (err (hermes-tool--example err))
                 (out (hermes-tool--example out))
                 (t ""))
          :fold (eq (hermes-tool-status tool) 'complete))))

;;;; Registration

(hermes-tool--register "\\`Bash\\'"          #'hermes-tool-format-bash)
(hermes-tool--register "\\`Read\\'"          #'hermes-tool-format-read)
(hermes-tool--register "\\`\\(Edit\\|MultiEdit\\|Write\\)\\'"
                       #'hermes-tool-format-edit)
(hermes-tool--register "\\`\\(Grep\\|Glob\\)\\'"
                       #'hermes-tool-format-grep)
(hermes-tool--register "\\`LS\\'"            #'hermes-tool-format-ls)
(hermes-tool--register "\\`TodoWrite\\'"     #'hermes-tool-format-todos)
(hermes-tool--register "\\`\\(WebFetch\\|WebSearch\\)\\'"
                       #'hermes-tool-format-web)
(hermes-tool--register "\\`\\(Task\\|Agent\\)\\'"
                       #'hermes-tool-format-agent)

(provide 'hermes-tool-formatters)
;;; hermes-tool-formatters.el ends here
