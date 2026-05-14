# Hermes Emacs Frontend vs. Official TUI — Reference Document

> **Purpose:** Comprehensive analysis of the official Hermes TUI (`ui-tui` + `tui_gateway`) compared to the Emacs frontend (`emacs-hermes`). This document captures protocol semantics, state shapes, event handling, and implementation gaps for future development.
>
> **Date:** 2026-05-13 (updated 2026-05-14)
> **Sources:** `hermes-agent/ui-tui/src/`, `hermes-agent/tui_gateway/server.py`, `hermes-agent/tools/approval.py`, and the Emacs codebase (`*.el`).
>
> **Recent changes reflected in this version:**
> - Segmented stream rendering: stream state uses typed `segments` vector; renderer does full rewrite
> - Tool rendering moved into segments (tool blocks are interleaved in arrival order, not appended after text)
> - Thinking/reasoning rendered as typed segments (not separate marker-managed blocks)
> - Approval choices fixed to canonical `once`/`session`/`always`/`deny`

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
