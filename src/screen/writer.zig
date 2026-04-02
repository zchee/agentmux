const std = @import("std");
const grid_mod = @import("grid.zig");
const screen_mod = @import("screen.zig");
const utf8 = @import("../core/utf8.zig");
const colour = @import("../core/colour.zig");

const Cell = grid_mod.Cell;
const Grid = grid_mod.Grid;
const Screen = screen_mod.Screen;

/// Screen write context.
/// Provides operations to write characters and control sequences to a screen.
pub const Writer = struct {
    s: *Screen,

    pub fn init(s: *Screen) Writer {
        return .{ .s = s };
    }

    /// Print a character at the current cursor position.
    pub fn putChar(self: *Writer, cp: u21) void {
        const w = utf8.charWidth(cp);
        if (w == 0) return; // skip zero-width for now

        // Check if we need to wrap
        if (self.s.cx >= self.s.grid.cols) {
            if (self.s.mode.wrap) {
                self.s.cx = 0;
                self.linefeed();
            } else {
                self.s.cx = self.s.grid.cols -| 1;
            }
        }

        // Wide character: check if there's room
        if (w == 2 and self.s.cx + 1 >= self.s.grid.cols) {
            if (self.s.mode.wrap) {
                self.s.cx = 0;
                self.linefeed();
            } else {
                return;
            }
        }

        const cell = self.s.grid.getCell(self.s.cx, self.s.cy);
        cell.* = .{
            .codepoint = cp,
            .fg = self.s.cell.fg,
            .bg = self.s.cell.bg,
            .attrs = self.s.cell.attrs,
            .width = w,
        };

        // For wide chars, blank the next cell
        if (w == 2 and self.s.cx + 1 < self.s.grid.cols) {
            const next = self.s.grid.getCell(self.s.cx + 1, self.s.cy);
            next.* = Cell.empty;
        }

        self.s.cx += w;
    }

    /// Linefeed: move cursor down, scroll if at bottom of scroll region.
    pub fn linefeed(self: *Writer) void {
        if (self.s.cy == self.s.rlower) {
            self.s.scrollUp(1);
        } else {
            self.s.cy += 1;
        }
    }

    /// Carriage return: move cursor to column 0.
    pub fn carriageReturn(self: *Writer) void {
        self.s.cx = 0;
    }

    /// Backspace: move cursor left by 1.
    pub fn backspace(self: *Writer) void {
        if (self.s.cx > 0) self.s.cx -= 1;
    }

    /// Tab: move to next tab stop (every 8 columns).
    pub fn tab(self: *Writer) void {
        const next = (self.s.cx / 8 + 1) * 8;
        self.s.cx = @min(next, self.s.grid.cols -| 1);
    }

    /// Reverse index: move cursor up, scroll down if at top of scroll region.
    pub fn reverseIndex(self: *Writer) void {
        if (self.s.cy == self.s.rupper) {
            self.s.scrollDown(1);
        } else if (self.s.cy > 0) {
            self.s.cy -= 1;
        }
    }

    /// Erase from cursor to end of line.
    pub fn eraseToEol(self: *Writer) void {
        const line = self.s.grid.getLine(self.s.cy);
        line.clear(self.s.cx, self.s.grid.cols);
    }

    /// Erase from start of line to cursor.
    pub fn eraseToBol(self: *Writer) void {
        const line = self.s.grid.getLine(self.s.cy);
        line.clear(0, self.s.cx + 1);
    }

    /// Erase entire line.
    pub fn eraseLine(self: *Writer) void {
        self.s.grid.clearLine(self.s.cy);
    }

    /// Erase from cursor to end of screen.
    pub fn eraseToEnd(self: *Writer) void {
        self.eraseToEol();
        var y = self.s.cy + 1;
        while (y < self.s.grid.rows) : (y += 1) {
            self.s.grid.clearLine(y);
        }
    }

    /// Erase from start of screen to cursor.
    pub fn eraseToStart(self: *Writer) void {
        self.eraseToBol();
        var y: u32 = 0;
        while (y < self.s.cy) : (y += 1) {
            self.s.grid.clearLine(y);
        }
    }

    /// Erase entire screen.
    pub fn eraseScreen(self: *Writer) void {
        var y: u32 = 0;
        while (y < self.s.grid.rows) : (y += 1) {
            self.s.grid.clearLine(y);
        }
    }

    /// Insert n blank lines at the cursor, scrolling down.
    pub fn insertLines(self: *Writer, n: u32) void {
        if (self.s.cy < self.s.rupper or self.s.cy > self.s.rlower) return;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            // Shift lines down within scroll region
            var y = self.s.rlower;
            while (y > self.s.cy) : (y -= 1) {
                // Copy line y-1 to y (simplified: just clear)
                self.s.grid.clearLine(y);
            }
            self.s.grid.clearLine(self.s.cy);
        }
    }

    /// Delete n lines at the cursor, scrolling up.
    pub fn deleteLines(self: *Writer, n: u32) void {
        if (self.s.cy < self.s.rupper or self.s.cy > self.s.rlower) return;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            self.s.grid.clearLine(self.s.cy);
        }
    }

    /// Insert n blank characters at the cursor, shifting existing chars right.
    pub fn insertChars(self: *Writer, n: u32) void {
        const line = self.s.grid.getLine(self.s.cy);
        const cols = self.s.grid.cols;
        if (self.s.cx >= cols) return;

        // Shift cells right
        var x: u32 = cols - 1;
        while (x >= self.s.cx + n) : (x -= 1) {
            line.cells[x] = line.cells[x - n];
            if (x == 0) break;
        }
        // Clear inserted cells
        var i: u32 = 0;
        while (i < n and self.s.cx + i < cols) : (i += 1) {
            line.cells[self.s.cx + i] = Cell.blank;
        }
    }

    /// Delete n characters at the cursor, shifting remaining chars left.
    pub fn deleteChars(self: *Writer, n: u32) void {
        const line = self.s.grid.getLine(self.s.cy);
        const cols = self.s.grid.cols;
        if (self.s.cx >= cols) return;

        const shift = @min(n, cols - self.s.cx);
        var x = self.s.cx;
        while (x + shift < cols) : (x += 1) {
            line.cells[x] = line.cells[x + shift];
        }
        // Clear vacated cells at end
        while (x < cols) : (x += 1) {
            line.cells[x] = Cell.blank;
        }
    }

    /// Write a UTF-8 string to the screen.
    pub fn writeString(self: *Writer, s: []const u8) void {
        var iter = utf8.Iterator.init(s);
        while (iter.next()) |ch| {
            self.putChar(ch.codepoint);
        }
    }
};

