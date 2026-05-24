# PLAN 03: TEA architecture violations — audit and remediation

## Context

The hermes.el codebase follows a TEA/Elm-inspired architecture:
- `hermes--reduce(msg, state) → state` — pure reducer, single source of truth
- `hermes-state-change-hook(old, new)` — subscribers project state to UI
- `hermes-dispatch(msg)` — calls reducer, swaps state atom, fires hook

This document catalogs every place where the code violates those
principles.  Each violation is tagged with severity and a concrete fix.

The comint rendering duplication bug (hook re-entrancy caused by
`:pending-turns-clear` dispatch from inside the org renderer) is
addressed by **F2 (shipped)** — the comint renderer reads live state
and converges idempotently under re-entrant hook firings.  **F3**
(deferring `:pending-turns-clear` via `run-at-time 0`) is optional
hardening at the source, not the primary fix.  See violation 3.1.

---

## Tier 1 — Impure reducer (`hermes-state.el`)

The reducer must be pure, deterministic, and side-effect-free.  These
violations break that contract and silently corrupt state.

### 1.1 — `hermes--log-write` inside reducer (7 locations)

**Severity:** Low

**Where:**
| Line | Event |
|------|-------|
| 1397 | `"error"` |
| 1408 | `"gateway.stderr"` |
| 1412 | `"gateway.protocol_error"` |
| 1416 | `"gateway.start_timeout"` |
| 1430 | `"background.complete"` |
| 1461 | `"review.summary"` |

**What:** `hermes--log-write` writes to the `*hermes-log*` buffer — a
visible Emacs buffer mutation every time the reducer runs.

**Fix:** Move logging to a `hermes-state-change-hook` subscriber or
a post-reduce callback.  The log buffer should be updated after the
state swap, not during reduction.

---

### 1.2 — `cl-incf` on global counters (2 locations)

**Severity:** Medium — makes the reducer non-deterministic; same
inputs produce different outputs with each invocation.

**Where:**
| Line | Variable | Called from |
|------|----------|------------|
| 457 | `hermes--segment-counter` | `hermes--next-segment-id` |
| 464 | `hermes--message-counter` | `hermes--next-message-id` (line 560, inside `hermes--push-committed`) |

**What:** Two `defvar` globals are mutated via `cl-incf` every time
the reducer runs.  The reducer's output depends on the current counter
value, not just its input `(msg, state)`.

**Fix:** Move counters into `hermes-state` as slots
(`next-segment-id`, `next-message-id`), incrementing them via `setf`
on the struct copy inside `hermes--with-copy`.

---

### 1.3 — Mutation leak: `usage` hash of old state corrupted

**Status:** ✅ FIXED — `copy-hash-table` before `puthash`.
Regression test: `message-complete-does-not-mutate-old-usage`.
Asserts `(eq old.usage new.usage)` is nil and old hash values are unchanged.

**Severity: HIGH**

**Where:** `"message.complete"` handler, lines 1077–1085

**What:**
```elisp
;; acc-usage is the OLD state's usage hash (or a new one)
;; puthash mutates it in place BEFORE the new state copy exists
(let* ((acc-usage (or (hermes-state-usage state)
                      (make-hash-table :test 'equal))))
  (when sent     (puthash "tokens_sent" (+ ...) acc-usage))
  (when received (puthash "tokens_received" (+ ...) acc-usage))
  ;; Now setf on the NEW state copies the mutated-hash reference
  (setf (hermes-state-usage s) acc-usage))
```

After this, `(hermes-state-usage old-state)` and
`(hermes-state-usage new-state)` point to **the same hash**.
Subscribers that compare old vs new usage data read corrupted old
values.

**Fix:**
```elisp
(let* ((acc-usage (if (hermes-state-usage state)
                      (copy-hash-table (hermes-state-usage state))
                    (make-hash-table :test 'equal))))
```

`copy-hash-table` is available since Emacs 25.1.

---

### 1.4 — Mutation leak: `session-info` and `usage` hashes of old state corrupted

**Status:** ✅ FIXED — `copy-hash-table` before mutating in `"session.info"` handler.
Regression test: `session-info-does-not-mutate-old-hashes`.
Asserts `(eq old.session-info new.session-info)` is nil post-merge.

