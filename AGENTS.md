# emacs-hermes

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway`.

## Architecture

```
hermes-rpc.el        JSON-RPC 2.0 transport (make-process, NDJSON, pending callback map)
hermes-events.el     Event/method name registry (single source of truth)
hermes-state.el      TEA-style ephemeral state atoms + pure reducers (in-flight stream, queue, pending)
hermes-render.el     Org buffer renderer (typed segments, incremental diff, adaptive throttling, :HERMES_RAW: drawers)
hermes-mode.el       Org-mode derived major mode, event routing, entry point, buffer parser
hermes-input.el      Input queue, slash commands, history ring, history seed
hermes-prompts.el    Minibuffer handlers (approval, clarify, sudo, secret)
hermes-compose.el    Multi-line org-mode composer (C-c C-c send, C-c C-k cancel)
hermes-bench.el      Persistent bottom bench for hermes-mode (user prompt, reasoning, answer, input)
hermes-sessions.el   tabulated-list-mode sidebar of live sessions
hermes-skin.el       Face-remap skin from gateway.ready colors
hermes-md.el         Best-effort markdown→Org (fences, bold, code, links, italic)
```

**Key design principle:** The Org buffer is the canonical source of truth for
committed conversation history. The state atom (`hermes-state`) only holds
ephemeral data: connection, in-flight stream, pending prompts, queue, and
minibuffer history. Every committed turn stores a `:HERMES_RAW:` drawer
(containing a serialized Elisp plist) at the end of its subtree, enabling
round-trip save/load/resume without a separate serialization format.

**Bench (major mode only):** `hermes-mode` buffers display a persistent bottom
bench (`*hermes-bench:<sid>*`) — a 20-line side-window with structured zones
for the last turn: user prompt, reasoning, answer, and an editable input area.
The bench is a pure display surface (no state atom). On `RET` the old turn is
cleared, the new user prompt appears, and the assistant response streams in.
On `message.complete` the turn is committed to the org buffer; the answer
persists in the bench until the next prompt. Minor mode buffers do not show
the bench (header-line only).

**Doom Emacs integration (separate files, optional):**

```
doom-hermes.el            Evil C-c normal-state bindings + SPC h leader prefix
doom-hermes-theme.el      Hermes-branded dark theme (gold/teal)
```

## Documentation

All reference docs are in [`docs/`](docs/):

| File | What |
|------|------|
| [README.md](docs/README.md) | Index of all docs sections |
| [01-architectural-model.md](docs/01-architectural-model.md) | System architecture, Elm reducer pattern |
| [02-event-protocol-comparison.md](docs/02-event-protocol-comparison.md) | Full event/method matrix vs official TUI |
| [03-state-shape-comparison.md](docs/03-state-shape-comparison.md) | State structs compared to TUI nanostores |
| [06-subagent-delegation-deep-dive.md](docs/06-subagent-delegation-deep-dive.md) | Subagent delegation lifecycle |
| [08-message-stream-segmentation.md](docs/08-message-stream-segmentation.md) | Segmented rendering, buffer structure, markers |
| [13-operational-notes.md](docs/13-operational-notes.md) | Reducer semantics, tool_id fallback, debugging |
| [14-architecture-reference.md](docs/14-architecture-reference.md) | Full architecture dump (transport, input pipeline, doom) |

## Setup

### Prerequisites

- Emacs 27.1+ (27+ for `json-parse-string` / `json-serialize`)
- Python 3.11+ (for the Hermes agent gateway)
- A working Hermes agent installation or checkout

### Quick start

```sh
cd ~/Projects/emacs-hermes
python3 -m venv .venv                     # create virtual environment
.venv/bin/pip install -e hermes-agent      # install the gateway
nix-shell                                  # enter dev shell (Emacs + Eldev)
```

Alternatively, activate the venv manually and set `hermes-rpc-python` in Emacs:

```elisp
(setq hermes-rpc-python "/path/to/.venv/bin/python")
```

The default auto-detects `.venv/bin/python` relative to the project root.

### Vanilla Emacs

```elisp
(add-to-list 'load-path "~/Projects/emacs-hermes")
(require 'hermes-mode)
M-x hermes
```

`M-x hermes` is the single entry point. It pops the most-recently-touched
live session if one exists; otherwise it starts the gateway and creates a
fresh session, popping the new buffer when `session.create` resolves. The
bench appears at the bottom showing a splash banner + status; cursor lands
in the bench input area. The splash is replaced by normal ephemeral content
on the first `RET`.

### Doom Emacs

Add to `~/.config/doom/config.el`:

```elisp
(load-file "~/Projects/emacs-hermes/doom-hermes.el")
```

Restart or `M-x load-file` the file.

## Usage

### Vanilla Emacs keybindings

| Context | Key | Action |
|---------|-----|--------|
| anywhere | `M-x hermes` | Go to primary session (create if none) |
| hermes-mode | `C-c C-i` | Focus bench input (or send via minibuffer if no bench) |
| hermes-mode | `C-c C-k` | Interrupt current turn |
| hermes-mode | `C-c C-l` | Multi-line compose |
| Bench | `RET` / `C-c C-c` | Send prompt |
| Bench | `C-c C-k` | Interrupt parent session |
| Bench | `C-c C-l` | Multi-line compose |
| Sessions sidebar | `RET` | Switch to session |
| Sessions sidebar | `k` | Close session |
| Sessions sidebar | `+` | New session |

### Doom Emacs keybindings

| Key | Action |
|-----|--------|
| `SPC h h` / `SPC h s` / `SPC h i` / `SPC h g` | Go to primary session (create if none) |
| `SPC h n` | New session (background) |
| `SPC h c` | Multi-line composer |
| `SPC h l` | Session list sidebar |
| `SPC h k` | Interrupt primary session |
| hermes-mode `C-c C-i` | Focus bench input |
| hermes-mode `C-c C-k` | Interrupt |
| hermes-mode `C-c C-l` | Multi-line compose |

## Development

### Nix shell

```sh
nix-shell                           # Emacs 30.2 + Eldev
```

### Eldev commands

```sh
eldev compile                        # byte-compile all source files
eldev test                           # run all ERT tests (191/191 green)
eldev emacs -nw                      # interactive Emacs with project loaded
```

### Headless E2E test

```sh
nix-shell --run 'eldev emacs --batch -L . -l hermes-mode -l hermes-render \
  -l m2-check/e2e-test.el'
```

Expect `=== E2E PASSED ===` in `m2-check/e2e-test.log`.

### Test suite

| File | Tests | Scope |
|------|-------|-------|
| `test/hermes-state-test.el` | 66 | Reducers (persistent + UI) + serialization round-trip |
| `test/hermes-render-test.el` | 28 | Segmented renderer + subagent blocks + raw drawer I/O + throttling + incremental diff + post-commit refresh |
| `test/hermes-md-test.el` | 16 | Markdown→Org conversion |
| `test/hermes-input-test.el` | 7 | History seed: builder truncation, sid-based guard, slash-command exemption, all three prompt.submit paths |
| `test/hermes-md-test.el` | 16 | Markdown→Org conversion |

**191/191 green, 0 unexpected** — all tests pass.

## Gateway

The gateway is a Python subprocess running `python -m tui_gateway.entry`. It
speaks newline-delimited JSON-RPC 2.0 over stdio. The Emacs client spawns it
via `make-process`, captures stderr, and dispatches responses by ID through a
pending-callback map.

Configuration is read from `~/.hermes/config.yaml` by the gateway. Environment
variables for API keys (e.g. `OPENROUTER_API_KEY`) must be set before Emacs
starts, or passed via the `process-environment`.
