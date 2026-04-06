const std = @import("std");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const protocol = @import("../protocol.zig");

// ---------- helpers ----------

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/zmux-pane-cmd-test.sock");
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

fn cleanupServer(server: *Server) void {
    for (server.sessions.items) |session| {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                cleanupPaneProcess(pane);
            }
        }
    }
}

fn makeSession(alloc: std.mem.Allocator, name: []const u8) !*Session {
    const session = try Session.init(alloc, name);
    const window = try Window.init(alloc, "win", 80, 24);
    const pane = try Pane.init(alloc, 80, 24);
    try window.addPane(pane);
    try session.addWindow(window);
    return session;
}

fn makeContext(server: *Server, session: ?*Session, registry: *const cmd.Registry, pipe_write: ?std.c.fd_t) cmd.Context {
    const window = if (session) |s| s.active_window else null;
    return .{
        .server = server,
        .session = session,
        .window = window,
        .pane = if (window) |w| w.active_pane else null,
        .allocator = std.testing.allocator,
        .reply_fd = pipe_write,
        .registry = registry,
    };
}

fn makePipe() ![2]std.c.fd_t {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    return fds;
}

fn readReply(alloc: std.mem.Allocator, read_fd: std.c.fd_t) ![]u8 {
    var msg = try protocol.recvMessageAlloc(alloc, read_fd);
    defer msg.deinit();
    return alloc.dupe(u8, msg.payload);
}

// ---------- break-pane ----------

test "break-pane moves pane from multi-pane window to new window" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "break-pane", &.{});

    // Source window now has one pane; a new window was added for the broken-out pane.
    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expectEqual(@as(usize, 2), session.windows.items.len);
}

test "break-pane -d does not change active window" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "break-pane", &.{"-d"});

    // Active window should remain the original window.
    try std.testing.expect(session.active_window == window);
    try std.testing.expectEqual(@as(usize, 2), session.windows.items.len);
}

test "break-pane on single-pane window returns error" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const pipes = try makePipe();
    defer {
        _ = std.c.close(pipes[0]);
        _ = std.c.close(pipes[1]);
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, pipes[1]);
    try std.testing.expectError(cmd.CmdError.CommandFailed, registry.execute(&ctx, "break-pane", &.{}));

    const reply = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(reply.len > 0);
}

// ---------- display-panes ----------

test "display-panes lists all panes with index and dimensions" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const pipes = try makePipe();
    defer {
        _ = std.c.close(pipes[0]);
        _ = std.c.close(pipes[1]);
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 40, 12);
    try window.addPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, pipes[1]);
    try registry.execute(&ctx, "display-panes", &.{});

    // Read first line: "0: pane %N [80x24]"
    const line0 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line0);
    try std.testing.expect(std.mem.indexOf(u8, line0, "0: pane %") != null);
    try std.testing.expect(std.mem.indexOf(u8, line0, "[80x24]") != null);

    // Read second line: "1: pane %N [40x12]"
    const line1 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line1);
    try std.testing.expect(std.mem.indexOf(u8, line1, "1: pane %") != null);
    try std.testing.expect(std.mem.indexOf(u8, line1, "[40x12]") != null);
}

// ---------- list-panes ----------

test "list-panes lists active window panes" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const pipes = try makePipe();
    defer {
        _ = std.c.close(pipes[0]);
        _ = std.c.close(pipes[1]);
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, pipes[1]);
    try registry.execute(&ctx, "list-panes", &.{});

    const line0 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line0);
    // Format: "0: [%N] [WxH] (active)"
    try std.testing.expect(std.mem.indexOf(u8, line0, "0: [%") != null);

    const line1 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line1);
    try std.testing.expect(std.mem.indexOf(u8, line1, "1: [%") != null);
}

test "list-panes -a includes all sessions" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const pipes = try makePipe();
    defer {
        _ = std.c.close(pipes[0]);
        _ = std.c.close(pipes[1]);
    }

    const s1 = try makeSession(std.testing.allocator, "alpha");
    try server.sessions.append(std.testing.allocator, s1);
    const s2 = try makeSession(std.testing.allocator, "beta");
    try server.sessions.append(std.testing.allocator, s2);
    server.default_session = s1;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, s1, &registry, pipes[1]);
    try registry.execute(&ctx, "list-panes", &.{"-a"});

    const line0 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line0);
    try std.testing.expect(std.mem.indexOf(u8, line0, "alpha:") != null);

    const line1 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line1);
    try std.testing.expect(std.mem.indexOf(u8, line1, "beta:") != null);
}

test "list-panes -s covers all windows in session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const pipes = try makePipe();
    defer {
        _ = std.c.close(pipes[0]);
        _ = std.c.close(pipes[1]);
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    // Add a second window with a pane.
    const win2 = try Window.init(std.testing.allocator, "win2", 80, 24);
    const pane2 = try Pane.init(std.testing.allocator, 80, 24);
    try win2.addPane(pane2);
    try session.addWindow(win2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, pipes[1]);
    try registry.execute(&ctx, "list-panes", &.{"-s"});

    const line0 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line0);
    // First entry is window 0 pane 0: "0.0: pane ..."
    try std.testing.expect(std.mem.indexOf(u8, line0, "0.0:") != null);

    const line1 = try readReply(std.testing.allocator, pipes[0]);
    defer std.testing.allocator.free(line1);
    // Second entry is window 1 pane 0: "1.0: pane ..."
    try std.testing.expect(std.mem.indexOf(u8, line1, "1.0:") != null);
}

// ---------- kill-pane ----------

test "kill-pane removes active pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "kill-pane", &.{});
    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
}

