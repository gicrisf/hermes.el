# Plan: Context-Aware `M-x hermes` Entry Point + Tagless Turn Headings

## Context
The bench (`hermes-bench.el`) is now the primary interactive surface and already shows a splash. The old dashboard buffers were removed in a previous iteration. `M-x hermes` was rewritten as a context-aware dispatcher, but two issues remain:

1. It still always creates a **new** Hermes heading when called from an Org buffer, even if point is already inside an existing session. The user expects `M-x hermes` to behave like "open Hermes here" — reuse, resume, or create.
2. Turn headings (`:user:`, `:hermes:`, `:system:` tags) clutter the Org outline and make sparse-tree searches noisy. Replacing them with `U:`, `A:`, `S:` prefixes keeps headings readable while removing the tag noise.

## Goals
1. `M-x hermes` must **never** auto-trigger a prompt/send.
2. When invoked from a `hermes-mode` buffer, ensure the bench is visible and focus its input area.
3. When invoked from a generic `org-mode` buffer:
   - If point is already inside a Hermes container with an **active** session → just ensure the bench and focus it.
   - If point is inside a Hermes container with a **stale** session ID → resume it via `hermes--resume-heading-session`.
   - If point is **not** inside any Hermes container → create a new heading-scoped session as a direct child of the Org heading at/above point.
4. When invoked from anywhere else, fall back to the primary session (create if none).
5. Remove `hermes-create-session-here`; it is superseded by the smarter `M-x hermes`.
6. Replace turn heading tags (`:user:`, `:hermes:`, `:system:`) with inline prefixes (`U:`, `A:`, `S:`).
7. Make container detection robust: a heading is a container if it has **either** the `:hermes:` tag **or** the `HERMES_SESSION` property.

---

## Proposed Changes

### 1. `hermes-org.el` — Safer container detection

Change `hermes--heading-is-container-p` to accept either the tag or the property:

```elisp
(defun hermes--heading-is-container-p ()
  "Non-nil if point is on a Hermes session container heading.
Recognises both the `:hermes:' tag and the `HERMES_SESSION' property,
so restored files (which may have lost the tag) and freshly-inserted
headings (which may not yet have the property) both work."
  (and (derived-mode-p 'org-mode)
       (org-at-heading-p)
       (or (member "hermes" (org-get-tags nil t))
           (org-entry-get (point) "HERMES_SESSION"))))
