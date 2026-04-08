const std = @import("std");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const Pane = @import("window.zig").Pane;
const ChooseTreeState = @import("window.zig").ChooseTreeState;
const pane_mod = @import("pane.zig");
const Pty = pane_mod.Pty;
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
const platform = @import("platform/platform.zig");
const FdPoller = @import("platform/poller.zig").Poller;
const StdIoRuntime = @import("platform/std_io.zig").Runtime;
const startup_probe = @import("startup_probe.zig");

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
    pending_pane_writes: std.AutoHashMap(u32, std.ArrayListAligned(u8, null)),
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
    status_command_cache: status_fmt.ShellCommandCache,
    messages: std.ArrayListAligned([]u8, null),
    marked_pane: ?*Pane,
    next_client_id: u64,
    running: bool,
    allocator: std.mem.Allocator,
    fd_registry: std.AutoHashMap(std.c.fd_t, FdOwner),
    pane_registry: std.AutoHashMap(u32, PaneRef),
    fd_poller: FdPoller,
    std_io_runtime: StdIoRuntime,

    const FdOwner = union(enum) {
        listen,
        client: usize,
        pane: u32,
    };

    const PaneRef = struct {
        session: *Session,
        pane: *Pane,
    };

    pub const ClientConnection = struct {
        const RelayState = enum {
            inactive,
            startup_pending,
            startup_active,
            relay_done,
        };

        const ProbeRequest = struct {
            request_id: u32,
            kind: startup_probe.ProbeKind,
        };

        const InFlightProbe = struct {
            request_id: u32,
            kind: startup_probe.ProbeKind,
        };

        fd: std.c.fd_t,
        session: ?*Session,
        identified: bool,
        choose_tree_state: ?ChooseTreeState,
        recv_state: protocol.RecvState = .{},
        locked: bool = false,
        client_id: u64 = 0,
        pid: i32 = 0,
        identify_flags: protocol.IdentifyFlags = .{},
        term_name: [64]u8 = .{0} ** 64,
        tty_name: [64]u8 = .{0} ** 64,
        cols: u16 = 80,
        rows: u16 = 24,
        xpixel: u16 = 0,
        ypixel: u16 = 0,
        prefix_active: bool = false,
        relay_state: RelayState = .inactive,
        relay_started_at_ns: u64 = 0,
        relay_last_probe_ns: u64 = 0,
        next_probe_request_id: u32 = 1,
        pending_probe_requests: std.ArrayListAligned(ProbeRequest, null) = .empty,
        inflight_probe_requests: std.ArrayListAligned(InFlightProbe, null) = .empty,
        probe_parse_buffer: std.ArrayListAligned(u8, null) = .empty,
        pending_output: std.ArrayListAligned(u8, null) = .empty,

        fn deinit(self: *ClientConnection, alloc: std.mem.Allocator) void {
            if (self.choose_tree_state) |*state| {
                state.deinit();
            }
            self.recv_state.deinit(alloc);
            self.pending_probe_requests.deinit(alloc);
            self.inflight_probe_requests.deinit(alloc);
            self.probe_parse_buffer.deinit(alloc);
            self.pending_output.deinit(alloc);
            if (self.fd >= 0) _ = std.c.close(self.fd);
        }
    };

    pub const WindowOptionDefaults = struct {
        mode_keys: []u8,
        window_status_format: []u8,
        window_status_current_format: []u8,
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
        const default_window_status_current_format = try alloc.dupe(u8, "#I:#W#F");
        errdefer alloc.free(default_window_status_current_format);
        const default_status_left = try alloc.dupe(u8, "[#S]");
        errdefer alloc.free(default_status_left);
        const default_status_right = try alloc.dupe(u8, "#H");
        errdefer alloc.free(default_status_right);

        return .{
            .listen_fd = -1,
            .socket_path = try alloc.dupe(u8, socket_path),
            .sessions = .empty,
            .clients = .empty,
            .pending_pane_writes = std.AutoHashMap(u32, std.ArrayListAligned(u8, null)).init(alloc),
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
                .window_status_current_format = default_window_status_current_format,
            },
            .config_file = null,
            .status_command_cache = status_fmt.ShellCommandCache.init(std.heap.c_allocator),
            .messages = .empty,
            .marked_pane = null,
            .next_client_id = 1,
            .running = false,
            .allocator = alloc,
            .fd_registry = std.AutoHashMap(std.c.fd_t, FdOwner).init(alloc),
            .pane_registry = std.AutoHashMap(u32, PaneRef).init(alloc),
            .fd_poller = try FdPoller.init(alloc),
            .std_io_runtime = StdIoRuntime.init(alloc),
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        for (self.sessions.items) |session| {
            session.deinit();
        }
        self.sessions.deinit(self.allocator);
        for (self.clients.items) |*client| {
            client.deinit(self.allocator);
        }
        self.clients.deinit(self.allocator);
        {
            var pending_iter = self.pending_pane_writes.iterator();
            while (pending_iter.next()) |entry| {
                entry.value_ptr.deinit(self.allocator);
            }
            self.pending_pane_writes.deinit();
        }
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
        self.allocator.free(self.window_defaults.window_status_current_format);
        self.status_command_cache.deinit();
        for (self.messages.items) |msg| self.allocator.free(msg);
        self.messages.deinit(self.allocator);
        self.fd_registry.deinit();
        self.pane_registry.deinit();
        self.fd_poller.deinit();
        self.std_io_runtime.deinit();
        self.allocator.free(self.socket_path);
    }

    pub fn applyWindowDefaults(self: *const Server, window: *Window) !void {
        try window.setModeKeys(self.window_defaults.mode_keys);
        try window.setWindowStatusFormat(self.window_defaults.window_status_format);
        try window.setWindowStatusCurrentFormat(self.window_defaults.window_status_current_format);
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
            const status_format = if (session.active_window == window)
                window.options.window_status_current_format
            else
                window.options.window_status_format;
            const expanded = try status_fmt.expand(alloc, status_format, &fmt_ctx);
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
                if (status_style.markerEnd(line, i)) |end| {
                    active_style = status_style.apply(active_style, line[i..end]);
                    applyStatusStyle(out, active_style);
                    i = end;
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

        const refresh_interval_ns = @as(u64, @max(session.options.status_interval, 1)) * std.time.ns_per_s;
        const left = try status_fmt.expandCached(self.allocator, session.options.status_left, &fmt_ctx, &self.status_command_cache, refresh_interval_ns);
        defer self.allocator.free(left);
        const right = try status_fmt.expandCached(self.allocator, session.options.status_right, &fmt_ctx, &self.status_command_cache, refresh_interval_ns);
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
            if (self.sessionStartupRelayActive(session)) continue;
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

    const idle_poll_timeout_ms: c_int = 1000;
    const pending_write_retry_timeout_ms: c_int = 10;

    fn hasPendingClientOutput(self: *const Server) bool {
        for (self.clients.items) |client| {
            if (client.pending_output.items.len > 0) return true;
        }
        return false;
    }

    fn hasPendingPaneWrites(self: *const Server) bool {
        var iter = self.pending_pane_writes.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.items.len > 0) return true;
        }
        return false;
    }

    fn nextStatusRefreshDelayMs(self: *const Server, now: i64) ?c_int {
        var next_refresh_at: ?i64 = null;

        for (self.clients.items) |client| {
            const session = client.session orelse continue;
            if (self.sessionStartupRelayActive(session)) continue;
            if (!session.options.status or session.options.status_interval == 0) continue;

            if (session.status_next_refresh_at == 0 or session.status_next_refresh_at <= now) {
                return 0;
            }

            next_refresh_at = if (next_refresh_at) |current|
                @min(current, session.status_next_refresh_at)
            else
                session.status_next_refresh_at;
        }

        const refresh_at = next_refresh_at orelse return null;
        const delay_s = @max(refresh_at - now, 0);
        const delay_ms: i64 = delay_s * std.time.ms_per_s;
        return @intCast(@min(delay_ms, idle_poll_timeout_ms));
    }

    fn nextPollTimeoutMs(self: *const Server) c_int {
        if (self.hasPendingClientOutput() or self.hasPendingPaneWrites()) {
            return pending_write_retry_timeout_ms;
        }

        var now: i64 = 0;
        _ = time(&now);
        return self.nextStatusRefreshDelayMs(now) orelse idle_poll_timeout_ms;
    }

    fn flushAllPendingPaneWrites(self: *Server) void {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (self.pending_pane_writes.contains(pane.id)) {
                        self.flushPendingPaneWrites(pane);
                    }
                }
            }
        }
    }

    fn runMaintenanceTick(self: *Server) void {
        self.flushAllClientOutputs();
        self.flushAllPendingPaneWrites();
        self.refreshStatusClientsIfDue();
    }

    fn registerReadableFd(self: *Server, fd: std.posix.fd_t, owner: FdOwner) !void {
        if (fd < 0) return;
        try self.fd_registry.put(fd, owner);
        try self.fd_poller.add(fd);
    }

    fn unregisterReadableFd(self: *Server, fd: std.posix.fd_t) void {
        if (fd < 0) return;
        _ = self.fd_registry.remove(fd);
        self.fd_poller.remove(fd);
    }

    fn updateClientFdOwnersFrom(self: *Server, start_idx: usize) void {
        var idx = start_idx;
        while (idx < self.clients.items.len) : (idx += 1) {
            const fd = self.clients.items[idx].fd;
            if (fd < 0) continue;
            self.fd_registry.put(fd, .{ .client = idx }) catch {};
        }
    }

    fn fdOwner(self: *const Server, fd: std.posix.fd_t) ?FdOwner {
        return self.fd_registry.get(fd);
    }

    fn registerPaneRef(self: *Server, pane_ref: PaneRef) void {
        self.pane_registry.put(pane_ref.pane.id, pane_ref) catch {};
    }

    fn unregisterPaneRef(self: *Server, pane_id: u32) void {
        _ = self.pane_registry.remove(pane_id);
    }

    pub fn listen(self: *Server) !void {
        try self.ensureSocketDir();
        self.removeStaleSocket();
        const io = self.std_io_runtime.io();
        const address = try std.Io.net.UnixAddress.init(self.socket_path);
        const listen_server = try address.listen(io, .{
            .kernel_backlog = 128,
        });
        self.listen_fd = listen_server.socket.handle;
        errdefer self.listen_fd = -1;
        try self.registerReadableFd(self.listen_fd, .listen);

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
        // Use trackPane to register the pane for I/O processing and perform an
        // immediate drain on any startup output already waiting on the PTY.
        try self.trackPane(pane, cols, rows);

        self.fireHooks(.after_new_session);

        return session;
    }

    pub fn acceptClient(self: *Server) !void {
        const io = self.std_io_runtime.io();
        var listen_server = std.Io.net.Server{
            .socket = .{
                .handle = self.listen_fd,
                .address = .{ .ip4 = .loopback(0) },
            },
            .options = if (std.Io.net.Server.AcceptOptions != void)
                .{ .mode = .stream, .protocol = null }
            else {},
        };
        var client_stream = listen_server.accept(io) catch |err| switch (err) {
            error.WouldBlock, error.ConnectionAborted => return,
            else => return err,
        };
        errdefer client_stream.close(io);

        const client_fd = client_stream.socket.handle;
        setFdNonblocking(client_fd);
        const client_id = self.next_client_id;
        self.next_client_id += 1;
        const client_idx = self.clients.items.len;
        try self.registerReadableFd(client_fd, .{ .client = client_idx });
        errdefer self.unregisterReadableFd(client_fd);
        try self.clients.append(self.allocator, .{
            .fd = client_fd,
            .session = null,
            .identified = false,
            .choose_tree_state = null,
            .client_id = client_id,
        });
        client_stream.socket.handle = -1;
    }

    /// Cross-platform std.Io-backed server runtime.
    ///
    /// `std.Io.Threaded` is the first-party stdlib backend that currently
    /// supports the Unix-domain socket control plane zmux uses on both macOS
    /// and Linux, while fd readiness is handled by the platform poller
    /// (`kqueue` on macOS, `epoll` on Linux, `poll` fallback elsewhere).
    pub fn run(self: *Server) !void {
        return self.runPoll();
    }

    /// Cross-platform fd-readiness loop used by the std.Io-backed server runtime.
    fn runPoll(self: *Server) !void {
        var ready_fds: [FdPoller.max_fds]std.posix.fd_t = undefined;

        while (self.running) {
            if (signals.SignalHandler.shouldExit()) {
                self.stop();
                break;
            }

            var timeout_ms = self.nextPollTimeoutMs();
            if (timeout_ms == 0) {
                startup_probe.traceEvent("server", "timer_tick", "source=poll");
                self.runMaintenanceTick();
                timeout_ms = self.nextPollTimeoutMs();
            }

            const ready = try self.fd_poller.wait(timeout_ms, &ready_fds);
            if (ready.len == 0) {
                startup_probe.traceEvent("server", "timer_tick", "source=poll");
                self.runMaintenanceTick();
                continue;
            }

            for (ready) |fd| {
                const owner = self.fdOwner(fd) orelse continue;
                switch (owner) {
                    .listen => self.acceptClient() catch {},
                    .client => |client_idx| {
                        if (client_idx >= self.clients.items.len or self.clients.items[client_idx].fd != fd) continue;
                        var detail: [160]u8 = undefined;
                        const msg = std.fmt.bufPrint(&detail, "source=poll client_id={d}", .{self.clients.items[client_idx].client_id}) catch "";
                        startup_probe.traceEvent("server", "client_fd_event", msg);
                        self.drainClient(client_idx);
                    },
                    .pane => |pane_id| {
                        if (self.findPaneRefById(pane_id)) |pane_ref| {
                            self.drainPaneReadableRef(pane_ref);
                        }
                    },
                }
            }
        }
    }

    pub fn stop(self: *Server) void {
        self.running = false;
        if (self.listen_fd >= 0) {
            self.unregisterReadableFd(self.listen_fd);
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
                self.unregisterReadableFd(pane.fd);
                self.unregisterPaneRef(pane.id);
                self.clearPendingPaneWrites(pane.id);
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
        client.relay_state = .inactive;
        client.inflight_probe_requests.clearRetainingCapacity();
        client.pending_probe_requests.clearRetainingCapacity();
        client.probe_parse_buffer.clearRetainingCapacity();
        self.fireHooks(.client_detached);
    }

    pub fn findClientIndex(self: *const Server, fd: std.c.fd_t) ?usize {
        if (self.fdOwner(fd)) |owner| switch (owner) {
            .client => |idx| {
                if (idx < self.clients.items.len and self.clients.items[idx].fd == fd) return idx;
            },
            else => {},
        };
        for (self.clients.items, 0..) |client, i| {
            if (client.fd == fd) return i;
        }
        return null;
    }

    fn handleClientReadable(self: *Server, client_idx: usize) !void {
        const client = &self.clients.items[client_idx];
        var message = protocol.recvMessageAllocNonblocking(self.allocator, client.fd, &client.recv_state) catch |err| switch (err) {
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
            .terminal_probe_ready => self.handleTerminalProbeReady(client_idx),
            .terminal_probe_rsp => try self.handleTerminalProbeRsp(client_idx, message.payload),
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
        self.clients.items[client_idx].identify_flags = ident.flags;
        self.clients.items[client_idx].term_name = ident.term_name;
        self.clients.items[client_idx].tty_name = ident.tty_name;
        self.clients.items[client_idx].cols = if (ident.cols > 0) ident.cols else 80;
        self.clients.items[client_idx].rows = if (ident.rows > 0) ident.rows else 24;
        self.clients.items[client_idx].xpixel = ident.xpixel;
        self.clients.items[client_idx].ypixel = ident.ypixel;
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
        var startup_attach_candidate = false;

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
            startup_attach_candidate = commandStartsStartupRelay(args.items[0]);

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
            startup_attach_candidate = commandStartsStartupRelay(commands.items[0].name);

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
            if (startup_attach_candidate) {
                self.beginClientStartupRelay(client_idx);
            }
            try protocol.sendMessage(client.fd, .ready, &.{});
            if (!startup_attach_candidate) {
                if (ctx.session) |session| {
                    self.renderActivePaneToClient(session, client.fd);
                }
            }
        } else {
            try protocol.sendMessageWithFlags(client.fd, .exit_ack, 0, &.{});
        }
    }

    fn commandStartsStartupRelay(name: []const u8) bool {
        return std.mem.eql(u8, name, "new-session") or
            std.mem.eql(u8, name, "new") or
            std.mem.eql(u8, name, "attach-session") or
            std.mem.eql(u8, name, "attach");
    }

    fn monotonicNs() u64 {
        var ts: std.c.timespec = undefined;
        if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    fn beginClientStartupRelay(self: *Server, client_idx: usize) void {
        const session = self.clients.items[client_idx].session orelse return;
        for (self.clients.items) |*other| {
            if (other.session != session) continue;
            if (other.client_id == self.clients.items[client_idx].client_id) continue;
            other.relay_state = .inactive;
            other.inflight_probe_requests.clearRetainingCapacity();
            other.pending_probe_requests.clearRetainingCapacity();
            other.probe_parse_buffer.clearRetainingCapacity();
        }

        const now = monotonicNs();
        const client = &self.clients.items[client_idx];
        client.relay_state = .startup_pending;
        client.relay_started_at_ns = now;
        client.relay_last_probe_ns = now;
        client.next_probe_request_id = 1;
        client.inflight_probe_requests.clearRetainingCapacity();
        client.pending_probe_requests.clearRetainingCapacity();
        client.probe_parse_buffer.clearRetainingCapacity();
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d}", .{ client.client_id, client.fd }) catch "";
        startup_probe.traceEvent("server", "begin_relay", msg);
    }

    fn handleTerminalProbeReady(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.relay_state != .startup_pending) return;
        client.relay_state = .startup_active;
        client.relay_last_probe_ns = monotonicNs();
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d}", .{ client.client_id, client.fd }) catch "";
        startup_probe.traceEvent("server", "recv_probe_ready", msg);
        self.dispatchNextStartupProbe(client_idx);
        self.drainClient(client_idx);
    }

    fn handleTerminalProbeRsp(self: *Server, client_idx: usize, payload: []const u8) !void {
        if (client_idx >= self.clients.items.len) return;
        const view = try protocol.decodeTerminalProbeRsp(payload);
        const client = &self.clients.items[client_idx];
        const session = client.session orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        var matched_idx: ?usize = null;
        for (client.inflight_probe_requests.items, 0..) |request, idx| {
            if (request.request_id == view.request_id) {
                matched_idx = idx;
                break;
            }
        }
        const inflight_idx = matched_idx orelse return;

        _ = client.inflight_probe_requests.orderedRemove(inflight_idx);
        client.relay_last_probe_ns = monotonicNs();
        var detail: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d} id={d} status={s} bytes={d}", .{ client.client_id, client.fd, view.request_id, @tagName(view.status), view.reply_bytes.len }) catch "";
        startup_probe.traceEvent("server", "recv_probe_rsp", msg);
        if (view.status == .complete and view.reply_bytes.len > 0) {
            self.writePaneInput(pane, view.reply_bytes);
        }
        self.dispatchNextStartupProbe(client_idx);
        self.drainClient(client_idx);
    }

    fn dispatchNextStartupProbe(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.relay_state != .startup_active) return;
        while (client.pending_probe_requests.items.len > 0) {
            const request = client.pending_probe_requests.orderedRemove(0);
            client.inflight_probe_requests.append(self.allocator, .{
                .request_id = request.request_id,
                .kind = request.kind,
            }) catch return;
            client.relay_last_probe_ns = monotonicNs();
            var detail: [192]u8 = undefined;
            const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d} id={d} kind={s} pending_left={d}", .{ client.client_id, client.fd, request.request_id, @tagName(request.kind), client.pending_probe_requests.items.len }) catch "";
            startup_probe.traceEvent("server", "dispatch_probe_req", msg);

            const payload = protocol.encodeTerminalProbeReq(
                self.allocator,
                request.request_id,
                client.client_id,
                request.kind,
                startup_probe.requestBytes(request.kind),
            ) catch return;
            defer self.allocator.free(payload);

            protocol.sendMessage(client.fd, .terminal_probe_req, payload) catch {};
        }
    }

    const ClientKey = struct {
        key: u21,
        mods: binding_mod.Modifiers,
    };

    const ClientKeyResolution = union(enum) {
        passthrough,
        prefix_armed,
        prefix_miss,
        command: []const u8,
    };

    fn decodeClientKey(byte: u8) ClientKey {
        if (byte == 0) {
            return .{
                .key = ' ',
                .mods = .{ .ctrl = true },
            };
        }
        if (byte < 27) {
            return .{
                .key = @as(u21, 'a') + byte - 1,
                .mods = .{ .ctrl = true },
            };
        }
        if (byte < 32) {
            return .{
                .key = @as(u21, byte) + '@',
                .mods = .{ .ctrl = true },
            };
        }
        return .{
            .key = byte,
            .mods = .{},
        };
    }

    fn lookupBindingCommand(self: *Server, table_name: []const u8, key: u21, mods: binding_mod.Modifiers) ?[]const u8 {
        const table = self.binding_manager.tables.get(table_name) orelse return null;
        const action = table.lookup(key, mods) orelse return null;
        return switch (action) {
            .command => |command| command,
            .none => null,
        };
    }

    fn normalizePrefixKey(prefix_key: u21) ?u21 {
        if (prefix_key == 0) return ' ';
        if (prefix_key < 27) return @as(u21, 'a') + prefix_key - 1;
        if (prefix_key < 32) return prefix_key + '@';
        return prefix_key;
    }

    fn matchesPrefixKey(prefix_key: u21, key: u21, mods: binding_mod.Modifiers) bool {
        const normalized = normalizePrefixKey(prefix_key) orelse return false;
        if (prefix_key < 32) {
            return mods.ctrl and !mods.meta and !mods.shift and key == normalized;
        }
        return !mods.ctrl and !mods.meta and !mods.shift and key == normalized;
    }

    fn isSessionPrefixKey(session: *Session, key: u21, mods: binding_mod.Modifiers) bool {
        if (matchesPrefixKey(session.options.prefix_key, key, mods)) return true;
        if (session.options.prefix2_key) |prefix2_key| {
            return matchesPrefixKey(prefix2_key, key, mods);
        }
        return false;
    }

    fn resolveClientKey(
        self: *Server,
        client: *ClientConnection,
        session: *Session,
        key: u21,
        mods: binding_mod.Modifiers,
    ) ClientKeyResolution {
        if (!client.prefix_active) {
            if (self.lookupBindingCommand("root", key, mods)) |command| {
                return .{ .command = command };
            }
            if (isSessionPrefixKey(session, key, mods)) {
                client.prefix_active = true;
                return .prefix_armed;
            }
            return .passthrough;
        }

        client.prefix_active = false;
        if (self.lookupBindingCommand("prefix", key, mods)) |command| {
            return .{ .command = command };
        }
        return .prefix_miss;
    }

    fn shiftPendingPaneWrite(buffer: *std.ArrayListAligned(u8, null), written: usize) void {
        if (written == 0) return;
        if (written >= buffer.items.len) {
            buffer.clearRetainingCapacity();
            return;
        }
        const remaining = buffer.items.len - written;
        std.mem.copyForwards(u8, buffer.items[0..remaining], buffer.items[written..]);
        buffer.shrinkRetainingCapacity(remaining);
    }

    fn flushPendingClientOutput(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.fd < 0 or client.pending_output.items.len == 0) return;
        const written = pane_mod.writeNonBlocking(client.fd, client.pending_output.items);
        shiftPendingPaneWrite(&client.pending_output, written);
    }

    fn flushAllClientOutputs(self: *Server) void {
        for (self.clients.items, 0..) |_, idx| {
            self.flushPendingClientOutput(idx);
        }
    }

    fn queueClientMessage(self: *Server, client_idx: usize, msg_type: protocol.MessageType, payload: []const u8) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        const encoded = protocol.encodeMessageAlloc(self.allocator, msg_type, 0, payload) catch return;
        defer self.allocator.free(encoded);
        client.pending_output.appendSlice(self.allocator, encoded) catch return;
        self.flushPendingClientOutput(client_idx);
    }

    fn clearPendingPaneWrites(self: *Server, pane_id: u32) void {
        if (self.pending_pane_writes.fetchRemove(pane_id)) |entry| {
            var pending = entry.value;
            pending.deinit(self.allocator);
        }
    }

    fn flushPendingPaneWrites(self: *Server, pane: *Pane) void {
        const pending = self.pending_pane_writes.getPtr(pane.id) orelse return;
        if (pane.fd < 0) {
            self.clearPendingPaneWrites(pane.id);
            return;
        }

        const written = pane_mod.writeNonBlocking(pane.fd, pending.items);
        shiftPendingPaneWrite(pending, written);
        if (pending.items.len == 0) {
            self.clearPendingPaneWrites(pane.id);
        }
    }

    fn appendPendingPaneWrite(self: *Server, pane_id: u32, data: []const u8) void {
        if (data.len == 0) return;

        if (self.pending_pane_writes.getPtr(pane_id)) |pending| {
            pending.appendSlice(self.allocator, data) catch {};
            return;
        }

        self.pending_pane_writes.put(pane_id, .empty) catch return;
        if (self.pending_pane_writes.getPtr(pane_id)) |pending| {
            pending.appendSlice(self.allocator, data) catch {};
        }
    }

    fn writePaneInput(self: *Server, pane: *Pane, data: []const u8) void {
        if (pane.fd < 0 or data.len == 0) return;
        var detail: [160]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "pane_id={d} bytes={d} newline={any}", .{ pane.id, data.len, std.mem.indexOfAny(u8, data, "\r\n") != null }) catch "";
        startup_probe.traceEvent("server", "write_pane_input", msg);

        if (self.pending_pane_writes.getPtr(pane.id)) |pending| {
            if (pending.items.len > 0) {
                self.appendPendingPaneWrite(pane.id, data);
                self.flushPendingPaneWrites(pane);
                return;
            }
            self.clearPendingPaneWrites(pane.id);
        }

        const written = pane_mod.writeNonBlocking(pane.fd, data);
        if (written < data.len) {
            self.appendPendingPaneWrite(pane.id, data[written..]);
            self.flushPendingPaneWrites(pane);
        }
    }

    fn handleClientKey(self: *Server, client_idx: usize, payload: []const u8) void {
        const client = &self.clients.items[client_idx];
        const session = client.session orelse return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        if (pane.fd < 0 or payload.len == 0) return;
        const startup_relay_flush = client.relay_state == .startup_active and std.mem.indexOfAny(u8, payload, "\r\n") != null;
        var detail: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d} bytes={d} newline={any} relay={s}", .{ client.client_id, client.fd, payload.len, std.mem.indexOfAny(u8, payload, "\r\n") != null, @tagName(client.relay_state) }) catch "";
        startup_probe.traceEvent("server", "handle_client_key", msg);

        self.flushPendingPaneWrites(pane);
        self.drainPaneReadable(pane.fd);

        // Pass escape sequences (multi-byte starting with ESC) directly to the PTY.
        if (payload.len > 1 and payload[0] == 0x1b) {
            client.prefix_active = false;
            // Check for SGR mouse sequence: ESC[<btn;x;yM or ESC[<btn;x;ym
            if (self.parseSgrMouse(payload, window, pane)) return;
            self.writePaneInput(pane, payload);
            if (startup_relay_flush) {
                client.relay_state = .relay_done;
                client.inflight_probe_requests.clearRetainingCapacity();
                client.pending_probe_requests.clearRetainingCapacity();
                client.probe_parse_buffer.clearRetainingCapacity();
                var finish_detail: [160]u8 = undefined;
                const finish_msg = std.fmt.bufPrint(&finish_detail, "client_id={d} reason=user_newline_escape", .{client.client_id}) catch "";
                startup_probe.traceEvent("server", "finish_relay", finish_msg);
            }
            return;
        }

        for (payload) |byte| {
            const decoded = decodeClientKey(byte);
            switch (self.resolveClientKey(client, session, decoded.key, decoded.mods)) {
                .command => |command_str| self.executeBindingCommand(client_idx, command_str),
                .passthrough => {
                    const out: [1]u8 = .{byte};
                    self.writePaneInput(pane, &out);
                },
                .prefix_armed, .prefix_miss => {},
            }
        }

        if (startup_relay_flush) {
            client.relay_state = .relay_done;
            client.inflight_probe_requests.clearRetainingCapacity();
            client.pending_probe_requests.clearRetainingCapacity();
            client.probe_parse_buffer.clearRetainingCapacity();
            var finish_detail: [160]u8 = undefined;
            const finish_msg = std.fmt.bufPrint(&finish_detail, "client_id={d} reason=user_newline_key", .{client.client_id}) catch "";
            startup_probe.traceEvent("server", "finish_relay", finish_msg);
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

        self.writePaneInput(target_pane, seq);
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

    fn ownerRelayClientIndexForSession(self: *const Server, session: *Session) ?usize {
        for (self.clients.items, 0..) |client, idx| {
            if (client.session != session) continue;
            if (client.relay_state != .inactive) {
                return idx;
            }
        }
        return null;
    }

    fn sessionStartupRelayActive(self: *const Server, session: *Session) bool {
        if (self.ownerRelayClientIndexForSession(session)) |idx| {
            const state = self.clients.items[idx].relay_state;
            return state == .startup_pending or state == .startup_active;
        }
        return false;
    }

    fn maybeExpireStartupRelay(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.relay_state != .startup_pending and client.relay_state != .startup_active) return;

        const now = monotonicNs();
        if (client.relay_started_at_ns != 0 and now - client.relay_started_at_ns >= std.time.ns_per_s) {
            client.relay_state = .relay_done;
            client.inflight_probe_requests.clearRetainingCapacity();
            client.pending_probe_requests.clearRetainingCapacity();
            var detail: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&detail, "client_id={d} reason=timeout", .{client.client_id}) catch "";
            startup_probe.traceEvent("server", "finish_relay", msg);
            return;
        }
        if (client.relay_state == .startup_active and client.inflight_probe_requests.items.len == 0 and
            client.pending_probe_requests.items.len == 0 and
            now - client.relay_last_probe_ns >= 200 * std.time.ns_per_ms)
        {
            client.relay_state = .relay_done;
            var detail: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&detail, "client_id={d} reason=quiescence", .{client.client_id}) catch "";
            startup_probe.traceEvent("server", "finish_relay", msg);
        }
    }

    fn queueStartupProbeRequest(self: *Server, client_idx: usize, kind: startup_probe.ProbeKind) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        const request_id = client.next_probe_request_id;
        client.next_probe_request_id += 1;
        client.pending_probe_requests.append(self.allocator, .{
            .request_id = request_id,
            .kind = kind,
        }) catch return;
        client.relay_last_probe_ns = monotonicNs();
        var detail: [192]u8 = undefined;
        const msg = std.fmt.bufPrint(&detail, "client_id={d} id={d} kind={s} pending={d}", .{ client.client_id, request_id, @tagName(kind), client.pending_probe_requests.items.len }) catch "";
        startup_probe.traceEvent("server", "queue_probe_req", msg);
    }

    fn flushStartupProbeBufferAsOutput(self: *Server, client_idx: usize, output: *std.ArrayListAligned(u8, null)) void {
        if (client_idx >= self.clients.items.len) return;
        const client = &self.clients.items[client_idx];
        if (client.probe_parse_buffer.items.len == 0) return;
        output.appendSlice(self.allocator, client.probe_parse_buffer.items) catch {};
        client.probe_parse_buffer.clearRetainingCapacity();
    }

    fn filterStartupProbeOutput(self: *Server, client_idx: usize, input: []const u8, output: *std.ArrayListAligned(u8, null)) void {
        const client = &self.clients.items[client_idx];
        client.probe_parse_buffer.appendSlice(self.allocator, input) catch {
            output.appendSlice(self.allocator, input) catch {};
            return;
        };

        while (client.probe_parse_buffer.items.len > 0) {
            const bytes = client.probe_parse_buffer.items;
            if (bytes[0] != 0x1b) {
                output.append(self.allocator, bytes[0]) catch {};
                _ = client.probe_parse_buffer.orderedRemove(0);
                continue;
            }

            var saw_prefix = false;
            inline for ([_]startup_probe.ProbeKind{ .osc_10, .osc_11, .osc_12, .csi_primary_da, .xtversion }) |kind| {
                const request = startup_probe.requestBytes(kind);
                if (bytes.len >= request.len and std.mem.eql(u8, bytes[0..request.len], request)) {
                    self.queueStartupProbeRequest(client_idx, kind);
                    client.probe_parse_buffer.replaceRange(self.allocator, 0, request.len, &.{}) catch {};
                    saw_prefix = true;
                    break;
                }
                if (startup_probe.requestPrefixMatch(kind, bytes) == .prefix) {
                    saw_prefix = true;
                    return;
                }
            }
            if (saw_prefix) continue;

            output.append(self.allocator, bytes[0]) catch {};
            _ = client.probe_parse_buffer.orderedRemove(0);
        }
    }

    fn renderActivePaneToClient(self: *Server, session: *Session, client_fd: std.c.fd_t) void {
        if (self.sessionStartupRelayActive(session)) return;
        const window = session.active_window orelse return;
        const pane = window.active_pane orelse return;
        self.drainPaneReadable(pane.fd);
        if (self.session_loop.getPane(pane.id)) |pane_state| {
            pane_state.dirty.markAllDirty();
            self.renderComposedToClient(client_fd, session, pane_state) catch {};
        }
    }

    fn deactivatePaneFd(self: *Server, pane: *Pane) void {
        if (pane.fd < 0) return;

        self.unregisterReadableFd(pane.fd);
        _ = std.c.close(pane.fd);
        pane.fd = -1;
        if (self.session_loop.getPane(pane.id)) |ps| {
            ps.pty_fd = -1;
        }
        self.clearPendingPaneWrites(pane.id);
    }

    fn handlePtyReadableRef(self: *Server, pane_ref: PaneRef) usize {
        const session = pane_ref.session;
        const pane = pane_ref.pane;
        const fd = pane.fd;
        var detail: [160]u8 = undefined;
        const start_msg = std.fmt.bufPrint(&detail, "fd={d}", .{fd}) catch "";
        startup_probe.traceEvent("server", "handle_pty_readable_begin", start_msg);
        var buf: [4096]u8 = undefined;
        const n = std.c.read(fd, &buf, buf.len);
        if (n < 0) {
            switch (std.posix.errno(n)) {
                .AGAIN, .INTR => return 0,
                else => return 0,
            }
        }
        if (n == 0) {
            if (!pane.flags.exited) {
                pane.flags.exited = true;
                self.fireHooks(.pane_exited);

                for (session.windows.items) |window| {
                    for (window.panes.items) |wp| {
                        if (wp == pane and window.options.remain_on_exit) {
                            if (self.session_loop.getPane(pane.id)) |ps| {
                                const dead_msg = "[Pane is dead]";
                                @import("input_handler.zig").processBytes(&ps.parser, &ps.screen, "\x1b[H\x1b[2J");
                                @import("input_handler.zig").processBytes(&ps.parser, &ps.screen, dead_msg);
                                ps.dirty.markAllDirty();
                            }
                            self.deactivatePaneFd(pane);
                            return 0;
                        }
                    }
                }
            }
            self.deactivatePaneFd(pane);
            return 0;
        }

        if (self.ownerRelayClientIndexForSession(session)) |relay_client_idx| {
            self.maybeExpireStartupRelay(relay_client_idx);
        }

        var filtered_output: std.ArrayListAligned(u8, null) = .empty;
        defer filtered_output.deinit(self.allocator);

        const owner_client_idx = self.ownerRelayClientIndexForSession(session);
        if (owner_client_idx) |relay_client_idx| {
            const relay_client = self.clients.items[relay_client_idx];
            if (relay_client.relay_state == .startup_pending or relay_client.relay_state == .startup_active) {
                self.filterStartupProbeOutput(relay_client_idx, buf[0..@intCast(n)], &filtered_output);
                self.dispatchNextStartupProbe(relay_client_idx);
                self.drainClient(relay_client_idx);
            } else {
                self.flushStartupProbeBufferAsOutput(relay_client_idx, &filtered_output);
                filtered_output.appendSlice(self.allocator, buf[0..@intCast(n)]) catch {};
            }
        } else {
            filtered_output.appendSlice(self.allocator, buf[0..@intCast(n)]) catch {};
        }

        const pane_state = self.session_loop.getPane(pane.id);
        if (pane_state) |ps| {
            ps.processPtyOutput(filtered_output.items);
        }

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

        const relay_render_bypass = if (owner_client_idx) |relay_client_idx|
            self.clients.items[relay_client_idx].relay_state == .startup_pending or
                self.clients.items[relay_client_idx].relay_state == .startup_active
        else
            false;

        for (self.clients.items) |client| {
            if (client.session != session) continue;
            if (relay_render_bypass) {
                if (self.findClientIndex(client.fd)) |client_idx| {
                    self.queueClientMessage(client_idx, .output, filtered_output.items);
                } else {
                    protocol.sendMessage(client.fd, .output, filtered_output.items) catch {};
                }
                continue;
            }
            self.renderComposedToClient(client.fd, session, pane_state) catch {
                if (self.findClientIndex(client.fd)) |client_idx| {
                    self.queueClientMessage(client_idx, .output, filtered_output.items);
                } else {
                    protocol.sendMessage(client.fd, .output, filtered_output.items) catch {};
                }
            };
        }

        const end_msg = std.fmt.bufPrint(&detail, "fd={d} bytes={d}", .{ fd, n }) catch "";
        startup_probe.traceEvent("server", "handle_pty_readable_end", end_msg);
        return @intCast(n);
    }

    fn handlePtyReadable(self: *Server, fd: std.c.fd_t) usize {
        const pane_ref = self.findPaneRefByFd(fd) orelse return 0;
        return self.handlePtyReadableRef(pane_ref);
    }

    fn drainPaneReadableRef(self: *Server, pane_ref: PaneRef) void {
        self.flushPendingPaneWrites(pane_ref.pane);
        var count: usize = 0;
        while (count < 32) : (count += 1) {
            if (self.handlePtyReadableRef(pane_ref) == 0) break;
        }
    }

    fn drainPaneReadable(self: *Server, fd: std.c.fd_t) void {
        const pane_ref = self.findPaneRefByFd(fd) orelse return;
        self.drainPaneReadableRef(pane_ref);
    }

    fn drainAllPanes(self: *Server) void {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd >= 0) self.drainPaneReadable(pane.fd);
                }
            }
        }
    }

    fn drainAllClients(self: *Server) void {
        var idx: usize = 0;
        while (idx < self.clients.items.len) : (idx += 1) {
            self.drainClient(idx);
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
        if (self.sessionStartupRelayActive(session)) return error.StartupRelayActive;
        var detail: [160]u8 = undefined;
        const start_msg = std.fmt.bufPrint(&detail, "client_fd={d}", .{client_fd}) catch "";
        startup_probe.traceEvent("server", "render_composed_begin", start_msg);
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
            if (self.findClientIndex(client_fd)) |client_idx| {
                self.queueClientMessage(client_idx, .output, rendered[0..total]);
            } else {
                try protocol.sendMessage(client_fd, .output, rendered[0..total]);
            }
        }
        const end_msg = std.fmt.bufPrint(&detail, "client_fd={d} bytes={d}", .{ client_fd, total }) catch "";
        startup_probe.traceEvent("server", "render_composed_end", end_msg);
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
    /// Called after accepting a client to handle data that arrived before the
    /// next poll iteration.
    fn drainClient(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        const fd = self.clients.items[client_idx].fd;
        var detail: [192]u8 = undefined;
        const start_msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d}", .{ self.clients.items[client_idx].client_id, fd }) catch "";
        startup_probe.traceEvent("server", "drain_client_start", start_msg);

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
                error.WouldBlock => {
                    const msg = std.fmt.bufPrint(&detail, "client_id={d} fd={d} count={d}", .{ self.clients.items[client_idx].client_id, fd, count }) catch "";
                    startup_probe.traceEvent("server", "drain_client_wouldblock", msg);
                    break;
                }, // no more data, normal for non-blocking
                else => break,
            };
        }
    }

    fn removeClient(self: *Server, client_idx: usize) void {
        if (client_idx >= self.clients.items.len) return;
        var client = self.clients.orderedRemove(client_idx);
        self.unregisterReadableFd(client.fd);
        self.updateClientFdOwnersFrom(client_idx);
        if (client.session) |session| {
            if (session.attached > 0) session.attached -= 1;
        }
        client.deinit(self.allocator);
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
        client.prefix_active = false;
        if (client.session) |existing| {
            if (existing.attached > 0) existing.attached -= 1;
        }
        client.session = session;
        client.relay_state = .inactive;
        client.inflight_probe_requests.clearRetainingCapacity();
        client.pending_probe_requests.clearRetainingCapacity();
        client.probe_parse_buffer.clearRetainingCapacity();
        if (session) |current| {
            current.attached += 1;
            self.fireHooks(.client_attached);
        }
    }

    fn scanPaneRefById(self: *Server, pane_id: u32) ?PaneRef {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.id == pane_id) {
                        return .{
                            .session = session,
                            .pane = pane,
                        };
                    }
                }
            }
        }
        return null;
    }

    fn findPaneRefById(self: *Server, pane_id: u32) ?PaneRef {
        if (self.pane_registry.get(pane_id)) |pane_ref| {
            return pane_ref;
        }
        const pane_ref = self.scanPaneRefById(pane_id) orelse return null;
        self.registerPaneRef(pane_ref);
        return pane_ref;
    }

    fn findPaneRefByFd(self: *Server, fd: std.c.fd_t) ?PaneRef {
        if (self.fdOwner(fd)) |owner| switch (owner) {
            .pane => |pane_id| return self.findPaneRefById(pane_id),
            else => {},
        };
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (pane.fd == fd) {
                        const pane_ref: PaneRef = .{
                            .session = session,
                            .pane = pane,
                        };
                        self.registerPaneRef(pane_ref);
                        return pane_ref;
                    }
                }
            }
        }
        return null;
    }

    fn findSessionForPaneFd(self: *Server, fd: std.c.fd_t) ?*Session {
        return if (self.findPaneRefByFd(fd)) |pane_ref| pane_ref.session else null;
    }

    pub fn findPaneByFd(self: *Server, fd: std.c.fd_t) ?*Pane {
        return if (self.findPaneRefByFd(fd)) |pane_ref| pane_ref.pane else null;
    }

    pub fn trackPane(self: *Server, pane: *Pane, cols: u32, rows: u32) !void {
        try self.session_loop.addPane(pane.id, pane.fd, cols, rows);
        errdefer self.session_loop.removePane(pane.id);
        if (self.scanPaneRefById(pane.id)) |pane_ref| {
            self.registerPaneRef(pane_ref);
        }
        if (pane.fd >= 0) {
            try self.registerReadableFd(pane.fd, .{ .pane = pane.id });
            self.drainPaneReadable(pane.fd);
        }
    }

    pub fn untrackPane(self: *Server, pane_id: u32) void {
        if (self.session_loop.getPane(pane_id)) |pane_state| {
            self.unregisterReadableFd(pane_state.pty_fd);
        }
        self.unregisterPaneRef(pane_id);
        self.clearPendingPaneWrites(pane_id);
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

extern "c" fn time(timer: ?*i64) i64;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn sleepMs(ms: u64) void {
    var ts = std.c.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    _ = std.c.nanosleep(&ts, null);
}

fn setFdNonblocking(fd: std.c.fd_t) void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return;
    _ = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true })));
}

