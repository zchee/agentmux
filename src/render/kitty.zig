const std = @import("std");

/// Kitty graphics protocol action.
pub const KittyAction = enum {
    transmit, // a=t: transmit image data
    transmit_and_display, // a=T: transmit and display
    display, // a=p: display previously transmitted image
    delete, // a=d: delete image
    query, // a=q: query support
};

/// Image format.
pub const KittyFormat = enum {
    rgb24, // f=24
    rgba32, // f=32
    png, // f=100
};

/// Parsed kitty graphics command.
pub const KittyCommand = struct {
    action: KittyAction,
    format: KittyFormat,
    id: u32,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
    cols: u32,
    rows: u32,
    payload: []const u8,
};

/// Parse a kitty graphics protocol command string.
/// Format: key=value,key=value,...;payload
/// or: key=value;key=value;...;payload (semicolons also valid)
pub fn parseCommand(data: []const u8) ?KittyCommand {
    var cmd = KittyCommand{
        .action = .transmit_and_display,
        .format = .rgba32,
        .id = 0,
        .width = 0,
        .height = 0,
        .x = 0,
        .y = 0,
        .cols = 0,
        .rows = 0,
        .payload = &.{},
    };

    // Find the payload separator (last ; or after all key=value pairs)
    // Key=value pairs are separated by , or ;
    // Payload comes after the header section
    var header_end = data.len;
    var payload_start = data.len;

    // Find where header ends and payload begins
    // Heuristic: payload is after the last ';' that follows a complete key=value section
    if (findPayloadSeparator(data)) |sep| {
        header_end = sep;
        payload_start = sep + 1;
        cmd.payload = data[payload_start..];
    }

    const header = data[0..header_end];

    // Parse key=value pairs
    var iter = std.mem.tokenizeAny(u8, header, ",;");
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];

            if (key.len == 1) {
                switch (key[0]) {
                    'a' => {
                        if (value.len > 0) {
                            cmd.action = switch (value[0]) {
                                't' => .transmit,
                                'T' => .transmit_and_display,
                                'p' => .display,
                                'd' => .delete,
                                'q' => .query,
                                else => .transmit_and_display,
                            };
                        }
                    },
                    'f' => {
                        const fmt = std.fmt.parseInt(u32, value, 10) catch 32;
                        cmd.format = switch (fmt) {
                            24 => .rgb24,
                            32 => .rgba32,
                            100 => .png,
                            else => .rgba32,
                        };
                    },
                    'i' => cmd.id = std.fmt.parseInt(u32, value, 10) catch 0,
                    's' => cmd.width = std.fmt.parseInt(u32, value, 10) catch 0,
                    'v' => cmd.height = std.fmt.parseInt(u32, value, 10) catch 0,
                    'x' => cmd.x = std.fmt.parseInt(u32, value, 10) catch 0,
                    'y' => cmd.y = std.fmt.parseInt(u32, value, 10) catch 0,
                    'c' => cmd.cols = std.fmt.parseInt(u32, value, 10) catch 0,
                    'r' => cmd.rows = std.fmt.parseInt(u32, value, 10) catch 0,
                    else => {},
                }
            }
        }
    }

    return cmd;
}

fn findPayloadSeparator(data: []const u8) ?usize {
    // The payload separator is a ';' that comes after the header.
    // Header consists of key=value pairs. The payload starts after the
    // last ';' where the content before it looks like key=value pairs.
    var last_semi: ?usize = null;
    var i: usize = 0;
    while (i < data.len) {
        if (data[i] == ';') {
            // Check if what follows looks like a key=value pair
            const rest = data[i + 1 ..];
            if (rest.len == 0 or !looksLikeKeyValue(rest)) {
                return i;
            }
            last_semi = i;
        }
        i += 1;
    }
    return last_semi;
}

fn looksLikeKeyValue(data: []const u8) bool {
    // A key=value pair starts with a letter followed by =
    if (data.len < 3) return false;
    if (!std.ascii.isAlphabetic(data[0])) return false;
    if (data[1] != '=') return false;
    return true;
}

test "parse transmit command" {
    const cmd = parseCommand("a=T,f=32,s=10,v=10;AAAA").?;
    try std.testing.expectEqual(KittyAction.transmit_and_display, cmd.action);
    try std.testing.expectEqual(KittyFormat.rgba32, cmd.format);
    try std.testing.expectEqual(@as(u32, 10), cmd.width);
    try std.testing.expectEqual(@as(u32, 10), cmd.height);
    try std.testing.expectEqualStrings("AAAA", cmd.payload);
}

test "parse display command" {
    const cmd = parseCommand("a=p,i=42").?;
    try std.testing.expectEqual(KittyAction.display, cmd.action);
    try std.testing.expectEqual(@as(u32, 42), cmd.id);
}

test "parse delete command" {
    const cmd = parseCommand("a=d,i=1").?;
    try std.testing.expectEqual(KittyAction.delete, cmd.action);
    try std.testing.expectEqual(@as(u32, 1), cmd.id);
}

test "parse rgb format" {
    const cmd = parseCommand("a=t,f=24,s=5,v=5").?;
    try std.testing.expectEqual(KittyFormat.rgb24, cmd.format);
    try std.testing.expectEqual(@as(u32, 5), cmd.width);
}
