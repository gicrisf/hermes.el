# Hermes Dashboard — Design Spec

## What it is

The Hermes dashboard is the landing screen shown when you invoke `M-x hermes` or press `SPC h d` in Doom Emacs.

## Layout

The dashboard is a read-only, full-window buffer divided into three visual zones, top to bottom:

### 1. Logo banner

A large ASCII "HERMES" wordmark in block characters, centred horizontally. The logo has no accompanying status text — it is a pure visual identifier.

### 2. Session information panel

Three lines below the logo:

| Line | Content                                                                            |
|------|------------------------------------------------------------------------------------|
| 1    | Connection status: `● connected`, `● starting session…`, or `● gateway down`       |
| 2    | Model name (e.g. `Model: nvidia/nemotron-3-super-120b-a12b:free`)                  |
| 3    | Session ID and tool/skill counts (e.g. `Session: a1b2c3d4 | Tools: 12  Skills: 5`) |

All three lines are centred to the same horizontal alignment.

When no session exists, the panel shows a single prompt: `Press SPC h n to start a session`.

### 3. Action menu

A list of clickable action items, each with an auto-detected keybinding displayed to the right:

```
  Send                  SPC h i
  Interrupt             SPC h k
  Compose               SPC h c
  New session           SPC h n
  Sessions              SPC h s
  Refresh               SPC g
```

Pressing any keybinding invokes the action directly; clicking the label with a mouse works too. The keybindings are detected at render time by looking up the current mode's keymap — they always reflect the user's actual bindings, not hardcoded assumptions.

## Behaviour

### Vertical centering

The entire content block (logo + session panel + action menu) is vertically centred in the window. When you resize the Emacs frame or change the window height, the content re-centres immediately without a full redraw — only the blank padding at the top adjusts. Dragging margins or splitting windows is instant.

### Navigation

| Key             | Action                                                  |
|-----------------|---------------------------------------------------------|
| `n` / `p`       | Next / previous item in the action menu                 |
| `TAB` / `S-TAB` | Next / previous item                                    |
| `RET`           | Invoke the action under point                           |
| `g`             | Full content rebuild (re-read session state, re-centre) |
| `q`             | Close the dashboard window                              |

In Doom Emacs with Evil, hjkl also navigate between items, and all Evil insertion/change commands are disabled — the dashboard is read-only.

## Visual style

The dashboard uses the same face hierarchy as the Doom Emacs splash screen:

- Logo text inherits from `+dashboard-banner` (comment-face tone)
- Action labels inherit from `+dashboard-menu-title` (keyword-face)
- Keybinding descriptions inherit from `+dashboard-menu-desc` (constant-face)
- Secondary info (session ID, tool counts) inherits from `+dashboard-loaded` (dimmed)

No hardcoded colours — everything adapts to the active Emacs theme.