**Severity: HIGH**

**Where:** `"session.info"` handler, lines 987–1005

**What:** Two hashes are mutated in-place before being assigned to
the new state copy:

```elisp
;; session-info: mutates old hash via maphash + puthash
(let ((merged (or (hermes-state-session-info state)
                  (make-hash-table :test 'equal))))
  (maphash (lambda (k v) (puthash k v merged)) p)
  (setf (hermes-state-session-info s) merged))

;; usage: same pattern
(let ((u (or (hermes-state-usage state)
             (make-hash-table :test 'equal))))
  (maphash (lambda (k v) (puthash k v u)) usage-payload)
  (setf (hermes-state-usage s) u))
```

**Fix:** Same pattern as 1.3 — wrap with `copy-hash-table`:
```elisp
(let ((merged (if (hermes-state-session-info state)
                  (copy-hash-table (hermes-state-session-info state))
                (make-hash-table :test 'equal))))
```

---

### 1.5 — `current-time` / `format-time-string` in reducer (6 locations)

**Severity:** Low-Medium — clocks make the reducer non-deterministic
but are widely accepted as benign impurity in TEA-like architectures.

**Where:**
| Line | Event |
|------|-------|
| 816 | `hermes--message-from-stream` (called from `"message.complete"`, `"error"`, `:user-submit`) |
| 866 | `:user-submit` |
| 952 | `:background-start` |
| 1169 | `"subagent.tool"` |
| 1380 | `:system-message` |
| 1438,1447 | `"background.complete"` |

**Fix (strict):** Capture `(current-time)` in the message payload at
the transport layer (`hermes--route-event`), before calling the
reducer.  Pass it as part of the message.

**Fix (pragmatic):** Document clock impurity explicitly in the
reducer's docstring.  Keep timestamps out of any equality/comparison
logic to prevent them from affecting branching.

---

### 1.6 — `hermes--next-message-id` in `hermes--push-committed`

**Severity:** Medium — same global counter issue as 1.2, but called
from the `"message.complete"` / `"error"` / `:user-submit` reducer
branches.

**Where:** `hermes--push-committed`, line 560

**What:** `hermes--push-committed` calls `hermes--next-message-id`,
which `cl-incf`s `hermes--message-counter` — a global mutable variable.
Contrast with `hermes--push-pending` (line 544), which is pure.

**Fix:** Covered by 1.2 — once counters are state-atom slots, this
becomes a pure read+increment on the copy.

---

### 1.7 — Shallow copy shares segment vector between original and committed copy

**Severity:** Low — latent risk, no current exploit

**Where:** `hermes--push-committed`, line 560

**What:** `hermes-message-copy` does a shallow copy.  The `:segments`
vector from the original message is shared between the original and
the committed copy in `turns`.  If any future code mutates the shared
vector, both are affected.

**Fix (defensive):** Copy the segments vector explicitly, or document
the shallow-copy contract in the function's docstring.

---

## Tier 2 — View reads its own output (`hermes-org-render.el`)

TEA principle: `view(state) → UI` is a one-directional projection.
Reading the painted buffer back turns it into a secondary input,
creating a feedback loop where the view depends on its own prior output.

### 2.1 — Reads buffer text for incremental diff comparison

**Severity:** High

**Where:** `hermes--render-stream-segments`, line 1093

**What:**
```elisp
(string= new-text
         (buffer-substring-no-properties pos (+ pos old-len)))
```

The incremental diff re-reads the painted buffer to decide whether a
segment needs updating.  The snapshot vector
(`hermes--stream-segments-snapshot`) already tracks `(:id :type
:length)`.  The buffer is the view's output; re-reading it creates a
circular dependency.

**Fix:** Extend snapshot entries from `(:id ID :type TYPE :length
LEN)` to `(:id ID :type TYPE :length LEN :text TEXT)`.  The stored
text can be compared against new content without touching the buffer.

---

### 2.2 — Scans text properties for fold targets

**Severity:** High

**Where:**
| Function | Lines |
|----------|-------|
| `hermes--apply-stream-folds` | 1187–1207 |
| `hermes--fold-reasoning-in-region` | 1209–1228 |

