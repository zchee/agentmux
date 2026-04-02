const std = @import("std");

/// Action returned from key handling.
pub const TreeAction = enum {
    none,
    select,
    cancel,
    toggle_expand,
};

/// A single item in the mode tree.
pub const TreeItem = struct {
    label: []const u8,
    depth: u8,
    expanded: bool,
    has_children: bool,
    tag: u32, // opaque identifier (session/window/pane id)
};

/// Mode tree for choose-tree, choose-buffer, choose-client.
pub const ModeTree = struct {
    items: std.ArrayListAligned(TreeItem, null),
    selected: usize,
    offset: usize, // scroll offset for display
    visible_rows: u32,
    filter: [128]u8,
    filter_len: u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, visible_rows: u32) ModeTree {
        return .{
            .items = .empty,
            .selected = 0,
            .offset = 0,
            .visible_rows = visible_rows,
            .filter = .{0} ** 128,
            .filter_len = 0,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *ModeTree) void {
        self.items.deinit(self.allocator);
    }

    /// Add an item to the tree.
    pub fn addItem(self: *ModeTree, item: TreeItem) !void {
        try self.items.append(self.allocator, item);
    }

    /// Get the currently selected item.
    pub fn getSelected(self: *const ModeTree) ?TreeItem {
        if (self.items.items.len == 0) return null;
        if (self.selected >= self.items.items.len) return null;
        return self.items.items[self.selected];
    }

    /// Handle a key press. Returns an action.
    pub fn handleKey(self: *ModeTree, key: u21) TreeAction {
        switch (key) {
            'j', 0x42 => { // j or Down
                self.moveDown();
                return .none;
            },
            'k', 0x41 => { // k or Up
                self.moveUp();
                return .none;
            },
            '\r', 'l' => { // Enter or l
                if (self.getSelected()) |item| {
                    if (item.has_children) return .toggle_expand;
                    return .select;
                }
                return .none;
            },
            'h' => { // collapse
                if (self.getSelected()) |item| {
                    if (item.expanded and item.has_children) return .toggle_expand;
                }
                return .none;
            },
            'q', 0x1b => return .cancel, // q or ESC
            else => return .none,
        }
    }

    fn moveDown(self: *ModeTree) void {
        if (self.items.items.len == 0) return;
        if (self.selected < self.items.items.len - 1) {
            self.selected += 1;
        }
        // Scroll if needed
        if (self.selected >= self.offset + self.visible_rows) {
            self.offset = self.selected - self.visible_rows + 1;
        }
    }

    fn moveUp(self: *ModeTree) void {
        if (self.selected > 0) {
            self.selected -= 1;
        }
        if (self.selected < self.offset) {
            self.offset = self.selected;
        }
    }

    /// Get visible items for rendering.
    pub fn visibleItems(self: *const ModeTree) []const TreeItem {
        const start = self.offset;
        const end = @min(self.offset + self.visible_rows, self.items.items.len);
        if (start >= self.items.items.len) return &.{};
        return self.items.items[start..end];
    }

    /// Render the tree to a buffer.
    pub fn render(self: *const ModeTree, alloc: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListAligned(u8, null) = .empty;
        errdefer buf.deinit(alloc);

        const visible = self.visibleItems();
        for (visible, 0..) |item, i| {
            const actual_idx = self.offset + i;
            const is_selected = actual_idx == self.selected;

            // Selection indicator
            if (is_selected) {
                try buf.appendSlice(alloc, "\x1b[7m"); // reverse video
            }

            // Indent
            var d: u8 = 0;
            while (d < item.depth) : (d += 1) {
                try buf.appendSlice(alloc, "  ");
            }

            // Expand indicator
            if (item.has_children) {
                if (item.expanded) {
                    try buf.appendSlice(alloc, "- ");
                } else {
                    try buf.appendSlice(alloc, "+ ");
                }
            } else {
                try buf.appendSlice(alloc, "  ");
            }

            // Label
            try buf.appendSlice(alloc, item.label);

            if (is_selected) {
                try buf.appendSlice(alloc, "\x1b[0m"); // reset
            }
            try buf.append(alloc, '\n');
        }

        return try buf.toOwnedSlice(alloc);
    }
};

test "mode tree navigation" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "session-0", .depth = 0, .expanded = true, .has_children = true, .tag = 0 });
    try tree.addItem(.{ .label = "window-0", .depth = 1, .expanded = false, .has_children = false, .tag = 1 });
    try tree.addItem(.{ .label = "window-1", .depth = 1, .expanded = false, .has_children = false, .tag = 2 });

    try std.testing.expectEqual(@as(usize, 0), tree.selected);

    _ = tree.handleKey('j');
    try std.testing.expectEqual(@as(usize, 1), tree.selected);

    _ = tree.handleKey('j');
    try std.testing.expectEqual(@as(usize, 2), tree.selected);

    _ = tree.handleKey('k');
    try std.testing.expectEqual(@as(usize, 1), tree.selected);
}

test "mode tree select" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "item", .depth = 0, .expanded = false, .has_children = false, .tag = 0 });

    const action = tree.handleKey('\r');
    try std.testing.expectEqual(TreeAction.select, action);
}

test "mode tree cancel" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "item", .depth = 0, .expanded = false, .has_children = false, .tag = 0 });

    const action = tree.handleKey('q');
    try std.testing.expectEqual(TreeAction.cancel, action);
}
