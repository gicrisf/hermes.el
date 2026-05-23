# PLAN: hermes-section semantic presentation

## 1. Motivation

The hermes-section magit-section viewer currently displays every turn as a
single flat text blob.  All segments (text, reasoning, tools, subagents) are
concatenated into one undifferentiated body or lost entirely (tools are
skipped).  The Org renderer, by contrast, breaks each turn into typed child
headings with proper segment structure.

This plan adds segment-aware child sections to `hermes-section-mode`.  The
Org renderer and the section viewer are two visualizations of the same data
— mirrors, not divergents.  This plan matches the Org renderer's semantic
richness in the magit-section presentation without touching the Org
renderer at all.

### 1.1 Current state

```
U: what is 2+2?              ← single section, flat text
  what is 2+2?

A: Sure, 2+2 is 4            ← single section, all segments merged flat
  Sure, 2+2 is 4.            ← tools + reasoning lost entirely
```

`hermes-section--message-text` concatenates text + reasoning into one
string.  `hermes-section--format-body` strips Org artifacts.  Tool and
subagent data is discarded — it never reaches the viewer.

### 1.2 Target state

magit-section headings must be single-line (enforced by the framework).
The heading is the first non-blank line — a quick-reference label.  The
body contains the full text verbatim plus metadata and child sections.
Background tinting distinguishes the writer — no `U:`/`A:`/`S:` prefixes.

```
what is 2+2?                              ← heading: first non-blank line (warm bg)
  what is 2+2?                            ← body: full question text verbatim
  ---
  submitted at 2026-05-14T03:56:12+0200   ← body: metadata
  model: deepseek-v4-flash
  [image: screenshot.png]                 ← body: image placeholders

Sure, 2+2 is 4.                           ← heading: first non-blank line (cool bg)
  Sure, 2+2 is 4.                         ← body: full response text verbatim
  So the calculation is straightforward.
  The answer is four.
├─ Reasoning                              ← body: reasoning child (collapsed)
├─ DONE calculator (0.3s) — computed 2+2  ← body: tool child (collapsed)
│   input: expression=2+2
│   result: 4  (0.3s)
├─ DONE read file.txt (0.1s)              ← body: tool child (collapsed)
│   input: file=file.txt
│   result: content of file.txt  (0.1s)
└─ verify (complete)                      ← body: subagent child (collapsed)
    thinking: double-checking...
    tools:
      - calculator(2+2)
    result: verified (1.2s)
```

For expanded assistant turns (the default), the full response text is
immediately visible in the body.  For collapsed user turns, only the
first-line heading is visible until expanded — the expand label serves as
a conversation index.

### 1.3 Key design decisions

| Decision | Rationale |
|----------|-----------|
| No `U:`/`A:`/`S:` prefix | Background color already distinguishes the writer |
| Heading = first non-blank line | magit-section requires single-line headings |
| Body = full text verbatim | No excerpt, no truncation — the heading is just a label |
| No `Response` child section | Response text is in the turn body directly; body children are metadata only |
| All text segments joined | Interleaved text chunks concatenated into heading + body |
| Assistant body = full text + child sections | Full response visible first, then collapsible supporting cast |
| User body = full text + metadata | Question text visible when expanded, with timestamp/usage |
| Plain text only | No Org markup, no tool formatters dependency |
| Raw gateway text | Segment content is stored as raw markdown — displayed as-is in the plain-text viewer; `hermes-md-to-org` is not invoked here (it produces Org tokens that render as ugly literal text in a non-org-mode buffer) |

---

## 2. Scope

- **Committed turns only.**  Streaming (append-only markers during live
  turns) is deferred to a future plan.  This plan improves the visual
  presentation of already-finished conversation turns.

- **`hermes-section.el` only.**  No other file is touched.  The Org
  renderer, state layer, tool formatters, and entry points stay unchanged.

- **Simplified tool display.**  Tool bodies are plain text — status,
  duration, context string verbatim, result (output ∥ summary ∥ "(no result)").
  No Org markup, no `hermes-tool-formatters.el` dependency.

- **Section background tinting.**  Each turn section gets a tinted
  background distinguishable by writer role, via text properties.

---

## 3. Section classes

Keep the three existing turn-level classes.  Add three new child classes
(for the supporting cast in assistant body):

