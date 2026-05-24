# hermes.el

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Chat in Org-mode buffers with streaming responses, tool use, subagents, and a
comint bench prompt — all over JSON-RPC 2.0 to the agent's `tui_gateway`.

```
M-x hermes
```

## Prerequisites

- Emacs 27.1+
- Python 3.11+
- [Hermes agent](https://github.com/NousResearch/hermes-agent) installed
- API key for your provider (e.g. `OPENROUTER_API_KEY`)

## Setup

```elisp
(add-to-list 'load-path "/path/to/hermes.el")
(require 'hermes)
```

If you run Hermes inside a virtualenv, point Emacs to its interpreter:

```elisp
(setq hermes-rpc-python "/path/to/venv/bin/python")
```

## Doom Emacs

In `~/.config/doom/packages.el`:

```elisp
(package! hermes
  :recipe (:local-repo "~/Projects/hermes.el"
           :files ("*.el")))
```

In `~/.config/doom/config.el`:

```elisp
(use-package! hermes
  :config
  (require 'hermes-doom))
```

If you prefer not to register the package, this also works:

```elisp
(add-to-list 'load-path "~/Projects/hermes.el")
(after! evil
  (require 'hermes-doom))
```

### Optional

```elisp
(require 'hermes-transient)      ; C-c C-t popup, SPC h . leader
(require 'hermes-notifications)   ; desktop alerts
(setq doom-theme 'hermes-doom)    ; bundled dark theme
```

## Keybindings

| Context | Key | Action |
|---------|-----|--------|
| everywhere | `M-x hermes` | Go to primary session (create if none) |
| Org buffer | `C-c C-i` | Focus bench input |
| Org buffer | `C-c C-k` | Interrupt current turn |
| Org buffer | `C-c C-l` | Multi-line compose |
| Org buffer | `C-c C-m` | Set model |
| Org buffer | `C-c C-f` | Toggle fast mode |
| Bench | `RET` / `C-c C-c` | Send prompt |
| Bench | `C-c C-k` | Interrupt |
| Bench | `C-c C-l` | Multi-line compose |

Full keybindings (Doom `SPC h` leader, Evil, etc.) and optional module details
are in [`AGENTS.md`](AGENTS.md).

## Docs

- [`AGENTS.md`](AGENTS.md) — full setup, usage, keybindings, development
- [`docs/`](docs/) — architecture, event protocol, state shapes, subagents
