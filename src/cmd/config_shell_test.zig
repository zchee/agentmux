const std = @import("std");
const protocol = @import("../protocol.zig");
const cmd = @import("cmd.zig");
const BindingManager = @import("../keybind/bindings.zig").BindingManager;
const Server = @import("../server.zig").Server;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;

fn initServer() !Server {
    return Server.init(std.testing.allocator, "/tmp/zmux-config-shell-test.sock");
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

const POLLIN: i16 = 0x0001;

const BlockingWait = struct {
    registry: *const cmd.Registry,
    ctx: *cmd.Context,
    args: []const []const u8,
    done_fd: std.c.fd_t,
    err: ?cmd.CmdError = null,

    fn run(self: *BlockingWait) void {
        self.registry.execute(self.ctx, "wait-for", self.args) catch |err| {
            self.err = err;
        };
        const byte = [_]u8{1};
        _ = std.c.write(self.done_fd, &byte, byte.len);
        _ = std.c.close(self.done_fd);
    }
};

fn waitForNotification(fd: std.c.fd_t, timeout_ms: i32) !bool {
    var pfd = [_]std.c.pollfd{
        .{ .fd = fd, .events = POLLIN, .revents = 0 },
    };
    const rc = std.c.poll(&pfd, pfd.len, timeout_ms);
    try std.testing.expect(rc >= 0);
    return rc == 1 and (pfd[0].revents & POLLIN) != 0;
}

// ── source-file ───────────────────────────────────────────────────────────

test "source-file -q silences missing file error" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    // Should not return an error even though file doesn't exist
    try registry.execute(&ctx, "source-file", &.{ "-q", "/tmp/zmux-nonexistent-file-xyz.conf" });
}

test "source-file -n does syntax check only without executing" {
    var server = try initServer();
    defer server.deinit();

    const session = try makeSession("demo");
    try server.sessions.append(std.testing.allocator, session);

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    // Write a temp file with a command that would change state if executed
    const tmp_path = "/tmp/zmux-syntax-check-test.conf";
    {
        const content = "set-option base-index 99\n";
        const cpath: [*:0]const u8 = tmp_path;
        const fd = std.c.open(cpath, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            _ = std.c.write(fd, content.ptr, content.len);
            _ = std.c.close(fd);
        }
    }
    defer _ = std.c.unlink(tmp_path);

    var ctx = initContext(&server, session, &registry, null);
    try registry.execute(&ctx, "source-file", &.{ "-n", tmp_path });

    // State should NOT have changed because -n only parses
    try std.testing.expectEqual(@as(u32, 0), session.options.base_index);
}

test "source-file parses escaped semicolons and line continuations for bind-key commands" {
    var server = try initServer();
    defer server.deinit();

    var bindings = BindingManager.init(std.testing.allocator);
    defer bindings.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const tmp_path = "/tmp/zmux-source-file-bind-key-compat.conf";
    {
        const content =
            "bind-key r \\\n" ++
            "  source-file ~/.tmux.conf \\; display-message 'reloaded'\n";
        const cpath: [*:0]const u8 = tmp_path;
        const fd = std.c.open(cpath, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
        if (fd >= 0) {
            _ = std.c.write(fd, content.ptr, content.len);
            _ = std.c.close(fd);
        }
    }
    defer _ = std.c.unlink(tmp_path);

    var ctx = initContext(&server, null, &registry, null);
    ctx.binding_manager = &bindings;

    try registry.execute(&ctx, "source-file", &.{tmp_path});

    const table = bindings.tables.get("prefix") orelse return error.ExpectedTable;
    try std.testing.expectEqual(@as(usize, 1), table.bindings.items.len);
    const binding = table.bindings.items[0];
    switch (binding.action) {
        .command => |command| try std.testing.expectEqualStrings(
            "source-file ~/.tmux.conf ; display-message reloaded",
            command,
        ),
        .none => return error.ExpectedCommand,
    }
}

// ── if-shell ─────────────────────────────────────────────────────────────

test "if-shell -F treats format string as condition" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, null, &registry, fds[1]);
    // Non-empty format string = true
    try registry.execute(&ctx, "if-shell", &.{ "-F", "1", "display-message format-true", "display-message format-false" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "format-true") != null);
}