**What:** Both functions scan the buffer for `hermes-fold` and
`hermes-fold-id` text properties to decide which headings to fold.
These properties were placed there by the view itself during stream
painting (line 935).  The state atom's segment vector already carries
segment types and IDs — the fold logic should be driven from that
data, not from text-property scanning.

**Fix:** Pass the segments vector directly to the fold functions.
Compute positions from the snapshot offset table rather than scanning
text properties that the view itself wrote.

---

### 2.3 — Regex-scans for `:PROPERTIES:` drawers to hide them

**Severity:** Medium

**Where:** `hermes--hide-drawers`, lines 1164–1185

**What:**
```elisp
(re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" end t)
(re-search-forward "^[ \t]*:END:[ \t]*$" end t)
```

Scans buffer text for drawer markers that the view just wrote.  The
view knows the exact positions of every inserted drawer.

**Fix:** Have the insertion functions record drawer boundaries
(start/end), then pass those as arguments to `hermes--hide-drawers`
instead of re-scanning.

---

### 2.4 — Regex-scans for `#+name: hermes-tool-*` to align tables

**Severity:** Medium

**Where:** `hermes--refresh-region`, lines 377–388

**What:**
```elisp
(while (re-search-forward
        "^#\\+name: hermes-tool-[^ \t\r\n]+[ \t]*$" end-marker t)
  (forward-line 1)
  (when (looking-at "^[ \t]*|")
    (ignore-errors (org-table-align))))
```

The view knows which segments are tool segments and where each table
was inserted.  Alignment should happen per-tool during insertion, not
via a post-paint buffer scan over all content.

**Fix:** Call `org-table-align` immediately after inserting each tool
table in `hermes--format-tool` / `hermes--render-stream-segments`
(currently suppressed by `with-silent-modifications`; a deferred
approach would avoid the scan).

---

### 2.5 — Reads overlays + buffer geometry to rewrite heading

**Severity:** Low

**Where:** `hermes--finalize-assistant-heading`, lines 1310–1318

**What:**
```elisp
(goto-char (marker-position hermes--stream-headline-marker))
(let ((line-beg (line-beginning-position))
      (line-end (line-end-position)))
  (dolist (ov (overlays-in line-beg (1+ line-end)))
    (when (overlay-get ov 'hermes-headline)
      (delete-overlay ov)))
  (delete-region line-beg line-end) ...)
```

The function scans overlays and reads buffer geometry to find an
overlay that the view itself created at `hermes--stream-begin:1251`.
The overlay reference should be stored directly rather than
re-discovered.

**Fix:** Save the headline overlay in a buffer-local variable
(`hermes--stream-headline-overlay`) at creation time.  Delete it
directly in `hermes--finalize-assistant-heading` without scanning.

---

### 2.6 — Reads text properties in org-cycle hook

**Severity:** Medium

**Where:** `hermes--remember-cycle`, lines 1154–1162

**What:**
```elisp
(let ((fid (save-excursion
             (beginning-of-line)
             (get-text-property (point) 'hermes-fold-id))))
  (when (and fid (not (member fid hermes--unfolded-ids)))
    (push fid hermes--unfolded-ids)))
```

Org-cycle hook that reads `hermes-fold-id` from text properties to
track which headings the user expanded.  This is user-interaction
state (not view-projection) but lives in a buffer-local variable
(`hermes--unfolded-ids`) rather than in the state atom.

**Fix:** Move `hermes--unfolded-ids` from a buffer-local variable to a
slot on `hermes-state`.  The renderer would then consult
`(hermes-state-unfolded-ids new)` instead of text properties when
deciding which folds to preserve.

---

## Tier 3 — View dispatches state mutations (`hermes-org-render.el`)

The view must not modify state.  Dispatching from within the render
also causes re-entrant hook firings, which is the root mechanism
behind the comint rendering duplication bug.

### 3.1 — Dispatches `:pending-turns-clear` from inside the render

**Status:** 🟡 F2 shipped (comint renderer reads live state → idempotent under
re-entrancy).  F3 optional hardening (defer dispatch via `run-at-time 0`).
Regression test: `comint-reentrant-hook-converges`.

**Severity: HIGH — was root cause of comint duplication; now mitigated**

**Where:** `hermes--render-1`, line 294

**What:**
```elisp
(when drain-pending
  (hermes-dispatch '(:pending-turns-clear)))
```

