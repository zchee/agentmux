const std = @import("std");
const protocol = @import("../protocol.zig");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/agentmux-option-test.sock");
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
