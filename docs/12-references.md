## 12. References

### Key Files in Official TUI

| File | Purpose |
|------|---------|
| `ui-tui/src/app/createGatewayEventHandler.ts` | Main event handler (33 event types) |
| `ui-tui/src/app/useMainApp.ts` | Main app hook, action callbacks, RPC calls |
| `ui-tui/src/app/interfaces.ts` | State shape definitions |
| `ui-tui/src/app/overlayStore.ts` | Overlay state management |
| `ui-tui/src/components/prompts.tsx` | Approval/clarify UI components |
| `ui-tui/src/components/appOverlays.tsx` | Overlay dispatch |
| `tui_gateway/server.py` | Gateway RPC methods, event emission, session mgmt |
| `tui_gateway/entry.py` | Gateway entry point, cold-start guards |
| `tools/approval.py` | Approval detection, prompting, session state, resolution |

### Key Files in Emacs Frontend

| File | Purpose |
|------|---------|
| `hermes-rpc.el` | JSON-RPC transport, process lifecycle |
| `hermes-events.el` | Event/method name registry |
| `hermes-state.el` | State atoms, reducer, structs |
| `hermes-org-render.el` | Diff-based Org buffer renderer |
| `hermes.el` | Context-aware entry point, event routing |
| `hermes-org-minor-mode.el` | Org minor mode, keybindings
| `hermes-prompts.el` | Minibuffer handlers for blocking prompts |
| `hermes-input.el` | Input queue, slash commands, history |
| `hermes-sessions.el` | Minibuffer session selectors (current, stored resume/branch/delete/save) |
| `hermes-skin.el` | Gateway skin → face remapping |
| `hermes-md.el` | Markdown→Org converter |
| `hermes-compose.el` | Multi-line composer |

---

*Document generated from analysis of `hermes-agent` commit (May 2026) and `hermes.el` codebase.*
