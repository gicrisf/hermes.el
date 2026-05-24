# PLAN 26: Simplify `hermes` startup — default to comint session

## Motivation

Currently `M-x hermes` has four code paths:

| Context | Behavior |
|---------|----------|
| `hermes-comint-mode` buffer | goto point-max |
| `hermes-org-minor-mode` buffer | ensure bench, focus it |
| generic `org-mode` buffer | find/create session heading, setup minor mode |
| everywhere else | find existing session (org or comint), or create a **new org buffer** based session |

The "everywhere else" path creates an org buffer via `hermes--do-session-create`
(line 278), which does `(org-mode)` + `(hermes-org-minor-mode 1)`.  Even
`hermes-comint` with prefix arg (line 1166–1171 of hermes-comint.el) follows
the same path — creating an org buffer, registering it, then immediately
opening a comint viewer on the same session.  The org buffer is a wasteful
side effect.

Now that comint is the primary UI (plan 24 moved all status there),
`M-x hermes` from a non-org context should create a comint-only session.
Org is an optional document layer triggered from org-mode buffers.

## Goal

`M-x hermes` creates a new comint session when invoked from a non-org,
non-comint context.  The comint buffer receives a bench (same buffer in
comint-only mode — bench IS the full viewer).

```
context              → action
─────────────────────   ───────────────────────────────
hermes-comint-mode   → goto point-max (unchanged)
hermes-org-minor-mode → ensure bench + focus (unchanged)
org-mode             → find/create session heading (unchanged)
anything else        → create comint session (NEW)
```

## Design

### New function: `hermes-comint--create-session` (in `hermes-comint.el`)

Mirrors `hermes--do-session-create` but creates a `hermes-comint-mode` buffer
instead of an org-mode buffer:

1. Capture `detected-cwd` from the caller's buffer
2. Start RPC if needed
3. Send `session.create`
4. On response:
   - Create a `hermes-comint-mode` buffer named `*hermes:<sid>*`
   - Set `hermes--current-session-id` to `sid`
   - Register in `hermes-comint--buffers`
   - Create and register state in `hermes--sessions`
   - Dispatch `gateway.ready` if available
   - Fetch slash-command catalog
   - Call callback with the buffer

Requires these `declare-function`s (all already in `hermes-comint.el`):
  `hermes--install-hooks`, `hermes-rpc-live-p`, `hermes-rpc-start`,
  `hermes-input-fetch-catalog`.  Plus one new:
  `hermes-project-detect-cwd` or inline the cwd detection (a single
  `(ignore-errors (hermes-project-detect-cwd))` call).

### Simplified `hermes` function (in `hermes-mode.el`)

The `t` branch (everywhere else) changes from ~14 lines to ~8:

Before:
```elisp
(t
  (let ((buf (hermes--primary-session-buffer)))
    (if buf
        (progn
          (pop-to-buffer-same-window buf)
          (when-let ((sid (hermes--buffer-sid buf)))
            (hermes-bench-ensure sid))
          (hermes--focus-bench-input buf))
      (hermes-new-session
       (lambda (b)
         (when (buffer-live-p b)
           (pop-to-buffer-same-window b)
           (when-let ((sid (hermes--buffer-sid b)))
             (hermes-bench-ensure sid))
           (hermes--focus-bench-input b)))))))
```

After:
```elisp
(t
  (hermes--install-hooks)
  (unless (hermes-rpc-live-p) (hermes-rpc-start))
  (hermes-comint--create-session
   (lambda (buf)
     (when (buffer-live-p buf)
       (pop-to-buffer-same-window buf)
       (goto-char (point-max))))))
```

### Remove double-buffer waste in `hermes-comint` (hermes-comint.el)

The `arg` (prefix) and `t` (default) branches of `hermes-comint` both call
`hermes-new-session` → `hermes--do-session-create` → creates an org buffer,
then opens a comint viewer.  After this plan, both branches call
`hermes-comint--create-session` directly:

Before (line 1166–1171):
```elisp
(arg
  (hermes-new-session
   (lambda (buf)
     (when buf
       (hermes-comint--open
        (buffer-local-value 'hermes--current-session-id buf))))))
```

After:
```elisp
(arg
  (hermes-comint--create-session
   (lambda (buf)
     (when buf
       (pop-to-buffer-same-window buf)
       (goto-char (point-max))))))
```

Same for the `t` branch.

### What stays untouched

- `hermes--primary-session-buffer` — still used by `hermes-doom.el` and
  `hermes-project.el`
- `hermes--live-session-buffers` — still used by `hermes-sessions.el`
- `hermes--focus-bench-input` — still used by `hermes-sessions.el`
- `hermes-new-session` and `hermes--do-session-create` — still used by
  dashboards and `hermes-sessions.el` for creating org-buffer sessions

No deletions in this plan — only additions and one branch simplification.

### Potential future cleanups (not in scope)

- `hermes--primary-session-buffer` / `hermes--live-session-buffers` / 
  `hermes--focus-bench-input` could move to `hermes-session.el`
- `hermes-org-minor-mode` could move to `hermes-org-minor-mode.el`
  (see plan 27)

## Changes by file

### `hermes-comint.el`

1. **Add `declare-function`** for `hermes-project-detect-cwd`
   (from `hermes-project.el`).

2. **Add `hermes-comint--create-session`** — creates a comint buffer
   for a new session via RPC (mirrors `hermes--do-session-create` but
   for comint buffers).

3. **Fix double-buffer waste** in `hermes-comint`:
   - `arg` branch: `hermes-new-session...` → `hermes-comint--create-session...`
   - `t` branch: same change

### `hermes-mode.el`

4. **Simplify `hermes` function**:
   - `t` branch: "find existing or create org" → "create comint session"
   - Add `(require 'hermes-comint)` if not already present
     (currently `hermes-mode` requires `hermes-org-render` but not
     `hermes-comint`)

## Files touched

| File | Lines changed | Nature |
|------|---------------|--------|
| `hermes-comint.el` | +35 / −10 | Add `hermes-comint--create-session`, simplify `hermes-comint` branches |
| `hermes-mode.el` | +5 / −12 | Simplify `t` branch of `hermes` |