fn setNonBlockingForTest(fd: std.c.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    try std.testing.expect(flags >= 0);
    try std.testing.expectEqual(@as(c_int, 0), std.c.fcntl(fd, std.c.F.SETFL, flags | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true }))));
}

fn drainFdForTest(fd: std.c.fd_t) void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n > 0) continue;
        if (n < 0 and std.posix.errno(n) == .AGAIN) break;
        break;
    }
}

fn fillFdForTest(fd: std.c.fd_t) void {
    var buf: [4096]u8 = .{'x'} ** 4096;
    while (pane_mod.writeNonBlocking(fd, &buf) == buf.len) {}
}

test "commandAllowsMissingSession includes if-shell" {
    try std.testing.expect(commandAllowsMissingSession("if-shell"));
    try std.testing.expect(!commandAllowsMissingSession("send-prefix"));
}

test "nextPollTimeoutMs uses idle timeout when no maintenance is pending" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-next-poll-timeout-idle.sock");
    defer server.deinit();

    try std.testing.expectEqual(Server.idle_poll_timeout_ms, server.nextPollTimeoutMs());
}

test "nextPollTimeoutMs retries quickly when client output is pending" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-next-poll-timeout-client-output.sock");
    defer server.deinit();

    try server.clients.append(server.allocator, .{
        .fd = 42,
        .session = null,
        .identified = true,
        .choose_tree_state = null,
    });
    try server.clients.items[0].pending_output.append(server.allocator, 'x');

    try std.testing.expectEqual(Server.pending_write_retry_timeout_ms, server.nextPollTimeoutMs());
}

