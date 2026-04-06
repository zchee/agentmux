<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# keybind

## Purpose
Key binding management. Maps key combinations to commands, supports key tables (prefix, root, copy-mode), and provides key string parsing/formatting.

## Key Files

| File | Description |
|------|-------------|
| `bindings.zig` | `BindingManager` u2014 manages key tables, `KeyBinding` (key + modifiers + command), `setupDefaults()` installs tmux-compatible default bindings |
| `string.zig` | Key string parser/formatter u2014 converts between human-readable key names (`C-b`, `M-Left`, `F1`) and internal key codes |

## For AI Agents

### Working In This Directory
- `BindingManager` is owned by `Server` u2014 bindings are global
- Default bindings match tmux: `C-b` prefix, then single key dispatches to a command string
- Key tables: `prefix` (after prefix key), `root` (always active), `copy-mode-vi`, `copy-mode`
- `string.zig` handles parsing: `"C-b"` u2192 ctrl+b, `"M-Left"` u2192 meta+left arrow, `"F1"` u2192 F1
- `bind-key`/`unbind-key` commands in `cmd/cmd.zig` modify bindings at runtime

### Testing Requirements
- Test default binding setup matches tmux defaults
- Test key string round-trip: string u2192 key code u2192 string
- Test key table lookup with prefix and root tables

## Dependencies

### Internal
- `../terminal/keys.zig` u2014 `Modifiers` and `SpecialKey` types

<!-- MANUAL: -->
