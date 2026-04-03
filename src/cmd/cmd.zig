const std = @import("std");
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const Server = @import("../server.zig").Server;

/// Command execution context.
pub const Context = struct {
    server: *Server,
    session: ?*Session,
    window: ?*Window,
    pane: ?*Pane,
    allocator: std.mem.Allocator,
};

/// Command handler function type.
pub const Handler = *const fn (ctx: *Context, args: []const []const u8) CmdError!void;

pub const CmdError = error{
    InvalidArgs,
    SessionNotFound,
    WindowNotFound,
    PaneNotFound,
    CommandFailed,
    OutOfMemory,
};

/// A registered command.
pub const CommandDef = struct {
    name: []const u8,
    alias: ?[]const u8,
    min_args: u8,
    max_args: u8,
    usage: []const u8,
    handler: Handler,
};

/// Command registry.
pub const Registry = struct {
    commands: std.StringHashMap(CommandDef),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .commands = std.StringHashMap(CommandDef).init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.commands.deinit();
    }

    pub fn register(self: *Registry, def: CommandDef) !void {
        try self.commands.put(def.name, def);
        if (def.alias) |alias| {
            try self.commands.put(alias, def);
        }
    }

    pub fn find(self: *const Registry, name: []const u8) ?CommandDef {
        return self.commands.get(name);
    }

    /// Execute a command by name with arguments.
    pub fn execute(self: *const Registry, ctx: *Context, name: []const u8, args: []const []const u8) CmdError!void {
        const def = self.find(name) orelse return CmdError.CommandFailed;
        if (args.len < def.min_args or (def.max_args > 0 and args.len > def.max_args)) {
            return CmdError.InvalidArgs;
        }
        return def.handler(ctx, args);
    }

    /// Register all built-in commands.
    pub fn registerBuiltins(self: *Registry) !void {
        try self.register(.{
            .name = "new-session",
            .alias = "new",
            .min_args = 0,
            .max_args = 10,
            .usage = "new-session [-d] [-s session-name] [-n window-name]",
            .handler = cmdNewSession,
        });
        try self.register(.{
            .name = "kill-server",
            .alias = null,
            .min_args = 0,
            .max_args = 0,
            .usage = "kill-server",
            .handler = cmdKillServer,
        });
        try self.register(.{
            .name = "kill-session",
            .alias = null,
            .min_args = 0,
            .max_args = 2,
            .usage = "kill-session [-t target-session]",
            .handler = cmdKillSession,
        });
        try self.register(.{
            .name = "new-window",
            .alias = "neww",
            .min_args = 0,
            .max_args = 10,
            .usage = "new-window [-d] [-n name]",
            .handler = cmdNewWindow,
        });
        try self.register(.{
            .name = "split-window",
            .alias = "splitw",
            .min_args = 0,
            .max_args = 10,
            .usage = "split-window [-h|-v] [-p percentage]",
            .handler = cmdSplitWindow,
        });
        try self.register(.{
            .name = "select-pane",
            .alias = null,
            .min_args = 0,
            .max_args = 4,
            .usage = "select-pane [-U|-D|-L|-R]",
            .handler = cmdSelectPane,
        });
        try self.register(.{
            .name = "select-window",
            .alias = "selectw",
            .min_args = 0,
            .max_args = 2,
            .usage = "select-window [-t target-window]",
            .handler = cmdSelectWindow,
        });
        try self.register(.{
            .name = "detach-client",
            .alias = "detach",
            .min_args = 0,
            .max_args = 2,
            .usage = "detach-client",
            .handler = cmdDetachClient,
        });
        try self.register(.{
            .name = "list-sessions",
            .alias = "ls",
            .min_args = 0,
            .max_args = 0,
            .usage = "list-sessions",
            .handler = cmdListSessions,
        });
        try self.register(.{
            .name = "send-keys",
            .alias = "send",
            .min_args = 1,
            .max_args = 20,
            .usage = "send-keys key ...",
            .handler = cmdSendKeys,
        });
        try self.register(.{
            .name = "next-window",
            .alias = "next",
            .min_args = 0,
            .max_args = 0,
            .usage = "next-window",
            .handler = cmdNextWindow,
        });
        try self.register(.{
            .name = "previous-window",
            .alias = "prev",
            .min_args = 0,
            .max_args = 0,
            .usage = "previous-window",
            .handler = cmdPrevWindow,
        });
        try self.register(.{
            .name = "last-window",
            .alias = "last",
            .min_args = 0,
            .max_args = 0,
            .usage = "last-window",
            .handler = cmdLastWindow,
        });
        try self.register(.{
            .name = "kill-window",
            .alias = "killw",
            .min_args = 0,
            .max_args = 2,
            .usage = "kill-window [-t target-window]",
            .handler = cmdKillWindow,
        });
        try self.register(.{
            .name = "kill-pane",
            .alias = "killp",
            .min_args = 0,
            .max_args = 2,
            .usage = "kill-pane [-t target-pane]",
            .handler = cmdKillPane,
        });
        try self.register(.{
            .name = "rename-session",
            .alias = null,
            .min_args = 1,
            .max_args = 2,
            .usage = "rename-session new-name",
            .handler = cmdRenameSession,
        });
        try self.register(.{
            .name = "rename-window",
            .alias = "renamew",
            .min_args = 1,
            .max_args = 2,
            .usage = "rename-window new-name",
            .handler = cmdRenameWindow,
        });
        try self.register(.{
            .name = "resize-pane",
            .alias = "resizep",
            .min_args = 0,
            .max_args = 4,
            .usage = "resize-pane [-U|-D|-L|-R] [amount]",
            .handler = cmdResizePane,
        });
        try self.register(.{
            .name = "swap-pane",
            .alias = "swapp",
            .min_args = 0,
            .max_args = 4,
            .usage = "swap-pane [-U|-D]",
            .handler = cmdSwapPane,
        });
        try self.register(.{
            .name = "display-message",
            .alias = "display",
            .min_args = 0,
            .max_args = 10,
            .usage = "display-message [message]",
            .handler = cmdDisplayMessage,
        });
        try self.register(.{
            .name = "source-file",
            .alias = "source",
            .min_args = 1,
            .max_args = 1,
            .usage = "source-file path",
            .handler = cmdSourceFile,
        });
        try self.register(.{
            .name = "list-windows",
            .alias = "lsw",
            .min_args = 0,
            .max_args = 0,
            .usage = "list-windows",
            .handler = cmdListWindows,
        });
        try self.register(.{
            .name = "list-panes",
            .alias = null,
            .min_args = 0,
            .max_args = 0,
            .usage = "list-panes",
            .handler = cmdListPanes,
        });
        try self.register(.{
            .name = "run-shell",
            .alias = "run",
            .min_args = 1,
            .max_args = 2,
            .usage = "run-shell command",
            .handler = cmdRunShell,
        });
    }
};