After writing pending turns to the org buffer, the render dispatches a
state mutation while still inside the hook chain.  This re-entrant
dispatch synchronously runs the entire hook chain again — including
subscribers like `hermes-comint--refresh` — before the outer hook
invocation completes (F3 fix).

**Fix (applied — F2):** The comint renderer was refactored to read live
state (`hermes--current-state`) and converge idempotently.  Both inner
and outer hook firings see the same post-commit state and produce the
same buffer content.  No duplicated turn.

**Fix (optional — F3):** Defer the dispatch to after the current hook
chain completes.  This removes the re-entrancy at the source so any
future subscriber is also safe.  Risk: `run-at-time 0` defers the
clear past the current command; must verify no other code reads
`pending-turns` synchronously after the hook.

---

### 3.2 — Dispatches `:bg-rendered` from inside the render

**Severity:** Medium — already deferred via `run-at-time 0`, same
re-entrancy risk

**Where:** `hermes--render-bg-task`, lines 688–694

**What:** After creating a background task buffer, dispatches
`:bg-rendered` so the reducer records the buffer name.  Already
wrapped in `(run-at-time 0 nil (lambda () ...))` to break
re-entrancy, but still originates from the view.

**Fix:** Return the `(:bg-rendered ...)` message as an effect from the
render function.  Let the render's caller dispatch it after the render
completes.

---

## Tier 4 — State lives outside the state atom

Variables holding session-scoped state that are mutated directly
(`setq`, `push`, `puthash`) rather than through the reducer.

### 4.1 — `hermes--last-gateway-ready` (cached gateway payload)

**Severity:** Medium

**Where:**
| Line | File | Operation |
|------|------|-----------|
| 69 | `hermes-mode.el` | `(setq hermes--last-gateway-ready payload)` |
| 91 | `hermes-mode.el` | `(setq hermes--last-gateway-ready nil)` |

**What:** `hermes--last-gateway-ready` is a de facto piece of global
state (the cached `gateway.ready` payload replayed into new buffers).
It lives as a raw `defvar`, mutated via `setq`, never involved in the
reducer.

**Fix:** Move into `hermes--global-state` as a slot, dispatching
updates through the reducer under the `"gateway.ready"` and
`"skin.changed"` cases (which already exist in the reducer).

---

### 4.2 — `hermes--seeded-session-id` (per-session seed stamp)

**Severity:** Medium

**Where:**
| Line | File | Operation |
|------|------|-----------|
| 188,193 | `hermes-input.el` | `(setq hermes--seeded-session-id sid)` in `hermes-input--seed-prefix` |
| 664 | `hermes-mode.el` | `(setq hermes--seeded-session-id nil)` in `hermes-reload-from-org` |
| 386 | `hermes-sessions.el` | `(setq hermes--seeded-session-id sid)` in DB resume |

**What:** Tracks whether the history seed has fired for the current
gateway session.  Lives as a `defvar-local` outside any state struct.

**Fix:** Add a `:seed-stamp` slot to `hermes-state`.  Provide a
reducer action `(:seeded . ,sid)` and dispatch it from the input
pipeline instead of raw `setq`.

---

### 4.3 — `hermes--pre-send-queue` (pending sends for stale headings)

**Severity:** Medium

**Where:**
| Line | File | Operation |
|------|------|-----------|
| 727 | `hermes-org.el` | `(setq hermes--pre-send-queue (assq-delete-all ...))` in `hermes--drain-pre-send-queue` |
| 760,764 | `hermes-org.el` | `(setq ... (push ...))` in `hermes--create-fresh-session` |
| 388 | `hermes-input.el` | `(push ...)` in `hermes-send` stale-heading branch |

**What:** A global alist of `(session-id . text)` pairs for text
queued before a stale session is resumed.  Never touched by a reducer.

**Fix:** Reducer actions `:pre-send-enqueue` / `:pre-send-dequeue`
operating on a `:pre-send-queue` slot on `hermes-state`.

---

### 4.4 — Registry hash tables

**Severity:** Low — infrastructure, not session state

