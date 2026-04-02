const std = @import("std");

/// Key modifiers.
pub const Modifiers = packed struct(u8) {
    ctrl: bool = false,
    meta: bool = false,
    shift: bool = false,
    _padding: u5 = 0,

    pub const none: Modifiers = .{};
};

/// Special key codes (non-printable keys).
pub const SpecialKey = enum(u16) {
    // Function keys
    f1 = 0x100,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,

    // Navigation
    up = 0x200,
    down,
    left,
    right,
    home,
    end,
    insert,
    delete,
    page_up,
    page_down,

    // Editing
    backspace = 0x300,
    tab,
    enter,
    escape,

    // Mouse events
    mouse = 0x400,

    // Paste
    paste_start = 0x500,
    paste_end,
};

/// A key event.
pub const KeyEvent = union(enum) {
    /// A printable Unicode character.
    char: struct {
        codepoint: u21,
        mods: Modifiers,
    },
    /// A special (non-printable) key.
    special: struct {
        key: SpecialKey,
        mods: Modifiers,
    },
    /// A mouse event.
    mouse: MouseEvent,
};

/// Mouse event data.
pub const MouseEvent = struct {
    x: u16,
    y: u16,
    button: MouseButton,
    mods: Modifiers,
    kind: MouseKind,
};

pub const MouseButton = enum(u3) {
    left = 0,
    middle = 1,
    right = 2,
    release = 3,
    wheel_up = 4,
    wheel_down = 5,
    none = 7,
};

pub const MouseKind = enum(u2) {
    press = 0,
    release = 1,
    drag = 2,
    motion = 3,
};

/// Parse xterm-style key sequences from CSI parameters.
/// CSI parameters for modified keys use the form: CSI 1;mod final
/// where mod = 1 + modifier_bits (shift=1, alt=2, ctrl=4).
pub fn modifiersFromCSIParam(param: u16) Modifiers {
    if (param < 2) return .{};
    const bits = param - 1;
    return .{
        .shift = (bits & 1) != 0,
        .meta = (bits & 2) != 0,
        .ctrl = (bits & 4) != 0,
    };
}

/// Parse a CSI cursor key final byte to a SpecialKey.
pub fn cursorKeyFromFinal(final: u8) ?SpecialKey {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        else => null,
    };
}

/// Parse a CSI ~ sequence parameter to a SpecialKey.
pub fn tildeKeyFromParam(param: u16) ?SpecialKey {
    return switch (param) {
        1 => .home,
        2 => .insert,
        3 => .delete,
        4 => .end,
        5 => .page_up,
        6 => .page_down,
        11 => .f1,
        12 => .f2,
        13 => .f3,
        14 => .f4,
        15 => .f5,
        17 => .f6,
        18 => .f7,
        19 => .f8,
        20 => .f9,
        21 => .f10,
        23 => .f11,
        24 => .f12,
        200 => .paste_start,
        201 => .paste_end,
        else => null,
    };
}

/// Parse SGR mouse encoding: CSI < button ; x ; y M/m
pub fn parseSGRMouse(params: []const u16, param_count: usize, final: u8) ?MouseEvent {
    if (param_count < 3) return null;
    const button_bits = params[0];
    const x = params[1];
    const y = params[2];

    const button: MouseButton = switch (button_bits & 0x3) {
        0 => .left,
        1 => .middle,
        2 => .right,
        3 => .release,
        else => .none,
    };

    const kind: MouseKind = if (final == 'm')
        .release
    else if (button_bits & 32 != 0)
        .drag
    else if (button_bits & 64 != 0)
        .motion
    else
        .press;

    const mods = Modifiers{
        .shift = (button_bits & 4) != 0,
        .meta = (button_bits & 8) != 0,
        .ctrl = (button_bits & 16) != 0,
    };

    return .{
        .x = if (x > 0) x - 1 else 0,
        .y = if (y > 0) y - 1 else 0,
        .button = button,
        .mods = mods,
        .kind = kind,
    };
}

test "modifiers from CSI param" {
    const none = modifiersFromCSIParam(1);
    try std.testing.expect(!none.shift and !none.ctrl and !none.meta);

    const shift = modifiersFromCSIParam(2);
    try std.testing.expect(shift.shift);

    const ctrl_alt = modifiersFromCSIParam(7); // 1 + 2 + 4
    try std.testing.expect(ctrl_alt.meta and ctrl_alt.ctrl);
}

test "cursor key from final" {
    try std.testing.expectEqual(SpecialKey.up, cursorKeyFromFinal('A').?);
    try std.testing.expectEqual(SpecialKey.down, cursorKeyFromFinal('B').?);
    try std.testing.expect(cursorKeyFromFinal('Z') == null);
}

test "tilde key from param" {
    try std.testing.expectEqual(SpecialKey.home, tildeKeyFromParam(1).?);
    try std.testing.expectEqual(SpecialKey.f5, tildeKeyFromParam(15).?);
    try std.testing.expectEqual(SpecialKey.paste_start, tildeKeyFromParam(200).?);
}
