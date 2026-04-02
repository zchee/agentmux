const std = @import("std");
const keys = @import("../terminal/keys.zig");

pub const Modifiers = keys.Modifiers;

/// Copy mode sub-state.
pub const CopyMode = enum {
    normal,
    visual,
    visual_line,
    search_forward,
    search_backward,
};

/// Actions that copy mode can emit to the caller.
pub const CopyAction = enum {
    move_cursor,
    start_selection,
    copy_selection,
    cancel,
    search_next,
    search_prev,
    scroll_up,
    scroll_down,
    page_up,
    page_down,
};

/// Copy mode state machine.
pub const CopyState = struct {
    mode: CopyMode,
    /// Cursor position in scrollback buffer.
    cx: u32,
    cy: u32,
    scroll_offset: u32,
    /// Selection anchor (set when entering visual mode).
    sel_start_x: u32,
    sel_start_y: u32,
    /// Incremental search buffer.
    search_buf: [256]u8,
    search_len: u16,
    /// True = vi bindings, false = emacs bindings.
    vi_mode: bool,
    /// Internal: waiting for second 'g' in "gg" sequence.
    pending_g: bool,

    pub fn init() CopyState {
        return .{
            .mode = .normal,
            .cx = 0,
            .cy = 0,
            .scroll_offset = 0,
            .sel_start_x = 0,
            .sel_start_y = 0,
            .search_buf = std.mem.zeroes([256]u8),
            .search_len = 0,
            .vi_mode = true,
            .pending_g = false,
        };
    }

    /// Process a key event in copy mode.
    /// Returns an action for the caller to handle, or null if the key was
    /// consumed internally (e.g. cursor movement, search input).
    pub fn handleKey(self: *CopyState, key: u21, mods: Modifiers) ?CopyAction {
        // In search mode, collect typed characters into the search buffer.
        if (self.mode == .search_forward or self.mode == .search_backward) {
            return self.handleSearchKey(key, mods);
        }

        if (self.vi_mode) {
            return self.handleViKey(key, mods);
        }
        return self.handleEmacsKey(key, mods);
    }

    fn handleSearchKey(self: *CopyState, key: u21, mods: Modifiers) ?CopyAction {
        _ = mods;
        switch (key) {
            // Enter / Escape: commit or cancel search
            '\r', '\n' => {
                self.mode = .normal;
                return .search_next;
            },
            0x1B => { // Escape
                self.search_len = 0;
                self.mode = .normal;
                return .cancel;
            },
            // Backspace
            0x7F, 0x08 => {
                if (self.search_len > 0) {
                    self.search_len -= 1;
                }
                return null;
            },
            else => {
                if (self.search_len < self.search_buf.len and key <= 0x7E) {
                    self.search_buf[self.search_len] = @truncate(key);
                    self.search_len += 1;
                }
                return null;
            },
        }
    }

    fn handleViKey(self: *CopyState, key: u21, mods: Modifiers) ?CopyAction {
        _ = mods;

        // Handle pending 'g' prefix (for "gg" = go to top).
        if (self.pending_g) {
            self.pending_g = false;
            if (key == 'g') {
                self.cy = 0;
                self.cx = 0;
                return .move_cursor;
            }
            // Not a valid 'g' sequence; fall through to handle key normally.
        }

        switch (key) {
            // Quit copy mode
            'q', 0x1B => {
                self.mode = .normal;
                return .cancel;
            },

            // Cursor movement
            'h' => {
                if (self.cx > 0) self.cx -= 1;
                return .move_cursor;
            },
            'l' => {
                self.cx += 1;
                return .move_cursor;
            },
            'j' => {
                self.cy += 1;
                return .move_cursor;
            },
            'k' => {
                if (self.cy > 0) self.cy -= 1;
                return .move_cursor;
            },

            // Word movement
            'w' => {
                self.cx += 1; // Caller advances by word; simplified position increment.
                return .move_cursor;
            },
            'b' => {
                if (self.cx > 0) self.cx -= 1;
                return .move_cursor;
            },
            'e' => {
                self.cx += 1;
                return .move_cursor;
            },

            // Line start / end
            '0' => {
                self.cx = 0;
                return .move_cursor;
            },
            '$' => {
                self.cx = std.math.maxInt(u32); // Caller clamps to line width.
                return .move_cursor;
            },

            // Go to bottom (G)
            'G' => {
                self.cy = std.math.maxInt(u32); // Caller clamps to scrollback height.
                return .move_cursor;
            },

            // 'g' prefix — wait for second character
            'g' => {
                self.pending_g = true;
                return null;
            },

            // Visual character selection
            'v' => {
                if (self.mode == .visual) {
                    self.mode = .normal;
                } else {
                    self.sel_start_x = self.cx;
                    self.sel_start_y = self.cy;
                    self.mode = .visual;
                }
                return .start_selection;
            },

            // Visual line selection
            'V' => {
                if (self.mode == .visual_line) {
                    self.mode = .normal;
                } else {
                    self.sel_start_x = 0;
                    self.sel_start_y = self.cy;
                    self.mode = .visual_line;
                }
                return .start_selection;
            },

            // Yank (copy selection)
            'y' => {
                self.mode = .normal;
                return .copy_selection;
            },

            // Search forward
            '/' => {
                self.search_len = 0;
                self.mode = .search_forward;
                return null;
            },

            // Search backward
            '?' => {
                self.search_len = 0;
                self.mode = .search_backward;
                return null;
            },

            // Next / previous search match
            'n' => return .search_next,
            'N' => return .search_prev,

            // Scrolling
            'u' => return .page_up,
            'd' => return .page_down,

            else => return null,
        }
    }

    fn handleEmacsKey(self: *CopyState, key: u21, mods: Modifiers) ?CopyAction {
        // Emacs bindings: C-n/C-p for up/down, C-f/C-b for left/right,
        // C-a/C-e for line start/end, C-g to quit, C-w to copy.
        if (mods.ctrl) {
            switch (key) {
                'g' => {
                    self.mode = .normal;
                    return .cancel;
                },
                'n' => {
                    self.cy += 1;
                    return .move_cursor;
                },
                'p' => {
                    if (self.cy > 0) self.cy -= 1;
                    return .move_cursor;
                },
                'f' => {
                    self.cx += 1;
                    return .move_cursor;
                },
                'b' => {
                    if (self.cx > 0) self.cx -= 1;
                    return .move_cursor;
                },
                'a' => {
                    self.cx = 0;
                    return .move_cursor;
                },
                'e' => {
                    self.cx = std.math.maxInt(u32);
                    return .move_cursor;
                },
                'w' => {
                    self.mode = .normal;
                    return .copy_selection;
                },
                'v' => return .page_down,
                'u' => return .page_up,
                's' => {
                    self.search_len = 0;
                    self.mode = .search_forward;
                    return null;
                },
                'r' => {
                    self.search_len = 0;
                    self.mode = .search_backward;
                    return null;
                },
                else => return null,
            }
        }

        if (mods.meta) {
            switch (key) {
                'v' => return .page_up,
                'f' => {
                    self.cx += 1;
                    return .move_cursor;
                },
                'b' => {
                    if (self.cx > 0) self.cx -= 1;
                    return .move_cursor;
                },
                '<' => {
                    self.cy = 0;
                    self.cx = 0;
                    return .move_cursor;
                },
                '>' => {
                    self.cy = std.math.maxInt(u32);
                    return .move_cursor;
                },
                else => return null,
            }
        }

        // Plain keys in emacs mode: space toggles selection.
        if (key == ' ') {
            if (self.mode == .visual) {
                self.mode = .normal;
            } else {
                self.sel_start_x = self.cx;
                self.sel_start_y = self.cy;
                self.mode = .visual;
            }
            return .start_selection;
        }

        return null;
    }

    /// Return the current search query as a slice.
    pub fn searchQuery(self: *const CopyState) []const u8 {
        return self.search_buf[0..self.search_len];
    }
};

