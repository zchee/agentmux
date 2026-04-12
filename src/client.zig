const std = @import("std");
const protocol = @import("protocol.zig");
const control = @import("control/control.zig");
const log = @import("core/log.zig");
const client_terminal = @import("client_terminal.zig");
const startup_probe = @import("startup_probe.zig");

pub const CommandResult = struct {
    exit_code: u16,
    attached: bool = false,
};

const relay_quiescence_ns = 200 * std.time.ns_per_ms;
const relay_timeout_ns = 150 * std.time.ns_per_ms;
const relay_total_timeout_ns = std.time.ns_per_s;
const relay_first_probe_grace_ns = @max(relay_timeout_ns, relay_quiescence_ns);

pub fn commandStartsStartupRelay(args: []const []const u8, control_mode: bool) bool {
    if (control_mode or args.len == 0) return false;
    return std.mem.eql(u8, args[0], "new-session") or
        std.mem.eql(u8, args[0], "new") or
        std.mem.eql(u8, args[0], "attach-session") or
        std.mem.eql(u8, args[0], "attach");
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Client that connects to a zmux server.
pub const Client = struct {
    fd: std.c.fd_t,
    socket_path: []const u8,
    allocator: std.mem.Allocator,
    identify_flags: protocol.IdentifyFlags,
    control_sequence: u32,

    const PendingProbeRequest = struct {
        request_id: u32,
        kind: startup_probe.ProbeKind,
    };

    const StartupRelay = struct {
        started_at_ns: u64,
        last_probe_ns: u64,
        expected_requests: std.ArrayListAligned(PendingProbeRequest, null) = .empty,
        reply_capture: std.ArrayListAligned(u8, null) = .empty,
        buffered_user_input: std.ArrayListAligned(u8, null) = .empty,
        saw_probe_request: bool = false,
        active: bool = true,

        fn init() StartupRelay {
            const now = monotonicNs();
            return .{
                .started_at_ns = now,
                .last_probe_ns = now,
            };
        }

        fn deinit(self: *StartupRelay, alloc: std.mem.Allocator) void {
            self.expected_requests.deinit(alloc);
            self.reply_capture.deinit(alloc);
            self.buffered_user_input.deinit(alloc);
            self.* = undefined;
        }

        fn hasBufferedNewline(self: *const StartupRelay) bool {
            return std.mem.indexOfAny(u8, self.buffered_user_input.items, "\r\n") != null;
        }
    };

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) Client {
        return .{
            .fd = -1,
            .socket_path = socket_path,
            .allocator = alloc,
            .identify_flags = .{},
            .control_sequence = 0,
        };
    }

    /// Connect to the server.
    pub fn connect(self: *Client) !void {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        var addr: std.c.sockaddr.un = .{ .path = undefined };
        if (self.socket_path.len >= addr.path.len) return error.PathTooLong;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        const result = std.c.connect(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un));
        if (result != 0) {
            _ = std.c.close(fd);
            return error.ConnectFailed;
        }

        self.fd = fd;
        log.info("connected to server at {s}", .{self.socket_path});
    }

    /// Send identification message.
    pub fn identify(self: *Client, term_name: []const u8, cols: u16, rows: u16) !void {
        var msg = protocol.IdentifyMsg{
            .protocol_version = protocol.version,
            .pid = std.c.getpid(),
            .flags = self.identify_flags,
            .term_name = .{0} ** 64,
            .tty_name = .{0} ** 64,
            .cols = cols,
            .rows = rows,
            .xpixel = 0,
            .ypixel = 0,
        };

        const copy_len = @min(term_name.len, msg.term_name.len - 1);
        @memcpy(msg.term_name[0..copy_len], term_name[0..copy_len]);

        const bytes = std.mem.asBytes(&msg);
        protocol.sendMessage(self.fd, .identify, bytes) catch |err| {
            log.err("failed to send identify: {}", .{err});
            return err;
        };
    }

    /// Send a command string to the server.
    pub fn sendCommand(self: *Client, command: []const u8) !void {
        protocol.sendMessage(self.fd, .command, command) catch |err| {
            log.err("failed to send command: {}", .{err});
            return err;
        };
    }

    pub fn sendCommandArgs(self: *Client, args: []const []const u8) !void {
        const payload = try protocol.encodeCommandArgs(self.allocator, args);
        defer self.allocator.free(payload);

        protocol.sendMessage(self.fd, .command, payload) catch |err| {
            log.err("failed to send command args: {}", .{err});
            return err;
        };
    }

    fn nextControlNumber(self: *Client) u32 {
        self.control_sequence += 1;
        return self.control_sequence;
    }

    fn finishControlCommand(ctrl: *control.ControlClient, saw_error: bool, exit_code: u16, number: u32) void {
        if (saw_error or exit_code != 0) {
            ctrl.sendError(0, number, 0);
        } else {
            ctrl.sendEnd(0, number, 0);
        }
        ctrl.sendExit();
    }

    pub fn readCommandResult(self: *Client) !CommandResult {
        const use_control_mode = self.identify_flags.control_mode;
        const ctrl_number: u32 = if (use_control_mode) self.nextControlNumber() else 0;
        var saw_error = false;
        var ctrl = control.ControlClient.init(1);
        if (use_control_mode) {
            ctrl.sendBegin(0, ctrl_number, 0);
        }

        while (true) {
            var msg = try protocol.recvMessageAlloc(self.allocator, self.fd);
            defer msg.deinit();

            switch (msg.msg_type) {
                .output => {
                    if (msg.payload.len > 0) {
                        _ = std.c.write(1, msg.payload.ptr, msg.payload.len);
                    }
                },
                .error_msg => {
                    saw_error = true;
                    if (msg.payload.len > 0) {
                        const error_fd: std.c.fd_t = if (use_control_mode) 1 else 2;
                        _ = std.c.write(error_fd, msg.payload.ptr, msg.payload.len);
                    }
                },
                .exit_ack => {
                    if (use_control_mode) {
                        finishControlCommand(&ctrl, saw_error, msg.flags, ctrl_number);
                    }
                    return .{ .exit_code = msg.flags };
                },
                .ready => {
                    return .{ .exit_code = 0, .attached = true };
                },
                .version => {},
                else => {},
            }
        }
    }

    pub fn requestCommand(self: *Client, args: []const []const u8) !CommandResult {
        try self.sendCommandArgs(args);
        return self.readCommandResult();
    }

    /// Send a key event.
    pub fn sendKey(self: *Client, key: u64) !void {
        const msg = protocol.KeyMsg{
            .key = key,
            .mouse_x = 0,
            .mouse_y = 0,
            .mouse_button = 0,
            .mouse_flags = 0,
        };
        const bytes = std.mem.asBytes(&msg);
        protocol.sendMessage(self.fd, .key, bytes) catch |err| {
            log.err("failed to send key: {}", .{err});
            return err;
        };
    }

    /// Send resize notification.
    pub fn sendResize(self: *Client, cols: u16, rows: u16) !void {
        const msg = protocol.ResizeMsg{
            .cols = cols,
            .rows = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        const bytes = std.mem.asBytes(&msg);
        protocol.sendMessage(self.fd, .resize, bytes) catch |err| {
            log.err("failed to send resize: {}", .{err});
            return err;
        };
    }

    /// Send raw bytes as key input to the server.
    pub fn sendKeyRaw(self: *Client, data: []const u8) !void {
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "fd={d} bytes={d} newline={any}", .{ self.fd, data.len, std.mem.indexOfAny(u8, data, "\r\n") != null }) catch "";
        startup_probe.traceEvent("client", "send_key_raw_begin", msg);
        protocol.sendMessage(self.fd, .key, data) catch |err| {
            log.err("failed to send key data: {}", .{err});
            return err;
        };
        startup_probe.traceEvent("client", "send_key_raw_end", msg);
    }

    fn sendTerminalProbeReady(self: *Client) !void {
        startup_probe.traceEvent("client", "send_probe_ready", "");
        protocol.sendMessage(self.fd, .terminal_probe_ready, &.{}) catch |err| {
            log.err("failed to send terminal probe ready: {}", .{err});
            return err;
        };
    }

    fn sendTerminalProbeRsp(
        self: *Client,
        request_id: u32,
        status: startup_probe.ResponseStatus,
        reply_bytes: []const u8,
    ) !void {
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "fd={d} id={d} status={s} bytes={d}", .{ self.fd, request_id, @tagName(status), reply_bytes.len }) catch "";
        startup_probe.traceEvent("client", "send_probe_rsp_begin", msg);
        const payload = try protocol.encodeTerminalProbeRsp(self.allocator, request_id, status, reply_bytes);
        defer self.allocator.free(payload);

        protocol.sendMessage(self.fd, .terminal_probe_rsp, payload) catch |err| {
            log.err("failed to send terminal probe response: {}", .{err});
            return err;
        };
        startup_probe.traceEvent("client", "send_probe_rsp_end", msg);
    }

    fn queueStartupProbe(self: *Client, relay: *StartupRelay, view: protocol.TerminalProbeReqView) !void {
        try relay.expected_requests.append(self.allocator, .{
            .request_id = view.request_id,
            .kind = view.probe_kind,
        });
        relay.saw_probe_request = true;
        relay.last_probe_ns = monotonicNs();
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "fd={d} id={d} kind={s} queued={d}", .{ self.fd, view.request_id, @tagName(view.probe_kind), relay.expected_requests.items.len }) catch "";
        startup_probe.traceEvent("client", "queue_probe_req", msg);
        const request = startup_probe.requestBytes(view.probe_kind);
        const request_detail = std.fmt.bufPrint(&detail, "fd={d} id={d} kind={s} bytes={d}", .{ self.fd, view.request_id, @tagName(view.probe_kind), request.len }) catch "";
        startup_probe.traceEvent("client", "write_probe_request_to_terminal", request_detail);
        _ = std.c.write(1, request.ptr, request.len);
    }

    fn flushBufferedUserInput(self: *Client, relay: *StartupRelay) !void {
        if (relay.buffered_user_input.items.len == 0) return;
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "bytes={d}", .{relay.buffered_user_input.items.len}) catch "";
        startup_probe.traceEvent("client", "flush_buffered_user_input", msg);
        try self.sendKeyRaw(relay.buffered_user_input.items);
        relay.buffered_user_input.clearRetainingCapacity();
    }

    fn finishStartupRelay(self: *Client, relay: *StartupRelay) !void {
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "remaining_expected={d} buffered={d}", .{ relay.expected_requests.items.len, relay.buffered_user_input.items.len }) catch "";
        startup_probe.traceEvent("client", "finish_relay", msg);
        try self.flushBufferedUserInput(relay);
        relay.reply_capture.clearRetainingCapacity();
        relay.active = false;
    }

    fn timeoutOutstandingProbes(self: *Client, relay: *StartupRelay) !void {
        while (relay.expected_requests.items.len > 0) {
            const request = relay.expected_requests.orderedRemove(0);
            var detail: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&detail, "id={d} kind={s}", .{ request.request_id, @tagName(request.kind) }) catch "";
            startup_probe.traceEvent("client", "timeout_probe", msg);
            try self.sendTerminalProbeRsp(request.request_id, .timeout, &.{});
        }
        relay.reply_capture.clearRetainingCapacity();
    }

    fn matchingExpectedRequestIndex(relay: *const StartupRelay) ?usize {
        for (relay.expected_requests.items, 0..) |request, idx| {
            switch (startup_probe.classifyReply(request.kind, relay.reply_capture.items)) {
                .complete => return idx,
                .need_more => return null,
                .invalid => {},
            }
        }
        return null;
    }

    fn maybeFinishStartupRelay(self: *Client, relay: *StartupRelay, now_ns: u64) !void {
        if (!relay.active) return;
        if (now_ns - relay.started_at_ns >= relay_total_timeout_ns) {
            try self.timeoutOutstandingProbes(relay);
            try self.finishStartupRelay(relay);
            return;
        }
        if (relay.expected_requests.items.len != 0 or relay.reply_capture.items.len != 0) return;
        if (!relay.saw_probe_request and now_ns - relay.started_at_ns < relay_first_probe_grace_ns) return;

        if (relay.hasBufferedNewline()) {
            try self.finishStartupRelay(relay);
            return;
        }
        if (now_ns - relay.last_probe_ns >= relay_quiescence_ns) {
            try self.finishStartupRelay(relay);
        }
    }

    fn routeStartupInput(self: *Client, relay: *StartupRelay, data: []const u8) !void {
        var index: usize = 0;
        while (index < data.len) : (index += 1) {
            if (!relay.active) {
                try self.sendKeyRaw(data[index..]);
                return;
            }

            if (relay.expected_requests.items.len == 0 and relay.reply_capture.items.len == 0) {
                try relay.buffered_user_input.appendSlice(self.allocator, data[index..]);
                relay.last_probe_ns = monotonicNs();
                return;
            }

            if (relay.reply_capture.items.len == 0 and data[index] != 0x1b) {
                try relay.buffered_user_input.append(self.allocator, data[index]);
                continue;
            }

            try relay.reply_capture.append(self.allocator, data[index]);
            if (matchingExpectedRequestIndex(relay)) |request_idx| {
                const request = relay.expected_requests.orderedRemove(request_idx);
                var detail: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&detail, "id={d} kind={s} bytes={d}", .{ request.request_id, @tagName(request.kind), relay.reply_capture.items.len }) catch "";
                startup_probe.traceEvent("client", "matched_probe_reply", msg);
                try self.sendTerminalProbeRsp(request.request_id, .complete, relay.reply_capture.items);
                relay.reply_capture.clearRetainingCapacity();
                relay.last_probe_ns = monotonicNs();
                continue;
            }

            var needs_more = false;
            for (relay.expected_requests.items) |request| {
                if (startup_probe.classifyReply(request.kind, relay.reply_capture.items) == .need_more) {
                    needs_more = true;
                    break;
                }
            }
            if (!needs_more) {
                var detail: [160]u8 = undefined;
                const msg = std.fmt.bufPrint(&detail, "bytes={d}", .{relay.reply_capture.items.len}) catch "";
                startup_probe.traceEvent("client", "classify_non_probe_bytes", msg);
                try relay.buffered_user_input.appendSlice(self.allocator, relay.reply_capture.items);
                relay.reply_capture.clearRetainingCapacity();
            }
        }
    }

    fn startupRelayPollTimeout(relay: *const StartupRelay) c_int {
        if (!relay.active) return -1;

        const now_ns = monotonicNs();
        var next_deadline = relay.started_at_ns + relay_total_timeout_ns;
        if (relay.expected_requests.items.len == 0 and relay.reply_capture.items.len == 0) {
            if (!relay.saw_probe_request) {
                const first_probe_deadline = relay.started_at_ns + relay_first_probe_grace_ns;
                if (first_probe_deadline < next_deadline) next_deadline = first_probe_deadline;
            } else {
                const quiescence_deadline = relay.last_probe_ns + relay_quiescence_ns;
                if (quiescence_deadline < next_deadline) next_deadline = quiescence_deadline;
            }
        }

        if (next_deadline <= now_ns) return 0;
        const remaining_ns = next_deadline - now_ns;
        const remaining_ms = remaining_ns / std.time.ns_per_ms;
        return @intCast(@min(remaining_ms, @as(u64, @intCast(std.math.maxInt(c_int)))));
    }

    /// Run an interactive session loop: relay stdin to server, server output to stdout.
    /// Returns when the server sends detach, shutdown, or the connection drops.
    pub fn interactiveLoop(self: *Client, existing_raw: ?*client_terminal.RawTerminal) !void {
        // Get actual terminal size and notify server.
        if (client_terminal.getTerminalSize(0)) |size| {
            self.sendResize(size.cols, size.rows) catch {};
        }

        var owned_raw: ?client_terminal.RawTerminal = null;
        var raw_ptr: *client_terminal.RawTerminal = undefined;
        if (existing_raw) |raw| {
            raw_ptr = raw;
        } else {
            owned_raw = client_terminal.RawTerminal.init(0) catch return;
            raw_ptr = &owned_raw.?;
            raw_ptr.enableRaw() catch return;
        }
        defer raw_ptr.restore();

        var relay = StartupRelay.init();
        defer relay.deinit(self.allocator);
        self.sendTerminalProbeReady() catch {
            relay.active = false;
        };

        const POLLIN: i16 = 0x0001;
        var pollfds = [_]std.c.pollfd{
            .{ .fd = 0, .events = POLLIN, .revents = 0 },
            .{ .fd = self.fd, .events = POLLIN, .revents = 0 },
        };

        while (true) {
            const ret = std.c.poll(&pollfds, pollfds.len, startupRelayPollTimeout(&relay));
            if (ret < 0) break;

            const now_ns = monotonicNs();
            if (now_ns - relay.started_at_ns >= relay_total_timeout_ns) {
                self.timeoutOutstandingProbes(&relay) catch break;
                self.finishStartupRelay(&relay) catch break;
            }

            // Server readable: handle messages.
            if (pollfds[1].revents & POLLIN != 0) {
                var msg = protocol.recvMessageAlloc(self.allocator, self.fd) catch break;
                defer msg.deinit();

                switch (msg.msg_type) {
                    .output => {
                        if (msg.payload.len > 0) {
                            _ = std.c.write(1, msg.payload.ptr, msg.payload.len);
                        }
                    },
                    .terminal_probe_req => {
                        if (!relay.active) continue;
                        const view = protocol.decodeTerminalProbeReq(msg.payload) catch continue;
                        self.queueStartupProbe(&relay, view) catch break;
                    },
                    .detach, .shutdown, .exit_ack => break,
                    else => {},
                }
            }

            // stdin readable: forward to server as key data.
            if (pollfds[0].revents & POLLIN != 0) {
                var buf: [4096]u8 = undefined;
                const n = std.c.read(0, &buf, buf.len);
                if (n <= 0) break;
                if (relay.active) {
                    self.routeStartupInput(&relay, buf[0..@intCast(n)]) catch break;
                } else {
                    self.sendKeyRaw(buf[0..@intCast(n)]) catch break;
                }
            }

            self.maybeFinishStartupRelay(&relay, monotonicNs()) catch break;
        }
    }

    /// Disconnect from the server.
    pub fn disconnect(self: *Client) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }

    /// Check if connected.
    pub fn isConnected(self: *const Client) bool {
        return self.fd >= 0;
    }
};