// -- Command implementations --

fn cmdNewSession(ctx: *Context, args: []const []const u8) CmdError!void {
    var session_name: []const u8 = "0";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            session_name = args[i];
        }
    }
    const shell: [:0]const u8 = "/bin/sh";
    _ = ctx.server.createSession(session_name, shell, 80, 24) catch return CmdError.CommandFailed;
}

fn cmdKillServer(ctx: *Context, _: []const []const u8) CmdError!void {
    ctx.server.stop();
}

fn cmdKillSession(ctx: *Context, args: []const []const u8) CmdError!void {
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        }
    }

    if (target) |name| {
        const session = ctx.server.findSession(name) orelse return CmdError.SessionNotFound;
        ctx.server.removeSession(session);
    } else if (ctx.session) |session| {
        ctx.session = null;
        ctx.server.removeSession(session);
    } else {
        return CmdError.SessionNotFound;
    }
}

fn cmdNewWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var name: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        }
    }
    const window = Window.init(ctx.allocator, name, 80, 24) catch return CmdError.OutOfMemory;
    const pane = Pane.init(ctx.allocator, 80, 24) catch {
        window.deinit();
        return CmdError.OutOfMemory;
    };
    window.addPane(pane) catch return CmdError.OutOfMemory;
    session.addWindow(window) catch return CmdError.OutOfMemory;
}

fn cmdSplitWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = Pane.init(ctx.allocator, window.sx / 2, window.sy) catch return CmdError.OutOfMemory;
    window.addPane(pane) catch return CmdError.OutOfMemory;
}

fn cmdSelectPane(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    window.nextPane();
}

fn cmdSelectWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    const session = ctx.session orelse return CmdError.SessionNotFound;
    session.nextWindow();
}

fn cmdDetachClient(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    // Detach all clients attached to this session
    for (ctx.server.clients.items, 0..) |client, i| {
        if (client.session == session) {
            ctx.server.detachClient(i);
        }
    }
}

fn cmdListSessions(ctx: *Context, _: []const []const u8) CmdError!void {
    for (ctx.server.sessions.items) |session| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s}: {d} windows (attached: {d})\n", .{
            session.name,
            session.windowCount(),
            session.attached,
        }) catch continue;
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

fn cmdSendKeys(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    for (args) |key_str| {
        // Handle named keys
        if (std.mem.eql(u8, key_str, "Enter")) {
            _ = std.c.write(pane.fd, "\n", 1);
        } else if (std.mem.eql(u8, key_str, "Escape")) {
            _ = std.c.write(pane.fd, "\x1b", 1);
        } else if (std.mem.eql(u8, key_str, "Tab")) {
            _ = std.c.write(pane.fd, "\t", 1);
        } else if (std.mem.eql(u8, key_str, "Space")) {
            _ = std.c.write(pane.fd, " ", 1);
        } else if (std.mem.eql(u8, key_str, "BSpace")) {
            _ = std.c.write(pane.fd, "\x7f", 1);
        } else if (key_str.len == 3 and key_str[0] == 'C' and key_str[1] == '-') {
            // Control key: C-a through C-z
            const ch = key_str[2];
            if (ch >= 'a' and ch <= 'z') {
                const ctrl: [1]u8 = .{ch - 'a' + 1};
                _ = std.c.write(pane.fd, &ctrl, 1);
            } else if (ch >= 'A' and ch <= 'Z') {
                const ctrl: [1]u8 = .{ch - 'A' + 1};
                _ = std.c.write(pane.fd, &ctrl, 1);
            } else {
                _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
            }
        } else {
            // Literal string
            _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
        }
    }
}

