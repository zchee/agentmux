const std = @import("std");
const protocol = @import("../protocol.zig");
const config_parser = @import("../config/parser.zig");
const options_mod = @import("../config/options.zig");
const options_table_mod = @import("../config/options_table.zig");
const binding_mod = @import("../keybind/bindings.zig");
const key_string = @import("../keybind/string.zig");
const paste_mod = @import("../copy/paste.zig");
const copy_mod = @import("../copy/copy.zig");
const status_style = @import("../status/style.zig");
const tree_mod = @import("../mode/tree.zig");
const screen_mod = @import("../screen/screen.zig");
const style_mod = @import("../status/style.zig");
const Pty = @import("../pane.zig").Pty;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const PromptState = @import("../window.zig").PromptState;
const ChooseTreeState = @import("../window.zig").ChooseTreeState;
const ChooseTreeItem = @import("../window.zig").ChooseTreeItem;
const CellType = @import("../layout/layout.zig").CellType;
const Server = @import("../server.zig").Server;

/// Command execution context.
pub const Context = struct {
    server: *Server,
    session: ?*Session,
    window: ?*Window,
    pane: ?*Pane,
    client_index: ?usize = null,
    allocator: std.mem.Allocator,
    reply_fd: ?std.c.fd_t = null,
    registry: ?*const Registry = null,
};

/// Command handler function type.
pub const Handler = *const fn (ctx: *Context, args: []const []const u8) CmdError!void;

pub const CmdError = error{
    InvalidArgs,
    SessionNotFound,
    WindowNotFound,
    PaneNotFound,
    BufferNotFound,
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

    pub fn executeParsed(self: *const Registry, ctx: *Context, command: *const config_parser.Command) CmdError!void {
        return self.execute(ctx, command.name, command.args.items);
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
            .usage = "select-pane [-U|-D|-L|-R] [-t target-pane]",
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
            .name = "set-option",
            .alias = "set",
            .min_args = 2,
            .max_args = 8,
            .usage = "set-option [-g] option value",
            .handler = cmdSetOption,
        });
        try self.register(.{
            .name = "set-window-option",
            .alias = "setw",
            .min_args = 2,
            .max_args = 8,
            .usage = "set-window-option option value",
            .handler = cmdSetWindowOption,
        });
        try self.register(.{
            .name = "bind-key",
            .alias = "bind",
            .min_args = 2,
            .max_args = 16,
            .usage = "bind-key [-T table|-n] key command",
            .handler = cmdBindKey,
        });
        try self.register(.{
            .name = "unbind-key",
            .alias = "unbind",
            .min_args = 1,
            .max_args = 8,
            .usage = "unbind-key [-T table|-n] key",
            .handler = cmdUnbindKey,
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
            .name = "set-option",
            .alias = "set",
            .min_args = 2,
            .max_args = 0,
            .usage = "set-option [-g|-s|-w|-p] option value",
            .handler = cmdSetOption,
        });
        try self.register(.{
            .name = "bind-key",
            .alias = "bind",
            .min_args = 2,
            .max_args = 0,
            .usage = "bind-key [-T table|-n] key command",
            .handler = cmdBindKey,
        });
        try self.register(.{
            .name = "if-shell",
            .alias = "if",
            .min_args = 2,
            .max_args = 3,
            .usage = "if-shell shell-command command-if-true [command-if-false]",
            .handler = cmdIfShell,
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
            .name = "set-buffer",
            .alias = "setb",
            .min_args = 1,
            .max_args = 3,
            .usage = "set-buffer [-b name] data",
            .handler = cmdSetBuffer,
        });
        try self.register(.{
            .name = "paste-buffer",
            .alias = "pasteb",
            .min_args = 0,
            .max_args = 2,
            .usage = "paste-buffer [-b name]",
            .handler = cmdPasteBuffer,
        });
        try self.register(.{
            .name = "copy-mode",
            .alias = "copy",
            .min_args = 0,
            .max_args = 1,
            .usage = "copy-mode",
            .handler = cmdCopyMode,
        });
        try self.register(.{
            .name = "command-prompt",
            .alias = "prompt",
            .min_args = 0,
            .max_args = 8,
            .usage = "command-prompt [initial-command]",
            .handler = cmdCommandPrompt,
        });
        try self.register(.{
            .name = "list-buffers",
            .alias = "lsb",
            .min_args = 0,
            .max_args = 0,
            .usage = "list-buffers",
            .handler = cmdListBuffers,
        });
        try self.register(.{
            .name = "show-buffer",
            .alias = "showb",
            .min_args = 0,
            .max_args = 2,
            .usage = "show-buffer [-b name]",
            .handler = cmdShowBuffer,
        });
        try self.register(.{
            .name = "delete-buffer",
            .alias = "deleteb",
            .min_args = 0,
            .max_args = 2,
            .usage = "delete-buffer [-b name]",
            .handler = cmdDeleteBuffer,
        });
        try self.register(.{
            .name = "list-keys",
            .alias = "lsk",
            .min_args = 0,
            .max_args = 0,
            .usage = "list-keys",
            .handler = cmdListKeys,
        });
        try self.register(.{
            .name = "choose-tree",
            .alias = null,
            .min_args = 0,
            .max_args = 2,
            .usage = "choose-tree [-s|-w]",
            .handler = cmdChooseTree,
        });
        try self.register(.{
            .name = "clock-mode",
            .alias = "clock",
            .min_args = 0,
            .max_args = 0,
            .usage = "clock-mode",
            .handler = cmdClockMode,
        });
        try self.register(.{
            .name = "send-prefix",
            .alias = null,
            .min_args = 0,
            .max_args = 0,
            .usage = "send-prefix",
            .handler = cmdSendPrefix,
        });
        try self.register(.{
            .name = "run-shell",
            .alias = "run",
            .min_args = 1,
            .max_args = 2,
            .usage = "run-shell command",
            .handler = cmdRunShell,
        });
        try self.register(.{
            .name = "if-shell",
            .alias = "if",
            .min_args = 2,
            .max_args = 4,
            .usage = "if-shell shell-command command [else-command]",
            .handler = cmdIfShell,
        });
    }
};

