# Plan 07 — Backend Request Indirection

**Status:** planned
**Goal:** Add a single indirection point between consumer code and
`hermes-rpc-request`, so a future pi (or other) backend can plug in its
own send function without touching any call site.

---

## 1. Design

Two additions to `hermes-rpc.el`:

```elisp
(defvar hermes--backend-send-function #'hermes-rpc-request
  "Function called by `hermes--request' to send a request to the backend.
Must accept the same signature: (METHOD PARAMS &optional CALLBACK).
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives.  A different backend (e.g. pi) replaces this value.")

(defun hermes--request (method params &optional callback)
  "Send a request with METHOD and PARAMS to the current backend.
Delegates to `hermes--backend-send-function'."
  (funcall hermes--backend-send-function method params callback))
```

**Placement:** Right after the existing `hermes-rpc-request` definition
(hermes-rpc.el:202), before `hermes-rpc--flush-pending`.

### Why variable + wrapper (not just renaming `hermes-rpc-request`)

- Tests can `let`-rebind the variable without redefining function slots
  (cleaner than `cl-letf` on `symbol-function`)
- A future backend just `setq`s one variable — no advice, no monkey-patching
- The wrapper provides a stable, introspectable API name not tied to
  RPC (a pi backend speaks JSONL, not JSON-RPC 2.0)

### Why `hermes--request` (not `hermes-send-request` or similar)

- Double-dash marks it internal — callers shouldn't think about which
  backend is active
- Not tied to "RPC" — a pi backend speaks JSONL
- Short and greppable

### Signature

```
(METHOD PARAMS &optional CALLBACK)
```

Identical to `hermes-rpc-request`.  CALLBACK is `(RESULT ERROR)`.
Exactly one of RESULT / ERROR is non-nil.

**Return value:** `hermes-rpc-request` returns an integer request ID.
No caller uses it.  The wrapper returns whatever the backend function
returns (integer for Hermes, string for pi).  Irrelevant in practice.

---

## 2. Call Sites — Full Inventory

50 references to `hermes-rpc-request` across the codebase.
Breakdown by disposition:

### 2.1 Replace with `hermes--request` (43 sites, 7 files)

| File | Sites | Methods called |
|------|-------|----------------|
| `hermes-input.el` | 9 | `prompt.submit`, `slash.exec`, `shell.exec`, `prompt.background`, `session.steer`, `commands.catalog` |
| `hermes-config.el` | 12 | `config.get`, `config.set`, `toolsets.list`, `tools.configure`, `skills.reload`, `skills.manage`, `slash.exec`, `session.steer` |
| `hermes-mode.el` | 5 | `session.create`, `session.interrupt` |
| `hermes-sessions.el` | 6 | `session.list`, `session.delete`, `session.save`, `session.resume`, `session.branch` |
| `hermes-prompts.el` | 4 | `approval.respond`, `clarify.respond`, `sudo.respond`, `secret.respond` |
| `hermes-image.el` | 3 | `image.attach`, `clipboard.paste`, `input.detect_drop` |
| `hermes-org.el` | 1 | `session.create` |

### 2.2 Keep as-is (5 sites, 1 file)

| File | Sites | Reason |
|------|-------|--------|
| `hermes-rpc.el:175` | 1 | The definition of `hermes-rpc-request` itself |
| `hermes-rpc.el:352` | 1 | Self-call in test helper `hermes-rpc--test-on-session` |
| `hermes-rpc.el:359` | 1 | Self-call in test helper `hermes-rpc--test-on-event` |
| `hermes-rpc.el` (new) | 1 | `hermes--backend-send-function` default value |
| `hermes-rpc.el` (new) | 1 | `hermes--request` body calls through the variable |

The two self-calls in test helpers are transport-layer code that tests
the raw RPC — they should keep calling `hermes-rpc-request` directly.

### 2.3 Update `declare-function` (1 site)

| File | Line | Change |
|------|------|--------|
| `hermes-org.el` | 29 | `(declare-function hermes-rpc-request "hermes-rpc" (method params callback))` → `(declare-function hermes--request "hermes-rpc" (method params &optional callback))` |

### 2.4 Archive — skip

| File | Sites | Reason |
|------|-------|--------|
| `archive/m2-check/e2e-test.el` | 2 | Already stale — won't compile against current code. Skip. |

### 2.5 Test stubs (2 files)

| File | Current pattern | New pattern |
|------|----------------|-------------|
| `test/hermes-input-test.el:24` | `(cl-letf (((symbol-function 'hermes-rpc-request) #'stub)))` | `(let ((hermes--backend-send-function #'stub)))` |
| `test/hermes-render-test.el:709` | `(cl-letf (((symbol-function 'hermes-rpc-request) (lambda (&rest _) nil))))` | `(let ((hermes--backend-send-function (lambda (&rest _) nil))))` |

`hermes-input-test.el:13` also has a docstring mentioning
`hermes-rpc-request` — update that reference.

---

## 3. Implementation Steps

### Step 1 — Add indirection to `hermes-rpc.el`

Insert after the closing paren of `hermes-rpc-request` (line 202):

```elisp
(defvar hermes--backend-send-function #'hermes-rpc-request
  "Function called by `hermes--request' to send a request to the backend.
Must accept (METHOD PARAMS &optional CALLBACK).  CALLBACK is
\(RESULT ERROR).  A different backend (e.g. pi) replaces this value.")

(defun hermes--request (method params &optional callback)
  "Send a request to the current backend via `hermes--backend-send-function'.
METHOD is a string (e.g. \"prompt.submit\"), PARAMS is a plist or alist.
CALLBACK, if non-nil, is called as (RESULT ERROR) when the response
arrives."
  (funcall hermes--backend-send-function method params callback))
```

### Step 2 — Replace all call sites

In each consumer file (`hermes-input.el`, `hermes-config.el`,
`hermes-mode.el`, `hermes-sessions.el`, `hermes-prompts.el`,
`hermes-image.el`, `hermes-org.el`), replace every occurrence of
`hermes-rpc-request` with `hermes--request`.

This is a mechanical s-expression-identical replacement — the
arguments and callback signature don't change.

### Step 3 — Update `declare-function` in `hermes-org.el`

Line 29: point to `hermes--request` instead of `hermes-rpc-request`.

### Step 4 — Update test stubs

Rebind `hermes--backend-send-function` instead of overriding
`symbol-function`.

### Step 5 — Verify

```sh
eldev compile   # 0 warnings expected
eldev test      # 377/377 green, 0 unexpected
```

The change is a pure rename — the variable defaults to the exact
same function.  Zero logic change.

---

## 4. What This Enables (not in scope of this plan)

After this lands, a pi backend plugin can:

```elisp
;; In pi-backend.el (future)
(require 'hermes-rpc)

(setq hermes--backend-send-function #'pi--send)

(defun pi--send (method params callback)
  "Translate Hermes-style (METHOD . PARAMS) to pi JSONL commands."
  (let* ((wire (pi--encode method params))
         (id   (pi--next-id)))
    (when callback
      (puthash id callback pi--pending))
    (pi--write wire)
    id))
```

No file outside `hermes-rpc.el` needs to know which backend is active.
The state reducer, renderer, bench, and Org buffer machinery remain
completely untouched — they only consume `hermes-state` structs via
`hermes-dispatch`, which the adapter produces independently of the
transport.

---

## 5. Files Touched Summary

| File | Change |
|------|--------|
| `hermes-rpc.el` | Add `hermes--backend-send-function` + `hermes--request` |
| `hermes-input.el` | 9x `hermes-rpc-request` → `hermes--request` |
| `hermes-config.el` | 12x `hermes-rpc-request` → `hermes--request` |
| `hermes-mode.el` | 5x `hermes-rpc-request` → `hermes--request` |
| `hermes-sessions.el` | 6x `hermes-rpc-request` → `hermes--request` |
| `hermes-prompts.el` | 4x `hermes-rpc-request` → `hermes--request` |
| `hermes-image.el` | 3x `hermes-rpc-request` → `hermes--request` |
| `hermes-org.el` | 1x call rename + update `declare-function` |
| `test/hermes-input-test.el` | Rebind variable instead of `symbol-function` |
| `test/hermes-render-test.el` | Rebind variable instead of `symbol-function` |

Total: **10 files changed, 0 new files, ~45 lines touched.**
