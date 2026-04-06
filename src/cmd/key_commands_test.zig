const std = @import("std");
const cmd = @import("cmd.zig");
const BindingManager = @import("../keybind/bindings.zig").BindingManager;
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const protocol = @import("../protocol.zig");

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/zmux-key-cmd-test.sock");
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

fn makeContext(server: *Server, session: ?*Session, reg: *const cmd.Registry, bindings: ?*BindingManager, reply_fd: ?std.c.fd_t) cmd.Context {
    const window = if (session) |s| s.active_window else null;
    return .{
        .server = server,
        .session = session,
        .window = window,
        .pane = if (window) |w| w.active_pane else null,
        .allocator = std.testing.allocator,
        .reply_fd = reply_fd,
        .registry = reg,
        .binding_manager = bindings,
    };
}

// ---------------------------------------------------------------------------
// bind-key: -r stores repeat flag
// ---------------------------------------------------------------------------

test "bind-key -r sets repeat on binding" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    try reg.execute(&ctx, "bind-key", &.{ "-r", "r", "next-window" });

    const table = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expectEqual(@as(usize, 1), table.bindings.items.len);
    try std.testing.expect(table.bindings.items[0].repeat);
}

// ---------------------------------------------------------------------------
// bind-key: -N stores note string
// ---------------------------------------------------------------------------

test "bind-key -N stores note on binding" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    try reg.execute(&ctx, "bind-key", &.{ "-N", "Switch to next window", "n", "next-window" });

    const table = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expectEqual(@as(usize, 1), table.bindings.items.len);
    const note = table.bindings.items[0].note orelse return error.ExpectedNote;
    try std.testing.expectEqualStrings("Switch to next window", note);
}

// ---------------------------------------------------------------------------
// bind-key: -r and -N combined
// ---------------------------------------------------------------------------

test "bind-key -r -N combined sets both fields" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    try reg.execute(&ctx, "bind-key", &.{ "-r", "-N", "Resize pane", "H", "resize-pane -L" });

    const table = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expectEqual(@as(usize, 1), table.bindings.items.len);
    try std.testing.expect(table.bindings.items[0].repeat);
    const note = table.bindings.items[0].note orelse return error.ExpectedNote;
    try std.testing.expectEqualStrings("Resize pane", note);
}

// ---------------------------------------------------------------------------
// list-keys: -T filters by table name
// ---------------------------------------------------------------------------

test "list-keys -T filters by table" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    try reg.execute(&ctx, "bind-key", &.{ "-T", "prefix", "c", "new-window" });
    try reg.execute(&ctx, "bind-key", &.{ "-T", "root", "M-c", "new-window" });

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    ctx.reply_fd = fds[1];
    try reg.execute(&ctx, "list-keys", &.{ "-T", "prefix" });
    _ = std.c.close(fds[1]);
    ctx.reply_fd = null;

    var buf: [1024]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    const output = buf[0..@max(0, @as(usize, @intCast(n)))];
    // Should contain "prefix" table bindings but not root bindings
    try std.testing.expect(std.mem.indexOf(u8, output, "prefix") != null);
}

// ---------------------------------------------------------------------------
// list-keys: -N shows only bindings with notes
// ---------------------------------------------------------------------------

test "list-keys -N shows only bindings with notes" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = makeContext(&server, null, &reg, &bindings, fds[1]);
    // One binding with note, one without
    try reg.execute(&ctx, "bind-key", &.{ "-N", "My note", "x", "kill-pane" });
    try reg.execute(&ctx, "bind-key", &.{ "y", "next-window" });

    ctx.reply_fd = fds[1];
    try reg.execute(&ctx, "list-keys", &.{"-N"});
    _ = std.c.close(fds[1]);
    ctx.reply_fd = null;

    // Read all output
    var all: [2048]u8 = undefined;
    const total = std.c.read(fds[0], &all, all.len);
    const output = all[0..@max(0, @as(usize, @intCast(total)))];

    // Should contain the noted binding
    try std.testing.expect(std.mem.indexOf(u8, output, "My note") != null);
    // Should not contain the non-noted binding key alone
    // (y binding should not appear in notes-only output)
    const y_line_count = std.mem.count(u8, output, " y ");
    try std.testing.expectEqual(@as(usize, 0), y_line_count);
}

// ---------------------------------------------------------------------------
// send-keys: -l literal mode does not interpret key names
// ---------------------------------------------------------------------------

test "send-keys -l sends Enter as literal bytes" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null, null);
    try reg.execute(&ctx, "send-keys", &.{ "-l", "Enter" });

    var buf: [16]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    // With -l, "Enter" is sent as the literal 5-byte string, not \n
    try std.testing.expectEqualStrings("Enter", buf[0..@intCast(n)]);
}

// ---------------------------------------------------------------------------
// send-keys: -H sends hex byte
// ---------------------------------------------------------------------------

test "send-keys -H interprets arg as hex byte" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null, null);
    // 0x41 = 'A'
    try reg.execute(&ctx, "send-keys", &.{ "-H", "41" });

    var buf: [4]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 1), n);
    try std.testing.expectEqual(@as(u8, 0x41), buf[0]);
}

// ---------------------------------------------------------------------------
// send-keys: -N repeat count
// ---------------------------------------------------------------------------

test "send-keys -N repeats key N times" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null, null);
    try reg.execute(&ctx, "send-keys", &.{ "-l", "-N", "3", "x" });

    var buf: [16]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 3), n);
    try std.testing.expectEqualStrings("xxx", buf[0..@intCast(n)]);
}

// ---------------------------------------------------------------------------
// send-prefix: -2 sends secondary prefix
// ---------------------------------------------------------------------------

test "send-prefix -2 sends secondary prefix byte" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    session.options.prefix2_key = 0x01; // C-a

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null, null);
    try reg.execute(&ctx, "send-prefix", &.{"-2"});

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &buf, 1));
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}

// ---------------------------------------------------------------------------
// send-prefix: -2 with no secondary prefix set fails
// ---------------------------------------------------------------------------

test "send-prefix -2 without prefix2 set returns CommandFailed" {
    var server = try initServer();
    defer server.deinit();
    const session = try makeSession(&server, "demo");
    const window = session.active_window.?;
    const pane = window.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    // prefix2_key left as null
    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, session, &reg, null, null);
    try std.testing.expectError(
        cmd.CmdError.CommandFailed,
        reg.execute(&ctx, "send-prefix", &.{"-2"}),
    );
}

// ---------------------------------------------------------------------------
// unbind-key: -a unbinds all keys in table
// ---------------------------------------------------------------------------

test "unbind-key -a removes all bindings from table" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();
    try bindings.setupDefaults();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    const prefix_table = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expect(prefix_table.bindings.items.len > 0);

    try reg.execute(&ctx, "unbind-key", &.{ "-a", "-T", "prefix" });

    const after = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expectEqual(@as(usize, 0), after.bindings.items.len);
}

// ---------------------------------------------------------------------------
// unbind-key: -q does not error on unknown key
// ---------------------------------------------------------------------------

test "unbind-key -q on unknown key is silent" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var reg = cmd.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var ctx = makeContext(&server, null, &reg, &bindings, null);
    // Without -q, unknown key string would fail; with -q it should succeed.
    try reg.execute(&ctx, "unbind-key", &.{ "-q", "F999" });
}
