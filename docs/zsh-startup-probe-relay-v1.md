# zsh startup probe relay v1: implementation and review notes

This note turns the consensus plan in `.omx/plans/zsh-startup-probe-response-consensus.md`
into a code-facing reference for the implementation/review lanes. It intentionally
focuses on the narrow v1 slice: startup-only relay, explicit wire messages,
stable per-client ownership, and regression coverage that preserves the recent
input/cpu fixes already landed on `main`.

## Why this note exists

The current attach path already improved early keystroke handling, but the real
startup bottleneck remains the child `zsh` waiting in `probe_terminal`. The code
paths that matter today are:

- `src/main.zig` — `runCommandMode()` still uses `requestCommand()` and only
  enters `interactiveLoop()` after `.ready`.
- `src/client.zig` — command mode and interactive mode are currently separate,
  and stdin bytes are treated as ordinary pane input once the interactive loop
  starts.
- `src/server.zig` — `handleCommand()`, `setClientSession()`,
  `handleClientKey()`, and `handlePtyReadable()` still have no first-class
  startup probe bridge.
- `src/protocol.zig` — message framing is generic, but there are no relay
  message types or payload structs yet.

## Review findings that should shape the implementation

1. **Client array indexes are not stable identities.**
   `Server.removeClient()` uses `orderedRemove`, so any startup relay ownership
   must use a separate `client_id`, not `client_idx`.

2. **The `.ready` boundary is now user-visible and correctness-sensitive.**
   `main.zig`/`client.zig`/`server.zig` were recently changed so raw-mode entry
   and early-keystroke survival depend on `.ready` arriving promptly. The relay
   work must not reintroduce a blocking pre-ready drain step.

3. **`handleClientKey()` cannot remain the first classifier during relay.**
   Today it assumes incoming stdin bytes are either prefix/mouse/pane input.
   During startup relay, probe replies have to be recognized before prefix
   handling or PTY passthrough.

4. **Probe interception must happen before ordinary render/broadcast.**
   `handlePtyReadable()` currently feeds bytes through `PaneState.processPtyOutput`
   and then renders to all attached clients. Startup probes need to be detected
   before those bytes are treated as ordinary pane output, otherwise the shell's
   request bytes will leak into the composed terminal path and the pane will not
   receive correlated replies.

5. **The implementation should extend the existing nonblocking framing model,
   not create an unrelated side channel.**
   `protocol.recvMessageAllocNonblocking()` already handles fragmented message
   delivery. The relay messages should reuse that framing and add regression
   coverage for fragmented request/reply delivery.

## v1 protocol surface

Add these explicit message types to `src/protocol.zig`:

- `terminal_probe_ready`
- `terminal_probe_req`
- `terminal_probe_rsp`

Recommended payload shapes for the wire structs:

```zig
pub const ProbeKind = enum(u16) {
    osc_10,
    osc_11,
    osc_12,
    csi_primary_da,
    csi_secondary_query,
};

pub const ProbeResponseStatus = enum(u8) {
    complete,
    timeout,
    unsupported,
};

pub const TerminalProbeReqMsg = extern struct {
    request_id: u32 align(1),
    owner_client_id: u64 align(1),
    probe_kind: ProbeKind align(1),
    payload_len: u32 align(1),
};

pub const TerminalProbeRspMsg = extern struct {
    request_id: u32 align(1),
    status: ProbeResponseStatus align(1),
    _padding: [3]u8 align(1) = .{0} ** 3,
    payload_len: u32 align(1),
};
```

Notes:

- Keep raw probe/request bytes as a payload slice after the fixed header rather
  than baking variable-length arrays into the struct.
- `terminal_probe_ready` can remain payload-free for v1 if ownership is already
  known from the accepted connection.
- Keep `request_id` server-assigned and monotonic per owner/relay window.

## Startup relay lifecycle (v1)

### Server-side states

- `inactive`
- `relay_startup_pending`
- `relay_startup_active`
- `relay_done`

### Client-side states

- `command_wait`
- `startup_prearm`
- `startup_relay`
- `interactive`

### Entry and exit rules

Enter relay only when all of the following are true:

1. the command is attach-capable (`new-session`, `new`, `attach-session`,
   `attach`)
2. the server bound the client to a session
3. that same client is the attach owner for the request
4. the client has sent `terminal_probe_ready`

Close relay when any of the following occurs:

1. there are no in-flight requests and 200ms of probe quiescence has elapsed
2. 1s total relay timeout has elapsed since attach
3. the first newline-terminated user command flush has been written to the pane

## Startup relay integration points

### `src/protocol.zig`

- add the three relay message types
- add request/response payload structs and encode/decode helpers
- add framing tests for full and fragmented delivery

### `src/client.zig`

- split `readCommandResult()`/`interactiveLoop()` into explicit attach-aware
  stages instead of treating `.ready` as a jump straight into ordinary stdin
  passthrough
- while in `startup_relay`, classify stdin bytes in this order:
  1. active probe reply matcher
  2. buffered user input
  3. flush buffered input on relay exit
- preserve the recent raw-mode behavior from `src/client_terminal.zig`
  (`TCSANOW`, not `TCSAFLUSH`)

### `src/server.zig`

- extend `ClientConnection` with a stable `client_id`
- keep attach ownership separate from the clients array position
- gate probe requests to the attach-owning client only
- detect probe requests in PTY output before ordinary render/broadcast
- inject `terminal_probe_rsp` bytes back through the pane input path without
  regressing pending-write handling

## v1 supported probe catalog

Only support the probe families backed by the locally captured startup traffic:

| Kind | Request bytes | Expected reply family |
| --- | --- | --- |
| OSC 10 | `ESC ] 10 ; ? ESC \\` | OSC 10 reply terminated by ST or BEL |
| OSC 11 | `ESC ] 11 ; ? ESC \\` | OSC 11 reply terminated by ST or BEL |
| OSC 12 | `ESC ] 12 ; ? ESC \\` | OSC 12 reply terminated by ST or BEL |
| Primary DA | `ESC [ c` | `CSI ? ... c` |
| Secondary/version query | `ESC [ > 0 q` | matching CSI reply family |

Explicitly defer for follow-up work:

- kitty keyboard capability queries
- xterm modifyOtherKeys capability queries
- steady-state general terminal query relay

## Regression surfaces to protect

These paths are already sensitive and should remain green while the relay work
lands:

- early keystrokes typed during session attach must still survive
- pending pane writes must not reintroduce the dead-pane CPU spin fixed on main
- non-owning attached clients must remain passive viewers during startup relay
- composed render output must remain correct after relay completion

## Verification checklist

Minimum repo verification:

- `zig build test`
- `zig build`
- `zig fmt --check <touched-files>`
- `git diff --check`

Focused behavioral checks:

- protocol framing tests for `terminal_probe_ready`, `terminal_probe_req`, and
  `terminal_probe_rsp`
- attach-path regression proving the client can still type immediately after
  attach
- startup relay tests proving buffered user input flush order is preserved
- multi-client ownership test proving only the attach owner services probes

Validation evidence to capture before final integration:

- minimal-home prompt timing (direct `zsh -i` vs `zmux new -s test`)
- real-home immediate-command acceptance (target: at least 4/5 runs under 2s
  mean / 3s max)
- child `zsh` sample output showing `probe_terminal` is no longer the dominant
  prolonged wait

## Documentation recommendation for the merge commit

When the feature is ready to merge, prefer updating the user-facing README only
after the code lands and the validation evidence exists. Until then, treat this
note as the developer-facing source of truth for the startup relay shape and the
review guardrails above.