test "identify sends configured client flags" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = fds[1];
    client.identify_flags = .{
        .utf8 = true,
        .control_mode = true,
        .terminal_256 = true,
    };

    try client.identify("xterm-256color", 120, 40);
    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();

    try std.testing.expectEqual(protocol.MessageType.identify, msg.msg_type);
    try std.testing.expect(msg.payload.len >= @sizeOf(protocol.IdentifyMsg));

    const identify: *const protocol.IdentifyMsg = @ptrCast(@alignCast(msg.payload.ptr));
    try std.testing.expect(identify.flags.utf8);
    try std.testing.expect(identify.flags.control_mode);
    try std.testing.expect(identify.flags.terminal_256);
    try std.testing.expectEqual(@as(u16, 120), identify.cols);
    try std.testing.expectEqual(@as(u16, 40), identify.rows);
}

test "control mode wraps command output with tmux-like guards" {
    var server_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&server_pipe));
    defer _ = std.c.close(server_pipe[0]);
    defer _ = std.c.close(server_pipe[1]);

    var stdout_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&stdout_pipe));
    defer _ = std.c.close(stdout_pipe[0]);
    defer _ = std.c.close(stdout_pipe[1]);

    const saved_stdout = std.c.dup(1);
    try std.testing.expect(saved_stdout >= 0);
    defer {
        _ = std.c.dup2(saved_stdout, 1);
        _ = std.c.close(saved_stdout);
    }
    try std.testing.expectEqual(@as(i32, 1), std.c.dup2(stdout_pipe[1], 1));

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = server_pipe[0];
    client.identify_flags.control_mode = true;

    try protocol.sendMessage(server_pipe[1], .output, "demo: 1 windows\n");
    try protocol.sendMessageWithFlags(server_pipe[1], .exit_ack, 0, &.{});

    const result = try client.readCommandResult();
    try std.testing.expectEqual(@as(u16, 0), result.exit_code);
    try std.testing.expect(!result.attached);

    _ = std.c.close(stdout_pipe[1]);
    var buf: [512]u8 = undefined;
    const n = std.c.read(stdout_pipe[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    const output = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, output, "%begin ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "demo: 1 windows\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "%end ") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "%exit\n") != null);
}