| Class | Parent | hide | value (identity) | Purpose |
|-------|--------|------|------------------|---------|
| `hermes-section-turn-section` | `magit-section` | — | `hermes-message-id` | Base class (exists) |
| `hermes-section-user-section` | `hermes-section-turn-section` | `t` | `hermes-message-id` | User turn (exists) |
| `hermes-section-assistant-section` | `hermes-section-turn-section` | `nil` | `hermes-message-id` | Assistant turn (exists) |
| `hermes-section-system-section` | `hermes-section-turn-section` | `nil` | `hermes-message-id` | System turn (exists) |
| `hermes-section-reasoning-section` | `magit-section` | `t` | `hermes-segment-id` | `reasoning` segment |
| `hermes-section-tool-section` | `magit-section` | `t` (complete) | `hermes-tool-id` | `tool` segment |
| `hermes-section-subagent-section` | `magit-section` | `t` | `hermes-subagent-id` | `hermes-subagent` entry |

Stable unique identities are required for `magit-section-cache-visibility`
to persist collapse states across rebuilds.  Using `hermes-segment-id` for
reasoning children ensures two reasoning segments in the same turn don't
collide (each gets its own stable identity via `hermes-segment.id`).

No `Response` child section class — response text is in the turn body
directly (above any child sections).

`system` segments inside assistant turns: **skip entirely in v1.**  They
are ephemeral gateway metadata, not conversation content.

---

## 4. Faces

### 4.1 Background faces

```elisp
(defface hermes-section-bg-user
  '((((background dark)) :background "#3a3530")
    (t                  :background "#f0ebe3"))
  "Warm tint for user turn sections.")

(defface hermes-section-bg-assistant
  '((((background dark)) :background "#2e3640")
    (t                  :background "#e8edf3"))
  "Cool tint for assistant turn sections.")

(defface hermes-section-bg-system
  '((((background dark)) :background "#353035")
    (t                  :background "#f5f0eb"))
  "Subtle tint for system turn sections.")
```

Each face ships with a `(background dark)` clause so hermes-doom and other
dark themes get correct tints out of the box.

### 4.2 Child-section heading faces

| Face | Inherits | Use |
|------|----------|-----|
| `hermes-section-face-user` | `font-lock-keyword-face :weight bold` | User heading (exists) |
| `hermes-section-face-assistant` | `font-lock-function-name-face :weight bold` | Assistant heading (exists) |
| `hermes-section-face-system` | `font-lock-builtin-face` | System heading (exists) |
| `hermes-section-face-reasoning` | `italic` `font-lock-comment-face` | Reasoning heading |
| `hermes-section-face-tool` | `font-lock-keyword-face` | Tool heading base |
| `hermes-section-face-tool-done` | `font-lock-doc-face` | Tool DONE keyword |
| `hermes-section-face-tool-error` | `font-lock-error-face` | Tool ERROR keyword |
| `hermes-section-face-tool-running` | `font-lock-warning-face` | Tool RUNNING keyword |
| `hermes-section-face-subagent` | `font-lock-builtin-face :weight bold` | Subagent heading |

---

## 5. Turn structure

### 5.1 User turn

- **Heading:** first non-blank line of the joined text segments.  Text
  properties: `hermes-section-face-user` + `hermes-section-bg-user`.
- **Body:** full question text verbatim (all paragraphs, excluding the
  first non-blank line when it equals the heading verbatim — avoids
  redundant duplication; comparison is against raw segment content).
  Then metadata, then image placeholders.  Collapsed by default.

Body content:
```
<full question text>          ← text segments joined with "\n"; skip line 1
                                when it equals the heading verbatim
---
submitted at <hermes-message.timestamp>
model: <model from session info>
tokens: <sent+received from hermes-message.usage>
        usage keys: "tokens_sent" + "tokens_received"
        (or "input_tokens" + "output_tokens" as fallback)
[image: filename]             ← for each image segment
```

### 5.2 Assistant turn

- **Heading:** first non-blank line of the joined text segments.  Text
  properties: `hermes-section-face-assistant` + `hermes-section-bg-assistant`.
- **Body:** full response text verbatim (all paragraphs, excluding the
  first non-blank line when it equals the heading verbatim),
  then a separator, then child sections — reasoning, tools, subagents —
  in arrival order (matching the segment vector order).  Expanded by default.

Body content:
```
<full response text>          ← all text segments joined with "\n"
───
├─ Reasoning                  ← reasoning child sections (collapsed)
├─ DONE toolname (0.3s)       ← tool child sections (collapsed)
└─ goal (status)              ← subagent child sections (collapsed)
```

When there are no text segments (a pure tool-execution turn), the heading
is `"(tool-only turn)"` and the full response text block is absent.

### 5.3 System turn

- **Heading:** first non-blank line of the system message text.  Text
  properties: `hermes-section-face-system` + `hermes-section-bg-system`.
