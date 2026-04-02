const std = @import("std");

/// A single tab entry in the tab bar.
pub const Tab = struct {
    id: u32,
    label: []const u8,
    session_id: u32,
};

/// Native tab bar — rendered at the top of the terminal, above the status bar.
pub const TabBar = struct {
    tabs: std.ArrayListAligned(Tab, null),
    active_tab: usize,
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) TabBar {
        return .{
            .tabs = .empty,
            .active_tab = 0,
            .next_id = 0,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *TabBar) void {
        for (self.tabs.items) |tab| {
            self.allocator.free(tab.label);
        }
        self.tabs.deinit(self.allocator);
    }

    /// Add a tab with the given label and session_id. Returns the new tab's id.
    pub fn addTab(self: *TabBar, label: []const u8, session_id: u32) !u32 {
        const owned_label = try self.allocator.dupe(u8, label);
        errdefer self.allocator.free(owned_label);

        const id = self.next_id;
        self.next_id += 1;

        try self.tabs.append(self.allocator, .{
            .id = id,
            .label = owned_label,
            .session_id = session_id,
        });

        return id;
    }

    /// Remove the tab with the given id. Frees the label. Adjusts active_tab if needed.
    pub fn removeTab(self: *TabBar, id: u32) void {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == id) {
                self.allocator.free(tab.label);
                _ = self.tabs.orderedRemove(i);
                // Clamp active_tab to valid range
                if (self.tabs.items.len > 0 and self.active_tab >= self.tabs.items.len) {
                    self.active_tab = self.tabs.items.len - 1;
                }
                return;
            }
        }
    }

    /// Set the active tab by id.
    pub fn selectTab(self: *TabBar, id: u32) void {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == id) {
                self.active_tab = i;
                return;
            }
        }
    }

    /// Cycle active tab forward (wraps around).
    pub fn nextTab(self: *TabBar) void {
        if (self.tabs.items.len == 0) return;
        self.active_tab = (self.active_tab + 1) % self.tabs.items.len;
    }

    /// Cycle active tab backward (wraps around).
    pub fn prevTab(self: *TabBar) void {
        if (self.tabs.items.len == 0) return;
        if (self.active_tab == 0) {
            self.active_tab = self.tabs.items.len - 1;
        } else {
            self.active_tab -= 1;
        }
    }

    /// Move tab from from_idx to to_idx (both are indices into tabs.items).
    pub fn moveTab(self: *TabBar, from_idx: usize, to_idx: usize) void {
        const n = self.tabs.items.len;
        if (from_idx >= n or to_idx >= n or from_idx == to_idx) return;

        const tab = self.tabs.items[from_idx];
        _ = self.tabs.orderedRemove(from_idx);
        self.tabs.insert(self.allocator, to_idx, tab) catch return;

        // Fix up active_tab index
        if (self.active_tab == from_idx) {
            self.active_tab = to_idx;
        } else if (from_idx < to_idx) {
            if (self.active_tab > from_idx and self.active_tab <= to_idx) {
                self.active_tab -= 1;
            }
        } else {
            if (self.active_tab >= to_idx and self.active_tab < from_idx) {
                self.active_tab += 1;
            }
        }
    }

    /// Return the currently active tab, or null if there are no tabs.
    pub fn getActive(self: *const TabBar) ?Tab {
        if (self.tabs.items.len == 0) return null;
        return self.tabs.items[self.active_tab];
    }

    /// Return the number of tabs.
    pub fn tabCount(self: *const TabBar) usize {
        return self.tabs.items.len;
    }

    /// Render the tab bar as a string fitting within `cols` columns.
    /// Active tab is highlighted with reverse video (\x1b[7m).
    /// Each tab is rendered as " label [x] " with a close indicator.
    /// Caller owns the returned slice.
    pub fn render(self: *const TabBar, alloc: std.mem.Allocator, cols: u32) ![]u8 {
        if (cols == 0 or self.tabs.items.len == 0) {
            return alloc.alloc(u8, 0);
        }

        var buf: std.ArrayListAligned(u8, null) = .empty;
        errdefer buf.deinit(alloc);

        var visible_cols: u32 = 0;

        for (self.tabs.items, 0..) |tab, i| {
            const is_active = (i == self.active_tab);

            // Format the tab cell: " label [x]"
            const cell = try std.fmt.allocPrint(alloc, " {s} [x]", .{tab.label});
            defer alloc.free(cell);

            const cell_len: u32 = @intCast(cell.len);
            if (visible_cols + cell_len > cols) break;

            if (is_active) {
                try buf.appendSlice(alloc, "\x1b[7m");
                try buf.appendSlice(alloc, cell);
                try buf.appendSlice(alloc, "\x1b[0m");
            } else {
                try buf.appendSlice(alloc, cell);
            }

            visible_cols += cell_len;
        }

        // Pad remainder with spaces (no escape codes, so terminal background shows)
        while (visible_cols < cols) : (visible_cols += 1) {
            try buf.append(alloc, ' ');
        }

        return buf.toOwnedSlice(alloc);
    }
};

