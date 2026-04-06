const std = @import("std");

/// Hook event types.
pub const HookType = enum(u8) {
    after_new_session,
    after_new_window,
    after_split_window,
    after_select_pane,
    after_select_window,
    after_resize_pane,
    after_rename_session,
    after_rename_window,
    client_attached,
    client_detached,
    client_resized,
    pane_exited,
    pane_focus_in,
    pane_focus_out,
    window_linked,
    window_unlinked,
    session_closed,
    session_renamed,
    window_renamed,
};

/// A registered hook.
pub const Hook = struct {
    command: []const u8,
};

/// Hook registry.
pub const HookRegistry = struct {
    hooks: std.AutoHashMap(HookType, std.ArrayListAligned(Hook, null)),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) HookRegistry {
        return .{
            .hooks = std.AutoHashMap(HookType, std.ArrayListAligned(Hook, null)).init(alloc),
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *HookRegistry) void {
        var iter = self.hooks.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.items) |hook| {
                self.allocator.free(hook.command);
            }
            entry.value_ptr.deinit(self.allocator);
        }
        self.hooks.deinit();
    }

    /// Add a hook.
    pub fn addHook(self: *HookRegistry, hook_type: HookType, command: []const u8) !void {
        const owned = try self.allocator.dupe(u8, command);
        errdefer self.allocator.free(owned);

        const result = try self.hooks.getOrPut(hook_type);
        if (!result.found_existing) {
            result.value_ptr.* = .empty;
        }
        try result.value_ptr.append(self.allocator, .{ .command = owned });
    }

    /// Remove a hook by command string.
    pub fn removeHook(self: *HookRegistry, hook_type: HookType, command: []const u8) void {
        const list = self.hooks.getPtr(hook_type) orelse return;
        var i: usize = 0;
        while (i < list.items.len) {
            if (std.mem.eql(u8, list.items[i].command, command)) {
                self.allocator.free(list.items[i].command);
                _ = list.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// Get hooks for a type.
    pub fn getHooks(self: *const HookRegistry, hook_type: HookType) []const Hook {
        const list = self.hooks.get(hook_type) orelse return &.{};
        return list.items;
    }

    /// Count hooks for a type.
    pub fn hookCount(self: *const HookRegistry, hook_type: HookType) usize {
        const list = self.hooks.get(hook_type) orelse return 0;
        return list.items.len;
    }

    /// Fire all hooks for a given event type.
    /// Returns the list of hook commands to execute.
    /// Caller is responsible for executing them in the appropriate context.
    pub fn fire(self: *const HookRegistry, hook_type: HookType) []const Hook {
        return self.getHooks(hook_type);
    }
};

test "add and get hooks" {
    var reg = HookRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.addHook(.after_new_session, "run-shell 'echo hello'");
    try reg.addHook(.after_new_session, "display-message 'new session'");
    try reg.addHook(.after_new_window, "run-shell 'echo window'");

    try std.testing.expectEqual(@as(usize, 2), reg.hookCount(.after_new_session));
    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.after_new_window));
    try std.testing.expectEqual(@as(usize, 0), reg.hookCount(.client_attached));
}

test "remove hook" {
    var reg = HookRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.addHook(.after_new_session, "cmd1");
    try reg.addHook(.after_new_session, "cmd2");
    reg.removeHook(.after_new_session, "cmd1");

    try std.testing.expectEqual(@as(usize, 1), reg.hookCount(.after_new_session));
    const hooks = reg.getHooks(.after_new_session);
    try std.testing.expectEqualStrings("cmd2", hooks[0].command);
}