test "commandStartsStartupRelay detects attach-capable commands only in normal mode" {
    try std.testing.expect(commandStartsStartupRelay(&.{"new-session"}, false));
    try std.testing.expect(commandStartsStartupRelay(&.{"attach-session"}, false));
    try std.testing.expect(!commandStartsStartupRelay(&.{"list-sessions"}, false));
    try std.testing.expect(!commandStartsStartupRelay(&.{"new-session"}, true));
}

test "startup relay classifies probe replies separately from buffered user input" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = fds[1];

    var relay = Client.StartupRelay.init();
    defer relay.deinit(std.testing.allocator);
    relay.saw_probe_request = true;
    try relay.expected_requests.append(std.testing.allocator, .{
        .request_id = 7,
        .kind = .osc_10,
    });

    try client.routeStartupInput(&relay, "ls\x1b]10;rgb:0000/0000/0000\x1b\\\r");
    try client.maybeFinishStartupRelay(&relay, monotonicNs());

    try std.testing.expectEqualStrings("", relay.buffered_user_input.items);
    try std.testing.expectEqual(@as(usize, 0), relay.expected_requests.items.len);
    try std.testing.expect(!relay.active);

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.terminal_probe_rsp, msg.msg_type);
    const rsp = try protocol.decodeTerminalProbeRsp(msg.payload);
    try std.testing.expectEqual(@as(u32, 7), rsp.request_id);
    try std.testing.expectEqual(startup_probe.ResponseStatus.complete, rsp.status);
    try std.testing.expectEqualStrings("\x1b]10;rgb:0000/0000/0000\x1b\\", rsp.reply_bytes);

    var key_msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer key_msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.key, key_msg.msg_type);
    try std.testing.expectEqualStrings("ls\r", key_msg.payload);
}

