# Incident Log: Thinking/Reasoning Rendering Breaks Tool Pipeline

> **Date:** 2026-05-14
> **Scope:** `hermes-render.el`, `hermes-state.el`
> **Severity:** High — runtime crashes during every tool call

---

## 1. Initial Problem Statement

After implementing thinking/reasoning interleaving as Org blocks (Phase 0), the user reported runtime errors during live Hermes sessions:

```
error in process filter: let*: Args out of range: "", -57, nil
error in process filter: let*: Args out of range: "-> running terminal
-> done terminal (0.5s)

", -308, nil
```

These errors occurred **every time a tool was invoked**, rendering the tool pipeline unusable.

### Root Cause (Initial Hypothesis)

The thinking block insertion logic (`hermes--insert-before-text`) was corrupting stream markers, causing `hermes--rewrite-stream` to compute a negative `already` offset (bytes already rendered vs. bytes in the clean text buffer). When `substring` received a negative start index, it threw `Args out of range`.

---

## 2. Issues Encountered

### Issue 2.1: `stream-end` Double-Advance

**Symptom:** After inserting a thinking block, the unstable region grew larger than the actual text, causing `old-unstable-len` to be wrong.

**Cause:** `hermes--insert-before-text` manually advanced `hermes--stream-end`:
```elisp
(when (markerp hermes--stream-end)
  (set-marker hermes--stream-end
              (+ (marker-position hermes--stream-end)
                 (length content))))
```

But `hermes--stream-end` has **insertion-type `t`** (set in `hermes--stream-begin`). This means Emacs already auto-advances it when text is inserted at its position. The manual advance added the length **twice**.

**Fix:** Remove the manual `stream-end` advance from `hermes--insert-before-text`. Only manually advance `content-start` and `stable-end` (both have insertion-type `nil`).

### Issue 2.2: `stable-end` Misplaced After Thinking Block Replacement

**Symptom:** After updating a thinking block (second `thinking.delta`), `stable-end` could end up inside the thinking block or before `content-start`.

**Cause:** The replacement branch used `delta` math to adjust `stable-end`:
```elisp
(set-marker hermes--stream-stable-end
            (+ (marker-position hermes--stream-stable-end) delta))
```

This assumed `stable-end` was at a known position relative to the old block. But after `delete-region`, Emacs shifts markers after the deleted region forward to the deletion point. The `delta` math compounded this shift, producing wrong positions.

**Fix:** After delete+insert, simply snap `stable-end` to `content-start`:
```elisp
(set-marker hermes--stream-stable-end
            (marker-position hermes--stream-content-start))
```

This is always correct because `stable-end` should track the boundary between "already converted to Org" and "still unstable/raw".

### Issue 2.3: `already` Could Go Negative

**Symptom:** Even after fixing markers, occasional negative `already` values caused `substring` crashes.

**Cause:** If any marker drifted (e.g., from a previous tool insertion that didn't properly adjust markers), `(- stable-end content-start)` could be negative.

**Fix:** Add `(max 0 ...)` guards in `hermes--rewrite-stream`:
```elisp
(already  (max 0 (- (marker-position hermes--stream-stable-end)
                    (marker-position hermes--stream-content-start))))
(old-unstable-len
 (max 0 (- (marker-position hermes--stream-end)
           (marker-position hermes--stream-stable-end))))
```

This makes the renderer resilient to transient marker drift.

### Issue 2.4: Thinking Marker Set to Block End Instead of Start

**Symptom:** When removing a thinking block (setting content to empty), the deletion left the block in the buffer.

**Cause:** In the insertion branch:
```elisp
(setq hermes--stream-thinking-marker (copy-marker hermes--stream-content-start))
```

But `hermes--insert-before-text` was called **after** this line, which advanced `content-start` past the block. So `thinking-marker` pointed to the **end** of the block, not the start.

**Fix:** Swap the order — set the marker **before** inserting:
```elisp
(setq hermes--stream-thinking-marker
      (copy-marker hermes--stream-content-start))
(hermes--insert-before-text block)
```

### Issue 2.5: `let*` vs `let` Scope Bug

**Symptom:** `void-variable end` error when removing a thinking block.

**Cause:** Used `let` instead of `let*` in the removal branch:
```elisp
(let ((beg ...) (end ...) (len (- end beg)))  ; end is NOT yet bound here!
```

With `let`, bindings are evaluated in parallel, so `(- end beg)` tried to reference `end` before it was bound.

**Fix:** Change to `let*` (sequential binding).

---

## 3. Deeper Issue: Tool Text Interleaved into `stream-text`

While fixing the marker bugs, we discovered a **design problem** in the original reducer: tools polluted `stream-text` with `-> running terminal\n` and `-> done terminal (0.5s)\n` strings.

This meant:
- `stream-text` was no longer pure assistant prose
- The stable/unstable split operated on mixed content
- Tool updates required rewriting text, which competed with assistant text streaming

**Decision:** Refactor tool rendering to follow the same model as thinking/reasoning blocks:
- `stream-text` stays **clean** — only assistant prose
- `stream-tools` holds the tool state vector
- Renderer detects tool changes and renders them as `*** tool (status)` Org sub-headlines **after** the text region
- `hermes--update-tool-views` replaces the entire tool block on any tool change

This separation means:
- Text rewriting never touches tool blocks
- Tool blocks update independently
- No more `-> running ...` pollution in `stream-text`

---

## 4. Resolution

### Files Changed

| File | Changes |
|------|---------|
| `hermes-render.el` | `hermes--insert-before-text` — removed `stream-end` double-advance; `hermes--update-thinking-block` — fixed marker snap, `let*` fix, marker order; `hermes--rewrite-stream` — `(max 0 ...)` guards; new `hermes--update-tool-views`, `hermes--format-tool`, `hermes--format-tools-block`; `hermes--stream-update` — detects tool changes |
| `hermes-state.el` | Removed tool text interleaving from `tool.generating` and `tool.complete` reducers; `hermes-message` struct gained `thinking`/`reasoning` slots; `message.complete` commits them |
| `hermes-prompts.el` | Approval choices fixed to canonical `once`/`session`/`always`/`deny` |
| `test/hermes-render-test.el` | 4 new tests for thinking block render |
| `test/hermes-state-test.el` | 2 new tests for thinking/reasoning commit |

### Test Results

All 69 tests pass:
- 33 state tests
- 8 render tests  
- 16 md tests
- 12 new/changed tests for thinking/reasoning + approval

### Lessons Learned

1. **Insertion-type matters.** Markers with `t` auto-advance; never manually advance them.
2. **Delete-region shifts markers.** After deletion, markers after the region are at the deletion point. Any manual adjustment must account for this.
3. **`let` vs `let*` is subtle but critical.** Parallel vs sequential binding affects whether earlier vars can be referenced in later init expressions.
4. **Defensive guards save hours.** `(max 0 ...)` on offsets would have prevented the crash even with marker drift.
5. **Separate concerns in renderer.** Mixing different content types (text, thinking, tools) into one buffer region creates fragile marker arithmetic. Each content type should have its own marker boundary.

---

*Logged by: OpenCode*
*Session: 2026-05-14*