fn writeReplyMessage(ctx: *Context, msg_type: protocol.MessageType, message: []const u8) CmdError!void {
    if (ctx.reply_fd) |fd| {
        protocol.sendMessage(fd, msg_type, message) catch return CmdError.CommandFailed;
        return;
    }

    const target_fd: std.c.fd_t = switch (msg_type) {
        .error_msg => 2,
        else => 1,
    };
    _ = std.c.write(target_fd, message.ptr, message.len);
}

fn writeOutput(ctx: *Context, comptime fmt: []const u8, args: anytype) CmdError!void {
    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch return CmdError.CommandFailed;
    try writeReplyMessage(ctx, .output, message);
}

fn executeCommandSource(ctx: *Context, source: []const u8) CmdError!void {
    const registry = ctx.registry orelse return CmdError.CommandFailed;

    var parser = config_parser.ConfigParser.init(ctx.allocator, source);
    var commands = parser.parseAll() catch return CmdError.CommandFailed;
    defer {
        for (commands.items) |*command| command.deinit(ctx.allocator);
        commands.deinit(ctx.allocator);
    }

    for (commands.items) |*command| {
        try registry.executeParsed(ctx, command);
    }
}

fn joinArgs(alloc: std.mem.Allocator, args: []const []const u8) CmdError![]u8 {
    return std.mem.join(alloc, " ", args) catch return CmdError.OutOfMemory;
}

fn spawnWindowPane(alloc: std.mem.Allocator, shell: [:0]const u8, sx: u32, sy: u32) CmdError!*Pane {
    const pane = Pane.init(alloc, sx, sy) catch return CmdError.OutOfMemory;
    errdefer pane.deinit();

    var pty = Pty.openPty() catch return CmdError.CommandFailed;
    pty.forkExec(shell, null) catch return CmdError.CommandFailed;
    pty.resize(@intCast(sx), @intCast(sy));
    pane.fd = pty.master_fd;
    pane.pid = pty.pid;
    return pane;
}

fn parseTargetWindow(args: []const []const u8) ?u32 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "-t") or i + 1 >= args.len) continue;
        i += 1;
        const target = args[i];
        if (target.len >= 2 and target[0] == ':') {
            return std.fmt.parseInt(u32, target[1..], 10) catch null;
        }
        return std.fmt.parseInt(u32, target, 10) catch null;
    }
    return null;
}

fn defaultShell(_: ?*Session) [:0]const u8 {
    return "/bin/sh";
}

fn sessionDefaultShell(session: ?*Session) [:0]const u8 {
    if (session) |current| {
        if (current.options.default_shell.len > 0) {
            return @ptrCast(current.options.default_shell.ptr);
        }
    }
    return defaultShell(session);
}

const ClockTm = extern struct {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
};

extern "c" fn time(timer: ?*i64) i64;
extern "c" fn localtime(timer: *const i64) ?*ClockTm;

fn parseNamedOption(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn joinArgs(alloc: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    if (parts.len == 0) return try alloc.dupe(u8, "");

    var total: usize = 0;
    for (parts, 0..) |part, i| {
        total += part.len;
        if (i + 1 < parts.len) total += 1;
    }

    var out = try alloc.alloc(u8, total);
    var pos: usize = 0;
    for (parts, 0..) |part, i| {
        @memcpy(out[pos .. pos + part.len], part);
        pos += part.len;
        if (i + 1 < parts.len) {
            out[pos] = ' ';
            pos += 1;
        }
    }
    return out;
}

fn parseBoolValue(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.mem.eql(u8, value, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "off") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.mem.eql(u8, value, "0"))
    {
        return false;
    }
    return null;
}

fn executeCommandText(ctx: *Context, text: []const u8) CmdError!void {
    const registry = ctx.registry orelse return CmdError.CommandFailed;
    var parser = config_parser.ConfigParser.init(ctx.allocator, text);
    var commands = parser.parseAll() catch return CmdError.CommandFailed;
    defer {
        for (commands.items) |*command| command.deinit(ctx.allocator);
        commands.deinit(ctx.allocator);
    }

    for (commands.items) |*command| {
        try registry.executeParsed(ctx, command);
    }
}

fn resolvePasteBuffer(ctx: *Context, name: ?[]const u8) CmdError!*paste_mod.PasteBuffer {
    if (name) |buffer_name| {
        return ctx.server.paste_stack.getByName(buffer_name) orelse CmdError.BufferNotFound;
    }
    return ctx.server.paste_stack.get(0) orelse CmdError.BufferNotFound;
}

