<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# cmd

## Purpose
Tmux-compatible command registry and handlers. Implements the full set of commands (session, window, pane, buffer, key, option, display) routed through a `Registry` that maps command names and aliases to handler functions.

## Key Files

| File | Description |
|------|-------------|
| `cmd.zig` | `Registry`, `Context`, `CommandDef`, `Handler` type, `registerBuiltins()` with all command registrations and handler implementations |
| `tmux_equivalent_test.zig` | Tests verifying tmux command compatibility |
| `window_commands_test.zig` | Tests for window-related commands (new-window, kill-window, etc.) |
| `pane_commands_test.zig` | Tests for pane-related commands (split-window, select-pane, etc.) |
| `buffer_commands_test.zig` | Tests for paste buffer commands (set-buffer, show-buffer, etc.) |
| `key_commands_test.zig` | Tests for key binding commands (bind-key, unbind-key, etc.) |
| `option_commands_test.zig` | Tests for option commands (set-option, show-options, etc.) |
| `display_commands_test.zig` | Tests for display commands (display-message, display-panes, etc.) |
| `config_shell_test.zig` | Tests for config/shell-related command behavior |

## For AI Agents

### Working In This Directory
- This is the most frequently modified directory (373 edits in hot path data)
- All commands follow the pattern: `fn cmdFooBar(ctx: *Context, args: []const []const u8) CmdError!void`
- `Context` carries `server`, `session`, `window`, `pane`, `client_index`, `allocator`, `reply_fd`
- Commands are registered in `registerBuiltins()` with name, alias, min/max args, usage string, and handler
- Command names match tmux exactly (e.g., `new-session`, `split-window`, `bind-key`)
- Aliases also match tmux (e.g., `new` for `new-session`, `splitw` for `split-window`)

### Testing Requirements
- Each command category has its own `*_test.zig` file
- Tests create a mock server context and verify command behavior
- All test files are imported by `main.zig`'s test block
- Run `zig build test` to execute all command tests

### Common Patterns
- Parse flags with a `while (args) |arg|` loop checking for `-` prefixed args
- Use `ctx.server.findSession(name)` / `ctx.session` / `ctx.window` for target resolution
- Reply to client via `ctx.reply_fd` for output commands
- Return `CmdError.InvalidArgs` for bad arguments, `CmdError.SessionNotFound` for missing targets

## Dependencies

### Internal
- `../protocol.zig` u2014 message framing for replies
- `../server.zig` u2014 `Server` state
- `../session.zig`, `../window.zig` u2014 session/window/pane models
- `../keybind/bindings.zig` u2014 key binding management
- `../copy/copy.zig`, `../copy/paste.zig` u2014 copy mode and paste buffers
- `../mode/tree.zig` u2014 choose-tree UI state
- `../layout/` u2014 layout manipulation
- `../config/parser.zig` u2014 config file command parsing
- `../hooks/hooks.zig` u2014 hook firing after commands
- `../status/format.zig` u2014 format string expansion
- `../clipboard.zig` u2014 clipboard integration

<!-- MANUAL: -->
