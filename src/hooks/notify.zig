const std = @import("std");
const hooks = @import("hooks.zig");

/// Notify the hook registry that an event occurred.
/// Looks up registered hooks and returns the commands to execute.
pub fn getCommands(registry: *const hooks.HookRegistry, hook_type: hooks.HookType) []const hooks.Hook {
    return registry.getHooks(hook_type);
}

/// Fire a hook event: look up commands and write them to a buffer.
/// Returns a list of command strings to execute.
pub fn fireHook(
    alloc: std.mem.Allocator,
    registry: *const hooks.HookRegistry,
    hook_type: hooks.HookType,
) !std.ArrayListAligned([]const u8, null) {
    var commands: std.ArrayListAligned([]const u8, null) = .empty;
    errdefer commands.deinit(alloc);

    const hook_list = registry.getHooks(hook_type);
    for (hook_list) |hook| {
        try commands.append(alloc, hook.command);
    }
    return commands;
}

test "fire hook" {
    var reg = hooks.HookRegistry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.addHook(.after_new_session, "cmd1");
    try reg.addHook(.after_new_session, "cmd2");

    var cmds = try fireHook(std.testing.allocator, &reg, .after_new_session);
    defer cmds.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), cmds.items.len);
    try std.testing.expectEqualStrings("cmd1", cmds.items[0]);
    try std.testing.expectEqualStrings("cmd2", cmds.items[1]);
}

test "fire hook empty" {
    var reg = hooks.HookRegistry.init(std.testing.allocator);
    defer reg.deinit();

    var cmds = try fireHook(std.testing.allocator, &reg, .client_attached);
    defer cmds.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), cmds.items.len);
}