fn extractGridLineSlice(alloc: std.mem.Allocator, pane_state: anytype, absolute_y: u32, start_x: u32, end_x: u32) ![]u8 {
    const grid = &pane_state.screen.grid;
    const total_lines = grid.hsize + grid.rows;
    if (absolute_y >= total_lines) return try alloc.dupe(u8, "");

    const line = if (absolute_y < grid.hsize)
        grid.getHistoryLine(absolute_y)
    else
        grid.getLine(absolute_y - grid.hsize);

    const max_x = @min(end_x, grid.cols -| 1);
    if (start_x > max_x) return try alloc.dupe(u8, "");

    var buf: std.ArrayListAligned(u8, null) = .empty;
    defer buf.deinit(alloc);
    var x = start_x;
    while (x <= max_x) : (x += 1) {
        const cell = line.getCell(x);
        const ch: u8 = if (cell.codepoint == 0)
            ' '
        else if (cell.codepoint < 0x80)
            @truncate(cell.codepoint)
        else
            '?';
        try buf.append(alloc, ch);
    }

    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    return try buf.toOwnedSlice(alloc);
}

fn extractCopySelection(alloc: std.mem.Allocator, pane_state: anytype, state: *const copy_mod.CopyState) ![]u8 {
    const grid = &pane_state.screen.grid;
    const total_lines = grid.hsize + grid.rows;
    if (total_lines == 0) return try alloc.dupe(u8, "");

    const start_y = @min(state.sel_start_y, state.cy);
    const end_y = @min(@max(state.sel_start_y, state.cy), total_lines - 1);
    const start_x = @min(state.sel_start_x, state.cx);
    const end_x = @max(state.sel_start_x, state.cx);

    var out: std.ArrayListAligned(u8, null) = .empty;
    errdefer out.deinit(alloc);

    var y = start_y;
    while (y <= end_y) : (y += 1) {
        const line_text = if (state.mode == .visual_line)
            try extractGridLineSlice(alloc, pane_state, y, 0, grid.cols -| 1)
        else if (start_y == end_y)
            try extractGridLineSlice(alloc, pane_state, y, start_x, end_x)
        else if (y == start_y)
            try extractGridLineSlice(alloc, pane_state, y, start_x, grid.cols -| 1)
        else if (y == end_y)
            try extractGridLineSlice(alloc, pane_state, y, 0, end_x)
        else
            try extractGridLineSlice(alloc, pane_state, y, 0, grid.cols -| 1);
        defer alloc.free(line_text);

        try out.appendSlice(alloc, line_text);
        if (y != end_y) try out.append(alloc, '\n');
    }

    return try out.toOwnedSlice(alloc);
}

fn handleCopyModeAction(ctx: *Context, pane: *Pane, pane_state: anytype, action: copy_mod.CopyAction) CmdError!void {
    switch (action) {
        .move_cursor, .start_selection, .search_next, .search_prev => {},
        .scroll_up => if (pane.copy_state) |*state| {
            if (state.cy > 0) state.cy -= 1;
        },
        .scroll_down => if (pane.copy_state) |*state| {
            const max_y = pane_state.screen.grid.hsize + pane_state.screen.grid.rows -| 1;
            state.cy = @min(max_y, state.cy + 1);
        },
        .page_up => if (pane.copy_state) |*state| {
            const step = pane_state.screen.grid.rows;
            state.cy = state.cy -| step;
        },
        .page_down => if (pane.copy_state) |*state| {
            const step = pane_state.screen.grid.rows;
            const max_y = pane_state.screen.grid.hsize + pane_state.screen.grid.rows -| 1;
            state.cy = @min(max_y, state.cy + step);
        },
        .cancel => pane.copy_state = null,
        .copy_selection => {
            const state = pane.copy_state orelse return;
            const text = extractCopySelection(ctx.allocator, pane_state, &state) catch return CmdError.CommandFailed;
            defer ctx.allocator.free(text);
            ctx.server.paste_stack.push(text, null) catch return CmdError.OutOfMemory;
            pane.copy_state = null;
        },
    }
}

fn handleCopyModeKey(ctx: *Context, pane: *Pane, key_arg: []const u8) CmdError!bool {
    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return false;
    var handled = false;

    if (key_string.stringToKey(key_arg)) |result| {
        if (pane.copy_state) |*state| {
            const mods: copy_mod.Modifiers = .{
                .ctrl = result.mods.ctrl,
                .meta = result.mods.meta,
                .shift = result.mods.shift,
            };
            if (state.handleKey(result.key, mods)) |action| {
                try handleCopyModeAction(ctx, pane, pane_state, action);
            }
            handled = true;
        }
    } else if (pane.copy_state) |*state| {
        for (key_arg) |byte| {
            if (state.handleKey(byte, .{})) |action| {
                try handleCopyModeAction(ctx, pane, pane_state, action);
            }
        }
        handled = true;
    }

    return handled;
}

fn appendPromptBytes(state: *PromptState, bytes: []const u8) void {
    const remaining = state.buffer.len - state.len;
    const copy_len = @min(remaining, bytes.len);
    if (copy_len == 0) return;
    @memcpy(state.buffer[state.len .. state.len + copy_len], bytes[0..copy_len]);
    state.len += copy_len;
}

