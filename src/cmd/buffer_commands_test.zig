const std = @import("std");
const cmd = @import("cmd.zig");
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const protocol = @import("../protocol.zig");

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/agentmux-buffer-cmd-test.sock");
}

fn makeSession(server: *Server, name: []const u8) !*Session {
    const session = try Session.init(std.testing.allocator, name);
    errdefer session.deinit();
    const window = try Window.init(std.testing.allocator, "win", 80, 24);
    errdefer window.deinit();
    const pane = try Pane.init(std.testing.allocator, 80, 24);
    errdefer pane.deinit();
    try window.addPane(pane);
    try session.addWindow(window);
    try server.sessions.append(std.testing.allocator, session);
    if (server.default_session == null) server.default_session = session;
    return session;
}

fn makeContext(server: *Server, session: ?*Session, reg: *const cmd.Registry, reply_fd: ?std.c.fd_t) cmd.Context {
    const window = if (session) |s| s.active_window else null;
    return .{
        .server = server,
        .session = session,
        .window = window,
        .pane = if (window) |w| w.active_pane else null,
        .allocator = std.testing.allocator,
        .reply_fd = reply_fd,
        .registry = reg,
    };
}

// ---------------------------------------------------------------------------
// choose-buffer: builds buffer list
// ---------------------------------------------------------------------------

test "choose-buffer renders buffer list into choose-tree state" {
    var server = try initServer();
    defer server.deinit();

    try server.paste_stack.push("hello", "buf0");
    try server.paste_stack.push("world", null);

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, null, &reg, fds[1]);
    try reg.execute(&ctx, "choose-buffer", &.{});

    try std.testing.expect(server.choose_tree_state != null);
    try std.testing.expectEqual(@as(usize, 2), server.choose_tree_state.?.items.items.len);
    try std.testing.expect(server.choose_tree_state.?.items.items[0].buffer_index != null);
    try std.testing.expect(server.choose_tree_state.?.items.items[1].buffer_index != null);
}

// ---------------------------------------------------------------------------
// clear-history: -H flag accepted without error
// ---------------------------------------------------------------------------

test "clear-history -H flag is accepted" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null);
    // No pane_state tracked so command fails with CommandFailed, not InvalidArgs.
    const result = reg.execute(&ctx, "clear-history", &.{"-H"});
    try std.testing.expectError(cmd.CmdError.CommandFailed, result);
}

// ---------------------------------------------------------------------------
// list-buffers: -F and -f flags accepted
// ---------------------------------------------------------------------------

test "list-buffers -F and -f flags are accepted" {
    var server = try initServer();
    defer server.deinit();

    try server.paste_stack.push("data", "mybuf");

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, null, &reg, fds[1]);
    try reg.execute(&ctx, "list-buffers", &.{ "-F", "#{buffer_name}", "-f", "#{buffer_name}" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "mybuf") != null);
}

// ---------------------------------------------------------------------------
// load-buffer: stdin path '-'
// ---------------------------------------------------------------------------

test "load-buffer reads from stdin path '-'" {
    var server = try initServer();
    defer server.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    // Replace stdin with a pipe so the test can feed data.
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[1]);

    const test_data = "stdin-content";
    _ = std.c.write(fds[1], test_data.ptr, test_data.len);
    _ = std.c.close(fds[1]);

    const saved_stdin = std.c.dup(0);
    defer {
        _ = std.c.dup2(saved_stdin, 0);
        _ = std.c.close(saved_stdin);
    }
    _ = std.c.dup2(fds[0], 0);
    _ = std.c.close(fds[0]);

    var ctx = makeContext(&server, null, &reg, null);
    try reg.execute(&ctx, "load-buffer", &.{"-"});

    const buf = server.paste_stack.get(0) orelse return error.ExpectedBuffer;
    try std.testing.expectEqualStrings(test_data, buf.data);
}

// ---------------------------------------------------------------------------
// paste-buffer: -d deletes buffer after paste
// ---------------------------------------------------------------------------

