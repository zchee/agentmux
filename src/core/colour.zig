const std = @import("std");

/// Colour representation supporting named, 256-color palette, and RGB.
pub const Colour = union(enum) {
    default,
    /// Standard 8 terminal colors (0-7) and bright variants (8-15).
    palette: u8,
    /// 24-bit RGB color.
    rgb: RGB,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };

    /// Named color constants matching tmux's color names.
    pub const black: Colour = .{ .palette = 0 };
    pub const red: Colour = .{ .palette = 1 };
    pub const green: Colour = .{ .palette = 2 };
    pub const yellow: Colour = .{ .palette = 3 };
    pub const blue: Colour = .{ .palette = 4 };
    pub const magenta: Colour = .{ .palette = 5 };
    pub const cyan: Colour = .{ .palette = 6 };
    pub const white: Colour = .{ .palette = 7 };
    pub const bright_black: Colour = .{ .palette = 8 };
    pub const bright_red: Colour = .{ .palette = 9 };
    pub const bright_green: Colour = .{ .palette = 10 };
    pub const bright_yellow: Colour = .{ .palette = 11 };
    pub const bright_blue: Colour = .{ .palette = 12 };
    pub const bright_magenta: Colour = .{ .palette = 13 };
    pub const bright_cyan: Colour = .{ .palette = 14 };
    pub const bright_white: Colour = .{ .palette = 15 };

    /// Parse a colour from a tmux-style string.
    /// Supports: "default", "black".."white", "colour0".."colour255",
    /// "#rrggbb", "brightred", etc.
    pub fn parse(s: []const u8) ?Colour {
        if (std.mem.eql(u8, s, "default")) return .default;

        // Named colors
        const named = [_]struct { name: []const u8, colour: Colour }{
            .{ .name = "black", .colour = black },
            .{ .name = "red", .colour = red },
            .{ .name = "green", .colour = green },
            .{ .name = "yellow", .colour = yellow },
            .{ .name = "blue", .colour = blue },
            .{ .name = "magenta", .colour = magenta },
            .{ .name = "cyan", .colour = cyan },
            .{ .name = "white", .colour = white },
            .{ .name = "brightblack", .colour = bright_black },
            .{ .name = "brightred", .colour = bright_red },
            .{ .name = "brightgreen", .colour = bright_green },
            .{ .name = "brightyellow", .colour = bright_yellow },
            .{ .name = "brightblue", .colour = bright_blue },
            .{ .name = "brightmagenta", .colour = bright_magenta },
            .{ .name = "brightcyan", .colour = bright_cyan },
            .{ .name = "brightwhite", .colour = bright_white },
        };
        for (named) |n| {
            if (std.ascii.eqlIgnoreCase(s, n.name)) return n.colour;
        }

        // colour0..colour255
        if (std.mem.startsWith(u8, s, "colour")) {
            const num = std.fmt.parseInt(u8, s[6..], 10) catch return null;
            return .{ .palette = num };
        }
        // color0..color255 (US spelling)
        if (std.mem.startsWith(u8, s, "color")) {
            const num = std.fmt.parseInt(u8, s[5..], 10) catch return null;
            return .{ .palette = num };
        }

        // #rrggbb
        if (s.len == 7 and s[0] == '#') {
            const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
            const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
            const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
            return .{ .rgb = .{ .r = r, .g = g, .b = b } };
        }

        return null;
    }

    /// Convert to SGR parameter for terminal output.
    /// Returns the parameter value for \e[38;... (foreground) or \e[48;... (background).
    pub fn toSgr(self: Colour, writer: anytype, is_fg: bool) !void {
        const base: u8 = if (is_fg) 38 else 48;
        switch (self) {
            .default => {
                try writer.print("{d}", .{if (is_fg) @as(u8, 39) else @as(u8, 49)});
            },
            .palette => |idx| {
                if (idx < 8) {
                    try writer.print("{d}", .{(if (is_fg) @as(u8, 30) else @as(u8, 40)) + idx});
                } else if (idx < 16) {
                    try writer.print("{d}", .{(if (is_fg) @as(u8, 90) else @as(u8, 100)) + idx - 8});
                } else {
                    try writer.print("{d};5;{d}", .{ base, idx });
                }
            },
            .rgb => |c| {
                try writer.print("{d};2;{d};{d};{d}", .{ base, c.r, c.g, c.b });
            },
        }
    }
};

/// Cell attributes (bold, underline, etc.).
pub const Attributes = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    reverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    _padding: u7 = 0,

    pub const none: Attributes = .{};
};

test "parse named colours" {
    const c = Colour.parse("red").?;
    try std.testing.expectEqual(Colour{ .palette = 1 }, c);
}

test "parse rgb" {
    const c = Colour.parse("#ff8000").?;
    try std.testing.expectEqual(Colour{ .rgb = .{ .r = 0xff, .g = 0x80, .b = 0x00 } }, c);
}

test "parse colour index" {
    const c = Colour.parse("colour196").?;
    try std.testing.expectEqual(Colour{ .palette = 196 }, c);
}

test "parse default" {
    try std.testing.expectEqual(Colour.default, Colour.parse("default").?);
}
