const std = @import("std");

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

    // Server -> Client
    version = 200,
    ready = 201,
    output = 202,
    pause = 203,
    detach = 204,
    shutdown = 205,
    error_msg = 206,
    exit_ack = 207,
};

/// Wire format header for all messages.
pub const Header = extern struct {
    msg_type: u16 align(1),
    payload_len: u32 align(1),
    flags: u16 align(1),
};

comptime {
    // Ensure header is a fixed size for wire protocol
    std.debug.assert(@sizeOf(Header) == 8);
}

/// Identification message sent by client on connect.
pub const IdentifyMsg = struct {
    protocol_version: u32,
    pid: i32,
    flags: IdentifyFlags,
    term_name: [64]u8,
    tty_name: [64]u8,
    cols: u16,
    rows: u16,
    xpixel: u16,
    ypixel: u16,
};

pub const IdentifyFlags = packed struct(u32) {
    utf8: bool = false,
    control_mode: bool = false,
    terminal_256: bool = false,
    _padding: u29 = 0,
};

/// Resize message.
pub const ResizeMsg = extern struct {
    cols: u16 align(1),
    rows: u16 align(1),
    xpixel: u16 align(1),
    ypixel: u16 align(1),
};

/// Key input message.
pub const KeyMsg = extern struct {
    key: u64 align(1),
    mouse_x: u16 align(1),
    mouse_y: u16 align(1),
    mouse_button: u8 align(1),
    mouse_flags: u8 align(1),
};

/// Serialize a header to bytes.
pub fn serializeHeader(header: Header) [8]u8 {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], header.msg_type, .little);
    std.mem.writeInt(u32, buf[2..6], header.payload_len, .little);
    std.mem.writeInt(u16, buf[6..8], header.flags, .little);
    return buf;
}

/// Deserialize a header from bytes.
pub fn deserializeHeader(buf: *const [8]u8) Header {
    return .{
        .msg_type = std.mem.readInt(u16, buf[0..2], .little),
        .payload_len = std.mem.readInt(u32, buf[2..6], .little),
        .flags = std.mem.readInt(u16, buf[6..8], .little),
    };
}

/// Send a message by writing header + payload to a file descriptor.
pub fn sendMessage(fd: std.posix.fd_t, msg_type: MessageType, payload: []const u8) !void {
    if (payload.len > max_payload) return error.PayloadTooLarge;

    const header_bytes = serializeHeader(.{
        .msg_type = @intFromEnum(msg_type),
        .payload_len = @intCast(payload.len),
        .flags = 0,
    });

    // Write header then payload via libc
    _ = std.c.write(fd, &header_bytes, header_bytes.len);
    if (payload.len > 0) {
        _ = std.c.write(fd, payload.ptr, payload.len);
    }
}

/// Receive a message header from a file descriptor.
pub fn recvHeader(fd: std.posix.fd_t) !Header {
    var buf: [8]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n != 8) return error.IncompleteHeader;
    return deserializeHeader(&buf);
}

test "header roundtrip" {
    const h = Header{
        .msg_type = @intFromEnum(MessageType.identify),
        .payload_len = 1234,
        .flags = 0,
    };
    const bytes = serializeHeader(h);
    const h2 = deserializeHeader(&bytes);
    try std.testing.expectEqual(h.msg_type, h2.msg_type);
    try std.testing.expectEqual(h.payload_len, h2.payload_len);
}
