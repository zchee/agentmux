const std = @import("std");
const Terminfo = @import("terminfo.zig").Terminfo;

/// Terminal feature flags detected from TERM and terminfo.
pub const Features = packed struct(u32) {
    color_256: bool = false,
    color_rgb: bool = false,
    title: bool = false,
    clipboard: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    mouse_sgr: bool = false,
    mouse_urxvt: bool = false,
    focus: bool = false,
    bracketed_paste: bool = false,
    extended_keys: bool = false,
    sixel: bool = false,
    osc7: bool = false,
    hyperlinks: bool = false,
    synchronized_output: bool = false,
    _padding: u17 = 0,
};

/// Detect terminal features from the TERM environment variable.
pub fn detectFromTerm(term: []const u8) Features {
    var f = Features{};

    // Check for known terminal types that support extended features
    if (containsAny(term, &.{ "256color", "256colour" })) {
        f.color_256 = true;
    }

    if (containsAny(term, &.{ "xterm", "rxvt", "screen", "tmux", "alacritty", "kitty", "foot", "wezterm", "ghostty" })) {
        f.title = true;
        f.mouse_sgr = true;
        f.focus = true;
        f.bracketed_paste = true;
    }

    if (containsAny(term, &.{ "kitty", "alacritty", "wezterm", "foot", "ghostty" })) {
        f.color_rgb = true;
        f.strikethrough = true;
        f.overline = true;
        f.extended_keys = true;
        f.hyperlinks = true;
    }

    if (containsAny(term, &.{ "xterm-direct", "xterm-truecolor" })) {
        f.color_rgb = true;
    }

    if (containsAny(term, &.{"kitty"})) {
        f.clipboard = true;
    }

    if (containsAny(term, &.{ "xterm-256color", "screen-256color", "tmux-256color" })) {
        f.color_256 = true;
    }

    return f;
}

/// Detect features using terminfo database.
pub fn detectFromTerminfo(tinfo: *const Terminfo) Features {
    var f = Features{};

    // Check color count
    if (tinfo.getNum("colors")) |colors| {
        if (colors >= 256) f.color_256 = true;
        if (colors >= 16777216) f.color_rgb = true;
    }

    // Check for truecolor via Tc or RGB terminfo extension
    if (tinfo.getFlag("Tc") or tinfo.getFlag("RGB")) {
        f.color_rgb = true;
    }

    // Check for title support
    if (tinfo.getString("tsl") != null) {
        f.title = true;
    }

    return f;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

test "detect from term" {
    const f = detectFromTerm("xterm-256color");
    try std.testing.expect(f.color_256);
    try std.testing.expect(f.title);
    try std.testing.expect(f.mouse_sgr);
    try std.testing.expect(f.bracketed_paste);
}

test "detect kitty" {
    const f = detectFromTerm("xterm-kitty");
    try std.testing.expect(f.color_rgb);
    try std.testing.expect(f.hyperlinks);
    try std.testing.expect(f.clipboard);
}
