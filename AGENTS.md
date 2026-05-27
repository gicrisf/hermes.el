# hermes.el

Emacs client for the [Hermes AI agent](https://github.com/NousResearch/hermes-agent).
Communicates via JSON-RPC 2.0 over stdio to the agent's `tui_gateway`.

## Architecture

```
hermes-rpc.el        JSON-RPC 2.0 transport (make-process, NDJSON, pending callback map)
hermes-events.el     Event/method name registry (single source of truth)
hermes-state.el      TEA-style state atoms + pure reducers (ephemeral: stream, queue, pending; persistent: turns, usage, history)
hermes-org-render.el Org buffer renderer (typed segments, incremental diff, adaptive throttling)
hermes.el            Context-aware entry point, event routing, debug commands
hermes-org-minor-mode.el Org minor mode, keybindings, session-scoped buffer parser
hermes-org.el        Heading-scoped session helpers + v2 buffer-canonical turn parser
hermes-input.el      Input queue, slash commands, history ring, history seed
hermes-prompts.el    Minibuffer handlers (approval, clarify, sudo, secret)
hermes-compose.el    Multi-line org-mode composer (C-c C-c send, C-c C-k cancel)
hermes-comint.el     Comint-derived conversation viewer with inline prompt (incremental segment-diff renderer like hermes-org-render) — also hosts the bench (a `hermes-comint--bench-p = t` variant displayed as a bottom side-window)
hermes-sessions.el   Minibuffer selectors: hermes-current-sessions (live), hermes-stored-{resume,branch,delete,save} (DB); also hosts the DB→Org renderer + install helper for hermes-resume-from-db / hermes-branch-from-db
hermes-skin.el       Face-remap skin from gateway.ready colors
hermes-md.el         Best-effort markdown→Org (fences, bold, code, links, italic)
hermes-config.el     Wrappers for config.get/set, toolsets.list, tools.configure (model/fast/reasoning/yolo/personality/skin/toolsets commands)
hermes-bg.el         Background task buffers (`/bg` prompts run async in dedicated Org buffers)
```

**Comint view vs org view:** `hermes-comint.el` is a pure projection of
`hermes--sessions[sid].turns`.  It has zero awareness of org buffers,
`pending-turns`, or `hermes-org-minor-mode`, and ships its own inline
writable prompt at the buffer bottom (no bench).  The `turns` vector is the
event-canonical conversation log — populated by `hermes--push-committed`
from three reducer paths (`:user-submit`, `"message.complete"`, `"error"`)
at `hermes-state.el:562` and never cleared except by `:turns-load`.
The org buffer is the body-canonical equivalent: you can dump `turns` into
org without loss, and vice versa.

**Key design principle:** The visible Org buffer is the *snapshot* source
of truth — rich, editable, portable across machines.  The gateway's SQLite
DB (`~/.hermes/state.db`) is the *live* shared cache — visible to all
clients (TUI, CLI, Telegram, Emacs) on the same machine.  Both are valid
authorities; the user picks which to use when reopening a stale heading
via `hermes--handle-stale-heading` (load-from-org / resume-from-DB /
branch-from-DB).

The state atom (`hermes-state`) only holds ephemeral data: connection,
in-flight stream, pending prompts, queue, and minibuffer history.  Every
turn heading in the Org snapshot carries `:HERMES_KIND:` (USER /
ASSISTANT / SYSTEM) and `:HERMES_TIMESTAMP:` properties; assistant child
headings (Response / Reasoning / Tool / Subagent) carry their own
`:HERMES_KIND:` markers.  Text content is parsed back from the visible
buffer, so user edits to prose are preserved across resume.

**DB-resumed buffers are intentionally lossy:** the gateway flattens
history via `_history_to_messages` (no `tool_call_id`, no reasoning,
no subagents, no images, no usage, no timestamps).  Tool arguments are
collapsed to a `context` summary string.  Round-tripping a DB resume
back into a canonical Org snapshot loses detail; for full fidelity
across machines, sync the `.org` file rather than the DB.

**Author preference:** Backward compatibility is not a priority. Obsolete
functions, stale docstrings, and misleading feature names are removed
rather than deprecated or kept as aliases.

Usage counters are body-canonical in `HERMES_USAGE_*` heading properties.
Tool segments are body-canonical in `#+name:'d blocks and heading properties;
subagents are body-canonical in child `HERMES_KIND: SUBAGENT` headings.

**Bench:** Org buffers with `hermes-org-minor-mode` display a persistent bottom
side-window (`*hermes-bench:<sid>*`) — a `hermes-comint-mode` buffer with
`hermes-comint--bench-p = t` that renders the in-flight turn ephemerally
(user heading, steer, status, assistant stream) above a writable prompt.
Committed turns live only in the paired org buffer; the bench wipes its
ephemeral region on stream commit. The bench provides comint's history ring
(M-p / M-n) and field-based prompt handling. Bg-task counters and attachment
counts surface in the comint header-line.

**Doom Emacs integration (separate files, optional):**

```
hermes-evil.el            Normal-state Evil C-c bindings (any Emacs with Evil)
hermes-doom.el            Doom SPC h leader prefix (also binds SPC h S steer and SPC h K skills)
hermes-doom-theme.el      Hermes-branded dark theme (gold/teal)
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
- A working Hermes agent installation — see the
  [Hermes installation docs](https://github.com/NousResearch/hermes-agent)

Once the gateway module (`tui_gateway.entry`) is available in your Python
environment, `hermes.el` will use the system `python3` by default.

If you run Hermes inside a virtualenv, point Emacs to its interpreter:

```elisp
(setq hermes-rpc-python "/path/to/venv/bin/python")
```

For finer control you can override the entire spawn command:

```elisp
(setq hermes-rpc-command '("hermes-gateway"))
```

### Nix development shell

Both a classic `shell.nix` and a modern `flake.nix` are provided.

```sh
nix-shell           # classic
nix develop         # flake
```

The shell provides Emacs, Eldev, Python 3.13, and `uv`.  If a `.venv/`
exists at the project root, the shell exports `HERMES_DEV_PYTHON`
pointing to its interpreter.  `hermes-rpc-python` picks this up
automatically, so `M-x hermes` works out of the box.

For automatic activation, use [direnv](https://direnv.net/):

```sh
direnv allow        # once
```

The included `.envrc` enters the Nix shell and applies the same
`HERMES_DEV_PYTHON` logic.

### Vanilla Emacs

```elisp
(add-to-list 'load-path "~/Projects/hermes.el")
(require 'hermes)

;; Optional extras — require individually:
(require 'hermes-transient)        ; C-c C-t popup
(require 'hermes-notifications)    ; desktop alerts

M-x hermes
```

`M-x hermes` is the single entry point. It pops the most-recently-touched
live session if one exists; otherwise it starts the gateway and creates a
fresh session, popping the new buffer when `session.create` resolves. The
bench appears at the bottom as a writable prompt; cursor lands in the input
area.

### Optional modules

The core package stays dependency-free.  `require` each satellite you
want — order does not matter, and each file is safe to load even when
its optional dependency (Evil, Transient) is absent.

| Module | Adds |
|--------|------|
| `hermes-evil` | Normal-state Evil `C-c` bindings (works in any Emacs with Evil) |
| `hermes-transient` | `C-c C-t` Transient popup (also bound under `SPC h .` in Doom) |
| `hermes-notifications` | Desktop notifications on turn completion / blocking prompts / background task completion |
| `hermes-doom` | Doom `SPC h` leader prefix |

### Doom Emacs

In `~/.config/doom/config.el`:

```elisp
(require 'hermes)
(require 'hermes-doom)   ; SPC h leader prefix (also load hermes-evil, hermes-transient, hermes-notifications separately if desired)
```

To use the bundled theme:

```elisp
(setq doom-theme 'hermes-doom)
```

The transient popup is context-sensitive: session-level commands
(send, config, steer, skills uninstall) are hidden when no Hermes
session is active.  Skills reload/list/search/install are always
available and will auto-start the gateway if needed.

Notifications fire via the built-in `notifications' library — DBus on
Linux, Notification Center on macOS — when a turn finishes, a
blocking prompt (approval/clarify/sudo/secret) appears, or a
background task completes while the Hermes buffer is hidden.
Disable at runtime with `(setq hermes-notifications-enabled nil)`.

### Debugging

- `M-x hermes-inspect-turn` — pretty-print the parsed `hermes-message'
  at point into a temporary buffer.
- `M-x hermes-debug-state` — inspect the live state atom for the
  current session.

## Usage

### Vanilla Emacs keybindings

| Context | Key | Action |
|---------|-----|--------|
| anywhere | `M-x hermes` | Go to primary session (create if none) |
| Org buffer | `C-c C-i` | Focus bench input (or send via minibuffer if no bench) |
| Org buffer | `C-c C-k` | Interrupt current turn |
| Org buffer | `C-c C-l` | Multi-line compose |
| Org buffer | `C-c C-m` | Set model (prefix arg: refresh provider list) |
| Org buffer | `C-c C-f` | Toggle fast mode |
| anywhere | `M-x hermes-toggle-reasoning` | Cycle reasoning (prefix arg: pick) |
| anywhere | `M-x hermes-toggle-yolo` | Toggle YOLO mode |
| anywhere | `M-x hermes-set-personality` / `hermes-set-skin` | Set personality / skin |
| anywhere | `M-x hermes-toolsets-toggle` | Enable/disable toolsets |
| Bench | `RET` / `C-c C-c` | Send prompt |
| Bench | `C-c C-k` | Interrupt parent session |
| Bench | `C-c C-l` | Multi-line compose |
| Bench | `C-c C-b` | List background tasks |
| anywhere | `M-x hermes-bg-list` | List background tasks for current session |

### Doom Emacs keybindings

| Key | Action |
|-----|--------|
| `SPC h h` / `SPC h s` / `SPC h i` / `SPC h g` | Go to primary session (create if none) |
| `SPC h n` | New session (background) |
| `SPC h c` | Multi-line composer |
| `SPC h l` | Session list (minibuffer) |
| `SPC h k` | Interrupt primary session |
| `SPC h m` | Set model |
| `SPC h f` | Toggle fast mode |
| `SPC h r` | Cycle reasoning |
| `SPC h y` | Toggle YOLO |
| `SPC h t` | Toggle toolsets |
| `SPC h S` | Steer personality |
| `SPC h K r/l/s/i/u` | Skills (reload/list/search/install/uninstall) |
| `SPC h .` | Transient command popup (requires `hermes-transient`) |
| Org buffer `C-c C-i` | Focus bench input |
| Org buffer `C-c C-t` | Transient command popup (requires `hermes-transient`) |
| Org buffer `C-c C-k` | Interrupt |
| Org buffer `C-c C-l` | Multi-line compose |

### Background tasks

Send a prompt that runs asynchronously in a separate agent thread while
you continue the main conversation.  Background tasks are initiated with
the `/bg` prefix (also `/background` or `/btw`):

```
/bg analyze the test suite for slow tests
```

The bench shows `[bg: 1 running]` while the task executes and
`[bg #N complete] …` when it finishes.  Results appear in a dedicated
`*hermes-bg:<sid>:<task-id>*` Org buffer, not in the main conversation
transcript.  `C-c C-b` from the bench (or `M-x hermes-bg-list`) opens a
listing of all background tasks for the session; `RET` visits a task
buffer and `k` kills it.  Background buffers are user-savable but are
killed automatically when the parent session closes.

---

## Development

### Nix shell

```sh
nix-shell                           # Emacs 30.2 + Eldev
```

### Eldev commands

```sh
eldev compile                        # byte-compile all source files
eldev test                           # run all ERT tests (419/419 green)
eldev emacs -nw                      # interactive Emacs with project loaded
```

### Headless E2E test

```sh
nix-shell --run 'eldev emacs --batch -L . -l hermes -l hermes-org-render \
  -l archive/m2-check/e2e-test.el'
```

Expect `=== E2E PASSED ===` in `archive/m2-check/e2e-test.log`.

**419/419 green, 0 unexpected** — all tests pass.

## Gateway

The gateway is a Python subprocess running `python -m tui_gateway.entry`. It
speaks newline-delimited JSON-RPC 2.0 over stdio. The Emacs client spawns it
via `make-process`, captures stderr, and dispatches responses by ID through a
pending-callback map.

Configuration is read from `~/.hermes/config.yaml` by the gateway. Environment
variables for API keys (e.g. `OPENROUTER_API_KEY`) must be set before Emacs
starts, or passed via the `process-environment`.
