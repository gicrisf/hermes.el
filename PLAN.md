# Plan: Fix Mode-Line Update + Refined Format

## Context
The previous plan moved the Hermes status bar from `header-line-format` to `mode-line-format`. Two issues were discovered after implementation:

1. **Bug:** The connection icon shows `○` (disconnected) even when the gateway is working. This happens because `hermes--mode-line-update` is only called once at `hermes-minor-mode` startup and is **not registered on any state-change hook**. It never refreshes when the connection transitions from `:connecting` to `:connected`.
2. **Design:** The user wants a cleaner, reordered format with fewer elements.

---

## Goal
1. Fix the stale connection icon by wiring `hermes--mode-line-update` into the correct hook.
2. Reorder and reformat `hermes--mode-line-status` to match the user's preference.
3. Simplify `mode-line-format` to remove mule-info, remote, frame-identification, position, and modes.

---

## Proposed Changes

### 1. `hermes-mode.el` — Fix hook wiring

**Current (broken):**
```elisp
(add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     t t)
```

`hermes--mode-line-update` is called once at startup but never again.

**Fix:** Add `hermes--mode-line-update` to `hermes-state-change-hook`. Keep `hermes--render-ui` on `hermes-ui-state-change-hook` (it updates `hermes--ui-line`, which `hermes--mode-line-status` reads).

```elisp
(defun hermes-minor-mode--on ()
  ...
  (add-hook 'hermes-state-change-hook    #'hermes--render        t t)
  (add-hook 'hermes-state-change-hook    #'hermes-prompts-watch  t t)
  (add-hook 'hermes-state-change-hook    #'hermes-input--drain   t t)
  (add-hook 'hermes-state-change-hook    #'hermes-skin-watch     t t)
  (add-hook 'hermes-state-change-hook    #'hermes--mode-line-update t t)  ; ← NEW
  (add-hook 'hermes-ui-state-change-hook #'hermes--render-ui     t t)      ; ← keeps hermes--ui-line fresh
  ...)

(defun hermes-minor-mode--off ()
  ...
  (remove-hook 'hermes-state-change-hook    #'hermes--mode-line-update t)
  (remove-hook 'hermes-ui-state-change-hook #'hermes--render-ui        t)
  ...)
```

**Why this fixes it:** `hermes-dispatch` fires `hermes-state-change-hook` on every persistent state change (connection, model info, token usage, queue drain). `hermes--mode-line-update` now receives those events and refreshes `mode-line-format` via `force-mode-line-update`.

---

### 2. `hermes-render.el` — Reformat `hermes--mode-line-update`

**Current format:**
```
 Hermes · ● · deepseek-v4-flash · 12→45 · queue: 2
```

**Desired format:**
```
● · deepseek-v4-flash · thinking… · (133600 tokens) · queue: 2
```

Changes:
- Drop `Hermes` label
- Reorder: `● · model · ui-line · (total tokens) · queue`
- Combine `sent→received` into a single `(total tokens)` figure

```elisp
(defun hermes--mode-line-update (&optional _state)
  "Recompute `hermes--mode-line-status' from the current state.
Installed on `hermes-state-change-hook' so connection/model/token
changes refresh the mode-line immediately."
  (setq hermes--mode-line-status
        (concat
         (pcase (and hermes--state (hermes-state-connection hermes--state))
           ('connected    "●")
           ('connecting   "◐")
           ('disconnected "○")
           (_             ""))
         (let* ((info  (and hermes--state (hermes-state-session-info hermes--state)))
                (model (and (hash-table-p info) (gethash "model" info))))
           (if model (format " · %s" model) ""))
         (let ((ui (or hermes--ui-line "")))
           (unless (string-empty-p ui)
             (format " · %s" (string-trim ui))))
         (let* ((usage (and hermes--state (hermes-state-usage hermes--state)))
                (sent  (and usage (gethash "tokens_sent" usage)))
                (recv  (and usage (gethash "tokens_received" usage))))
           (if (or sent recv)
               (format " · (%s tokens)"
                       (+ (or sent 0) (or recv 0)))
             ""))
         (let ((q (and hermes--state (hermes-state-queue hermes--state))))
           (if (and q (> (length q) 0))
               (format " · queue: %d" (length q))
             ""))))
  (force-mode-line-update))
```

**Note on number formatting:** `(format "%s" (+ sent recv))` produces `133600`. If the user prefers European thousands-separators (`133.600`) or compact notation, a helper like `hermes--format-token-count` can be added later.

---

### 3. `hermes-mode.el` — Simplify `mode-line-format`

```elisp
(setq-local mode-line-format
            '("%e"
              mode-line-front-space
              mode-line-modified
              " "
              mode-line-buffer-identification
              "    "
              (:eval hermes--mode-line-status)
              mode-line-end-spaces))
```

**Dropped:** `mode-line-mule-info`, `mode-line-client`, `mode-line-remote`, `mode-line-frame-identification`, `mode-line-position`, `mode-line-modes`.

**Kept:** `mode-line-modified` (`**`/`--`), `mode-line-buffer-identification` (`*hermes:abc123*`), and the dynamic Hermes status.

---

## Visual Result

```
┌─────────────────────────────────────────────────────────────┐
│ * Hermes session :hermes:                                   │
│ ** U: Hello                                                 │
│ ** A: Hi there                                              │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│ ** *hermes:abc123*    ● · deepseek-v4-flash · (133600 tokens)│ ← mode-line
└─────────────────────────────────────────────────────────────┘
│ Hello, how can I help?                                      │
│ ------                                                      │
│ >                                                           │
└─────────────────────────────────────────────────────────────┘
```

When streaming / thinking:
```
** *hermes:abc123*    ● · deepseek-v4-flash · thinking… · (45 tokens)
```

With queue:
```
** *hermes:abc123*    ● · deepseek-v4-flash · (133600 tokens) · queue: 2
```

---

## Files to touch

| File | Change |
|------|--------|
| `hermes-mode.el` | Add `hermes--mode-line-update` to `hermes-state-change-hook`; simplify `mode-line-format` |
| `hermes-render.el` | Rewrite `hermes--mode-line-update` body for new format and order |

No changes needed in `hermes-bench.el` (bench header-line remains nil).

## Out of scope
- Number formatting (thousands separators, compact notation).
- Removing `hermes--render-ui` entirely — it still serves the useful purpose of updating `hermes--ui-line` from ephemeral state.
