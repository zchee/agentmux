const std = @import("std");

/// Clipboard integration via OSC 52 protocol.
/// OSC 52 allows terminal applications to read/write the system clipboard.
pub const Clipboard = struct {
    /// Internal paste buffer (used when system clipboard is unavailable).
    buffer: ?[]u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Clipboard {
        return .{
            .buffer = null,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Clipboard) void {
        if (self.buffer) |b| {
            self.allocator.free(b);
        }
    }

    /// Set clipboard content.
    pub fn set(self: *Clipboard, data: []const u8) !void {
        if (self.buffer) |old| {
            self.allocator.free(old);
        }
        self.buffer = try self.allocator.dupe(u8, data);
    }

    /// Get clipboard content.
    pub fn get(self: *const Clipboard) ?[]const u8 {
        return self.buffer;
    }

    /// Generate OSC 52 set clipboard sequence.
    /// Returns: ESC ] 52 ; c ; <base64-encoded data> ESC \
    pub fn encodeOsc52Set(alloc: std.mem.Allocator, data: []const u8) ![]u8 {
        // Calculate base64 size: ceil(n/3)*4
        const b64_len = ((data.len + 2) / 3) * 4;
        // Total: \x1b]52;c; + base64 + \x1b\
        const total = 7 + b64_len + 2;
        const buf = try alloc.alloc(u8, total);

        // Header
        buf[0] = 0x1b; // ESC
        buf[1] = ']'; // OSC
        buf[2] = '5';
        buf[3] = '2';
        buf[4] = ';';
        buf[5] = 'c';
        buf[6] = ';';

        // Base64 encode
        base64Encode(data, buf[7 .. 7 + b64_len]);

        // String terminator
        buf[total - 2] = 0x1b;
        buf[total - 1] = '\\';

        return buf;
    }

    /// Generate OSC 52 query clipboard sequence.
    /// Returns: ESC ] 52 ; c ; ? ESC \
    pub fn encodeOsc52Query() [10]u8 {
        return .{ 0x1b, ']', '5', '2', ';', 'c', ';', '?', 0x1b, '\\' };
    }

    /// Decode base64-encoded clipboard data from OSC 52 response.
    pub fn decodeOsc52Response(alloc: std.mem.Allocator, b64_data: []const u8) ![]u8 {
        const decoded_len = (b64_data.len / 4) * 3;
        const buf = try alloc.alloc(u8, decoded_len);
        const actual = base64Decode(b64_data, buf);
        if (actual < decoded_len) {
            const trimmed = try alloc.alloc(u8, actual);
            @memcpy(trimmed, buf[0..actual]);
            alloc.free(buf);
            return trimmed;
        }
        return buf;
    }
};

// Base64 encoding/decoding
const b64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64Encode(input: []const u8, output: []u8) void {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 2 < input.len) {
        const a = input[i];
        const b = input[i + 1];
        const c = input[i + 2];
        output[o] = b64_chars[(a >> 2) & 0x3F];
        output[o + 1] = b64_chars[((a & 0x3) << 4) | ((b >> 4) & 0xF)];
        output[o + 2] = b64_chars[((b & 0xF) << 2) | ((c >> 6) & 0x3)];
        output[o + 3] = b64_chars[c & 0x3F];
        i += 3;
        o += 4;
    }
    if (i < input.len) {
        const a = input[i];
        output[o] = b64_chars[(a >> 2) & 0x3F];
        if (i + 1 < input.len) {
            const b = input[i + 1];
            output[o + 1] = b64_chars[((a & 0x3) << 4) | ((b >> 4) & 0xF)];
            output[o + 2] = b64_chars[(b & 0xF) << 2];
            output[o + 3] = '=';
        } else {
            output[o + 1] = b64_chars[(a & 0x3) << 4];
            output[o + 2] = '=';
            output[o + 3] = '=';
        }
    }
}

fn base64Decode(input: []const u8, output: []u8) usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 < input.len and o < output.len) {
        const a = b64Lookup(input[i]);
        const b = b64Lookup(input[i + 1]);
        const c = b64Lookup(input[i + 2]);
        const d = b64Lookup(input[i + 3]);
        if (a == 0xFF or b == 0xFF) break;
        output[o] = (a << 2) | (b >> 4);
        o += 1;
        if (c != 0xFF and o < output.len) {
            output[o] = ((b & 0xF) << 4) | (c >> 2);
            o += 1;
        }
        if (d != 0xFF and o < output.len) {
            output[o] = ((c & 0x3) << 6) | d;
            o += 1;
        }
        i += 4;
    }
    return o;
}

fn b64Lookup(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c - 'A';
    if (c >= 'a' and c <= 'z') return c - 'a' + 26;
    if (c >= '0' and c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return 0xFF; // padding or invalid
}

test "clipboard set and get" {
    var cb = Clipboard.init(std.testing.allocator);
    defer cb.deinit();

    try cb.set("hello");
    try std.testing.expectEqualStrings("hello", cb.get().?);
}

test "osc52 encode" {
    const encoded = try Clipboard.encodeOsc52Set(std.testing.allocator, "test");
    defer std.testing.allocator.free(encoded);
    // Should start with ESC]52;c;
    try std.testing.expectEqual(@as(u8, 0x1b), encoded[0]);
    try std.testing.expectEqual(@as(u8, ']'), encoded[1]);
    try std.testing.expectEqual(@as(u8, '5'), encoded[2]);
    try std.testing.expectEqual(@as(u8, '2'), encoded[3]);
}

test "base64 roundtrip" {
    const input = "Hello, World!";
    var encoded: [20]u8 = undefined;
    base64Encode(input, &encoded);
    var decoded: [20]u8 = undefined;
    const len = base64Decode(&encoded, &decoded);
    try std.testing.expectEqualStrings(input, decoded[0..len]);
}
