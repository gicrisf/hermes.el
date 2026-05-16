# emacs-hermes

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway`.

## Architecture

```
hermes-rpc.el        JSON-RPC 2.0 transport (make-process, NDJSON, pending callback map)
hermes-events.el     Event/method name registry (single source of truth)
hermes-state.el      TEA-style state atoms + pure reducers (persistent + UI)
hermes-render.el     Diff-based Org buffer renderer (typed segments, full rewrite)
hermes-mode.el       Org-mode derived major mode, event routing, entry point
hermes-input.el      Input queue, slash commands, history ring
hermes-prompts.el    Minibuffer handlers (approval, clarify, sudo, secret)
hermes-compose.el    Multi-line org-mode composer (C-c C-c send, C-c C-k cancel)
hermes-sessions.el   tabulated-list-mode sidebar of live sessions
hermes-skin.el       Face-remap skin from gateway.ready colors
hermes-md.el         Best-effort markdown→Org (fences, bold, code, links, italic)
hermes-dashboard.el  Vanilla Emacs dashboard (special-mode, no dependencies)
```

**Doom Emacs integration (separate files, optional):**

```
doom-dashboard-hermes.el  Standalone Doom-styled dashboard (window-margin centering,
                          debounced refresh, clickable menu, own buffer *doom-hermes*)
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

`M-x hermes` opens the dashboard, starts the gateway, creates a session in the
background, and registers it as the primary session. The conversation buffer is
ready when you press `C-c C-i`.

### Doom Emacs

Add to `~/.config/doom/config.el`:

```elisp
(load-file "~/Projects/emacs-hermes/doom-dashboard-hermes.el")
(load-file "~/Projects/emacs-hermes/doom-hermes.el")
```

Restart or `M-x load-file` each file.

## Usage

### Vanilla Emacs keybindings

| Context | Key | Action |
|---------|-----|--------|
| Dashboard | `i` | Send prompt to primary session |
| Dashboard | `c` | Open multi-line composer |
| Dashboard | `RET` | On session row: switch; else send |
| Dashboard | `n` | New session |
| Dashboard | `s` | Sessions sidebar |
| Dashboard | `g` | Refresh |
| Dashboard | `q` | Bury dashboard |
| hermes-mode | `C-c C-i` | Send prompt |
| hermes-mode | `C-c C-k` | Interrupt current turn |
| hermes-mode | `C-c C-l` | Multi-line compose |
| Sessions sidebar | `RET` | Switch to session |
| Sessions sidebar | `k` | Close session |
| Sessions sidebar | `+` | New session |

### Doom Emacs keybindings

| Key | Action |
|-----|--------|
| `SPC h d` | Open dashboard |
| `SPC h s` | Start chatting (send prompt) |
| `SPC h i` | Start chatting (alias) |
| `SPC h n` | New session |
| `SPC h c` | Open multi-line composer |
| `SPC h l` | Session list sidebar |
| `SPC h g` | Go to primary session buffer |
| `SPC h k` | Interrupt primary session |
| hermes-mode `C-c C-i` | Send prompt |
| hermes-mode `C-c C-k` | Interrupt |
| hermes-mode `C-c C-l` | Multi-line compose |

### Doom dashboard (`*doom-hermes*`)

The Doom-styled dashboard (`SPC h d`) features:

- **Centred layout** via window margins (same technique as Doom's own dashboard).
  Content is flush-left; margins push the canvas to the centre. No per-line
  padding, no `line-prefix` text properties — just two `set-window-margins` calls.
- **Debounced refresh** — events during a streaming turn coalesce into a single
  repaint after 0.1s of idle time. No freeze, no flicker.
- **Clickable menu** — each row is a `insert-text-button`. The keybinding string
  displayed next to each label is looked up dynamically via `where-is-internal`.
- **Resize handling** — `window-size-change-functions` adjusts margins on resize.

Navigation: `TAB`/`C-n`/`<down>` for next item, `C-p`/`<up>` for previous, `RET`
to activate.

## Development

### Nix shell

```sh
nix-shell                           # Emacs 30.2 + Eldev
```

### Eldev commands

```sh
eldev compile                        # byte-compile all source files
eldev test                           # run all ERT tests (104/104 green)
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
| `test/hermes-state-test.el` | 56 | Reducers (persistent + UI) |
| `test/hermes-render-test.el` | 12 | Segmented renderer + subagent blocks |
| `test/hermes-md-test.el` | 16 | Markdown→Org conversion |

**104/104 green, 0 unexpected** — all tests pass.

## Gateway

The gateway is a Python subprocess running `python -m tui_gateway.entry`. It
speaks newline-delimited JSON-RPC 2.0 over stdio. The Emacs client spawns it
via `make-process`, captures stderr, and dispatches responses by ID through a
pending-callback map.

Configuration is read from `~/.hermes/config.yaml` by the gateway. Environment
variables for API keys (e.g. `OPENROUTER_API_KEY`) must be set before Emacs
starts, or passed via the `process-environment`.
