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
const config_path = @import("config/path.zig");
const binding_mod = @import("keybind/bindings.zig");
const key_string = @import("keybind/string.zig");
const hooks_mod = @import("hooks/hooks.zig");
const output_mod = @import("terminal/output.zig");
const status_fmt = @import("status/format.zig");
const status_mod = @import("status/status.zig");
const status_style = @import("status/style.zig");
const log = @import("core/log.zig");
const signals = @import("signals.zig");
const builtin = @import("builtin");
const event_loop_mod = @import("core/event_loop.zig");
const platform = @import("platform/platform.zig");
const GcdEventLoop = @import("platform/darwin.zig").GcdEventLoop;
const IoUringEventLoop = @import("platform/linux.zig").IoUringEventLoop;

/// Server ACL entry.
pub const AclEntry = struct {
    user: []const u8,
    allow: bool,
    read_only: bool,
};

/// Server state.
pub const Server = struct {
    pub const WaitChannel = struct {
        locked: bool = false,
        waiters: std.ArrayListAligned(std.c.fd_t, null) = .empty,
        lock_waiters: std.ArrayListAligned(std.c.fd_t, null) = .empty,

        pub fn deinit(self: *WaitChannel, alloc: std.mem.Allocator) void {
            for (self.waiters.items) |fd| _ = std.c.close(fd);
            self.waiters.deinit(alloc);
            for (self.lock_waiters.items) |fd| _ = std.c.close(fd);
            self.lock_waiters.deinit(alloc);
        }
    };

    listen_fd: std.c.fd_t,
    socket_path: []const u8,
    sessions: std.ArrayListAligned(*Session, null),
    clients: std.ArrayListAligned(ClientConnection, null),
    default_session: ?*Session,
    choose_tree_state: ?ChooseTreeState,
    paste_stack: PasteStack,
    session_loop: SessionLoop,
    binding_manager: binding_mod.BindingManager,
    hook_registry: hooks_mod.HookRegistry,
    wait_channels: std.StringHashMap(WaitChannel),
    wait_channels_mutex: std.atomic.Mutex,
    prompt_history: std.ArrayListAligned([]const u8, null),
    acl_entries: std.ArrayListAligned(AclEntry, null),
    global_default_shell: ?[:0]u8,
    session_status_defaults: SessionStatusDefaults,
    window_defaults: WindowOptionDefaults,
    config_file: ?[]const u8,
    messages: std.ArrayListAligned([]u8, null),
    marked_pane: ?*Pane,
    running: bool,
    allocator: std.mem.Allocator,
    gcd_loop: if (builtin.os.tag == .macos) ?GcdEventLoop else void,
    uring_loop: if (builtin.os.tag == .linux) ?IoUringEventLoop else void,

    pub const ClientConnection = struct {
        fd: std.c.fd_t,
        session: ?*Session,
        identified: bool,
        choose_tree_state: ?ChooseTreeState,
        locked: bool = false,
        pid: i32 = 0,
        cols: u16 = 80,
        rows: u16 = 24,
    };

    pub const WindowOptionDefaults = struct {
        mode_keys: []u8,
        window_status_format: []u8,
        aggressive_resize: bool = false,
        remain_on_exit: bool = false,
    };

    pub const SessionStatusDefaults = struct {
        base_index: u32 = 0,
        status: bool = true,
        status_style: status_style.Style = .{
            .fg = .green,
            .bg = .black,
            .attrs = .{},
        },
        status_left: []u8,
        status_right: []u8,
        status_position: Session.StatusPosition = .bottom,
        status_interval: u32 = 15,
    };

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !Server {
        var bm = binding_mod.BindingManager.init(alloc);
        try bm.setupDefaults();

        const default_mode_keys = try alloc.dupe(u8, "emacs");
        errdefer alloc.free(default_mode_keys);
        const default_window_status_format = try alloc.dupe(u8, "#I:#W#F");
        errdefer alloc.free(default_window_status_format);
        const default_status_left = try alloc.dupe(u8, "[#S]");
        errdefer alloc.free(default_status_left);
        const default_status_right = try alloc.dupe(u8, "#H");
        errdefer alloc.free(default_status_right);

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
            .hook_registry = hooks_mod.HookRegistry.init(alloc),
            .wait_channels = std.StringHashMap(WaitChannel).init(alloc),
            .wait_channels_mutex = .unlocked,
            .prompt_history = .empty,
            .acl_entries = .empty,
            .global_default_shell = null,
            .session_status_defaults = .{
                .status_left = default_status_left,
                .status_right = default_status_right,
            },
            .window_defaults = .{
                .mode_keys = default_mode_keys,
                .window_status_format = default_window_status_format,
            },
            .config_file = null,
            .messages = .empty,
            .marked_pane = null,
            .running = false,
            .allocator = alloc,
            .gcd_loop = if (builtin.os.tag == .macos) null else {},
            .uring_loop = if (builtin.os.tag == .linux) null else {},
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
        self.hook_registry.deinit();
        {
            var wc_iter = self.wait_channels.iterator();
            while (wc_iter.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            self.wait_channels.deinit();
        }
        for (self.prompt_history.items) |h| self.allocator.free(h);
        self.prompt_history.deinit(self.allocator);
        for (self.acl_entries.items) |entry| self.allocator.free(entry.user);
        self.acl_entries.deinit(self.allocator);
        if (self.global_default_shell) |shell| self.allocator.free(shell);
        self.allocator.free(self.session_status_defaults.status_left);
        self.allocator.free(self.session_status_defaults.status_right);
        self.allocator.free(self.window_defaults.mode_keys);
        self.allocator.free(self.window_defaults.window_status_format);
        for (self.messages.items) |msg| self.allocator.free(msg);
        self.messages.deinit(self.allocator);
        if (builtin.os.tag == .macos) {
            if (self.gcd_loop) |*loop| loop.deinit();
        }
        if (builtin.os.tag == .linux) {
            if (self.uring_loop) |*loop| loop.deinit();
        }
        self.allocator.free(self.socket_path);
    }

    pub fn applyWindowDefaults(self: *const Server, window: *Window) !void {
        try window.setModeKeys(self.window_defaults.mode_keys);
        try window.setWindowStatusFormat(self.window_defaults.window_status_format);
        window.options.aggressive_resize = self.window_defaults.aggressive_resize;
        window.options.remain_on_exit = self.window_defaults.remain_on_exit;
        window.options.overrides = .{};
    }

    pub fn applySessionStatusDefaults(self: *const Server, session: *Session) !void {
        session.options.base_index = self.session_status_defaults.base_index;
        session.options.status = self.session_status_defaults.status;
        session.options.status_style = self.session_status_defaults.status_style;
        try session.setStatusLeft(self.session_status_defaults.status_left);
        try session.setStatusRight(self.session_status_defaults.status_right);
        session.options.status_position = self.session_status_defaults.status_position;
        session.options.status_interval = self.session_status_defaults.status_interval;
        session.status_next_refresh_at = 0;
    }

    pub fn addMessage(self: *Server, msg: []const u8) void {
        const owned = self.allocator.dupe(u8, msg) catch return;
        self.messages.append(self.allocator, owned) catch {
            self.allocator.free(owned);
        };
    }

    const ActiveCursorState = struct {
        col: u32,
        row: u32,
        visible: bool,
        style: u3,
    };

    fn statusContentOffset(session: *const Session) u32 {
        return if (session.options.status and session.options.status_position == .top) 1 else 0;
    }

    fn statusRow(session: *const Session, rows: u32) ?u32 {
        if (!session.options.status or rows == 0) return null;
        return if (session.options.status_position == .top) 0 else rows - 1;
    }

    fn statusContentRows(session: *const Session, rows: u32) u32 {
        if (!session.options.status or rows == 0) return rows;
        return rows - 1;
    }

    fn getActiveCursorState(self: *Server, session: *const Session, window: *Window) ?ActiveCursorState {
        const active = window.active_pane orelse return null;
        const ps = self.session_loop.getPane(active.id) orelse return null;
        const yoff = statusContentOffset(session);
        return .{
            .col = active.xoff + ps.screen.cx,
            .row = active.yoff + ps.screen.cy + yoff,
            .visible = ps.screen.mode.cursor_visible,
            .style = @intFromEnum(ps.screen.cstyle),
        };
    }

    fn restoreActiveCursor(out: *output_mod.Output, cursor: ?ActiveCursorState) void {
        const active = cursor orelse return;
        out.cursorTo(active.col, active.row);
        if (active.visible) {
            out.showCursor();
            out.setCursorStyle(active.style);
        } else {
            out.hideCursor();
        }
    }

    fn hostname() []const u8 {
        const host = std.c.getenv("HOSTNAME") orelse std.c.getenv("HOST");
        return if (host) |value| std.mem.sliceTo(value, 0) else "";
    }

    fn paneIndex(window: *const Window, pane: *const Pane) u32 {
        for (window.panes.items, 0..) |candidate, idx| {
            if (candidate == pane) return @intCast(idx);
        }
        return 0;
    }

    fn windowIndex(session: *const Session, window: *const Window) u32 {
        for (session.windows.items, 0..) |candidate, idx| {
            if (candidate == window) {
                return session.options.base_index + @as(u32, @intCast(idx));
            }
        }
        return session.options.base_index;
    }

    fn windowFlags(session: *const Session, window: *const Window) []const u8 {
        if (session.active_window == window) return "*";
        if (window.flags.bell) return "!";
        if (window.flags.activity) return "#";
        if (window.flags.silence) return "~";
        return "-";
    }

    fn buildWindowStatusList(self: *Server, alloc: std.mem.Allocator, session: *const Session) ![]u8 {
        _ = self;
        var windows: std.ArrayListAligned(u8, null) = .empty;
        errdefer windows.deinit(alloc);

        const host_name = hostname();
        for (session.windows.items, 0..) |window, idx| {
            if (idx > 0) {
                try windows.append(alloc, ' ');
            }

            const active_pane = window.active_pane;
            const fmt_ctx = status_fmt.FormatContext{
                .session_name = session.name,
                .session_id = session.id,
                .window_name = window.name,
                .window_index = windowIndex(session, window),
                .window_active = session.active_window == window,
                .window_flags = windowFlags(session, window),
                .pane_index = if (active_pane) |pane| paneIndex(window, pane) else 0,
                .host = host_name,
            };
            const expanded = try status_fmt.expand(alloc, window.options.window_status_format, &fmt_ctx);
            defer alloc.free(expanded);
            try windows.appendSlice(alloc, expanded);
        }

        return try windows.toOwnedSlice(alloc);
    }

    fn applyStatusStyle(out: *output_mod.Output, style: status_style.Style) void {
        out.attrReset();
        out.setAttrs(style.attrs);
        out.setFg(style.fg);
        out.setBg(style.bg);
    }

    fn writeStyledStatusLine(out: *output_mod.Output, base_style: status_style.Style, line: []const u8) void {
        var active_style = base_style;
        applyStatusStyle(out, active_style);

        var i: usize = 0;
        while (i < line.len) {
            if (i + 1 < line.len and line[i] == '#' and line[i + 1] == '[') {
                if (std.mem.indexOfScalarPos(u8, line, i + 2, ']')) |close| {
                    active_style = status_style.apply(active_style, line[i .. close + 1]);
                    applyStatusStyle(out, active_style);
                    i = close + 1;
                    continue;
                }
            }

            const next_marker = std.mem.indexOfPos(u8, line, i, "#[") orelse line.len;
            out.writeBytes(line[i..next_marker]);
            i = next_marker;
        }
    }

    fn renderStatusBar(self: *Server, out: *output_mod.Output, session: *const Session, window: *const Window, cols: u32, rows: u32) !void {
        const row = statusRow(session, rows) orelse return;
        const host_name = hostname();
        const active_pane = window.active_pane;
        const fmt_ctx = status_fmt.FormatContext{
            .session_name = session.name,
            .session_id = session.id,
            .window_name = window.name,
            .window_index = windowIndex(session, window),
            .window_active = true,
            .window_flags = windowFlags(session, window),
            .pane_index = if (active_pane) |pane| paneIndex(window, pane) else 0,
            .host = host_name,
        };

        const left = try status_fmt.expand(self.allocator, session.options.status_left, &fmt_ctx);
        defer self.allocator.free(left);
        const right = try status_fmt.expand(self.allocator, session.options.status_right, &fmt_ctx);
        defer self.allocator.free(right);
        const center = try self.buildWindowStatusList(self.allocator, session);
        defer self.allocator.free(center);

        const status_bar = status_mod.StatusBar{
            .left = session.options.status_left,
            .right = session.options.status_right,
            .style = session.options.status_style,
            .interval = session.options.status_interval,
            .enabled = session.options.status,
        };
        const line = try status_bar.renderSections(self.allocator, cols, left, center, right);
        defer self.allocator.free(line);

        out.cursorTo(0, row);
        writeStyledStatusLine(out, status_bar.style, line);
        out.attrReset();
    }

    fn refreshStatusClientsIfDue(self: *Server) void {
        var now: i64 = 0;
        _ = time(&now);

        for (self.clients.items) |client| {
            const session = client.session orelse continue;
            if (!session.options.status or session.options.status_interval == 0) continue;

            if (session.status_next_refresh_at == 0) {
                session.status_next_refresh_at = now + @as(i64, @intCast(session.options.status_interval));
                continue;
            }
            if (now < session.status_next_refresh_at) continue;

            const window = session.active_window orelse continue;
            const pane = window.active_pane orelse continue;
            const pane_state = self.session_loop.getPane(pane.id) orelse continue;
            pane_state.dirty.markAllDirty();
            self.renderComposedToClient(client.fd, session, pane_state) catch {};
            session.status_next_refresh_at = now + @as(i64, @intCast(session.options.status_interval));
        }
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

        // Set default shell from $SHELL (like tmux).
        if (self.global_default_shell == null) {
            const shell_env = std.c.getenv("SHELL");
            if (shell_env) |s| {
                const shell_slice = std.mem.sliceTo(s, 0);
                if (shell_slice.len > 0) {
                    self.global_default_shell = self.allocator.dupeZ(u8, shell_slice) catch null;
                }
            }
        }

        log.info("server listening on {s}", .{self.socket_path});
    }

    /// Load a configuration file by executing it as commands.
    /// Returns true once a file was successfully opened, even if it was empty.
    pub fn loadConfigFile(self: *Server, path: []const u8) bool {
        const expanded_path = config_path.expandHomePath(self.allocator, path) catch return false;
        defer self.allocator.free(expanded_path);

        var path_buf: [4096]u8 = .{0} ** 4096;
        if (expanded_path.len >= path_buf.len) return false;
        @memcpy(path_buf[0..expanded_path.len], expanded_path);
        const cpath: [*:0]const u8 = @ptrCast(path_buf[0..expanded_path.len :0]);
        const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (fd < 0) return false;
        defer _ = std.c.close(fd);

        var content_buf: [65536]u8 = undefined;
        var total: usize = 0;
        while (total < content_buf.len) {
            const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
            if (n <= 0) break;
            total += @intCast(n);
        }
        if (total == 0) return true;

        var registry = cmd.Registry.init(self.allocator);
        defer registry.deinit();
        registry.registerBuiltins() catch return true;

        var ctx = cmd.Context{
            .server = self,
            .session = self.default_session,
            .window = if (self.default_session) |s| s.active_window else null,
            .pane = if (self.default_session) |s| if (s.active_window) |w| w.active_pane else null else null,
            .allocator = self.allocator,
            .registry = &registry,
            .binding_manager = &self.binding_manager,
        };

        var parser = config_parser.ConfigParser.init(self.allocator, content_buf[0..total]);
        var commands = parser.parseAll() catch return true;
        defer {
            for (commands.items) |*command| command.deinit(self.allocator);
            commands.deinit(self.allocator);
        }

        for (commands.items) |*command| {
            registry.executeParsed(&ctx, command) catch {};
        }
        return true;
    }

    /// Load config from the standard paths.
    pub fn loadDefaultConfig(self: *Server) void {
        if (self.config_file) |path| {
            _ = self.loadConfigFile(path);
            return;
        }
        if (self.loadConfigFile("~/.config/zmux/zmux.conf")) return;
        _ = self.loadConfigFile("~/.tmux.conf");
    }

    /// Fire all registered hooks for a given event type.
    /// Executes each hook command through the command registry.
    pub fn fireHooks(self: *Server, hook_type: hooks_mod.HookType) void {
        const hook_list = self.hook_registry.fire(hook_type);
        if (hook_list.len == 0) return;

        var registry = cmd.Registry.init(self.allocator);
        defer registry.deinit();
        registry.registerBuiltins() catch return;

        var ctx = cmd.Context{
            .server = self,
            .session = self.default_session,
            .window = if (self.default_session) |s| s.active_window else null,
            .pane = if (self.default_session) |s| if (s.active_window) |w| w.active_pane else null else null,
            .allocator = self.allocator,
            .registry = &registry,
            .binding_manager = &self.binding_manager,
        };

        for (hook_list) |hook| {
            var parser = config_parser.ConfigParser.init(self.allocator, hook.command);
            var commands = parser.parseAll() catch continue;
            defer {
                for (commands.items) |*command| command.deinit(self.allocator);
                commands.deinit(self.allocator);
            }
            for (commands.items) |*command| {
                registry.executeParsed(&ctx, command) catch {};
            }
        }
    }

    pub fn createSession(self: *Server, name: []const u8, shell: [:0]const u8, cols: u32, rows: u32) !*Session {
        const session = try Session.init(self.allocator, name);
        errdefer session.deinit();
        try self.applySessionStatusDefaults(session);

        const window = try Window.init(self.allocator, name, cols, rows);
        errdefer window.deinit();
        try self.applyWindowDefaults(window);

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
        // Use trackPane to both register the pane for I/O processing
        // and monitor its PTY fd with the platform event loop.
        try self.trackPane(pane, cols, rows);

        self.fireHooks(.after_new_session);

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
        if (builtin.os.tag == .macos) {
            return self.runGcd();
        }
        if (builtin.os.tag == .linux) {
            return self.runIoUring();
        }
        return self.runPoll();
    }

    /// GCD-based event loop for macOS. Uses dispatch sources for fd monitoring
    /// instead of poll(), enabling efficient kernel-level event notification.
    fn runGcd(self: *Server) !void {
        if (builtin.os.tag != .macos) return self.runPoll();

        self.gcd_loop = GcdEventLoop.init(self.allocator);
        const gcd: *GcdEventLoop = &self.gcd_loop.?;

        // Server context for dispatch callbacks — uses a stable pointer to self.
        const ServerCtx = struct {
            fn makeCallback(server: *Server) event_loop_mod.Callback {
                return .{
                    .context = @ptrCast(server),
                    .func = @ptrCast(&handleGcdEvent),
                };
            }

            fn handleGcdEvent(ctx: *anyopaque, fd: std.posix.fd_t, _: event_loop_mod.EventType) void {
                const server: *Server = @ptrCast(@alignCast(ctx));
                // Accept new clients on listen fd.
                if (fd == server.listen_fd) {
                    server.acceptClient() catch {};
                    // Register the new client fd with GCD and drain any
                    // data that arrived before the source was armed.
                    if (server.clients.items.len > 0) {
                        const new_idx = server.clients.items.len - 1;
                        const new_client = server.clients.items[new_idx];
                        if (builtin.os.tag == .macos) {
                            if (server.gcd_loop) |*gl| {
                                gl.addFd(new_client.fd, .read, makeCallback(server)) catch {};
                            }
                        }
                        // Drain buffered messages (identify + command may
                        // already be waiting before the dispatch source fires).
                        server.drainClient(new_idx);
                    }
                    return;
                }
                // Client or PTY fd.
                if (server.findClientIndex(fd)) |client_idx| {
                    server.handleClientReadable(client_idx) catch {};
                } else {
                    server.handlePtyReadable(fd);
                }
            }
        };

        const cb = ServerCtx.makeCallback(self);

        // Register listen fd.
        if (self.listen_fd >= 0) {
            try gcd.addFd(self.listen_fd, .read, cb);
        }

        // Register existing pane fds.
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd >= 0) {
                        gcd.addFd(pane.fd, .read, cb) catch {};
                    }
                }
            }
        }

        // Register existing client fds.
        for (self.clients.items) |client| {
            if (client.fd >= 0) {
                gcd.addFd(client.fd, .read, cb) catch {};
            }
        }

        // Add signal check timer (100ms).
        const signal_cb = event_loop_mod.TimerCallback{
            .context = @ptrCast(self),
            .func = @ptrCast(&struct {
                fn check(ctx: *anyopaque) void {
                    const server: *Server = @ptrCast(@alignCast(ctx));
                    server.refreshStatusClientsIfDue();
                    if (signals.SignalHandler.shouldExit()) {
                        server.stop();
                        if (builtin.os.tag == .macos) {
                            if (server.gcd_loop) |*gl| gl.stop();
                        }
                    }
                }
            }.check),
        };
        _ = try gcd.addTimer(100, true, signal_cb);

        // Block on the GCD run loop.
        try gcd.run();
    }

    /// io_uring-based event loop for Linux. Uses kernel-level async I/O
    /// instead of poll(), reducing syscall overhead.
    fn runIoUring(self: *Server) !void {
        if (builtin.os.tag != .linux) return self.runPoll();

        self.uring_loop = IoUringEventLoop.init(self.allocator) catch return self.runPoll();
        const uring: *IoUringEventLoop = &self.uring_loop.?;

        const cb = event_loop_mod.Callback{
            .context = @ptrCast(self),
            .func = @ptrCast(&struct {
                fn handleEvent(ctx: *anyopaque, fd: std.posix.fd_t, _: event_loop_mod.EventType) void {
                    const server: *Server = @ptrCast(@alignCast(ctx));
                    // Accept new clients on listen fd.
                    if (fd == server.listen_fd) {
                        server.acceptClient() catch {};
                        // Register the new client fd with io_uring and
                        // drain any buffered messages.
                        if (server.clients.items.len > 0) {
                            const new_idx = server.clients.items.len - 1;
                            const new_client = server.clients.items[new_idx];
                            if (builtin.os.tag == .linux) {
                                if (server.uring_loop) |*ul| {
                                    const new_cb = event_loop_mod.Callback{
                                        .context = @ptrCast(server),
                                        .func = @ptrCast(&handleEvent),
                                    };
                                    ul.addFd(new_client.fd, .read, new_cb) catch {};
                                }
                            }
                            server.drainClient(new_idx);
                        }
                        return;
                    }
                    // Client or PTY fd.
                    if (server.findClientIndex(fd)) |client_idx| {
                        server.handleClientReadable(client_idx) catch {};
                    } else {
                        server.handlePtyReadable(fd);
                    }
                }
            }.handleEvent),
        };

        // Register listen fd.
        if (self.listen_fd >= 0) {
            try uring.addFd(self.listen_fd, .read, cb);
        }

        // Register existing pane fds.
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd >= 0) {
                        uring.addFd(pane.fd, .read, cb) catch {};
                    }
                }
            }
        }

        // Register existing client fds.
        for (self.clients.items) |client| {
            if (client.fd >= 0) {
                uring.addFd(client.fd, .read, cb) catch {};
            }
        }

        // Add signal check timer (100ms).
        const signal_cb = event_loop_mod.TimerCallback{
            .context = @ptrCast(self),
            .func = @ptrCast(&struct {
                fn check(ctx: *anyopaque) void {
                    const server: *Server = @ptrCast(@alignCast(ctx));
                    server.refreshStatusClientsIfDue();
                    if (signals.SignalHandler.shouldExit()) {
                        server.stop();
                        if (builtin.os.tag == .linux) {
                            if (server.uring_loop) |*ul| ul.stop();
                        }
                    }
                }
            }.check),
        };
        _ = try uring.addTimer(100, true, signal_cb);

        // Block on the io_uring event loop.
        try uring.run();
    }

    /// Traditional poll()-based event loop. Used as fallback when platform-specific loops unavailable.
    fn runPoll(self: *Server) !void {
        const max_fds = 256;
        var pollfds: [max_fds]std.c.pollfd = undefined;

        while (self.running) {
            self.refreshStatusClientsIfDue();
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
            if (result == 0) {
                self.refreshStatusClientsIfDue();
                continue;
            }

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
        self.fireHooks(.session_closed);
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
        self.fireHooks(.client_detached);
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
            error.WouldBlock => return err, // no data yet, propagate to caller
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
        const ident: *const protocol.IdentifyMsg = @ptrCast(@alignCast(payload.ptr));
        self.clients.items[client_idx].identified = true;
        self.clients.items[client_idx].pid = ident.pid;
        self.clients.items[client_idx].cols = if (ident.cols > 0) ident.cols else 80;
        self.clients.items[client_idx].rows = if (ident.rows > 0) ident.rows else 24;
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

        // Send ready (enter interactive mode) when the command attached the
        // client to a (possibly different) session. This covers:
        //   - new-session: prev was null or different session
        //   - attach-session: prev was null or different session
        // Send exit_ack for non-attaching commands (list-sessions, etc.).
        if (ctx.session != null and (prev_session == null or prev_session != ctx.session)) {
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
            // Check for SGR mouse sequence: ESC[<btn;x;yM or ESC[<btn;x;ym
            if (self.parseSgrMouse(payload, window, pane)) return;
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

    /// Parse an SGR mouse sequence (ESC[<btn;x;yM or ESC[<btn;x;ym),
    /// find the target pane by coordinates, adjust coordinates to pane-local,
    /// and forward the adjusted sequence to the pane's PTY.
    /// Returns true if the payload was handled as a mouse event.
    fn parseSgrMouse(
        self: *Server,
        payload: []const u8,
        window: *Window,
        default_pane: *Pane,
    ) bool {
        // SGR mouse format: ESC [ < Btn ; X ; Y [Mm]
        // Minimum length: ESC [ < 0 ; 1 ; 1 M = 10 bytes
        if (payload.len < 10) return false;
        if (payload[1] != '[' or payload[2] != '<') return false;

        const final = payload[payload.len - 1];
        if (final != 'M' and final != 'm') return false;

        // Parse btn;x;y from payload[3..len-1]
        const params = payload[3 .. payload.len - 1];
        var parts: [3]u32 = .{ 0, 0, 0 };
        var part_idx: usize = 0;
        for (params) |c| {
            if (c == ';') {
                part_idx += 1;
                if (part_idx >= 3) return false;
            } else if (c >= '0' and c <= '9') {
                parts[part_idx] = parts[part_idx] * 10 + (c - '0');
            } else {
                return false; // unexpected character
            }
        }
        if (part_idx != 2) return false;

        const btn = parts[0];
        const abs_x = parts[1];
        const abs_y = parts[2];

        // Convert from 1-based to 0-based.
        const x = if (abs_x > 0) abs_x - 1 else 0;
        const y = if (abs_y > 0) abs_y - 1 else 0;

        // Find which pane contains these coordinates.
        var target_pane = default_pane;
        for (window.panes.items) |pane| {
            if (x >= pane.xoff and x < pane.xoff + pane.sx and
                y >= pane.yoff and y < pane.yoff + pane.sy)
            {
                target_pane = pane;
                break;
            }
        }

        // Check if the target pane has mouse mode enabled.
        if (self.session_loop.getPane(target_pane.id)) |ps| {
            if (!ps.screen.mode.mouse_standard and !ps.screen.mode.mouse_button and
                !ps.screen.mode.mouse_any)
            {
                // Mouse not enabled on this pane — select pane on click.
                if (final == 'M' and btn == 0) {
                    window.selectPane(target_pane);
                }
                return true;
            }
        }

        // Adjust coordinates to pane-local (1-based).
        const local_x = x - target_pane.xoff + 1;
        const local_y = y - target_pane.yoff + 1;

        // Rebuild and forward the adjusted SGR mouse sequence.
        var buf: [32]u8 = undefined;
        const seq = std.fmt.bufPrint(&buf, "\x1b[<{d};{d};{d}{c}", .{
            btn, local_x, local_y, final,
        }) catch return false;

        if (target_pane.fd >= 0) {
            _ = std.c.write(target_pane.fd, seq.ptr, seq.len);
        }
        return true;
    }

    fn handleClientResize(self: *Server, client_idx: usize, payload: []const u8) void {
        if (payload.len < @sizeOf(protocol.ResizeMsg)) return;
        const msg: *const protocol.ResizeMsg = @ptrCast(@alignCast(payload.ptr));
        const client = &self.clients.items[client_idx];
        client.cols = if (msg.cols > 0) msg.cols else client.cols;
        client.rows = if (msg.rows > 0) msg.rows else client.rows;
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
        if (n <= 0) {
            // EOF on PTY — pane process exited.
            if (!pane.flags.exited) {
                pane.flags.exited = true;
                self.fireHooks(.pane_exited);

                // Check remain-on-exit: if set, write "Pane is dead" overlay.
                const session = self.findSessionForPaneFd(fd) orelse return;
                for (session.windows.items) |window| {
                    for (window.panes.items) |wp| {
                        if (wp == pane and window.options.remain_on_exit) {
                            if (self.session_loop.getPane(pane.id)) |ps| {
                                const dead_msg = "[Pane is dead]";
                                @import("input_handler.zig").processBytes(&ps.parser, &ps.screen, "\x1b[H\x1b[2J");
                                @import("input_handler.zig").processBytes(&ps.parser, &ps.screen, dead_msg);
                                ps.dirty.markAllDirty();
                            }
                            return; // Don't remove the pane.
                        }
                    }
                }
            }
            return;
        }

        const pane_state = self.session_loop.getPane(pane.id);
        if (pane_state) |ps| {
            ps.processPtyOutput(buf[0..@intCast(n)]);
        }

        const session = self.findSessionForPaneFd(fd) orelse return;

        // Auto-rename: update window name from foreground process.
        if (pane.pid > 0) {
            for (session.windows.items) |window| {
                if (window.active_pane == pane) {
                    if (platform.getProcessName(self.allocator, pane.pid) catch null) |new_name| {
                        defer self.allocator.free(new_name);
                        if (!std.mem.eql(u8, window.name, new_name)) {
                            window.rename(new_name) catch {};
                        }
                    }
                    break;
                }
            }
        }

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
        _ = pane_state_opt;

        // Use a pipe so Output can flush to the write end while we
        // collect the bytes from the read end. Set write end non-blocking
        // to prevent deadlock when output exceeds the kernel pipe buffer.
        var pipe_fds: [2]std.c.fd_t = undefined;
        if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
        defer _ = std.c.close(pipe_fds[0]);

        const fl = std.c.fcntl(pipe_fds[1], std.c.F.GETFL);
        if (fl >= 0) {
            _ = std.c.fcntl(pipe_fds[1], std.c.F.SETFL, fl | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true })));
        }

        const redraw_mod = @import("screen/redraw.zig");
        var out = output_mod.Output.init(pipe_fds[1]);

        // Render all panes in the active window at their layout offsets.
        const window = session.active_window orelse {
            _ = std.c.close(pipe_fds[1]);
            return error.NoPaneState;
        };
        const pane_count = window.panes.items.len;
        const active_cursor = self.getActiveCursorState(session, window);
        const cols: u32 = window.sx;
        const rows: u32 = window.sy;
        const pane_yoff = statusContentOffset(session);
        const pane_rows = statusContentRows(session, rows);

        if (pane_count > 1) {
            out.hideCursor();
        }
        for (window.panes.items) |pane| {
            if (self.session_loop.getPane(pane.id)) |ps| {
                const available_rows = pane_rows -| pane.yoff;
                redraw_mod.redrawAtClipped(&ps.dirty, &ps.screen, &out, pane.xoff, pane.yoff + pane_yoff, available_rows);
            }
        }

        if (pane_count > 1) {
            if (window.layout_root) |root| {
                self.drawLayoutBorders(&out, root, window.sx, pane_rows, pane_yoff);
            }
        }

        try self.renderStatusBar(&out, session, window, cols, rows);

        restoreActiveCursor(&out, active_cursor);

        out.flush();

        // Close write end so read gets EOF.
        _ = std.c.close(pipe_fds[1]);

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

    /// Recursively draw border lines between panes based on the layout tree.
    fn drawLayoutBorders(
        self: *Server,
        out: *output_mod.Output,
        cell: *const @import("layout/layout.zig").LayoutCell,
        total_cols: u32,
        total_rows: u32,
        y_offset: u32,
    ) void {
        if (cell.cell_type == .pane) return;

        const children = cell.children.items;
        if (children.len < 2) {
            for (children) |child| {
                self.drawLayoutBorders(out, child, total_cols, total_rows, y_offset);
            }
            return;
        }

        // Draw borders between adjacent children.
        for (children[0 .. children.len - 1]) |child| {
            if (cell.cell_type == .horizontal) {
                // Vertical border: draw at (child.xoff + child.sx, child.yoff) to (child.xoff + child.sx, child.yoff + child.sy - 1)
                const bx = child.xoff + child.sx;
                const top = child.yoff;
                const bottom = @min(child.yoff + child.sy, total_rows) -| 1;
                out.attrReset();
                var y = top;
                while (y <= bottom) : (y += 1) {
                    out.cursorTo(bx, y + y_offset);
                    out.writeBytes("\xe2\x94\x82"); // U+2502 │
                }
            } else if (cell.cell_type == .vertical) {
                // Horizontal border: draw at (child.xoff, child.yoff + child.sy) to (child.xoff + child.sx - 1, child.yoff + child.sy)
                const by = child.yoff + child.sy;
                if (by >= total_rows) continue;
                const left = child.xoff;
                const right = child.xoff + child.sx -| 1;
                out.attrReset();
                out.cursorTo(left, by + y_offset);
                var x = left;
                while (x <= right) : (x += 1) {
                    out.writeBytes("\xe2\x94\x80"); // U+2500 ─
                }
            }
        }

        // Recurse into children.
        for (children) |child| {
            self.drawLayoutBorders(out, child, total_cols, total_rows, y_offset);
        }
    }

    /// Drain all pending messages on a newly accepted client.
    /// Called after registering the fd with the platform event loop to
    /// handle data that arrived before the dispatch source was armed.
    fn drainClient(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const fd = self.clients.items[client_idx].fd;

        // Set non-blocking temporarily so we don't hang.
        const fl = std.c.fcntl(fd, std.c.F.GETFL);
        if (fl >= 0) {
            _ = std.c.fcntl(fd, std.c.F.SETFL, fl | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true })));
        }
        defer if (fl >= 0) {
            _ = std.c.fcntl(fd, std.c.F.SETFL, fl);
        };

        // Process up to a few messages (identify + command typically).
        // Break on WouldBlock (no more data) without removing the client.
        var count: usize = 0;
        while (count < 8) : (count += 1) {
            if (client_idx >= self.clients.items.len) break;
            self.handleClientReadable(client_idx) catch |err| switch (err) {
                error.WouldBlock => break, // no more data, normal for non-blocking
                else => break,
            };
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
            self.fireHooks(.client_attached);
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
        if (pane.fd >= 0) {
            const cb = event_loop_mod.Callback{
                .context = @ptrCast(self),
                .func = @ptrCast(&struct {
                    fn handle(ctx: *anyopaque, fd: std.posix.fd_t, _: event_loop_mod.EventType) void {
                        const server: *Server = @ptrCast(@alignCast(ctx));
                        server.handlePtyReadable(fd);
                    }
                }.handle),
            };
            // Register with platform event loop if active.
            if (builtin.os.tag == .macos) {
                if (self.gcd_loop) |*gcd| gcd.addFd(pane.fd, .read, cb) catch {};
            }
            if (builtin.os.tag == .linux) {
                if (self.uring_loop) |*uring| uring.addFd(pane.fd, .read, cb) catch {};
            }
        }
    }

    pub fn untrackPane(self: *Server, pane_id: u32) void {
        // Remove from platform event loop if active.
        if (self.session_loop.getPane(pane_id)) |ps| {
            if (builtin.os.tag == .macos) {
                if (self.gcd_loop) |*gcd| gcd.removeFd(ps.pty_fd);
            }
            if (builtin.os.tag == .linux) {
                if (self.uring_loop) |*uring| uring.removeFd(ps.pty_fd);
            }
        }
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
extern "c" fn time(timer: ?*i64) i64;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

test "commandAllowsMissingSession includes if-shell" {
    try std.testing.expect(commandAllowsMissingSession("if-shell"));
    try std.testing.expect(!commandAllowsMissingSession("send-prefix"));
}

test "loadDefaultConfig falls back to legacy tmux path and stores window defaults" {
    var home_buf: [128]u8 = undefined;
    const home_path = try std.fmt.bufPrint(&home_buf, "/tmp/zmux-test-home-{d}", .{std.c.getpid()});
    const home_z = try std.testing.allocator.dupeZ(u8, home_path);
    defer std.testing.allocator.free(home_z);
    if (std.c.mkdir(home_z, 0o755) != 0) {
        return error.Unexpected;
    }

    var file_buf: [160]u8 = undefined;
    const legacy_path = try std.fmt.bufPrint(&file_buf, "{s}/.tmux.conf", .{home_path});
    const legacy_z = try std.testing.allocator.dupeZ(u8, legacy_path);
    defer std.testing.allocator.free(legacy_z);
    defer {
        _ = std.c.unlink(legacy_z);
        _ = std.c.rmdir(home_z);
    }

    const fd = std.c.open(legacy_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const content =
        \\bind-key -n C-a display-message legacy
        \\set -g mode-keys vi
        \\
    ;
    try std.testing.expectEqual(@as(isize, @intCast(content.len)), std.c.write(fd, content.ptr, content.len));

    const old_home = if (std.c.getenv("HOME")) |home|
        try std.testing.allocator.dupeZ(u8, std.mem.sliceTo(home, 0))
    else
        null;
    defer {
        if (old_home) |home| {
            _ = setenv("HOME", home, 1);
            std.testing.allocator.free(home);
        } else {
            _ = unsetenv("HOME");
        }
    }

    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", home_z, 1));

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-default-config.sock");
    defer server.deinit();
    server.loadDefaultConfig();

    try std.testing.expectEqualStrings("vi", server.window_defaults.mode_keys);

    const root = server.binding_manager.tables.get("root") orelse return error.ExpectedRootTable;
    const c_a = key_string.stringToKey("C-a") orelse return error.ExpectedKey;
    const action = root.lookup(c_a.key, c_a.mods) orelse return error.ExpectedBinding;
    switch (action) {
        .command => |command| try std.testing.expectEqualStrings("display-message legacy", command),
        .none => return error.ExpectedCommand,
    }
}

test "renderComposedToClient restores single-pane cursor after status bar" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-single-pane.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 20, 4);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 20, 3);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    const pane_state = server.session_loop.getPane(pane.id).?;
    pane_state.processPtyOutput("prompt");
    pane_state.processPtyOutput("\x1b[2;5H");

    var client_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&client_pipe));
    defer _ = std.c.close(client_pipe[0]);
    defer _ = std.c.close(client_pipe[1]);

    try server.renderComposedToClient(client_pipe[1], session, pane_state);

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, client_pipe[0]);
    defer msg.deinit();

    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expect(std.mem.endsWith(u8, msg.payload, "\x1b[2;5H\x1b[?25h\x1b[2 q"));
}

