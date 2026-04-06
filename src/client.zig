const std = @import("std");
const protocol = @import("protocol.zig");
const control = @import("control/control.zig");
const log = @import("core/log.zig");

pub const CommandResult = struct {
    exit_code: u16,
    attached: bool = false,
};

/// Client that connects to a zmux server.
pub const Client = struct {
    fd: std.c.fd_t,
    socket_path: []const u8,
    allocator: std.mem.Allocator,
    identify_flags: protocol.IdentifyFlags,
    control_sequence: u32,

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
        protocol.sendMessage(self.fd, .key, data) catch |err| {
            log.err("failed to send key data: {}", .{err});
            return err;
        };
    }

    /// Run an interactive session loop: relay stdin to server, server output to stdout.
    /// Returns when the server sends detach, shutdown, or the connection drops.
    pub fn interactiveLoop(self: *Client) !void {
        const client_terminal = @import("client_terminal.zig");

        // Get actual terminal size and notify server.
        if (client_terminal.getTerminalSize(0)) |size| {
            self.sendResize(size.cols, size.rows) catch {};
        }

        // Enter raw mode.
        var raw = client_terminal.RawTerminal.init(0) catch return;
        raw.enableRaw() catch return;
        defer raw.restore();

        const POLLIN: i16 = 0x0001;
        var pollfds = [_]std.c.pollfd{
            .{ .fd = 0, .events = POLLIN, .revents = 0 },
            .{ .fd = self.fd, .events = POLLIN, .revents = 0 },
        };

        while (true) {
            const ret = std.c.poll(&pollfds, pollfds.len, -1);
            if (ret < 0) break;

            // stdin readable: forward to server as key data.
            if (pollfds[0].revents & POLLIN != 0) {
                var buf: [4096]u8 = undefined;
                const n = std.c.read(0, &buf, buf.len);
                if (n <= 0) break;
                self.sendKeyRaw(buf[0..@intCast(n)]) catch break;
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
                    .detach, .shutdown, .exit_ack => break,
                    else => {},
                }
            }
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