fn executePromptBuffer(ctx: *Context, pane: *Pane) CmdError!void {
    const prompt_state = pane.prompt_state orelse return;
    const registry = ctx.registry orelse return CmdError.CommandFailed;
    const command_text = prompt_state.buffer[0..prompt_state.len];

    pane.prompt_state = null;
    if (command_text.len == 0) return;

    var parser = config_parser.ConfigParser.init(ctx.allocator, command_text);
    var commands = parser.parseAll() catch return CmdError.CommandFailed;
    defer {
        for (commands.items) |*command| command.deinit(ctx.allocator);
        commands.deinit(ctx.allocator);
    }
    if (commands.items.len == 0) return CmdError.InvalidArgs;

    for (commands.items) |*command| {
        try registry.executeParsed(ctx, command);
    }
}

fn handlePromptKey(ctx: *Context, pane: *Pane, key_arg: []const u8) CmdError!bool {
    var prompt_state = &(pane.prompt_state orelse return false);

    if (std.mem.eql(u8, key_arg, "Enter")) {
        try executePromptBuffer(ctx, pane);
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Escape")) {
        pane.prompt_state = null;
        return true;
    }
    if (std.mem.eql(u8, key_arg, "BSpace")) {
        if (prompt_state.len > 0) prompt_state.len -= 1;
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Space")) {
        appendPromptBytes(prompt_state, " ");
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Tab")) {
        appendPromptBytes(prompt_state, "\t");
        return true;
    }

    appendPromptBytes(prompt_state, key_arg);
    return true;
}

fn addChooseTreeEntry(state: *ChooseTreeState, label: []const u8, depth: u8, has_children: bool, session: *Session, window: ?*Window, pane: ?*Pane) CmdError!void {
    const owned_label = state.allocator.dupe(u8, label) catch return CmdError.OutOfMemory;
    errdefer state.allocator.free(owned_label);
    state.labels.append(state.allocator, owned_label) catch return CmdError.OutOfMemory;
    state.tree.addItem(.{
        .label = owned_label,
        .depth = depth,
        .expanded = true,
        .has_children = has_children,
        .tag = @intCast(state.items.items.len),
    }) catch return CmdError.OutOfMemory;
    state.items.append(state.allocator, .{
        .session = @ptrCast(session),
        .window = if (window) |w| @ptrCast(w) else null,
        .pane = if (pane) |p| @ptrCast(p) else null,
    }) catch return CmdError.OutOfMemory;
}

fn currentChooseTreeState(ctx: *Context, pane: ?*Pane) ?*ChooseTreeState {
    if (ctx.server.choose_tree_state) |*state| return state;
    if (ctx.client_index) |client_index| {
        if (client_index < ctx.server.clients.items.len) {
            if (ctx.server.clients.items[client_index].choose_tree_state) |*state| return state;
        }
    }
    if (pane) |p| {
        if (p.choose_tree_state) |*state| return state;
    }
    return null;
}

fn clearChooseTreeState(ctx: *Context, pane: ?*Pane) void {
    if (ctx.server.choose_tree_state) |*state| {
        state.deinit();
        ctx.server.choose_tree_state = null;
    }
    if (ctx.client_index) |client_index| {
        if (client_index < ctx.server.clients.items.len) {
            if (ctx.server.clients.items[client_index].choose_tree_state) |*state| {
                state.deinit();
            }
            ctx.server.clients.items[client_index].choose_tree_state = null;
        }
    }
    if (pane) |p| {
        if (p.choose_tree_state) |*state| {
            state.deinit();
        }
        p.choose_tree_state = null;
    }
}

fn renderChooseTree(ctx: *Context, pane: ?*Pane) CmdError!void {
    const state = currentChooseTreeState(ctx, pane) orelse return CmdError.CommandFailed;
    const rendered = state.tree.render(ctx.allocator) catch return CmdError.OutOfMemory;
    defer ctx.allocator.free(rendered);
    try writeOutput(ctx, "{s}", .{rendered});
}

fn handleChooseTreeSelect(ctx: *Context, pane: ?*Pane, item_index: usize) CmdError!void {
    const state = currentChooseTreeState(ctx, pane) orelse return CmdError.CommandFailed;
    if (item_index >= state.items.items.len) return CmdError.InvalidArgs;
    const item = state.items.items[item_index];
    const session: *Session = @ptrCast(@alignCast(item.session orelse return CmdError.SessionNotFound));
    ctx.session = session;
    ctx.server.default_session = session;
    if (item.window) |window_ptr| {
        const window: *Window = @ptrCast(@alignCast(window_ptr));
        session.selectWindow(window);
        ctx.window = window;
        if (item.pane) |pane_ptr| {
            const selected_pane: *Pane = @ptrCast(@alignCast(pane_ptr));
            window.selectPane(selected_pane);
            ctx.pane = selected_pane;
        } else {
            ctx.pane = window.active_pane;
        }
    } else {
        ctx.window = session.active_window;
        ctx.pane = if (ctx.window) |window| window.active_pane else null;
    }
    clearChooseTreeState(ctx, pane);
}