**Where:**
| Line | File | Operation |
|------|------|-----------|
| 148–153 | `hermes-org.el` | `puthash` on `hermes--sessions`, `hermes--session-markers`, `hermes--org-buffers` via `hermes--register-session` |
| 292 | `hermes-bench.el` | `puthash` on `hermes--bench-buffers` via `hermes-bench-ensure` |
| 316 | `hermes-bench.el` | `remhash` on `hermes--bench-buffers` via `hermes-bench-hide` |

**What:** Viewer registries map session-ids to live buffer objects.
They are mutated via `puthash`/`remhash` rather than through the
reducer.

**Assessment:** These are sidecar tables, not session state.  Buffers
have no place in a pure data struct (they are Emacs objects with
identity).  The registries are infrastructure, not data.  Wrapping
them in reducer actions would add ceremony without benefit.
**Accept as pragmatic concession; document.**

---

## Tier 5 — Pragmatic concessions (not violations per se)

These depend on Emacs environment state that cannot practically live in
the atom.  They are documented here as intentionally impure, not to be
"fixed" but to be acknowledged.

### 5.1 — Window point tracking for auto-scroll

**Where:** `hermes--render-1`, lines 211–215, 330–334

**What:** Reads `(get-buffer-window-list)`, `(window-point)`,
`(set-window-point)` to auto-scroll windows pinned to `point-max`.

**Assessment:** Necessary — Emacs views must manage window point.
Could be extracted to a separate `hermes--pin-tail-windows` helper
called after the render, improving separation but not purity.

---

### 5.2 — Buffer visibility check

**Where:** Both `hermes-org-render.el` and `hermes-comint.el`, calling
`hermes--buffer-visible-p`

**What:** Gates stream painting on whether the buffer is displayed in
a visible window.  Performance optimization; self-correcting (next
hook fire will catch up).

**Assessment:** Pragmatic.  Could be modeled as a state-atom flag set
when the buffer is shown/hidden, but the plumbing cost outweighs any
correctness benefit.

---

### 5.3 — `display-graphic-p` / `window-width` for inline images

**Where:** `hermes-org-render.el` → `hermes--refresh-region`, lines
393–398

**What:** Reads whether Emacs runs in a GUI and the current window
pixel width to render inline images at the right size.

**Assessment:** Display environment, not session state.  `display-graphic-p` could be captured once at session init; `window-width` is inherently dynamic.

---

### 5.4 — `org-element-cache-reset`

**Where:** `hermes-org-render.el`, lines 304, 503, 557, 1462

**What:** Called after structural buffer changes.  Needed because
`with-silent-modifications` suppresses `after-change-functions`,
preventing Emacs from auto-invalidating its parse cache.

**Assessment:** Already well-documented in the code (lines 295–302).
Necessary concession to Emacs internals.

---

### 5.5 — `hermes-comint--paint-stream` reads buffer-local markers

**Where:** `hermes-comint.el`, lines 538–544

**What:** The paint function reads `hermes-comint--output-end` and
`hermes-comint--prompt-start` markers to determine where to paint.
The marker values are a function of previous renders, not of the
current state atom.

**Assessment:** Being addressed by the F2 fix — the comint renderer
will read live state instead of trusting buffer-local copies.

---

### 5.6 — Throttle infrastructure

**Where:** Both renderers

**What:** Timer + pending-snapshot mechanism that deliberately
de-syncs the buffer from the state atom for performance.  The
snapshot tracks what was actually painted.

**Assessment:** This is the *raison d'être* of the throttle.  The
design document (plan 02) already acknowledges the deliberate
state/buffer desync.  Not a violation — a documented optimization.

---

## Summary table

