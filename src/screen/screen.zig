const std = @import("std");
const grid_mod = @import("grid.zig");
const colour = @import("../core/colour.zig");

pub const Grid = grid_mod.Grid;
pub const Cell = grid_mod.Cell;
pub const Line = grid_mod.Line;

/// Cursor style.
pub const CursorStyle = enum(u3) {
    default = 0,
    blinking_block = 1,
    steady_block = 2,
    blinking_underline = 3,
    steady_underline = 4,
    blinking_bar = 5,
    steady_bar = 6,
};

/// Screen mode flags (DEC private modes, etc.).
pub const Mode = packed struct(u32) {
    cursor_visible: bool = true,
    insert: bool = false,
    origin: bool = false,
    wrap: bool = true,
    mouse_standard: bool = false,
    mouse_button: bool = false,
    mouse_any: bool = false,
    mouse_sgr: bool = false,
    app_cursor: bool = false,
    app_keypad: bool = false,
    bracketed_paste: bool = false,
    focus_events: bool = false,
    alt_screen: bool = false,
    _padding: u19 = 0,

    pub const default: Mode = .{};
};

/// Saved cursor state for DECSC/DECRC.
const SavedState = struct {
    cx: u32 = 0,
    cy: u32 = 0,
    cstyle: CursorStyle = .steady_bar,
    cell: Cell = Cell.blank,
    cstyle: CursorStyle = .steady_bar,
    origin_mode: bool = false,
};

