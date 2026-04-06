<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# core

## Purpose
Shared utility modules used across the entire codebase. Provides the custom allocator, colour representation, environment variable management, event loop abstraction, structured logging, and UTF-8 width calculation.

## Key Files

| File | Description |
|------|-------------|
| `allocator.zig` | `ZmuxAllocator` u2014 custom allocator wrapping `std.heap.c_allocator` with tracking |
| `colour.zig` | `Colour` union (default/palette/RGB), named constants, `Attributes` flags, tmux-style colour parsing |
| `environ.zig` | `Environ` u2014 key-value environment variable store with get/set/unset/inherit |
| `event_loop.zig` | Event loop abstraction u2014 interfaces for platform-specific event loops (GCD, io_uring) |
| `log.zig` | Structured logging u2014 level-based (debug/info/warn/error), optional file output |
| `utf8.zig` | UTF-8 utilities u2014 codepoint decoding, `charWidth()` for wide/zero-width character detection |

## For AI Agents

### Working In This Directory
- These modules are imported by almost every other file in the project
- Changes here have wide blast radius u2014 test thoroughly with `zig build test`
- `colour.zig` is the canonical colour type; do not create parallel colour representations
- `log.zig` is initialized once in `main.zig` u2014 use `log.info(...)`, `log.debug(...)` etc.

### Testing Requirements
- Each module has inline `test` blocks
- `utf8.zig` and `colour.zig` have parsing tests that should cover edge cases

### Common Patterns
- `Colour` uses a tagged union: `.default`, `.{ .palette = N }`, `.{ .rgb = .{ .r, .g, .b } }`
- `Environ` stores entries as `[]const u8` key-value pairs in an `ArrayList`

## Dependencies

### External
- `std` (Zig standard library)
- libc for `c_allocator`

<!-- MANUAL: -->
