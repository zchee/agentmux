const std = @import("std");
const startup_probe = @import("startup_probe.zig");

/// Protocol version. Incremented on breaking changes.
pub const version: u32 = 1;

/// Maximum message payload size.
pub const max_payload: usize = 65536;

/// Message types sent between client and server.
pub const MessageType = enum(u16) {
    // Client -> Server
    identify = 100,
    command = 101,
    resize = 102,
    key = 103,
    shell = 104,
    exit = 105,
    exiting = 106,
    terminal_probe_ready = 107,
    terminal_probe_rsp = 108,

    // Server -> Client
    version = 200,
    ready = 201,
    output = 202,
    pause = 203,
    detach = 204,
    shutdown = 205,
    error_msg = 206,
    exit_ack = 207,
    terminal_probe_req = 208,
};

/// Wire format header for all messages.
pub const Header = extern struct {
    msg_type: u16 align(1),
    payload_len: u32 align(1),
    flags: u16 align(1),
};

pub const Message = struct {
    msg_type: MessageType,
    flags: u16,
    payload: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.payload);
        self.* = undefined;
    }
};

pub const RecvState = struct {
    header_buf: [@sizeOf(Header)]u8 = [_]u8{0} ** @sizeOf(Header),
    header_len: usize = 0,
    header: ?Header = null,
    payload: ?[]u8 = null,
    payload_read: usize = 0,

    pub fn deinit(self: *RecvState, alloc: std.mem.Allocator) void {
        self.reset(alloc);
    }

    pub fn reset(self: *RecvState, alloc: std.mem.Allocator) void {
        if (self.payload) |payload| {
            alloc.free(payload);
        }
        self.payload = null;
        self.payload_read = 0;
        self.header = null;
        self.header_len = 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(Header) == 8);
}

/// Identification message sent by client on connect.
pub const IdentifyMsg = extern struct {
    protocol_version: u32 align(1),
    pid: i32 align(1),
    flags: IdentifyFlags align(1),
    term_name: [64]u8 align(1),
    tty_name: [64]u8 align(1),
    cols: u16 align(1),
    rows: u16 align(1),
    xpixel: u16 align(1),
    ypixel: u16 align(1),
};

pub const IdentifyFlags = packed struct(u32) {
    utf8: bool = false,
    control_mode: bool = false,
    terminal_256: bool = false,
    _padding: u29 = 0,
};

pub const ResizeMsg = extern struct {
    cols: u16 align(1),
    rows: u16 align(1),
    xpixel: u16 align(1),
    ypixel: u16 align(1),
};

pub const KeyMsg = extern struct {
    key: u64 align(1),
    mouse_x: u16 align(1),
    mouse_y: u16 align(1),
    mouse_button: u8 align(1),
    mouse_flags: u8 align(1),
};

pub const TerminalProbeReqHeader = extern struct {
    request_id: u32 align(1),
    owner_client_id: u64 align(1),
    probe_kind: u16 align(1),
    reserved: u16 align(1),
};

pub const TerminalProbeRspHeader = extern struct {
    request_id: u32 align(1),
    status: u8 align(1),
    reserved: [3]u8 align(1),
};

pub const TerminalProbeReqView = struct {
    request_id: u32,
    owner_client_id: u64,
    probe_kind: startup_probe.ProbeKind,
    probe_bytes: []const u8,
};

pub const TerminalProbeRspView = struct {
    request_id: u32,
    status: startup_probe.ResponseStatus,
    reply_bytes: []const u8,
};

pub fn serializeHeader(header: Header) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], header.msg_type, .little);
    std.mem.writeInt(u32, buf[2..6], header.payload_len, .little);
    std.mem.writeInt(u16, buf[6..8], header.flags, .little);
    return buf;
}

pub fn deserializeHeader(buf: *const [8]u8) Header {
    return .{
        .msg_type = std.mem.readInt(u16, buf[0..2], .little),
        .payload_len = std.mem.readInt(u32, buf[2..6], .little),
        .flags = std.mem.readInt(u16, buf[6..8], .little),
    };
}