fn cmdNextWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    session.nextWindow();
}

fn cmdPrevWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    session.prevWindow();
}

fn cmdLastWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (!session.lastWindow()) return CmdError.WindowNotFound;
}

fn cmdKillWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const empty = session.removeWindow(window);
    if (empty) {
        // Session has no windows left — destroy it
        ctx.session = null;
        ctx.server.removeSession(session);
    }
}

fn cmdKillPane(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    const window_empty = window.removePane(pane);
    if (window_empty) {
        // Window has no panes left u2014 remove the window
        const session_empty = session.removeWindow(window);
        if (session_empty) {
            ctx.session = null;
            ctx.server.removeSession(session);
        }
    } else {
        // Rebalance layout to fill the gap
        if (window.layout_root) |root| {
            root.resize(window.sx, window.sy);
        }
    }
}

fn cmdRenameSession(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (args.len == 0) return CmdError.InvalidArgs;
    session.rename(args[args.len - 1]) catch return CmdError.OutOfMemory;
}

fn cmdRenameWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    if (args.len == 0) return CmdError.InvalidArgs;
    window.rename(args[args.len - 1]) catch return CmdError.OutOfMemory;
}

fn cmdResizePane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    var dx: i32 = 0;
    var dy: i32 = 0;
    var amount: u32 = 1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-U")) {
            dy = -1;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            dy = 1;
        } else if (std.mem.eql(u8, args[i], "-L")) {
            dx = -1;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            dx = 1;
        } else {
            // Try to parse as amount
            amount = std.fmt.parseInt(u32, args[i], 10) catch 1;
        }
    }

    if (dx == 0 and dy == 0) return;

    const new_sx = if (dx < 0)
        @max(1, pane.sx -| amount)
    else if (dx > 0)
        pane.sx + amount
    else
        pane.sx;

    const new_sy = if (dy < 0)
        @max(1, pane.sy -| amount)
    else if (dy > 0)
        pane.sy + amount
    else
        pane.sy;

    pane.resize(new_sx, new_sy);

    // Re-layout the window
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdSwapPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var direction: Window.SwapDirection = .next;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-U")) {
            direction = .prev;
        } else if (std.mem.eql(u8, arg, "-D")) {
            direction = .next;
        }
    }

    window.swapActivePane(direction);
}

fn cmdDisplayMessage(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = ctx;
    if (args.len > 0) {
        const msg = args[args.len - 1];
        _ = std.c.write(1, msg.ptr, msg.len);
        _ = std.c.write(1, "\n", 1);
    }
}

fn cmdSourceFile(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];

    // Read file via libc
    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return CmdError.CommandFailed;
    defer _ = std.c.close(fd);

    // Read contents
    var content_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < content_buf.len) {
        const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    // Parse and execute commands
    const config_parser = @import("../config/parser.zig");
    var parser = config_parser.ConfigParser.init(ctx.allocator, content_buf[0..total]);
    var cmds = parser.parseAll() catch return CmdError.CommandFailed;
    defer {
        for (cmds.items) |*c| c.deinit(ctx.allocator);
        cmds.deinit(ctx.allocator);
    }

    // Execute each command (need access to registry — for now, log them)
    for (cmds.items) |cmd_item| {
        var log_buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&log_buf, "source: {s}\n", .{cmd_item.name}) catch continue;
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

fn cmdListWindows(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (session.windows.items, 0..) |w, i| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{d}: {s} ({d} panes)\n", .{
            i,
            w.name,
            w.paneCount(),
        }) catch continue;
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

fn cmdListPanes(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items, 0..) |p, i| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{d}: [{d}x{d}]\n", .{ i, p.sx, p.sy }) catch continue;
        _ = std.c.write(1, msg.ptr, msg.len);
    }
}

fn cmdRunShell(_: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const command = args[args.len - 1];

    // Copy command to null-terminated buffer for execvp
    var cmd_buf: [4096]u8 = .{0} ** 4096;
    if (command.len >= cmd_buf.len) return CmdError.CommandFailed;
    @memcpy(cmd_buf[0..command.len], command);

    const pid = std.c.fork();
    if (pid < 0) return CmdError.CommandFailed;

    if (pid == 0) {
        // Child: exec sh -c <command>
        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..command.len :0]);
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z };
        _ = execvp(sh, &argv);
        std.c.exit(127);
    }

    // Parent: wait for child
    _ = std.c.waitpid(pid, null, 0);
}

extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) i32;

test "registry register and find" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    try std.testing.expect(reg.find("new-session") != null);
    try std.testing.expect(reg.find("new") != null); // alias
    try std.testing.expect(reg.find("kill-server") != null);
    try std.testing.expect(reg.find("nonexistent") == null);
}