test "renderComposedToClient preserves active-pane cursor style in multi-pane mode" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-multi-pane.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 30, 6);
    try session.addWindow(window);

    const left = try Pane.init(std.testing.allocator, 14, 5);
    try window.addPane(left);
    try server.session_loop.addPane(left.id, -1, left.sx, left.sy);

    const right = try Pane.init(std.testing.allocator, 14, 5);
    right.xoff = 15;
    try window.addPane(right);
    try server.session_loop.addPane(right.id, -1, right.sx, right.sy);
    window.selectPane(right);

    const right_state = server.session_loop.getPane(right.id).?;
    right_state.processPtyOutput("vim");
    right_state.processPtyOutput("\x1b[2;4H");
    right_state.processPtyOutput("\x1b[4 q");

    var client_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&client_pipe));
    defer _ = std.c.close(client_pipe[0]);
    defer _ = std.c.close(client_pipe[1]);

    try server.renderComposedToClient(client_pipe[1], session, right_state);

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, client_pipe[0]);
    defer msg.deinit();

    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expect(std.mem.endsWith(u8, msg.payload, "\x1b[2;19H\x1b[?25h\x1b[4 q"));
}

fn renderPayloadForTest(server: *Server, session: *Session, pane_state: ?*server_loop.PaneState) ![]u8 {
    var client_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&client_pipe));
    defer _ = std.c.close(client_pipe[0]);
    defer _ = std.c.close(client_pipe[1]);

    try server.renderComposedToClient(client_pipe[1], session, pane_state);

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, client_pipe[0]);
    defer msg.deinit();

    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    return try std.testing.allocator.dupe(u8, msg.payload);
}