pub fn messageTypeFromInt(raw: u16) !MessageType {
    return switch (raw) {
        @intFromEnum(MessageType.identify) => .identify,
        @intFromEnum(MessageType.command) => .command,
        @intFromEnum(MessageType.resize) => .resize,
        @intFromEnum(MessageType.key) => .key,
        @intFromEnum(MessageType.shell) => .shell,
        @intFromEnum(MessageType.exit) => .exit,
        @intFromEnum(MessageType.exiting) => .exiting,
        @intFromEnum(MessageType.terminal_probe_ready) => .terminal_probe_ready,
        @intFromEnum(MessageType.terminal_probe_rsp) => .terminal_probe_rsp,
        @intFromEnum(MessageType.version) => .version,
        @intFromEnum(MessageType.ready) => .ready,
        @intFromEnum(MessageType.output) => .output,
        @intFromEnum(MessageType.pause) => .pause,
        @intFromEnum(MessageType.detach) => .detach,
        @intFromEnum(MessageType.shutdown) => .shutdown,
        @intFromEnum(MessageType.error_msg) => .error_msg,
        @intFromEnum(MessageType.exit_ack) => .exit_ack,
        @intFromEnum(MessageType.terminal_probe_req) => .terminal_probe_req,
        else => error.InvalidMessageType,
    };
}

pub fn writeAll(fd: std.posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) switch (std.posix.errno(rc)) {
            .INTR, .AGAIN => continue,
            else => return error.WriteFailed,
        };
        if (rc == 0) return error.WriteFailed;
        written += @intCast(rc);
    }
}

pub fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var read_total: usize = 0;
    while (read_total < buf.len) {
        const rc = std.c.read(fd, buf[read_total..].ptr, buf.len - read_total);
        if (rc < 0) switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReadFailed,
        };
        if (rc == 0) return error.UnexpectedEof;
        read_total += @intCast(rc);
    }
}

pub fn sendMessage(fd: std.posix.fd_t, msg_type: MessageType, payload: []const u8) !void {
    return sendMessageWithFlags(fd, msg_type, 0, payload);
}

pub fn sendMessageWithFlags(fd: std.posix.fd_t, msg_type: MessageType, flags: u16, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;

    const header_bytes = serializeHeader(.{
        .msg_type = @intFromEnum(msg_type),
        .payload_len = @intCast(payload.len),
        .flags = flags,
    });
    try writeAll(fd, &header_bytes);
    if (payload.len > 0) {
        try writeAll(fd, payload);
    }
}

pub fn recvHeader(fd: std.posix.fd_t) !Header {
    var buf: [8]u8 = undefined;
    try readExact(fd, &buf);
    return deserializeHeader(&buf);
}

pub fn recvMessageAlloc(alloc: std.mem.Allocator, fd: std.posix.fd_t) !Message {
    const header = try recvHeader(fd);
    const msg_type = try messageTypeFromInt(header.msg_type);
    if (header.payload_len > max_payload) return error.PayloadTooLarge;

    const payload = try alloc.alloc(u8, header.payload_len);
    errdefer alloc.free(payload);
    if (payload.len > 0) {
        try readExact(fd, payload);
    }

    return .{
        .msg_type = msg_type,
        .flags = header.flags,
        .payload = payload,
        .allocator = alloc,
    };
}

fn readSome(fd: std.posix.fd_t, buf: []u8) !usize {
    while (true) {
        const rc = std.c.read(fd, buf.ptr, buf.len);
        if (rc < 0) switch (std.posix.errno(rc)) {
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => return error.ReadFailed,
        };
        return @intCast(rc);
    }
}

