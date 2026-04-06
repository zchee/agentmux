const std = @import("std");
const protocol = @import("../protocol.zig");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/zmux-option-test.sock");
}

fn makeSession(name: []const u8) !*Session {
    const session = try Session.init(std.testing.allocator, name);
    errdefer session.deinit();
    const window = try Window.init(std.testing.allocator, "win", 80, 24);
    errdefer window.deinit();
    const pane = try Pane.init(std.testing.allocator, 80, 24);
    errdefer pane.deinit();
    try window.addPane(pane);
    try session.addWindow(window);
    return session;
}

fn initContext(server: *Server, session: ?*Session, registry: *const cmd.Registry, reply_fd: ?std.c.fd_t) cmd.Context {
    const window = if (session) |s| s.active_window else null;
    return .{
        .server = server,
        .session = session,
        .window = window,
        .pane = if (window) |w| w.active_pane else null,
        .allocator = std.testing.allocator,
        .reply_fd = reply_fd,
        .registry = registry,
    };
}

fn makePipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    return fds;
}

test "set-option -q suppresses unknown option error" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    // unknown option with -q should not error
    try registry.execute(&ctx, "set-option", &.{ "-q", "unknown-option-xyz", "value" });
}

test "set-option -u is a no-op unset" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);
    session.options.base_index = 5;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    // unset should not crash
    try registry.execute(&ctx, "set-option", &.{ "-u", "base-index" });
}

test "set-option updates visual-activity" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "visual-activity", "on" });
    try std.testing.expect(session.options.visual_activity);

    try registry.execute(&ctx, "set-option", &.{ "visual-activity", "off" });
    try std.testing.expect(!session.options.visual_activity);
}

test "set-option updates status-left and status-right" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "status-left", "[custom-left]" });
    try std.testing.expectEqualStrings("[custom-left]", session.options.status_left);

    try registry.execute(&ctx, "set-option", &.{ "status-right", "[custom-right]" });
    try std.testing.expectEqualStrings("[custom-right]", session.options.status_right);
}

test "set-option updates status-style, status-position, and status-interval" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "status-style", "fg=white,bg=black,bold" });
    try registry.execute(&ctx, "set-option", &.{ "status-position", "top" });
    try registry.execute(&ctx, "set-option", &.{ "status-interval", "3" });

    try std.testing.expectEqual(@import("../core/colour.zig").Colour.white, session.options.status_style.fg);
    try std.testing.expectEqual(@import("../core/colour.zig").Colour.black, session.options.status_style.bg);
    try std.testing.expect(session.options.status_style.attrs.bold);
    try std.testing.expectEqual(.top, session.options.status_position);
    try std.testing.expectEqual(@as(u32, 3), session.options.status_interval);
}

test "set-option -g persists status defaults for future sessions" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "-g", "status-left", "[cfg-left]" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "status-right", "[cfg-right]" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "status-position", "top" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "status-interval", "9" });

    const session = try makeSession("demo");
    defer session.deinit();
    try server.applySessionStatusDefaults(session);

    try std.testing.expectEqualStrings("[cfg-left]", session.options.status_left);
    try std.testing.expectEqualStrings("[cfg-right]", session.options.status_right);
    try std.testing.expectEqual(.top, session.options.status_position);
    try std.testing.expectEqual(@as(u32, 9), session.options.status_interval);
}

test "show-options -v emits value only" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);
    session.options.base_index = 7;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "show-options", &.{ "-v", "base-index" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqualStrings("7\n", msg.payload);
}

test "show-options -q suppresses unknown option error" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "show-options", &.{ "-q", "nonexistent-option" });
}

test "show-options -H shows hooks" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    // Set a hook first
    server.hook_registry.addHook(.after_new_session, "display-message hook-fired") catch unreachable;

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "show-options", &.{"-H"});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "after-new-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "hook-fired") != null);
}

