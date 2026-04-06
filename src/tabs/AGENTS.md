<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# tabs

## Purpose
Native tab bar rendered at the top of the terminal, above the status bar. Provides a browser-style tab interface for switching between sessions.

## Key Files

| File | Description |
|------|-------------|
| `tabs.zig` | `Tab` (id, label, session_id), `TabBar` u2014 add/remove/select/rename tabs, tracks active tab index |

## For AI Agents

### Working In This Directory
- `TabBar` manages a list of `Tab` entries with auto-incrementing IDs
- Each tab maps to a session via `session_id`
- `active_tab` is an index into the tabs array
- Tab labels are owned strings (allocated, freed on remove)
- This is a UI-only layer u2014 session management stays in `server.zig`/`session.zig`

### Testing Requirements
- Test add/remove/select/rename operations
- Test active tab adjustment when tabs before it are removed
- Test empty tab bar state

## Dependencies

### Internal
- No internal dependencies beyond `std`

<!-- MANUAL: -->
