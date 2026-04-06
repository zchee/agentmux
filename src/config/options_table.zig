const std = @import("std");
const options = @import("options.zig");
const colour = @import("../core/colour.zig");

const OptionDef = options.OptionDef;
const OptionScope = options.OptionScope;
const OptionValue = options.OptionValue;
const Style = options.Style;

/// Default option definitions matching tmux's options-table.c.
///
/// Scopes:
///   server  — global server settings
///   session — per-session settings
///   window  — per-window settings
///   pane    — per-pane settings (currently empty)
pub const options_table = [_]OptionDef{
    // -------------------------------------------------------------------------
    // Server options
    // -------------------------------------------------------------------------

    .{
        .name = "default-terminal",
        .scope = .server,
        .option_type = .string,
        .default_value = .{ .string = "screen" },
    },
    .{
        .name = "history-limit",
        .scope = .server,
        .option_type = .number,
        .default_value = .{ .number = 2000 },
    },
    .{
        .name = "escape-time",
        .scope = .server,
        .option_type = .number,
        .default_value = .{ .number = 500 },
    },
    .{
        .name = "set-clipboard",
        .scope = .server,
        .option_type = .string,
        // "external" = pass through to OSC 52; "on" = internal; "off" = disabled.
        .default_value = .{ .string = "external" },
    },

    // -------------------------------------------------------------------------
    // Session options
    // -------------------------------------------------------------------------

    .{
        .name = "base-index",
        .scope = .session,
        .option_type = .number,
        .default_value = .{ .number = 0 },
    },
    .{
        .name = "prefix",
        .scope = .session,
        .option_type = .string,
        .default_value = .{ .string = "C-b" },
    },
    .{
        .name = "status",
        .scope = .session,
        .option_type = .boolean,
        .default_value = .{ .boolean = true },
    },
    .{
        .name = "status-style",
        .scope = .session,
        .option_type = .style,
        .default_value = .{ .style = .{
            .fg = colour.Colour.green,
            .bg = colour.Colour.black,
        } },
    },
    .{
        .name = "status-left",
        .scope = .session,
        .option_type = .string,
        .default_value = .{ .string = "[#S]" },
    },
    .{
        .name = "status-right",
        .scope = .session,
        .option_type = .string,
        .default_value = .{ .string = "#H" },
    },
    .{
        .name = "status-position",
        .scope = .session,
        .option_type = .string,
        .default_value = .{ .string = "bottom" },
    },
    .{
        .name = "status-interval",
        .scope = .session,
        .option_type = .number,
        .default_value = .{ .number = 15 },
    },
    .{
        .name = "mouse",
        .scope = .session,
        .option_type = .boolean,
        .default_value = .{ .boolean = false },
    },
    .{
        .name = "visual-activity",
        .scope = .session,
        .option_type = .boolean,
        .default_value = .{ .boolean = false },
    },

    // -------------------------------------------------------------------------
    // Window options
    // -------------------------------------------------------------------------

    .{
        .name = "mode-keys",
        .scope = .window,
        .option_type = .string,
        // "emacs" or "vi"
        .default_value = .{ .string = "emacs" },
    },
    .{
        .name = "window-status-format",
        .scope = .window,
        .option_type = .string,
        .default_value = .{ .string = "#I:#W#F" },
    },
    .{
        .name = "window-status-current-format",
        .scope = .window,
        .option_type = .string,
        .default_value = .{ .string = "#I:#W#F" },
    },
    .{
        .name = "aggressive-resize",
        .scope = .window,
        .option_type = .boolean,
        .default_value = .{ .boolean = false },
    },
    .{
        .name = "remain-on-exit",
        .scope = .window,
        .option_type = .boolean,
        .default_value = .{ .boolean = false },
    },

    // -------------------------------------------------------------------------
    // Pane options (currently empty — placeholder for future options)
    // -------------------------------------------------------------------------
};

test "options_table has expected entries" {
    // Verify counts per scope.
    var server_count: usize = 0;
    var session_count: usize = 0;
    var window_count: usize = 0;
    var pane_count: usize = 0;

    for (options_table) |def| {
        switch (def.scope) {
            .server => server_count += 1,
            .session => session_count += 1,
            .window => window_count += 1,
            .pane => pane_count += 1,
        }
    }

    try std.testing.expectEqual(@as(usize, 4), server_count);
    try std.testing.expectEqual(@as(usize, 10), session_count);
    try std.testing.expectEqual(@as(usize, 5), window_count);
    try std.testing.expectEqual(@as(usize, 0), pane_count);
}

test "options_table prefix default is C-b" {
    for (options_table) |def| {
        if (std.mem.eql(u8, def.name, "prefix")) {
            try std.testing.expectEqualStrings("C-b", def.default_value.string);
            return;
        }
    }
    return error.PrefixOptionNotFound;
}

test "options_table history-limit default is 2000" {
    for (options_table) |def| {
        if (std.mem.eql(u8, def.name, "history-limit")) {
            try std.testing.expectEqual(@as(i64, 2000), def.default_value.number);
            return;
        }
    }
    return error.HistoryLimitOptionNotFound;
}

test "load options_table into store" {
    const opts = @import("options.zig");

    var store = opts.OptionsStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadDefaults(&options_table);

    // Server option readable at server scope.
    const hist = store.get(.server, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), hist.number);

    // Server option inherited at session scope.
    const hist_sess = store.get(.session, "history-limit").?;
    try std.testing.expectEqual(@as(i64, 2000), hist_sess.number);

    // Session option readable at session scope.
    const mouse = store.get(.session, "mouse").?;
    try std.testing.expect(mouse.boolean == false);

    // Session option inherited at pane scope.
    const mouse_pane = store.get(.pane, "mouse").?;
    try std.testing.expect(mouse_pane.boolean == false);

    // Window option readable at window scope.
    const mode_keys = store.get(.window, "mode-keys").?;
    try std.testing.expectEqualStrings("emacs", mode_keys.string);
}
