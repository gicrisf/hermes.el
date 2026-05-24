# Hermes Emacs Frontend vs. Official TUI — Reference Document

> **Purpose:** Comprehensive analysis of the official Hermes TUI (`ui-tui` + `tui_gateway`) compared to the Emacs frontend (`hermes.el`). This document captures protocol semantics, state shapes, event handling, and implementation gaps for future development.
>
> **Date:** 2026-05-22
> **Sources:** `hermes-agent/ui-tui/src/`, `hermes-agent/tui_gateway/server.py`, `hermes-agent/tools/approval.py`, and the Emacs codebase (`*.el`).
>
> **Recent changes reflected in this version:**
> - **Org buffer is the canonical source of truth** — committed history lives in the visible buffer, not in a state atom or hidden drawer. Every field (text, tool blocks, subagent trees, usage counters, image references) is body-canonical: parsed back from visible headings, properties, and `#+name:`d blocks. User edits to prose are preserved across resume.
> - State atom is ephemeral only: connection, in-flight stream, queue, pending prompts, history. No committed message duplication.
> - Segmented stream rendering: stream state uses typed `segments` vector; renderer uses incremental diffing (only changed tail is replaced, O(delta) cost)
> - Stream paint throttling with adaptive backoff: 25 Hz for short text, decaying to 0.5 Hz for very long responses
> - Tool rendering moved into segments (tool blocks are interleaved in arrival order, not appended after text)
> - Reasoning rendered as typed segments (not separate marker-managed blocks); thinking is UI-only via header-line status
> - Approval choices fixed to canonical `once`/`session`/`always`/`deny`
> - Usage counters in `HERMES_USAGE_*` heading properties. Tool fields via `#+name`d blocks and TOOL_* properties.
> - **Session management (Phase 1):** Three session slash commands intercepted client-side (`/resume`, `/sessions`, `/delete`) — minibuffer pickers, no RPC sent. Remaining session slashes fall through to `slash.exec` (gateway handles them server-side). Gap matrix rewritten to reflect true wiring state across all RPC methods.

## Sections

- [1. Architectural Model](01-architectural-model.md)
- [2. Event Protocol Comparison](02-event-protocol-comparison.md)
- [3. State Shape Comparison](03-state-shape-comparison.md)
- [4. Approval Flow Deep Dive](04-approval-flow-deep-dive.md)
- [5. Tool Pipeline Deep Dive](05-tool-pipeline-deep-dive.md)
- [6. Subagent / Delegation Deep Dive](06-subagent-delegation-deep-dive.md)
- [7. Gateway Lifecycle Deep Dive](07-gateway-lifecycle-deep-dive.md)
- [8. Message Stream Segmentation](08-message-stream-segmentation.md)
- [9. Input Queue Mechanics](09-input-queue-mechanics.md)
- [10. Detailed Gap Matrix](10-detailed-gap-matrix.md)
- [11. Implementation Plan](11-implementation-plan.md)
- [12. References](12-references.md)
- [13. Operational Notes & Debugging](13-operational-notes.md)
- [15. Bottom Bench](15-bench.md) — Comint-backed bottom side-window showing the current ephemeral turn + writable prompt

- [14. Architecture Reference (Supplementary)](14-architecture-reference.md)

## Doom Emacs Integration

- [Hermes Doom Theme Spec](hermes-doom-theme-spec.md) — brand colors, faces, and theme design
- [Dashboard Spec](hermes-dashboard-spec.md) — dashboard layout and component spec
