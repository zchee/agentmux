# Audit: worker-4 startup relay checkpoint `637f06a`

This note records the first concrete code-review pass against the evolving
startup-only zsh probe/response relay implementation checkpoint in
`worker-4` (`637f06aee1f858d16a8535ad4f185fed332724a9`).

Scope: exact blocker evidence, concrete protocol/query contract observations,
and verification results only.

## Verified commands

- `zig test src/protocol.zig` in `worker-4` — PASS
- `git diff --check` in `worker-4` — PASS
- `zig build test` in `worker-4` — FAIL
- `zig build` in `worker-4` — FAIL
- `zig fmt --check src/protocol.zig src/client.zig src/server.zig src/main.zig` in `worker-4` — PASS

## Concrete protocol/query contracts observed

The checkpoint wires the explicit relay message family in `src/protocol.zig`:

- `terminal_probe_ready`
- `terminal_probe_req`
- `terminal_probe_rsp`

It also defines a v1 probe catalog with request-byte helpers for:

- foreground color (`OSC 10`)
- background color (`OSC 11`)
- cursor color (`OSC 12`)
- primary device attributes (`CSI c`)
- terminal version / secondary query (`CSI > 0 q`)

This matches the current docs-only contract captured in:

- `docs/zsh-startup-probe-relay-v1.md`
- `docs/zsh-startup-probe-test-matrix.md`

## Exact blockers

### 1. `std.time.nanoTimestamp()` does not exist in this Zig toolchain

Build/test both fail on the same API usage:

- `worker-4/src/client.zig:45`
- `worker-4/src/server.zig:1004`

Observed error:

```text
error: root source file struct 'time' has no member named 'nanoTimestamp'
```

Impact:

- breaks `zig build`
- breaks `zig build test`
- blocks all runtime validation of the relay implementation

### 2. `handleProbeRequest` has an unused `self` parameter

- `worker-4/src/client.zig:318`

Observed error:

```text
error: unused function parameter
```

Impact:

- breaks `zig build`
- breaks `zig build test`

### 3. `detectStartupProbeMatch` returns an incompatible anonymous struct type

- `worker-4/src/server.zig:1025-1034`

Observed error at return site:

- `worker-4/src/server.zig:1029`

Observed error:

```text
error: expected type '?server.Server.detectStartupProbeMatch__struct_...', found '?server.Server.detectStartupProbeMatch__struct_...'
```

Impact:

- breaks `zig build`
- breaks `zig build test`

### 4. Test fixtures were not updated for the new required `client_id` field

Representative failing anchors:

- `worker-4/src/cmd/display_commands_test.zig:267`
- `worker-4/src/server.zig:2535`
- `worker-4/src/server.zig:2730`
- `worker-4/src/server.zig:2759`
- `worker-4/src/server.zig:2793`
- `worker-4/src/server.zig:2880`
- `worker-4/src/server.zig:2938`
- `worker-4/src/server.zig:2981`
- `worker-4/src/server.zig:3040`
- `worker-4/src/server.zig:3081`
- `worker-4/src/server.zig:3141`
- `worker-4/src/server.zig:3183`

Observed error shape:

```text
error: missing struct field: client_id
```

Impact:

- breaks `zig build test`
- confirms the stable-identity migration is not fully propagated through the
  regression surface yet

## Additional review findings from source inspection

### 5. `handleClientReadable()` still does not dispatch the new relay messages

Current switch anchor:

- `worker-4/src/server.zig:1227-1231`

Observed cases handled there:

- `.identify`
- `.command`
- `.key`
- `.resize`
- `.exit`, `.exiting`
- `.shell`

Missing dispatch cases:

- `.terminal_probe_ready`
- `.terminal_probe_rsp`

This is a functional blocker even after the compile errors are fixed, because
`handleTerminalProbeReady()` and `handleTerminalProbeResponse()` exist in the
same file but are not reachable from the client message pump.

### 6. Protocol coverage still lacks explicit `terminal_probe_ready` framing tests

Current protocol additions in `worker-4/src/protocol.zig:508-548` cover:

- request payload roundtrip
- response payload roundtrip
- request message roundtrip through pipe

Still missing from the current checkpoint relative to the docs/test matrix:

- explicit `terminal_probe_ready` message framing test
- fragmented nonblocking delivery coverage for the new relay messages

## Review summary

The checkpoint is moving in the right architectural direction:

- stable `client_id` is present
- explicit relay message types exist
- attach-capable command prearm is wired in `src/main.zig`
- startup relay state appears on both client and server sides

But it is not yet integration-ready because the first full verification pass is
red on both compile and test, and there is at least one confirmed functional
wiring hole (`handleClientReadable()` missing the new relay message dispatch).

## Addendum: latest worker-4 and integrated-branch evidence

### Latest worker-4 checkpoint observed