test "if-shell -F with empty string is false" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, null, &registry, fds[1]);
    try registry.execute(&ctx, "if-shell", &.{ "-F", "0", "display-message format-true", "display-message format-false" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "format-false") != null);
}

// ── run-shell ─────────────────────────────────────────────────────────────

test "run-shell -C executes tmux command" {
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
    try registry.execute(&ctx, "run-shell", &.{ "-C", "display-message from-run-shell" });

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "from-run-shell") != null);
}

test "run-shell without flags runs a shell command" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "run-shell", &.{"true"});
}

// ── set-hook / show-hooks ─────────────────────────────────────────────────

test "set-hook registers a hook command" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "set-hook", &.{ "after-new-session", "display-message new-session-hook" });

    try std.testing.expectEqual(@as(usize, 1), server.hook_registry.hookCount(.after_new_session));
    const hooks = server.hook_registry.getHooks(.after_new_session);
    try std.testing.expectEqualStrings("display-message new-session-hook", hooks[0].command);
}

test "set-hook -a appends a hook" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "set-hook", &.{ "after-new-window", "display-message hook1" });
    try registry.execute(&ctx, "set-hook", &.{ "-a", "after-new-window", "display-message hook2" });

    try std.testing.expectEqual(@as(usize, 2), server.hook_registry.hookCount(.after_new_window));
}

test "set-hook without -a replaces existing hook" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "set-hook", &.{ "after-new-window", "display-message old" });
    try registry.execute(&ctx, "set-hook", &.{ "after-new-window", "display-message new" });

    try std.testing.expectEqual(@as(usize, 1), server.hook_registry.hookCount(.after_new_window));
    const hooks = server.hook_registry.getHooks(.after_new_window);
    try std.testing.expectEqualStrings("display-message new", hooks[0].command);
}

test "set-hook -u removes hook" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "set-hook", &.{ "after-select-pane", "display-message pane-hook" });
    try std.testing.expectEqual(@as(usize, 1), server.hook_registry.hookCount(.after_select_pane));

    try registry.execute(&ctx, "set-hook", &.{ "-u", "after-select-pane" });
    try std.testing.expectEqual(@as(usize, 0), server.hook_registry.hookCount(.after_select_pane));
}

test "show-hooks lists registered hooks" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    server.hook_registry.addHook(.client_attached, "display-message attached") catch unreachable;

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, null, &registry, fds[1]);
    try registry.execute(&ctx, "show-hooks", &.{});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "client-attached") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "attached") != null);
}

// ── prompt history ────────────────────────────────────────────────────────

test "clear-prompt-history empties history" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    // Manually add history entries
    const e1 = try std.testing.allocator.dupe(u8, "cmd1");
    try server.prompt_history.append(std.testing.allocator, e1);
    const e2 = try std.testing.allocator.dupe(u8, "cmd2");
    try server.prompt_history.append(std.testing.allocator, e2);
    try std.testing.expectEqual(@as(usize, 2), server.prompt_history.items.len);

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "clear-prompt-history", &.{});

    try std.testing.expectEqual(@as(usize, 0), server.prompt_history.items.len);
}

test "show-prompt-history displays entries" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const e1 = try std.testing.allocator.dupe(u8, "display-message hi");
    try server.prompt_history.append(std.testing.allocator, e1);

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = initContext(&server, null, &registry, fds[1]);
    try registry.execute(&ctx, "show-prompt-history", &.{});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "display-message hi") != null);
}

// ── wait-for ─────────────────────────────────────────────────────────────

test "wait-for -L locks a channel" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "wait-for", &.{ "-L", "my-channel" });

    try std.testing.expect(server.wait_channels.contains("my-channel"));
}

test "wait-for -S does not release a lock channel" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "wait-for", &.{ "-L", "chan" });
    try std.testing.expect(server.wait_channels.contains("chan"));

    try registry.execute(&ctx, "wait-for", &.{ "-S", "chan" });
    const channel = server.wait_channels.get("chan").?;
    try std.testing.expect(channel.locked);
    try std.testing.expectEqual(@as(usize, 0), channel.waiters.items.len);
}

