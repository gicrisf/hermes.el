# Plan: Context-Aware `M-x hermes` Entry Point

## Context
The bench (`hermes-bench.el`) is now the primary interactive surface and already shows a splash. The old dashboard buffers (`hermes-dashboard.el`, `doom-dashboard-hermes.el`) were removed in the previous iteration. The remaining gap is that `M-x hermes` still behaves as a blunt "new session or primary session" switch. It should be context-aware so the user can invoke it from anywhere and get the right result.

## Goals
1. `M-x hermes` must **never** auto-trigger a prompt/send.
2. When invoked from a `hermes-mode` buffer, ensure the bench is visible and focus its input area.
3. When invoked from a generic `org-mode` buffer, create a heading-scoped Hermes session as a **direct child** of the Org heading at/above point.
4. When invoked from anywhere else, fall back to the primary session (create if none).
5. Remove `hermes-create-session-here`; it is superseded by the smarter `M-x hermes`.

## Proposed Changes

### 1. `hermes-mode.el` — Rewrite `hermes` as context-aware dispatcher

Replace the body of `hermes` with a three-way `cond`:

```elisp
(defun hermes ()
  "Context-aware entry point.
- In a `hermes-mode' buffer: ensure the bench is visible and focus it.
- In a generic `org-mode' buffer: create a Hermes session heading under
  the heading at point.
- Everywhere else: switch to the primary session or create a new one."
  (interactive)
  (cond
   ;; Case A: already inside a dedicated hermes buffer -> re-spawn bench
   ((derived-mode-p 'hermes-mode)
    (hermes-bench-ensure (current-buffer))
    (when-let ((bench (hermes-bench-active-p))
               (win  (get-buffer-window bench)))
      (select-window win)
      (goto-char (point-max))))

   ;; Case B: inside a generic org buffer -> heading-scoped session
   ((derived-mode-p 'org-mode)
    (hermes--create-session-under-heading))

   ;; Case C: everywhere else -> primary session fallback
   (t
    (let ((buf (hermes--primary-session-buffer)))
      (if buf
          (pop-to-buffer buf)
        (hermes-new-session
         (lambda (b) (when (buffer-live-p b) (pop-to-buffer b)))))))))
```

### 2. `hermes-mode.el` — New `hermes--create-session-under-heading`

This is a context-aware sibling of the old `hermes-create-session-here`. It derives the heading level from the Org outline rather than hard-coding level 1, and inserts at the **end of the subtree** so it never splits body text.

**Algorithm:**
1. Ensure `hermes-minor-mode` is enabled in the current buffer.
2. Call `hermes--install-hooks` and start the gateway if down.
3. Save excursion, move to the nearest heading at/above point (`org-back-to-heading t`).
4. Compute `container-level`:
   - If a heading is found: `(org-current-level) + 1`
   - If no heading is found (point is before any heading): default to `1`
5. Move to the **end of that subtree** (`org-end-of-subtree t`) so the new heading is inserted as the last child.
6. Ensure a newline, then insert:
   ```
   <stars> Hermes session :hermes:
   ```
   where `<stars>` is `(make-string container-level ?*)`.
7. Place a marker at the new heading position.
8. Set `hermes--container-level` buffer-locally to `container-level` so that turn insertion (`hermes--stars`) uses the correct relative depth.
9. Fire `session.create` and, in the callback:
   - Write `:HERMES_SESSION:` on the heading.
   - Build state, register in `hermes--buffer-sessions` / `hermes--session-markers`.
   - Put the buffer into `hermes--session-buffers`.
   - Dispatch cached `gateway.ready` if available.
   - Message the user.

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
Turns then render at `****` (container-level + 1).

### 3. `hermes-mode.el` — Remove `hermes-create-session-here`

- Delete the function definition entirely.
- Remove any `;;;###autoload` cookie if present.
- Remove or update any docstring / commentary that references it.
- This reduces the autoloaded command surface to a single entry point: `hermes`.

### 4. Bench re-spawn details (Case A)

`hermes-bench-ensure` is already idempotent: it reuses an existing bench buffer if live, recreates it if killed, and calls `display-buffer-in-side-window` to ensure the window exists. Calling it again from `hermes` is sufficient.

If the bench window already exists and has focus, the `select-window` + `goto-char` at the end of the function is harmless.

## Edge Cases

| Situation | Behavior |
|-----------|----------|
| Point in org buffer but **before any heading** | Default `container-level = 1`. Insert a top-level `* Hermes session` at end of file. |
| Point inside a `hermes-mode` bench buffer | `derived-mode-p 'hermes-mode` is nil, so falls through to Case C (pop primary session). The bench is not the canonical buffer. |
| Org buffer already has `hermes-minor-mode` on | The new helper still works; `hermes-minor-mode` is idempotent. |
| Multiple Hermes sessions in the same org file at different levels | `hermes--container-level` is buffer-local, so only the *last created* session's level wins. This is a pre-existing limitation of the minor-mode architecture and is out of scope. |

## Out of Scope
- Dashboard files: already removed in a previous iteration.
- Splash logic: already implemented in `hermes-bench.el`.
- `AGENTS.md` updates: only necessary after implementation is done.