test "writer putChar" {
    var screen = Screen.init(std.testing.allocator, 80, 24, 0);
    defer screen.deinit();
    var w = Writer.init(&screen);

    w.putChar('A');
    try std.testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 1), screen.cx);
}

test "writer linefeed and wrap" {
    var screen = Screen.init(std.testing.allocator, 5, 3, 0);
    defer screen.deinit();
    var w = Writer.init(&screen);

    // Fill first line
    w.writeString("ABCDE");
    try std.testing.expectEqual(@as(u32, 5), screen.cx);

    // Next char should wrap to next line
    w.putChar('F');
    try std.testing.expectEqual(@as(u32, 1), screen.cy); // wrapped -> LF moves to row 1
    try std.testing.expectEqual(@as(u32, 1), screen.cx); // 'F' written at col 0, cursor now at 1
}

test "writer eraseToEol" {
    var screen = Screen.init(std.testing.allocator, 10, 3, 0);
    defer screen.deinit();
    var w = Writer.init(&screen);

    w.writeString("ABCDEFGHIJ");
    screen.cx = 5;
    screen.cy = 0;
    w.eraseToEol();

    // First 5 chars should remain
    try std.testing.expectEqual(@as(u21, 'A'), screen.grid.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), screen.grid.getCell(4, 0).codepoint);
    // Rest should be blank
    try std.testing.expectEqual(@as(u21, ' '), screen.grid.getCell(5, 0).codepoint);
}