/// Screen represents the visible terminal state.
/// Each pane has its own Screen instance.
pub const Screen = struct {
    grid: Grid,

    /// Cursor position.
    cx: u32,
    cy: u32,

    /// Cursor style and color.
    cstyle: CursorStyle,
    default_cstyle: CursorStyle,

    /// Scroll region (top and bottom, inclusive).
    rupper: u32,
    rlower: u32,

    /// Current cell attributes for new characters.
    cell: Cell,

    /// Screen modes.
    mode: Mode,
    default_mode: Mode,

    /// Saved state for DECSC/DECRC.
    saved: SavedState,

    /// Alt-screen backing grid (created on first use).
    alt_grid: ?Grid,
    alt_saved: SavedState,

    /// Title.
    title: ?[]const u8,

    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, init_cols: u32, init_rows: u32, hlimit: u32) Screen {
        return .{
            .grid = Grid.init(alloc, init_cols, init_rows, hlimit),
            .cx = 0,
            .cy = 0,
            .cstyle = .steady_bar,
            .default_cstyle = .steady_bar,
            .rupper = 0,
            .rlower = init_rows -| 1,
            .cell = Cell.blank,
            .mode = Mode.default,
            .default_mode = Mode.default,
            .saved = .{},
            .alt_grid = null,
            .alt_saved = .{},
            .title = null,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Screen) void {
        self.grid.deinit();
        if (self.alt_grid) |*ag| {
            ag.deinit();
        }
        if (self.title) |t| {
            self.allocator.free(t);
        }
    }

    /// Get grid dimensions.
    pub fn cols(self: *const Screen) u32 {
        return self.grid.cols;
    }

    pub fn rows(self: *const Screen) u32 {
        return self.grid.rows;
    }

    /// Move cursor, clamping to grid bounds.
    pub fn cursorTo(self: *Screen, x: u32, y: u32) void {
        self.cx = @min(x, self.grid.cols -| 1);
        if (self.mode.origin) {
            self.cy = @min(y + self.rupper, self.rlower);
        } else {
            self.cy = @min(y, self.grid.rows -| 1);
        }
    }

    /// Move cursor up by n, stopping at scroll region top.
    pub fn cursorUp(self: *Screen, n: u32) void {
        const stop = if (self.cy >= self.rupper) self.rupper else 0;
        self.cy = if (self.cy >= n + stop) self.cy - n else stop;
    }

    /// Move cursor down by n, stopping at scroll region bottom.
    pub fn cursorDown(self: *Screen, n: u32) void {
        const stop = if (self.cy <= self.rlower) self.rlower else self.grid.rows -| 1;
        self.cy = @min(self.cy + n, stop);
    }

    /// Set scroll region (1-based, inclusive).
    pub fn setScrollRegion(self: *Screen, top: u32, bottom: u32) void {
        const t = if (top > 0) top - 1 else 0;
        const b = if (bottom > 0) @min(bottom - 1, self.grid.rows -| 1) else self.grid.rows -| 1;
        if (t < b) {
            self.rupper = t;
            self.rlower = b;
        }
    }

    /// Scroll the scroll region up by n lines.
    /// Shifts lines within [rupper..rlower] upward and clears the bottom.
    pub fn scrollUp(self: *Screen, n: u32) void {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            if (self.rupper == 0 and self.rlower == self.grid.rows -| 1) {
                // Full-screen scroll: push top line into history.
                self.grid.scrollUp(1);
            } else {
                // Scroll within region: shift lines up, clear bottom.
                var y = self.rupper;
                while (y < self.rlower) : (y += 1) {
                    const src_line = self.grid.getLine(y + 1);
                    const dst_line = self.grid.getLine(y);
                    var x: u32 = 0;
                    while (x < self.grid.cols) : (x += 1) {
                        dst_line.getCell(x).* = src_line.getCell(x).*;
                    }
                }
                self.grid.clearLine(self.rlower);
            }
        }
    }

    /// Scroll the scroll region down by n lines.
    /// Shifts lines within [rupper..rlower] downward and clears the top.
    pub fn scrollDown(self: *Screen, n: u32) void {
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // Shift lines down: copy each line from (rlower-1) down to rupper
            // into the line below it, then clear rupper.
            if (self.rlower > self.rupper) {
                var y = self.rlower;
                while (y > self.rupper) : (y -= 1) {
                    const src_line = self.grid.getLine(y - 1);
                    const dst_line = self.grid.getLine(y);
                    var x: u32 = 0;
                    while (x < self.grid.cols) : (x += 1) {
                        dst_line.getCell(x).* = src_line.getCell(x).*;
                    }
                }
            }
            self.grid.clearLine(self.rupper);
        }
    }

    /// Save cursor state (DECSC).
    pub fn saveCursor(self: *Screen) void {
        self.saved = .{
            .cx = self.cx,
            .cy = self.cy,
            .cstyle = self.cstyle,
            .cell = self.cell,
            .cstyle = self.cstyle,
            .origin_mode = self.mode.origin,
        };
    }

    /// Restore cursor state (DECRC).
    pub fn restoreCursor(self: *Screen) void {
        self.cx = @min(self.saved.cx, self.grid.cols -| 1);
        self.cy = @min(self.saved.cy, self.grid.rows -| 1);
        self.cstyle = self.saved.cstyle;
        self.cell = self.saved.cell;
        self.cstyle = self.saved.cstyle;
        self.mode.origin = self.saved.origin_mode;
    }

    /// Enter alt-screen: save cursor, swap to a fresh grid, clear it.
    pub fn enterAltScreen(self: *Screen) void {
        if (self.mode.alt_screen) return; // already in alt screen

        // Save main cursor state.
        self.alt_saved = .{
            .cx = self.cx,
            .cy = self.cy,
            .cstyle = self.cstyle,
            .cell = self.cell,
            .cstyle = self.cstyle,
            .origin_mode = self.mode.origin,
        };

        // Create alt grid (no scrollback) and swap.
        if (self.alt_grid == null) {
            self.alt_grid = Grid.init(self.allocator, self.grid.cols, self.grid.rows, 0);
        }
        const tmp = self.grid;
        self.grid = self.alt_grid.?;
        self.alt_grid = tmp;

        // Reset state for alt screen.
        self.cx = 0;
        self.cy = 0;
        self.rupper = 0;
        self.rlower = self.grid.rows -| 1;
        self.mode.alt_screen = true;

        // Clear the alt grid.
        var y: u32 = 0;
        while (y < self.grid.rows) : (y += 1) {
            self.grid.clearLine(y);
        }
    }

    /// Leave alt-screen: swap back to main grid, restore cursor.
    pub fn leaveAltScreen(self: *Screen) void {
        if (!self.mode.alt_screen) return; // not in alt screen

        // Swap grids back.
        const tmp = self.grid;
        self.grid = self.alt_grid.?;
        self.alt_grid = tmp;

        // Restore main cursor state.
        self.cx = @min(self.alt_saved.cx, self.grid.cols -| 1);
        self.cy = @min(self.alt_saved.cy, self.grid.rows -| 1);
        self.cstyle = self.alt_saved.cstyle;
        self.cell = self.alt_saved.cell;
        self.cstyle = self.alt_saved.cstyle;
        self.mode.origin = self.alt_saved.origin_mode;
        self.mode.alt_screen = false;
        self.rupper = 0;
        self.rlower = self.grid.rows -| 1;
    }

    /// Set the terminal title.
    pub fn setTitle(self: *Screen, title: []const u8) !void {
        if (self.title) |old| {
            self.allocator.free(old);
        }
        self.title = try self.allocator.dupe(u8, title);
    }

    /// Reset to initial state.
    pub fn reset(self: *Screen) void {
        self.cx = 0;
        self.cy = 0;
        self.cstyle = self.default_cstyle;
        self.rupper = 0;
        self.rlower = self.grid.rows -| 1;
        self.cell = Cell.blank;
        self.mode = self.default_mode;
        self.saved = .{};
    }
};

