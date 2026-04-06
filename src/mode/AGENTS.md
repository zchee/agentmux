<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# mode

## Purpose
Interactive chooser UI widgets. Provides the tree widget used by `choose-tree`, `choose-buffer`, `choose-client`, and similar commands.

## Key Files

| File | Description |
|------|-------------|
| `tree.zig` | `ModeTree` u2014 scrollable tree widget with `TreeItem` (label, depth, expanded, has_children, tag), keyboard navigation (up/down/enter/escape), expand/collapse, filtering, scroll offset |

## For AI Agents

### Working In This Directory
- `ModeTree` is a flat list of `TreeItem`s with depth levels to represent hierarchy
- Items have an opaque `tag: u32` for identifying the underlying session/window/pane/buffer
- Key handling returns `TreeAction`: `none`, `select`, `cancel`, `toggle_expand`
- Filtering: set `filtering = true`, type into `filter` buffer, items are matched against labels
- Scroll offset tracks the viewport for large lists; `visible_rows` is set from terminal height
- `ChooseTreeState` in `window.zig` wraps `ModeTree` with `ChooseTreeItem` for back-references

### Testing Requirements
- Test navigation: up/down wrapping, expand/collapse with children
- Test filtering: partial match, empty filter, no matches
- Test scrolling: offset updates when selected item moves out of viewport

## Dependencies

### Internal
- No internal dependencies beyond `std`

<!-- MANUAL: -->
