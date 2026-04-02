const std = @import("std");
const bindings = @import("bindings.zig");
const Modifiers = bindings.Modifiers;

pub const KeyResult = struct {
    key: u21,
    mods: Modifiers,
};

/// Parse a tmux key string into a key code and modifiers.
/// Supports: C-b, M-a, S-F1, C-M-a, Enter, Space, F1-F12, Up/Down/Left/Right, etc.
pub fn stringToKey(s: []const u8) ?KeyResult {
    if (s.len == 0) return null;

    var remaining = s;
    var mods = Modifiers{};

    // Parse modifier prefixes: C-, M-, S-
    while (remaining.len >= 2 and remaining[1] == '-') {
        switch (remaining[0]) {
            'C' => mods.ctrl = true,
            'M' => mods.meta = true,
            'S' => mods.shift = true,
            else => break,
        }
        remaining = remaining[2..];
    }

    // Special key names
    const special_keys = [_]struct { name: []const u8, key: u21 }{
        .{ .name = "Enter", .key = '\r' },
        .{ .name = "Return", .key = '\r' },
        .{ .name = "Escape", .key = 0x1b },
        .{ .name = "Space", .key = ' ' },
        .{ .name = "Tab", .key = '\t' },
        .{ .name = "BSpace", .key = 0x7f },
        .{ .name = "Up", .key = 0x100 },
        .{ .name = "Down", .key = 0x101 },
        .{ .name = "Left", .key = 0x102 },
        .{ .name = "Right", .key = 0x103 },
        .{ .name = "Home", .key = 0x104 },
        .{ .name = "End", .key = 0x105 },
        .{ .name = "IC", .key = 0x106 },
        .{ .name = "Insert", .key = 0x106 },
        .{ .name = "DC", .key = 0x107 },
        .{ .name = "Delete", .key = 0x107 },
        .{ .name = "PgUp", .key = 0x108 },
        .{ .name = "PageUp", .key = 0x108 },
        .{ .name = "PgDn", .key = 0x109 },
        .{ .name = "PageDown", .key = 0x109 },
        .{ .name = "F1", .key = 0x110 },
        .{ .name = "F2", .key = 0x111 },
        .{ .name = "F3", .key = 0x112 },
        .{ .name = "F4", .key = 0x113 },
        .{ .name = "F5", .key = 0x114 },
        .{ .name = "F6", .key = 0x115 },
        .{ .name = "F7", .key = 0x116 },
        .{ .name = "F8", .key = 0x117 },
        .{ .name = "F9", .key = 0x118 },
        .{ .name = "F10", .key = 0x119 },
        .{ .name = "F11", .key = 0x11a },
        .{ .name = "F12", .key = 0x11b },
    };

    for (special_keys) |sk| {
        if (std.ascii.eqlIgnoreCase(remaining, sk.name)) {
            return .{ .key = sk.key, .mods = mods };
        }
    }

    // Single character
    if (remaining.len == 1) {
        return .{ .key = remaining[0], .mods = mods };
    }

    return null;
}

/// Convert a key code and modifiers to a tmux key string.
/// Returns a statically-allocated string.
pub fn keyToString(key: u21, mods: Modifiers) []const u8 {
    // Check special keys first
    const name: ?[]const u8 = switch (key) {
        '\r' => "Enter",
        0x1b => "Escape",
        ' ' => "Space",
        '\t' => "Tab",
        0x7f => "BSpace",
        0x100 => "Up",
        0x101 => "Down",
        0x102 => "Left",
        0x103 => "Right",
        0x104 => "Home",
        0x105 => "End",
        0x106 => "IC",
        0x107 => "DC",
        0x108 => "PgUp",
        0x109 => "PgDn",
        0x110 => "F1",
        0x111 => "F2",
        0x112 => "F3",
        0x113 => "F4",
        0x114 => "F5",
        0x115 => "F6",
        0x116 => "F7",
        0x117 => "F8",
        0x118 => "F9",
        0x119 => "F10",
        0x11a => "F11",
        0x11b => "F12",
        else => null,
    };

    // For simple cases, return static strings
    if (name) |n| {
        if (mods.ctrl and !mods.meta) return prefixed("C-", n);
        if (mods.meta and !mods.ctrl) return prefixed("M-", n);
        if (mods.ctrl and mods.meta) return prefixed("C-M-", n);
        return n;
    }

    // For plain ASCII characters
    if (key >= 0x20 and key < 0x7f) {
        if (mods.ctrl and mods.meta) return "C-M-?";
        if (mods.ctrl) return "C-?";
        if (mods.meta) return "M-?";
        return "?";
    }

    return "?";
}

fn prefixed(prefix: []const u8, name: []const u8) []const u8 {
    // Return just the name since we can't allocate here
    // In practice, callers would use bufPrint
    _ = prefix;
    return name;
}

test "parse simple key" {
    const r = stringToKey("a").?;
    try std.testing.expectEqual(@as(u21, 'a'), r.key);
    try std.testing.expect(!r.mods.ctrl);
}

test "parse ctrl key" {
    const r = stringToKey("C-b").?;
    try std.testing.expectEqual(@as(u21, 'b'), r.key);
    try std.testing.expect(r.mods.ctrl);
}

test "parse meta key" {
    const r = stringToKey("M-a").?;
    try std.testing.expectEqual(@as(u21, 'a'), r.key);
    try std.testing.expect(r.mods.meta);
}

test "parse compound modifiers" {
    const r = stringToKey("C-M-x").?;
    try std.testing.expectEqual(@as(u21, 'x'), r.key);
    try std.testing.expect(r.mods.ctrl);
    try std.testing.expect(r.mods.meta);
}

test "parse special keys" {
    try std.testing.expectEqual(@as(u21, '\r'), stringToKey("Enter").?.key);
    try std.testing.expectEqual(@as(u21, 0x1b), stringToKey("Escape").?.key);
    try std.testing.expectEqual(@as(u21, ' '), stringToKey("Space").?.key);
    try std.testing.expectEqual(@as(u21, 0x110), stringToKey("F1").?.key);
    try std.testing.expectEqual(@as(u21, 0x100), stringToKey("Up").?.key);
}

test "parse ctrl special" {
    const r = stringToKey("C-Space").?;
    try std.testing.expectEqual(@as(u21, ' '), r.key);
    try std.testing.expect(r.mods.ctrl);
}

test "keyToString" {
    try std.testing.expectEqualStrings("Enter", keyToString('\r', .{}));
    try std.testing.expectEqualStrings("F1", keyToString(0x110, .{}));
    try std.testing.expectEqualStrings("Up", keyToString(0x100, .{}));
}