- **Body:** full system message text, then timestamp + model metadata.
  Expanded by default.

---

## 6. Child section details

### 6.1 Reasoning → `hermes-section-reasoning-section`

- **Heading:** `"Reasoning"` with `hermes-section-face-reasoning`
- **Body:** chain-of-thought text as raw markdown from the segment
- **Collapsed** by default

### 6.2 Tool → `hermes-section-tool-section`

- **Heading:** `"KEYWORD toolname (0.3s) — summary"` where:
  - `KEYWORD` face depends on status:
    - `RUNNING` → `hermes-section-face-tool-running`
    - `DONE` → `hermes-section-face-tool-done`
    - `ERROR` → `hermes-section-face-tool-error`
  - `toolname` from `hermes-tool-name`
  - `(0.3s)` from `hermes-tool-duration` (omitted if nil)
  - `— summary` from `hermes-tool-summary` (omitted if empty)
- **Body** (plain text):
  ```
  input: <tool.context verbatim>       ← verbatim string (no key=val parsing)
  result: <result string>  (0.3s)      ← output ∥ summary ∥ "(no result)", duration appended
  ```
  If `hermes-tool.error` is non-nil:
  ```
  input: <tool.context verbatim>
  error: <error text>  (0.3s)
  ```
  The result line uses precedence: `hermes-tool.output` if non-nil,
  else `hermes-tool.summary`, else `"(no result)"`.  Duration is
  appended in `(0.3s)` format — mirrors the Org renderer's tool heading.
  The tool name is already in the heading; duplicating it as the result
  body is noise.
- **Collapsed** by default when status is `complete` or `error`

The gateway already collapses tool arguments to a context summary string
(per `CLAUDE.md`).  `hermes-tool.context` is rendered verbatim under `input:`
— no JSON parse, no key=val extraction.

Do **not** call `hermes-tool-formatters.el`.  Those produce Org markup
blocks (`#+begin_example`, `#+name:`, todos tables) unsuitable for a
plain-text magit-section viewer.  Extract raw fields from `hermes-tool`
structs directly.

### 6.3 Subagent → `hermes-section-subagent-section`

- **Heading:** `"goal-text (status)"` with `hermes-section-face-subagent`
  - `goal-text` from `hermes-subagent-goal`
  - `status` from `hermes-subagent-status`
- **Body:**
  ```
  thinking: <hermes-subagent-thinking text>
  tools:
    - tool1(args)
    - tool2(args)
  result: <hermes-subagent-summary>        (if complete/error, with duration)
  ```
- **Collapsed** by default

---

## 7. Background tinting approach

Use **text properties** on every character inserted within a turn section:

```elisp
(insert (propertize text 'face (list heading-face bg-face)))
```

**Face stacking order matters.**  When `'face` is a list, later faces win
for conflicting attributes.  The heading face goes first (foreground color),
the background face second (background).  Both are applied to every inserted
character — heading and body alike.

```elisp
;; Heading line: both faces, heading face first for foreground priority
(propertize "...first line..." 'face (list 'hermes-section-face-assistant
                                          'hermes-section-bg-assistant))

;; Body text: background only (inherits default foreground)
(propertize "...full response..." 'face 'hermes-section-bg-assistant)

;; Child section heading: child face + background
(propertize "Reasoning" 'face (list 'hermes-section-face-reasoning
                                    'hermes-section-bg-assistant))
```

**Highlight overlay compatibility.**  `magit-section-highlight` uses
overlays which paint over text properties, so the bg tint via text
properties will coexist correctly with selection highlighting.  Verify
during implementation.

Drawback: background doesn't extend to the full window width (only covers
text characters).  Acceptable for v1; full-width overlays can be added
later if desired.

---

## 8. `hermes-section--insert-turn` rewrite

Current logic (~15 lines):

```elisp
(defun hermes-section--insert-turn (msg)
  ;; 1. Extract flat text from text + reasoning segments
  ;; 2. Create one magit section with heading (excerpt) + flat body
  ;; 3. Done
```

New logic (~70 lines):

```elisp
(defun hermes-section--insert-turn (msg)
  ;; 1. Determine turn kind → faces, bg face, hide default
  ;; 2. Build heading text = first non-blank line of text segments
  ;;    (raw segment content; no markdown conversion)
  ;; 3. Create parent turn section with magit-insert-section
  ;;    - Heading = heading-text with (list heading-face bg-face) property
  ;; 4. In magit-insert-section-body washer:
  ;;    a. Insert full text (text segments joined with "\n"),
  ;;       dedup first line when it equals heading, bg-face property
  ;;    b. User turn: insert "---" separator, then timestamp + model + usage + images
  ;;    c. Assistant turn: insert "───" separator, then iterate segments:
  ;;       - reasoning → hermes-section--insert-reasoning-child
  ;;       - tool → hermes-section--insert-tool-child
  ;;       - system → skip
  ;;       - image → skip
  ;;       Then iterate subagents → hermes-section--insert-subagent-child
  ;;    d. System turn: insert timestamp + model metadata
```

