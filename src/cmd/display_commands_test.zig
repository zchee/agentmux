const std = @import("std");
const protocol = @import("../protocol.zig");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/agentmux-display-test.sock");
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

test "display-message emits text over reply pipe" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "display-message", &.{"hello world"});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "hello world") != null);
}

test "display-message -I outputs server info" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "display-message", &.{"-I"});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "sessions:") != null);
}

test "display-message -v prefixes output" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "display-message", &.{ "-v", "test" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "[display-message]") != null);
}

test "display-menu renders title and entries" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "display-menu", &.{ "-T", "My Menu", "Option A", "a", "display-message a", "Option B", "b", "display-message b" });

    var msg1 = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg1.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg1.payload, "My Menu") != null);
}

test "copy-mode -d cancels copy state" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    const pane = session.active_window.?.active_pane.?;

    // Put pane in fake copy state
    pane.copy_state = @import("../copy/copy.zig").CopyState.init();
    try std.testing.expect(pane.copy_state != null);

    try registry.execute(&ctx, "copy-mode", &.{"-d"});
    try std.testing.expect(pane.copy_state == null);
}

test "command-prompt -p sets custom prompt text" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "command-prompt", &.{ "-p", "Enter command:" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "Enter command:") != null);
}

test "confirm-before -y executes immediately" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "confirm-before", &.{ "-y", "display-message confirmed" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "confirmed") != null);
}

test "customize-mode lists session options" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("myses");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "customize-mode", &.{});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "myses") != null);
}

test "choose-client builds choose-tree from client list" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    // Register a fake client pointing at the session
    try server.clients.append(std.testing.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "choose-client", &.{});

    // Should have set choose_tree_state
    try std.testing.expect(server.choose_tree_state != null);
}
