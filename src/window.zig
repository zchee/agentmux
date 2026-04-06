const std = @import("std");
const LayoutCell = @import("layout/layout.zig").LayoutCell;
const CellType = @import("layout/layout.zig").CellType;
const CopyState = @import("copy/copy.zig").CopyState;
const ModeTree = @import("mode/tree.zig").ModeTree;

pub const PromptState = struct {
    buffer: [512]u8 = .{0} ** 512,
    len: usize = 0,
};

pub const ChooseTreeItem = struct {
    session: ?*anyopaque = null,
    window: ?*anyopaque = null,
    pane: ?*anyopaque = null,
    buffer_index: ?u32 = null,
};

pub const ChooseTreeState = struct {
    tree: ModeTree,
    items: std.ArrayListAligned(ChooseTreeItem, null),
    labels: std.ArrayListAligned([]u8, null),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, visible_rows: u32) ChooseTreeState {
        return .{
            .tree = ModeTree.init(alloc, visible_rows),
            .items = .empty,
            .labels = .empty,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *ChooseTreeState) void {
        self.tree.deinit();
        for (self.labels.items) |label| {
            self.allocator.free(label);
        }
        self.labels.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

/// A pane within a window.
pub const Pane = struct {
    id: u32,
    pid: std.c.pid_t,
    fd: std.c.fd_t,
    pipe_fd: std.c.fd_t,

    sx: u32,
    sy: u32,
    xoff: u32,
    yoff: u32,

    flags: Flags,
    copy_state: ?CopyState,
    prompt_state: ?PromptState,
    choose_tree_state: ?ChooseTreeState,
    allocator: std.mem.Allocator,

    pub const Flags = packed struct(u16) {
        redraw: bool = false,
        focused: bool = false,
        exited: bool = false,
        empty: bool = false,
        input_disabled: bool = false,
        _padding: u11 = 0,
    };

    var next_id: u32 = 0;

    pub fn init(alloc: std.mem.Allocator, sx: u32, sy: u32) !*Pane {
        const p = try alloc.create(Pane);
        p.* = .{
            .id = next_id,
            .pid = 0,
            .fd = -1,
            .pipe_fd = -1,
            .sx = sx,
            .sy = sy,
            .xoff = 0,
            .yoff = 0,
            .flags = .{},
            .copy_state = null,
            .prompt_state = null,
            .choose_tree_state = null,
            .allocator = alloc,
        };
        next_id += 1;
        return p;
    }

    pub fn deinit(self: *Pane) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
        }
        if (self.pipe_fd >= 0) {
            _ = std.c.close(self.pipe_fd);
        }
        if (self.choose_tree_state) |*state| {
            state.deinit();
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
    last_pane: ?*Pane,

    layout_root: ?*LayoutCell,
    layout_preset_index: u3,

    sx: u32,
    sy: u32,

    options: Options,
    flags: Flags,
    allocator: std.mem.Allocator,

    pub const Options = struct {
        mode_keys: []u8,
        window_status_format: []u8,
        window_status_current_format: []u8,
        aggressive_resize: bool = false,
        remain_on_exit: bool = false,
        overrides: OverrideFlags = .{},
    };

    pub const OverrideFlags = packed struct(u8) {
        mode_keys: bool = false,
        window_status_format: bool = false,
        window_status_current_format: bool = false,
        aggressive_resize: bool = false,
        remain_on_exit: bool = false,
        _padding: u3 = 0,
    };

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
        errdefer alloc.destroy(w);
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const mode_keys = try alloc.dupe(u8, "emacs");
        errdefer alloc.free(mode_keys);
        const window_status_format = try alloc.dupe(u8, "#I:#W#F");
        errdefer alloc.free(window_status_format);
        const window_status_current_format = try alloc.dupe(u8, "#I:#W#F");
        errdefer alloc.free(window_status_current_format);
        w.* = .{
            .id = next_id,
            .name = owned_name,
            .panes = .empty,
            .active_pane = null,
            .last_pane = null,
            .layout_root = null,
            .layout_preset_index = 0,
            .sx = sx,
            .sy = sy,
            .options = .{
                .mode_keys = mode_keys,
                .window_status_format = window_status_format,
                .window_status_current_format = window_status_current_format,
            },
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
        self.allocator.free(self.options.mode_keys);
        self.allocator.free(self.options.window_status_format);
        self.allocator.free(self.options.window_status_current_format);
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Add a pane to the window.
    pub fn addPane(self: *Window, pane: *Pane) !void {
        try self.panes.append(self.allocator, pane);
        if (self.active_pane == null) {
            self.active_pane = pane;
        }
        if (self.layout_root == null) {
            self.layout_root = try LayoutCell.initLeaf(self.allocator, pane.id, self.sx, self.sy, 0, 0);
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
                    if (self.flags.zoomed) self.applyZoomLayout();
                    return;
                }
            }
        }
        self.active_pane = self.panes.items[0];
        if (self.flags.zoomed) self.applyZoomLayout();
    }

    /// Select the previous pane.
    pub fn prevPane(self: *Window) void {
        if (self.panes.items.len == 0) return;
        if (self.active_pane) |active| {
            for (self.panes.items, 0..) |p, i| {
                if (p == active) {
                    const prev_idx = if (i == 0) self.panes.items.len - 1 else i - 1;
                    self.active_pane = self.panes.items[prev_idx];
                    if (self.flags.zoomed) self.applyZoomLayout();
                    return;
                }
            }
        }
    }

    pub fn selectPane(self: *Window, pane: *Pane) void {
        if (self.active_pane) |current| {
            if (current != pane) self.last_pane = current;
        }
        self.active_pane = pane;
        pane.flags.focused = true;
        if (self.flags.zoomed) self.applyZoomLayout();
    }

    pub fn selectPaneByIndex(self: *Window, index: usize) bool {
        if (index >= self.panes.items.len) return false;
        self.selectPane(self.panes.items[index]);
        return true;
    }

    pub fn selectPaneById(self: *Window, pane_id: u32) bool {
        for (self.panes.items) |pane| {
            if (pane.id == pane_id) {
                self.selectPane(pane);
                return true;
            }
        }
        return false;
    }

    /// Remove and destroy a pane. Returns true if the window has no panes left.
    pub fn removePane(self: *Window, pane: *Pane) bool {
        if (self.last_pane == pane) self.last_pane = null;

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
        if (self.flags.zoomed) {
            self.applyZoomLayout();
        } else if (self.layout_root) |root| {
            root.resize(new_sx, new_sy);
            self.syncPanesFromLayout();
        }
    }

    pub fn splitActivePane(self: *Window, new_pane: *Pane, direction: CellType, percent: u32) !void {
        const active = self.active_pane orelse {
            try self.addPane(new_pane);
            return;
        };

        if (self.layout_root == null) {
            self.layout_root = try LayoutCell.initLeaf(self.allocator, active.id, self.sx, self.sy, 0, 0);
        }

        const root = self.layout_root.?;
        const target = root.findPane(active.id) orelse return error.PaneNotFound;
        _ = try target.split(direction, new_pane.id, percent);
        try self.panes.append(self.allocator, new_pane);
        self.active_pane = new_pane;
        if (self.flags.zoomed) {
            self.applyZoomLayout();
        } else {
            self.syncPanesFromLayout();
        }
    }

    pub fn syncPanesFromLayout(self: *Window) void {
        const root = self.layout_root orelse return;
        for (self.panes.items) |pane| {
            if (root.findPane(pane.id)) |cell| {
                pane.xoff = cell.xoff;
                pane.yoff = cell.yoff;
                pane.sx = cell.sx;
                pane.sy = cell.sy;
                pane.flags.redraw = true;
            }
        }
    }

    fn applyZoomLayout(self: *Window) void {
        const active = self.active_pane orelse return;
        for (self.panes.items) |pane| {
            if (pane == active) {
                pane.xoff = 0;
                pane.yoff = 0;
                pane.sx = self.sx;
                pane.sy = self.sy;
            } else {
                pane.xoff = 0;
                pane.yoff = 0;
                pane.sx = 0;
                pane.sy = 0;
            }
            pane.flags.redraw = true;
        }
    }

    pub fn toggleZoom(self: *Window) bool {
        if (self.active_pane == null) return self.flags.zoomed;
        self.flags.zoomed = !self.flags.zoomed;
        if (self.flags.zoomed) {
            self.applyZoomLayout();
        } else if (self.layout_root) |root| {
            root.resize(self.sx, self.sy);
            self.syncPanesFromLayout();
        }
        return self.flags.zoomed;
    }

    /// Rename the window.
    pub fn rename(self: *Window, new_name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = owned;
    }

    pub fn setModeKeys(self: *Window, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.mode_keys);
        self.options.mode_keys = owned;
    }

    pub fn setWindowStatusFormat(self: *Window, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.window_status_format);
        self.options.window_status_format = owned;
    }

    pub fn setWindowStatusCurrentFormat(self: *Window, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.window_status_current_format);
        self.options.window_status_current_format = owned;
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

