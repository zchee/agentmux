<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# src

## Purpose
All application source code for zmux. The root module is `main.zig`, which re-exports every submodule and serves as the entry point for both the binary and the test suite. Top-level files implement the client/server architecture, while subdirectories organize domain-specific functionality.

## Key Files

| File | Description |
|------|-------------|
| `main.zig` | Entry point — CLI arg parsing, server/client dispatch, module re-exports, test root |
| `server.zig` | Server state — owns sessions, clients, bindings, hooks, paste stack, and the std.Io-backed runtime bootstrap |
| `server_loop.zig` | Per-pane processing state (`PaneState`) — parser + screen + dirty tracker pipeline |
| `client.zig` | Client connection — Unix socket connect, identify, command request, interactive loop |
| `client_terminal.zig` | Raw terminal mode (`RawTerminal`) — saves/restores termios, enters raw mode |
| `protocol.zig` | Wire protocol — message types, 8-byte header, identify/resize/key messages, serialization |
| `session.zig` | Session model — windows list, options (prefix key, status style, shell), environment |
| `window.zig` | Window and Pane models, PromptState, ChooseTreeState |
| `pane.zig` | PTY management (`Pty`) — forkpty, read/write to child process |
| `input_handler.zig` | VT100/xterm event dispatcher — routes parsed events (print, C0, CSI, ESC, OSC) to screen |
| `clipboard.zig` | Clipboard integration via OSC 52 — base64 encode/decode, internal paste buffer |
| `signals.zig` | Signal handling — SIGWINCH, SIGTERM, SIGHUP, SIGUSR1, daemonize |

## Subdirectories

| Directory | Purpose |
|-----------|--------|
| `cmd/` | Tmux-compatible command registry and handlers (see `cmd/AGENTS.md`) |
| `config/` | Configuration parser, option types, and option table (see `config/AGENTS.md`) |
| `control/` | Control mode for programmatic client access (see `control/AGENTS.md`) |
| `copy/` | Copy mode state machine and paste buffer stack (see `copy/AGENTS.md`) |
| `core/` | Shared utilities — allocator, colour, environ, logging, UTF-8 (see `core/AGENTS.md`) |
| `hooks/` | Hook registry, job execution, and notification system (see `hooks/AGENTS.md`) |
| `keybind/` | Key binding manager and key string parser (see `keybind/AGENTS.md`) |
| `layout/` | Pane layout tree, preset layouts, and custom layout serialization (see `layout/AGENTS.md`) |
| `mode/` | Interactive chooser UI — tree widget for choose-tree/choose-buffer (see `mode/AGENTS.md`) |
| `platform/` | OS abstraction — platform detection, process/socket helpers, the std.Io runtime wrapper, and readiness backend glue (see `platform/AGENTS.md`) |
| `render/` | GPU rendering — Metal, Vulkan, glyph atlas, font, image, sixel, kitty, shaders (see `render/AGENTS.md`) |
| `screen/` | Terminal screen state — grid, cell model, writer, dirty-tracked redraw (see `screen/AGENTS.md`) |
| `status/` | Status bar — format expansion, style, rendering (see `status/AGENTS.md`) |
| `tabs/` | Native tab bar above the status line (see `tabs/AGENTS.md`) |
| `terminal/` | Terminal I/O — VT100 parser, key definitions, terminfo, ACS, output buffering, feature detection (see `terminal/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- `main.zig` is both the binary entry point and the test root — all modules must be referenced in its `test` block
- Adding a new module requires: (1) `pub const` import in `main.zig`, (2) `_ = module;` in the test block
- Top-level files handle the client/server architecture; domain logic belongs in subdirectories
- The data flow is: `client.zig` u2192 `protocol.zig` u2192 `server.zig` u2192 `cmd/cmd.zig` u2192 session/window/pane state
- PTY output flow: pty fd u2192 `server_loop.zig` (`PaneState.processPtyOutput`) u2192 `input_handler.zig` u2192 `screen/`

### Testing Requirements
- Run `zig build test` — it compiles from `main.zig` which pulls in all modules
- Each file should have inline `test` blocks for its own logic
- Test files in `cmd/` (e.g., `tmux_equivalent_test.zig`) are imported by `main.zig`

### Common Patterns
- Allocator-based init/deinit lifecycle on all heap-owning types
- `std.ArrayListAligned(T, null)` initialized with `.empty` for growable collections
- `packed struct` for flags and bitfields
- Conditional compilation via `builtin.os.tag` for platform-specific code
- VTable-based polymorphism for the renderer interface

## Dependencies

### Internal
- Every subdirectory depends on `core/` for colour, logging, UTF-8, allocator
- `cmd/` depends on nearly every other module (server, session, window, layout, copy, hooks, etc.)
- `server_loop.zig` bridges `terminal/input.zig`, `input_handler.zig`, and `screen/`

### External
- `std` (Zig standard library)
- libc via `std.c` for POSIX syscalls

<!-- MANUAL: -->