test "nextPollTimeoutMs retries quickly when pane writes are pending" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-next-poll-timeout-pane-write.sock");
    defer server.deinit();

    try server.pending_pane_writes.put(42, .empty);
    if (server.pending_pane_writes.getPtr(42)) |pending| {
        try pending.append(server.allocator, 'x');
    } else {
        return error.ExpectedPendingPaneWrite;
    }

    try std.testing.expectEqual(Server.pending_write_retry_timeout_ms, server.nextPollTimeoutMs());
}

test "nextPollTimeoutMs returns immediate when status refresh is due" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-next-poll-timeout-status.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;
    session.options.status = true;
    session.options.status_interval = 1;

    var now: i64 = 0;
    _ = time(&now);
    session.status_next_refresh_at = now - 1;

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    try std.testing.expectEqual(@as(c_int, 0), server.nextPollTimeoutMs());
}

test "removeClient reindexes fd registry for remaining clients" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-remove-client-reindex.sock");
    defer server.deinit();

    var pipe_a: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_a));
    defer _ = std.c.close(pipe_a[1]);

    var pipe_b: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_b));
    defer _ = std.c.close(pipe_b[1]);

    try server.registerReadableFd(pipe_a[0], .{ .client = 0 });
    try server.clients.append(server.allocator, .{
        .fd = pipe_a[0],
        .session = null,
        .identified = true,
        .choose_tree_state = null,
    });
    try server.registerReadableFd(pipe_b[0], .{ .client = 1 });
    try server.clients.append(server.allocator, .{
        .fd = pipe_b[0],
        .session = null,
        .identified = true,
        .choose_tree_state = null,
    });

    server.removeClient(0);

    try std.testing.expectEqual(@as(usize, 1), server.clients.items.len);
    try std.testing.expectEqual(@as(?usize, 0), server.findClientIndex(pipe_b[0]));
}

