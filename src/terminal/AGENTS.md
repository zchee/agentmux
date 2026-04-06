<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# terminal

## Purpose
Terminal I/O layer. Implements a VT100/xterm input parser (state machine producing typed events), key definitions with modifiers, terminfo database access, Alternate Character Set (ACS) mappings, buffered output with escape sequence generation, and terminal feature detection.

## Key Files

| File | Description |
|------|-------------|
| `input.zig` | VT100/xterm input parser u2014 state machine producing `InputEvent` union (print/c0/csi/osc/esc/dcs), `CSI`/`OSC`/`ESC`/`DCS` parameter structs |
| `keys.zig` | `Modifiers` (ctrl/meta/shift), `SpecialKey` enum (function keys, navigation, editing, mouse, paste) |
| `output.zig` | `Output` u2014 buffered writer to fd with escape sequence helpers: cursor movement, SGR attributes, erase, scroll, clipboard, title |
| `terminfo.zig` | `Terminfo` u2014 reads and queries compiled terminfo database entries |
| `acs.zig` | `AcsMap` u2014 VT100 Alternate Character Set lookup, maps line-drawing chars to Unicode (box drawing, arrows, etc.) |
| `features.zig` | `Features` u2014 packed struct of terminal capability flags (256-color, RGB, sixel, mouse, bracketed paste, etc.), `detectFromTerm()` |

## For AI Agents

### Working In This Directory
- `input.zig` is the core parser u2014 a state machine (`State` enum) that processes bytes one at a time via `feed()`, returning `?InputEvent`
- Parser states: `ground`, `escape`, `escape_intermediate`, `csi_entry`, `csi_param`, `csi_intermediate`, `osc_string`, `dcs_entry`, `dcs_passthrough`
- `CSI` struct: up to 16 params (u16), up to 4 intermediates, `getParam(index, default)` helper
- `Output` buffers 8KB before flushing to fd u2014 call `flush()` after writing a frame
- Feature detection is heuristic based on `$TERM` string matching against known terminal names
- `acs.zig` is a pure lookup table with no state

### Testing Requirements
- Parser tests should cover all state transitions and edge cases (incomplete sequences, unknown finals)
- Test CSI parameter parsing with defaults, missing params, and maximum param count
- Test feature detection for known terminal types (xterm-256color, kitty, alacritty, etc.)

### Common Patterns
- Feed bytes into `Parser.feed(byte)` u2192 get `?InputEvent` u2192 dispatch via `input_handler.handleEvent()`
- Use `Output.print()` for formatted escape sequences, `Output.writeBytes()` for raw data

## Dependencies

### Internal
- `../core/colour.zig` u2014 used by `output.zig` for SGR colour output

### External
- `ncurses` u2014 terminfo database access (linked in `build.zig`)

<!-- MANUAL: -->