test "wait-for blocks until wait-for -S signals the same channel" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const done_pipe = try makePipe();
    defer _ = std.c.close(done_pipe[0]);

    var wait_ctx = initContext(&server, null, &registry, null);
    var signal_ctx = initContext(&server, null, &registry, null);
    const wait_args = [_][]const u8{"blocking-channel"};
    var blocking_wait = BlockingWait{
        .registry = &registry,
        .ctx = &wait_ctx,
        .args = wait_args[0..],
        .done_fd = done_pipe[1],
    };

    var thread = try std.Thread.spawn(.{}, BlockingWait.run, .{&blocking_wait});
    defer thread.join();

    try std.testing.expect(!try waitForNotification(done_pipe[0], 100));
    try registry.execute(&signal_ctx, "wait-for", &.{ "-S", "blocking-channel" });
    try std.testing.expect(try waitForNotification(done_pipe[0], 1000));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(done_pipe[0], &byte, byte.len));
    try std.testing.expect(blocking_wait.err == null);
    try std.testing.expect(!server.wait_channels.contains("blocking-channel"));
}

test "wait-for -L blocks until wait-for -U unlocks the channel" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    const done_pipe = try makePipe();
    defer _ = std.c.close(done_pipe[0]);

    var lock_ctx = initContext(&server, null, &registry, null);
    var waiter_ctx = initContext(&server, null, &registry, null);
    var unlock_ctx = initContext(&server, null, &registry, null);

    try registry.execute(&lock_ctx, "wait-for", &.{ "-L", "lock-channel" });

    const wait_args = [_][]const u8{ "-L", "lock-channel" };
    var blocking_wait = BlockingWait{
        .registry = &registry,
        .ctx = &waiter_ctx,
        .args = wait_args[0..],
        .done_fd = done_pipe[1],
    };

    var thread = try std.Thread.spawn(.{}, BlockingWait.run, .{&blocking_wait});
    defer thread.join();

    try std.testing.expect(!try waitForNotification(done_pipe[0], 100));
    try registry.execute(&unlock_ctx, "wait-for", &.{ "-U", "lock-channel" });
    try std.testing.expect(try waitForNotification(done_pipe[0], 1000));

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(done_pipe[0], &byte, byte.len));
    try std.testing.expect(blocking_wait.err == null);
    try std.testing.expect(server.wait_channels.contains("lock-channel"));
    try std.testing.expect(server.wait_channels.get("lock-channel").?.locked);

    try registry.execute(&unlock_ctx, "wait-for", &.{ "-U", "lock-channel" });
    try std.testing.expect(!server.wait_channels.contains("lock-channel"));
}

// ── server-access ─────────────────────────────────────────────────────────

test "server-access -a adds allow entry" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "server-access", &.{ "-a", "alice" });

    try std.testing.expectEqual(@as(usize, 1), server.acl_entries.items.len);
    try std.testing.expectEqualStrings("alice", server.acl_entries.items[0].user);
    try std.testing.expect(server.acl_entries.items[0].allow);
}

test "server-access -d removes user entry" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "server-access", &.{ "-a", "bob" });
    try std.testing.expectEqual(@as(usize, 1), server.acl_entries.items.len);

    try registry.execute(&ctx, "server-access", &.{ "-d", "bob" });
    try std.testing.expectEqual(@as(usize, 0), server.acl_entries.items.len);
}

test "server-access -l lists entries" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "server-access", &.{ "-a", "charlie" });

    const fds = try makePipe();
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    ctx.reply_fd = fds[1];
    try registry.execute(&ctx, "server-access", &.{"-l"});

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[0]);
    defer msg.deinit();
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "charlie") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "allow") != null);
}

test "server-access -r marks entry read-only" {
    var server = try initServer();
    defer server.deinit();

    var registry = cmd.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.registerBuiltins();

    var ctx = initContext(&server, null, &registry, null);
    try registry.execute(&ctx, "server-access", &.{ "-r", "dave" });

    try std.testing.expectEqual(@as(usize, 1), server.acl_entries.items.len);
    try std.testing.expect(server.acl_entries.items[0].read_only);
}
