<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# platform

## Purpose
OS abstraction layer. Provides platform detection, default socket directory resolution, process name lookup, and the std.Io runtime wrapper used by the server control plane.

## Key Files

| File | Description |
|------|-------------|
| `platform.zig` | `Os` enum, `defaultSocketDir()`, `getProcessName()` with per-platform dispatch |
| `std_io.zig` | `Runtime` u2014 `std.Io.Threaded` wrapper for the zmux control-plane runtime |

## For AI Agents

### Working In This Directory
- Platform-specific code uses `builtin.os.tag` for conditional compilation
- `platform.zig` is the unified entry point for helpers; keep the std.Io runtime wrapper small and reusable rather than reintroducing bespoke per-platform event-loop code
- Socket directory resolution: `$ZMUX_TMPDIR` > `$TMPDIR` > `/tmp`
- Process name lookup: `proc_pidpath` on macOS, `/proc/<pid>/comm` on Linux

### Testing Requirements
- Platform-specific tests should be gated with `if (builtin.os.tag == .macos)` / `.linux`
- The std.Io runtime wrapper should keep at least one focused test proving the Unix control-plane socket path works

## Dependencies

### External
- `std.Io.Threaded` from the Zig standard library

<!-- MANUAL: -->