test "trackPane registers pane registry entry and untrackPane clears it" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-pane-registry.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 20, 5);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 20, 4);
    try window.addPane(pane);

    try server.trackPane(pane, pane.sx, pane.sy);
    try std.testing.expect(server.findPaneRefById(pane.id) != null);

    server.untrackPane(pane.id);
    try std.testing.expect(server.pane_registry.get(pane.id) == null);
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
        \\set -g window-status-current-format '#[bold]#I:#W#F'
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
    try std.testing.expectEqualStrings("#[bold]#I:#W#F", server.window_defaults.window_status_current_format);

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

test "renderComposedToClient handles tmux-style conditional branches and quoted shell commands" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-status-conditional-shell.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 96, 5);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 96, 4);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    try session.setStatusLeft("#{?session_name,#[fg=default#,bold#,bg=blue] #S ,#[fg=default#,bg=colour238] #S }");
    try session.setStatusRight("#[fg=colour255,bold#,bg=default]#(if true; then printf \"up\"; else printf \"down\"; fi)");
    session.options.status_style = .{
        .fg = .white,
        .bg = .black,
        .attrs = .{},
    };

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "bg=blue]") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "#(") == null);
    try std.testing.expect(std.mem.indexOf(u8, payload, " demo ") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "up") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\x1b[44m") != null);
}

