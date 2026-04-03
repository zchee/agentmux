const std = @import("std");
const protocol = @import("../protocol.zig");
const config_parser = @import("../config/parser.zig");
const BindingManager = @import("../keybind/bindings.zig").BindingManager;
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/agentmux-tmux-equivalent-tests.sock");
}

fn cleanupPaneProcess(pane: *Pane) void {
    if (pane.pid > 0) {
        _ = std.c.kill(pane.pid, .TERM);
        _ = std.c.waitpid(pane.pid, null, 0);
        pane.pid = 0;
    }
    if (pane.fd >= 0) {
        _ = std.c.close(pane.fd);
        pane.fd = -1;
    }
}

fn cleanupServerProcesses(server: *Server) void {
    for (server.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                cleanupPaneProcess(pane);
            }
        }
    }
}

fn appendSession(server: *Server, session: *Session) !void {
    try server.sessions.append(std.testing.allocator, session);
    if (server.default_session == null) server.default_session = session;
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
    const window = if (session) |current_session| current_session.active_window else null;
    return .{
        .server = server,
        .session = session,
        .window = window,
        .pane = if (window) |current_window| current_window.active_pane else null,
        .allocator = std.testing.allocator,
        .reply_fd = reply_fd,
        .registry = registry,
    };
}

fn executeCommandText(registry: *const cmd.Registry, ctx: *cmd.Context, command_text: []const u8) !void {
    var parser = config_parser.ConfigParser.init(std.testing.allocator, command_text);
    var commands = try parser.parseAll();
    defer {
        for (commands.items) |*command| command.deinit(std.testing.allocator);
        commands.deinit(std.testing.allocator);
    }

    try std.testing.expectEqual(@as(usize, 1), commands.items.len);
    try registry.executeParsed(ctx, &commands.items[0]);
}

test "tmux-equivalent new alias creates a session with a live pane" {
    var server = try initServer();
    defer {
        cleanupServerProcesses(&server);
        server.deinit();
    }

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "new", &.{ "-s", "demo" });

    try std.testing.expectEqual(@as(usize, 1), server.sessions.items.len);
    const session = ctx.session orelse return error.ExpectedSession;
    try std.testing.expect(server.default_session == session);
    try std.testing.expectEqualStrings("demo", session.name);
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;
    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expect(pane.fd >= 0);
    try std.testing.expect(pane.pid > 0);
}

test "tmux-equivalent split binding dispatches through the parser" {
    var server = try initServer();
    defer {
        cleanupServerProcesses(&server);
        server.deinit();
    }

    const session = try makeSession("demo");
    try appendSession(&server, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.setupDefaults();

    _ = bindings.processKey('b', .{ .ctrl = true });
    const command_text = bindings.processKey('%', .{}) orelse return error.ExpectedCommand;
    try std.testing.expectEqualStrings("split-window -h", command_text);

    var ctx = initContext(&server, session, &registry, null);
    const original_pane = session.active_window.?.active_pane.?;
    try executeCommandText(&registry, &ctx, command_text);

    const window = session.active_window orelse return error.ExpectedWindow;
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());
    const active_pane = window.active_pane orelse return error.ExpectedPane;
    try std.testing.expect(active_pane != original_pane);
    try std.testing.expect(server.session_loop.getPane(active_pane.id) != null);
}

test "tmux-equivalent select-pane command cycles and resolves pane ids" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try appendSession(&server, session);
    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.active_pane orelse return error.ExpectedPane;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.setupDefaults();

    window.selectPane(first);
    _ = bindings.processKey('b', .{ .ctrl = true });
    const next_command = bindings.processKey('o', .{}) orelse return error.ExpectedCommand;
    try std.testing.expectEqualStrings("select-pane -t :.+", next_command);

    var ctx = initContext(&server, session, &registry, null);
    try executeCommandText(&registry, &ctx, next_command);
    try std.testing.expect(window.active_pane == second);

    var pane_id_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&pane_id_buf, "%{d}", .{first.id});
    try registry.execute(&ctx, "select-pane", &.{ "-t", target });
    try std.testing.expect(window.active_pane == first);

    try std.testing.expectError(cmd.CmdError.PaneNotFound, registry.execute(&ctx, "select-pane", &.{ "-t", "%999999" }));
}

test "tmux-equivalent list-sessions alias emits summaries over the reply pipe" {
    var server = try initServer();
    defer server.deinit();

    const alpha = try makeSession("alpha");
    alpha.attached = 1;
    try appendSession(&server, alpha);

    const beta = try makeSession("beta");
    try appendSession(&server, beta);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, null, &registry, fds[1]);
    try registry.execute(&ctx, "ls", &.{});

    var first = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer first.deinit();
    var second = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer second.deinit();

    try std.testing.expectEqual(protocol.MessageType.output, first.msg_type);
    try std.testing.expectEqual(protocol.MessageType.output, second.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, first.payload, "alpha: 1 windows (attached: 1)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.payload, "beta: 1 windows (attached: 0)\n") != null);
}

test "tmux-equivalent kill-pane alias removes panes and tears down an empty session" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try appendSession(&server, session);
    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.active_pane orelse return error.ExpectedPane;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    window.selectPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "killp", &.{});
    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expect(window.active_pane == first);
    try std.testing.expectEqual(@as(usize, 1), server.sessions.items.len);

    try registry.execute(&ctx, "kill-pane", &.{});
    try std.testing.expect(ctx.session == null);
    try std.testing.expectEqual(@as(usize, 0), server.sessions.items.len);
    try std.testing.expect(server.default_session == null);
}
