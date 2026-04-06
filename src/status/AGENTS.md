<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# status

## Purpose
Status bar system. Handles format string expansion (tmux-compatible `#S`, `#W`, `%H:%M` patterns), terminal style definitions, and status bar rendering with left/right sections.

## Key Files

| File | Description |
|------|-------------|
| `format.zig` | `FormatContext` and `expand()` u2014 expands tmux-style format strings (`#S` = session name, `#W` = window name, `%H:%M` = time, etc.) |
| `style.zig` | `Style` struct (fg, bg, attributes) and style string parser for tmux `style` option format |
| `status.zig` | `StatusBar` u2014 left/right sections, style, refresh interval, `render()` producing a padded line |

## For AI Agents

### Working In This Directory
- `StatusBar` defaults: left=`"[#S] "`, right=`" %H:%M %d-%b-%y"`, interval=15s
- Format expansion requires a `FormatContext` with session/window/pane state
- Style parsing handles tmux format: `"fg=red,bg=black,bold"`
- `render()` produces a fixed-width line: left-aligned left section + padding + right-aligned right section

### Testing Requirements
- Test format expansion with various `#` and `%` specifiers
- Test style parsing with combined attributes
- Test status bar rendering at various widths

## Dependencies

### Internal
- `../core/colour.zig` u2014 `Colour` and `Attributes` types

<!-- MANUAL: -->