test "renderComposedToClient uses current window format for the active window" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-render-current-window-format.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "zsh", 64, 5);
    try server.applyWindowDefaults(window);
    try window.setWindowStatusFormat("  #{window_index}  #{window_name} ");
    try window.setWindowStatusCurrentFormat("ACTIVE #{window_index} #{window_name}");
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 64, 4);
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, -1, pane.sx, pane.sy);

    try session.setStatusLeft("");
    try session.setStatusRight("");

    const pane_state = server.session_loop.getPane(pane.id).?;
    const payload = try renderPayloadForTest(&server, session, pane_state);
    defer std.testing.allocator.free(payload);

    try std.testing.expect(std.mem.indexOf(u8, payload, "ACTIVE 0 zsh") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "  0  zsh ") == null);
}

test "handlePtyReadable ignores EAGAIN on nonblocking panes" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-pty-eagain.sock");
    defer server.deinit();

    var pty = try Pty.openPty();
    defer pty.close();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 80, 24);
    try session.addWindow(window);
    const pane = try Pane.init(std.testing.allocator, 80, 24);
    pane.fd = pty.master_fd;
    pty.master_fd = -1;
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, pane.fd, pane.sx, pane.sy);

    try std.testing.expectEqual(@as(usize, 0), server.handlePtyReadable(pane.fd));
    try std.testing.expect(!pane.flags.exited);
}

