const std = @import("std");

/// Key binding action.
pub const Action = union(enum) {
    /// Run a tmux command string.
    command: []const u8,
    /// No-op (unbound).
    none,
};

/// A single key binding.
pub const Binding = struct {
    key: u21,
    modifiers: Modifiers,
    action: Action,
    note: ?[]const u8 = null,
    repeat: bool = false,
};

pub const Modifiers = packed struct(u8) {
    ctrl: bool = false,
    meta: bool = false,
    shift: bool = false,
    _padding: u5 = 0,

    pub const none: Modifiers = .{};
};

/// A key table (e.g., "prefix", "root", "copy-mode-vi").
pub const KeyTable = struct {
    name: []const u8,
    bindings: std.ArrayListAligned(Binding, null),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, name: []const u8) KeyTable {
        return .{
            .name = name,
            .bindings = .empty,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *KeyTable) void {
        for (self.bindings.items) |*b| {
            switch (b.action) {
                .command => |cmd| self.allocator.free(cmd),
                .none => {},
            }
            if (b.note) |n| self.allocator.free(n);
        }
        self.bindings.deinit(self.allocator);
    }

    /// Bind a key to a command.
    pub fn bind(self: *KeyTable, key: u21, mods: Modifiers, command: []const u8) !void {
        try self.bindFull(key, mods, command, null, false);
    }

    /// Bind a key with optional note and repeat flag.
    pub fn bindFull(self: *KeyTable, key: u21, mods: Modifiers, command: []const u8, note: ?[]const u8, repeat: bool) !void {
        self.unbind(key, mods);
        const owned_cmd = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned_cmd);
        const owned_note: ?[]const u8 = if (note) |n| try self.allocator.dupe(u8, n) else null;
        try self.bindings.append(self.allocator, .{
            .key = key,
            .modifiers = mods,
            .action = .{ .command = owned_cmd },
            .note = owned_note,
            .repeat = repeat,
        });
    }

    /// Unbind a key.
    pub fn unbind(self: *KeyTable, key: u21, mods: Modifiers) void {
        var i: usize = 0;
        while (i < self.bindings.items.len) {
            const b = &self.bindings.items[i];
            if (b.key == key and @as(u8, @bitCast(b.modifiers)) == @as(u8, @bitCast(mods))) {
                switch (b.action) {
                    .command => |cmd| self.allocator.free(cmd),
                    .none => {},
                }
                _ = self.bindings.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Look up a binding.
    pub fn lookup(self: *const KeyTable, key: u21, mods: Modifiers) ?Action {
        for (self.bindings.items) |b| {
            if (b.key == key and @as(u8, @bitCast(b.modifiers)) == @as(u8, @bitCast(mods))) {
                return b.action;
            }
        }
        return null;
    }
};

/// Key binding manager with multiple tables.
pub const BindingManager = struct {
    tables: std.StringHashMap(KeyTable),
    prefix_key: u21,
    prefix_mods: Modifiers,
    in_prefix: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) BindingManager {
        return .{
            .tables = std.StringHashMap(KeyTable).init(alloc),
            .prefix_key = 'b', // C-b by default
            .prefix_mods = .{ .ctrl = true },
            .in_prefix = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *BindingManager) void {
        var iter = self.tables.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.tables.deinit();
    }

    /// Get or create a key table.
    pub fn getOrCreateTable(self: *BindingManager, name: []const u8) !*KeyTable {
        if (self.tables.getPtr(name)) |table| return table;

        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);

        try self.tables.put(owned_name, KeyTable.init(self.allocator, owned_name));
        return self.tables.getPtr(owned_name).?;
    }

    /// Process a key event. Returns the command to execute, if any.
    pub fn processKey(self: *BindingManager, key: u21, mods: Modifiers) ?[]const u8 {
        if (!self.in_prefix) {
            // Check root table first
            if (self.tables.get("root")) |root| {
                if (root.lookup(key, mods)) |action| {
                    switch (action) {
                        .command => |cmd| return cmd,
                        .none => {},
                    }
                }
            }

            // Check if this is the prefix key
            if (key == self.prefix_key and @as(u8, @bitCast(mods)) == @as(u8, @bitCast(self.prefix_mods))) {
                self.in_prefix = true;
                return null;
            }

            return null;
        }

        // In prefix mode: look up in prefix table
        self.in_prefix = false;

        if (self.tables.get("prefix")) |prefix| {
            if (prefix.lookup(key, mods)) |action| {
                switch (action) {
                    .command => |cmd| return cmd,
                    .none => {},
                }
            }
        }

        return null;
    }

    /// Set up default key bindings (matching tmux defaults).
    pub fn setupDefaults(self: *BindingManager) !void {
        const prefix = try self.getOrCreateTable("prefix");

        // Window management
        try prefix.bind('c', .{}, "new-window");
        try prefix.bind('b', .{ .ctrl = true }, "send-prefix");
        try prefix.bind('n', .{}, "next-window");
        try prefix.bind('p', .{}, "previous-window");
        try prefix.bind('l', .{}, "last-window");
        try prefix.bind('w', .{}, "choose-tree -w");
        try prefix.bind('&', .{}, "kill-window");

        // Pane management
        try prefix.bind('%', .{}, "split-window -h");
        try prefix.bind('"', .{}, "split-window -v");
        try prefix.bind('o', .{}, "select-pane -t :.+");
        try prefix.bind('x', .{}, "kill-pane");
        try prefix.bind('z', .{}, "resize-pane -Z");
        try prefix.bind('{', .{}, "swap-pane -U");
        try prefix.bind('}', .{}, "swap-pane -D");

        // Session management
        try prefix.bind('d', .{}, "detach-client");
        try prefix.bind('s', .{}, "choose-tree -s");
        try prefix.bind('$', .{}, "rename-session");

        // Copy mode
        try prefix.bind('[', .{}, "copy-mode");
        try prefix.bind(']', .{}, "paste-buffer");

        // Misc
        try prefix.bind(':', .{}, "command-prompt");
        try prefix.bind('?', .{}, "list-keys");
        try prefix.bind('t', .{}, "clock-mode");

        // Number keys for window selection
        var digit: u21 = '0';
        while (digit <= '9') : (digit += 1) {
            var buf: [32]u8 = undefined;
            const cmd = std.fmt.bufPrint(&buf, "select-window -t :{d}", .{digit - '0'}) catch continue;
            try prefix.bind(digit, .{}, cmd);
        }
    }
};

test "key table bind and lookup" {
    var table = KeyTable.init(std.testing.allocator, "test");
    defer table.deinit();

    try table.bind('c', .{}, "new-window");
    const action = table.lookup('c', .{}).?;
    switch (action) {
        .command => |cmd| try std.testing.expectEqualStrings("new-window", cmd),
        .none => return error.UnexpectedNone,
    }

    try std.testing.expect(table.lookup('x', .{}) == null);
}

test "binding manager prefix" {
    var mgr = BindingManager.init(std.testing.allocator);
    defer mgr.deinit();

    const prefix = try mgr.getOrCreateTable("prefix");
    try prefix.bind('c', .{}, "new-window");

    // Not in prefix: C-b should activate prefix
    const r1 = mgr.processKey('b', .{ .ctrl = true });
    try std.testing.expect(r1 == null);
    try std.testing.expect(mgr.in_prefix);

    // In prefix: 'c' should return command
    const r2 = mgr.processKey('c', .{});
    try std.testing.expect(r2 != null);
    try std.testing.expectEqualStrings("new-window", r2.?);
    try std.testing.expect(!mgr.in_prefix);
}

test "default deferred bindings produce explicit messages" {
    var mgr = BindingManager.init(std.testing.allocator);
    defer mgr.deinit();
    try mgr.setupDefaults();

    _ = mgr.processKey('b', .{ .ctrl = true });
    const send_prefix = mgr.processKey('b', .{ .ctrl = true });
    try std.testing.expect(send_prefix != null);
    try std.testing.expectEqualStrings("send-prefix", send_prefix.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const choose_tree = mgr.processKey('w', .{});
    try std.testing.expect(choose_tree != null);
    try std.testing.expectEqualStrings("choose-tree -w", choose_tree.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const list_keys = mgr.processKey('?', .{});
    try std.testing.expect(list_keys != null);
    try std.testing.expectEqualStrings("list-keys", list_keys.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const zoom = mgr.processKey('z', .{});
    try std.testing.expect(zoom != null);
    try std.testing.expectEqualStrings("resize-pane -Z", zoom.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const paste = mgr.processKey(']', .{});
    try std.testing.expect(paste != null);
    try std.testing.expectEqualStrings("paste-buffer", paste.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const copy = mgr.processKey('[', .{});
    try std.testing.expect(copy != null);
    try std.testing.expectEqualStrings("copy-mode", copy.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const prompt = mgr.processKey(':', .{});
    try std.testing.expect(prompt != null);
    try std.testing.expectEqualStrings("command-prompt", prompt.?);

    _ = mgr.processKey('b', .{ .ctrl = true });
    const clock = mgr.processKey('t', .{});
    try std.testing.expect(clock != null);
    try std.testing.expectEqualStrings("clock-mode", clock.?);
}