```

**Why:** Restored Org files may have the property but lack the tag (user edited it away, or the file was generated). Fresh headings have the tag before `session.create` assigns the property. Either signal is sufficient.

---

### 2. `hermes-render.el` — Tagless turn headings with prefixes

#### 2a. `hermes--turn-tags`

Return an empty string for all kinds. The function is kept (rather than deleted) because `hermes--insert-turn-headline` and `hermes--finalize-assistant-heading` both call it, and the empty-string path simplifies the call sites:

```elisp
(defun hermes--turn-tags (_kind &optional _model)
  "Return the tag string for a turn.
Previously returned `:user:', `:system:', or `:hermes:'.  Now always
returns the empty string — turn kinds are expressed via the `U:' / `S:'
/ `A:' prefix in the heading text instead."
  "")
```

#### 2b. `hermes--insert-turn-headline`

Prepend a prefix to the excerpt based on `kind`:

```elisp
(defun hermes--insert-turn-headline (msg face)
  "Insert a turn heading for user, system, or assistant MSG."
  (let* ((kind     (hermes-message-kind msg))
         (text     (hermes--message-text-for-display msg))
         (prefix   (pcase kind
                     ('user      "U: ")
                     ('system    "S: ")
                     ('assistant "A: ")))
         (excerpt  (concat prefix (hermes--heading-excerpt text)))
         (heading  (format "%s %s" (hermes--stars 1) excerpt))
         (tags     (hermes--turn-tags kind))
         ...)
    ...))
```

When `tags` is empty, `hermes--tag-spacer` returns a single space and the heading line becomes simply:

```
** U: What is the capital of France?
```

instead of:

```
** What is the capital of France?                                              :user:
```

#### 2c. `hermes--stream-begin`

Change the streaming assistant heading from:

```elisp
(let* ((...)
       (short   (or (hermes--model-short-name model) ""))
       (heading (format "%s %s" (hermes--stars 1) short))
       (tags    ":hermes:")
       ...)
  (insert (format "%s %s %s\n"
                  heading (hermes--tag-spacer heading tags) tags)))
```

to:

```elisp
(let* ((...)
       (short   (or (hermes--model-short-name model) ""))
       (prefix  (if (string-empty-p short) "A: " (concat "A: " short " ")))
       (heading (format "%s %s" (hermes--stars 1) prefix))
       (tags    "")
       ...)
  (insert heading "\n"))
```

Result during streaming:

```
** A: deepseek-v4-flash
```

#### 2d. `hermes--finalize-assistant-heading`

Same prefix logic. Rewrite the in-flight heading to:

```elisp
(let* ((text     (hermes--message-text-for-display msg))
       (excerpt  (concat "A: " (hermes--heading-excerpt text)))
       (heading  (format "%s %s" (hermes--stars 1) excerpt))
       ...)
  ...)
```

Result after commit:

```
** A: Paris is the capital of France.
```

---

### 3. `hermes-mode.el` — Rewrite `hermes` as context-aware dispatcher

Same three-way `cond`, but with updated terminology ("Hermes container" instead of ":hermes: container"):

```elisp
(defun hermes ()
  "Context-aware entry point — never sends a prompt.
- In a `hermes-mode' buffer: ensure the bench is visible and focus its
  input area.
- In a generic `org-mode' buffer: if point is inside an existing Hermes
  session container, resume or continue it; otherwise create a new
  Hermes session heading under the heading at/above point.
- Everywhere else: pop the most-recently-touched live session, or
  create a fresh one if none exists."
  (interactive)
  (cond
   ;; Case A: already inside a dedicated hermes buffer -> re-spawn bench
   ((derived-mode-p 'hermes-mode)
    (hermes-bench-ensure (current-buffer))
    (when-let ((bench (hermes-bench-active-p))
               (win  (get-buffer-window bench)))
      (select-window win)
      (goto-char (point-max))))

   ;; Case B: inside a generic org buffer
   ((derived-mode-p 'org-mode)
    (let* ((marker (hermes--container-marker-at-point))  ; nearest container
           (sid    (and marker (hermes--session-at-point))) ; HERMES_SESSION
           (state  (and sid (hermes--lookup-session-state sid))))
      (cond
       ;; B1: active session at point -> just show/focus bench
       (state
        (hermes-bench-ensure (current-buffer))
        (when-let ((bench (hermes-bench-active-p))
                   (win  (get-buffer-window bench)))
          (select-window win)
          (goto-char (point-max))))
       ;; B2: stale session heading -> resume it (rebuilds state, shows bench)
       (sid
        (hermes--resume-heading-session sid))
       ;; B3: no hermes container -> create new heading + session
       (t
        (hermes--create-session-under-heading)))))

   ;; Case C: everywhere else -> primary session fallback
   (t
    (let ((buf (hermes--primary-session-buffer)))
      (if buf
          (pop-to-buffer buf)
        (hermes-new-session
         (lambda (b) (when (buffer-live-p b) (pop-to-buffer b)))))))))
```

---

### 4. `hermes-mode.el` — `hermes--create-session-under-heading`

Unchanged from the previous plan. This helper is only reached in **Case B3** when there is no existing Hermes container.

**Algorithm:**
1. Ensure `hermes-minor-mode` is enabled.
2. Call `hermes--install-hooks` and start the gateway if down.
3. Save excursion, move to the nearest heading at/above point (`org-back-to-heading t`).
4. Compute `container-level`:
   - If a heading is found: `(org-current-level) + 1`
   - If no heading is found: default to `1`
5. Move to the **end of that subtree** (`org-end-of-subtree t t`) and insert the new heading.
6. Set `hermes--container-level` buffer-locally.
7. Fire `session.create` and register the callback (write `HERMES_SESSION`, build state, register in registries, show bench, dispatch `gateway.ready`).

The **session container heading** keeps its `:hermes:` tag:

```
*** Hermes session :hermes:
```

Only **turn headings** lose their tags.

---

### 5. `hermes-mode.el` — Remove `hermes-create-session-here`

Delete the function definition entirely. This reduces the autoloaded command surface to a single entry point: `hermes`.

---

### 6. Tests

The following test assertions must be updated to match the new heading format:

| File | Old assertion pattern | New assertion pattern |
|------|----------------------|----------------------|
| `test/hermes-input-test.el` | `:user:` in heading | `U:` prefix in heading text |
| `test/hermes-render-test.el` | `:hermes:` / `:user:` / `:system:` tag counts | Prefix checks (`"U: "`, `"A: "`, `"S: "`) |
| `test/hermes-render-test.el` | `:hermes:` in `** assistant` line | `A:` prefix |
| `test/hermes-org-test.el` | `:hermes:` tag in container headings | keep as-is (container tags stay) |

The container headings in `test/hermes-org-test.el` (`* Research chat :hermes:`) do **not** change — only turn headings change.

---

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| Point inside Hermes container with **active** state | Show/focus bench. No new heading created. |
| Point inside Hermes container with **stale** `HERMES_SESSION` | Resume via `hermes--resume-heading-session`. Bench appears when state rebuilds. |
| Point inside Hermes container with **no** `HERMES_SESSION` property | Falls through to B3 (create new heading). |
| Point in org buffer but **before any heading** and no container | Default `container-level = 1`. Insert top-level `* Hermes session` at end of file. |
| Point inside a `hermes-mode` bench buffer | `derived-mode-p 'hermes-mode` is nil, so falls through to Case C (pop primary session). |
| Org buffer already has `hermes-minor-mode` on | Idempotent; works fine. |
| Multiple Hermes sessions in the same org file at different levels | `hermes--container-level` is buffer-local, so only the *last touched* session's level wins for rendering. Pre-existing limitation, out of scope. |

## Out of Scope
- Dashboard files: already removed.
- Splash logic: already implemented in `hermes-bench.el`.
- `AGENTS.md` updates: only necessary after implementation.
- History seeding for resumed sessions: `hermes--resume-heading-session` rebuilds local state only; gateway history seeding is a separate enhancement.
