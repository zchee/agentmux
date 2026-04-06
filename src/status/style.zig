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

fn normalizeSpec(spec: []const u8) []const u8 {
    var remaining = spec;
    if (std.mem.startsWith(u8, remaining, "#[")) {
        remaining = remaining[2..];
        if (remaining.len > 0 and remaining[remaining.len - 1] == ']') {
            remaining = remaining[0 .. remaining.len - 1];
        }
    }
    return remaining;
}

fn applyParts(style: *Style, spec: []const u8) void {
    var iter = std.mem.splitScalar(u8, normalizeSpec(spec), ',');
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        var cleaned = trimmed;
        while (cleaned.len > 0 and cleaned[cleaned.len - 1] == '#') {
            cleaned = cleaned[0 .. cleaned.len - 1];
        }
        if (cleaned.len == 0) continue;

        if (std.mem.startsWith(u8, cleaned, "fg=")) {
            if (colour.Colour.parse(cleaned[3..])) |c| {
                style.fg = c;
            }
        } else if (std.mem.startsWith(u8, cleaned, "bg=")) {
            if (colour.Colour.parse(cleaned[3..])) |c| {
                style.bg = c;
            }
        } else if (std.mem.eql(u8, cleaned, "bold")) {
            style.attrs.bold = true;
        } else if (std.mem.eql(u8, cleaned, "dim")) {
            style.attrs.dim = true;
        } else if (std.mem.eql(u8, cleaned, "italics") or std.mem.eql(u8, cleaned, "italic")) {
            style.attrs.italic = true;
        } else if (std.mem.eql(u8, cleaned, "underscore") or std.mem.eql(u8, cleaned, "underline")) {
            style.attrs.underline = true;
        } else if (std.mem.eql(u8, cleaned, "blink")) {
            style.attrs.blink = true;
        } else if (std.mem.eql(u8, cleaned, "reverse")) {
            style.attrs.reverse = true;
        } else if (std.mem.eql(u8, cleaned, "hidden")) {
            style.attrs.hidden = true;
        } else if (std.mem.eql(u8, cleaned, "strikethrough")) {
            style.attrs.strikethrough = true;
        } else if (std.mem.eql(u8, cleaned, "overline")) {
            style.attrs.overline = true;
        } else if (std.mem.eql(u8, cleaned, "default") or std.mem.eql(u8, cleaned, "none")) {
            style.* = Style.default;
        } else if (std.mem.eql(u8, cleaned, "nobold")) {
            style.attrs.bold = false;
        } else if (std.mem.eql(u8, cleaned, "nodim")) {
            style.attrs.dim = false;
        } else if (std.mem.eql(u8, cleaned, "noitalics")) {
            style.attrs.italic = false;
        } else if (std.mem.eql(u8, cleaned, "nounderscore")) {
            style.attrs.underline = false;
        } else if (std.mem.eql(u8, cleaned, "noblink")) {
            style.attrs.blink = false;
        } else if (std.mem.eql(u8, cleaned, "noreverse")) {
            style.attrs.reverse = false;
        } else if (std.mem.eql(u8, cleaned, "nohidden")) {
            style.attrs.hidden = false;
        } else if (std.mem.eql(u8, cleaned, "nostrikethrough")) {
            style.attrs.strikethrough = false;
        } else if (std.mem.eql(u8, cleaned, "nooverline")) {
            style.attrs.overline = false;
        }
    }
}

/// Parse a tmux-style string.
/// Formats: "fg=red,bg=blue,bold" or "fg=colour196,bold,italics"
pub fn parse(s: []const u8) Style {
    var style = Style.default;
    applyParts(&style, s);
    return style;
}

/// Apply a tmux-style fragment on top of an existing style.
pub fn apply(base: Style, spec: []const u8) Style {
    var style = base;
    applyParts(&style, spec);
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

test "apply keeps existing colours for attribute-only fragments" {
    const base = Style{
        .fg = colour.Colour.green,
        .bg = colour.Colour.black,
        .attrs = .{},
    };
    const s = apply(base, "#[bold]");
    try std.testing.expectEqual(colour.Colour.green, s.fg);
    try std.testing.expectEqual(colour.Colour.black, s.bg);
    try std.testing.expect(s.attrs.bold);
}

test "apply accepts tmux escaped commas inside inline fragments" {
    const s = apply(Style.default, "#[fg=#666361#,bold#,bg=colour238]");
    try std.testing.expectEqual(colour.Colour{ .rgb = .{ .r = 0x66, .g = 0x63, .b = 0x61 } }, s.fg);
    try std.testing.expectEqual(colour.Colour{ .palette = 238 }, s.bg);
    try std.testing.expect(s.attrs.bold);
}
