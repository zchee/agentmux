const std = @import("std");
const protocol = @import("protocol.zig");
const log = @import("core/log.zig");

pub const CommandResult = struct {
    exit_code: u16,
};

/// Client that connects to an agentmux server.
pub const Client = struct {
    fd: std.c.fd_t,
    socket_path: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) Client {
        return .{
            .fd = -1,
            .socket_path = socket_path,
            .allocator = alloc,
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
            .flags = .{},
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

    pub fn readCommandResult(self: *Client) !CommandResult {
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
                    if (msg.payload.len > 0) {
                        _ = std.c.write(2, msg.payload.ptr, msg.payload.len);
                    }
                },
                .exit_ack => {
                    return .{ .exit_code = msg.flags };
                },
                .ready, .version => {},
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
