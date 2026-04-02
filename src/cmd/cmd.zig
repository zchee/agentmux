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
        _ = ctx.server.findSession(name) orelse return CmdError.SessionNotFound;
        // TODO: actually remove the session from the server's list
    } else if (ctx.session) |_| {
        // TODO: kill current session
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
    _ = ctx;
    // TODO: send detach message to client
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

fn cmdSendKeys(_: *Context, _: []const []const u8) CmdError!void {
    // TODO: parse key strings and send to active pane
}

test "registry register and find" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    try std.testing.expect(reg.find("new-session") != null);
    try std.testing.expect(reg.find("new") != null); // alias
    try std.testing.expect(reg.find("kill-server") != null);
    try std.testing.expect(reg.find("nonexistent") == null);
}