test "copy state init" {
    const cs = CopyState.init();
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
    try std.testing.expectEqual(@as(u32, 0), cs.cx);
    try std.testing.expectEqual(@as(u32, 0), cs.cy);
    try std.testing.expect(cs.vi_mode);
}

test "vi mode cursor movement" {
    var cs = CopyState.init();

    // Move right then down
    _ = cs.handleKey('l', .{});
    _ = cs.handleKey('l', .{});
    _ = cs.handleKey('j', .{});
    try std.testing.expectEqual(@as(u32, 2), cs.cx);
    try std.testing.expectEqual(@as(u32, 1), cs.cy);

    // Move left and up
    _ = cs.handleKey('h', .{});
    _ = cs.handleKey('k', .{});
    try std.testing.expectEqual(@as(u32, 1), cs.cx);
    try std.testing.expectEqual(@as(u32, 0), cs.cy);

    // Can't go above 0
    _ = cs.handleKey('k', .{});
    try std.testing.expectEqual(@as(u32, 0), cs.cy);
}

test "vi mode line start and end" {
    var cs = CopyState.init();
    cs.cx = 10;

    const r0 = cs.handleKey('0', .{});
    try std.testing.expectEqual(CopyAction.move_cursor, r0.?);
    try std.testing.expectEqual(@as(u32, 0), cs.cx);

    const r_dollar = cs.handleKey('$', .{});
    try std.testing.expectEqual(CopyAction.move_cursor, r_dollar.?);
    try std.testing.expectEqual(std.math.maxInt(u32), cs.cx);
}

test "vi mode gg goes to top" {
    var cs = CopyState.init();
    cs.cy = 100;

    const r1 = cs.handleKey('g', .{});
    try std.testing.expect(r1 == null); // waiting for second g
    try std.testing.expect(cs.pending_g);

    const r2 = cs.handleKey('g', .{});
    try std.testing.expectEqual(CopyAction.move_cursor, r2.?);
    try std.testing.expectEqual(@as(u32, 0), cs.cy);
    try std.testing.expectEqual(@as(u32, 0), cs.cx);
    try std.testing.expect(!cs.pending_g);
}

