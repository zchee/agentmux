# zmux

A terminal multiplexer written in [Zig](https://ziglang.org/), feature-compatible with [tmux](https://github.com/tmux/tmux) and extended with GPU-accelerated rendering, image protocol support, and a native tab UI.

## Status

> [!IMPORTANT]
> **Work in progress.** The core architecture is implemented (58 source files, ~10,800 LOC). The binary builds, unit tests pass, and the module pipeline is wired end-to-end. GPU shader implementations and integration testing are in progress.

## Features

### tmux-compatible

- Client-server architecture with detach/reattach via Unix domain sockets
- PTY management (openpty, fork/exec)
- Window/pane layout engine with horizontal/vertical splits
- 5 preset layouts: even-horizontal, even-vertical, main-horizontal, main-vertical, tiled
- Custom layout serialization (tmux-compatible checksum format)
- Key binding engine with prefix key (default: `C-b`) and key tables
- tmux-compatible configuration file syntax (`.tmux.conf`)
- 37 built-in tmux-equivalent commands with 30 aliases (`new-session`, `split-window`, `select-pane`, etc.)
- Status bar with format string expansion (`#S`, `#W`, `#{pane_current_path}`, etc.)
- Style parsing (`fg=red,bg=blue,bold`)
- Copy mode with vi and emacs key bindings, incremental search, visual selection
- Paste buffer stack
- Hooks system (19 event types: `after-new-session`, `client-attached`, etc.)
- Background job management (`run-shell`, `if-shell`)
- Control mode for programmatic integration
- Options system with scoped inheritance (server -> session -> window -> pane)

### Beyond tmux

- **GPU-accelerated rendering** via Metal (macOS) and Vulkan (Linux)
- **Image protocol support**: sixel and kitty graphics protocol decoders
- **Native tab bar UI**
- **Modern event loops**: Grand Central Dispatch on macOS, io_uring on Linux
- **Clipboard integration** via OSC 52
- **Written in Zig**: memory safety, no hidden allocations, comptime, cross-compilation

## Requirements

- [Zig](https://ziglang.org/download/) 0.14+ (developed on 0.16.0-dev nightly)
- C library (libc)
- ncurses/tinfo (for terminfo)
- macOS or Linux

### macOS

- CoreFoundation, CoreGraphics, Metal, QuartzCore, IOKit frameworks (linked automatically)

### Linux

- Vulkan SDK (optional, for GPU rendering)

## Building

```sh
zig build
```

### Run

```sh
zig build run
# or
./zig-out/bin/zmux
```

### Test

```sh
zig build test
```

### Command-line options

```
zmux [-2CDuVv] [-c shell-command] [-f config-file] [-L socket-name] [-S socket-path] [command [flags]]

  -2    Force 256 colors
  -C    Start in control mode
  -D    Do not start server as daemon
  -f    Configuration file path
  -L    Socket name (default: "default")
  -S    Socket path
  -u    UTF-8 mode
  -v    Verbose logging (repeat for more)
  -V    Print version
```

## Architecture

```
Client                            Server
+-----------------+              +-----------------------------------+
| Terminal        |              | Session                           |
| (raw mode)      +-----------+--+ Window                            |
|                 |  Unix     |  |   +-------+  +-------+            |
| Key Input ------+> Socket --+--+-> | Pane  |  | Pane  |            |
|                 |           |  |   | PTY   |  | PTY   |            |
| Screen  <-------+-----------+--+-- | Shell |  | Shell |            |
| Output          |           |  |   +---+---+  +---+---+            |
+-----------------+           |  |       |          |                |
                              |  |       v          v                |
                              |  |   VT Parser                       |
                              |  |       |                           |
                              |  |   Input Handler                   |
                              |  |       |                           |
                              |  |   Screen + Grid                   |
                              |  |       |                           |
                              |  |   Dirty Tracker                   |
                              |  |       |                           |
                              |  |   Redraw --> GPU Renderer         |
                              |  |              or TTY Output        |
                              |  +-----------------------------------+
```

## Source Layout

```
src/
  main.zig                 Entry point, argument parsing
  server.zig               Unix socket server, poll loop
  client.zig               Unix socket client
  server_loop.zig          PTY -> parser -> screen -> redraw pipeline
  input_handler.zig        Map escape sequences to screen operations
  client_terminal.zig      Raw terminal mode, I/O relay
  session.zig              Session management
  window.zig               Window + pane structs
  pane.zig                 PTY management (openpty, fork/exec)
  protocol.zig             Client-server wire protocol
  signals.zig              Signal handling + daemonization
  clipboard.zig            OSC 52 clipboard integration

  core/
    allocator.zig          Debug allocator with leak tracking
    colour.zig             Colour types (256, RGB, named)
    environ.zig            Environment variable store
    event_loop.zig         Platform-agnostic event loop interface
    log.zig                Logging
    utf8.zig               UTF-8 encoding/decoding + width

  terminal/
    input.zig              VT100/xterm escape sequence parser
    keys.zig               Key event types, SGR mouse
    output.zig             Buffered terminal output
    terminfo.zig           C tinfo wrapper
    acs.zig                Alternate character set
    features.zig           Terminal capability detection

  screen/
    grid.zig               Cell/line/grid data structures
    screen.zig             Screen state (cursor, modes)
    writer.zig             Screen write operations
    redraw.zig             Dirty tracking + partial redraw

  layout/
    layout.zig             Layout cell tree
    set.zig                Preset layout algorithms
    custom.zig             Layout string serialization

  config/
    parser.zig             tmux config language parser
    options.zig            Scoped options with inheritance
    options_table.zig      Default options

  cmd/
    cmd.zig                Command registry + 34 tmux-equivalent commands

  keybind/
    bindings.zig           Key tables, prefix key
    string.zig             Key name <-> code conversion

  status/
    style.zig              Style string parser
    format.zig             Format variable expansion
    status.zig             Status bar renderer

  copy/
    copy.zig               Copy mode (vi/emacs)
    paste.zig              Paste buffer stack

  hooks/
    hooks.zig              Hook registry
    notify.zig             Event dispatch
    job.zig                Background job management

  control/
    control.zig            Control mode protocol

  mode/
    tree.zig               Navigable tree UI

  render/
    renderer.zig           Abstract GPU renderer interface
    atlas.zig              Glyph atlas
    metal.zig              Metal backend (macOS)
    vulkan.zig             Vulkan backend (Linux)
    image.zig              Image lifecycle manager
    sixel.zig              Sixel decoder
    kitty.zig              Kitty graphics protocol

  platform/
    platform.zig           Platform detection
    darwin.zig             GCD event loop (macOS)
    linux.zig              io_uring event loop (Linux)

  tabs/
    tabs.zig               Native tab bar UI
```

## Configuration

zmux reads `~/.config/zmux/zmux.conf` on startup. The configuration syntax is compatible with tmux:

```tmux
# Set prefix key
set -g prefix C-a

# Enable mouse
set -g mouse on

# Status bar
set -g status-style 'fg=white,bg=black'
set -g status-left '[#S] '
set -g status-right ' %H:%M'

# Key bindings
bind-key C-a send-prefix
bind-key '"' split-window -v
bind-key '%' split-window -h

# vi copy mode
set -g mode-keys vi
```

## Differences from tmux

| Feature | tmux | zmux |
|---------|------|------|
| Language | C | Zig |
| Event loop | libevent | GCD (macOS) / io_uring (Linux) |
| Rendering | TTY escape sequences | GPU (Metal/Vulkan) + TTY fallback |
| Image support | Sixel (partial) | Sixel + Kitty graphics protocol |
| Tabs | N/A | Native tab bar |
| Config syntax | tmux command language | Same (compatible) |
| Memory safety | Manual | Zig allocator tracking |

## Contributing

Contributions are welcome. Please read the [Code of Conduct](CODE_OF_CONDUCT.md) before contributing.

### Development

```sh
# Build and run tests
zig build test

# Build with debug logging
zig build run -- -v

# Build optimized
zig build -Doptimize=ReleaseFast
```

## License

[Apache License 2.0](LICENSE)