test "handlePtyReadable deactivates pane fd on EOF" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-pty-eof.sock");
    defer server.deinit();

    var pipe_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_fds));
    defer {
        if (pipe_fds[0] >= 0) _ = std.c.close(pipe_fds[0]);
        if (pipe_fds[1] >= 0) _ = std.c.close(pipe_fds[1]);
    }

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 80, 24);
    try session.addWindow(window);
    const pane = try Pane.init(std.testing.allocator, 80, 24);
    pane.fd = pipe_fds[0];
    pipe_fds[0] = -1;
    try window.addPane(pane);
    try server.session_loop.addPane(pane.id, pane.fd, pane.sx, pane.sy);

    _ = std.c.close(pipe_fds[1]);
    pipe_fds[1] = -1;

    try std.testing.expectEqual(@as(usize, 0), server.handlePtyReadable(pane.fd));
    try std.testing.expect(pane.flags.exited);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), pane.fd);
    try std.testing.expectEqual(@as(std.c.fd_t, -1), server.session_loop.getPane(pane.id).?.pty_fd);
}

test "handleClientKey queues pane input when nonblocking writes back up" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-pane-backpressure.sock");
    defer server.deinit();

    const session = try Session.init(std.testing.allocator, "demo");
    try server.sessions.append(server.allocator, session);
    server.default_session = session;

    const window = try Window.init(std.testing.allocator, "win", 80, 24);
    try session.addWindow(window);

    const pane = try Pane.init(std.testing.allocator, 80, 24);
    try window.addPane(pane);

    var pipe_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_fds));
    defer _ = std.c.close(pipe_fds[0]);
    pane.fd = pipe_fds[1];

    try setNonBlockingForTest(pipe_fds[0]);
    try setNonBlockingForTest(pipe_fds[1]);
    fillFdForTest(pipe_fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    server.handleClientKey(0, "abc");

    const pending = server.pending_pane_writes.getPtr(pane.id) orelse return error.ExpectedPendingWrite;
    try std.testing.expectEqualStrings("abc", pending.items);

    drainFdForTest(pipe_fds[0]);
    server.flushPendingPaneWrites(pane);

    var buf: [8]u8 = undefined;
    const n = std.c.read(pipe_fds[0], &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 3), n);
    try std.testing.expectEqualStrings("abc", buf[0..@intCast(n)]);
    try std.testing.expect(server.pending_pane_writes.getPtr(pane.id) == null);
}

test "handleClientKey keeps prefix state per client" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-client-prefix-isolation.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/bin/sh", 80, 24);
    try session.setDefaultShell("/bin/sh");

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });
    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    server.handleClientKey(0, &.{0x02}); // C-b
    try std.testing.expect(server.clients.items[0].prefix_active);

    server.handleClientKey(1, "c");
    try std.testing.expectEqual(@as(usize, 1), session.windows.items.len);
    try std.testing.expect(server.clients.items[0].prefix_active);
    try std.testing.expect(!server.clients.items[1].prefix_active);

    server.handleClientKey(0, "c");
    try std.testing.expectEqual(@as(usize, 2), session.windows.items.len);
    try std.testing.expect(!server.clients.items[0].prefix_active);
}

test "handleClientKey honors session prefix updates" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-prefix-update.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/bin/sh", 80, 24);
    try session.setDefaultShell("/bin/sh");
    try session.setPrefix("C-a", 0x01);

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    server.handleClientKey(0, &.{0x02}); // Old C-b should pass through.
    server.handleClientKey(0, "c");
    try std.testing.expectEqual(@as(usize, 1), session.windows.items.len);

    server.handleClientKey(0, &.{0x01}); // New C-a prefix.
    server.handleClientKey(0, "c");
    try std.testing.expectEqual(@as(usize, 2), session.windows.items.len);
}