test "set-window-option updates active window options" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-window-option", &.{ "mode-keys", "vi" });
    try registry.execute(&ctx, "set-window-option", &.{ "remain-on-exit", "on" });

    const window = session.active_window orelse return error.MissingWindow;
    try std.testing.expectEqualStrings("vi", window.options.mode_keys);
    try std.testing.expect(window.options.remain_on_exit);
}

test "show-window-options -v emits window option value" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);
    const window = session.active_window orelse return error.MissingWindow;
    try window.setModeKeys("vi");

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "show-window-options", &.{ "-v", "mode-keys" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqualStrings("vi\n", msg.payload);
}

test "set-option -g window option updates defaults for future windows" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "-g", "mode-keys", "vi" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "window-status-current-format", "ACTIVE" });
    try std.testing.expectEqualStrings("vi", server.window_defaults.mode_keys);
    try std.testing.expectEqualStrings("ACTIVE", server.window_defaults.window_status_current_format);

    const future_window = try Window.init(std.testing.allocator, "future", 80, 24);
    defer future_window.deinit();
    try server.applyWindowDefaults(future_window);
    try std.testing.expectEqualStrings("vi", future_window.options.mode_keys);
    try std.testing.expectEqualStrings("ACTIVE", future_window.options.window_status_current_format);
}

test "set-window-option -u restores inherited global default" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-option", &.{ "-g", "mode-keys", "vi" });
    try registry.execute(&ctx, "set-window-option", &.{ "mode-keys", "emacs" });
    try registry.execute(&ctx, "set-window-option", &.{ "-u", "mode-keys" });

    const window = session.active_window orelse return error.MissingWindow;
    try std.testing.expectEqualStrings("vi", window.options.mode_keys);
    try std.testing.expect(!window.options.overrides.mode_keys);
}

test "set-option -g window option preserves local override" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);
    const second = try Window.init(std.testing.allocator, "second", 80, 24);
    try server.applyWindowDefaults(second);
    try session.addWindow(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-window-option", &.{ "window-status-format", "custom-format" });
    try registry.execute(&ctx, "set-window-option", &.{ "window-status-current-format", "custom-current-format" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "window-status-format", "global-format" });
    try registry.execute(&ctx, "set-option", &.{ "-g", "window-status-current-format", "global-current-format" });

    const active = session.active_window orelse return error.MissingWindow;
    try std.testing.expectEqualStrings("custom-format", active.options.window_status_format);
    try std.testing.expectEqualStrings("custom-current-format", active.options.window_status_current_format);
    try std.testing.expect(active.options.overrides.window_status_format);
    try std.testing.expect(active.options.overrides.window_status_current_format);
    try std.testing.expectEqualStrings("global-format", second.options.window_status_format);
    try std.testing.expectEqualStrings("global-current-format", second.options.window_status_current_format);
    try std.testing.expect(!second.options.overrides.window_status_format);
    try std.testing.expect(!second.options.overrides.window_status_current_format);
}

test "set-environment sets variable on session" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-environment", &.{ "MY_VAR", "hello" });

    try std.testing.expectEqualStrings("hello", session.environ.get("MY_VAR").?);
}

test "set-environment -r removes variable" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-environment", &.{ "MY_VAR", "hello" });
    try registry.execute(&ctx, "set-environment", &.{ "-r", "MY_VAR" });

    try std.testing.expect(session.environ.get("MY_VAR") == null);
}

test "set-environment -h sets hidden variable" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "set-environment", &.{ "-h", "SECRET", "topsecret" });

    const entry = session.environ.vars.get("SECRET") orelse return error.Missing;
    try std.testing.expect(entry.hidden);
    try std.testing.expectEqualStrings("topsecret", entry.value.?);
}

test "show-environment lists variables" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    try session.environ.set("PATH", "/usr/bin");

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "show-environment", &.{});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "PATH=/usr/bin") != null);
}

test "show-environment -s uses shell format" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    try session.environ.set("MYVAR", "42");

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "show-environment", &.{"-s"});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "export MYVAR=42;") != null);
}
