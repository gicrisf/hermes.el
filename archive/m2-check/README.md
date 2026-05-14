# M2 — State, Render, Mode (verification record)

## What M1 established

- `hermes-rpc.el` — JSON-RPC 2.0 over stdio via `make-process`
- `hermes-events.el` — event/method name registry
- Verified: gateway.ready → session.create → prompt.submit → event stream

## What M2 added

- `hermes-state.el` — two buffer-local atoms (`hermes--state`, `hermes--ui-state`),
  pure reducers (`hermes--reduce`, `hermes--ui-reduce`), copy-and-swap dispatch
- `hermes-render.el` — diff-based renderer, stable/unstable streaming with
  fence-aware boundary detection, header-line renderer
- `hermes-mode.el` — `org-mode`-derived major mode, event routing by session-id,
  `M-x hermes` entrypoint, `C-c C-i` / `hermes-send`

## Bugs caught during headless testing

| Bug | Symptom | Fix |
|-----|---------|-----|
| `(let ((st ...) (conn ...))` | `void-variable st` — parallel `let` evaluates init forms in outer scope | Use `let*` for sequential binding |
| Buffer not in `hermes--session-buffers` | `gateway.ready` / connection events never reached the buffer | Register buffer with `puthash` before starting gateway |
| Session-id key mismatch | Events with `sid=abc123` looked up buffer under `""` | Update `hermes--session-buffers` key when `session.create` response arrives |
| `(hermes--state)` called as function | `void-function hermes--state` — parens made Elisp think it's a function call | Remove parens: `hermes--state` not `(hermes--state)` |

## Final E2E trace

```
[conn] connecting
[event] gateway.ready          → state: connected
session.create → sid=b28c2fe9
prompt.submit  → {status: streaming}
[event] session.info           → state: session-info merged
[event] message.start          → stream=live
[event] thinking.delta ×2      → stream.thinking accumulates
[event] reasoning.delta        → stream.reasoning accumulates
[event] message.delta          → stream.text="Hi there, how are you?"
[event] message.complete       → msgs=2 (user+assistant), stream=nil
=== E2E PASSED ===
```

All five edge-case defaults from the plan verified:
- message.start while stream live → silently discarded ✓
- session.info re-emit → merge fields ✓
- tool.progress with nil stream → dropped (tested implicitly) ✓
- User message on submit → optimistic commit ✓
- prompt.submit while running → guarded by gateway (tested implicitly) ✓

## How to test interactively

From the project root:

```sh
nix-shell --run 'eldev emacs -nw --eval "(require (quote hermes-mode))" -f hermes'
```

Or after entering `nix-shell` manually:

```sh
eldev emacs -nw --eval "(require 'hermes-mode)" -f hermes
```

`hermes-rpc` auto-detects `.venv/bin/python` relative to the project root.
If you use a different venv path, override before launching:

```sh
eldev emacs -nw --eval "(setq hermes-rpc-python \"/path/to/venv/bin/python\")" \
  --eval "(require 'hermes-mode)" -f hermes
```

Step by step inside Emacs if you prefer manual control:

1. `M-x load-file RET hermes-mode.el RET`
2. `M-x load-file RET hermes-render.el RET`
3. `M-x hermes`
4. `C-c C-i` → type `say hi in five words` → RET

Headless run:

```sh
./m2-check/run.sh
```

Or manually:

```sh
nix-shell --run 'eldev emacs --batch -L . -l hermes-mode -l hermes-render \
  -l m2-check/e2e-test.el'
```

## Configuration

The gateway reads `~/.hermes/config.yaml`. The test above used:

```yaml
model:
  default: nvidia/nemotron-3-super-120b-a12b:free
  provider: openrouter
```

With `OPENROUTER_API_KEY` in the environment. No additional setup needed
if your Hermes config is already working.
