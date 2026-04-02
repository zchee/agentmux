const std = @import("std");

/// Layout cell type.
pub const CellType = enum {
    pane,
    horizontal,
    vertical,
};

/// A layout cell in the layout tree.
/// Leaf cells correspond to panes, branch cells split horizontally or vertically.
pub const LayoutCell = struct {
    cell_type: CellType,

    // Position and size (in character cells)
    sx: u32,
    sy: u32,
    xoff: u32,
    yoff: u32,

    // For leaf cells: pane ID
    pane_id: ?u32,

    // Tree structure
    parent: ?*LayoutCell,
    children: std.ArrayListAligned(*LayoutCell, null),

    allocator: std.mem.Allocator,

    pub fn initLeaf(alloc: std.mem.Allocator, pane_id: u32, sx: u32, sy: u32, xoff: u32, yoff: u32) !*LayoutCell {
        const cell = try alloc.create(LayoutCell);
        cell.* = .{
            .cell_type = .pane,
            .sx = sx,
            .sy = sy,
            .xoff = xoff,
            .yoff = yoff,
            .pane_id = pane_id,
            .parent = null,
            .children = .empty,
            .allocator = alloc,
        };
        return cell;
    }

    pub fn initBranch(alloc: std.mem.Allocator, cell_type: CellType, sx: u32, sy: u32, xoff: u32, yoff: u32) !*LayoutCell {
        std.debug.assert(cell_type != .pane);
        const cell = try alloc.create(LayoutCell);
        cell.* = .{
            .cell_type = cell_type,
            .sx = sx,
            .sy = sy,
            .xoff = xoff,
            .yoff = yoff,
            .pane_id = null,
            .parent = null,
            .children = .empty,
            .allocator = alloc,
        };
        return cell;
    }

    pub fn deinit(self: *LayoutCell) void {
        // Recursively free children
        for (self.children.items) |child| {
            child.deinit();
        }
        self.children.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// Add a child cell.
    pub fn addChild(self: *LayoutCell, child: *LayoutCell) !void {
        child.parent = self;
        try self.children.append(self.allocator, child);
    }

    /// Count leaf (pane) cells.
    pub fn countPanes(self: *const LayoutCell) u32 {
        if (self.cell_type == .pane) return 1;
        var count: u32 = 0;
        for (self.children.items) |child| {
            count += child.countPanes();
        }
        return count;
    }

    /// Find a leaf cell by pane ID.
    pub fn findPane(self: *LayoutCell, pane_id: u32) ?*LayoutCell {
        if (self.cell_type == .pane) {
            if (self.pane_id == pane_id) return self;
            return null;
        }
        for (self.children.items) |child| {
            if (child.findPane(pane_id)) |found| return found;
        }
        return null;
    }

    /// Split this leaf cell into two panes.
    /// Returns the new cell for the new pane.
    pub fn split(self: *LayoutCell, direction: CellType, new_pane_id: u32, percent: u32) !*LayoutCell {
        std.debug.assert(self.cell_type == .pane);
        std.debug.assert(direction == .horizontal or direction == .vertical);

        const alloc = self.allocator;
        const old_pane_id = self.pane_id.?;

        // Convert this cell to a branch
        self.cell_type = direction;
        self.pane_id = null;

        // Calculate sizes for the split
        var first_size: u32 = undefined;
        var second_size: u32 = undefined;
        var first_cell: *LayoutCell = undefined;
        var second_cell: *LayoutCell = undefined;

        const pct = @max(10, @min(percent, 90));

        if (direction == .horizontal) {
            // Split left-right
            first_size = self.sx * pct / 100;
            if (first_size == 0) first_size = 1;
            second_size = self.sx - first_size - 1; // -1 for border
            if (second_size == 0) second_size = 1;

            first_cell = try LayoutCell.initLeaf(alloc, old_pane_id, first_size, self.sy, self.xoff, self.yoff);
            second_cell = try LayoutCell.initLeaf(alloc, new_pane_id, second_size, self.sy, self.xoff + first_size + 1, self.yoff);
        } else {
            // Split top-bottom
            first_size = self.sy * pct / 100;
            if (first_size == 0) first_size = 1;
            second_size = self.sy - first_size - 1; // -1 for border
            if (second_size == 0) second_size = 1;

            first_cell = try LayoutCell.initLeaf(alloc, old_pane_id, self.sx, first_size, self.xoff, self.yoff);
            second_cell = try LayoutCell.initLeaf(alloc, new_pane_id, self.sx, second_size, self.xoff, self.yoff + first_size + 1);
        }

        try self.addChild(first_cell);
        try self.addChild(second_cell);

        return second_cell;
    }

    /// Resize the layout tree to fit new dimensions.
    pub fn resize(self: *LayoutCell, new_sx: u32, new_sy: u32) void {
        if (self.cell_type == .pane) {
            self.sx = new_sx;
            self.sy = new_sy;
            return;
        }

        self.sx = new_sx;
        self.sy = new_sy;

        const child_count = self.children.items.len;
        if (child_count == 0) return;

        if (self.cell_type == .horizontal) {
            // Distribute width among children
            const borders = @as(u32, @intCast(child_count)) - 1;
            const available = if (new_sx > borders) new_sx - borders else 1;
            var used: u32 = 0;
            for (self.children.items, 0..) |child, i| {
                const is_last = i == child_count - 1;
                const child_sx = if (is_last) available - used else available / @as(u32, @intCast(child_count));
                child.xoff = self.xoff + used + @as(u32, @intCast(i)); // +i for borders
                child.yoff = self.yoff;
                child.resize(child_sx, new_sy);
                used += child_sx;
            }
        } else {
            // Distribute height among children
            const borders = @as(u32, @intCast(child_count)) - 1;
            const available = if (new_sy > borders) new_sy - borders else 1;
            var used: u32 = 0;
            for (self.children.items, 0..) |child, i| {
                const is_last = i == child_count - 1;
                const child_sy = if (is_last) available - used else available / @as(u32, @intCast(child_count));
                child.xoff = self.xoff;
                child.yoff = self.yoff + used + @as(u32, @intCast(i));
                child.resize(new_sx, child_sy);
                used += child_sy;
            }
        }
    }
};

test "layout leaf" {
    const cell = try LayoutCell.initLeaf(std.testing.allocator, 0, 80, 24, 0, 0);
    defer cell.deinit();
    try std.testing.expectEqual(@as(u32, 1), cell.countPanes());
    try std.testing.expectEqual(@as(u32, 80), cell.sx);
}

test "layout split horizontal" {
    var root = try LayoutCell.initLeaf(std.testing.allocator, 0, 80, 24, 0, 0);
    defer root.deinit();

    _ = try root.split(.horizontal, 1, 50);
    try std.testing.expectEqual(@as(u32, 2), root.countPanes());
    try std.testing.expect(root.findPane(0) != null);
    try std.testing.expect(root.findPane(1) != null);
}

test "layout split vertical" {
    var root = try LayoutCell.initLeaf(std.testing.allocator, 0, 80, 24, 0, 0);
    defer root.deinit();

    _ = try root.split(.vertical, 1, 50);
    try std.testing.expectEqual(@as(u32, 2), root.countPanes());

    const pane0 = root.findPane(0).?;
    const pane1 = root.findPane(1).?;
    // Top pane gets roughly half the height
    try std.testing.expect(pane0.sy > 0);
    try std.testing.expect(pane1.sy > 0);
    try std.testing.expect(pane0.sy + pane1.sy + 1 == 24); // +1 for border
}
