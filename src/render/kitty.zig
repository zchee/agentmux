const std = @import("std");

/// Kitty graphics protocol action (key "a").
pub const KittyAction = enum {
    /// Transmit image data (a=T).
    transmit,
    /// Transmit and immediately display (a=t).
    transmit_and_display,
    /// Display a previously transmitted image (a=p).
    display,
    /// Delete an image (a=D).
    delete,
    /// Query terminal capabilities (a=q).
    query,
};

/// Pixel format for transmitted image data (key "f").
pub const KittyFormat = enum {
    /// 24-bit RGB (f=24).
    rgb24,
    /// 32-bit RGBA (f=32).
    rgba32,
    /// PNG encoded (f=100).
    png,
};

/// Parsed kitty graphics command.
pub const KittyCommand = struct {
    action: KittyAction,
    format: KittyFormat,
    /// Image ID (key "i").
    id: u32,
    /// Image width in pixels (key "s").
    width: u32,
    /// Image height in pixels (key "v").
    height: u32,
    /// Raw (typically base64-encoded) payload — slice into the input data, not owned.
    payload: []const u8,
};

/// Kitty image with decoded pixel data and placement info.
pub const KittyImage = struct {
    id: u32,
    width: u32,
    height: u32,
    /// RGBA pixel data, 4 bytes per pixel, row-major.
    pixels: std.ArrayListAligned(u8, null),
    /// Placement: top-left terminal column and row.
    place_x: u32,
    place_y: u32,
    /// Placement size in terminal cells.
    cols: u32,
    rows: u32,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) KittyImage {
        return .{
            .id = 0,
            .width = 0,
            .height = 0,
            .pixels = .empty,
            .place_x = 0,
            .place_y = 0,
            .cols = 0,
            .rows = 0,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *KittyImage) void {
        self.pixels.deinit(self.allocator);
    }
};

/// Parse a kitty graphics protocol command.
///
/// `data` is the inner content of an APC sequence after stripping "G" and ST:
///   key=value[,key=value...][;payload]
///
/// Key=value pairs may be comma- or semicolon-separated.
/// The payload (base64-encoded image data) follows the last semicolon that is
/// not part of a key=value pair.
///
/// Keys:
///   a — action: T=transmit, t=transmit_and_display, p=display, D=delete, q=query
///   f — format: 24=rgb24, 32=rgba32, 100=png
///   i — image id (decimal)
///   s — image width in pixels (decimal)
///   v — image height in pixels (decimal)
pub fn parseCommand(data: []const u8) !KittyCommand {
    var cmd = KittyCommand{
        .action = .transmit,
        .format = .rgba32,
        .id = 0,
        .width = 0,
        .height = 0,
        .payload = &.{},
    };

    // Split params from payload on the last ';' that is not part of a kv pair.
    const header, const payload = splitHeaderPayload(data);
    cmd.payload = payload;

    // Key=value pairs may be comma- or semicolon-separated.
    var iter = std.mem.tokenizeAny(u8, header, ",;");
    while (iter.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        if (key.len != 1) continue;

        switch (key[0]) {
            'a' => {
                if (val.len > 0) {
                    cmd.action = switch (val[0]) {
                        'T' => .transmit,
                        't' => .transmit_and_display,
                        'p' => .display,
                        'D' => .delete,
                        'q' => .query,
                        else => .transmit,
                    };
                }
            },
            'f' => {
                const n = std.fmt.parseInt(u32, val, 10) catch continue;
                cmd.format = switch (n) {
                    24 => .rgb24,
                    32 => .rgba32,
                    100 => .png,
                    else => .rgba32,
                };
            },
            'i' => cmd.id = std.fmt.parseInt(u32, val, 10) catch 0,
            's' => cmd.width = std.fmt.parseInt(u32, val, 10) catch 0,
            'v' => cmd.height = std.fmt.parseInt(u32, val, 10) catch 0,
            else => {},
        }
    }

    return cmd;
}

/// Split `data` into (header, payload) on the last ';' that is not followed
/// by a key=value token.  If no such separator exists the whole string is the
/// header and payload is empty.
fn splitHeaderPayload(data: []const u8) struct { []const u8, []const u8 } {
    // Walk from the end; the first ';' whose right-hand side does not start
    // with <letter>'=' is the payload separator.
    var i: usize = data.len;
    while (i > 0) {
        i -= 1;
        if (data[i] == ';') {
            const rest = data[i + 1 ..];
            if (!startsWithKeyValue(rest)) {
                return .{ data[0..i], rest };
            }
        }
    }
    return .{ data, &.{} };
}

fn startsWithKeyValue(s: []const u8) bool {
    return s.len >= 3 and std.ascii.isAlphabetic(s[0]) and s[1] == '=';
}

test "parse kitty transmit command" {
    const cmd = try parseCommand("a=T,f=32,s=10,v=10;AAAA");

    try std.testing.expectEqual(KittyAction.transmit, cmd.action);
    try std.testing.expectEqual(KittyFormat.rgba32, cmd.format);
    try std.testing.expectEqual(@as(u32, 10), cmd.width);
    try std.testing.expectEqual(@as(u32, 10), cmd.height);
    try std.testing.expectEqualStrings("AAAA", cmd.payload);
}

test "parse kitty display command" {
    const cmd = try parseCommand("a=p,i=42");

    try std.testing.expectEqual(KittyAction.display, cmd.action);
    try std.testing.expectEqual(@as(u32, 42), cmd.id);
    try std.testing.expectEqualStrings("", cmd.payload);
}

test "parse kitty delete command" {
    const cmd = try parseCommand("a=D,i=1");

    try std.testing.expectEqual(KittyAction.delete, cmd.action);
    try std.testing.expectEqual(@as(u32, 1), cmd.id);
}

test "parse kitty rgb24 format" {
    const cmd = try parseCommand("a=T,f=24,s=8,v=8");

    try std.testing.expectEqual(KittyFormat.rgb24, cmd.format);
    try std.testing.expectEqual(@as(u32, 8), cmd.width);
    try std.testing.expectEqual(@as(u32, 8), cmd.height);
}

test "parse kitty png format with payload" {
    const cmd = try parseCommand("a=T,f=100;base64data");

    try std.testing.expectEqual(KittyFormat.png, cmd.format);
    try std.testing.expectEqualStrings("base64data", cmd.payload);
}