Latest worker-4 checkpoint at audit time:

- `dc2faf43e3d7d068e3aa13771f24c0609802b640`

Updated targeted verification against that lane:

- `zig build` in `worker-4` — PASS
- `zig test src/server.zig --test-filter "handleClientReadable attaches a new session without fixed startup delay"` — PASS
- `zig test src/server.zig --test-filter "createSession drains startup output so pane accepts input"` — PASS
- `zig test src/server.zig --test-filter "protocol identify then new-session then key input reaches shell"` — TIMEOUT in this audit lane
- `zig build test` in `worker-4` — TIMEOUT in this audit lane

This means the lane moved past the initial compile blockers, but at least one
critical attach/input regression test still appears to hang.

### Integrated branch duplication/conflict evidence

The leader branch at `/Users/zchee/src/github.com/zchee/zmux` is currently red.
Both `zig build` and `zig build test` fail immediately with duplicate-definition
errors caused by conflicting relay implementations being present at once.

Exact duplicate-definition anchors observed:

1. Duplicate import in `src/client.zig`
   - `src/client.zig:4`
   - `src/client.zig:6`

2. Duplicate `next_client_id` field in `src/server.zig`
   - `src/server.zig:74`
   - `src/server.zig:76`

3. Duplicate `queueStartupProbeRequest` implementations in `src/server.zig`
   - `src/server.zig:1149`
   - `src/server.zig:1846`

4. Duplicate `handleTerminalProbeReady` implementations in `src/server.zig`
   - `src/server.zig:1228`
   - `src/server.zig:1430`

The integrated branch also shows mixed naming from two relay implementations in
the same file set, for example:

- one path uses `TerminalProbeKind` / `handleTerminalProbeResponse`
- another path uses `startup_probe.ProbeKind` / `handleTerminalProbeRsp`

This is consistent with a partial reconciliation merge rather than a single
coherent implementation path.

## Addendum: worker-2 green lane vs integrated red branch

A later audit pass found that the active implementation/test lane in `worker-2`
is materially healthier than the currently integrated `main` branch.

### worker-2 evidence

Observed worker-2 checkpoint during this pass:

- `4f057cd`

Verification run in `worker-2`:

- `zig build test` — PASS
- `zig build` — PASS
- `git diff --check` — PASS
- `zig test src/server.zig --test-filter "protocol identify then new-session then key input reaches shell"` — PASS

Coverage evidence observed in source:

- `src/protocol.zig` has fragmented request and response frame tests
  - request: `src/protocol.zig:483`
  - response: `src/protocol.zig:523`
- `src/server.zig` has fragmented `terminal_probe_ready` dispatch coverage
  - `src/server.zig:3267`
- attach/input regressions remain present in the worker-2 test surface
  - `src/server.zig:2798`
  - `src/server.zig:3054`
  - `src/server.zig:3121`

### Remaining gap relative to the docs/test matrix

Even in the green worker-2 lane, the explicit `terminal_probe_ready` framing
coverage currently lives at the server/message-pump layer rather than as a
separate protocol-layer roundtrip/nonblocking test in `src/protocol.zig`.
That is now a coverage note rather than a build blocker.

### Integration conclusion

The current leader branch failure is not because the startup relay design is
universally red. The evidence now points to a reconciliation problem:

- worker-2 lane is green on build/test
- integrated `main` remains red due to duplicate relay definitions

That makes the present blocker primarily an integration/conflict issue, not a
fundamental proof-of-concept failure of the relay approach.

## Addendum: integrated branch regressed further after worker-4 reconciliation

A later reconciliation pass advanced the integrated branch to:

- `/Users/zchee/src/github.com/zchee/zmux` HEAD `2780665`

But the branch is still red, and the blocker set has expanded beyond the earlier
server-side duplicate definitions.

### Current integrated verification

- `cd /Users/zchee/src/github.com/zchee/zmux && zig build` — FAIL
- `cd /Users/zchee/src/github.com/zchee/zmux && zig build test` — FAIL

### New concrete blocker evidence

#### Client-side duplication / drift

1. `StartupRelayState` references an undeclared type:
   - `src/client.zig:29` — `StartupRelayPhase` undeclared

2. Duplicate helper definitions now exist inside `Client`:
   - `src/client.zig:270` and `src/client.zig:532` — `sendTerminalProbeReady`
   - `src/client.zig:285` and `src/client.zig:562` — `flushBufferedUserInput`
   - `src/client.zig:300` and `src/client.zig:568` — `finishStartupRelay`
   - `src/client.zig:310` and `src/client.zig:602` — `maybeFinishStartupRelay`

3. Tests still reference the missing enum:
   - `src/client.zig:870`
   - `src/client.zig:895`

This shows the client file now contains overlapping relay implementations rather
than a single reconciled path.

#### Server-side duplication remains