test "vi mode G goes to bottom" {
    var cs = CopyState.init();
    const r = cs.handleKey('G', .{});
    try std.testing.expectEqual(CopyAction.move_cursor, r.?);
    try std.testing.expectEqual(std.math.maxInt(u32), cs.cy);
}

test "vi mode visual selection" {
    var cs = CopyState.init();
    cs.cx = 5;
    cs.cy = 3;

    const r = cs.handleKey('v', .{});
    try std.testing.expectEqual(CopyAction.start_selection, r.?);
    try std.testing.expectEqual(CopyMode.visual, cs.mode);
    try std.testing.expectEqual(@as(u32, 5), cs.sel_start_x);
    try std.testing.expectEqual(@as(u32, 3), cs.sel_start_y);

    // Toggle off
    const r2 = cs.handleKey('v', .{});
    try std.testing.expectEqual(CopyAction.start_selection, r2.?);
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
}

test "vi mode visual line selection" {
    var cs = CopyState.init();
    cs.cx = 5;
    cs.cy = 7;

    const r = cs.handleKey('V', .{});
    try std.testing.expectEqual(CopyAction.start_selection, r.?);
    try std.testing.expectEqual(CopyMode.visual_line, cs.mode);
    try std.testing.expectEqual(@as(u32, 0), cs.sel_start_x); // always starts at col 0
    try std.testing.expectEqual(@as(u32, 7), cs.sel_start_y);
}

test "vi mode yank returns copy_selection and resets mode" {
    var cs = CopyState.init();
    cs.mode = .visual;

    const r = cs.handleKey('y', .{});
    try std.testing.expectEqual(CopyAction.copy_selection, r.?);
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
}

test "vi mode search forward" {
    var cs = CopyState.init();

    _ = cs.handleKey('/', .{});
    try std.testing.expectEqual(CopyMode.search_forward, cs.mode);

    // Type search term
    _ = cs.handleKey('f', .{});
    _ = cs.handleKey('o', .{});
    _ = cs.handleKey('o', .{});
    try std.testing.expectEqualStrings("foo", cs.searchQuery());

    // Backspace removes last char
    _ = cs.handleKey(0x7F, .{});
    try std.testing.expectEqualStrings("fo", cs.searchQuery());

    // Enter commits
    const r = cs.handleKey('\r', .{});
    try std.testing.expectEqual(CopyAction.search_next, r.?);
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
}

test "vi mode search escape cancels" {
    var cs = CopyState.init();
    _ = cs.handleKey('/', .{});
    _ = cs.handleKey('a', .{});
    const r = cs.handleKey(0x1B, .{});
    try std.testing.expectEqual(CopyAction.cancel, r.?);
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
    try std.testing.expectEqual(@as(u16, 0), cs.search_len);
}

test "vi mode next and prev search" {
    var cs = CopyState.init();
    try std.testing.expectEqual(CopyAction.search_next, cs.handleKey('n', .{}).?);
    try std.testing.expectEqual(CopyAction.search_prev, cs.handleKey('N', .{}).?);
}

test "vi mode quit" {
    var cs = CopyState.init();
    const r = cs.handleKey('q', .{});
    try std.testing.expectEqual(CopyAction.cancel, r.?);
    try std.testing.expectEqual(CopyMode.normal, cs.mode);
}

test "emacs mode ctrl movement" {
    var cs = CopyState.init();
    cs.vi_mode = false;

    _ = cs.handleKey('f', .{ .ctrl = true }); // C-f: right
    _ = cs.handleKey('f', .{ .ctrl = true });
    try std.testing.expectEqual(@as(u32, 2), cs.cx);

    _ = cs.handleKey('b', .{ .ctrl = true }); // C-b: left
    try std.testing.expectEqual(@as(u32, 1), cs.cx);

    _ = cs.handleKey('n', .{ .ctrl = true }); // C-n: down
    try std.testing.expectEqual(@as(u32, 1), cs.cy);

    _ = cs.handleKey('p', .{ .ctrl = true }); // C-p: up
    try std.testing.expectEqual(@as(u32, 0), cs.cy);

    _ = cs.handleKey('e', .{ .ctrl = true }); // C-e: end of line
    try std.testing.expectEqual(std.math.maxInt(u32), cs.cx);

    _ = cs.handleKey('a', .{ .ctrl = true }); // C-a: start of line
    try std.testing.expectEqual(@as(u32, 0), cs.cx);
}

test "emacs mode ctrl-g quits" {
    var cs = CopyState.init();
    cs.vi_mode = false;
    const r = cs.handleKey('g', .{ .ctrl = true });
    try std.testing.expectEqual(CopyAction.cancel, r.?);
}

test "emacs mode space toggles selection" {
    var cs = CopyState.init();
    cs.vi_mode = false;
    cs.cx = 3;
    cs.cy = 2;

    const r = cs.handleKey(' ', .{});
    try std.testing.expectEqual(CopyAction.start_selection, r.?);
    try std.testing.expectEqual(CopyMode.visual, cs.mode);
    try std.testing.expectEqual(@as(u32, 3), cs.sel_start_x);
}
