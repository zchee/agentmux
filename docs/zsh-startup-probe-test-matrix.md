# zsh startup probe relay v1: regression matrix

This matrix complements `docs/zsh-startup-probe-relay-v1.md` by mapping the
consensus-plan acceptance criteria onto the current test surface. The goal is to
make it obvious which tests already protect adjacent behavior and which new
coverage the startup relay work still needs.

## Existing tests to keep green

| Area | Existing test anchor | Why it still matters |
| --- | --- | --- |
| Protocol nonblocking framing | `src/protocol.zig` — `test "nonblocking recv preserves fragmented frame state"` | New relay messages should reuse the same fragmented nonblocking framing model. |
| Startup output drain | `src/server.zig` — `test "createSession drains startup output so pane accepts input"` | Relay work must not regress initial pane readiness. |
| Early key delivery after attach | `src/server.zig` — `test "protocol identify then new-session then key input reaches shell"` | `.ready` / raw-mode timing must continue to preserve startup keystrokes. |
| No fixed startup delay before attach | `src/server.zig` — `test "handleClientReadable attaches a new session without fixed startup delay"` | The relay must not reintroduce the blocking attach warmup path that main just removed. |
| Fragmented client frame handling | `src/server.zig` — `test "handleClientReadable preserves fragmented nonblocking client frames"` | Relay messages and attach handshakes should remain correct under split reads. |
| Pending PTY writes | `src/server.zig` — `test "handleClientKey queues pane input when nonblocking writes back up"` | Probe reply injection cannot regress queued pane writes or dead-pane CPU protections. |
| Ordinary interactive input | `src/server.zig` — `test "handleClientKey forwards input bytes to interactive shells"` and `test "handleClientReadable forwards protocol key payloads to interactive shells"` | Buffered user input must still reach the shell after relay exit. |

## New tests required for the relay work

### Protocol layer

1. `terminal_probe_ready` frame roundtrip
2. `terminal_probe_req` frame roundtrip with request id, owner id, probe kind,
   and payload bytes
3. `terminal_probe_rsp` frame roundtrip with request id, status, and payload
4. fragmented nonblocking delivery for the new relay messages

Suggested home: `src/protocol.zig`

## Server lifecycle / ownership

1. relay owner uses stable `client_id`, not array index
2. non-owning attached clients do not receive probe requests
3. `relay_startup_pending -> relay_startup_active` requires
   `terminal_probe_ready`
4. relay exits on quiescence / timeout / first newline flush
5. probe request bytes are intercepted before ordinary render/broadcast
6. reply bytes are injected back through the pane input path

Suggested home: `src/server.zig`

## Client stdin demux / buffering

1. active probe reply bytes are consumed by the in-flight matcher
2. non-matching bytes are buffered as user input during relay
3. buffered user input flushes in-order when relay closes
4. ordinary interactive mode resumes after relay exit without losing prefix or
   resize behavior

Suggested home: `src/client.zig` or focused helpers extracted from it

## End-to-end validation evidence

These are not just unit tests; they are the acceptance checks the final lane
should capture before claiming the feature is complete.

### Minimal-home

- PTY-driven prompt timing for direct `zsh -i`
- PTY-driven prompt timing for `zmux new -s test`
- confirm the relay does not regress the already-good minimal-home path

### Real-home

- immediate `touch` command succeeds in at least 4/5 runs
- mean completion time under 2.0s and max under 3.0s
- child `zsh` sample no longer shows prolonged `probe_terminal` as the dominant
  wait

## Review checklist for the integration diff

- [ ] Startup relay ownership is keyed by stable `client_id`
- [ ] `.ready` still arrives promptly and is not delayed by extra drain work
- [ ] `handleClientKey()` is bypassed or wrapped correctly during relay demux
- [ ] PTY probe bytes are intercepted before ordinary composed rendering
- [ ] Relay tests cover fragmented delivery and multi-client ownership
- [ ] Existing attach/input/cpu-fix regressions remain green
