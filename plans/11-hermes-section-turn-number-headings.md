# PLAN: hermes-section fixes (headings, reasoning, subagent notes)

## 1. Motivation

Three issues with the Plan 08 design surfaced during review:

**I. Turn-number headings.**  "First non-blank line of response text" as
the section heading breaks when a response opens with code fences (` ``` `),
ATX headings, or blockquotes.  The raw syntax gets promoted to the heading
label and deduplicated out of the body.

**II. Reasoning placement.**  Plan 08 renders reasoning child sections in
arrival order (interleaved with tools in the segment vector).  Reasoning
represents the model's internal thought process — it should appear *before*
the visible response, not buried between tool calls.

**III. Subagent notes.**  `hermes-subagent.notes` (a vector of progress
strings) is not displayed anywhere.  The Org renderer includes it; the
section viewer should too.

---

## 2. Turn-number headings

### 2.1 Format

```
#1 · User
#2 · Assistant · deepseek-v4-flash
#3 · User
#4 · System
#5 · Assistant · deepseek-v4-flash
#6 · Assistant · (tool-only)
```

| Turn kind | Format |
|-----------|--------|
| User | `"#N · User"` |
| Assistant (with text) | `"#N · Assistant · <model>"` |
| Assistant (tool-only) | `"#N · Assistant · (tool-only)"` |
| System | `"#N · System"` |

Where `N` is the 1-based index in the `hermes-state-turns` vector.
Model comes from `hermes-state-session-info` → `"model"` key.
Duration is skipped for v1 — `hermes-message` has no duration field.

### 2.2 What this replaces from Plan 08

| Plan 08 | Plan 11 |
|---------|---------|
| Heading = first non-blank line | Heading = `"#N · Kind · model"` |
| First-line dedup rule (§5.1-5.2) | Removed — heading never equals body content |
| `--heading-text` → first non-blank line | `--heading-text` → `(format "#%d · %s" n kind-string)` |
| `--body-text` joins all segments | Unchanged — body always shows full text verbatim |

### 2.3 Integration

`hermes-section--rebuild` (line 504) currently uses `seq-doseq` without
an index.  Switch to `seq-do-indexed` to pass a 1-based index:

```elisp
(seq-do-indexed (lambda (msg i)
                  (hermes-section--insert-turn msg (1+ i)))
                turns)
```

`hermes-section--insert-turn` (line 481) gains an `index` parameter.
The heading construction reuses existing helpers
`hermes-section--session-model` (line 228) and
`hermes-section--has-segment-type-p` (line 149 — already accepts any
segment type, not just `'tool`; verify during implementation):

```elisp
(defun hermes-section--heading-text (msg index)
  "Return turn-number heading for MSG at 1-based INDEX."
  (let ((kind (hermes-message-kind msg)))
    (pcase kind
      ('user (format "#%d · User" index))
      ('assistant
       (let ((has-text (hermes-section--has-segment-type-p msg 'text)))
         (if has-text
             (format "#%d · Assistant · %s" index
                     (or (hermes-section--session-model
                          hermes--current-session-id)
                         "?"))
           (format "#%d · Assistant · (tool-only)" index))))
      (_ (format "#%d · System" index)))))
```

`hermes-section--insert-full-text` (line 250) loses the `heading`
parameter and the first-line dedup loop — it simplifies to just insert
the full body text verbatim:

```elisp
(defun hermes-section--insert-full-text (msg _bg-face)
  "Insert MSG body text in full (no dedup — heading never matches body)."
  (let ((text (hermes-section--body-text msg)))
    (unless (string-empty-p text)
      (insert (hermes-section--fontify-org
               (concat text (unless (string-suffix-p "\n" text) "\n")))))))
```

The `heading` argument threaded through `--insert-user-body` (line 289),
`--insert-assistant-body` (line 451), and `--insert-system-body` (line 308)
is dropped from all three signatures.

---

## 3. Reasoning placement

### 3.1 Current (Plan 08)

Reasoning appears wherever it lands in the segment vector — often between
tool calls or even after the response text.

```
  Sure, 2+2 is 4.
  ───
├─ DONE calculator (0.3s)
├─ Reasoning                 ← interleaved with tools
└─ DONE grep pattern (0.1s)
```

### 3.2 Target

Reasoning is extracted from the segment vector and placed *first* in the
body, above the response text.  This reflects its role as the model's
internal thought process — it happened before the visible response.

```
├─ Reasoning                 ← always first in body
│   Let me think about this...
│   I should use calculator.
  Sure, 2+2 is 4.            ← response text
  The answer is four.
  ───
├─ DONE calculator (0.3s)    ← tools follow in arrival order
└─ DONE grep pattern (0.1s)
```

### 3.3 Implementation — `hermes-section--insert-assistant-body`

The current function (line 451) inserts body text first, then iterates
all segments mixing reasoning and tools in arrival order.  The new logic
splits into two passes:

```elisp
(defun hermes-section--insert-assistant-body (msg bg-face)
  (let* ((segs (or (hermes-message-segments msg) []))
         (sas  (or (hermes-message-subagents msg) [])))

    ;; Pass 1: reasoning segments → child sections (before response text)
    (dotimes (i (length segs))
      (when (eq 'reasoning (hermes-segment-type (aref segs i)))
        (hermes-section--insert-reasoning-child (aref segs i) bg-face)))

    ;; Response text (all text segments joined, no heading dedup)
    (hermes-section--insert-full-text msg bg-face)

    ;; Pass 2: separator + tool segments + subagents
    (let ((any-child
           (or (> (length sas) 0)
               (catch 'yes
                 (dotimes (i (length segs))
                   (when (eq 'tool (hermes-segment-type (aref segs i)))
                     (throw 'yes t)))
                 nil))))
      (when any-child
        (insert "───\n"))
      (dotimes (i (length segs))
        (let ((seg (aref segs i)))
          (when (eq 'tool (hermes-segment-type seg))
            (let ((c (hermes-segment-content seg)))
              (when (hermes-tool-p c)
                (hermes-section--insert-tool-child c bg-face))))))
      (dotimes (i (length sas))
        (hermes-section--insert-subagent-child (aref sas i) bg-face)))))
```

Key changes from current code:
- `any-child` check (line 455) excludes `'reasoning` from the condition —
  the `───` separator fires only when tools or subagents are present.
- Reasoning segments are handled in a dedicated pass above the body text.
- If no reasoning segments exist, Pass 1 is a no-op.
- Streaming is not affected — the section viewer only rebuilds from
  committed turns; no partial-message path exists in this file.

---

## 4. Reasoning text color

The existing `hermes-section-face-reasoning` inherits from
`font-lock-comment-face` + `italic`, which renders as grey italic on most
themes (light and dark).  No new face needed.

Apply it *after* fontification so the baseline face survives on
un-fontified characters (font-lock-face wins on styled tokens):

```elisp
;; Current (line 332): fontification before face property
(insert (hermes-section--fontify-org
         (concat c (if (or (string-empty-p c)
                           (string-suffix-p "\n" c))
                       "" "\n"))))

;; Fixed: wrap fontified result with baseline face, preserving the
;; trailing-newline logic from the current code
(insert (propertize
         (hermes-section--fontify-org
          (concat c (if (or (string-empty-p c)
                            (string-suffix-p "\n" c))
                        "" "\n")))
         'face 'hermes-section-face-reasoning))
```

The heading line already uses `hermes-section-face-reasoning` per Plan 08.
This change extends it to the body text as well.  If Plan 10 `--fontify-org`
converts face → font-lock-face on stylable tokens, the baseline `face`
property fills un-fontified characters — plain prose in reasoning still
renders grey.

---

## 5. Subagent notes

### 5.1 Current (Plan 08)

Subagent body shows thinking, tools, and result:

```
thinking: <text>
tools:
  - tool1(args)
result: <summary> (1.2s)
```

`hermes-subagent.notes` (vector of strings) is not displayed.

### 5.2 Target

Notes appear between thinking and tools:

```
thinking: <text>
notes:
  - Checking dependencies...
  - Running tests...
tools:
  - tool1(args)
  - tool2(args)
result: verified (1.2s)
```

### 5.3 Implementation

Two functions need notes inserted (between thinking and tools):

**`hermes-section--subagent-body` (line 388)** — test-only stringifier.
Current body: `thinking: ...\ntools:\n...\nresult: ...`.  Add a notes
block after thinking:

```elisp
;; In the let binding at lines 390–395, add notes:
(let ((parts nil)
      (thinking (hermes-subagent-thinking sa))
      (notes    (hermes-subagent-notes sa))        ;; NEW
      (tools    (hermes-subagent-tools sa))
      (summary  (hermes-subagent-summary sa))
      (status   (hermes-subagent-status sa))
      (dur      (hermes-section--format-duration (hermes-subagent-duration sa))))
  ;; ...
  ;; After the thinking push:
  (when (and (vectorp notes) (> (length notes) 0))
    (push "notes:\n" parts)
    (dotimes (i (length notes))
      (push (format "  - %s\n" (aref notes i)) parts)))
  ;; ...)
```

**`hermes-section--insert-subagent-child` (line 418)** — production
renderer.  Current body: thinking → tools → result.  Add the same notes
block between the thinking `(insert ...)` and the tools `(when ...)`
blocks.

Note: `(when-let ((t ...)))` in the colleague's original example shadows
the symbol `t`.  Use a non-shadowing variable name: `text` or `body-text`.

---

## 6. Amended assistant body structure

After all changes, the final body layout for an assistant turn:

```
├─ Reasoning                    ← always first (collapsed, grey text)
│   Let me think about this...
  Sure, 2+2 is 4.               ← response text (all text segments joined)
  The answer is four.           ← no bg tint (per Plan 09)
  ───
├─ DONE calculator (0.3s)       ← tools in arrival order
│   input: expression=2+2
│   result: 4  (0.3s)
├─ DONE grep pattern (0.1s)
│   input: pattern=error
│   result: 3 matches  (0.1s)
└─ verify (complete)            ← subagent (collapsed)
    thinking: double-checking...
    notes:
      - Checking dependencies...
      - Running tests...
    tools:
      - calculator(2+2)
    result: verified (1.2s)
```

---

## 7. Scope

Amends Plan 08 (turn structure, child section rendering, helper functions).
All other Plan 08 rules (section classes, faces, bg tint, section identity,
streaming exclusion) are unchanged.  Only `hermes-section.el` is touched.

**Test impact:** existing tests that assert on heading text (e.g.
`--heading-text` returning a first non-blank line) will fail — the heading
is now turn-number-based.  Update test expectations to match
`"#N · Kind"` format.  Tests for `--subagent-body` need new assertions
for the `notes:` block.  `eldev test` will catch all breakage.
