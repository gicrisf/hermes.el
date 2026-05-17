# Plan: Bench Splash & Unified Entry Point
## Context
The major-mode bench (`hermes-bench.el`) is now the primary interactive surface. The separate dashboard buffers (`hermes-dashboard.el`, `doom-dashboard-hermes.el`) feel redundant because the bench already provides a persistent bottom panel. The goal is to unify the entry point so `M-x hermes` opens a bench buffer directly, showing a lightweight splash graphic (logo + session status) until the first prompt is sent.
## Goals
1. `M-x hermes` must **never** auto-trigger a prompt/send. It simply opens the bench.
2. The bench should display a **splash** (ASCII logo + one-line status) in its upper region when no conversation has started yet.
3. Cursor must land in the bench input area (bottom).
4. On first `RET` (send), the splash is flushed and normal ephemeral rendering (user prompt / reasoning / answer) takes over.
5. Deprecate or remove the standalone dashboard buffers; the bench splash replaces them.
## Proposed Changes
### 1. `hermes-mode.el` — Entry point semantics
- **Change `hermes`** to act as *go-to-primary-or-create*:
  - If a live session buffer exists (most recently touched), pop it.
  - Otherwise, call `hermes-new-session` and pop the new buffer.
- **Move** `hermes-dashboard--live-buffers` (or an equivalent helper) from `hermes-dashboard.el` into `hermes-mode.el` so the entry point no longer depends on the dashboard file.
- **Remove** the auto-send behavior from any command that currently does it (see Doom & vanilla dashboard below).
### 2. `hermes-bench.el` — Splash rendering
- **Add constants & helpers**:
  - `hermes-bench--builtin-logo` (same ASCII art currently in dashboard).
  - `hermes-bench--splash-logo()` — returns skin-provided banner or builtin fallback (reads `hermes--last-gateway-ready`).
  - `hermes-bench--splash-status()` — returns a one-line string like `●  session XXXXXXXX ready  ·  model-name` (mirrors dashboard status logic).
  - `hermes-bench--short-sid()`.
- **Modify `hermes-bench--paint-ephemeral`**:
  - When `user-text` is nil, `hermes-bench--current-user-prompt` is nil, and no stream is active, insert the splash logo + status at `point-min` before any ephemeral zones.
  - When `user-text` is non-nil (first send), skip the splash entirely and render the normal ephemeral layout.
- **Add `hermes-bench--refresh-ui`**:
  - Hook function for `hermes-ui-state-change-hook` (runs in parent buffer).
  - If the paired bench is live, idle (no stream), and has no user prompt yet, repaints the splash so status updates (e.g. model name from `session.info`) appear in real time.
- **No changes needed** for input logic: `hermes-bench--input-start`, `hermes-bench--input-text`, `hermes-bench-send` already work because the splash lives above `input-boundary`.
### 3. Dashboard files — Deprecation
- **Option A (Recommended):** Delete `hermes-dashboard.el` and `doom-dashboard-hermes.el`. The bench splash is simpler and sufficient.
- **Option B:** Keep them as thin wrappers that only call `hermes` (no separate buffer, no rendering).
- **Update `doom-hermes.el`**:
  - Change `SPC h s` and `SPC h i` bindings from `doom-dashboard-hermes-start` (which pops + sends) to the new `hermes` command (pop only).
  - Remove or deprecate `doom-dashboard-hermes-start` and `doom-dashboard-hermes-compose` if they only duplicated the bench workflow.
### 4. `AGENTS.md` & docs
- Remove dashboard-centric descriptions.
- Update the `M-x hermes` section: it opens the bench directly with a splash.
- Update keybinding tables: remove dashboard keys, note that `M-x hermes` is the single entry point.
## Open Questions / Trade-offs
1. **Dashboard removal?** Should we physically delete `hermes-dashboard.el` and `doom-dashboard-hermes.el`, or keep them as `M-x hermes-dashboard` for users who prefer the old landing screen?
2. **Session creation on `M-x hermes`:** Should `M-x hermes` always create a brand-new session (current behavior), or switch to the most-recent live session if one exists (proposed)? The latter prevents buffer clutter.
3. **Splash after stream ends:** After the first prompt and assistant response complete, should the splash ever reappear (e.g. when the bench is idle again), or is it shown **only once** at session startup and then permanently gone?
