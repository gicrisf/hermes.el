# Plan: Fix Stale State in Per-Session Registry

## Root Cause (confirmed by logs)

The log sequence reveals the exact bug:

```
[dispatch] "gateway.ready"  sid="373a5af8"  conn: disconnected → connected
[ml] buf-conn=connected ...
[dispatch] :user-submit  sid="373a5af8"  conn: disconnected → disconnected
```

`gateway.ready` successfully sets `hermes--state` to `connected`, but `:user-submit` immediately sees `disconnected` again. This happens because:

1. `session.create` callback creates `hermes--state` with `connection = 'disconnected`
2. `hermes--register-session` puts the SAME struct into `hermes--buffer-sessions` registry
3. `gateway.ready` arrives as a **global** event (dispatched with `session-id = nil`) → `hermes--state-slot-write` only updates `hermes--state`, **skipping the registry entry**
4. The registry entry still points to the OLD `disconnected` struct
5. `:user-submit` is dispatched with the session-id → reads from the stale registry entry → gets `disconnected` → overwrites `hermes--state` back to `disconnected`
6. From then on, ALL streaming events see `disconnected → disconnected` (no-op)

## Fix

### `hermes-state.el` — Update `hermes--state-slot-write`

Change the function so that when `hermes--state` is updated (even with `session-id = nil`), the registry entry for the buffer-local active session is also synced:

```elisp
(defun hermes--state-slot-write (session-id new-state)
  "Persist NEW-STATE under SESSION-ID and mirror to `hermes--state'.
When SESSION-ID is non-nil and present in `hermes--buffer-sessions',
that entry is replaced.  The buffer-local `hermes--state' is always
updated.  Additionally, if NEW-STATE carries a session-id that differs
from SESSION-ID, the registry entry for that active session is also
updated — this prevents stale data when global events (e.g.
`gateway.ready') update `hermes--state' without touching the registry."
  (when (and session-id
             (boundp 'hermes--buffer-sessions)
             (hash-table-p hermes--buffer-sessions)
             (gethash session-id hermes--buffer-sessions))
    (puthash session-id new-state hermes--buffer-sessions))
  ;; Sync registry for the active session-id carried by NEW-STATE,
  ;; ensuring global dispatches don't leave stale registry entries.
  (let ((active-sid (and new-state (hermes-state-session-id new-state))))
    (when (and active-sid
               (not (equal active-sid session-id))
               (boundp 'hermes--buffer-sessions)
               (hash-table-p hermes--buffer-sessions)
               (gethash active-sid hermes--buffer-sessions))
      (puthash active-sid new-state hermes--buffer-sessions)))
  (setq hermes--state new-state))
```

## Verification

After this fix, the log should show:

```
[dispatch] "gateway.ready"  sid="373a5af8"  conn: disconnected → connected
[dispatch] :user-submit  sid="373a5af8"  conn: connected → connected
[dispatch] "message.start"  sid="373a5af8"  conn: connected → connected
[dispatch] "thinking.delta"  sid="373a5af8"  conn: connected → connected
```

And the mode-line should show `●` throughout the streaming session.

## Files to touch

| File | Change |
|------|--------|
| `hermes-state.el` | Update `hermes--state-slot-write` to sync active session registry entry |

No other files need changes. The fix is purely in the state persistence layer.

## Cleanup (after verification)

Remove the temporary diagnostic logging added in the previous iteration:
- `hermes-rpc.el`: `[rpc] sentinel fired: ...` line
- `hermes-mode.el`: `[sess] replay gateway.ready? ...` line
- `hermes-state.el`: `[dispatch] ...` line
- `hermes-render.el`: `[ml] buf-conn=...` line