test "startup relay flushes buffered user input when the first command is complete" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = fds[1];

    var relay = Client.StartupRelay.init();
    defer relay.deinit(std.testing.allocator);
    relay.saw_probe_request = true;
    try relay.buffered_user_input.appendSlice(std.testing.allocator, "echo hi\r");
    relay.last_probe_ns = monotonicNs() - relay_quiescence_ns;

    try client.maybeFinishStartupRelay(&relay, monotonicNs());

    try std.testing.expect(!relay.active);
    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.key, msg.msg_type);
    try std.testing.expectEqualStrings("echo hi\r", msg.payload);
}

test "startup relay flushes newly typed input immediately once no probe replies remain" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = fds[1];

    var relay = Client.StartupRelay.init();
    defer relay.deinit(std.testing.allocator);
    relay.saw_probe_request = true;
    relay.last_probe_ns = monotonicNs();

    try client.routeStartupInput(&relay, "echo hi\r");
    try client.maybeFinishStartupRelay(&relay, monotonicNs());

    try std.testing.expect(!relay.active);
    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.key, msg.msg_type);
    try std.testing.expectEqualStrings("echo hi\r", msg.payload);
}

test "startup relay keeps buffered newline until first-probe grace elapses" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    const flags = std.c.fcntl(fds[0], std.c.F.GETFL);
    try std.testing.expect(flags >= 0);
    try std.testing.expectEqual(@as(i32, 0), std.c.fcntl(fds[0], std.c.F.SETFL, flags | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true }))));

    var client = Client.init(std.testing.allocator, "/tmp/unused.sock");
    client.fd = fds[1];

    var relay = Client.StartupRelay.init();
    defer relay.deinit(std.testing.allocator);
    relay.last_probe_ns = monotonicNs();
    var recv_state: protocol.RecvState = .{};
    defer recv_state.deinit(std.testing.allocator);

    try client.routeStartupInput(&relay, "echo hi\r");
    try client.maybeFinishStartupRelay(&relay, monotonicNs());

    try std.testing.expect(relay.active);
    try std.testing.expectEqualStrings("echo hi\r", relay.buffered_user_input.items);
    try std.testing.expectError(error.WouldBlock, protocol.recvMessageAllocNonblocking(std.testing.allocator, fds[0], &recv_state));

    relay.started_at_ns = monotonicNs() - relay_first_probe_grace_ns;
    try client.maybeFinishStartupRelay(&relay, monotonicNs());

    try std.testing.expect(!relay.active);
    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.key, msg.msg_type);
    try std.testing.expectEqualStrings("echo hi\r", msg.payload);
}

test "startup relay poll timeout prefers first-probe grace before first request" {
    var relay = Client.StartupRelay.init();
    defer relay.deinit(std.testing.allocator);

    relay.started_at_ns = monotonicNs() - (relay_first_probe_grace_ns - 10 * std.time.ns_per_ms);
    relay.last_probe_ns = monotonicNs();

    const timeout_ms = Client.startupRelayPollTimeout(&relay);
    try std.testing.expect(timeout_ms >= 0);
    try std.testing.expect(timeout_ms <= 25);
}
