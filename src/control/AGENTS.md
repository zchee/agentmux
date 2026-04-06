<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-06 | Updated: 2026-04-06 -->

# control

## Purpose
Control mode for programmatic access to the server. Allows external tools to send commands and receive structured output, similar to tmux's `-C` control mode.

## Key Files

| File | Description |
|------|-------------|
| `control.zig` | Control mode implementation u2014 command dispatch and structured output formatting |

## For AI Agents

### Working In This Directory
- Control mode is activated with the `-C` flag
- Output should be machine-parseable (line-based, prefixed)
- Changes here should maintain compatibility with tmux control mode consumers

## Dependencies

### Internal
- `../protocol.zig` u2014 message framing
- `../cmd/cmd.zig` u2014 command execution

<!-- MANUAL: -->
