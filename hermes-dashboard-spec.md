# Hermes Dashboard — Design Spec

Two independent dashboard implementations exist:

- **Core dashboard** (`hermes-dashboard.el`) — vanilla Emacs, no dependencies.
  Buffer: `*Hermes*`. Mode: `hermes-dashboard-mode`.
- **Doom dashboard** (`doom-dashboard-hermes.el`) — Doom-styled, standalone.
  Buffer: `*doom-hermes*`. Mode: `doom-dashboard-hermes-mode`.

Both are loaded independently and do not interfere. The core dashboard is
accessed via `M-x hermes` in vanilla Emacs; the Doom dashboard via `SPC h d`
in Doom Emacs.

---

## Core dashboard (`*Hermes*`)

The vanilla dashboard is a `special-mode` buffer split into three zones:

### 1. Logo banner

Unicode "HERMES" block-art, centred horizontally. Connection status
(`● connected` / `● gateway down` / `● starting session…`) appended to the
last logo line, right-padded to the logo width.

### 2. Session information

- Model name
- Session ID
- Tools / Skills count

When no session exists, shows: `(no session)`.

### 3. Actions

- `i` / `RET` — send prompt to primary session
- `c` — multi-line composer
- `n` — new session
- `s` — sessions sidebar
- `g` — refresh
- `q` — bury

### Keymap

Standard Emacs `define-key` in `hermes-dashboard-mode-map`. No Evil remaps,
no Doom-specific code.

---

## Doom dashboard (`*doom-hermes*`)

Standalone buffer styled after Doom Emacs's `+doom-dashboard-mode`.
Independent of the core dashboard — no shared code.

### Layout

```
              ██╗  ██╗███████╗██████╗ ███╗   ███╗███████╗███████╗
              ██║  ██║██╔════╝██╔══██╗████╗ ████║██╔════╝██╔════╝
              ███████║█████╗  ██████╔╝██╔████╔██║█████╗  ███████╗
              ██╔══██║██╔══╝  ██╔══██╗██║╚██╔╝██║██╔══╝  ╚════██║
              ██║  ██║███████╗██║  ██║██║ ╚═╝ ██║███████╗███████║
              ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝╚══════╝

        ● session af19d21b ready  ·  nvidia/nemotron-3-super-120b-a12b

          Start chatting                                                  SPC h i
          Open composer                                                   SPC h c
          New session                                                     SPC h n
          Session list                                                    SPC h l
          Quit

                         1 session live  ·  gateway up
```

### Centering

- **Horizontal**: window margins via `set-window-margins`. Content is flush-left;
  margins push the canvas to the centre. Recalculated on `window-configuration-change-hook`.
- **Vertical**: blank lines at top, sized to `(/ (window-height) 2)`. Recalculated
  on `window-size-change-functions`.

### Performance

Debounced refresh via `run-with-idle-timer` (default 0.1s). Burst events
(gateway.ready + session.info + message.complete) coalesce into a single
repaint. Streaming deltas (message.delta, tool.progress) are filtered entirely
and never trigger a refresh.

### Keybindings

Menu keybindings are auto-detected at render time via `where-is-internal`.
The display shows whatever key is actually bound to each command. Single-letter
shortcuts in the dashboard buffer:

| Key | Action |
|-----|--------|
| `s` | Start chatting |
| `c` | Open composer |
| `n` | New session |
| `l` | Session list sidebar |
| `g` | Refresh |
| `q` | Quit |
| `TAB` / `C-n` / `<down>` | Next item |
| `C-p` / `<up>` | Previous item |
| `RET` | Activate item |

### Faces

| Face | Inherits | Used for |
|------|----------|----------|
| `doom-dashboard-hermes-banner-face` | `font-lock-keyword-face` | Logo banner |
| `doom-dashboard-hermes-menu-face` | `default` | Menu row labels |
| `doom-dashboard-hermes-key-face` | `font-lock-constant-face` | Keybinding strings |
| `doom-dashboard-hermes-footer-face` | `shadow` | Status footer |
| `doom-dashboard-hermes-status-face` | `success` | Gateway up dot |
| `doom-dashboard-hermes-status-down-face` | `error` | Gateway down dot |
| `doom-dashboard-hermes-status-starting-face` | `warning` | Gateway starting dot |

All adapt to the active Emacs theme — no hardcoded colours.

### Customisation

```elisp
(setq doom-dashboard-hermes-width 80)         ;; canvas width in columns
(setq doom-dashboard-hermes-banner "...")     ;; override logo
(setq doom-dashboard-hermes-debounce 0.1)     ;; idle seconds before refresh
(setq doom-dashboard-hermes-menu             ;; override menu items
      '(("Action" some-command) ...))
```