pub fn recvMessageAllocNonblocking(alloc: std.mem.Allocator, fd: std.posix.fd_t, state: *RecvState) !Message {
    while (state.header == null) {
        while (state.header_len < @sizeOf(Header)) {
            const n = readSome(fd, state.header_buf[state.header_len..]) catch |err| switch (err) {
                error.WouldBlock => return error.WouldBlock,
                else => return err,
            };
            if (n == 0) return error.UnexpectedEof;
            state.header_len += n;
        }

        const header = deserializeHeader(@ptrCast(&state.header_buf));
        _ = try messageTypeFromInt(header.msg_type);
        if (header.payload_len > max_payload) {
            state.reset(alloc);
            return error.PayloadTooLarge;
        }
        state.header = header;
        if (state.payload == null) {
            state.payload = try alloc.alloc(u8, header.payload_len);
        }
    }

    const header = state.header.?;
    const msg_type = try messageTypeFromInt(header.msg_type);
    const payload = state.payload.?;
    while (state.payload_read < payload.len) {
        const n = readSome(fd, payload[state.payload_read..]) catch |err| switch (err) {
            error.WouldBlock => return error.WouldBlock,
            else => return err,
        };
        if (n == 0) return error.UnexpectedEof;
        state.payload_read += n;
    }

    state.payload = null;
    state.payload_read = 0;
    state.header = null;
    state.header_len = 0;
    return .{
        .msg_type = msg_type,
        .flags = header.flags,
        .payload = payload,
        .allocator = alloc,
    };
}

pub fn encodeCommandArgs(alloc: std.mem.Allocator, args: []const []const u8) ![]u8 {
    var total: usize = 0;
    for (args) |arg| total += arg.len + 1;
    if (total > max_payload) return error.PayloadTooLarge;

    const payload = try alloc.alloc(u8, total);
    var offset: usize = 0;
    for (args) |arg| {
        @memcpy(payload[offset .. offset + arg.len], arg);
        offset += arg.len;
        payload[offset] = 0;
        offset += 1;
    }
    return payload;
}

pub fn decodeCommandArgs(alloc: std.mem.Allocator, payload: []const u8) !std.ArrayListAligned([]const u8, null) {
    var args: std.ArrayListAligned([]const u8, null) = .empty;
    errdefer args.deinit(alloc);

    if (payload.len == 0) return args;

    var start: usize = 0;
    for (payload, 0..) |byte, i| {
        if (byte != 0) continue;
        try args.append(alloc, payload[start..i]);
        start = i + 1;
    }

    if (start < payload.len) {
        try args.append(alloc, payload[start..]);
    }

    return args;
}

pub fn encodeTerminalProbeReq(
    alloc: std.mem.Allocator,
    request_id: u32,
    owner_client_id: u64,
    probe_kind: startup_probe.ProbeKind,
    probe_bytes: []const u8,
) ![]u8 {
    const total = @sizeOf(TerminalProbeReqHeader) + probe_bytes.len;
    if (total > max_payload) return error.PayloadTooLarge;

    const payload = try alloc.alloc(u8, total);
    const header: *TerminalProbeReqHeader = @ptrCast(@alignCast(payload.ptr));
    header.* = .{
        .request_id = request_id,
        .owner_client_id = owner_client_id,
        .probe_kind = @intFromEnum(probe_kind),
        .reserved = 0,
    };
    @memcpy(payload[@sizeOf(TerminalProbeReqHeader)..], probe_bytes);
    return payload;
}

pub fn decodeTerminalProbeReq(payload: []const u8) !TerminalProbeReqView {
    if (payload.len < @sizeOf(TerminalProbeReqHeader)) return error.InvalidPayload;
    const header: *const TerminalProbeReqHeader = @ptrCast(@alignCast(payload.ptr));
    return .{
        .request_id = header.request_id,
        .owner_client_id = header.owner_client_id,
        .probe_kind = try startup_probe.probeKindFromInt(header.probe_kind),
        .probe_bytes = payload[@sizeOf(TerminalProbeReqHeader)..],
    };
}

pub fn encodeTerminalProbeRsp(
    alloc: std.mem.Allocator,
    request_id: u32,
    status: startup_probe.ResponseStatus,
    reply_bytes: []const u8,
) ![]u8 {
    const total = @sizeOf(TerminalProbeRspHeader) + reply_bytes.len;
    if (total > max_payload) return error.PayloadTooLarge;

    const payload = try alloc.alloc(u8, total);
    const header: *TerminalProbeRspHeader = @ptrCast(@alignCast(payload.ptr));
    header.* = .{
        .request_id = request_id,
        .status = @intFromEnum(status),
        .reserved = .{ 0, 0, 0 },
    };
    @memcpy(payload[@sizeOf(TerminalProbeRspHeader)..], reply_bytes);
    return payload;
}