- `src/server.zig:108` and `src/server.zig:110` — duplicate `next_client_id`
- `src/server.zig:1217` and `src/server.zig:1916` — duplicate `queueStartupProbeRequest`
- `src/server.zig:1296` and `src/server.zig:1500` — duplicate `handleTerminalProbeReady`

#### Protocol/toolchain incompatibility

The integrated protocol layer also now fails on enum decoding helpers that are
not available in the current Zig toolchain:

- `src/protocol.zig:373` — `std.meta.intToEnum(TerminalProbeKind, ...)`
- `src/protocol.zig:398` — `std.meta.intToEnum(TerminalProbeStatus, ...)`

Observed error shape:

```text
error: root source file struct 'meta' has no member named 'intToEnum'
```

### Interpretation

The integration problem is now broader than the earlier server-only duplicate
merge. The current `main` branch contains:

- two competing client-side relay implementations
- two competing server-side relay implementations
- a protocol implementation using helpers incompatible with the local Zig toolchain

That means the branch is not yet at the "pick one implementation and clean up a
few duplicate functions" stage; it still needs a more deliberate reconciliation
pass across client, server, and protocol layers.

## Addendum: integrated head `f3d0426` still red with expanded client test fallout

A subsequent reconciliation pass advanced integrated `main` again:

- `/Users/zchee/src/github.com/zchee/zmux` HEAD `f3d0426`

The branch still does not build.

### Current integrated verification

- `zig build` — FAIL
- `zig build test` — FAIL

### Updated concrete blocker deltas

Relative to the prior pass, the main new evidence is that the missing
`StartupRelayPhase` leak is now also visible in an additional client test:

- `src/client.zig:942`

So the missing/overlapping client-side relay state now blocks:

- `src/client.zig:29`
- `src/client.zig:870`
- `src/client.zig:895`
- `src/client.zig:942`

The previously captured duplicate client helper definitions and duplicate
server relay definitions remain present, and `zig build test` still reports the
protocol/toolchain incompatibility at:

- `src/protocol.zig:373`
- `src/protocol.zig:398`

### Interpretation

This confirms the reconciliation is still moving the integrated branch forward
without restoring a single coherent client relay state machine. The blocker set
is not yet shrinking in a meaningful way; it is still drifting across multiple
client/server/protocol surfaces.

## Addendum: canonical worker-2 is green, integrated head `f8cec0e` is still diverging

Leader clarified that `worker-2` is now the canonical final implementation lane.
A fresh audit confirms the canonical-vs-integrated split remains stark.

### Canonical worker-2 evidence

Observed canonical worker-2 checkpoint:

- `e842054`

Verification in `worker-2`:

- `zig build test` — PASS
- `zig build` — PASS
- `git diff --check` — PASS

### Integrated main evidence

Observed integrated main checkpoint during this pass:

- `/Users/zchee/src/github.com/zchee/zmux` HEAD `f8cec0e`

Verification in integrated main:

- `zig build` — FAIL with 11 compile errors
- `zig build test` — FAIL with 16 compile errors

### Additional duplicate-definition drift now present in integrated main

Beyond the earlier duplicate helper set, the integrated branch now also contains
extra duplicated server lifecycle helpers:

- `src/server.zig:735` and `src/server.zig:1176` — duplicate `monotonicNowNs`
- `src/server.zig:764` and `src/server.zig:1577` — duplicate `beginClientStartupRelay`
- `src/server.zig:773` and `src/server.zig:1305` — duplicate `findStartupRelayOwnerIndex`
- `src/server.zig:1316` and `src/server.zig:2015` — duplicate `queueStartupProbeRequest`
- `src/server.zig:1395` and `src/server.zig:1599` — duplicate `handleTerminalProbeReady`

The integrated branch still also carries the client-side duplicate relay helper
set and the protocol toolchain incompatibility already recorded above.

### Root-cause direction

This further supports the same conclusion: integrated main is not converging
onto the canonical worker-2 result. It is continuing to accrete overlapping
relay implementations on top of one another, while the canonical worker-2 lane
remains green.

### Correction: current server duplicate helper anchors in integrated `f8cec0e`

A direct symbol grep on the integrated branch gives these current duplicate
server helper anchors:

- `src/server.zig:735` and `src/server.zig:1294` — duplicate `monotonicNowNs`
- `src/server.zig:764` and `src/server.zig:1695` — duplicate `beginClientStartupRelay`
- `src/server.zig:773` and `src/server.zig:1423` — duplicate `findStartupRelayOwnerIndex`
- `src/server.zig:1434` and `src/server.zig:2133` — duplicate `queueStartupProbeRequest`
- `src/server.zig:1513` and `src/server.zig:1717` — duplicate `handleTerminalProbeReady`

These are the symbol-level anchors that currently match the red integrated tree.