test "createSession drains startup output so pane accepts input" {
    const script_path = "/tmp/zmux-input-accepts-script.sh";
    const proof_path = "/tmp/zmux-create-session-proof";

    const script =
        \\#!/bin/sh
        \\i=0
        \\while [ "$i" -lt 400 ]; do
        \\  printf 'startup-line-%03d................................\n' "$i"
        \\  i=$((i + 1))
        \\done
        \\while IFS= read -r line; do
        \\  eval "$line"
        \\done
        \\
    ;

    var script_buf: [256]u8 = .{0} ** 256;
    @memcpy(script_buf[0..script_path.len], script_path);
    const script_z: [*:0]const u8 = @ptrCast(script_buf[0..script_path.len :0]);
    _ = std.c.unlink(script_z);

    const fd = std.c.open(script_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o755));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    defer _ = std.c.unlink(script_z);
    try std.testing.expectEqual(@as(isize, @intCast(script.len)), std.c.write(fd, script.ptr, script.len));

    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-create-session-input.sock");
    defer server.deinit();

    const session = try server.createSession("demo", script_path, 80, 24);
    const pane = session.active_window.?.active_pane.?;

    sleepMs(250);
    server.drainPaneReadable(pane.fd);

    const command = "touch /tmp/zmux-create-session-proof\r";
    try std.testing.expectEqual(@as(isize, command.len), std.c.write(pane.fd, command.ptr, command.len));

    sleepMs(250);
    server.drainPaneReadable(pane.fd);

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

test "handleClientKey forwards input bytes to interactive shells" {
    const proof_path = "/tmp/zmux-handle-client-key-proof";
    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-handle-client-key.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);
    const pane = session.active_window.?.active_pane.?;

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

    var loops: usize = 0;
    while (loops < 50) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    server.handleClientKey(0, "touch /tmp/zmux-handle-client-key-proof\r");

    loops = 0;
    while (loops < 30) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

test "handleClientKey forwards input bytes even after config load" {
    const cfg_path = "/tmp/zmux-handle-client-key.conf";
    const proof_path = "/tmp/zmux-handle-client-key-config-proof";

    var cfg_buf: [256]u8 = .{0} ** 256;
    @memcpy(cfg_buf[0..cfg_path.len], cfg_path);
    const cfg_z: [*:0]const u8 = @ptrCast(cfg_buf[0..cfg_path.len :0]);
    _ = std.c.unlink(cfg_z);
    defer _ = std.c.unlink(cfg_z);

    const cfg_fd = std.c.open(cfg_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(cfg_fd >= 0);
    defer _ = std.c.close(cfg_fd);
    const cfg = "set -g status-style fg=colour015,bg=colour235\n";
    try std.testing.expectEqual(@as(isize, cfg.len), std.c.write(cfg_fd, cfg.ptr, cfg.len));

    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-handle-client-key-config.sock");
    defer server.deinit();
    try std.testing.expect(server.loadConfigFile(cfg_path));

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);
    const pane = session.active_window.?.active_pane.?;

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

    var loops: usize = 0;
    while (loops < 50) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    server.handleClientKey(0, "touch /tmp/zmux-handle-client-key-config-proof\r");

    loops = 0;
    while (loops < 30) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

test "handleClientReadable forwards protocol key payloads to interactive shells" {
    const proof_path = "/tmp/zmux-handle-client-readable-proof";
    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-handle-client-readable.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);
    const pane = session.active_window.?.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    var loops: usize = 0;
    while (loops < 50) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try protocol.sendMessage(fds[1], .key, "touch /tmp/zmux-handle-client-readable-proof\r");
    try server.handleClientReadable(0);

    loops = 0;
    while (loops < 30) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

test "handleClientReadable forwards protocol key payloads after config load" {
    const cfg_path = "/tmp/zmux-handle-client-readable.conf";
    const proof_path = "/tmp/zmux-handle-client-readable-config-proof";

    var cfg_buf: [256]u8 = .{0} ** 256;
    @memcpy(cfg_buf[0..cfg_path.len], cfg_path);
    const cfg_z: [*:0]const u8 = @ptrCast(cfg_buf[0..cfg_path.len :0]);
    _ = std.c.unlink(cfg_z);
    defer _ = std.c.unlink(cfg_z);

    const cfg_fd = std.c.open(cfg_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(cfg_fd >= 0);
    defer _ = std.c.close(cfg_fd);
    const cfg = "set -g status-style fg=colour015,bg=colour235\n";
    try std.testing.expectEqual(@as(isize, cfg.len), std.c.write(cfg_fd, cfg.ptr, cfg.len));

    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-handle-client-readable-config.sock");
    defer server.deinit();
    try std.testing.expect(server.loadConfigFile(cfg_path));

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);
    const pane = session.active_window.?.active_pane.?;

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
    });

    var loops: usize = 0;
    while (loops < 50) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try protocol.sendMessage(fds[1], .key, "touch /tmp/zmux-handle-client-readable-config-proof\r");
    try server.handleClientReadable(0);

    loops = 0;
    while (loops < 30) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

test "protocol identify then new-session then key input reaches shell" {
    const proof_path = "/tmp/zmux-identify-new-key-proof";
    var proof_buf: [256]u8 = .{0} ** 256;
    @memcpy(proof_buf[0..proof_path.len], proof_path);
    const proof_z: [*:0]const u8 = @ptrCast(proof_buf[0..proof_path.len :0]);
    _ = std.c.unlink(proof_z);
    defer _ = std.c.unlink(proof_z);

    var server = try Server.init(std.testing.allocator, "/tmp/zmux-identify-new-key.sock");
    defer server.deinit();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = null,
        .identified = false,
        .choose_tree_state = null,
    });

    const identify = protocol.IdentifyMsg{
        .protocol_version = protocol.version,
        .pid = std.c.getpid(),
        .flags = .{},
        .term_name = .{0} ** 64,
        .tty_name = .{0} ** 64,
        .cols = 120,
        .rows = 24,
        .xpixel = 0,
        .ypixel = 0,
    };
    try protocol.sendMessage(fds[1], .identify, std.mem.asBytes(&identify));
    try server.handleClientReadable(0);

    try protocol.sendMessage(fds[1], .command, "new-session\x00-s\x00demo\x00");
    try server.handleClientReadable(0);

    const session = server.clients.items[0].session orelse return error.ExpectedSession;
    const pane = session.active_window.?.active_pane.?;

    var loops: usize = 0;
    while (loops < 50) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try protocol.sendMessage(fds[1], .key, "touch /tmp/zmux-identify-new-key-proof\r");
    try server.handleClientReadable(0);

    loops = 0;
    while (loops < 30) : (loops += 1) {
        sleepMs(100);
        server.drainPaneReadable(pane.fd);
    }

    try std.testing.expectEqual(@as(c_int, 0), std.c.access(proof_z, 0));
}

fn monotonicNsForTest() !u64 {
    var ts: std.c.timespec = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts));
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

test "handleClientReadable attaches a new session without fixed startup delay" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-ready-latency.sock");
    defer server.deinit();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = null,
        .identified = false,
        .choose_tree_state = null,
    });

    const identify = protocol.IdentifyMsg{
        .protocol_version = protocol.version,
        .pid = std.c.getpid(),
        .flags = .{},
        .term_name = .{0} ** 64,
        .tty_name = .{0} ** 64,
        .cols = 120,
        .rows = 24,
        .xpixel = 0,
        .ypixel = 0,
    };
    try protocol.sendMessage(fds[1], .identify, std.mem.asBytes(&identify));
    try server.handleClientReadable(0);

    try protocol.sendMessage(fds[1], .command, "new-session\x00-s\x00latency\x00");
    const start_ns = try monotonicNsForTest();
    try server.handleClientReadable(0);
    const elapsed_ns = (try monotonicNsForTest()) - start_ns;

    try std.testing.expect(elapsed_ns < 300 * std.time.ns_per_ms);
    try std.testing.expect(server.clients.items[0].session != null);
}