pub fn decodeTerminalProbeRsp(payload: []const u8) !TerminalProbeRspView {
    if (payload.len < @sizeOf(TerminalProbeRspHeader)) return error.InvalidPayload;
    const header: *const TerminalProbeRspHeader = @ptrCast(@alignCast(payload.ptr));
    return .{
        .request_id = header.request_id,
        .status = try startup_probe.responseStatusFromInt(header.status),
        .reply_bytes = payload[@sizeOf(TerminalProbeRspHeader)..],
    };
}

test "header roundtrip" {
    const h = Header{
        .msg_type = @intFromEnum(MessageType.identify),
        .payload_len = 1234,
        .flags = 7,
    };
    const bytes = serializeHeader(h);
    const h2 = deserializeHeader(&bytes);
    try std.testing.expectEqual(h.msg_type, h2.msg_type);
    try std.testing.expectEqual(h.payload_len, h2.payload_len);
    try std.testing.expectEqual(h.flags, h2.flags);
}

test "message roundtrip through pipe" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try sendMessageWithFlags(fds[1], .output, 3, "hello");
    var msg = try recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();

    try std.testing.expectEqual(MessageType.output, msg.msg_type);
    try std.testing.expectEqual(@as(u16, 3), msg.flags);
    try std.testing.expectEqualStrings("hello", msg.payload);
}

test "command arg payload roundtrip" {
    const input = [_][]const u8{ "new-session", "-s", "demo session" };
    const payload = try encodeCommandArgs(std.testing.allocator, &input);
    defer std.testing.allocator.free(payload);

    var decoded = try decodeCommandArgs(std.testing.allocator, payload);
    defer decoded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, input.len), decoded.items.len);
    for (input, decoded.items) |expected, actual| {
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "terminal probe request payload roundtrip" {
    const payload = try encodeTerminalProbeReq(
        std.testing.allocator,
        11,
        42,
        .osc_11,
        startup_probe.requestBytes(.osc_11),
    );
    defer std.testing.allocator.free(payload);

    const decoded = try decodeTerminalProbeReq(payload);
    try std.testing.expectEqual(@as(u32, 11), decoded.request_id);
    try std.testing.expectEqual(@as(u64, 42), decoded.owner_client_id);
    try std.testing.expectEqual(startup_probe.ProbeKind.osc_11, decoded.probe_kind);
    try std.testing.expectEqualStrings(startup_probe.requestBytes(.osc_11), decoded.probe_bytes);
}

test "terminal probe response payload roundtrip" {
    const payload = try encodeTerminalProbeRsp(
        std.testing.allocator,
        7,
        .complete,
        "\x1b]10;rgb:0000/0000/0000\x1b\\",
    );
    defer std.testing.allocator.free(payload);

    const decoded = try decodeTerminalProbeRsp(payload);
    try std.testing.expectEqual(@as(u32, 7), decoded.request_id);
    try std.testing.expectEqual(startup_probe.ResponseStatus.complete, decoded.status);
    try std.testing.expectEqualStrings("\x1b]10;rgb:0000/0000/0000\x1b\\", decoded.reply_bytes);
}

test "nonblocking recv preserves fragmented terminal probe request frames" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const fl = std.c.fcntl(fds[0], std.c.F.GETFL);
    try std.testing.expect(fl >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(fds[0], std.c.F.SETFL, fl | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true }))));

    const payload = try encodeTerminalProbeReq(std.testing.allocator, 9, 77, .xtversion, startup_probe.requestBytes(.xtversion));
    defer std.testing.allocator.free(payload);
    const header = serializeHeader(.{
        .msg_type = @intFromEnum(MessageType.terminal_probe_req),
        .payload_len = @intCast(payload.len),
        .flags = 0,
    });

    var state = RecvState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(isize, 4), std.c.write(fds[1], header[0..4].ptr, 4));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));

    try std.testing.expectEqual(@as(isize, @intCast(header.len - 4)), std.c.write(fds[1], header[4..].ptr, header.len - 4));
    try std.testing.expectEqual(@as(isize, 5), std.c.write(fds[1], payload[0..5].ptr, 5));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));

    try std.testing.expectEqual(@as(isize, @intCast(payload.len - 5)), std.c.write(fds[1], payload[5..].ptr, payload.len - 5));
    var msg = try recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state);
    defer msg.deinit();

    try std.testing.expectEqual(MessageType.terminal_probe_req, msg.msg_type);
    const decoded = try decodeTerminalProbeReq(msg.payload);
    try std.testing.expectEqual(@as(u32, 9), decoded.request_id);
    try std.testing.expectEqual(@as(u64, 77), decoded.owner_client_id);
    try std.testing.expectEqual(startup_probe.ProbeKind.xtversion, decoded.probe_kind);
    try std.testing.expectEqualStrings(startup_probe.requestBytes(.xtversion), decoded.probe_bytes);
}

