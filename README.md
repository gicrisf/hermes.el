# hermes.el

> **Warning:** This project works but is highly unstable and under active
> development.  This is not the definitive documentation.

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Chat in Org-mode buffers with streaming responses, tool use, subagents, and a
comint bench prompt — all over JSON-RPC 2.0 to the agent's `tui_gateway`.

```
M-x hermes
```

## Features

- Org-mode buffers as lossless portable chats — every turn is an Org heading
  with properties, saved as plain .org files; edits survive across resume.
- Org-mode powered tool rendering — Bash, Read, Edit, Grep, and more
  rendered as rich subtrees with status keywords, inline diffs, and named blocks.
- Image support — paste from clipboard or attach files, rendered inline.
- Background tasks — `/bg` prompts run asynchronously in dedicated Org buffers.
- Subagent delegation — spawned subagent trees render in-place with goal,
  thinking trace, tools, and result summaries.
- Interactive configuration — switch models, toggle fast/reasoning/yolo,
  set personality/skin, enable/disable toolsets on the fly.
- Slash commands with completion — client-side session management shortcuts,
  server-side dispatch for everything else with TAB-driven catalog completion.

## Prerequisites

- Emacs 27.1+
- [Hermes agent](https://github.com/NousResearch/hermes-agent) installed (gateway reachable via `python3` or configured via `hermes-rpc-command`)
- API key for your provider (e.g. `OPENROUTER_API_KEY`)

## Setup

```elisp
(add-to-list 'load-path "/path/to/hermes.el")
(require 'hermes)
```

If you run Hermes inside a virtualenv, or its gateway runs in Docker/elsewhere:

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
(use-package! hermes)

;; Optional modules:
(use-package! hermes-evil)           ; normal-state C-c bindings
(use-package! hermes-doom)           ; SPC h leader prefix
;; and other ones
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