test "add tabs and tab count" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    const id0 = try bar.addTab("alpha", 1);
    const id1 = try bar.addTab("beta", 2);
    const id2 = try bar.addTab("gamma", 3);

    try std.testing.expectEqual(@as(usize, 3), bar.tabCount());
    try std.testing.expectEqual(@as(u32, 0), id0);
    try std.testing.expectEqual(@as(u32, 1), id1);
    try std.testing.expectEqual(@as(u32, 2), id2);
}

test "select tab by id" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    _ = try bar.addTab("alpha", 1);
    _ = try bar.addTab("beta", 2);
    const id2 = try bar.addTab("gamma", 3);

    bar.selectTab(id2);
    const active = bar.getActive().?;
    try std.testing.expectEqual(id2, active.id);
    try std.testing.expectEqualStrings("gamma", active.label);
}

test "next and prev cycling" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    _ = try bar.addTab("a", 0);
    _ = try bar.addTab("b", 0);
    _ = try bar.addTab("c", 0);

    // Starts at 0
    try std.testing.expectEqual(@as(usize, 0), bar.active_tab);

    bar.nextTab();
    try std.testing.expectEqual(@as(usize, 1), bar.active_tab);

    bar.nextTab();
    try std.testing.expectEqual(@as(usize, 2), bar.active_tab);

    // Wrap forward
    bar.nextTab();
    try std.testing.expectEqual(@as(usize, 0), bar.active_tab);

    // Wrap backward
    bar.prevTab();
    try std.testing.expectEqual(@as(usize, 2), bar.active_tab);

    bar.prevTab();
    try std.testing.expectEqual(@as(usize, 1), bar.active_tab);
}

test "remove tab" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    _ = try bar.addTab("alpha", 1);
    const id1 = try bar.addTab("beta", 2);
    _ = try bar.addTab("gamma", 3);

    bar.removeTab(id1);
    try std.testing.expectEqual(@as(usize, 2), bar.tabCount());

    // Remaining tabs should be alpha and gamma
    try std.testing.expectEqualStrings("alpha", bar.tabs.items[0].label);
    try std.testing.expectEqualStrings("gamma", bar.tabs.items[1].label);
}

test "render width" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    _ = try bar.addTab("one", 1);
    _ = try bar.addTab("two", 2);

    const rendered = try bar.render(std.testing.allocator, 40);
    defer std.testing.allocator.free(rendered);

    // The visible (non-escape-code) width should equal cols.
    // Count printable bytes by stripping ANSI sequences.
    var visible: usize = 0;
    var j: usize = 0;
    while (j < rendered.len) {
        if (rendered[j] == '\x1b') {
            // Skip until 'm'
            while (j < rendered.len and rendered[j] != 'm') : (j += 1) {}
            j += 1; // skip 'm'
        } else {
            visible += 1;
            j += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 40), visible);
}

test "render active tab highlighted" {
    var bar = TabBar.init(std.testing.allocator);
    defer bar.deinit();

    _ = try bar.addTab("hello", 1);

    const rendered = try bar.render(std.testing.allocator, 20);
    defer std.testing.allocator.free(rendered);

    // Active tab should have reverse-video escape
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[7m") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\x1b[0m") != null);
}