test "paste-buffer -d deletes buffer after paste" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try server.paste_stack.push("hello", null);
    try std.testing.expectEqual(@as(usize, 1), server.paste_stack.count());

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null);
    try reg.execute(&ctx, "paste-buffer", &.{"-d"});

    try std.testing.expectEqual(@as(usize, 0), server.paste_stack.count());
}

// ---------------------------------------------------------------------------
// paste-buffer: -r sends raw without newline replacement
// ---------------------------------------------------------------------------

test "paste-buffer -r sends newlines verbatim" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try server.paste_stack.push("line1\nline2", null);

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null);
    try reg.execute(&ctx, "paste-buffer", &.{"-r"});

    var buf: [32]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqualStrings("line1\nline2", buf[0..@intCast(n)]);
}

// ---------------------------------------------------------------------------
// paste-buffer: default replaces newlines with CR (matching tmux)
// ---------------------------------------------------------------------------

test "paste-buffer default replaces newlines with CR" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try server.paste_stack.push("a\nb", null);

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null);
    try reg.execute(&ctx, "paste-buffer", &.{});

    var buf: [16]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqualStrings("a\rb", buf[0..@intCast(n)]);
}

// ---------------------------------------------------------------------------
// paste-buffer: -p wraps with bracketed paste sequences
// ---------------------------------------------------------------------------

test "paste-buffer -p adds bracketed paste markers" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try server.paste_stack.push("hi", null);

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null);
    try reg.execute(&ctx, "paste-buffer", &.{ "-p", "-r" });

    var buf: [32]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    const result = buf[0..@intCast(n)];
    // Should start with ESC[200~ and end with ESC[201~
    try std.testing.expect(std.mem.startsWith(u8, result, "\x1b[200~"));
    try std.testing.expect(std.mem.endsWith(u8, result, "\x1b[201~"));
    try std.testing.expect(std.mem.indexOf(u8, result, "hi") != null);
}

// ---------------------------------------------------------------------------
// set-buffer: -a appends to existing buffer
// ---------------------------------------------------------------------------

test "set-buffer -a appends to existing named buffer" {
    var server = try initServer();
    defer server.deinit();

    try server.paste_stack.push("hello", "mybuf");

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, null);
    try reg.execute(&ctx, "set-buffer", &.{ "-a", "-b", "mybuf", " world" });

    const buf = server.paste_stack.getByName("mybuf") orelse return error.ExpectedBuffer;
    try std.testing.expectEqualStrings("hello world", buf.data);
}

// ---------------------------------------------------------------------------
// set-buffer: -n renames buffer
// ---------------------------------------------------------------------------

test "set-buffer -n renames buffer" {
    var server = try initServer();
    defer server.deinit();

    try server.paste_stack.push("data", "old");

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, null);
    try reg.execute(&ctx, "set-buffer", &.{ "-b", "old", "-n", "new" });

    try std.testing.expect(server.paste_stack.getByName("old") == null);
    try std.testing.expect(server.paste_stack.getByName("new") != null);
}

// ---------------------------------------------------------------------------
// set-buffer: -a with no existing buffer creates new one
// ---------------------------------------------------------------------------

test "set-buffer -a with no existing buffer creates new entry" {
    var server = try initServer();
    defer server.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, null);
    try reg.execute(&ctx, "set-buffer", &.{ "-a", "content" });

    try std.testing.expectEqual(@as(usize, 1), server.paste_stack.count());
    const buf = server.paste_stack.get(0).?;
    try std.testing.expectEqualStrings("content", buf.data);
}

// ---------------------------------------------------------------------------
// Negative: set-buffer -n on missing buffer fails
// ---------------------------------------------------------------------------

test "set-buffer -n on missing buffer returns BufferNotFound" {
    var server = try initServer();
    defer server.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, null);
    try std.testing.expectError(
        cmd.CmdError.BufferNotFound,
        reg.execute(&ctx, "set-buffer", &.{ "-b", "nope", "-n", "other" }),
    );
}
