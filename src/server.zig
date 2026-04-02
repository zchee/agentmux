const std = @import("std");
const builtin = @import("builtin");
const Session = @import("session.zig").Session;
const Window = @import("window.zig").Window;
const Pane = @import("window.zig").Pane;
const Pty = @import("pane.zig").Pty;
const protocol = @import("protocol.zig");
const log = @import("core/log.zig");
const platform = @import("platform/platform.zig");

/// Server state.
pub const Server = struct {
    listen_fd: std.c.fd_t,
    socket_path: []const u8,
    sessions: std.ArrayListAligned(*Session, null),
    clients: std.ArrayListAligned(ClientConnection, null),
    running: bool,
    allocator: std.mem.Allocator,

    pub const ClientConnection = struct {
        fd: std.c.fd_t,
        session: ?*Session,
        identified: bool,
    };

    pub fn init(alloc: std.mem.Allocator, socket_path: []const u8) !Server {
        return .{
            .listen_fd = -1,
            .socket_path = try alloc.dupe(u8, socket_path),
            .sessions = .empty,
            .clients = .empty,
            .running = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
        for (self.sessions.items) |s| {
            s.deinit();
        }
        self.sessions.deinit(self.allocator);
        for (self.clients.items) |c| {
            if (c.fd >= 0) _ = std.c.close(c.fd);
        }
        self.clients.deinit(self.allocator);
        self.allocator.free(self.socket_path);
    }

    /// Start listening on the Unix socket.
    pub fn listen(self: *Server) !void {
        // Ensure socket directory exists
        self.ensureSocketDir() catch |err| {
            log.err("failed to create socket directory: {}", .{err});
            return err;
        };

        // Remove stale socket
        self.removeStaleSocket();

        // Create socket
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) {
            log.err("failed to create socket", .{});
            return error.SocketFailed;
        }
        self.listen_fd = fd;

        // Bind
        var addr: std.c.sockaddr.un = .{ .path = undefined };
        if (self.socket_path.len >= addr.path.len) return error.PathTooLong;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..self.socket_path.len], self.socket_path);

        const bind_result = std.c.bind(fd, @ptrCast(&addr), @sizeOf(std.c.sockaddr.un));
        if (bind_result != 0) {
            log.err("failed to bind socket: {s}", .{self.socket_path});
            return error.BindFailed;
        }

        // Listen
        if (std.c.listen(fd, 128) != 0) {
            return error.ListenFailed;
        }

        // Set permissions (owner only)
        var path_buf: [256]u8 = .{0} ** 256;
        @memcpy(path_buf[0..self.socket_path.len], self.socket_path);
        _ = std.c.chmod(@ptrCast(path_buf[0..self.socket_path.len :0]), 0o700);

        log.info("server listening on {s}", .{self.socket_path});
        self.running = true;
    }

    /// Create a new session with a default window.
    pub fn createSession(self: *Server, name: []const u8, shell: [:0]const u8, cols: u32, rows: u32) !*Session {
        const session = try Session.init(self.allocator, name);
        errdefer session.deinit();

        // Create default window
        const window = try Window.init(self.allocator, name, cols, rows);
        errdefer window.deinit();

        // Create pane with PTY
        const pane = try Pane.init(self.allocator, cols, rows);
        errdefer pane.deinit();

        // Open PTY and fork shell
        var pty = try Pty.openPty();
        try pty.forkExec(shell, null);
        pty.resize(@intCast(cols), @intCast(rows));

        pane.fd = pty.master_fd;
        pane.pid = pty.pid;

        try window.addPane(pane);
        try session.addWindow(window);
        try self.sessions.append(self.allocator, session);

        log.info("created session '{s}' with shell {s}", .{ name, shell });
        return session;
    }

    /// Accept a new client connection.
    pub fn acceptClient(self: *Server) !void {
        const client_fd = std.c.accept(self.listen_fd, null, null);
        if (client_fd < 0) return;

        try self.clients.append(self.allocator, .{
            .fd = client_fd,
            .session = null,
            .identified = false,
        });
        log.info("accepted client fd={d}", .{client_fd});
    }

    /// Main server poll loop (simplified using poll).
    pub fn run(self: *Server) !void {
        const max_fds = 256;
        var pollfds: [max_fds]PollFd = undefined;

        while (self.running) {
            var nfds: usize = 0;

            // Add listen socket
            pollfds[nfds] = .{
                .fd = self.listen_fd,
                .events = POLLIN,
                .revents = 0,
            };
            nfds += 1;

            // Add client fds
            for (self.clients.items) |client| {
                if (nfds >= max_fds) break;
                pollfds[nfds] = .{
                    .fd = client.fd,
                    .events = POLLIN,
                    .revents = 0,
                };
                nfds += 1;
            }

            // Add PTY master fds from all sessions
            for (self.sessions.items) |session| {
                for (session.windows.items) |window| {
                    for (window.panes.items) |pane| {
                        if (nfds >= max_fds) break;
                        if (pane.fd >= 0) {
                            pollfds[nfds] = .{
                                .fd = pane.fd,
                                .events = POLLIN,
                                .revents = 0,
                            };
                            nfds += 1;
                        }
                    }
                }
            }

            // Poll with 100ms timeout
            const result = std.c.poll(&pollfds, @intCast(nfds), 100);
            if (result < 0) continue;
            if (result == 0) continue;

            // Check listen socket
            if (pollfds[0].revents & POLLIN != 0) {
                self.acceptClient() catch {};
            }

            // Check client fds and PTY fds
            var i: usize = 1;
            while (i < nfds) : (i += 1) {
                if (pollfds[i].revents & POLLIN != 0) {
                    // Read data and process
                    var buf: [4096]u8 = undefined;
                    const n = std.c.read(pollfds[i].fd, &buf, buf.len);
                    if (n <= 0) {
                        // EOF or error - handle disconnect
                        continue;
                    }
                    // TODO: Route data to appropriate handler
                    // (client message or PTY output)
                }
            }
        }
    }

    /// Stop the server.
    pub fn stop(self: *Server) void {
        self.running = false;
        if (self.listen_fd >= 0) {
            _ = std.c.close(self.listen_fd);
            self.listen_fd = -1;
        }
        // Remove socket file
        var path_buf: [256]u8 = .{0} ** 256;
        if (self.socket_path.len < path_buf.len) {
            @memcpy(path_buf[0..self.socket_path.len], self.socket_path);
            _ = std.c.unlink(@ptrCast(path_buf[0..self.socket_path.len :0]));
        }
    }

    /// Find a session by name.
    pub fn findSession(self: *const Server, name: []const u8) ?*Session {
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn ensureSocketDir(self: *Server) !void {
        // Extract directory from socket path
        if (std.mem.lastIndexOfScalar(u8, self.socket_path, '/')) |sep| {
            const dir = self.socket_path[0..sep];
            var dir_buf: [256]u8 = .{0} ** 256;
            if (dir.len < dir_buf.len) {
                @memcpy(dir_buf[0..dir.len], dir);
                _ = std.c.mkdir(@ptrCast(dir_buf[0..dir.len :0]), 0o700);
                // Ignore EEXIST
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

// Poll constants
const POLLIN: i16 = 0x0001;
const PollFd = extern struct {
    fd: std.c.fd_t,
    events: i16,
    revents: i16,
};