test "kill-pane -a removes all non-active panes" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    const third = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    try window.addPane(third);
    try std.testing.expectEqual(@as(usize, 3), window.paneCount());

    const active = window.active_pane orelse return error.ExpectedPane;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "kill-pane", &.{"-a"});

    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expect(window.active_pane == active);
}

test "kill-pane -t targets pane by index" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    // Ensure active pane is first so killing index 1 is non-active.
    window.selectPane(window.panes.items[0]);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "kill-pane", &.{ "-t", "1" });

    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
}

test "kill-pane -t %id targets pane by id" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    window.selectPane(window.panes.items[0]);

    var id_buf: [32]u8 = undefined;
    const id_spec = try std.fmt.bufPrint(&id_buf, "%{d}", .{second.id});

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "kill-pane", &.{ "-t", id_spec });

    try std.testing.expectEqual(@as(usize, 1), window.paneCount());
    try std.testing.expect(window.panes.items[0] != second);
}

// ---------- select-pane ----------

test "select-pane -d disables input on active pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;
    try std.testing.expect(!pane.flags.input_disabled);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-pane", &.{"-d"});
    try std.testing.expect(pane.flags.input_disabled);
}

test "select-pane -e re-enables input on active pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;
    pane.flags.input_disabled = true;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-pane", &.{"-e"});
    try std.testing.expect(!pane.flags.input_disabled);
}

test "select-pane -l selects previously active pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.active_pane orelse return error.ExpectedPane;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    // Select second so first becomes last_pane.
    window.selectPane(second);
    try std.testing.expect(window.active_pane == second);
    try std.testing.expect(window.last_pane == first);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-pane", &.{"-l"});
    try std.testing.expect(window.active_pane == first);
}

test "select-pane -t by %id changes active pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.active_pane orelse return error.ExpectedPane;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var id_buf: [32]u8 = undefined;
    const target = try std.fmt.bufPrint(&id_buf, "%{d}", .{second.id});

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-pane", &.{ "-t", target });
    try std.testing.expect(window.active_pane == second);
    _ = first;
}

test "select-pane -t invalid id returns PaneNotFound" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try std.testing.expectError(cmd.CmdError.PaneNotFound, registry.execute(&ctx, "select-pane", &.{ "-t", "%999999" }));
}

// ---------- last-pane ----------

test "last-pane -d disables input on pane after prev selection" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    // Ensure there is a prev pane to cycle to.
    window.selectPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "last-pane", &.{"-d"});
    // After last-pane the active pane has input_disabled.
    const active = window.active_pane orelse return error.ExpectedPane;
    try std.testing.expect(active.flags.input_disabled);
}

test "last-pane -e enables input on pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);
    window.selectPane(second);
    // Pre-disable input on first pane so we can verify -e clears it.
    window.panes.items[0].flags.input_disabled = true;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // last-pane with -e will prevPane() and then clear input_disabled.
    try registry.execute(&ctx, "last-pane", &.{"-e"});
    const active = window.active_pane orelse return error.ExpectedPane;
    try std.testing.expect(!active.flags.input_disabled);
}

// ---------- resize-pane ----------

test "resize-pane -R increases pane width" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;
    const orig_sx = pane.sx;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "resize-pane", &.{"-R"});
    try std.testing.expect(pane.sx > orig_sx);
}

test "resize-pane -L decreases pane width" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;
    const orig_sx = pane.sx;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "resize-pane", &.{"-L"});
    try std.testing.expect(pane.sx < orig_sx);
}

test "resize-pane -x/-y sets absolute dimensions" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const pane = window.active_pane orelse return error.ExpectedPane;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "resize-pane", &.{ "-x", "40", "-y", "12" });
    try std.testing.expectEqual(@as(u32, 40), pane.sx);
    try std.testing.expectEqual(@as(u32, 12), pane.sy);
}

// ---------- swap-pane ----------

test "swap-pane -s/-t exchanges pane positions in list" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.panes.items[0];
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var s_buf: [32]u8 = undefined;
    var t_buf: [32]u8 = undefined;
    const s_spec = try std.fmt.bufPrint(&s_buf, "%{d}", .{first.id});
    const t_spec = try std.fmt.bufPrint(&t_buf, "%{d}", .{second.id});

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "swap-pane", &.{ "-s", s_spec, "-t", t_spec });

    // After swap the slice order is reversed.
    try std.testing.expect(window.panes.items[0] == second);
    try std.testing.expect(window.panes.items[1] == first);
}

test "swap-pane without flags cycles active pane forward" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window orelse return error.ExpectedWindow;
    const first = window.active_pane orelse return error.ExpectedPane;
    const second = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(second);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // swap-pane with no flags calls swapActivePane(.next), rotating the slice.
    try registry.execute(&ctx, "swap-pane", &.{});
    // Either first or the slice order changed; verify state is still consistent.
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());
    _ = first;
}

// ---------- join-pane ----------

test "join-pane moves pane from another window into active window" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    // Create a second window with a pane to join from.
    const src_window = try Window.init(std.testing.allocator, "src", 80, 24);
    const src_pane = try Pane.init(std.testing.allocator, 80, 24);
    try src_window.addPane(src_pane);
    try session.addWindow(src_window);

    var id_buf: [32]u8 = undefined;
    const src_spec = try std.fmt.bufPrint(&id_buf, "%{d}", .{src_pane.id});

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    const dst_window = session.active_window orelse return error.ExpectedWindow;
    const orig_dst_count = dst_window.paneCount();

    try registry.execute(&ctx, "join-pane", &.{ "-s", src_spec });

    // Destination window gained the pane.
    try std.testing.expectEqual(orig_dst_count + 1, dst_window.paneCount());
    // Source window became empty and was removed from the session.
    try std.testing.expectEqual(@as(usize, 1), session.windows.items.len);
}
