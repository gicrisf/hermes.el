# hermes.el

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

Install the Hermes agent first — see the
[Hermes installation docs](https://github.com/NousResearch/hermes-agent).
Once the gateway module (`tui_gateway.entry`) is available in your Python
environment, `hermes.el` will use the system `python3` by default.

```elisp
(add-to-list 'load-path "/path/to/hermes.el")
(require 'hermes-mode)
M-x hermes
```

If you run Hermes inside a virtualenv, point Emacs to its interpreter:

```elisp
(setq hermes-rpc-python "/path/to/venv/bin/python")
```

## Docs

- [`AGENTS.md`](AGENTS.md) — full setup, usage, keybindings, development
- [`docs/`](docs/) — architecture, event protocol, state shapes, subagents
