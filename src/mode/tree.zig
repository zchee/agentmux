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
    filtering: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, visible_rows: u32) ModeTree {
        return .{
            .items = .empty,
            .selected = 0,
            .offset = 0,
            .visible_rows = visible_rows,
            .filter = .{0} ** 128,
            .filter_len = 0,
            .filtering = false,
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
        if (self.filtering) {
            return self.handleFilterKey(key);
        }

        switch (key) {
            '/' => {
                self.filtering = true;
                self.filter_len = 0;
                self.ensureValidSelection();
                self.ensureSelectionVisible();
                return .none;
            },
            'j', 0x42 => { // j or Down
                self.moveDown();
                return .none;
            },
            'k', 0x41 => { // k or Up
                self.moveUp();
                return .none;
            },
            '\r' => {
                if (self.getSelected()) |_| return .select;
                return .none;
            },
            'l' => {
                if (self.getSelected()) |item| {
                    if (item.has_children) {
                        if (!self.items.items[self.selected].expanded) {
                            self.items.items[self.selected].expanded = true;
                        }
                        return .none;
                    }
                    return .select;
                }
                return .none;
            },
            'h' => { // collapse
                if (self.getSelected()) |item| {
                    if (item.has_children and item.expanded) {
                        self.items.items[self.selected].expanded = false;
                        return .none;
                    }
                    if (item.depth > 0) {
                        if (self.findParentIndex(self.selected)) |parent_idx| {
                            self.selected = parent_idx;
                            self.ensureSelectionVisible();
                        }
                    }
                }
                return .none;
            },
            'q', 0x1b => return .cancel, // q or ESC
            else => return .none,
        }
    }

    fn handleFilterKey(self: *ModeTree, key: u21) TreeAction {
        switch (key) {
            '\r' => {
                self.filtering = false;
                self.ensureValidSelection();
                self.ensureSelectionVisible();
                return .none;
            },
            0x1b => {
                self.filtering = false;
                self.filter_len = 0;
                self.ensureValidSelection();
                self.ensureSelectionVisible();
                return .none;
            },
            0x7f, 0x08 => {
                if (self.filter_len > 0) self.filter_len -= 1;
                self.ensureValidSelection();
                self.ensureSelectionVisible();
                return .none;
            },
            else => {
                if (key >= 0x20 and key <= 0x7e and self.filter_len < self.filter.len) {
                    self.filter[self.filter_len] = @truncate(key);
                    self.filter_len += 1;
                    self.ensureValidSelection();
                    self.ensureSelectionVisible();
                }
                return .none;
            },
        }
    }

    fn moveDown(self: *ModeTree) void {
        if (self.items.items.len == 0) return;
        var idx = self.selected + 1;
        while (idx < self.items.items.len) : (idx += 1) {
            if (self.isVisibleIndex(idx)) {
                self.selected = idx;
                break;
            }
        }
        self.ensureSelectionVisible();
    }

    fn moveUp(self: *ModeTree) void {
        if (self.items.items.len == 0 or self.selected == 0) return;
        var idx = self.selected;
        while (idx > 0) {
            idx -= 1;
            if (self.isVisibleIndex(idx)) {
                self.selected = idx;
                break;
            }
        }
        self.ensureSelectionVisible();
    }

    fn isVisibleIndex(self: *const ModeTree, index: usize) bool {
        if (index >= self.items.items.len) return false;
        if (self.filter_len > 0) return self.isFilterVisibleIndex(index);
        return self.isExpandedVisibleIndex(index);
    }

    fn isExpandedVisibleIndex(self: *const ModeTree, index: usize) bool {
        const depth = self.items.items[index].depth;
        if (depth == 0) return true;

        var current_depth = depth;
        var i = index;
        while (i > 0 and current_depth > 0) {
            i -= 1;
            const candidate = self.items.items[i];
            if (candidate.depth + 1 == current_depth) {
                if (!candidate.expanded) return false;
                current_depth = candidate.depth;
            }
        }
        return true;
    }

    fn isFilterVisibleIndex(self: *const ModeTree, index: usize) bool {
        return self.itemMatchesFilter(index) or self.hasMatchingAncestor(index) or self.hasMatchingDescendant(index);
    }

    fn itemMatchesFilter(self: *const ModeTree, index: usize) bool {
        if (self.filter_len == 0) return true;
        const item = self.items.items[index];
        return containsIgnoreCase(item.label, self.filter[0..self.filter_len]);
    }

    fn hasMatchingAncestor(self: *const ModeTree, index: usize) bool {
        const depth = self.items.items[index].depth;
        if (depth == 0) return false;

        var current_depth = depth;
        var i = index;
        while (i > 0 and current_depth > 0) {
            i -= 1;
            const candidate = self.items.items[i];
            if (candidate.depth + 1 == current_depth) {
                if (self.itemMatchesFilter(i)) return true;
                current_depth = candidate.depth;
            }
        }
        return false;
    }

    fn hasMatchingDescendant(self: *const ModeTree, index: usize) bool {
        const depth = self.items.items[index].depth;
        var i = index + 1;
        while (i < self.items.items.len) : (i += 1) {
            const candidate = self.items.items[i];
            if (candidate.depth <= depth) break;
            if (self.itemMatchesFilter(i)) return true;
        }
        return false;
    }

    fn ensureSelectionVisible(self: *ModeTree) void {
        var visible_idx: usize = 0;
        var selected_visible_idx: ?usize = null;
        for (self.items.items, 0..) |_, idx| {
            if (!self.isVisibleIndex(idx)) continue;
            if (idx == self.selected) {
                selected_visible_idx = visible_idx;
                break;
            }
            visible_idx += 1;
        }

        const selected_row = selected_visible_idx orelse 0;
        if (selected_row < self.offset) {
            self.offset = selected_row;
        } else if (selected_row >= self.offset + self.visible_rows) {
            self.offset = selected_row - self.visible_rows + 1;
        }
    }

    fn ensureValidSelection(self: *ModeTree) void {
        if (self.items.items.len == 0) {
            self.selected = 0;
            self.offset = 0;
            return;
        }
        if (!self.isVisibleIndex(self.selected)) {
            if (self.firstVisibleIndex()) |idx| {
                self.selected = idx;
            }
        }
    }

    fn firstVisibleIndex(self: *const ModeTree) ?usize {
        for (self.items.items, 0..) |_, idx| {
            if (self.isVisibleIndex(idx)) return idx;
        }
        return null;
    }

    fn findParentIndex(self: *const ModeTree, index: usize) ?usize {
        if (index == 0 or index >= self.items.items.len) return null;
        const depth = self.items.items[index].depth;
        if (depth == 0) return null;

        var i = index;
        while (i > 0) {
            i -= 1;
            if (self.items.items[i].depth + 1 == depth) return i;
        }
        return null;
    }

    /// Render the tree to a buffer.
    pub fn render(self: *const ModeTree, alloc: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListAligned(u8, null) = .empty;
        errdefer buf.deinit(alloc);

        if (self.filter_len > 0 or self.filtering) {
            try buf.append(alloc, '/');
            try buf.appendSlice(alloc, self.filter[0..self.filter_len]);
            try buf.append(alloc, '\n');
        }

        var visible_seen: usize = 0;
        var rendered_any = false;
        for (self.items.items, 0..) |item, actual_idx| {
            if (!self.isVisibleIndex(actual_idx)) continue;
            if (visible_seen < self.offset) {
                visible_seen += 1;
                continue;
            }
            if (visible_seen >= self.offset + self.visible_rows) break;

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
            visible_seen += 1;
            rendered_any = true;
        }

        if (!rendered_any) {
            try buf.appendSlice(alloc, "(no matches)\n");
        }

        return try buf.toOwnedSlice(alloc);
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

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

test "mode tree collapse hides children and navigation skips them" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "session", .depth = 0, .expanded = true, .has_children = true, .tag = 0 });
    try tree.addItem(.{ .label = "window-0", .depth = 1, .expanded = true, .has_children = false, .tag = 1 });
    try tree.addItem(.{ .label = "window-1", .depth = 1, .expanded = true, .has_children = false, .tag = 2 });
    try tree.addItem(.{ .label = "session-2", .depth = 0, .expanded = true, .has_children = false, .tag = 3 });

    _ = tree.handleKey('h');
    try std.testing.expect(!tree.items.items[0].expanded);

    _ = tree.handleKey('j');
    try std.testing.expectEqual(@as(usize, 3), tree.selected);
}

