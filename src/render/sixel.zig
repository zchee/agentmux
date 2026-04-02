const std = @import("std");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
};

/// Decoded sixel image.
pub const SixelImage = struct {
    width: u32,
    height: u32,
    pixels: []u8, // RGBA
    palette: [256]Color,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *SixelImage) void {
        self.allocator.free(self.pixels);
    }
};

/// Decode sixel data into an RGBA image.
/// Sixel format: data chars (0x3F-0x7E) encode 6 vertical pixels.
/// '#' sets color, '!' is repeat, '-' is newline (6 rows), '$' is carriage return.
pub fn decode(alloc: std.mem.Allocator, data: []const u8) !SixelImage {
    var palette: [256]Color = [_]Color{.{ .r = 0, .g = 0, .b = 0 }} ** 256;
    // Set some default palette entries
    palette[0] = .{ .r = 0, .g = 0, .b = 0 };
    palette[1] = .{ .r = 0, .g = 0, .b = 255 };
    palette[2] = .{ .r = 255, .g = 0, .b = 0 };
    palette[3] = .{ .r = 0, .g = 255, .b = 0 };
    palette[7] = .{ .r = 255, .g = 255, .b = 255 };

    // First pass: determine dimensions
    var max_x: u32 = 0;
    var max_y: u32 = 0;
    var cur_x: u32 = 0;
    var cur_y: u32 = 0;
    var i: usize = 0;

    while (i < data.len) {
        const c = data[i];
        if (c == '#') {
            // Color selector: #N or #N;Pc;Px;Py;Pz
            i += 1;
            _ = parseNumber(data, &i);
            if (i < data.len and data[i] == ';') {
                // Color definition - skip params
                while (i < data.len and data[i] != '#' and data[i] != '!' and data[i] != '-' and data[i] != '$' and !(data[i] >= 0x3F and data[i] <= 0x7E)) : (i += 1) {}
            }
        } else if (c == '!') {
            // Repeat: !N<char>
            i += 1;
            const count = parseNumber(data, &i);
            if (i < data.len and data[i] >= 0x3F and data[i] <= 0x7E) {
                cur_x += count;
                i += 1;
            }
        } else if (c == '-') {
            // Newline (next 6-pixel row)
            max_x = @max(max_x, cur_x);
            cur_x = 0;
            cur_y += 6;
            i += 1;
        } else if (c == '$') {
            // Carriage return
            max_x = @max(max_x, cur_x);
            cur_x = 0;
            i += 1;
        } else if (c >= 0x3F and c <= 0x7E) {
            // Data character
            cur_x += 1;
            i += 1;
        } else {
            i += 1;
        }
    }
    max_x = @max(max_x, cur_x);
    max_y = cur_y + 6;

    if (max_x == 0 or max_y == 0) {
        return .{
            .width = 0,
            .height = 0,
            .pixels = try alloc.alloc(u8, 0),
            .palette = palette,
            .allocator = alloc,
        };
    }

    // Allocate pixel buffer (RGBA)
    const pixel_count = max_x * max_y * 4;
    const pixels = try alloc.alloc(u8, pixel_count);
    @memset(pixels, 0);

    // Second pass: render pixels
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
                // Parse color definition: ;Pc;Px;Py;Pz
                i += 1;
                const pc = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const px = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const py = parseNumber(data, &i);
                if (i < data.len and data[i] == ';') i += 1;
                const pz = parseNumber(data, &i);
                if (pc == 2) {
                    // RGB percentages
                    palette[current_color] = .{
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
                    renderSixel(pixels, max_x, cur_x, cur_y, bits, palette[current_color]);
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
            renderSixel(pixels, max_x, cur_x, cur_y, bits, palette[current_color]);
            cur_x += 1;
            i += 1;
        } else {
            i += 1;
        }
    }

    return .{
        .width = max_x,
        .height = max_y,
        .pixels = pixels,
        .palette = palette,
        .allocator = alloc,
    };
}

fn renderSixel(pixels: []u8, stride: u32, x: u32, y: u32, bits: u6, color: Color) void {
    var bit: u3 = 0;
    while (bit < 6) : (bit += 1) {
        if ((bits >> bit) & 1 != 0) {
            const py = y + bit;
            const offset = (py * stride + x) * 4;
            if (offset + 3 < pixels.len) {
                pixels[offset] = color.r;
                pixels[offset + 1] = color.g;
                pixels[offset + 2] = color.b;
                pixels[offset + 3] = 255; // alpha
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
    // A single sixel character '?' = 0x3F - 0x3F = 0 (no pixels set)
    // '~' = 0x7E - 0x3F = 0x3F = all 6 bits set
    var img = try decode(std.testing.allocator, "~");
    defer img.deinit();
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
    try std.testing.expectEqual(@as(u32, 12), img.height); // 2 rows of 6
}