test "renderComposedToClient uses configured status-left and status-right" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-status-configured.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 32, 5);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 32, 4);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    try session.setStatusLeft("LEFT:#S");
    try session.setStatusRight("RIGHT:#W");

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "LEFT:demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "RIGHT:win") != null);
}

test "renderComposedToClient omits configured status when disabled" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-status-disabled.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 28, 4);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 28, 3);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    session.options.status = false;
    try session.setStatusLeft("STATUS-DISABLED");

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "STATUS-DISABLED") == null);
}

test "renderComposedToClient includes window list output for active session" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-window-list.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const first = try Window.init(std.testing.allocator, "editor", 40, 5);
    try session.addWindow(first);
    const first_pane = try Pane.init(std.testing.allocator, 40, 4);
    try first.addPane(first_pane);
    try server.session_loop.addPane(first_pane.id, -1, first_pane.sx, first_pane.sy);

    const second = try Window.init(std.testing.allocator, "shell", 40, 5);
    try session.addWindow(second);
    const second_pane = try Pane.init(std.testing.allocator, 40, 4);
    try second.addPane(second_pane);
    try server.session_loop.addPane(second_pane.id, -1, second_pane.sx, second_pane.sy);
    session.selectWindow(second);

    try session.setStatusLeft("");
    try session.setStatusRight("");

    const pane_state = server.session_loop.getPane(second_pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    const first_idx = std.mem.indexOf(u8, payload, "editor");
    const second_idx = std.mem.indexOf(u8, payload, "shell");
    try std.testing.expect(first_idx != null);
    try std.testing.expect(second_idx != null);
    try std.testing.expect(first_idx.? < second_idx.?);
}

