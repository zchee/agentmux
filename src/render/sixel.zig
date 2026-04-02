const std = @import("std");

/// RGB color for the sixel palette.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Decoded sixel image with RGBA pixel data.
pub const SixelImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data, 4 bytes per pixel, row-major.
    pixels: std.ArrayListAligned(u8, null),
    palette: [256]Color,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SixelImage {
        return .{
            .width = 0,
            .height = 0,
            .pixels = .empty,
            .palette = [_]Color{.{ .r = 0, .g = 0, .b = 0 }} ** 256,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *SixelImage) void {
        self.pixels.deinit(self.allocator);
    }
};

/// Decode a sixel image from raw sixel data (after any DCS prefix is stripped).
/// Caller must call deinit() on the returned SixelImage.
///
/// Sixel format:
///   #N[;Pc;Px;Py;Pz]  — color register (N=index, Pc=1 HLS / 2 RGB, Px/Py/Pz = 0-100)
///   !N<char>           — repeat data char N times
///   -                  — newline (advance to next 6-pixel row)
///   $                  — carriage return (return to column 0)
///   ?..~               — data char: value = char - '?', 6-bit mask, bit 0 = topmost pixel
pub fn decode(alloc: std.mem.Allocator, data: []const u8) !SixelImage {
    var img = SixelImage.init(alloc);
    errdefer img.deinit();

    // Set default palette entries.
    img.palette[0] = .{ .r = 0, .g = 0, .b = 0 };
    img.palette[1] = .{ .r = 0, .g = 0, .b = 255 };
    img.palette[2] = .{ .r = 255, .g = 0, .b = 0 };
    img.palette[3] = .{ .r = 0, .g = 255, .b = 0 };
    img.palette[7] = .{ .r = 255, .g = 255, .b = 255 };

    // Pass 1: determine image dimensions.
    var max_x: u32 = 0;
    var cur_x: u32 = 0;
    var cur_y: u32 = 0;
    var i: usize = 0;

    while (i < data.len) {
        const c = data[i];
        if (c == '#') {
            i += 1;
            _ = parseNumber(data, &i);
            if (i < data.len and data[i] == ';') {
                while (i < data.len and data[i] != '#' and
                    data[i] != '!' and data[i] != '-' and data[i] != '$' and
                    !(data[i] >= 0x3F and data[i] <= 0x7E)) : (i += 1)
                {}
            }
        } else if (c == '!') {
            i += 1;
            const count = parseNumber(data, &i);
            if (i < data.len and data[i] >= 0x3F and data[i] <= 0x7E) {
                cur_x += count;
                i += 1;
            }
        } else if (c == '-') {
            max_x = @max(max_x, cur_x);
            cur_x = 0;
            cur_y += 6;
            i += 1;
        } else if (c == '$') {
            max_x = @max(max_x, cur_x);
            cur_x = 0;
            i += 1;
        } else if (c >= 0x3F and c <= 0x7E) {
            cur_x += 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    max_x = @max(max_x, cur_x);
    const max_y = cur_y + 6;

    if (max_x == 0) return img;

    img.width = max_x;
    img.height = max_y;

    // Allocate zero-initialised RGBA pixel buffer.
    const pixel_count = @as(usize, max_x) * @as(usize, max_y) * 4;
    try img.pixels.appendNTimes(alloc, 0, pixel_count);

    // Pass 2: render pixels.
    cur_x = 0;
    cur_y = 0;
    var current_color: u8 = 0;
    i = 0;

    while (i < data.len) {
        const c = data[i];
        if (c == '#') {
            i += 1;
            const color_idx = parseNumber(data, &i);
            current_color = @intCast(@min(color_idx, 255));
            if (i < data.len and data[i] == ';') {
                i += 1;
                const pc = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const px = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const py = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const pz = parseNumber(data, &i);
                if (pc == 2) {
                    img.palette[current_color] = .{
                        .r = @intCast(@min(px * 255 / 100, 255)),
                        .g = @intCast(@min(py * 255 / 100, 255)),
                        .b = @intCast(@min(pz * 255 / 100, 255)),
                    };
                }
            }
        } else if (c == '!') {
            i += 1;
            const count = parseNumber(data, &i);
            if (i < data.len and data[i] >= 0x3F and data[i] <= 0x7E) {
                const bits: u6 = @intCast(data[i] - 0x3F);
                var rep: u32 = 0;
                while (rep < count) : (rep += 1) {
                    renderSixel(img.pixels.items, max_x, cur_x, cur_y, bits, img.palette[current_color]);
                    cur_x += 1;
                }
                i += 1;
            }
        } else if (c == '-') {
            cur_x = 0;
            cur_y += 6;
            i += 1;
        } else if (c == '$') {
            cur_x = 0;
            i += 1;
        } else if (c >= 0x3F and c <= 0x7E) {
            const bits: u6 = @intCast(c - 0x3F);
            renderSixel(img.pixels.items, max_x, cur_x, cur_y, bits, img.palette[current_color]);
            cur_x += 1;
            i += 1;
        } else {
            i += 1;
        }
    }

    return img;
}

fn renderSixel(pixels: []u8, stride: u32, x: u32, y: u32, bits: u6, color: Color) void {
    var bit: u3 = 0;
    while (bit < 6) : (bit += 1) {
        if ((bits >> bit) & 1 != 0) {
            const py = y + bit;
            const offset = (@as(usize, py) * @as(usize, stride) + @as(usize, x)) * 4;
            if (offset + 3 < pixels.len) {
                pixels[offset] = color.r;
                pixels[offset + 1] = color.g;
                pixels[offset + 2] = color.b;
                pixels[offset + 3] = 255;
            }
        }
    }
}

fn parseNumber(data: []const u8, pos: *usize) u32 {
    var n: u32 = 0;
    while (pos.* < data.len and data[pos.*] >= '0' and data[pos.*] <= '9') {
        n = n *| 10 +| (data[pos.*] - '0');
        pos.* += 1;
    }
    return n;
}

test "decode minimal sixel" {
    // '~' = 0x7E - 0x3F = 63 = 0b111111: all 6 pixels set -> 1 wide, 6 tall
    var img = try decode(std.testing.allocator, "~");
    defer img.deinit();
    try std.testing.expect(img.width > 0);
    try std.testing.expect(img.height > 0);
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 6), img.height);
}

test "decode sixel with repeat" {
    var img = try decode(std.testing.allocator, "!10~");
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 10), img.width);
    try std.testing.expectEqual(@as(u32, 6), img.height);
}

test "decode sixel multiline" {
    var img = try decode(std.testing.allocator, "~-~");
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 12), img.height);
}

test "decode sixel color register" {
    // "#0;2;100;0;0" sets palette[0] to red, then draw all 6 pixels
    var img = try decode(std.testing.allocator, "#0;2;100;0;0~");
    defer img.deinit();
    try std.testing.expectEqual(@as(u32, 1), img.width);
    try std.testing.expectEqual(@as(u32, 6), img.height);
    // Top pixel (offset 0) should be red (255, 0, 0, 255)
    try std.testing.expectEqual(@as(u8, 255), img.pixels.items[0]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels.items[1]);
    try std.testing.expectEqual(@as(u8, 0), img.pixels.items[2]);
    try std.testing.expectEqual(@as(u8, 255), img.pixels.items[3]);
}