test "handleClientReadable preserves fragmented nonblocking client frames" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-fragmented-client.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    setFdNonblocking(fds[0]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = null,
        .identified = false,
        .choose_tree_state = null,
    });

    const identify = protocol.IdentifyMsg{
        .protocol_version = protocol.version,
        .pid = std.c.getpid(),
        .flags = .{},
        .term_name = .{0} ** 64,
        .tty_name = .{0} ** 64,
        .cols = 120,
        .rows = 40,
        .xpixel = 0,
        .ypixel = 0,
    };
    const identify_payload = std.mem.asBytes(&identify);
    const identify_header = protocol.serializeHeader(.{
        .msg_type = @intFromEnum(protocol.MessageType.identify),
        .payload_len = identify_payload.len,
        .flags = 0,
    });

    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], identify_header[0..3].ptr, 3));
    try std.testing.expectError(error.WouldBlock, server.handleClientReadable(0));
    try std.testing.expect(!server.clients.items[0].identified);

    try std.testing.expectEqual(@as(isize, @intCast(identify_header.len - 3)), std.c.write(fds[1], identify_header[3..].ptr, identify_header.len - 3));
    try std.testing.expectEqual(@as(isize, 5), std.c.write(fds[1], identify_payload[0..5].ptr, 5));
    try std.testing.expectError(error.WouldBlock, server.handleClientReadable(0));
    try std.testing.expect(!server.clients.items[0].identified);

    try std.testing.expectEqual(@as(isize, @intCast(identify_payload.len - 5)), std.c.write(fds[1], identify_payload[5..].ptr, identify_payload.len - 5));
    try server.handleClientReadable(0);
    try std.testing.expect(server.clients.items[0].identified);
    try std.testing.expectEqual(session, server.clients.items[0].session.?);
    try std.testing.expectEqual(@as(u16, 120), server.clients.items[0].cols);
    try std.testing.expectEqual(@as(u16, 40), server.clients.items[0].rows);

    const command_args = [_][]const u8{"list-sessions"};
    const command_payload = try protocol.encodeCommandArgs(std.testing.allocator, &command_args);
    defer std.testing.allocator.free(command_payload);
    const command_header = protocol.serializeHeader(.{
        .msg_type = @intFromEnum(protocol.MessageType.command),
        .payload_len = @intCast(command_payload.len),
        .flags = 0,
    });

    try std.testing.expectEqual(@as(isize, 2), std.c.write(fds[1], command_header[0..2].ptr, 2));
    try std.testing.expectError(error.WouldBlock, server.handleClientReadable(0));

    try std.testing.expectEqual(@as(isize, @intCast(command_header.len - 2)), std.c.write(fds[1], command_header[2..].ptr, command_header.len - 2));
    try std.testing.expectEqual(@as(isize, 4), std.c.write(fds[1], command_payload[0..4].ptr, 4));
    try std.testing.expectError(error.WouldBlock, server.handleClientReadable(0));

    try std.testing.expectEqual(@as(isize, @intCast(command_payload.len - 4)), std.c.write(fds[1], command_payload[4..].ptr, command_payload.len - 4));
    try server.handleClientReadable(0);

    var output = try protocol.recvMessageAlloc(std.testing.allocator, fds[1]);
    defer output.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, output.msg_type);
    try std.testing.expect(std.mem.indexOf(u8, output.payload, "demo") != null);

    var exit_ack = try protocol.recvMessageAlloc(std.testing.allocator, fds[1]);
    defer exit_ack.deinit();
    try std.testing.expectEqual(protocol.MessageType.exit_ack, exit_ack.msg_type);
    try std.testing.expectEqual(@as(u16, 0), exit_ack.flags);
}

test "startup relay strips probe requests from pane output and queues a correlated request" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-startup-probe-filter.sock");
    defer server.deinit();

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = null,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 44,
        .relay_state = .startup_active,
    });

    var output: std.ArrayListAligned(u8, null) = .empty;
    defer output.deinit(std.testing.allocator);

    server.filterStartupProbeOutput(0, "hello\x1b]10;?\x1b\\world", &output);

    try std.testing.expectEqualStrings("helloworld", output.items);
    try std.testing.expectEqual(@as(usize, 1), server.clients.items[0].pending_probe_requests.items.len);
    try std.testing.expectEqual(startup_probe.ProbeKind.osc_10, server.clients.items[0].pending_probe_requests.items[0].kind);
    try std.testing.expectEqual(@as(u32, 1), server.clients.items[0].pending_probe_requests.items[0].request_id);
}

test "handleClientReadable preserves fragmented terminal_probe_ready frames and dispatches queued probes" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-fragmented-probe-ready.sock");
    defer server.deinit();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    setFdNonblocking(fds[0]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = null,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 99,
        .relay_state = .startup_pending,
        .pending_probe_requests = .empty,
    });
    try server.clients.items[0].pending_probe_requests.append(server.allocator, .{
        .request_id = 3,
        .kind = .osc_11,
    });

    const header = protocol.serializeHeader(.{
        .msg_type = @intFromEnum(protocol.MessageType.terminal_probe_ready),
        .payload_len = 0,
        .flags = 0,
    });

    try std.testing.expectEqual(@as(isize, 3), std.c.write(fds[1], header[0..3].ptr, 3));
    try std.testing.expectError(error.WouldBlock, server.handleClientReadable(0));
    try std.testing.expectEqual(Server.ClientConnection.RelayState.startup_pending, server.clients.items[0].relay_state);

    try std.testing.expectEqual(@as(isize, @intCast(header.len - 3)), std.c.write(fds[1], header[3..].ptr, header.len - 3));
    try server.handleClientReadable(0);
    try std.testing.expectEqual(Server.ClientConnection.RelayState.startup_active, server.clients.items[0].relay_state);

    var msg = try protocol.recvMessageAlloc(std.testing.allocator, fds[1]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.terminal_probe_req, msg.msg_type);
    const view = try protocol.decodeTerminalProbeReq(msg.payload);
    try std.testing.expectEqual(@as(u32, 3), view.request_id);
    try std.testing.expectEqual(@as(u64, 99), view.owner_client_id);
    try std.testing.expectEqual(startup_probe.ProbeKind.osc_11, view.probe_kind);
}

test "startup relay dispatch stays owned by the attaching client when viewers share the session" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-probe-owner.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);

    var owner_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &owner_fds));
    defer _ = std.c.close(owner_fds[0]);
    defer _ = std.c.close(owner_fds[1]);

    var viewer_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &viewer_fds));
    defer _ = std.c.close(viewer_fds[0]);
    defer _ = std.c.close(viewer_fds[1]);

    setFdNonblocking(viewer_fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = viewer_fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 301,
        .relay_state = .inactive,
    });
    try server.clients.append(server.allocator, .{
        .fd = owner_fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 302,
        .relay_state = .startup_pending,
        .pending_probe_requests = .empty,
    });
    try server.clients.items[1].pending_probe_requests.append(server.allocator, .{
        .request_id = 8,
        .kind = .osc_12,
    });

    server.handleTerminalProbeReady(1);
    try std.testing.expectEqual(Server.ClientConnection.RelayState.startup_active, server.clients.items[1].relay_state);
    try std.testing.expectEqual(Server.ClientConnection.RelayState.inactive, server.clients.items[0].relay_state);

    var owner_msg = try protocol.recvMessageAlloc(std.testing.allocator, owner_fds[1]);
    defer owner_msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.terminal_probe_req, owner_msg.msg_type);
    const owner_view = try protocol.decodeTerminalProbeReq(owner_msg.payload);
    try std.testing.expectEqual(@as(u64, 302), owner_view.owner_client_id);
    try std.testing.expectEqual(startup_probe.ProbeKind.osc_12, owner_view.probe_kind);

    var scratch: [32]u8 = undefined;
    const rc = std.c.read(viewer_fds[1], &scratch, scratch.len);
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(rc));
}

test "startup relay ignores mismatched terminal probe responses" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-probe-mismatch.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 401,
        .relay_state = .startup_active,
        .inflight_probe_requests = .empty,
    });
    try server.clients.items[0].inflight_probe_requests.append(server.allocator, .{
        .request_id = 9,
        .kind = .osc_10,
    });

    const payload = try protocol.encodeTerminalProbeRsp(std.testing.allocator, 99, .complete, "\x1b]10;rgb:0000/0000/0000\x1b\\");
    defer std.testing.allocator.free(payload);

    try server.handleTerminalProbeRsp(0, payload);

    try std.testing.expectEqual(@as(usize, 1), server.clients.items[0].inflight_probe_requests.items.len);
    try std.testing.expectEqual(@as(u32, 9), server.clients.items[0].inflight_probe_requests.items[0].request_id);
}

test "startup relay does not dispatch probes before terminal_probe_ready" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-probe-pre-ready.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);
    setFdNonblocking(fds[1]);

    try server.clients.append(server.allocator, .{
        .fd = fds[0],
        .session = session,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 403,
        .relay_state = .startup_pending,
        .pending_probe_requests = .empty,
    });
    try server.clients.items[0].pending_probe_requests.append(server.allocator, .{
        .request_id = 12,
        .kind = .csi_primary_da,
    });

    server.dispatchNextStartupProbe(0);

    try std.testing.expectEqual(@as(usize, 0), server.clients.items[0].inflight_probe_requests.items.len);
    var scratch: [32]u8 = undefined;
    const rc = std.c.read(fds[1], &scratch, scratch.len);
    try std.testing.expect(rc < 0);
    try std.testing.expectEqual(std.posix.E.AGAIN, std.posix.errno(rc));
}

test "startup relay expires to relay_done after quiescence with no inflight probes" {
    var server = try Server.init(std.testing.allocator, "/tmp/zmux-probe-quiescence.sock");
    defer server.deinit();

    const session = try server.createSession("demo", "/opt/homebrew/bin/zsh", 80, 24);
    const now = try monotonicNsForTest();

    try server.clients.append(server.allocator, .{
        .fd = -1,
        .session = session,
        .identified = true,
        .choose_tree_state = null,
        .client_id = 402,
        .relay_state = .startup_active,
        .relay_started_at_ns = now - 500 * std.time.ns_per_ms,
        .relay_last_probe_ns = now - 250 * std.time.ns_per_ms,
    });

    server.maybeExpireStartupRelay(0);

    try std.testing.expectEqual(Server.ClientConnection.RelayState.relay_done, server.clients.items[0].relay_state);
}