fn handleChooseTreeKey(ctx: *Context, pane: ?*Pane, key_arg: []const u8) CmdError!bool {
    if (currentChooseTreeState(ctx, pane) == null) return false;

    const key: u21 = if (key_string.stringToKey(key_arg)) |result|
        result.key
    else if (key_arg.len == 1)
        key_arg[0]
    else
        return false;

    var state = currentChooseTreeState(ctx, pane) orelse return false;
    switch (state.tree.handleKey(key)) {
        .none => {
            try renderChooseTree(ctx, pane);
            return true;
        },
        .cancel => {
            clearChooseTreeState(ctx, pane);
            return true;
        },
        .select, .toggle_expand => {
            const selected = state.tree.selected;
            try handleChooseTreeSelect(ctx, pane, selected);
            return true;
        },
    }
}

fn formatBindingKey(buf: []u8, key: u21, mods: binding_mod.Modifiers) []const u8 {
    var pos: usize = 0;
    if (mods.ctrl) {
        @memcpy(buf[pos .. pos + 2], "C-");
        pos += 2;
    }
    if (mods.meta) {
        @memcpy(buf[pos .. pos + 2], "M-");
        pos += 2;
    }
    if (mods.shift) {
        @memcpy(buf[pos .. pos + 2], "S-");
        pos += 2;
    }

    const special: ?[]const u8 = switch (key) {
        '\r' => "Enter",
        0x1b => "Escape",
        ' ' => "Space",
        '\t' => "Tab",
        0x7f => "BSpace",
        0x100 => "Up",
        0x101 => "Down",
        0x102 => "Left",
        0x103 => "Right",
        else => null,
    };

    if (special) |name| {
        @memcpy(buf[pos .. pos + name.len], name);
        pos += name.len;
        return buf[0..pos];
    }

    if (key < 0x80) {
        buf[pos] = @truncate(key);
        pos += 1;
        return buf[0..pos];
    }

    const rendered = std.fmt.bufPrint(buf[pos..], "U+{X}", .{key}) catch "?";
    return buf[0 .. pos + rendered.len];
}

fn writeKeyArgToPane(pane: *Pane, key_str: []const u8) void {
    if (pane.fd < 0) return;

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
        _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
    }
}

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

    const session = ctx.server.createSession(session_name, defaultShell(ctx.session), 80, 24) catch return CmdError.CommandFailed;
    ctx.session = session;
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
    errdefer window.deinit();

    const pane = spawnWindowPane(ctx.allocator, defaultShell(ctx.session), 80, 24) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer pane.deinit();

    window.addPane(pane) catch return CmdError.OutOfMemory;
    session.addWindow(window) catch return CmdError.OutOfMemory;
    session.selectWindow(window);
    ctx.server.trackPane(pane, window.sx, window.sy) catch return CmdError.CommandFailed;
}

fn cmdSplitWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var direction: CellType = .horizontal;
    var percent: u32 = 50;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            direction = .horizontal;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            direction = .vertical;
        } else if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            percent = std.fmt.parseInt(u32, args[i], 10) catch 50;
        }
    }

    const new_pane = spawnWindowPane(ctx.allocator, defaultShell(ctx.session), window.sx, window.sy) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer new_pane.deinit();
    window.splitActivePane(new_pane, direction, percent) catch return CmdError.CommandFailed;
    ctx.server.trackPane(new_pane, new_pane.sx, new_pane.sy) catch return CmdError.CommandFailed;
}

fn cmdSelectPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const target = args[i];
            if (std.mem.eql(u8, target, ":.+") or std.mem.eql(u8, target, ":+")) {
                window.nextPane();
                return;
            }
            if (target.len >= 2 and target[0] == '%') {
                const pane_id = std.fmt.parseInt(u32, target[1..], 10) catch return CmdError.InvalidArgs;
                if (!window.selectPaneById(pane_id)) return CmdError.PaneNotFound;
                return;
            }
            const pane_index = std.fmt.parseInt(usize, target, 10) catch return CmdError.InvalidArgs;
            if (!window.selectPaneByIndex(pane_index)) return CmdError.PaneNotFound;
            return;
        }
        if (std.mem.eql(u8, args[i], "-U") or std.mem.eql(u8, args[i], "-L")) {
            window.prevPane();
            return;
        }
        if (std.mem.eql(u8, args[i], "-D") or std.mem.eql(u8, args[i], "-R")) {
            window.nextPane();
            return;
        }
    }

    window.nextPane();
}

fn cmdSelectWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (parseTargetWindow(args)) |window_number| {
        const window = session.findWindowByNumber(window_number) orelse return CmdError.WindowNotFound;
        session.selectWindow(window);
        return;
    }
    session.nextWindow();
}

fn cmdDetachClient(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (ctx.server.clients.items, 0..) |client, i| {
        if (client.session == session) {
            ctx.server.detachClient(i);
        }
    }
}

fn cmdListSessions(ctx: *Context, _: []const []const u8) CmdError!void {
    for (ctx.server.sessions.items) |session| {
        try writeOutput(ctx, "{s}: {d} windows (attached: {d})\n", .{
            session.name,
            session.windowCount(),
            session.attached,
        });
    }
}

