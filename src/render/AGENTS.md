<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# render

## Purpose
GPU-accelerated rendering system. Provides an abstract renderer interface with Metal (macOS) and Vulkan (Linux) backends, FreeType font rasterization with a glyph atlas cache, and inline image support via Sixel and Kitty protocols.

## Key Files

| File | Description |
|------|-------------|
| `renderer.zig` | `Renderer` vtable interface u2014 `Backend` enum, `RenderConfig`, `VTable` with deinit/resize/beginFrame/endFrame/drawCell/drawRect/drawImage/present/getCellSize |
| `metal.zig` | `MetalRenderer` u2014 macOS Metal backend using Objective-C runtime bindings (`objc_msgSend` trampolines), pipeline state, vertex/uniform buffers, atlas texture |
| `vulkan.zig` | `VulkanRenderer` u2014 Linux Vulkan backend using Vulkan C API, render pass, pipeline, vertex buffer, framebuffer |
| `atlas.zig` | `GlyphAtlas` u2014 texture atlas for caching rasterized font glyphs, row-based packing, keyed by codepoint (u21) |
| `font.zig` | FreeType font loader u2014 C API bindings (`FT_Library`, `FT_Face`, `FT_GlyphSlotRec`), glyph rasterization and atlas population |
| `shaders.zig` | `MetalShaders` u2014 embedded MSL source, function names, attribute/buffer/texture indices, `CellVertex` layout |
| `image.zig` | `Image` and `ImageManager` u2014 RGBA pixel data storage, placement tracking per pane, lifecycle management |
| `sixel.zig` | `SixelImage` u2014 sixel protocol decoder, 256-color palette, RGBA pixel output |
| `kitty.zig` | Kitty image protocol handler u2014 base64 payload decoding, placement, animation |

## Subdirectories

| Directory | Purpose |
|-----------|--------|
| `shaders/` | GPU shader source files (see `shaders/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- `Renderer` is the public interface u2014 other code interacts only through the vtable, never directly with Metal/Vulkan types
- Both backends are conditionally compiled: `MetalRenderer` exists only on macOS, `VulkanRenderer` only on Linux
- Metal uses typed `objc_msgSend` trampolines for Objective-C runtime calls u2014 each signature needs its own extern function
- `GlyphAtlas` uses row-based packing: glyphs fill left-to-right, wrap to next row when full
- `font.zig` uses FreeType's C API via extern declarations u2014 no Zig bindings package
- Image lifecycle: decode (sixel/kitty) u2192 store in `ImageManager` u2192 place in pane u2192 render via `drawImage`
- `CellVertex` layout must match the MSL shader's `VertexIn` struct exactly

### Testing Requirements
- Atlas packing tests: insert glyphs, verify coordinates, handle atlas full
- Sixel decoder tests: colour registers, repeat operator, newline, RGBA output
- Image manager tests: create, lookup, delete, placement tracking
- Renderer tests are primarily visual u2014 verify by running the application

### Common Patterns
- `beginFrame()` u2192 `drawCell()`/`drawRect()`/`drawImage()` for each visible cell u2192 `endFrame()` u2192 `present()`
- Vertex data collected in `ArrayList(CellVertex)` per frame, uploaded to GPU buffer before draw

## Dependencies

### Internal
- `../screen/grid.zig` u2014 `Cell` type for `drawCell()`
- `../core/colour.zig` u2014 `Colour` type for color conversion

### External
- `freetype` u2014 font rasterization (linked in `build.zig`)
- `Metal` + `CoreGraphics` + `QuartzCore` frameworks (macOS, linked in `build.zig`)
- `vulkan` (Linux, linked in `build.zig`)

<!-- MANUAL: -->
