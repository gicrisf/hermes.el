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

## Doom Emacs

### Local repo via `packages.el` (recommended)

In `~/.config/doom/packages.el`:

```elisp
(package! hermes
  :recipe (:local-repo "~/Projects/hermes.el"
           :files ("*.el")))
```

In `~/.config/doom/config.el`:

```elisp
(use-package! hermes-mode
  :config
  (require 'hermes-doom))
```

**Important:** Always load `hermes-doom` inside `use-package!` or `after! evil`.
Doom lazy-loads Evil, and loading `hermes-doom` too early causes an
`(invalid-function evil-define-key)` error because `evil-define-key` is a
macro that is not yet available during early init.

### Manual `load-path` (no package.el)

If you prefer not to register the package with Doom:

```elisp
(add-to-list 'load-path "~/Projects/hermes.el")
(after! evil
  (require 'hermes-doom))
```

### Optional: bundled theme

```elisp
(setq doom-theme 'hermes-doom)
```

## Keybindings

| Context | Key | Action |
|---------|-----|--------|
| anywhere | `M-x hermes` | Go to primary session (create if none) |
| hermes-mode | `C-c C-i` | Focus bench input (or send via minibuffer if no bench) |
| hermes-mode | `C-c C-k` | Interrupt current turn |
| hermes-mode | `C-c C-l` | Multi-line compose |
| hermes-mode | `C-c C-m` | Set model (prefix arg: refresh provider list) |
| hermes-mode | `C-c C-f` | Toggle fast mode |
| Bench | `RET` / `C-c C-c` | Send prompt |
| Bench | `C-c C-k` | Interrupt parent session |
| Bench | `C-c C-l` | Multi-line compose |

See `AGENTS.md` for the full Doom leader key table (`SPC h ...`).

## Docs

- [`AGENTS.md`](AGENTS.md) — full setup, usage, keybindings, development
- [`docs/`](docs/) — architecture, event protocol, state shapes, subagents
