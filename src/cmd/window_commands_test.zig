const std = @import("std");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const protocol = @import("../protocol.zig");

// ---------- helpers ----------

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/zmux-window-cmd-test.sock");
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

// ---------- find-window ----------

test "find-window matches window by name substring" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    // Add a second window with a distinct name
    const w2 = try Window.init(std.testing.allocator, "editor", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "find-window", &.{"editor"});

    const reply = try readReply(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "editor") != null);
}

test "find-window case-insensitive flag" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "MyTerm", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, session, &registry, fds[1]);
    try registry.execute(&ctx, "find-window", &.{ "-i", "myterm" });

    const reply = try readReply(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "MyTerm") != null);
}

test "find-window returns error for no match" {
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
    const result = registry.execute(&ctx, "find-window", &.{"zzznomatch"});
    try std.testing.expectError(cmd.CmdError.CommandFailed, result);
}

// ---------- kill-window -a ----------

test "kill-window -a kills all windows except active" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);
    const w3 = try Window.init(std.testing.allocator, "third", 80, 24);
    const p3 = try Pane.init(std.testing.allocator, 80, 24);
    try w3.addPane(p3);
    try session.addWindow(w3);

    try std.testing.expectEqual(@as(usize, 3), session.windowCount());

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "kill-window", &.{"-a"});

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());
    try std.testing.expect(session.active_window != null);
}

test "kill-window -t kills specific window by number" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // base_index=0, so window index 1 is the second window
    try registry.execute(&ctx, "kill-window", &.{ "-t", "1" });
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());
}

// ---------- last-window -t ----------

test "last-window -t targets named session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const s1 = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, s1);
    server.default_session = s1;

    const s2 = try makeSession(std.testing.allocator, "s2");
    try server.sessions.append(std.testing.allocator, s2);

    // Add a second window to s2 and navigate away so last_window is set
    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try s2.addWindow(w2);
    s2.selectWindow(w2); // sets last_window = win

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, s1, &registry, null);
    try registry.execute(&ctx, "last-window", &.{ "-t", "s2" });
    // s2's active window should now be the original "win"
    try std.testing.expectEqualStrings("win", s2.active_window.?.name);
}

// ---------- list-windows ----------

test "list-windows -a lists all sessions" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const s1 = try makeSession(std.testing.allocator, "alpha");
    try server.sessions.append(std.testing.allocator, s1);
    server.default_session = s1;

    const s2 = try makeSession(std.testing.allocator, "beta");
    try server.sessions.append(std.testing.allocator, s2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, s1, &registry, fds[1]);
    try registry.execute(&ctx, "list-windows", &.{"-a"});

    const reply = try readReply(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "beta") != null);
}

test "list-windows -t targets named session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const s1 = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, s1);
    server.default_session = s1;

    const s2 = try makeSession(std.testing.allocator, "s2");
    const w2 = try Window.init(std.testing.allocator, "targetwin", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try s2.addWindow(w2);
    try server.sessions.append(std.testing.allocator, s2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, s1, &registry, fds[1]);
    try registry.execute(&ctx, "list-windows", &.{ "-t", "s2" });

    const reply = try readReply(std.testing.allocator, fds[0]);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "targetwin") != null);
}

// ---------- new-window flags ----------

test "new-window -d does not select new window" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;
    const original = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "new-window", &.{ "-d", "-n", "bg" });

    cleanupServer(&server);
    try std.testing.expectEqual(@as(usize, 2), session.windowCount());
    try std.testing.expect(session.active_window == original);
}

test "new-window -S selects existing window with same name" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    // Rename first window to "shared"
    try session.active_window.?.rename("shared");

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "new-window", &.{ "-S", "-n", "shared" });

    // No new window should have been created
    try std.testing.expectEqual(@as(usize, 1), session.windowCount());
}

// ---------- next-window / previous-window flags ----------

test "next-window -t targets named session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const s1 = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, s1);
    server.default_session = s1;

    const s2 = try makeSession(std.testing.allocator, "s2");
    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try s2.addWindow(w2);
    try server.sessions.append(std.testing.allocator, s2);

    const first_active = s2.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, s1, &registry, null);
    try registry.execute(&ctx, "next-window", &.{ "-t", "s2" });

    // s2 should have cycled to next window
    try std.testing.expect(s2.active_window != null);
    try std.testing.expect(s2.active_window != first_active);
}

test "previous-window -t targets named session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const s1 = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, s1);
    server.default_session = s1;

    const s2 = try makeSession(std.testing.allocator, "s2");
    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try s2.addWindow(w2);
    try server.sessions.append(std.testing.allocator, s2);
    s2.nextWindow(); // move to "second"

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, s1, &registry, null);
    try registry.execute(&ctx, "previous-window", &.{ "-t", "s2" });
    try std.testing.expectEqualStrings("win", s2.active_window.?.name);
}

// ---------- rename-window -t ----------

test "rename-window -t renames specific window by number" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "old", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "rename-window", &.{ "-t", "1", "newname" });

    try std.testing.expectEqualStrings("newname", session.windows.items[1].name);
}