test "renderComposedToClient applies status style, top position, and window markers" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-status-top.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const first = try Window.init(std.testing.allocator, "editor", 36, 5);
    try session.addWindow(first);
    const first_pane = try Pane.init(std.testing.allocator, 36, 4);
    try first.addPane(first_pane);
    try server.session_loop.addPane(first_pane.id, -1, first_pane.sx, first_pane.sy);

    const second = try Window.init(std.testing.allocator, "shell", 36, 5);
    try session.addWindow(second);
    const second_pane = try Pane.init(std.testing.allocator, 36, 4);
    try second.addPane(second_pane);
    try server.session_loop.addPane(second_pane.id, -1, second_pane.sx, second_pane.sy);

    try session.setStatusLeft("[#S]");
    try session.setStatusRight("RIGHT");
    session.options.status_style = .{
        .fg = .white,
        .bg = .black,
        .attrs = .{ .bold = true },
    };
    session.options.status_position = .top;

    const pane_state = server.session_loop.getPane(first_pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[1;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[1m\x1b[37m\x1b[40m") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "0:editor* 1:shell-") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "RIGHT") != null);
}

test "loadDefaultConfig applies status defaults that reach composed render" {
    var home_buf: [128]u8 = undefined;
    const home_path = try std.fmt.bufPrint(&home_buf, "/tmp/zmux-test-home-status-{d}", .{std.c.getpid()});
    const home_z = try std.testing.allocator.dupeZ(u8, home_path);
    defer std.testing.allocator.free(home_z);
    if (std.c.mkdir(home_z, 0o755) != 0) return error.Unexpected;

    var file_buf: [192]u8 = undefined;
    const legacy_path = try std.fmt.bufPrint(&file_buf, "{s}/.tmux.conf", .{home_path});
    const legacy_z = try std.testing.allocator.dupeZ(u8, legacy_path);
    defer std.testing.allocator.free(legacy_z);
    defer {
        _ = std.c.unlink(legacy_z);
        _ = std.c.rmdir(home_z);
    }

    const fd = std.c.open(legacy_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const content =
        \\set -g status-left '[cfg-left]'
        \\set -g status-right '[cfg-right]'
        \\set -g status-style 'fg=white,bg=black,bold'
        \\set -g status-position top
        \\set -g status-interval 7
        \\
    ;
    try std.testing.expectEqual(@as(isize, @intCast(content.len)), std.c.write(fd, content.ptr, content.len));

    const old_home = if (std.c.getenv("HOME")) |home|
        try std.testing.allocator.dupeZ(u8, std.mem.sliceTo(home, 0))
    else
        null;
    defer {
        if (old_home) |home| {
            _ = setenv("HOME", home, 1);
            std.testing.allocator.free(home);
        } else {
            _ = unsetenv("HOME");
        }
    }
    try std.testing.expectEqual(@as(c_int, 0), setenv("HOME", home_z, 1));

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-config-status.sock");
    defer server.deinit();
    server.loadDefaultConfig();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.applySessionStatusDefaults(session);
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 32, 5);
    try session.addWindow(window);
    const pane = try Pane.init(std.testing.allocator, 32, 4);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    try std.testing.expectEqualStrings("[cfg-left]", session.options.status_left);
    try std.testing.expectEqualStrings("[cfg-right]", session.options.status_right);
    try std.testing.expectEqual(.top, session.options.status_position);
    try std.testing.expectEqual(@as(u32, 7), session.options.status_interval);

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "[cfg-left]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "[cfg-right]") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[1;1H") != null);
}

test "status interval refresh renders attached clients when due" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-status-refresh.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 28, 4);
    try session.addWindow(window);
    const pane = try Pane.init(std.testing.allocator, 28, 3);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);
    const pane_state = server.session_loop.getPane(pane.id).?;
    pane_state.processPtyOutput("body");

    try session.setStatusLeft("LEFT");
    try session.setStatusRight("RIGHT");
    session.options.status_interval = 1;
    var now: i64 = 0;
    _ = time(&now);
    session.status_next_refresh_at = now - 1;

    var client_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&client_pipe));
    defer _ = std.c.close(client_pipe[0]);
    defer _ = std.c.close(client_pipe[1]);

    try server.clients.append(server.allocator, .{
        .fd = client_pipe[1],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    server.refreshStatusClientsIfDue();

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, client_pipe[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "LEFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg.payload, "RIGHT") != null);
    try std.testing.expect(session.status_next_refresh_at > now);
}

test "renderComposedToClient interprets inline status styles and shell segments" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-status-inline-style.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 48, 5);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 48, 4);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    try session.setStatusLeft("#[fg=green#,bold#,bg=colour235]LEFT#[default] #(printf up)");
    try session.setStatusRight("#[fg=#666361#,bg=default]RIGHT");
    session.options.status_style = .{
        .fg = .white,
        .bg = .black,
        .attrs = .{},
    };

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "#[") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "#(") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "LEFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "up") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "RIGHT") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[1m\x1b[32m\x1b[48;5;235mLEFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[0m\x1b[39m\x1b[49m") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[38;2;102;99;97m\x1b[49mRIGHT") != null);
}