test "nonblocking recv preserves fragmented terminal probe response frames" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const fl = std.c.fcntl(fds[0], std.c.F.GETFL);
    try std.testing.expect(fl >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(fds[0], std.c.F.SETFL, fl | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true }))));

    const payload = try encodeTerminalProbeRsp(std.testing.allocator, 5, .complete, "\x1b[?1;2c");
    defer std.testing.allocator.free(payload);
    const header = serializeHeader(.{
        .msg_type = @intFromEnum(MessageType.terminal_probe_rsp),
        .payload_len = @intCast(payload.len),
        .flags = 0,
    });

    var state = RecvState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], header[0..2].ptr, 2));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));

    try std.testing.expectEqual(@as(isize, @intCast(header.len - 2)), std.c.write(fds[1], header[2..].ptr, header.len - 2));
    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], payload[0..3].ptr, 3));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));

    try std.testing.expectEqual(@as(isize, @intCast(payload.len - 3)), std.c.write(fds[1], payload[3..].ptr, payload.len - 3));
    var msg = try recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state);
    defer msg.deinit();

    try std.testing.expectEqual(MessageType.terminal_probe_rsp, msg.msg_type);
    const decoded = try decodeTerminalProbeRsp(msg.payload);
    try std.testing.expectEqual(@as(u32, 5), decoded.request_id);
    try std.testing.expectEqual(startup_probe.ResponseStatus.complete, decoded.status);
    try std.testing.expectEqualStrings("\x1b[?1;2c", decoded.reply_bytes);
}

test "nonblocking recv preserves fragmented frame state" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    const fl = std.c.fcntl(fds[0], std.c.F.GETFL);
    try std.testing.expect(fl >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(fds[0], std.c.F.SETFL, fl | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true }))));

    const payload = "split payload";
    const header = serializeHeader(.{
        .msg_type = @intFromEnum(MessageType.output),
        .payload_len = payload.len,
        .flags = 9,
    });
    var state = RecvState{};
    defer state.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], header[0..3].ptr, 3));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));
    try std.testing.expectEqual(@as(usize, 3), state.header_len);

    try std.testing.expectEqual(@as(isize, 5), std.c.write(fds[1], header[3..8].ptr, 5));
    try std.testing.expectEqual(@as(isize, 4), std.c.write(fds[1], payload[0..4].ptr, 4));
    try std.testing.expectError(error.WouldBlock, recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state));
    try std.testing.expectEqual(@as(usize, 8), state.header_len);
    try std.testing.expect(state.header != null);
    try std.testing.expectEqual(@as(usize, 4), state.payload_read);

    try std.testing.expectEqual(@as(isize, payload.len - 4), std.c.write(fds[1], payload[4..].ptr, payload.len - 4));
    var msg = try recvMessageAllocNonblocking(std.testing.allocator, fds[0], &state);
    defer msg.deinit();

    try std.testing.expectEqual(MessageType.output, msg.msg_type);
    try std.testing.expectEqual(@as(u16, 9), msg.flags);
    try std.testing.expectEqualStrings(payload, msg.payload);
    try std.testing.expectEqual(@as(usize, 0), state.header_len);
    try std.testing.expect(state.header == null);
    try std.testing.expect(state.payload == null);
    try std.testing.expectEqual(@as(usize, 0), state.payload_read);
}
