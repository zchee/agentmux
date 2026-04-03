const std = @import("std");
const LayoutCell = @import("layout/layout.zig").LayoutCell;

/// A pane within a window.
pub const Pane = struct {
    id: u32,
    pid: std.c.pid_t,
    fd: std.c.fd_t,

    sx: u32,
    sy: u32,
    xoff: u32,
    yoff: u32,

    flags: Flags,
    allocator: std.mem.Allocator,

    pub const Flags = packed struct(u16) {
        redraw: bool = false,
        focused: bool = false,
        exited: bool = false,
        empty: bool = false,
        _padding: u12 = 0,
    };

    var next_id: u32 = 0;

    pub fn init(alloc: std.mem.Allocator, sx: u32, sy: u32) !*Pane {
        const p = try alloc.create(Pane);
        p.* = .{
            .id = next_id,
            .pid = 0,
            .fd = -1,
            .sx = sx,
            .sy = sy,
            .xoff = 0,
            .yoff = 0,
            .flags = .{},
            .allocator = alloc,
        };
        next_id += 1;
        return p;
    }

    pub fn deinit(self: *Pane) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
        }
        self.allocator.destroy(self);
    }

    pub fn resize(self: *Pane, sx: u32, sy: u32) void {
        self.sx = sx;
        self.sy = sy;
        self.flags.redraw = true;
    }
};

/// A window containing one or more panes arranged in a layout.
pub const Window = struct {
    id: u32,
    name: []const u8,

    panes: std.ArrayListAligned(*Pane, null),
    active_pane: ?*Pane,

    layout_root: ?*LayoutCell,

    sx: u32,
    sy: u32,

    flags: Flags,
    allocator: std.mem.Allocator,

    pub const Flags = packed struct(u16) {
        bell: bool = false,
        activity: bool = false,
        silence: bool = false,
        zoomed: bool = false,
        _padding: u12 = 0,
    };

    var next_id: u32 = 0;

    pub fn init(alloc: std.mem.Allocator, name: []const u8, sx: u32, sy: u32) !*Window {
        const w = try alloc.create(Window);
        const owned_name = try alloc.dupe(u8, name);
        w.* = .{
            .id = next_id,
            .name = owned_name,
            .panes = .empty,
            .active_pane = null,
            .layout_root = null,
            .sx = sx,
            .sy = sy,
            .flags = .{},
            .allocator = alloc,
        };
        next_id += 1;
        return w;
    }

    pub fn deinit(self: *Window) void {
        for (self.panes.items) |p| {
            p.deinit();
        }
        self.panes.deinit(self.allocator);
        if (self.layout_root) |root| {
            root.deinit();
        }
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Add a pane to the window.
    pub fn addPane(self: *Window, pane: *Pane) !void {
        try self.panes.append(self.allocator, pane);
        if (self.active_pane == null) {
            self.active_pane = pane;
        }
    }

    /// Get the number of panes.
    pub fn paneCount(self: *const Window) usize {
        return self.panes.items.len;
    }

    /// Select the next pane.
    pub fn nextPane(self: *Window) void {
        if (self.panes.items.len == 0) return;
        if (self.active_pane) |active| {
            for (self.panes.items, 0..) |p, i| {
                if (p == active) {
                    const next_idx = (i + 1) % self.panes.items.len;
                    self.active_pane = self.panes.items[next_idx];
                    return;
                }
            }
        }
        self.active_pane = self.panes.items[0];
    }

    /// Select the previous pane.
    pub fn prevPane(self: *Window) void {
        if (self.panes.items.len == 0) return;
        if (self.active_pane) |active| {
            for (self.panes.items, 0..) |p, i| {
                if (p == active) {
                    const prev_idx = if (i == 0) self.panes.items.len - 1 else i - 1;
                    self.active_pane = self.panes.items[prev_idx];
                    return;
                }
            }
        }
    }

    /// Remove and destroy a pane. Returns true if the window has no panes left.
    pub fn removePane(self: *Window, pane: *Pane) bool {
        for (self.panes.items, 0..) |p, i| {
            if (p == pane) {
                _ = self.panes.orderedRemove(i);
                break;
            }
        }

        // If active pane was removed, select another
        if (self.active_pane == pane) {
            self.active_pane = if (self.panes.items.len > 0) self.panes.items[0] else null;
        }

        pane.deinit();
        return self.panes.items.len == 0;
    }

    pub const SwapDirection = enum { next, prev };

    /// Swap the active pane with the next or previous pane.
    pub fn swapActivePane(self: *Window, direction: SwapDirection) void {
        if (self.panes.items.len < 2) return;
        const active = self.active_pane orelse return;

        for (self.panes.items, 0..) |p, i| {
            if (p == active) {
                const other_idx = switch (direction) {
                    .next => (i + 1) % self.panes.items.len,
                    .prev => if (i == 0) self.panes.items.len - 1 else i - 1,
                };
                // Swap pane pointers in the list
                self.panes.items[i] = self.panes.items[other_idx];
                self.panes.items[other_idx] = active;

                // Swap positions
                const tmp_xoff = active.xoff;
                const tmp_yoff = active.yoff;
                const tmp_sx = active.sx;
                const tmp_sy = active.sy;
                active.xoff = self.panes.items[i].xoff;
                active.yoff = self.panes.items[i].yoff;
                active.sx = self.panes.items[i].sx;
                active.sy = self.panes.items[i].sy;
                self.panes.items[i].xoff = tmp_xoff;
                self.panes.items[i].yoff = tmp_yoff;
                self.panes.items[i].sx = tmp_sx;
                self.panes.items[i].sy = tmp_sy;

                active.flags.redraw = true;
                self.panes.items[i].flags.redraw = true;
                return;
            }
        }
    }

    /// Resize the window and all panes.
    pub fn resize(self: *Window, new_sx: u32, new_sy: u32) void {
        self.sx = new_sx;
        self.sy = new_sy;
        if (self.layout_root) |root| {
            root.resize(new_sx, new_sy);
        }
    }

    /// Rename the window.
    pub fn rename(self: *Window, new_name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = owned;
    }
};

test "window and pane lifecycle" {
    const alloc = std.testing.allocator;
    var w = try Window.init(alloc, "test", 80, 24);
    defer w.deinit();

    const p1 = try Pane.init(alloc, 80, 24);
    try w.addPane(p1);
    try std.testing.expectEqual(@as(usize, 1), w.paneCount());
    try std.testing.expect(w.active_pane == p1);

    const p2 = try Pane.init(alloc, 40, 24);
    try w.addPane(p2);
    try std.testing.expectEqual(@as(usize, 2), w.paneCount());
}
