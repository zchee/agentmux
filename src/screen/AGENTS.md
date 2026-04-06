<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# screen

## Purpose
Terminal screen state management. Models the visible terminal as a grid of cells, provides a writer for cursor movement and text output, and tracks dirty lines for efficient incremental redraw.

## Key Files

| File | Description |
|------|-------------|
| `grid.zig` | `Cell` (codepoint + fg + bg + attrs + width), `Line` (cell array + flags), `Grid` (2D cell array + scrollback history) |
| `screen.zig` | `Screen` u2014 cursor position/style, mode flags (DEC private modes), saved state (DECSC/DECRC), scroll region, alternate screen |
| `writer.zig` | `Writer` u2014 screen write operations: `putChar`, `linefeed`, `carriageReturn`, `backspace`, `tab`, `eraseInLine`, `eraseInDisplay`, `insertLines`, `deleteLines` |
| `redraw.zig` | `DirtyTracker` u2014 per-line dirty flags, force-full flag; `redrawScreen()` outputs only changed lines via `Output` |

## For AI Agents

### Working In This Directory
- `Cell` is the atomic unit: codepoint (u21) + foreground + background + attributes + display width
- `Cell.empty` (codepoint 0, width 0) marks continuation cells of wide characters
- `Cell.blank` (space, width 1) is the default fill
- `Grid` owns rows of `Line`s and provides scrollback via a history ring buffer
- `Screen` holds the grid plus cursor state, DEC mode flags, scroll region, and saved cursor state
- `Writer` operates on a `Screen` pointer and handles wrap-at-margin, scroll region, wide character placement
- `DirtyTracker` enables incremental redraw u2014 only changed lines are re-output
- `Screen.Mode` is a `packed struct(u32)` with DEC private mode bits

### Testing Requirements
- Grid resize tests (grow/shrink columns, preserve content)
- Writer tests: character output, line wrapping, scrolling within scroll region
- Screen mode flag tests (cursor visibility, origin mode, alt screen switch)
- Redraw tests: verify only dirty lines are redrawn

### Common Patterns
- `Writer.init(screen)` creates a temporary write context
- Wide characters (width=2) place the glyph in cell N and `Cell.empty` in cell N+1
- Scroll region is `[scroll_top, scroll_bottom]` inclusive range

## Dependencies

### Internal
- `../core/colour.zig` u2014 `Colour` and `Attributes` types
- `../core/utf8.zig` u2014 `charWidth()` for wide character detection
- `../terminal/output.zig` u2014 `Output` used by `redraw.zig` for terminal output

<!-- MANUAL: -->