fn cmdSendKeys(ctx: *Context, args: []const []const u8) CmdError!void {
    if (ctx.server.choose_tree_state != null) {
        for (args) |key_str| {
            if (try handleChooseTreeKey(ctx, null, key_str)) continue;
        }
        return;
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    for (args) |key_str| {
        if (pane.prompt_state != null and try handlePromptKey(ctx, pane, key_str)) {
            continue;
        }
        if (try handleChooseTreeKey(ctx, pane, key_str)) {
            continue;
        }
        if (pane.copy_state != null and try handleCopyModeKey(ctx, pane, key_str)) {
            continue;
        }
        writeKeyArgToPane(pane, key_str);
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
    for (window.panes.items) |pane| {
        ctx.server.untrackPane(pane.id);
    }
    const empty = session.removeWindow(window);
    if (empty) {
        ctx.session = null;
        ctx.server.removeSession(session);
    }
}

fn cmdKillPane(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    ctx.server.untrackPane(pane.id);
    const window_empty = window.removePane(pane);
    if (window_empty) {
        const session_empty = session.removeWindow(window);
        if (session_empty) {
            ctx.session = null;
            ctx.server.removeSession(session);
        }
    } else if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
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
        if (std.mem.eql(u8, args[i], "-Z")) {
            _ = window.toggleZoom();
            return;
        } else if (std.mem.eql(u8, args[i], "-U")) {
            dy = -1;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            dy = 1;
        } else if (std.mem.eql(u8, args[i], "-L")) {
            dx = -1;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            dx = 1;
        } else {
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
    if (args.len > 0) {
        try writeOutput(ctx, "{s}\n", .{args[args.len - 1]});
    }
}

fn cmdSourceFile(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];

    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return CmdError.CommandFailed;
    defer _ = std.c.close(fd);

    var content_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < content_buf.len) {
        const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    try executeCommandSource(ctx, content_buf[0..total]);
}

fn cmdSetOption(ctx: *Context, args: []const []const u8) CmdError!void {
    var option_name: ?[]const u8 = null;
    var value_start: ?usize = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-g") or
            std.mem.eql(u8, arg, "-s") or
            std.mem.eql(u8, arg, "-w") or
            std.mem.eql(u8, arg, "-p"))
        {
            continue;
        }
        option_name = arg;
        value_start = i + 1;
        break;
    }

    const resolved_name = option_name orelse return CmdError.InvalidArgs;
    const start = value_start orelse return CmdError.InvalidArgs;
    if (start >= args.len) return CmdError.InvalidArgs;

    const def = findOptionDef(resolved_name) orelse return CmdError.CommandFailed;
    const scope = scopeFromSetArgs(args, def.scope);
    const raw_value = if (args.len - start == 1)
        args[start]
    else
        blk: {
            const joined = try joinArgs(ctx.allocator, args[start..]);
            defer ctx.allocator.free(joined);
            const parsed_value = try parseOptionValue(def.option_type, joined);
            try ctx.server.options.set(scope, resolved_name, parsed_value);
            if (scope == .session) applySessionOption(ctx.server, resolved_name, parsed_value);
            return;
        };

    const parsed = try parseOptionValue(def.option_type, raw_value);
    try ctx.server.options.set(scope, resolved_name, parsed);
    if (scope == .session) applySessionOption(ctx.server, resolved_name, parsed);
}

fn cmdBindKey(ctx: *Context, args: []const []const u8) CmdError!void {
    var table_name: []const u8 = "prefix";
    var key_name: ?[]const u8 = null;
    var command_start: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-n")) {
            table_name = "root";
            continue;
        }
        if (std.mem.eql(u8, arg, "-T")) {
            if (i + 1 >= args.len) return CmdError.InvalidArgs;
            table_name = args[i + 1];
            i += 1;
            continue;
        }
        key_name = arg;
        command_start = i + 1;
        break;
    }

    const resolved_key = key_name orelse return CmdError.InvalidArgs;
    if (command_start >= args.len) return CmdError.InvalidArgs;

    const parsed_key = key_string.stringToKey(resolved_key) orelse return CmdError.InvalidArgs;
    const command = if (args.len - command_start == 1)
        args[command_start]
    else
        try joinArgs(ctx.allocator, args[command_start..]);
    defer if (args.len - command_start > 1) ctx.allocator.free(command);

    const table = ctx.server.bindings.getOrCreateTable(table_name) catch return CmdError.OutOfMemory;
    table.bind(parsed_key.key, parsed_key.mods, command) catch return CmdError.OutOfMemory;
}

fn cmdIfShell(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len < 2) return CmdError.InvalidArgs;
    const exit_code = try runShellCommand(args[0]);
    if (exit_code == 0) {
        try executeCommandSource(ctx, args[1]);
        return;
    }
    if (args.len >= 3) {
        try executeCommandSource(ctx, args[2]);
    }
}

fn cmdListWindows(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (session.windows.items, 0..) |window, i| {
        try writeOutput(ctx, "{d}: {s} ({d} panes)\n", .{
            session.options.base_index + @as(u32, @intCast(i)),
            window.name,
            window.paneCount(),
        });
    }
}

fn cmdListPanes(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items, 0..) |pane, i| {
        try writeOutput(ctx, "{d}: pane {d} [{d}x{d}]\n", .{ i, pane.id, pane.sx, pane.sy });
    }
}

