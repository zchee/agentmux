<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# copy

## Purpose
Copy mode state machine and paste buffer management. Implements vi/emacs-style copy mode navigation, visual selection, incremental search, and a stack of named paste buffers.

## Key Files

| File | Description |
|------|-------------|
| `copy.zig` | `CopyState` u2014 copy mode state machine with vi/emacs bindings, visual/visual-line selection, incremental search |
| `paste.zig` | `PasteBuffer` and `PasteStack` u2014 named paste buffers with push/pop/get-by-index/delete operations |

## For AI Agents

### Working In This Directory
- `CopyState` lives on each `Pane` as `copy_state: ?CopyState`
- Copy mode sub-states: `normal`, `visual`, `visual_line`, `search_forward`, `search_backward`
- Actions emitted: `move_cursor`, `start_selection`, `copy_selection`, `cancel`, `search_next/prev`, `scroll_up/down`, `page_up/down`
- `PasteStack` is owned by `Server` u2014 buffers are global across sessions
- Key handling returns `CopyAction` for the caller to act on

### Testing Requirements
- Test state transitions: normal u2192 visual u2192 copy_selection u2192 cancel
- Test vi keybindings (hjkl, /, n, N, v, V, y)
- Test paste buffer push/pop/delete ordering

## Dependencies

### Internal
- `../terminal/keys.zig` u2014 `Modifiers` type for key handling

<!-- MANUAL: -->
