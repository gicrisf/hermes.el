# Plan: Context-Aware `M-x hermes` Entry Point

## Context
The bench (`hermes-bench.el`) is now the primary interactive surface and already shows a splash. The old dashboard buffers were removed in the previous iteration. `M-x hermes` was rewritten as a context-aware dispatcher, but it still always creates a **new** Hermes heading when called from an Org buffer. The user expects `M-x hermes` to behave like "open Hermes here" — if point is already inside an existing `:hermes:` session, it should resume/continue that conversation instead of spawning a nested container.

## Goals
1. `M-x hermes` must **never** auto-trigger a prompt/send.
2. When invoked from a `hermes-mode` buffer, ensure the bench is visible and focus its input area.
3. When invoked from a generic `org-mode` buffer:
   - If point is **already inside** a `:hermes:` container with an **active** session → just ensure the bench and focus it.
   - If point is inside a `:hermes:` container with a **stale** session ID (heading has `HERMES_SESSION` property but no in-memory state) → resume it via `hermes--resume-heading-session`.
   - If point is **not** inside any `:hermes:` container → create a new heading-scoped session as a direct child of the Org heading at/above point.
4. When invoked from anywhere else, fall back to the primary session (create if none).
5. Remove `hermes-create-session-here`; it is superseded by the smarter `M-x hermes`.

## Proposed Changes

### 1. `hermes-mode.el` — Rewrite `hermes` as context-aware dispatcher

Replace the body of `hermes` with a three-way `cond` where the Org branch adds a container check:

```elisp
(defun hermes ()
  "Context-aware entry point — never sends a prompt.
- In a `hermes-mode' buffer: ensure the bench is visible and focus its
  input area.
- In a generic `org-mode' buffer: if point is inside an existing
  `:hermes:' session, resume or continue it; otherwise create a new
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
    (let* ((marker (hermes--container-marker-at-point))  ; nearest :hermes: ancestor
           (sid    (and marker (hermes--session-at-point))) ; HERMES_SESSION property
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

### 2. `hermes-mode.el` — New `hermes--create-session-under-heading`

Unchanged from the previous plan. This helper is only reached in **Case B3** when there is no existing `:hermes:` container.

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

**Example:**
```
* My first title
** My second title

[] <- point is here
```
Running `M-x hermes` produces:
```
* My first title
** My second title
*** Hermes session :hermes:
```

### 3. `hermes-mode.el` — Remove `hermes-create-session-here`

Delete the function definition entirely. This reduces the autoloaded command surface to a single entry point: `hermes`.

### 4. `hermes-org.el` — Resume helpers already exist

The following helpers from `hermes-org.el` are reused without modification:
- `hermes--container-marker-at-point` — finds the nearest `:hermes:` ancestor.
- `hermes--session-at-point` — extracts the `HERMES_SESSION` property.
- `hermes--lookup-session-state` — checks if the session is active in memory.
- `hermes--resume-heading-session` — fires `session.resume` and rebuilds state on success, or creates a fresh session on failure.

**No changes needed** in `hermes-org.el`.

### 5. Bench re-spawn details (Cases A and B1)

`hermes-bench-ensure` is idempotent: it reuses an existing bench buffer if live, recreates it if killed, and calls `display-buffer-in-side-window` to ensure the window exists. Calling it again from `hermes` is sufficient.

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| Point inside `:hermes:` container with **active** state | Show/focus bench. No new heading created. |
| Point inside `:hermes:` container with **stale** `HERMES_SESSION` | Resume via `hermes--resume-heading-session`. Bench appears when state rebuilds. |
| Point inside `:hermes:` container with **no** `HERMES_SESSION` property | Falls through to B3 (create new heading). This is an edge case for manually-inserted headings. |
| Point in org buffer but **before any heading** and no `:hermes:` ancestor | Default `container-level = 1`. Insert top-level `* Hermes session` at end of file. |
| Point inside a `hermes-mode` bench buffer | `derived-mode-p 'hermes-mode` is nil, so falls through to Case C (pop primary session). |
| Org buffer already has `hermes-minor-mode` on | Idempotent; works fine. |
| Multiple Hermes sessions in the same org file at different levels | `hermes--container-level` is buffer-local, so only the *last touched* session's level wins for rendering. This is a pre-existing limitation and is out of scope. |

## Out of Scope
- Dashboard files: already removed in a previous iteration.
- Splash logic: already implemented in `hermes-bench.el`.
- `AGENTS.md` updates: only necessary after implementation is done.
- History seeding for resumed sessions: the `hermes--resume-heading-session` path currently does not seed history into the gateway; it only rebuilds the local state atom. If gateway `session.resume` supports history, that would be a separate enhancement.