fn cmdSetBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const name = parseNamedOption(args, "-b");
    var data: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b") and i + 1 < args.len) {
            i += 1;
            continue;
        }
        data = args[i];
    }

    const buffer_data = data orelse return CmdError.InvalidArgs;
    ctx.server.paste_stack.push(buffer_data, name) catch return CmdError.OutOfMemory;
}

fn cmdPasteBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    const buffer = try resolvePasteBuffer(ctx, parseNamedOption(args, "-b"));
    _ = std.c.write(pane.fd, buffer.data.ptr, buffer.data.len);
}

fn cmdCopyMode(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return CmdError.CommandFailed;

    var state = copy_mod.CopyState.init();
    state.cx = pane_state.screen.cx;
    state.cy = pane_state.screen.grid.hsize + pane_state.screen.cy;
    pane.copy_state = state;
}

fn cmdCommandPrompt(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    var state = PromptState{};
    for (args, 0..) |arg, i| {
        if (i > 0) appendPromptBytes(&state, " ");
        appendPromptBytes(&state, arg);
    }
    pane.prompt_state = state;
    try writeOutput(ctx, ":\n", .{});
}

fn cmdListBuffers(ctx: *Context, _: []const []const u8) CmdError!void {
    const count = ctx.server.paste_stack.count();
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const buffer = ctx.server.paste_stack.get(index) orelse continue;
        if (buffer.name) |name| {
            try writeOutput(ctx, "{d}: {s} ({d} bytes)\n", .{ index, name, buffer.data.len });
        } else {
            try writeOutput(ctx, "{d}: buffer{d} ({d} bytes)\n", .{ index, index, buffer.data.len });
        }
    }
}

fn cmdShowBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const buffer = try resolvePasteBuffer(ctx, parseNamedOption(args, "-b"));
    try writeOutput(ctx, "{s}\n", .{buffer.data});
}

fn cmdDeleteBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    if (parseNamedOption(args, "-b")) |name| {
        if (!ctx.server.paste_stack.removeByName(name)) return CmdError.BufferNotFound;
        return;
    }
    if (!ctx.server.paste_stack.removeTop()) return CmdError.BufferNotFound;
}

fn cmdListKeys(ctx: *Context, _: []const []const u8) CmdError!void {
    var iter = ctx.server.bindings.tables.iterator();
    while (iter.next()) |entry| {
        const table_name = entry.key_ptr.*;
        const table = entry.value_ptr;
        for (table.bindings.items) |binding| {
            var key_buf: [32]u8 = undefined;
            const rendered_key = formatBindingKey(&key_buf, binding.key, binding.modifiers);
            switch (binding.action) {
                .command => |command| try writeOutput(ctx, "-T {s} {s} {s}\n", .{ table_name, rendered_key, command }),
                .none => {},
            }
        }
    }
}

fn cmdChooseTree(ctx: *Context, args: []const []const u8) CmdError!void {
    const pane = if (ctx.session) |session|
        if (session.active_window) |window| window.active_pane else null
    else
        null;

    var sessions_only = false;
    var windows_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s")) sessions_only = true;
        if (std.mem.eql(u8, arg, "-w")) windows_only = true;
    }

    var state = ChooseTreeState.init(ctx.allocator, 20);
    errdefer state.deinit();

    for (ctx.server.sessions.items) |tree_session| {
        try addChooseTreeEntry(&state, tree_session.name, 0, !sessions_only, tree_session, null, null);
        if (sessions_only) continue;

        for (tree_session.windows.items, 0..) |tree_window, window_idx| {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d}: {s} ({d} panes)", .{
                tree_session.options.base_index + @as(u32, @intCast(window_idx)),
                tree_window.name,
                tree_window.paneCount(),
            }) catch return CmdError.CommandFailed;
            try addChooseTreeEntry(&state, label, 1, !windows_only and tree_window.paneCount() > 0, tree_session, tree_window, null);
            if (windows_only) continue;

            for (tree_window.panes.items, 0..) |tree_pane, pane_idx| {
                var pane_label_buf: [256]u8 = undefined;
                const pane_label = std.fmt.bufPrint(&pane_label_buf, "{d}: pane {d} [{d}x{d}]", .{
                    pane_idx,
                    tree_pane.id,
                    tree_pane.sx,
                    tree_pane.sy,
                }) catch return CmdError.CommandFailed;
                try addChooseTreeEntry(&state, pane_label, 2, false, tree_session, tree_window, tree_pane);
            }
        }
    }

    if (ctx.server.choose_tree_state) |*existing| existing.deinit();
    ctx.server.choose_tree_state = state;
    try renderChooseTree(ctx, pane);
}

fn cmdClockMode(ctx: *Context, _: []const []const u8) CmdError!void {
    var now: i64 = 0;
    _ = time(&now);
    const tm_ptr = localtime(&now) orelse return CmdError.CommandFailed;

    var line_buf: [64]u8 = undefined;
    const clock = std.fmt.bufPrint(&line_buf, " {d:0>2}:{d:0>2}:{d:0>2} ", .{
        @as(u32, @intCast(tm_ptr.tm_hour)),
        @as(u32, @intCast(tm_ptr.tm_min)),
        @as(u32, @intCast(tm_ptr.tm_sec)),
    }) catch return CmdError.CommandFailed;

    try writeOutput(ctx, "┌──────────┐\n", .{});
    try writeOutput(ctx, "│{s}│\n", .{clock});
    try writeOutput(ctx, "└──────────┘\n", .{});
}

