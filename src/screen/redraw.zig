const std = @import("std");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const output_mod = @import("../terminal/output.zig");
const colour = @import("../core/colour.zig");

const Cell = grid_mod.Cell;
const Screen = screen_mod.Screen;
const Output = output_mod.Output;

/// Tracks which lines need redrawing.
pub const DirtyTracker = struct {
    dirty: []bool,
    force_full: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, rows: u32) !DirtyTracker {
        const dirty = try alloc.alloc(bool, rows);
        @memset(dirty, true); // initially everything is dirty
        return .{
            .dirty = dirty,
            .force_full = true,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *DirtyTracker) void {
        self.allocator.free(self.dirty);
    }

    pub fn markDirty(self: *DirtyTracker, y: u32) void {
        if (y < self.dirty.len) self.dirty[y] = true;
    }

    pub fn markAllDirty(self: *DirtyTracker) void {
        @memset(self.dirty, true);
        self.force_full = true;
    }

    pub fn isDirty(self: *const DirtyTracker, y: u32) bool {
        if (self.force_full) return true;
        if (y >= self.dirty.len) return false;
        return self.dirty[y];
    }

    pub fn clearDirty(self: *DirtyTracker) void {
        @memset(self.dirty, false);
        self.force_full = false;
    }

    pub fn resize(self: *DirtyTracker, new_rows: u32) !void {
        const new_dirty = try self.allocator.alloc(bool, new_rows);
        @memset(new_dirty, true);
        self.allocator.free(self.dirty);
        self.dirty = new_dirty;
        self.force_full = true;
    }
};

/// Redraw dirty lines from screen to output.
pub fn redraw(tracker: *DirtyTracker, scr: *Screen, out: *Output) void {
    var cur_fg: colour.Colour = .default;
    var cur_bg: colour.Colour = .default;
    var cur_attrs: colour.Attributes = .{};

    // Reset attributes at start
    out.attrReset();

    var y: u32 = 0;
    while (y < scr.grid.rows) : (y += 1) {
        if (!tracker.isDirty(y)) continue;

        out.cursorTo(0, y);
        const line = scr.grid.getLine(y);

        var x: u32 = 0;
        while (x < scr.grid.cols) : (x += 1) {
            const cell = &line.cells[x];

            // Skip empty cells (width 0, used for wide char continuation)
            if (cell.width == 0 and cell.codepoint == 0) {
                continue;
            }

            // Update attributes if changed
            if (@as(u16, @bitCast(cell.attrs)) != @as(u16, @bitCast(cur_attrs))) {
                out.attrReset();
                out.setAttrs(cell.attrs);
                cur_fg = .default;
                cur_bg = .default;
                cur_attrs = cell.attrs;
            }

            // Update colors if changed
            if (!colourEql(cell.fg, cur_fg)) {
                out.setFg(cell.fg);
                cur_fg = cell.fg;
            }
            if (!colourEql(cell.bg, cur_bg)) {
                out.setBg(cell.bg);
                cur_bg = cell.bg;
            }

            // Write character
            if (cell.codepoint >= 0x20) {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.codepoint, &utf8_buf) catch 1;
                out.writeBytes(utf8_buf[0..len]);
            } else {
                out.writeBytes(" ");
            }
        }

        // Clear to end of line
        out.clearToEol();
    }

    // Position cursor
    out.cursorTo(scr.cx, scr.cy);

    // Show/hide cursor and set cursor style
    if (scr.mode.cursor_visible) {
        out.showCursor();
        out.setCursorStyle(@intFromEnum(scr.cstyle));
    } else {
        out.hideCursor();
    }

    out.flush();
    tracker.clearDirty();
}

fn colourEql(a: colour.Colour, b: colour.Colour) bool {
    return switch (a) {
        .default => switch (b) {
            .default => true,
            else => false,
        },
        .palette => |pa| switch (b) {
            .palette => |pb| pa == pb,
            else => false,
        },
        .rgb => |ra| switch (b) {
            .rgb => |rb| ra.r == rb.r and ra.g == rb.g and ra.b == rb.b,
            else => false,
        },
    };
}

/// Redraw dirty lines from screen to output at a given offset within a larger composed view.
pub fn redrawAt(tracker: *DirtyTracker, scr: *Screen, out: *Output, xoff: u32, yoff: u32) void {
    var cur_fg: colour.Colour = .default;
    var cur_bg: colour.Colour = .default;
    var cur_attrs: colour.Attributes = .{};

    var y: u32 = 0;
    while (y < scr.grid.rows) : (y += 1) {
        if (!tracker.isDirty(y)) continue;

        out.cursorTo(xoff, yoff + y);
        const line = scr.grid.getLine(y);

        var x: u32 = 0;
        while (x < scr.grid.cols) : (x += 1) {
            const cell = &line.cells[x];

            if (cell.width == 0 and cell.codepoint == 0) continue;

            if (@as(u16, @bitCast(cell.attrs)) != @as(u16, @bitCast(cur_attrs))) {
                out.attrReset();
                out.setAttrs(cell.attrs);
                cur_fg = .default;
                cur_bg = .default;
                cur_attrs = cell.attrs;
            }

            if (!colourEql(cell.fg, cur_fg)) {
                out.setFg(cell.fg);
                cur_fg = cell.fg;
            }
            if (!colourEql(cell.bg, cur_bg)) {
                out.setBg(cell.bg);
                cur_bg = cell.bg;
            }

            if (cell.codepoint >= 0x20) {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.codepoint, &utf8_buf) catch 1;
                out.writeBytes(utf8_buf[0..len]);
            } else {
                out.writeBytes(" ");
            }
        }
    }

    tracker.clearDirty();
}

/// Draw a vertical border line at column x from top_y to bottom_y inclusive.
pub fn drawVerticalBorder(out: *Output, x: u32, top_y: u32, bottom_y: u32) void {
    out.attrReset();
    var y = top_y;
    while (y <= bottom_y) : (y += 1) {
        out.cursorTo(x, y);
        out.writeBytes("\xe2\x94\x82"); // U+2502 vertical line
    }
}

/// Draw a horizontal border line at row y from left_x to right_x inclusive.
pub fn drawHorizontalBorder(out: *Output, y: u32, left_x: u32, right_x: u32) void {
    out.attrReset();
    out.cursorTo(left_x, y);
    var x = left_x;
    while (x <= right_x) : (x += 1) {
        out.writeBytes("\xe2\x94\x80"); // U+2500 horizontal line
    }
}

test "dirty tracker" {
    var tracker = try DirtyTracker.init(std.testing.allocator, 24);
    defer tracker.deinit();

    // Initially all dirty
    try std.testing.expect(tracker.isDirty(0));
    try std.testing.expect(tracker.isDirty(23));

    tracker.clearDirty();
    try std.testing.expect(!tracker.isDirty(0));

    tracker.markDirty(5);
    try std.testing.expect(tracker.isDirty(5));
    try std.testing.expect(!tracker.isDirty(0));
}

test "dirty tracker resize" {
    var tracker = try DirtyTracker.init(std.testing.allocator, 10);
    defer tracker.deinit();

    tracker.clearDirty();
    try tracker.resize(20);
    // After resize, all should be dirty
    try std.testing.expect(tracker.isDirty(0));
    try std.testing.expect(tracker.isDirty(19));
}
