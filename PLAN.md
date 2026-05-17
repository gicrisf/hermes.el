# Plan: Fix Stale `disconnected` State During Streaming

## Context
The mode-line shows `○` (disconnected) throughout the entire streaming session, even while `thinking.delta` and `message.delta` events are actively arriving. Debug logs confirm `hermes--state` has `connection = 'disconnected` from the first mode-line update through `message.complete`.

This is a **state bug**, not a rendering bug. The mode-line reads faithfully from `hermes--state`; the problem is that the state never transitions to `connected` (or transitions briefly then flips back).

## Root Cause Hypotheses

### H1: Race — `gateway.ready` misses the new buffer
`gateway.ready` is broadcast via `hermes--broadcast-dispatch` to all buffers in `hermes--session-buffers`. If it arrives before the `session.create` callback adds the new buffer to that table, the buffer never receives it. The callback's replay of `hermes--last-gateway-ready` should catch it, but if that fails, the state stays at its initial `disconnected` value.

### H2: Spurious `:disconnected` dispatch
The user reports seeing `●` (connected) briefly before it turns to `○`. The only source of `:disconnected` is `hermes-rpc--sentinel` (process death). If the gateway subprocess signals exit spuriously, the state flips to `disconnected` and never recovers — even though the process continues to stream.

### H3: State atom shadowing / rebinding
`hermes--state` might be reinitialized or shadowed after `gateway.ready` sets it to `connected`, causing the mode-line to read from a stale struct.

---

## Diagnostic Steps

### 1. Add targeted logging

In `hermes-rpc.el`, log every connection hook call:

```elisp
(defun hermes-rpc--sentinel (proc event)
  (when (memq (process-status proc) '(exit signal closed))
    (message "[rpc] sentinel: status=%S event=%S" (process-status proc) event)
    ...))
```

In `hermes-mode.el`, log the replay:

```elisp
;; inside hermes--do-session-create callback
(message "[sess] replay gateway.ready? %S" (not (null hermes--last-gateway-ready)))
(when hermes--last-gateway-ready
  (message "[sess] dispatching gateway.ready replay")
  (hermes-dispatch (cons "gateway.ready" hermes--last-gateway-ready)))
```

In `hermes-state.el`, log every state transition:

```elisp
(defun hermes-dispatch (msg &optional session-id)
  (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
         (old (hermes--state-slot-read hermes--current-session-id))
         (new (hermes--reduce old msg)))
    (when (eq old new)
      (message "[dispatch] no-op: type=%S" (car msg)))
    (unless (eq old new)
      (message "[dispatch] %S → %S (conn: %S → %S)"
               (car msg)
               (hermes-state-session-id new)
               (and old (hermes-state-connection old))
               (hermes-state-connection new))
      (hermes--state-slot-write hermes--current-session-id new)
      (run-hook-with-args 'hermes-state-change-hook old new))))
```

Run `M-x hermes`, observe `*Messages*`. We need to see:
- Does `[rpc] sentinel: ...` appear during streaming? (confirms H2)
- Does `[sess] replay gateway.ready?` say `nil`? (confirms H1)
- Does `[dispatch]` show `gateway.ready` → `connected` followed by another dispatch → `disconnected`? (confirms H2/H3)

---

## Fixes (apply after diagnosis confirms root cause)

### Fix A: Robust `gateway.ready` replay (for H1)

Cache `gateway.ready` in a buffer-local variable at creation time, rather than relying solely on the global `hermes--last-gateway-ready`:

```elisp
;; In hermes-mode.el hermes--do-session-create callback
(let ((replay-payload (or hermes--last-gateway-ready
                          ;; fallback: read from any live buffer
                          (hermes--last-gateway-ready-from-any-buffer))))
  (when replay-payload
    (hermes-dispatch (cons "gateway.ready" replay-payload))))
```

Or simpler: replay unconditionally — if `hermes--last-gateway-ready` is nil, the buffer was created before any `gateway.ready` and should wait for the real event. But if it's non-nil, we MUST replay it successfully.

### Fix B: Defensive mode-line fallback (for H2/H3)

If the buffer state says `disconnected` but the RPC process is `ready`, use the RPC state as the ground truth:

```elisp
(defun hermes--mode-line-update (&optional _old _new)
  (let* ((buf-conn (and hermes--state (hermes-state-connection hermes--state)))
         (rpc-conn (pcase hermes-rpc--state
                     ('starting 'connecting)
                     ('ready    'connected)
                     (_         'disconnected)))
         ;; Defensive: if buffer state is disconnected but RPC is ready,
         ;; the state is stale. Use RPC as source of truth.
         (conn (if (and (eq buf-conn 'disconnected)
                        (eq rpc-conn 'connected))
                   'connected
                 (or buf-conn rpc-conn 'disconnected))))
    (setq hermes--mode-line-status
          (concat
           (pcase conn
             ('connected    "●")
             ('connecting   "◐")
             ('disconnected "○")
             (_             "○"))
           ...))))
```

This is a **workaround**, not a fix. It masks the stale state but doesn't heal it.

### Fix C: Auto-heal on streaming events (for H3)

If a streaming event (`message.delta`, `thinking.delta`, etc.) arrives while `connection = 'disconnected`, automatically dispatch `:connected` to repair the state:

```elisp
;; In hermes--reduce, before processing streaming events
(when (eq (hermes-state-connection state) 'disconnected)
  (setq state (hermes--reduce state '(:connected))))
```

This is aggressive but safe: if the gateway is sending us deltas, we are by definition connected.

---

## Recommendation

1. **First:** Add the diagnostic logging and run one session. Share `*Messages*` output.
2. **Then:** Apply the fix that matches the confirmed root cause.
3. **Regardless:** Apply **Fix B** (defensive fallback) as a safety net so the mode-line never lies to the user, even if the state gets out of sync again.

---

## Files to touch

| File | Change |
|------|--------|
| `hermes-rpc.el` | Add sentinel logging |
| `hermes-mode.el` | Add replay logging; apply Fix A if H1 confirmed |
| `hermes-state.el` | Add dispatch logging; apply Fix C if H3 confirmed |
| `hermes-render.el` | Apply Fix B (defensive fallback in `hermes--mode-line-update`) |

---

## Appendix: Copy-Paste Logging Snippets

### A1. `hermes-rpc.el` — sentinel logging

Find `hermes-rpc--sentinel` (~line 284) and add one line at the top of the `when` body:

```elisp
(defun hermes-rpc--sentinel (proc event)
  "Handle subprocess lifecycle: signal disconnection."
  (when (memq (process-status proc) '(exit signal closed))
    (message "[rpc] sentinel fired: status=%S event=%S"
             (process-status proc) (string-trim event))
    ;; existing code continues...
```

### A2. `hermes-mode.el` — replay logging

Find the `hermes--do-session-create` callback (~line 245) and add two lines before the `when hermes--last-gateway-ready` block:

```elisp
;; inside hermes--do-session-create, inside the (lambda (result error) ...)
;; After: (puthash sid buf hermes--session-buffers)
;; Before: (when hermes--last-gateway-ready ...)
(message "[sess] replay gateway.ready? %S  state-conn=%S"
         (not (null hermes--last-gateway-ready))
         (and hermes--state (hermes-state-connection hermes--state)))
```

### A3. `hermes-state.el` — dispatch logging

Find `hermes-dispatch` (~line 180) and add logging inside the `unless (eq old new)` block:

```elisp
(defun hermes-dispatch (msg &optional session-id)
  "Reduce MSG into the persistent state and notify subscribers."
  (let* ((hermes--current-session-id (or session-id hermes--current-session-id))
         (old (hermes--state-slot-read hermes--current-session-id))
         (new (hermes--reduce old msg)))
    (unless (eq old new)
      (message "[dispatch] %S  sid=%S  conn: %S → %S"
               (car msg)
               (hermes-state-session-id new)
               (and old (hermes-state-connection old))
               (hermes-state-connection new))
      (hermes--state-slot-write hermes--current-session-id new)
      (run-hook-with-args 'hermes-state-change-hook old new))))
```

### A4. `hermes-render.el` — temporary mode-line debug

Add one temporary line at the top of `hermes--mode-line-update` (~line 1316):

```elisp
(defun hermes--mode-line-update (&optional _old _new)
  "Recompute `hermes--mode-line-status' from the current state."
  (message "[ml] conn=%S sid=%S buf=%s"
           (and hermes--state (hermes-state-connection hermes--state))
           (and hermes--state (hermes-state-session-id hermes--state))
           (buffer-name))
  ;; existing code continues...
```

**Remove A4 after diagnosis** — it prints every state change and will flood `*Messages*`.

---

## Out of scope
- Investigating why the gateway process might spuriously signal exit (if H2 is confirmed, that's a gateway bug, not an Emacs client bug).