fn cmdRunShell(_: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const command = args[args.len - 1];

    var cmd_buf: [4096]u8 = .{0} ** 4096;
    if (command.len >= cmd_buf.len) return CmdError.CommandFailed;
    @memcpy(cmd_buf[0..command.len], command);

    const pid = std.c.fork();
    if (pid < 0) return CmdError.CommandFailed;

    if (pid == 0) {
        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..command.len :0]);
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z };
        _ = execvp(sh, &argv);
        std.c.exit(127);
    }

    _ = std.c.waitpid(pid, null, 0);
}

extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) i32;

const documented_builtin_commands = [_]struct {
    name: []const u8,
    alias: ?[]const u8 = null,
}{
    .{ .name = "new-session", .alias = "new" },
    .{ .name = "kill-server" },
    .{ .name = "kill-session" },
    .{ .name = "new-window", .alias = "neww" },
    .{ .name = "split-window", .alias = "splitw" },
    .{ .name = "select-pane" },
    .{ .name = "select-window", .alias = "selectw" },
    .{ .name = "detach-client", .alias = "detach" },
    .{ .name = "list-sessions", .alias = "ls" },
    .{ .name = "send-keys", .alias = "send" },
    .{ .name = "next-window", .alias = "next" },
    .{ .name = "previous-window", .alias = "prev" },
    .{ .name = "last-window", .alias = "last" },
    .{ .name = "kill-window", .alias = "killw" },
    .{ .name = "kill-pane", .alias = "killp" },
    .{ .name = "rename-session" },
    .{ .name = "rename-window", .alias = "renamew" },
    .{ .name = "resize-pane", .alias = "resizep" },
    .{ .name = "swap-pane", .alias = "swapp" },
    .{ .name = "display-message", .alias = "display" },
    .{ .name = "source-file", .alias = "source" },
    .{ .name = "list-windows", .alias = "lsw" },
    .{ .name = "list-panes" },
    .{ .name = "set-buffer", .alias = "setb" },
    .{ .name = "paste-buffer", .alias = "pasteb" },
    .{ .name = "copy-mode", .alias = "copy" },
    .{ .name = "command-prompt", .alias = "prompt" },
    .{ .name = "list-buffers", .alias = "lsb" },
    .{ .name = "show-buffer", .alias = "showb" },
    .{ .name = "delete-buffer", .alias = "deleteb" },
    .{ .name = "list-keys", .alias = "lsk" },
    .{ .name = "choose-tree" },
    .{ .name = "clock-mode", .alias = "clock" },
    .{ .name = "run-shell", .alias = "run" },
};

test "registry register and find" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    var alias_count: usize = 0;
    for (documented_builtin_commands) |command| {
        try std.testing.expect(reg.find(command.name) != null);
        if (command.alias) |alias| {
            alias_count += 1;
            try std.testing.expect(reg.find(alias) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, documented_builtin_commands.len + alias_count), reg.commands.count());
    try std.testing.expect(reg.find("nonexistent") == null);
}

test "parse target window helper" {
    const args = [_][]const u8{ "-t", ":3" };
    try std.testing.expectEqual(@as(?u32, 3), parseTargetWindow(&args));
}

test "formatBindingKey renders ctrl meta modifiers" {
    var buf: [32]u8 = undefined;
    const rendered = formatBindingKey(&buf, 'b', .{ .ctrl = true, .meta = true });
    try std.testing.expectEqualStrings("C-M-b", rendered);
}

test "extractCopySelection reads visual line from screen history space" {
    var fake = struct {
        screen: screen_mod.Screen,
    }{
        .screen = screen_mod.Screen.init(std.testing.allocator, 20, 5, 10),
    };
    defer fake.screen.deinit();

    const line = fake.screen.grid.getLine(0);
    line.getCell(0).codepoint = 'h';
    line.getCell(1).codepoint = 'e';
    line.getCell(2).codepoint = 'l';
    line.getCell(3).codepoint = 'l';
    line.getCell(4).codepoint = 'o';

    var state = copy_mod.CopyState.init();
    state.mode = .visual_line;
    state.sel_start_y = 0;
    state.cy = 0;

    const text = try extractCopySelection(std.testing.allocator, &fake, &state);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "appendPromptBytes appends text" {
    var state = PromptState{};
    appendPromptBytes(&state, "display-message");
    appendPromptBytes(&state, " ");
    appendPromptBytes(&state, "ok");
    try std.testing.expectEqualStrings("display-message ok", state.buffer[0..state.len]);
}

test "addChooseTreeEntry stores pane metadata" {
    const alloc = std.testing.allocator;
    var choose_state = ChooseTreeState.init(alloc, 10);
    defer choose_state.deinit();

    var session = try Session.init(alloc, "demo");
    defer session.deinit();
    var window = try Window.init(alloc, "win", 80, 24);
    const pane = try Pane.init(alloc, 80, 24);
    try window.addPane(pane);
    try session.addWindow(window);

    try addChooseTreeEntry(&choose_state, "pane", 2, false, session, window, pane);
    try std.testing.expectEqual(@as(usize, 1), choose_state.items.items.len);
    try std.testing.expect(choose_state.items.items[0].pane != null);
}
