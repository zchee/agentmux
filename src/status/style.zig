const std = @import("std");
const colour = @import("../core/colour.zig");

/// A parsed style with foreground, background, and attributes.
pub const Style = struct {
    fg: colour.Colour,
    bg: colour.Colour,
    attrs: colour.Attributes,

    pub const default: Style = .{
        .fg = .default,
        .bg = .default,
        .attrs = .{},
    };
};

/// Parse a tmux-style string.
/// Formats: "fg=red,bg=blue,bold" or "fg=colour196,bold,italics"
pub fn parse(s: []const u8) Style {
    var style = Style.default;
    var remaining = s;

    // Strip #[ prefix and ] suffix if present
    if (std.mem.startsWith(u8, remaining, "#[")) {
        remaining = remaining[2..];
        if (remaining.len > 0 and remaining[remaining.len - 1] == ']') {
            remaining = remaining[0 .. remaining.len - 1];
        }
    }

    var iter = std.mem.splitScalar(u8, remaining, ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;

        if (std.mem.startsWith(u8, trimmed, "fg=")) {
            if (colour.Colour.parse(trimmed[3..])) |c| {
                style.fg = c;
            }
        } else if (std.mem.startsWith(u8, trimmed, "bg=")) {
            if (colour.Colour.parse(trimmed[3..])) |c| {
                style.bg = c;
            }
        } else if (std.mem.eql(u8, trimmed, "bold")) {
            style.attrs.bold = true;
        } else if (std.mem.eql(u8, trimmed, "dim")) {
            style.attrs.dim = true;
        } else if (std.mem.eql(u8, trimmed, "italics") or std.mem.eql(u8, trimmed, "italic")) {
            style.attrs.italic = true;
        } else if (std.mem.eql(u8, trimmed, "underscore") or std.mem.eql(u8, trimmed, "underline")) {
            style.attrs.underline = true;
        } else if (std.mem.eql(u8, trimmed, "blink")) {
            style.attrs.blink = true;
        } else if (std.mem.eql(u8, trimmed, "reverse")) {
            style.attrs.reverse = true;
        } else if (std.mem.eql(u8, trimmed, "hidden")) {
            style.attrs.hidden = true;
        } else if (std.mem.eql(u8, trimmed, "strikethrough")) {
            style.attrs.strikethrough = true;
        } else if (std.mem.eql(u8, trimmed, "overline")) {
            style.attrs.overline = true;
        } else if (std.mem.eql(u8, trimmed, "default") or std.mem.eql(u8, trimmed, "none")) {
            style = Style.default;
        } else if (std.mem.eql(u8, trimmed, "nobold")) {
            style.attrs.bold = false;
        } else if (std.mem.eql(u8, trimmed, "nodim")) {
            style.attrs.dim = false;
        } else if (std.mem.eql(u8, trimmed, "noitalics")) {
            style.attrs.italic = false;
        } else if (std.mem.eql(u8, trimmed, "nounderscore")) {
            style.attrs.underline = false;
        } else if (std.mem.eql(u8, trimmed, "noblink")) {
            style.attrs.blink = false;
        } else if (std.mem.eql(u8, trimmed, "noreverse")) {
            style.attrs.reverse = false;
        }
    }

    return style;
}

test "parse basic style" {
    const s = parse("fg=red,bg=blue,bold");
    try std.testing.expectEqual(colour.Colour.red, s.fg);
    try std.testing.expectEqual(colour.Colour.blue, s.bg);
    try std.testing.expect(s.attrs.bold);
    try std.testing.expect(!s.attrs.italic);
}

test "parse with brackets" {
    const s = parse("#[fg=green,italics]");
    try std.testing.expectEqual(colour.Colour.green, s.fg);
    try std.testing.expect(s.attrs.italic);
}

test "parse colour index" {
    const s = parse("fg=colour196");
    try std.testing.expectEqual(colour.Colour{ .palette = 196 }, s.fg);
}

test "parse default" {
    const s = parse("default");
    try std.testing.expectEqual(colour.Colour.default, s.fg);
    try std.testing.expectEqual(colour.Colour.default, s.bg);
}
