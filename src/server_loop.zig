const std = @import("std");
const builtin = @import("builtin");
const input = @import("terminal/input.zig");
const input_handler = @import("input_handler.zig");
const screen_mod = @import("screen/screen.zig");
const redraw_mod = @import("screen/redraw.zig");
const output_mod = @import("terminal/output.zig");
const protocol = @import("protocol.zig");
const log = @import("core/log.zig");

/// Per-pane processing state.
/// Each pane has its own parser, screen, and dirty tracker.
pub const PaneState = struct {
    pane_id: u32,
    pty_fd: std.c.fd_t,
    parser: input.Parser,
    screen: screen_mod.Screen,
    dirty: redraw_mod.DirtyTracker,
    bell_pending: bool,
    activity_pending: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, pane_id: u32, pty_fd: std.c.fd_t, cols: u32, rows: u32, hlimit: u32) !PaneState {
        return .{
            .pane_id = pane_id,
            .pty_fd = pty_fd,
            .parser = input.Parser.init(),
            .screen = screen_mod.Screen.init(alloc, cols, rows, hlimit),
            .dirty = try redraw_mod.DirtyTracker.init(alloc, rows),
            .bell_pending = false,
            .activity_pending = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *PaneState) void {
        self.screen.deinit();
        self.dirty.deinit();
    }

    /// Process bytes read from the PTY.
    /// Feeds through parser -> input_handler -> screen state.
    /// Marks changed lines as dirty.
    pub fn processPtyOutput(self: *PaneState, data: []const u8) void {
        // Scan for BEL (0x07) to detect bell events.
        for (data) |byte| {
            if (byte == 0x07) {
                self.bell_pending = true;
                break;
            }
        }
        // Any output is activity.
        if (data.len > 0) {
            self.activity_pending = true;
        }

        const old_cy = self.screen.cy;
        input_handler.processBytes(&self.parser, &self.screen, data);
        // Mark affected lines dirty
        // Simple heuristic: mark all lines between old and new cursor position
        const min_y = @min(old_cy, self.screen.cy);
        const max_y = @max(old_cy, self.screen.cy);
        var y = min_y;
        while (y <= max_y) : (y += 1) {
            self.dirty.markDirty(y);
        }
        // Also mark the current cursor line
        self.dirty.markDirty(self.screen.cy);
    }

    /// Read from PTY and process output.
    /// Returns number of bytes read, 0 on EOF/EAGAIN.
    pub fn readAndProcess(self: *PaneState) usize {
        var buf: [8192]u8 = undefined;
        const n = std.c.read(self.pty_fd, &buf, buf.len);
        if (n <= 0) return 0;
        const len: usize = @intCast(n);
        self.processPtyOutput(buf[0..len]);
        return len;
    }

    /// Send key input to the PTY.
    pub fn sendKey(self: *PaneState, data: []const u8) void {
        _ = std.c.write(self.pty_fd, data.ptr, data.len);
    }

    /// Resize the pane.
    pub fn resize(self: *PaneState, cols: u32, rows: u32) void {
        self.screen.grid.resize(cols, rows);
        self.dirty.resize(self.allocator, rows) catch {};
        self.dirty.markAllDirty();
        // Resize PTY via ioctl
        const TIOCSWINSZ = if (builtin.os.tag == .linux)
            @as(i32, 0x5414)
        else
            @as(i32, @bitCast(@as(u32, 0x80087467)));
        const ws = std.posix.winsize{
            .col = @intCast(@min(cols, 0xFFFF)),
            .row = @intCast(@min(rows, 0xFFFF)),
            .xpixel = 0,
            .ypixel = 0,
        };
        _ = std.c.ioctl(self.pty_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// Render dirty lines to an output writer.
    pub fn renderTo(self: *PaneState, out: *output_mod.Output) void {
        redraw_mod.redraw(&self.dirty, &self.screen, out);
    }
};

/// Server session loop: manages multiple pane states.
pub const SessionLoop = struct {
    panes: std.AutoHashMap(u32, PaneState),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) SessionLoop {
        return .{
            .panes = std.AutoHashMap(u32, PaneState).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *SessionLoop) void {
        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.panes.deinit();
    }

    /// Register a pane for processing.
    pub fn addPane(self: *SessionLoop, pane_id: u32, pty_fd: std.c.fd_t, cols: u32, rows: u32) !void {
        const state = try PaneState.init(self.allocator, pane_id, pty_fd, cols, rows, 10000);
        try self.panes.put(pane_id, state);
    }

    /// Remove a pane.
    pub fn removePane(self: *SessionLoop, pane_id: u32) void {
        if (self.panes.fetchRemove(pane_id)) |entry| {
            var state = entry.value;
            state.deinit();
        }
    }

    /// Process I/O for all panes.
    /// Returns total bytes processed.
    pub fn processAll(self: *SessionLoop) usize {
        var total: usize = 0;
        var iter = self.panes.iterator();
        while (iter.next()) |entry| {
            total += entry.value_ptr.readAndProcess();
        }
        return total;
    }

    /// Get a pane state.
    pub fn getPane(self: *SessionLoop, pane_id: u32) ?*PaneState {
        return self.panes.getPtr(pane_id);
    }

    /// Send key input to a specific pane.
    pub fn sendKeyToPane(self: *SessionLoop, pane_id: u32, data: []const u8) void {
        if (self.panes.getPtr(pane_id)) |state| {
            state.sendKey(data);
        }
    }

    /// Render a pane to an output.
    pub fn renderPane(self: *SessionLoop, pane_id: u32, out: *output_mod.Output) void {
        if (self.panes.getPtr(pane_id)) |state| {
            state.renderTo(out);
        }
    }

    /// Resize a pane.
    pub fn resizePane(self: *SessionLoop, pane_id: u32, cols: u32, rows: u32) void {
        if (self.panes.getPtr(pane_id)) |state| {
            state.resize(cols, rows);
        }
    }
};

test "pane state process bytes" {
    var state = try PaneState.init(std.testing.allocator, 0, -1, 80, 24, 0);
    defer state.deinit();

    // Process some text
    state.processPtyOutput("Hello, World!");
    try std.testing.expectEqual(@as(u21, 'H'), state.screen.grid.getCell(0, 0).codepoint);
    try std.testing.expectEqual(@as(u21, '!'), state.screen.grid.getCell(12, 0).codepoint);
    try std.testing.expectEqual(@as(u32, 13), state.screen.cx);
}

test "pane state process escape sequences" {
    var state = try PaneState.init(std.testing.allocator, 0, -1, 80, 24, 0);
    defer state.deinit();

    // Move cursor to (5, 3) and write
    state.processPtyOutput("\x1b[4;6H"); // row 4, col 6 (1-based)
    try std.testing.expectEqual(@as(u32, 5), state.screen.cx);
    try std.testing.expectEqual(@as(u32, 3), state.screen.cy);

    state.processPtyOutput("X");
    try std.testing.expectEqual(@as(u21, 'X'), state.screen.grid.getCell(5, 3).codepoint);
}

test "session loop" {
    var loop = SessionLoop.init(std.testing.allocator);
    defer loop.deinit();

    try loop.addPane(0, -1, 80, 24);
    try loop.addPane(1, -1, 40, 12);

    // Process text on pane 0
    if (loop.getPane(0)) |state| {
        state.processPtyOutput("pane0");
        try std.testing.expectEqual(@as(u21, 'p'), state.screen.grid.getCell(0, 0).codepoint);
    }

    // Process text on pane 1
    if (loop.getPane(1)) |state| {
        state.processPtyOutput("pane1");
        try std.testing.expectEqual(@as(u21, 'p'), state.screen.grid.getCell(0, 0).codepoint);
    }

    loop.removePane(0);
    try std.testing.expect(loop.getPane(0) == null);
    try std.testing.expect(loop.getPane(1) != null);
}
