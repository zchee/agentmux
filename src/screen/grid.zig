const std = @import("std");
const colour = @import("../core/colour.zig");

/// A single terminal cell.
pub const Cell = struct {
    codepoint: u21,
    fg: colour.Colour,
    bg: colour.Colour,
    attrs: colour.Attributes,
    width: u2,

    pub const empty: Cell = .{
        .codepoint = 0,
        .fg = .default,
        .bg = .default,
        .attrs = .{},
        .width = 0,
    };

    pub const blank: Cell = .{
        .codepoint = ' ',
        .fg = .default,
        .bg = .default,
        .attrs = .{},
        .width = 1,
    };
};

pub const LineFlags = packed struct(u8) {
    extended: bool = false,
    wrapped: bool = false,
    _padding: u6 = 0,
};

/// A single line in the grid.
pub const Line = struct {
    cells: []Cell,
    flags: LineFlags,

    pub fn init(alloc: std.mem.Allocator, cols: u32) !Line {
        const cells = try alloc.alloc(Cell, cols);
        @memset(cells, Cell.blank);
        return .{ .cells = cells, .flags = .{} };
    }

    pub fn deinit(self: *Line, alloc: std.mem.Allocator) void {
        alloc.free(self.cells);
        self.cells = &.{};
    }

    pub fn getCell(self: *Line, x: u32) *Cell {
        if (x >= self.cells.len) return &self.cells[self.cells.len - 1];
        return &self.cells[x];
    }

    pub fn resize(self: *Line, alloc: std.mem.Allocator, new_cols: u32) !void {
        if (new_cols == self.cells.len) return;
        const new_cells = try alloc.alloc(Cell, new_cols);
        const copy_len = @min(self.cells.len, new_cols);
        @memcpy(new_cells[0..copy_len], self.cells[0..copy_len]);
        if (new_cols > self.cells.len) {
            @memset(new_cells[copy_len..], Cell.blank);
        }
        alloc.free(self.cells);
        self.cells = new_cells;
    }

    pub fn clear(self: *Line, start: u32, end: u32) void {
        const s = @min(start, @as(u32, @intCast(self.cells.len)));
        const e = @min(end, @as(u32, @intCast(self.cells.len)));
        if (s < e) {
            @memset(self.cells[s..e], Cell.blank);
        }
    }
};

pub const GridFlags = packed struct(u8) {
    history: bool = true,
    _padding: u7 = 0,
};

/// Grid: stores lines of cells for terminal output.
pub const Grid = struct {
    cols: u32,
    rows: u32,
    hsize: u32,
    hlimit: u32,
    lines: std.ArrayListAligned(Line, null),
    flags: GridFlags,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, cols: u32, rows: u32, hlimit: u32) Grid {
        var g = Grid{
            .cols = cols,
            .rows = rows,
            .hsize = 0,
            .hlimit = hlimit,
            .lines = .empty,
            .flags = .{},
            .allocator = alloc,
        };
        // Allocate visible lines
        g.lines.ensureTotalCapacity(alloc, rows) catch {};
        var i: u32 = 0;
        while (i < rows) : (i += 1) {
            const line = Line.init(alloc, cols) catch {
                break;
            };
            g.lines.append(alloc, line) catch break;
        }
        return g;
    }

    pub fn deinit(self: *Grid) void {
        for (self.lines.items) |*line| {
            line.deinit(self.allocator);
        }
        self.lines.deinit(self.allocator);
    }

    /// Get a visible line (0 = top of visible area).
    pub fn getLine(self: *Grid, y: u32) *Line {
        const idx = self.hsize + y;
        if (idx >= self.lines.items.len) {
            return &self.lines.items[self.lines.items.len - 1];
        }
        return &self.lines.items[idx];
    }

    /// Get a history line (0 = oldest).
    pub fn getHistoryLine(self: *Grid, y: u32) *Line {
        if (y >= self.hsize) return self.getLine(0);
        return &self.lines.items[y];
    }

    /// Get a cell at (x, y) in the visible area.
    pub fn getCell(self: *Grid, x: u32, y: u32) *Cell {
        return self.getLine(y).getCell(x);
    }

    /// Scroll visible lines up by count, moving top lines into history.
    pub fn scrollUp(self: *Grid, count: u32) void {
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.flags.history and self.hsize < self.hlimit) {
                // Add new line at the bottom, top line becomes history
                self.hsize += 1;
                const new_line = Line.init(self.allocator, self.cols) catch return;
                self.lines.append(self.allocator, new_line) catch return;
            } else if (self.flags.history and self.hsize >= self.hlimit) {
                // History full: discard oldest history line
                self.lines.items[0].deinit(self.allocator);
                // Shift all lines down
                std.mem.copyForwards(Line, self.lines.items[0 .. self.lines.items.len - 1], self.lines.items[1..]);
                // Add new blank line at end
                const new_line = Line.init(self.allocator, self.cols) catch return;
                self.lines.items[self.lines.items.len - 1] = new_line;
            } else {
                // No history: just rotate
                self.clearLine(0);
            }
        }
    }

    /// Clear a visible line.
    pub fn clearLine(self: *Grid, y: u32) void {
        const line = self.getLine(y);
        line.clear(0, self.cols);
    }

    /// Clear a rectangular region in the visible area.
    pub fn clearRegion(self: *Grid, x1: u32, y1: u32, x2: u32, y2: u32) void {
        var y = y1;
        while (y <= y2 and y < self.rows) : (y += 1) {
            const line = self.getLine(y);
            line.clear(x1, x2 + 1);
        }
    }

    /// Resize the grid.
    pub fn resize(self: *Grid, new_cols: u32, new_rows: u32) void {
        // Resize existing lines width
        if (new_cols != self.cols) {
            for (self.lines.items) |*line| {
                line.resize(self.allocator, new_cols) catch {};
            }
            self.cols = new_cols;
        }

        // Add or remove visible lines
        const total_needed = self.hsize + new_rows;
        while (self.lines.items.len < total_needed) {
            const line = Line.init(self.allocator, self.cols) catch break;
            self.lines.append(self.allocator, line) catch break;
        }
        while (self.lines.items.len > total_needed) {
            if (self.lines.pop()) |popped| {
                var line = popped;
                line.deinit(self.allocator);
            } else break;
        }
        self.rows = new_rows;
    }
};

test "grid init and getCell" {
    var grid = Grid.init(std.testing.allocator, 80, 24, 100);
    defer grid.deinit();

    try std.testing.expectEqual(@as(u32, 80), grid.cols);
    try std.testing.expectEqual(@as(u32, 24), grid.rows);

    const cell = grid.getCell(0, 0);
    try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
}

test "grid resize" {
    var grid = Grid.init(std.testing.allocator, 80, 24, 0);
    defer grid.deinit();

    grid.resize(120, 40);
    try std.testing.expectEqual(@as(u32, 120), grid.cols);
    try std.testing.expectEqual(@as(u32, 40), grid.rows);

    // Cell should still be accessible
    const cell = grid.getCell(100, 30);
    try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
}

test "grid scrollUp with history" {
    var grid = Grid.init(std.testing.allocator, 80, 5, 10);
    defer grid.deinit();

    // Write something to the first line
    grid.getCell(0, 0).codepoint = 'A';

    grid.scrollUp(1);
    try std.testing.expectEqual(@as(u32, 1), grid.hsize);

    // The old first line should now be in history
    const hist = grid.getHistoryLine(0);
    try std.testing.expectEqual(@as(u21, 'A'), hist.cells[0].codepoint);
}
