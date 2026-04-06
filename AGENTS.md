<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# agentmux

## Purpose
A Zig terminal multiplexer with a tmux-compatible client/server architecture. Provides session, window, and pane management over Unix domain sockets, with GPU-accelerated rendering via Metal (macOS) and Vulkan (Linux), FreeType font rasterization, and inline image support (Sixel, Kitty).

## Key Files

| File | Description |
|------|-------------|
| `build.zig` | Zig build script — links libc, ncurses, freetype, and platform frameworks (Metal/Vulkan) |
| `build.zig.zon` | Package manifest — name, version 0.1.0, minimum Zig 0.14.0, no external deps |
| `README.md` | Project overview and usage |
| `LICENSE` | License file |
| `.gitignore` | Git ignore rules |

## Subdirectories

| Directory | Purpose |
|-----------|--------|
| `src/` | All application source code (see `src/AGENTS.md`) |
| `.github/workflows/` | CI workflows |

## For AI Agents

### Working In This Directory
- Build: `zig build` — output goes to `zig-out/bin/agentmux`
- Run: `zig build run -- <args>` or `./zig-out/bin/agentmux <args>`
- Test: `zig build test` — runs all inline `test` blocks from `src/main.zig`
- Format: `zig fmt src/**/*.zig`
- No external Zig dependencies — only system libraries (ncurses, freetype, Metal/Vulkan)
- Socket env vars: `AGENTMUX_SOCKET_NAME`, `AGENTMUX_SOCKET_PATH`, `AGENTMUX_TMPDIR`

### Architecture
- **Client/server model**: `main.zig` → either launches server or acts as one-shot client
- **Protocol**: `protocol.zig` defines wire format (8-byte header, little-endian, max 64KB payload)
- **Server**: `server.zig` owns sessions, windows, panes, bindings, hooks, paste stack
- **Commands**: `cmd/cmd.zig` is the routed command registry with tmux-compatible commands
- **Rendering**: Abstract `Renderer` vtable with Metal and Vulkan backends
- **Terminal I/O**: VT100/xterm parser → screen state machine → dirty-tracked redraw

### Naming Conventions
- `cmdFooBar` for command handlers, `PaneState` for types, `handleX`/`renderY` for actions
- Zig defaults: 4-space indent, `zig fmt` as source of truth
- Extend existing modules before creating new top-level directories

### Testing Requirements
- Inline `test` blocks beside the code they cover
- Run `zig build test` before committing
- For command changes, smoke test: `zig build run -- new-session -s demo`

### Commit Style
- Concise imperative subjects: `scope: imperative summary`
- Scopes: `core`, `cmd`, `screen`, `render`, `terminal`, `layout`, `docs`, `ci`, etc.

## Dependencies

### External
- `libc` — POSIX APIs, socket, fork, pty
- `ncurses` — terminfo database
- `freetype` — font rasterization
- `Metal` + `CoreFoundation` + `CoreGraphics` + `QuartzCore` + `IOKit` (macOS)
- `Vulkan` (Linux)

<!-- MANUAL: -->
