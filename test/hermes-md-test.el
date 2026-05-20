;;; hermes-md-test.el --- ERT tests for markdown→Org conversion -*- lexical-binding: t; -*-

(require 'ert)
(require 'hermes-md)

(defmacro hermes-md-test--should= (input expected)
  `(should (equal ,expected (hermes-md-to-org ,input))))

;;;; Inline

(ert-deftest hermes-md-test/bold ()
  (hermes-md-test--should= "this is **bold** text" "this is *bold* text"))

(ert-deftest hermes-md-test/inline-code ()
  (hermes-md-test--should= "run `ls -la` now" "run ~ls -la~ now"))

(ert-deftest hermes-md-test/link ()
  (hermes-md-test--should=
   "see [docs](https://example.com) here"
   "see [[https://example.com][docs]] here"))

(ert-deftest hermes-md-test/italic-star ()
  (hermes-md-test--should= "this is *em* text" "this is /em/ text"))

(ert-deftest hermes-md-test/italic-underscore ()
  (hermes-md-test--should= "this is _em_ text" "this is /em/ text"))

(ert-deftest hermes-md-test/underscores-in-snake-case-untouched ()
  (hermes-md-test--should= "call foo_bar_baz now" "call foo_bar_baz now"))

(ert-deftest hermes-md-test/bold-runs-before-italic ()
  ;; **x** must not be converted to /*x*/ by an aggressive italic pass.
  (hermes-md-test--should= "**bold** and *em*" "*bold* and /em/"))

;;;; Headings

(ert-deftest hermes-md-test/heading-demoted-by-one-level ()
  ;; ATX headings are demoted to nest inside the assistant turn's
  ;; `*** Response' heading: # → ****, ## → *****, etc.
  (hermes-md-test--should= "# Title\nbody" "**** Title\nbody")
  (hermes-md-test--should= "## Sub\nbody" "***** Sub\nbody"))

;;;; Fences

(ert-deftest hermes-md-test/fenced-src-with-language ()
  (hermes-md-test--should=
   "```python\nprint(1)\n```\n"
   "#+begin_src python\nprint(1)\n#+end_src\n"))

(ert-deftest hermes-md-test/fenced-example-without-language ()
  (hermes-md-test--should=
   "```\nplain text\n```\n"
   "#+begin_example\nplain text\n#+end_example\n"))

(ert-deftest hermes-md-test/fence-body-untouched-by-inline ()
  ;; Inside a fence: **bold**, `code`, [l](u) must all stay raw.
  (hermes-md-test--should=
   "```python\n# **bold** and `code` and [l](u)\n```\n"
   "#+begin_src python\n# **bold** and `code` and [l](u)\n#+end_src\n"))

(ert-deftest hermes-md-test/fence-then-inline-after ()
  (hermes-md-test--should=
   "```sh\necho hi\n```\n\nThen **after**.\n"
   "#+begin_src sh\necho hi\n#+end_src\n\nThen *after*.\n"))

;;;; Tables

(ert-deftest hermes-md-test/table-separator-rewritten ()
  (hermes-md-test--should=
   "| a | b |\n|---|---|\n| 1 | 2 |\n"
   "| a | b |\n|---+---|\n| 1 | 2 |\n"))

;;;; Fences — hardening (tick counting, nesting, whitespace, auto-close)

(ert-deftest hermes-md-test/nested-fences ()
  ;; 4-tick outer fence contains a 3-tick block as body text.
  (hermes-md-test--should=
   "````markdown\n```python\nprint(1)\n```\n````\n"
   "#+begin_src markdown\n```python\nprint(1)\n```\n#+end_src\n"))

(ert-deftest hermes-md-test/fence-with-leading-whitespace ()
  (hermes-md-test--should=
   "  ```python\n  print(1)\n  ```\n"
   "#+begin_src python\n  print(1)\n#+end_src\n"))

(ert-deftest hermes-md-test/unmatched-fence-auto-closed ()
  (hermes-md-test--should=
   "```python\nprint(1)\n"
   "#+begin_src python\nprint(1)\n#+end_src\n"))

;;;; Bullets

(ert-deftest hermes-md-test/bullet-star-to-dash ()
  (hermes-md-test--should= "* first\n* second\n" "- first\n- second\n"))

(ert-deftest hermes-md-test/bullet-plus-to-dash ()
  (hermes-md-test--should= "+ first\n+ second\n" "- first\n- second\n"))

(ert-deftest hermes-md-test/bullets-inside-fence-untouched ()
  (hermes-md-test--should=
   "```\n* inside\n```\n"
   "#+begin_example\n* inside\n#+end_example\n"))

;;;; Guardrail (accidental Org heading escape)

(ert-deftest hermes-md-test/double-star-accidental-escaped ()
  (hermes-md-test--should= "** Also not\n" " ** Also not\n"))

(ert-deftest hermes-md-test/triple-star-accidental-escaped ()
  (hermes-md-test--should= "*** Three stars\n" " *** Three stars\n"))

(ert-deftest hermes-md-test/our-headings-untouched ()
  ;; # demotes to 4 stars; guardrail's 1-3 star filter must skip it.
  (hermes-md-test--should= "# Title\n" "**** Title\n"))

(ert-deftest hermes-md-test/numbered-list-passthrough ()
  (hermes-md-test--should= "1. first\n2. second\n" "1. first\n2. second\n"))

;;;; Empty / passthrough

(ert-deftest hermes-md-test/empty-string ()
  (hermes-md-test--should= "" ""))

(ert-deftest hermes-md-test/nil-is-empty ()
  (should (equal "" (hermes-md-to-org nil))))

(ert-deftest hermes-md-test/plain-text-untouched ()
  (hermes-md-test--should=
   "Just plain prose with no markdown.\n"
   "Just plain prose with no markdown.\n"))

;;;; ANSI escape stripping inside fenced code

(ert-deftest hermes-md-test/fence-diff-ansi-stripped ()
  (let ((out (hermes-md-to-org "```diff\n\e[32m+ x\e[0m\n```\n")))
    (should (equal out "#+begin_src diff\n+ x\n#+end_src\n"))
    (should-not (string-match-p "\e\\[" out))))

(ert-deftest hermes-md-test/fence-ansi-stripped-eof-autoclose ()
  ;; Missing close fence — body still gets ANSI-stripped.
  (let ((out (hermes-md-to-org "```diff\n\e[31m- gone\e[0m\n")))
    (should (string-match-p "^- gone$" out))
    (should-not (string-match-p "\e\\[" out))))

(provide 'hermes-md-test)
;;; hermes-md-test.el ends here