Helper functions added:

| Function | Purpose |
|----------|---------|
| `hermes-section--heading-text` | Return first non-blank line of raw text segment contents |
| `hermes-section--body-text` | Return raw text segment contents joined with `"\n"` |
| `hermes-section--insert-user-body` | Insert body text + `---` + timestamp/model/usage/images |
| `hermes-section--insert-reasoning-child` | Insert collapsed reasoning section (raw text body) |
| `hermes-section--insert-tool-child` | Insert collapsed tool section (plain text body) |
| `hermes-section--insert-subagent-child` | Insert collapsed subagent section |
| `hermes-section--tool-body` | Build `input:` / `result:` plain-text body for a `hermes-tool` |
| `hermes-section--subagent-body` | Build plain-text body for a `hermes-subagent` |

Functions removed or replaced:

| Old function | Fate |
|-------------|------|
| `hermes-section--message-text` | Replaced by `--heading-text` + `--body-text` (both operate on raw segment content) |
| `hermes-section--excerpt` | Removed — heading is first non-blank line, no truncation |
| `hermes-section--format-body` | Removed — it stripped Org artifacts from already-Org-formatted text; raw markdown segments have no Org drawers/blocks to strip |

---

## 9. Data model (unchanged)

Read from the existing structs — no new fields, no state layer changes:

| Source | Struct field | Use |
|--------|-------------|-----|
| `hermes-message.kind` | `'user \| 'assistant \| 'system` | Turn class + bg face |
| `hermes-message.segments` | `[hermes-segment, ...]` | Text → heading + body; others → child sections |
| `hermes-segment.type` | `'text \| 'reasoning \| 'tool \| 'system \| 'image` | Dispatch |
| `hermes-segment.content` | string / `hermes-tool` / plist | Body content |
| `hermes-message.timestamp` | ISO-8601 string | User/System body metadata |
| `hermes-message.usage` | hash-table | User body metadata |
| `hermes-message.subagents` | `[hermes-subagent, ...]` | Subagent child sections |
| `hermes-message.id` | string like `"msg-42"` | Section identity |

---

## 10. What stays unchanged

- `hermes-section--rebuild` — erase-buffer + full rebuild pattern
- `hermes-section--refresh` — same state-change-hook dispatch
- `hermes-section-mode` — keymap, mode definition, derived from
  `magit-section-mode`
- `hermes-section--open` / `hermes-section` / `hermes-section-export` /
  `hermes-section-fork-from-org` — all entry points
- `hermes--sessions` global table
- `hermes--on-session-buffer` dispatch
- No new dependencies (magit-section already required)
- No Org renderer changes
- No state layer changes
- No tool formatters dependency

---

## 11. Edge cases

| Case | Handling |
|------|----------|
| Turn with zero text segments | User: `"(empty)"` heading.  Assistant: `"(tool-only turn)"` heading + expanded tool children. |
| Assistant with no tools/reasoning/subagents | Heading = first line; body = full response text; no child sections |
| User turn with images | `[image: filename]` placeholders in body after metadata |
| Tool without `context` field | `input: (no input)` |
| Tool without `output`, `summary`, or `name` | `result: (no result)  (0.3s)` |
| Tool with `error` | `input: <context>` + `error: <error text>  (0.3s)`; heading gets `ERROR` keyword |
| Subagent without `thinking` | Omit thinking block |
| Subagent with empty `tools` vector | Omit tools list |
| System message | Flat heading + full text + timestamp/model body; no child sections |
| Image segment (any turn) | Assistant: skip (response text covers it).  User: `[image: filename]` in body. |

---

## 12. Testing strategy

- Unit tests for `hermes-section--heading-text`, `hermes-section--body-text`,
  `hermes-section--tool-body`, `hermes-section--subagent-body`: build
  structs with raw markdown content, call function, assert plain-text result.
- E2E test: create a session with user + assistant turns (including
  reasoning, tools, subagents), open `hermes-section`, assert section tree
  structure, collapsed states, and background face properties.
- Regression check: `hermes-section--message-text`, `--excerpt`, and
  `--format-body` are removed — grep the test suite for callers and update
  or delete tests accordingly before removing them.  No other module
  references these functions.
