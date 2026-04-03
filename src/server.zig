const std = @import("std");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const Pane = @import("window.zig").Pane;
const ChooseTreeState = @import("window.zig").ChooseTreeState;
const Pty = @import("pane.zig").Pty;
const PasteStack = @import("copy/paste.zig").PasteStack;
const server_loop = @import("server_loop.zig");
const SessionLoop = server_loop.SessionLoop;
const protocol = @import("protocol.zig");
const cmd = @import("cmd/cmd.zig");
const config_parser = @import("config/parser.zig");
const binding_mod = @import("keybind/bindings.zig");
const output_mod = @import("terminal/output.zig");
const status_fmt = @import("status/format.zig");
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
    paste_stack: PasteStack,
    session_loop: SessionLoop,
    binding_manager: binding_mod.BindingManager,
    running: bool,
    allocator: std.mem.Allocator,

    pub const ClientConnection = struct {
        fd: std.c.fd_t,
        session: ?*Session,
        identified: bool,
        choose_tree_state: ?ChooseTreeState,
    };

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !Server {
        var bm = binding_mod.BindingManager.init(alloc);
        try bm.setupDefaults();

        return .{
            .listen_fd = -1,
            .socket_path = try alloc.dupe(u8, socket_path),
            .sessions = .empty,
            .clients = .empty,
            .default_session = null,
            .choose_tree_state = null,
            .paste_stack = PasteStack.init(alloc),
            .session_loop = SessionLoop.init(alloc),
            .binding_manager = bm,
            .running = false,
            .allocator = alloc,
        };
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
        self.paste_stack.deinit();
        self.session_loop.deinit();
        self.binding_manager.deinit();
        self.allocator.free(self.socket_path);
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
            .key => self.handleClientKey(client_idx, message.payload),
            .resize => self.handleClientResize(client_idx, message.payload),
            .exit, .exiting => self.removeClient(client_idx),
            .shell => {},
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
            .binding_manager = &self.binding_manager,
        };

        if (std.mem.indexOfScalar(u8, payload, 0) != null) {
            var args = try protocol.decodeCommandArgs(self.allocator, payload);
            defer args.deinit(self.allocator);

            if (args.items.len == 0) {
                try self.sendError(client.fd, "empty command\n", 1);
                return;
            }

            if (!std.mem.eql(u8, args.items[0], "choose-tree") and !(std.mem.eql(u8, args.items[0], "send-keys") and self.choose_tree_state != null)) {
                try self.ensureCommandSession(&ctx, client.fd, args.items[0], &registry);
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
                    try self.ensureCommandSession(&ctx, client.fd, command.name, &registry);
                }
                ctx.window = if (ctx.session) |session| session.active_window else null;
                ctx.pane = if (ctx.window) |window| window.active_pane else null;

                registry.executeParsed(&ctx, command) catch |err| {
                    try self.sendError(client.fd, commandErrorMessage(err), 1);
                    return;
                };
            }
        }

        const prev_session = client.session;
        self.setClientSession(client_idx, ctx.session);

        // If the client became attached to a session, send ready instead of
        // exit_ack so the client enters interactive mode.
        if (prev_session == null and ctx.session != null) {
            try protocol.sendMessage(client.fd, .ready, &.{});
        } else {
            try protocol.sendMessageWithFlags(client.fd, .exit_ack, 0, &.{});
        }
    }

    fn handleClientKey(self: *Server, client_idx: usize, payload: []const u8) void {
        const client = &self.clients.items[client_idx];
        const session = client.session orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        if (pane.fd < 0 or payload.len == 0) return;

        // Pass escape sequences (multi-byte starting with ESC) directly to the PTY.
        if (payload.len > 1 and payload[0] == 0x1b) {
            _ = std.c.write(pane.fd, payload.ptr, payload.len);
            return;
        }

        for (payload) |byte| {
            var key: u21 = undefined;
            var mods = binding_mod.Modifiers{};

            if (byte < 32) {
                // Control character: derive the letter and set ctrl modifier.
                key = @as(u21, byte) + '@';
                mods.ctrl = true;
            } else {
                key = byte;
            }

            if (self.binding_manager.processKey(key, mods)) |command_str| {
                self.executeBindingCommand(client_idx, command_str);
            } else {
                _ = std.c.write(pane.fd, @ptrCast(&byte), 1);
            }
        }
    }

    fn executeBindingCommand(self: *Server, client_idx: usize, command_str: []const u8) void {
        var registry = cmd.Registry.init(self.allocator);
        defer registry.deinit();
        registry.registerBuiltins() catch return;

        const client = &self.clients.items[client_idx];
        var ctx = cmd.Context{
            .server = self,
            .session = client.session,
            .window = if (client.session) |s| s.active_window else null,
            .pane = if (client.session) |s| if (s.active_window) |w| w.active_pane else null else null,
            .client_index = client_idx,
            .allocator = self.allocator,
            .reply_fd = client.fd,
            .registry = &registry,
            .binding_manager = &self.binding_manager,
        };

        var parser = config_parser.ConfigParser.init(self.allocator, command_str);
        var commands = parser.parseAll() catch return;
        defer {
            for (commands.items) |*c| c.deinit(self.allocator);
            commands.deinit(self.allocator);
        }

        for (commands.items) |*command| {
            ctx.window = if (ctx.session) |s| s.active_window else null;
            ctx.pane = if (ctx.window) |w| w.active_pane else null;
            registry.executeParsed(&ctx, command) catch {};
        }
    }

    fn handleClientResize(self: *Server, client_idx: usize, payload: []const u8) void {
        if (payload.len < @sizeOf(protocol.ResizeMsg)) return;
        const msg: *const protocol.ResizeMsg = @alignCast(@ptrCast(payload.ptr));
        const client = &self.clients.items[client_idx];
        const session = client.session orelse return;
        const window = session.active_window orelse return;
        window.resize(msg.cols, msg.rows);
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

        const pane_state = self.session_loop.getPane(pane.id);
        if (pane_state) |ps| {
            ps.processPtyOutput(buf[0..@intCast(n)]);
        }

        const session = self.findSessionForPaneFd(fd) orelse return;
        for (self.clients.items) |client| {
            if (client.session == session) {
                self.renderComposedToClient(client.fd, session, pane_state) catch {
                    // Fall back to raw relay on render failure.
                    protocol.sendMessage(client.fd, .output, buf[0..@intCast(n)]) catch {};
                };
            }
        }
    }

    /// Render the composed terminal view (screen content + status bar) for a
    /// client.  Uses a pipe pair so the existing Output→fd writer can produce
    /// escape sequences that we then wrap in a protocol message.
    fn renderComposedToClient(
        self: *Server,
        client_fd: std.c.fd_t,
        session: *Session,
        pane_state_opt: ?*server_loop.PaneState,
    ) !void {
        const ps = pane_state_opt orelse return error.NoPaneState;

        // Use a pipe so Output can flush to the write end while we
        // collect the bytes from the read end.
        var pipe_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        defer _ = std.c.close(pipe_fds[0]);
        errdefer _ = std.c.close(pipe_fds[1]);

        // Render dirty screen lines through the redraw pipeline.
        var out = output_mod.Output.init(pipe_fds[1]);
        ps.renderTo(&out);

        // Render status bar on the last row.
        const window = session.active_window;
        const cols: u32 = if (window) |w| w.sx else 80;
        const rows: u32 = if (window) |w| w.sy else 24;

        const fmt_ctx = status_fmt.FormatContext{
            .session_name = session.name,
            .window_name = if (window) |w| w.name else "",
        };
        const status_bar = @import("status/status.zig").StatusBar.init();
        const status_line = status_bar.render(self.allocator, cols, &fmt_ctx) catch null;
        defer if (status_line) |sl| self.allocator.free(sl);

        if (status_line) |sl| {
            out.cursorTo(0, rows -| 1);
            out.attrReset();
            // Reverse video for status bar (like tmux default).
            out.writeBytes("\x1b[7m");
            out.writeBytes(sl);
            out.writeBytes("\x1b[0m");
        }

        out.flush();

        // Close write end so read gets EOF.
        _ = std.c.close(pipe_fds[1]);
        pipe_fds[1] = -1;

        // Read rendered bytes from the pipe.
        var rendered: [protocol.max_payload]u8 = undefined;
        var total: usize = 0;
        while (total < rendered.len) {
            const rc = std.c.read(pipe_fds[0], rendered[total..].ptr, rendered.len - total);
            if (rc <= 0) break;
            total += @intCast(rc);
        }

        if (total > 0) {
            try protocol.sendMessage(client_fd, .output, rendered[0..total]);
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

    fn ensureCommandSession(self: *Server, ctx: *cmd.Context, reply_fd: std.c.fd_t, command_name: []const u8, registry: *const cmd.Registry) !void {
        const canonical = if (registry.find(command_name)) |def| def.name else command_name;
        if (ctx.session != null or commandAllowsMissingSession(canonical)) return;
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
        std.mem.eql(u8, name, "list-commands") or
        std.mem.eql(u8, name, "start-server") or
        std.mem.eql(u8, name, "kill-server") or
        std.mem.eql(u8, name, "display-message") or
        std.mem.eql(u8, name, "if-shell");
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

test "commandAllowsMissingSession includes if-shell" {
    try std.testing.expect(commandAllowsMissingSession("if-shell"));
    try std.testing.expect(!commandAllowsMissingSession("send-prefix"));
}
