## 4. Approval Flow Deep Dive

### 4.1 Gateway Side (`tui_gateway/server.py`)

Approvals are routed through `tools/approval.py`.

**Session registration** (`server.py:1937-1942`):
```python
from tools.approval import register_gateway_notify, load_permanent_allowlist
register_gateway_notify(key, lambda data: _emit("approval.request", sid, data))
load_permanent_allowlist()
```

**Blocking prompt factory** (`server.py:723-731`):
```python
def _block(event: str, sid: str, payload: dict, timeout: int = 300) -> str:
    rid = uuid.uuid4().hex[:8]
    ev = threading.Event()
    _pending[rid] = (sid, ev)
    payload["request_id"] = rid
    _emit(event, sid, payload)
    ev.wait(timeout=timeout)
    _pending.pop(rid, None)
    return _answers.pop(rid, "")
```

**Approval response method** (`server.py:3596-3615`):
```python
@method("approval.respond")
def _(rid, params: dict) -> dict:
    session, err = _sess(params, rid)
    if err: return err
    try:
        from tools.approval import resolve_gateway_approval
        return _ok(rid, {
            "resolved": resolve_gateway_approval(
                session["session_key"],
                params.get("choice", "deny"),
                resolve_all=params.get("all", False),
            )
        })
    except Exception as e:
        return _err(rid, 5004, str(e))
```

**Resolution** (`tools/approval.py:517-543`):
```python
def resolve_gateway_approval(session_key: str, choice: str,
                             resolve_all: bool = False) -> int:
    """Called by gateway's /approve or /deny handler to unblock waiting threads.
    When resolve_all=True every pending approval is resolved at once.
    Returns number of approvals resolved."""
    with _lock:
        queue = _gateway_queues.get(session_key)
        if not queue: return 0
        if resolve_all:
            targets = list(queue)
            queue.clear()
        else:
            targets = [queue.pop(0)]
        if not queue:
            _gateway_queues.pop(session_key, None)
    for entry in targets:
        entry.result = choice
        entry.event.set()
    return len(targets)
```

### 4.2 Approval Choices

The canonical choices are:
- **`once`** — allow this single invocation
- **`session`** — allow for this session (adds pattern to `_session_approved`)
- **`always`** — permanently allowlist (adds to persistent allowlist)
- **`deny`** — reject

### 4.3 TUI Frontend (`ui-tui/src/app/useMainApp.ts:681-689`)

```typescript
const answerApproval = useCallback(
  (choice: string) =>
    respondWith('approval.respond', { choice, session_id: ui.sid }, () => {
      patchOverlayState({ approval: null })
      patchTurnState({ outcome: choice === 'deny' ? 'denied' : `approved (${choice})` })
      patchUiState({ status: 'running…' })
    }),
  [respondWith, ui.sid]
)
```

### 4.4 Emacs Frontend (`hermes-prompts.el:61-80`) — Fixed 2026-05-14

```elisp
(defun hermes--prompt-approval (sid rid payload)
  "Ask the user to allow/deny a tool call, then dispatch `approval.respond'.
Canonical choices match the TUI: once, session, always, deny."
  (let* ((cmd (hermes--prompts-get payload "command"))
         (desc (hermes--prompts-get payload "description"))
         (prompt (format "Approve%s%s? "
                         (if desc (format " (%s)" desc) "")
                         (if cmd (format " [%s]" cmd) "")))
         (choice (condition-case _
                     (read-multiple-choice
                      prompt
                      '((?o "once"    "allow this single invocation")
                        (?s "session" "allow for this session")
                        (?a "always"  "allowlist this pattern permanently")
                        (?n "no"      "deny")))
                   (quit '(?n "no" "deny"))))
         (key (car choice))
         (resp (pcase key
                 (?o "once")
                 (?s "session")
                 (?a "always")
                 (_  "deny"))))
    (hermes-rpc-request
     "approval.respond"
     (list :session_id sid :request_id rid :choice resp))))
```

### 4.5 Approval Gap Analysis

| Issue | Detail | Severity | Status |
|-------|--------|----------|--------|
| ~~Non-canonical choice values~~ | ~~Sends `"allow"` instead of `"once"` / `"session"`~~ | ~~**High**~~ | **Fixed 2026-05-14** |
| ~~Missing `always` choice~~ | ~~No way to permanently allowlist a pattern~~ | ~~**High**~~ | **Fixed 2026-05-14** |
| ~~`all` param semantics~~ | ~~`all: true` with `"allow"` approximates `session`, but is ambiguous~~ | ~~**Medium**~~ | **Fixed 2026-05-14** — `all` param removed entirely |
| **No `outcome` tracking** | Turn state does not record approval outcome | Low | Open |
| **Minibuffer UX** | `read-multiple-choice` with `?o/?s/?a/?n` matches TUI keybindings | Low | Fixed 2026-05-14 |

---
