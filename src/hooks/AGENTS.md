<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# hooks

## Purpose
Event hook system for executing commands in response to lifecycle events. Supports registering commands against hook types (e.g., `after-new-session`, `client-attached`, `pane-exited`) and running them when events fire.

## Key Files

| File | Description |
|------|-------------|
| `hooks.zig` | `HookType` enum (19 event types), `Hook` struct, `HookRegistry` u2014 register/fire hooks by event type |
| `job.zig` | Background job execution for hook commands |
| `notify.zig` | Notification dispatch u2014 routes events to registered hooks |

## For AI Agents

### Working In This Directory
- Adding a new hook type: add variant to `HookType` enum, fire it from the appropriate place in server/session/window code
- `HookRegistry` is owned by `Server` u2014 hooks are global, not per-session
- Hook commands are strings executed through the command registry

### Testing Requirements
- Test hook registration and firing
- Verify hooks fire in registration order

## Dependencies

### Internal
- `../cmd/cmd.zig` u2014 command execution for hook commands

<!-- MANUAL: -->