test "splitActivePane updates layout and active pane" {
    const alloc = std.testing.allocator;
    var w = try Window.init(alloc, "test", 80, 24);
    defer w.deinit();

    const p1 = try Pane.init(alloc, 80, 24);
    try w.addPane(p1);

    const p2 = try Pane.init(alloc, 80, 24);
    try w.splitActivePane(p2, .horizontal, 50);

    try std.testing.expectEqual(@as(usize, 2), w.paneCount());
    try std.testing.expect(w.active_pane == p2);
    try std.testing.expect(w.layout_root != null);
    try std.testing.expect(p1.sx > 0);
    try std.testing.expect(p2.sx > 0);
}

test "toggleZoom zooms and restores active pane geometry" {
    const alloc = std.testing.allocator;
    var w = try Window.init(alloc, "zoom", 80, 24);
    defer w.deinit();

    const p1 = try Pane.init(alloc, 80, 24);
    try w.addPane(p1);
    const p2 = try Pane.init(alloc, 80, 24);
    try w.splitActivePane(p2, .horizontal, 50);

    const left_width = p1.sx;
    const right_width = p2.sx;
    try std.testing.expectEqual(@as(u32, 40), left_width);
    try std.testing.expectEqual(@as(u32, 39), right_width);

    try std.testing.expectEqual(true, w.toggleZoom());
    try std.testing.expect(w.flags.zoomed);
    try std.testing.expectEqual(@as(u32, 80), p2.sx);
    try std.testing.expectEqual(@as(u32, 24), p2.sy);
    try std.testing.expectEqual(@as(u32, 0), p1.sx);
    try std.testing.expectEqual(@as(u32, 0), p1.sy);

    try std.testing.expectEqual(false, w.toggleZoom());
    try std.testing.expect(!w.flags.zoomed);
    try std.testing.expect(p1.sx > 0);
    try std.testing.expect(p2.sx > 0);
    try std.testing.expectEqual(@as(u32, 79), p1.sx + p2.sx);
}
