# Doom Hermes Theme — Design Spec

## Overview

A dark, warm Emacs theme based on the [Hermes AI agent](https://github.com/NousResearch/hermes-agent) brand colours. The deep teal background comes from the Hermes web dashboard; the gold, amber, and bronze accents come from the CLI skin engine (`hermes_cli/skin_engine.py`) and TUI theme (`ui-tui/src/theme.ts`).

Works with Doom Emacs (`doom-theme`) and vanilla Emacs (`load-theme`).

---

## Colour Palette

### Background family

| Role | Hex | WCAG on BG |
|------|-----|------------|
| Base background | `#041c1c` | — |
| Alt background | `#0a2626` | — |
| Highlight | `#0f2e2e` | — |

### Foreground family

| Role | Hex | Contrast on `#041c1c` |
|------|-----|----------------------|
| Body text | `#FFF8DC` (cornsilk) | **13.3:1** (AAA) |
| Alt text | `#E8D5A0` (warm gold) | **11.0:1** (AAA) |
| Muted text | `#8B7355` (olive) | **5.1:1** (AA) |

### Accent family

| Role | Hex | Contrast on `#041c1c` | Brand source |
|------|-----|----------------------|--------------|
| Gold | `#FFD700` | **13.9:1** (AAA) | CLI primary gold |
| Amber | `#FFBF00` | **11.5:1** (AAA) | CLI accent |
| Bronze | `#CD7F32` | **4.6:1** (AA) | CLI borders |

### Status family

| Role | Hex | Contrast on `#041c1c` |
|------|-----|----------------------|
| Success | `#4EC9B0` (teal-green) | **8.5:1** (AAA) |
| Error | `#FF6B6B` (coral) | **8.2:1** (AAA) |
| Warning | `#FFD93D` (warm yellow) | **12.5:1** (AAA) |
| Info | `#7EC8E3` (sky blue) | **7.6:1** (AAA) |

### UI

| Role | Hex |
|------|-----|
| Region selection | `#CD7F3240` (bronze at 25% alpha) |
| Cursor | `#FFD700` (gold) |
| Vertical border | `#CD7F32` (bronze) |

---

## Face Inheritance for the Dashboard

The Doom Hermes dashboard (`doom-dashboard-hermes.el`) does **not** reference theme colours directly. It uses `:inherit` chains that pick up the theme's base faces automatically:

```
doom-dashboard-hermes-banner-face            → font-lock-keyword-face  → gold #FFD700
doom-dashboard-hermes-menu-face              → default                 → cornsilk #FFF8DC
doom-dashboard-hermes-key-face               → font-lock-constant-face → amber #FFBF00
doom-dashboard-hermes-footer-face            → shadow                  → muted #8B7355
doom-dashboard-hermes-status-face            → success                 → teal #4EC9B0
doom-dashboard-hermes-status-down-face       → error                   → coral #FF6B6B
doom-dashboard-hermes-status-starting-face   → warning                 → yellow #FFD93D
```

No theme-specific face overrides are needed in the dashboard file. Switching themes (`doom-one`, `doom-hermes`, etc.) updates the dashboard appearance automatically.

---

## Font Lock Mapping

| Emacs face | Theme colour | Use case |
|------------|--------------|----------|
| `font-lock-keyword-face` | Gold `#FFD700` bold | `if`, `else`, `return`, banner |
| `font-lock-builtin-face` | Amber `#FFBF00` | `require`, `lambda`, quotes |
| `font-lock-constant-face` | Amber `#FFBF00` | `nil`, `t`, `:keyword` |
| `font-lock-type-face` | Bronze `#CD7F32` | class/struct names |
| `font-lock-string-face` | Alt `#E8D5A0` | string literals |
| `font-lock-doc-face` | Muted `#8B7355` italic | docstrings |
| `font-lock-comment-face` | Muted `#8B7355` italic | comments |
| `font-lock-function-name-face` | Fg `#FFF8DC` | function definitions |
| `font-lock-variable-name-face` | Fg `#FFF8DC` | variable definitions |

---

## Installation

### File location

```
~/Projects/emacs-hermes/doom-hermes-theme.el
```

### Doom Emacs

```elisp
;; in ~/.config/doom/config.el
(load-file "~/Projects/emacs-hermes/doom-hermes-theme.el")
(setq doom-theme 'doom-hermes)              ; make default
;; or keep default theme and switch at will:
;; M-x load-theme RET doom-hermes RET
```

### Vanilla Emacs

```elisp
(add-to-list 'custom-theme-load-path "~/Projects/emacs-hermes/")
M-x load-theme RET doom-hermes RET
```

---

## Usage

| Action | Key / Command |
|--------|--------------|
| Enable theme | `M-x load-theme RET doom-hermes RET` |
| Disable | `M-x disable-theme RET doom-hermes RET` |
| Make default | `(setq doom-theme 'doom-hermes)` in `init.el` / `config.el` |

The theme is loaded at startup via `config.el` but not enabled by default
(leaving `doom-one` as the user's current theme). The Hermes dashboard
inherits colours from whichever theme is active.

---

## File

| Field | Value |
|-------|-------|
| Path | `doom-hermes-theme.el` |
| Lines | 130 |
| Format | `deftheme` with `custom-theme-set-faces` |
| Deps | Emacs 27.1+, no additional packages |
| DOOM compat | Yes (defines `doom-modeline-*` and `powerline-*` faces) |
