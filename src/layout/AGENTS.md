<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# layout

## Purpose
Pane layout tree for arranging panes within a window. Implements a tree of `LayoutCell` nodes (leaf panes or horizontal/vertical splits), preset layouts matching tmux, and tmux-compatible layout string serialization with checksums.

## Key Files

| File | Description |
|------|-------------|
| `layout.zig` | `LayoutCell` tree node u2014 `CellType` (pane/horizontal/vertical), dimensions, offsets, children, resize logic |
| `set.zig` | `LayoutPreset` enum and `applyPreset()` u2014 even-horizontal, even-vertical, main-horizontal, main-vertical, tiled |
| `custom.zig` | Layout string serialization u2014 `serialize()`/`deserialize()` with tmux-compatible checksum format |

## For AI Agents

### Working In This Directory
- `LayoutCell` is a recursive tree: branches have children, leaves have a pane ID
- Preset layouts compute dimensions from pane count and available space, accounting for border separators
- Custom layout strings use tmux format: `"XXXX,WxH,X,Y{...}"` with 16-bit checksum prefix
- Resize operations propagate through the tree, adjusting sibling sizes

### Testing Requirements
- Test preset layouts with varying pane counts and dimensions
- Test serialization round-trip: layout tree u2192 string u2192 layout tree
- Test checksum calculation matches tmux behavior

## Dependencies

### Internal
- No internal dependencies beyond `std`

<!-- MANUAL: -->
