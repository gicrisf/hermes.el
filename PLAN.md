# Plan: Skills management commands

## Problem

The Hermes gateway exposes two skills-related RPC methods that the Emacs client does not currently call:

- `skills.reload` — rescans the skills directory and reports added/removed skills.
- `skills.manage` — list, search, install, inspect, or browse skills from the skills hub.

These are listed in the gap matrix as low-value, but they are genuinely useful: installing skills mid-session is a common workflow, and reloading after adding local skills is faster than restarting the gateway.

## Gateway API

### `skills.reload`
- Params: `{}` (no `session_id`)
- Response: `{"output": "...", "result": {"added": [...], "removed": [...], "total": N}}`
- Handler type: quick (synchronous)

### `skills.manage`
- Params: `{"action": "...", "query": "...", "page": N, "page_size": N}` (no `session_id`)
- Actions:
  - `list` → `{"skills": {"category": ["skill1", ...], ...}}`
  - `search` → `{"results": [{"name": "...", "description": "..."}, ...]}`
  - `install` → `{"installed": true, "name": "..."}`
  - `inspect` → `{"info": {...}}`
  - `browse` → paginated hub results
- Handler type: long (asynchronous, processed in worker pool)

## Proposed changes

### 1. Register methods in `hermes-events.el`

Add `"skills.reload"` and `"skills.manage"` to `hermes-rpc-methods`.

### 2. Add interactive commands in `hermes-config.el`

All commands are global (no `session_id`), so they do not use `hermes--config-resolve-target`.

#### `hermes-skills-reload`
- Calls `skills.reload`.
- Echoes the `output` string (from the response) to the minibuffer message area.

#### `hermes-skills-list`
- Calls `skills.manage` with `action: "list"`.
- Displays the category→skills map in a temporary `*Hermes Skills*` buffer in `tabulated-list-mode` or plain `outline-mode`.

#### `hermes-skills-search`
- Prompts the user for a query string.
- Calls `skills.manage` with `action: "search"` and `query`.
- Presents the `results` array via `completing-read`.
- Candidates are formatted as `"name — description"`.
- On selection, copies the skill name to the kill ring and shows it in the message area (so the user can then run `hermes-skills-install`).

#### `hermes-skills-install`
- **Without prefix arg:** runs the search flow (same as `hermes-skills-search`), then immediately calls `skills.manage` with `action: "install"` and the selected skill name.
- **With prefix arg (C-u):** prompts for a skill name verbatim (bypasses search), then calls `skills.manage` with `action: "install"`.
- On success, echoes `"Installed <name>"`. On error, echoes the error message.

### 3. Keybindings

**Vanilla:**
- `M-x hermes-skills-reload`
- `M-x hermes-skills-list`
- `M-x hermes-skills-search`
- `M-x hermes-skills-install`

**Doom Emacs (add to `doom-hermes.el`):**
- `SPC h S r` — reload
- `SPC h S l` — list
- `SPC h S s` — search
- `SPC h S i` — install

## Testing

1. Run `eldev test` to ensure no regressions.
2. Manually test against a live gateway:
   - `M-x hermes-skills-reload` should show a minibuffer message with the reload result.
   - `M-x hermes-skills-list` should populate a buffer with categorized skills.
   - `M-x hermes-skills-search` with query `"git"` should return matching skills via completing-read.
   - `M-x hermes-skills-install` should install a selected skill and confirm.

## Notes

- Both RPCs are global (no `session_id`), so they work even when no session is active.
- `skills.manage` is a long handler — responses arrive asynchronously. All commands must use `hermes-rpc-request` with a callback (consistent with `hermes-toolsets-toggle`).
- `skills.reload` is quick, but using the same async callback pattern keeps the implementation uniform.