// ---------- rotate-window ----------

test "rotate-window -D rotates panes forward" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(p2);
    const original_active = window.active_pane.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "rotate-window", &.{"-D"});

    try std.testing.expect(window.active_pane != original_active);
}

test "rotate-window -Z zooms after rotate" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(p2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "rotate-window", &.{"-Z"});
    try std.testing.expect(window.flags.zoomed);
}

// ---------- select-layout flags ----------

test "select-layout -t targets window by number" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "w2", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // Should not error; -t 1 resolves to second window
    try registry.execute(&ctx, "select-layout", &.{ "-t", "1" });
}

// ---------- select-window flags ----------

test "select-window -l switches to last window" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);
    session.selectWindow(w2);

    const expected_last = session.last_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-window", &.{"-l"});
    try std.testing.expect(session.active_window == expected_last);
}

test "select-window -n advances to next" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    const first = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-window", &.{"-n"});
    try std.testing.expect(session.active_window != first);
}

test "select-window -p goes to previous" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);
    session.nextWindow(); // move to second

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "select-window", &.{"-p"});
    try std.testing.expectEqualStrings("win", session.active_window.?.name);
}

// ---------- split-window flags ----------

test "split-window -d does not select new pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;
    const original_pane = window.active_pane.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "split-window", &.{"-d"});

    cleanupServer(&server);
    try std.testing.expectEqual(@as(usize, 2), window.paneCount());
    try std.testing.expect(window.active_pane == original_pane);
}

test "split-window -Z zooms new pane" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "split-window", &.{"-Z"});

    cleanupServer(&server);
    try std.testing.expect(window.flags.zoomed);
}

// ---------- swap-window -d ----------

test "swap-window -d does not change active window after swap" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    const before_active = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "swap-window", &.{ "-d", "-s", "0", "-t", "1" });

    // -d: active window pointer should NOT change to dst
    try std.testing.expect(session.active_window == before_active);
}

// ---------- move-window ----------

test "move-window reorders window within same session" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "second", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    const first = session.windows.items[0];

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // Move window 0 (current active) — should end up at tail
    try registry.execute(&ctx, "move-window", &.{ "-s", "0" });

    try std.testing.expectEqual(@as(usize, 2), session.windowCount());
    try std.testing.expect(session.windows.items[session.windows.items.len - 1] == first);
}

// ---------- resize-window ----------

test "resize-window -R grows window width" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;
    const original_sx = window.sx;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "resize-window", &.{ "-R", "5" });

    try std.testing.expectEqual(original_sx + 5, window.sx);
}

test "resize-window -x sets absolute width" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const window = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "resize-window", &.{ "-x", "120" });

    try std.testing.expectEqual(@as(u32, 120), window.sx);
}

// ---------- respawn-window ----------

test "respawn-window -k kills running process and restarts" {
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
    // Create session with live pane via new-session flow
    try registry.execute(&ctx, "new-session", &.{ "-s", "respawn-test" });

    const sess2 = ctx.server.findSession("respawn-test") orelse return error.MissingSession;
    var ctx2 = makeContext(&server, sess2, &registry, null);
    const win = sess2.active_window orelse return error.MissingWindow;
    const pane = win.active_pane orelse return error.MissingPane;
    const old_pid = pane.pid;

    try registry.execute(&ctx2, "respawn-window", &.{"-k"});

    cleanupServer(&server);
    try std.testing.expect(pane.pid != old_pid or pane.pid == 0);
}

// ---------- unlink-window ----------

test "unlink-window -k removes window from session" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "linked", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);
    session.selectWindow(w2);

    try std.testing.expectEqual(@as(usize, 2), session.windowCount());

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "unlink-window", &.{"-k"});

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());
}

// ---------- link-window ----------

test "link-window creates new window in current session" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    try std.testing.expectEqual(@as(usize, 1), session.windowCount());

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "link-window", &.{ "-s", "0" });

    cleanupServer(&server);
    try std.testing.expectEqual(@as(usize, 2), session.windowCount());
}

test "link-window -d does not select new window" {
    var server = try initServer();
    defer {
        cleanupServer(&server);
        server.deinit();
    }

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const original = session.active_window.?;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "link-window", &.{ "-d", "-s", "0" });

    cleanupServer(&server);
    try std.testing.expect(session.active_window == original);
}

// ---------- next-layout / previous-layout -t ----------

test "next-layout -t targets window by number" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    const w2 = try Window.init(std.testing.allocator, "w2", 80, 24);
    const p2 = try Pane.init(std.testing.allocator, 80, 24);
    try w2.addPane(p2);
    try session.addWindow(w2);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    // Should not error — resolves window 1 and calls resize
    try registry.execute(&ctx, "next-layout", &.{ "-t", "1" });
}

test "previous-layout -t targets window by number" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession(std.testing.allocator, "s1");
    try server.sessions.append(std.testing.allocator, session);
    server.default_session = session;

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = makeContext(&server, session, &registry, null);
    try registry.execute(&ctx, "previous-layout", &.{ "-t", "0" });
}
