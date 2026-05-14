## 7. Gateway Lifecycle Deep Dive

### 7.1 Startup Sequence

**TUI:**
1. Spawn gateway process
2. Wait for `gateway.ready`
3. Apply skin
4. Fetch `commands.catalog`
5. Check `STARTUP_RESUME_ID` env → resume if set
6. Else check `display.tui_auto_resume_recent` config → resume most recent
7. Else create new session
8. Schedule `STARTUP_QUERY` / `STARTUP_IMAGE` if set

**Emacs:**
1. Spawn gateway process (`hermes-rpc-start`)
2. Wait for `gateway.ready`
3. Set connection=connected, store skin
4. Create new session (`session.create`)
5. Fetch `commands.catalog` after session creation

**Gap:** No auto-resume, no startup prompt, no `STARTUP_RESUME_ID` handling.

### 7.2 Error Handling

**TUI:**
- `gateway.start_timeout` → detailed error with stderr tail
- `gateway.protocol_error` → warning status + activity
- `gateway.stderr` → activity items in turn feed
- `error` → resets turn state, pushes activity, handles "No provider" setup overlay

**Emacs:**
- `gateway.start_timeout` → no handler
- `gateway.protocol_error` → `message` call only
- `gateway.stderr` → separate hook, never in chat buffer
- `error` → appends system message, does not reset turn state

**Gap:** Critical debug info is invisible or insufficient.

---
