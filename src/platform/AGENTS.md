<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# platform

## Purpose
OS abstraction layer. Provides platform detection, default socket directory resolution, process name lookup, the std.Io runtime wrapper used by the server control plane, and readiness backend glue (`kqueue` on macOS, `epoll` on Linux, `poll` fallback).

## Key Files

| File | Description |
|------|-------------|
| `platform.zig` | `Os` enum, `defaultSocketDir()`, `getProcessName()` with per-platform dispatch |
| `std_io.zig` | `Runtime` u2014 `std.Io.Threaded` wrapper for the zmux control-plane runtime |
| `poller.zig` | `Poller` u2014 readiness backend wrapper using `kqueue` / `epoll` / `poll` |

## For AI Agents

### Working In This Directory
- Platform-specific code uses `builtin.os.tag` for conditional compilation
- `platform.zig` is the unified entry point for helpers; keep the std.Io runtime wrapper and readiness poller small and reusable rather than reintroducing large bespoke event-loop stacks
- Socket directory resolution: `$ZMUX_TMPDIR` > Linux `$XDG_RUNTIME_DIR` > `$TMPDIR` > `/tmp`
- Process name lookup: `proc_pidpath` on macOS, `/proc/<pid>/comm` on Linux

### Testing Requirements
- Platform-specific tests should be gated with `if (builtin.os.tag == .macos)` / `.linux`
- The std.Io runtime wrapper should keep at least one focused test proving the Unix control-plane socket path works
- The readiness poller should keep focused tests for readable-fd wakeups, gated per platform where needed

## Dependencies

### External
- `std.Io.Threaded` from the Zig standard library
- POSIX readiness APIs: `kqueue` on macOS, `epoll` on Linux, `poll` fallback elsewhere

<!-- MANUAL: -->
