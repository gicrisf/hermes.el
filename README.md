# emacs-hermes

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway`.

```
M-x hermes
```

## Prerequisites

- Emacs 27.1+
- Python 3.11+
- [Hermes agent](https://github.com/NousResearch/hermes-agent) installed (provides `tui_gateway`)
- API key for your provider (e.g. `OPENROUTER_API_KEY`)

## Setup

### 1. Install the gateway

```sh
pip install hermes-agent   # or from source: pip install -e /path/to/hermes-agent
```

### 2. Configure Emacs

```elisp
(add-to-list 'load-path "/path/to/emacs-hermes")
(require 'hermes-mode)
M-x hermes
```

If `hermes-agent` is in a virtualenv, point Emacs to its Python:

```elisp
(setq hermes-rpc-python "/path/to/venv/bin/python")
```

## Docs

- [`AGENTS.md`](AGENTS.md) — full setup, usage, keybindings, development
- [`docs/`](docs/) — architecture, event protocol, state shapes, subagents
