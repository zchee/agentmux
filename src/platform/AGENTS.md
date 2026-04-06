<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# platform

## Purpose
OS abstraction layer. Provides platform detection, default socket directory resolution, process name lookup, and platform-specific event loop implementations (GCD for macOS, io_uring for Linux).

## Key Files

| File | Description |
|------|-------------|
| `platform.zig` | `Os` enum, `defaultSocketDir()`, `getProcessName()` with per-platform dispatch |
| `darwin.zig` | `GcdEventLoop` u2014 macOS Grand Central Dispatch event loop for socket/PTY I/O |
| `linux.zig` | `IoUringEventLoop` u2014 Linux io_uring-based event loop |

## For AI Agents

### Working In This Directory
- Platform-specific code uses `builtin.os.tag` for conditional compilation
- `platform.zig` is the unified entry point; avoid importing `darwin.zig` or `linux.zig` directly from other modules (except `main.zig` and `server.zig` which need the concrete types)
- Socket directory resolution: `$ZMUX_TMPDIR` > `$TMPDIR` > `/tmp`
- Process name lookup: `proc_pidpath` on macOS, `/proc/<pid>/comm` on Linux

### Testing Requirements
- Platform-specific tests should be gated with `if (builtin.os.tag == .macos)` / `.linux`

## Dependencies

### External
- macOS: `CoreFoundation`, `IOKit` frameworks (linked in `build.zig`)
- Linux: `liburing` / io_uring syscalls

<!-- MANUAL: -->
