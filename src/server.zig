const std = @import("std");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const Pane = @import("window.zig").Pane;
const ChooseTreeState = @import("window.zig").ChooseTreeState;
const Pty = @import("pane.zig").Pty;
const PasteStack = @import("copy/paste.zig").PasteStack;
const SessionLoop = @import("server_loop.zig").SessionLoop;
const protocol = @import("protocol.zig");
const cmd = @import("cmd/cmd.zig");
const config_parser = @import("config/parser.zig");
const binding_mod = @import("keybind/bindings.zig");
const log = @import("core/log.zig");
const signals = @import("signals.zig");

/// Server state.
pub const Server = struct {
    listen_fd: std.c.fd_t,
    socket_path: []const u8,
    sessions: std.ArrayListAligned(*Session, null),
    clients: std.ArrayListAligned(ClientConnection, null),
    default_session: ?*Session,
    choose_tree_state: ?ChooseTreeState,
    bindings: binding_mod.BindingManager,
    paste_stack: PasteStack,
    bindings: binding_mod.BindingManager,
    options: options_mod.OptionsStore,
    session_loop: SessionLoop,
    options: Options,
    running: bool,
    allocator: std.mem.Allocator,

    pub const Options = struct {
        default_terminal: []u8,
        history_limit: i64 = 2000,
        escape_time: i64 = 500,
        set_clipboard: []u8,
    };

    pub const ClientConnection = struct {
        fd: std.c.fd_t,
        session: ?*Session,
        identified: bool,
        choose_tree_state: ?ChooseTreeState,
    };

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !Server {
        var bindings = binding_mod.BindingManager.init(alloc);
        errdefer bindings.deinit();
        try bindings.setupDefaults();

        const owned_socket_path = try alloc.dupe(u8, socket_path);
        errdefer alloc.free(owned_socket_path);
        const default_terminal = try alloc.dupe(u8, "screen");
        errdefer alloc.free(default_terminal);
        const set_clipboard = try alloc.dupe(u8, "external");
        errdefer alloc.free(set_clipboard);

        return .{
            .listen_fd = -1,
            .socket_path = owned_socket_path,
            .sessions = .empty,
            .clients = .empty,
            .default_session = null,
            .choose_tree_state = null,
            .bindings = bindings,
            .paste_stack = PasteStack.init(alloc),
            .bindings = binding_mod.BindingManager.init(alloc),
            .options = options_mod.OptionsStore.init(alloc),
            .session_loop = SessionLoop.init(alloc),
            .options = .{
                .default_terminal = default_terminal,
                .set_clipboard = set_clipboard,
            },
            .running = false,
            .allocator = alloc,
        };
        errdefer {
            server.bindings.deinit();
            server.options.deinit();
            server.paste_stack.deinit();
            server.session_loop.deinit();
            alloc.free(server.socket_path);
        }

        try server.bindings.setupDefaults();
        try server.options.loadDefaults(&options_table_mod.options_table);
        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        for (self.sessions.items) |session| {
            session.deinit();
        }
        self.sessions.deinit(self.allocator);
        for (self.clients.items) |*client| {
            if (client.choose_tree_state) |*state| {
                state.deinit();
            }
            if (client.fd >= 0) _ = std.c.close(client.fd);
        }
        self.clients.deinit(self.allocator);
        if (self.choose_tree_state) |*state| {
            state.deinit();
        }
        self.bindings.deinit();
        self.paste_stack.deinit();
        self.bindings.deinit();
        self.options.deinit();
        self.session_loop.deinit();
        self.allocator.free(self.options.default_terminal);
        self.allocator.free(self.options.set_clipboard);
        self.allocator.free(self.socket_path);
    }

    pub fn setDefaultTerminal(self: *Server, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.default_terminal);
        self.options.default_terminal = owned;
    }

    pub fn setSetClipboard(self: *Server, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.set_clipboard);
        self.options.set_clipboard = owned;
    }

    pub fn listen(self: *Server) !void {
        try self.ensureSocketDir();
        self.removeStaleSocket();

        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        self.listen_fd = fd;

        var addr: std.c.sockaddr.un = .{ .path = undefined };
        if (self.socket_path.len >= addr.path.len) return error.PathTooLong;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un)) != 0) {
            return error.BindFailed;
        }
        if (std.c.listen(fd, 128) != 0) {
            return error.ListenFailed;
        }

        var path_buf: [256]u8 = .{0} ** 256;
        @memcpy(path_buf[0..self.socket_path.len], self.socket_path);
        _ = std.c.chmod(@ptrCast(path_buf[0..self.socket_path.len :0]), 0o700);

        self.running = true;
        log.info("server listening on {s}", .{self.socket_path});
    }

    pub fn createSession(self: *Server, name: []const u8, shell: [:0]const u8, cols: u32, rows: u32) !*Session {
        const session = try Session.init(self.allocator, name);
        errdefer session.deinit();
        self.applySessionDefaults(session);

        const window = try Window.init(self.allocator, name, cols, rows);
        errdefer window.deinit();

        const pane = try Pane.init(self.allocator, cols, rows);
        errdefer pane.deinit();

        var pty = try Pty.openPty();
        try pty.forkExec(shell, null);
        pty.resize(@intCast(cols), @intCast(rows));
        pane.fd = pty.master_fd;
        pane.pid = pty.pid;

        try window.addPane(pane);
        try session.addWindow(window);
        try self.sessions.append(self.allocator, session);
        if (self.default_session == null) self.default_session = session;
        try self.session_loop.addPane(pane.id, pane.fd, cols, rows);
        return session;
    }

    pub fn applySessionDefaults(self: *Server, session: *Session) void {
        if (self.options.get(.session, "base-index")) |value| {
            switch (value) {
                .number => |number| if (number >= 0) session.options.base_index = @intCast(number),
                else => {},
            }
        }
        if (self.options.get(.session, "status")) |value| {
            switch (value) {
                .boolean => |enabled| session.options.status = enabled,
                else => {},
            }
        }
        if (self.options.get(.session, "mouse")) |value| {
            switch (value) {
                .boolean => |enabled| session.options.mouse = enabled,
                else => {},
            }
        }
        if (self.options.get(.session, "prefix")) |value| {
            switch (value) {
                .string => |binding| if (key_string.stringToKey(binding)) |parsed| {
                    session.options.prefix_key = parsed.key;
                    self.bindings.prefix_key = parsed.key;
                    self.bindings.prefix_mods = parsed.mods;
                },
                else => {},
            }
        }
    }

    pub fn acceptClient(self: *Server) !void {
        const client_fd = std.c.accept(self.listen_fd, null, null);
        if (client_fd < 0) return;
        try self.clients.append(self.allocator, .{
            .fd = client_fd,
            .session = null,
            .identified = false,
            .choose_tree_state = null,
        });
    }

    pub fn run(self: *Server) !void {
        const max_fds = 256;
        var pollfds: [max_fds]std.c.pollfd = undefined;

        while (self.running) {
            if (signals.SignalHandler.shouldExit()) {
                self.stop();
                break;
            }

            var nfds: usize = 0;
            if (self.listen_fd >= 0) {
                pollfds[nfds] = .{ .fd = self.listen_fd, .events = POLLIN, .revents = 0 };
                nfds += 1;
            }

            for (self.clients.items) |client| {
                if (nfds >= max_fds) break;
                pollfds[nfds] = .{ .fd = client.fd, .events = POLLIN, .revents = 0 };
                nfds += 1;
            }

            for (self.sessions.items) |session| {
                for (session.windows.items) |window| {
                    for (window.panes.items) |pane| {
                        if (nfds >= max_fds) break;
                        if (pane.fd >= 0) {
                            pollfds[nfds] = .{ .fd = pane.fd, .events = POLLIN, .revents = 0 };
                            nfds += 1;
                        }
                    }
                }
            }

            const result = std.c.poll(pollfds[0..nfds].ptr, @intCast(nfds), 100);
            if (result < 0) continue;
            if (result == 0) continue;

            if (nfds > 0 and pollfds[0].revents & POLLIN != 0) {
                self.acceptClient() catch {};
            }

            var i: usize = if (self.listen_fd >= 0) 1 else 0;
            while (i < nfds) : (i += 1) {
                if (pollfds[i].revents & POLLIN == 0) continue;
                const fd = pollfds[i].fd;
                if (self.findClientIndex(fd)) |client_idx| {
                    self.handleClientReadable(client_idx) catch {};
                } else {
                    self.handlePtyReadable(fd);
                }
            }
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
        if (self.listen_fd >= 0) {
            _ = std.c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        var path_buf: [256]u8 = .{0} ** 256;
        if (self.socket_path.len < path_buf.len) {
            @memcpy(path_buf[0..self.socket_path.len], self.socket_path);
            _ = std.c.unlink(@ptrCast(path_buf[0..self.socket_path.len :0]));
        }
    }

    pub fn findSession(self: *const Server, name: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.name, name)) return session;
        }
        return null;
    }

    pub fn removeSession(self: *Server, session: *Session) void {
        for (session.windows.items) |window| {
            for (window.panes.items) |pane| {
                self.session_loop.removePane(pane.id);
            }
        }
        for (self.clients.items) |*client| {
            if (client.session == session) {
                client.session = null;
            }
        }
        for (self.sessions.items, 0..) |existing, i| {
            if (existing == session) {
                _ = self.sessions.orderedRemove(i);
                break;
            }
        }
        if (self.default_session == session) {
            self.default_session = if (self.sessions.items.len > 0) self.sessions.items[0] else null;
        }
        if (self.choose_tree_state) |*state| {
            state.deinit();
            self.choose_tree_state = null;
        }
        session.deinit();
    }

    pub fn detachClient(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.session) |session| {
            if (session.attached > 0) session.attached -= 1;
        }
        protocol.sendMessage(client.fd, .detach, &.{}) catch {};
        client.session = null;
    }

    pub fn findClientIndex(self: *const Server, fd: std.c.fd_t) ?usize {
        for (self.clients.items, 0..) |client, i| {
            if (client.fd == fd) return i;
        }
        return null;
    }

    fn handleClientReadable(self: *Server, client_idx: usize) !void {
        const fd = self.clients.items[client_idx].fd;
        var message = protocol.recvMessageAlloc(self.allocator, fd) catch |err| switch (err) {
            error.UnexpectedEof, error.ReadFailed => {
                self.removeClient(client_idx);
                return;
            },
            else => return err,
        };
        defer message.deinit();

        switch (message.msg_type) {
            .identify => try self.handleIdentify(client_idx, message.payload),
            .command => try self.handleCommand(client_idx, message.payload),
            .resize, .key, .shell, .exit, .exiting => {},
            else => {},
        }
    }

    fn handleIdentify(self: *Server, client_idx: usize, payload: []const u8) !void {
        if (payload.len < @sizeOf(protocol.IdentifyMsg)) return;
        self.clients.items[client_idx].identified = true;
        if (self.clients.items[client_idx].session == null and self.sessions.items.len == 1) {
            self.setClientSession(client_idx, self.sessions.items[0]);
        } else if (self.clients.items[client_idx].session == null and self.default_session != null) {
            self.setClientSession(client_idx, self.default_session);
        }
    }

    fn handleCommand(self: *Server, client_idx: usize, payload: []const u8) !void {
        const client = &self.clients.items[client_idx];
        var registry = cmd.Registry.init(self.allocator);
        defer registry.deinit();
        try registry.registerBuiltins();

        var ctx = cmd.Context{
            .server = self,
            .session = client.session,
            .window = if (client.session) |session| session.active_window else null,
            .pane = if (client.session) |session| if (session.active_window) |window| window.active_pane else null else null,
            .client_index = client_idx,
            .allocator = self.allocator,
            .reply_fd = client.fd,
            .registry = &registry,
        };

        if (std.mem.indexOfScalar(u8, payload, 0) != null) {
            var args = try protocol.decodeCommandArgs(self.allocator, payload);
            defer args.deinit(self.allocator);

            if (args.items.len == 0) {
                try self.sendError(client.fd, "empty command\n", 1);
                return;
            }

            if (!std.mem.eql(u8, args.items[0], "choose-tree") and !(std.mem.eql(u8, args.items[0], "send-keys") and self.choose_tree_state != null)) {
                try self.ensureCommandSession(&ctx, client.fd, args.items[0]);
            }
            ctx.window = if (ctx.session) |session| session.active_window else null;
            ctx.pane = if (ctx.window) |window| window.active_pane else null;

            registry.execute(&ctx, args.items[0], args.items[1..]) catch |err| {
                try self.sendError(client.fd, commandErrorMessage(err), 1);
                return;
            };
        } else {
            var parser = config_parser.ConfigParser.init(self.allocator, payload);
            var commands = parser.parseAll() catch {
                try self.sendError(client.fd, "failed to parse command\n", 1);
                return;
            };
            defer {
                for (commands.items) |*command| command.deinit(self.allocator);
                commands.deinit(self.allocator);
            }
            if (commands.items.len == 0) {
                try self.sendError(client.fd, "empty command\n", 1);
                return;
            }

            for (commands.items) |*command| {
                if (!std.mem.eql(u8, command.name, "choose-tree") and !(std.mem.eql(u8, command.name, "send-keys") and self.choose_tree_state != null)) {
                    try self.ensureCommandSession(&ctx, client.fd, command.name);
                }
                ctx.window = if (ctx.session) |session| session.active_window else null;
                ctx.pane = if (ctx.window) |window| window.active_pane else null;

                registry.executeParsed(&ctx, command) catch |err| {
                    try self.sendError(client.fd, commandErrorMessage(err), 1);
                    return;
                };
            }
        }

        self.setClientSession(client_idx, ctx.session);
        try protocol.sendMessageWithFlags(client.fd, .exit_ack, 0, &.{});
    }

    fn sendError(self: *Server, fd: std.c.fd_t, message: []const u8, exit_code: u16) !void {
        _ = self;
        try protocol.sendMessage(fd, .error_msg, message);
        try protocol.sendMessageWithFlags(fd, .exit_ack, exit_code, &.{});
    }

    fn handlePtyReadable(self: *Server, fd: std.c.fd_t) void {
        const pane = self.findPaneByFd(fd) orelse return;
        var buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) return;

        if (self.session_loop.getPane(pane.id)) |pane_state| {
            pane_state.processPtyOutput(buf[0..@intCast(n)]);
        }

        const session = self.findSessionForPaneFd(fd) orelse return;
        for (self.clients.items) |client| {
            if (client.session == session) {
                protocol.sendMessage(client.fd, .output, buf[0..@intCast(n)]) catch {};
            }
        }
    }

    fn removeClient(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        var client = self.clients.orderedRemove(client_idx);
        if (client.choose_tree_state) |*state| {
            state.deinit();
        }
        if (client.session) |session| {
            if (session.attached > 0) session.attached -= 1;
        }
        if (client.fd >= 0) _ = std.c.close(client.fd);
    }

    fn ensureCommandSession(self: *Server, ctx: *cmd.Context, reply_fd: std.c.fd_t, command_name: []const u8) !void {
        if (ctx.session != null or commandAllowsMissingSession(command_name)) return;
        if (self.default_session) |session| {
            ctx.session = session;
            return;
        }
        if (self.sessions.items.len == 1) {
            ctx.session = self.sessions.items[0];
            return;
        }
        if (self.sessions.items.len == 0) {
            try self.sendError(reply_fd, "no current session\n", 1);
            return error.CommandFailed;
        }
        try self.sendError(reply_fd, "ambiguous session; specify -t\n", 1);
        return error.CommandFailed;
    }

    fn setClientSession(self: *Server, client_idx: usize, session: ?*Session) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.session == session) return;
        if (client.session) |existing| {
            if (existing.attached > 0) existing.attached -= 1;
        }
        client.session = session;
        if (session) |current| {
            current.attached += 1;
        }
    }

    fn findSessionForPaneFd(self: *Server, fd: std.c.fd_t) ?*Session {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd == fd) return session;
                }
            }
        }
        return null;
    }

    pub fn findPaneByFd(self: *Server, fd: std.c.fd_t) ?*Pane {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd == fd) return pane;
                }
            }
        }
        return null;
    }

    pub fn trackPane(self: *Server, pane: *Pane, cols: u32, rows: u32) !void {
        try self.session_loop.addPane(pane.id, pane.fd, cols, rows);
    }

    pub fn untrackPane(self: *Server, pane_id: u32) void {
        self.session_loop.removePane(pane_id);
    }

    fn ensureSocketDir(self: *Server) !void {
        if (std.mem.lastIndexOfScalar(u8, self.socket_path, '/')) |sep| {
            const dir = self.socket_path[0..sep];
            var dir_buf: [256]u8 = .{0} ** 256;
            if (dir.len < dir_buf.len) {
                @memcpy(dir_buf[0..dir.len], dir);
                _ = std.c.mkdir(@ptrCast(dir_buf[0..dir.len :0]), 0o700);
            }
        }
    }

    fn removeStaleSocket(self: *Server) void {
        var path_buf: [256]u8 = .{0} ** 256;
        if (self.socket_path.len < path_buf.len) {
            @memcpy(path_buf[0..self.socket_path.len], self.socket_path);
            _ = std.c.unlink(@ptrCast(path_buf[0..self.socket_path.len :0]));
        }
    }
};

fn commandAllowsMissingSession(name: []const u8) bool {
    return std.mem.eql(u8, name, "new-session") or
        std.mem.eql(u8, name, "list-sessions") or
        std.mem.eql(u8, name, "kill-server") or
        std.mem.eql(u8, name, "display-message");
}

fn commandErrorMessage(err: cmd.CmdError) []const u8 {
    return switch (err) {
        error.InvalidArgs => "invalid arguments\n",
        error.SessionNotFound => "session not found\n",
        error.WindowNotFound => "window not found\n",
        error.PaneNotFound => "pane not found\n",
        error.BufferNotFound => "buffer not found\n",
        error.CommandFailed => "command failed\n",
        error.OutOfMemory => "out of memory\n",
    };
}

const POLLIN: i16 = 0x0001;
