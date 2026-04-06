<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# shaders

## Purpose
GPU shader source files. Contains the Metal Shading Language (MSL) source for the macOS Metal rendering backend.

## Key Files

| File | Description |
|------|-------------|
| `terminal.metal` | MSL shader source u2014 vertex and fragment functions for cell backgrounds, glyph rendering, cursor, selection highlight, and image display |

## For AI Agents

### Working In This Directory
- `terminal.metal` is embedded at compile time via `@embedFile("shaders/terminal.metal")` in `shaders.zig`
- Vertex functions: `vertex_main`, `vertex_fullscreen`
- Fragment functions: `fragment_background`, `fragment_glyph`, `fragment_cell`, `fragment_cursor`, `fragment_selection`, `fragment_image`
- Vertex input matches `CellVertex` in `shaders.zig`: position, tex_coord, fg_color, bg_color, is_glyph
- Changes here require rebuilding the Zig binary to take effect (no runtime shader compilation)

### Testing Requirements
- Visual verification u2014 shader changes must be tested by running the application and inspecting rendering
- Ensure attribute indices match `shaders.zig` constants

## Dependencies

### Internal
- `../shaders.zig` u2014 embeds this file and defines matching constants

<!-- MANUAL: -->