| # | Tier | Severity | Status | What |
|---|------|----------|--------|------|
| 1.1 | 1 | Low | 🟡 Worth doing | `hermes--log-write` in reducer |
| 1.2 | 1 | Med | 🟡 Worth doing | `cl-incf` on global counters (message-id, segment-id) |
| 1.3 | 1 | **HIGH** | ✅ FIXED | Old usage hash mutated in place — regression test added |
| 1.4 | 1 | **HIGH** | ✅ FIXED | Old session-info/usage hashes mutated in place — regression test added |
| 1.5 | 1 | Low-Med | ❌ Declined | `current-time` in reducer — documented pragmatic concession |
| 1.6 | 1 | Med | 🟡 Worth doing | Counter mutation in `push-committed` (same root as 1.2) |
| 1.7 | 1 | Low | ❌ Declined | Shallow copy shares segment vector — documented contract |
| 2.1 | 2 | High | 🟡 Worth doing | Reads buffer text for incremental diff — store `:text` in snapshot |
| 2.2 | 2 | High | ❌ Declined | Scans text properties for folds — functional, O(n) over small region |
| 2.3 | 2 | Med | ❌ Declined | Regex-scans for `:PROPERTIES:` — bounded, fast |
| 2.4 | 2 | Med | ❌ Declined | Regex-scans for tool tables — bounded, fast |
| 2.5 | 2 | Low | ❌ Declined | Reads overlays for heading rewrite — bounded, fast |
| 2.6 | 2 | Med | ❌ Declined | Reads text props in org-cycle hook — fold-id list stays buffer-local |
| 3.1 | 3 | **HIGH** | 🟡 F2 shipped / F3 optional | `:pending-turns-clear` in render — comint converges idempotently (F2). F3 optional hardening at source. Regression test added. |
| 3.2 | 3 | Med | ❌ Declined | `:bg-rendered` in render — already deferred via `run-at-time 0` |
| 4.1 | 4 | Med | 🟡 Worth doing | `last-gateway-ready` outside atom — small reducer-action addition |
| 4.2 | 4 | Med | 🟡 Worth doing | `seeded-session-id` outside atom — small reducer-action addition |
| 4.3 | 4 | Med | 🟡 Worth doing | `pre-send-queue` outside atom — small reducer-action addition |
| 4.4 | 4 | Low | ❌ Declined | Registry hash tables — pragmatic, documented |

**Legend:** ✅ FIXED = shipped with regression test | 🟡 Worth doing = eventual cleanup, no current bug | ❌ Declined = smell without observable symptom, cost > benefit

### In-code annotations applied

TEA impurities are now documented at the source (the plan document is
not the sole reference):

| File | Annotation |
|------|-----------|
| `hermes-state.el` | Header comment on `hermes--reduce` listing pragmatic impurities (clocks, counters, log-write). Note on `hermes--{segment,message}-counter` defvars. Note on `hermes--push-committed`'s shallow segment-vector copy. |
| `hermes-org-render.el` | Note on `:pending-turns-clear` dispatch with pointer to F2 + suggested F3 fix. Note on buffer re-read in `hermes--render-stream-segments`. |
| `hermes-mode.el` | Note on `hermes--last-gateway-ready`. |
| `hermes-input.el` | Note on `hermes--seeded-session-id`. |
| `hermes-org.el` | Note on `hermes--pre-send-queue`. |

### Debug traces removed

`hermes-comint.el` — the trace `message` calls in `hermes-comint--refresh`,
`hermes-comint--append-new-turns`, `hermes-comint--stream-update`, and
`hermes-comint--stream-commit` have been removed.

---

## Clean modules — no violations

| Module | Notes |
|--------|-------|
| `hermes-bg.el` | Pure view/listing. All state mutations go through the reducer. |
| `hermes-ui-reduce` | Pure UI state reducer. No side effects, no global writes. |
| `hermes-comint.el` | No state mutations. F2 shipped — reads live state, converges idempotently under re-entrant hook firings. |

## Test status

408/408 green (405 prior + 2 mutation regression tests for 1.3/1.4 + 1 comint re-entrancy regression for 3.1).

## References

| What | Where |
|------|-------|
| Reducer (`hermes--reduce`) | `hermes-state.el:824–1464` |
| State struct | `hermes-state.el:109–134` |
| Org renderer | `hermes-org-render.el` (renamed from `hermes-render.el` per plan 02) |
| Comint renderer | `hermes-comint.el` |
| Event routing + hook installation | `hermes-mode.el` |
| Buffer parsing (intentional dual authority) | `hermes-org.el` |
| Architecture documentation | `AGENTS.md`, `docs/01-architectural-model.md`, `docs/14-architecture-reference.md` |
| Comint duplication fix (F2 shipped, F3 optional) | `hermes-comint.el` — reads live state → idempotent under re-entrant hook firings |
| Plan 02 — unified stream lifecycle | `plans/02-unified-stream-lifecycle.md` |