test "screen init" {
    var screen = Screen.init(std.testing.allocator, 80, 24, 1000);
    defer screen.deinit();
    try std.testing.expectEqual(@as(u32, 80), screen.cols());
    try std.testing.expectEqual(@as(u32, 24), screen.rows());
    try std.testing.expectEqual(@as(u32, 0), screen.cx);
    try std.testing.expectEqual(@as(u32, 0), screen.cy);
}

test "cursor movement" {
    var screen = Screen.init(std.testing.allocator, 80, 24, 0);
    defer screen.deinit();
    screen.cursorTo(10, 5);
    try std.testing.expectEqual(@as(u32, 10), screen.cx);
    try std.testing.expectEqual(@as(u32, 5), screen.cy);

    // Clamp to bounds
    screen.cursorTo(100, 100);
    try std.testing.expectEqual(@as(u32, 79), screen.cx);
    try std.testing.expectEqual(@as(u32, 23), screen.cy);
}

test "save restore cursor" {
    var screen = Screen.init(std.testing.allocator, 80, 24, 0);
    defer screen.deinit();
    screen.cursorTo(10, 5);
    screen.cstyle = .steady_underline;
    screen.saveCursor();
    screen.cstyle = .steady_block;
    screen.cursorTo(0, 0);
    screen.cstyle = .blinking_block;
    screen.restoreCursor();
    try std.testing.expectEqual(@as(u32, 10), screen.cx);
    try std.testing.expectEqual(@as(u32, 5), screen.cy);
    try std.testing.expectEqual(CursorStyle.steady_underline, screen.cstyle);
}

test "alt screen enter and leave" {
    var screen = Screen.init(std.testing.allocator, 10, 5, 100);
    defer screen.deinit();

    // Write to main screen.
    screen.grid.getCell(0, 0).codepoint = 'M';
    screen.cursorTo(3, 2);
    screen.cstyle = .steady_bar;

    // Enter alt screen.
    screen.enterAltScreen();
    try std.testing.expect(screen.mode.alt_screen);
    // Alt screen should start with cleared grid.
    try std.testing.expectEqual(@as(u21, ' '), screen.grid.getCell(0, 0).codepoint);
    // Cursor should be reset.
    try std.testing.expectEqual(@as(u32, 0), screen.cx);
    try std.testing.expectEqual(@as(u32, 0), screen.cy);

    // Write to alt screen.
    screen.grid.getCell(0, 0).codepoint = 'A';
    screen.cstyle = .steady_underline;

    // Leave alt screen.
    screen.leaveAltScreen();
    try std.testing.expect(!screen.mode.alt_screen);
    // Main screen content should be restored.
    try std.testing.expectEqual(@as(u21, 'M'), screen.grid.getCell(0, 0).codepoint);
    // Cursor should be restored.
    try std.testing.expectEqual(@as(u32, 3), screen.cx);
    try std.testing.expectEqual(@as(u32, 2), screen.cy);
    try std.testing.expectEqual(CursorStyle.steady_bar, screen.cstyle);
}

test "alt screen double enter is no-op" {
    var screen = Screen.init(std.testing.allocator, 10, 5, 0);
    defer screen.deinit();

    screen.grid.getCell(0, 0).codepoint = 'X';
    screen.enterAltScreen();
    screen.grid.getCell(0, 0).codepoint = 'Y';

    // Second enter should be a no-op.
    screen.enterAltScreen();
    try std.testing.expectEqual(@as(u21, 'Y'), screen.grid.getCell(0, 0).codepoint);

    screen.leaveAltScreen();
    try std.testing.expectEqual(@as(u21, 'X'), screen.grid.getCell(0, 0).codepoint);
}