test "mode tree l expands collapsed parent without selecting child" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "session", .depth = 0, .expanded = false, .has_children = true, .tag = 0 });
    try tree.addItem(.{ .label = "window-0", .depth = 1, .expanded = true, .has_children = false, .tag = 1 });

    const action = tree.handleKey('l');
    try std.testing.expectEqual(TreeAction.none, action);
    try std.testing.expect(tree.items.items[0].expanded);
    try std.testing.expectEqual(@as(usize, 0), tree.selected);
}

test "mode tree filter keeps matching descendants and ancestors visible" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "session", .depth = 0, .expanded = false, .has_children = true, .tag = 0 });
    try tree.addItem(.{ .label = "window-alpha", .depth = 1, .expanded = false, .has_children = false, .tag = 1 });
    try tree.addItem(.{ .label = "window-beta", .depth = 1, .expanded = false, .has_children = false, .tag = 2 });

    _ = tree.handleKey('/');
    _ = tree.handleKey('b');
    _ = tree.handleKey('e');
    _ = tree.handleKey('t');
    _ = tree.handleKey('a');

    const rendered = try tree.render(std.testing.allocator);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(containsIgnoreCase(rendered, "session"));
    try std.testing.expect(containsIgnoreCase(rendered, "window-beta"));
    try std.testing.expect(!containsIgnoreCase(rendered, "window-alpha"));
}

test "mode tree filter backspace and escape" {
    var tree = ModeTree.init(std.testing.allocator, 10);
    defer tree.deinit();

    try tree.addItem(.{ .label = "alpha", .depth = 0, .expanded = true, .has_children = false, .tag = 0 });
    try tree.addItem(.{ .label = "beta", .depth = 0, .expanded = true, .has_children = false, .tag = 1 });

    _ = tree.handleKey('/');
    _ = tree.handleKey('b');
    try std.testing.expect(tree.filter_len == 1);
    _ = tree.handleKey(0x7f);
    try std.testing.expect(tree.filter_len == 0);
    _ = tree.handleKey('a');
    try std.testing.expect(tree.filter_len == 1);
    _ = tree.handleKey(0x1b);
    try std.testing.expect(tree.filter_len == 0);
    try std.testing.expect(!tree.filtering);
}
