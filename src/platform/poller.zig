const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const Poller = struct {
    pub const max_fds: usize = 256;

    impl: Impl,

    const Impl = switch (builtin.os.tag) {
        .macos => KqueuePoller,
        .linux => EpollPoller,
        else => PollPoller,
    };

    pub fn init(allocator: std.mem.Allocator) !Poller {
        return .{ .impl = try Impl.init(allocator) };
    }

    pub fn deinit(self: *Poller) void {
        self.impl.deinit();
    }

    pub fn add(self: *Poller, fd: posix.fd_t) !void {
        if (fd < 0) return;
        return self.impl.add(fd);
    }

    pub fn remove(self: *Poller, fd: posix.fd_t) void {
        if (fd < 0) return;
        self.impl.remove(fd);
    }

    pub fn wait(self: *Poller, timeout_ms: c_int, ready_fds: []posix.fd_t) ![]posix.fd_t {
        return self.impl.wait(timeout_ms, ready_fds);
    }
};

const PollPoller = struct {
    allocator: std.mem.Allocator,
    fds: std.ArrayListAligned(posix.fd_t, null) = .empty,

    fn init(allocator: std.mem.Allocator) !PollPoller {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *PollPoller) void {
        self.fds.deinit(self.allocator);
    }

    fn add(self: *PollPoller, fd: posix.fd_t) !void {
        if (containsFd(self.fds.items, fd)) return;
        if (self.fds.items.len >= Poller.max_fds) return error.TooManyFds;
        try self.fds.append(self.allocator, fd);
    }

    fn remove(self: *PollPoller, fd: posix.fd_t) void {
        removeFd(&self.fds, fd);
    }

    fn wait(self: *PollPoller, timeout_ms: c_int, ready_fds: []posix.fd_t) ![]posix.fd_t {
        var pollfds: [Poller.max_fds]std.c.pollfd = undefined;
        var nfds: usize = 0;
        for (self.fds.items) |fd| {
            if (nfds >= pollfds.len) break;
            pollfds[nfds] = .{ .fd = fd, .events = poll_events, .revents = 0 };
            nfds += 1;
        }

        const rc = std.c.poll(pollfds[0..nfds].ptr, @intCast(nfds), timeout_ms);
        if (rc < 0) switch (posix.errno(rc)) {
            .INTR => return ready_fds[0..0],
            else => return error.WaitFailed,
        };
        if (rc == 0) return ready_fds[0..0];

        var ready_len: usize = 0;
        for (pollfds[0..nfds]) |pfd| {
            if (pfd.revents & ready_events_mask == 0) continue;
            ready_fds[ready_len] = pfd.fd;
            ready_len += 1;
            if (ready_len >= ready_fds.len) break;
        }
        return ready_fds[0..ready_len];
    }
};

const KqueuePoller = if (builtin.os.tag == .macos) struct {
    allocator: std.mem.Allocator,
    kq_fd: posix.fd_t,
    fds: std.ArrayListAligned(posix.fd_t, null) = .empty,

    fn init(allocator: std.mem.Allocator) !KqueuePoller {
        const kq_fd = std.c.kqueue();
        if (kq_fd < 0) return error.CreateFailed;
        return .{
            .allocator = allocator,
            .kq_fd = kq_fd,
        };
    }

    fn deinit(self: *KqueuePoller) void {
        self.fds.deinit(self.allocator);
        _ = std.c.close(self.kq_fd);
    }

    fn add(self: *KqueuePoller, fd: posix.fd_t) !void {
        if (containsFd(self.fds.items, fd)) return;
        if (self.fds.items.len >= Poller.max_fds) return error.TooManyFds;

        var change = makeReadChange(fd, std.c.EV.ADD | std.c.EV.ENABLE);
        var ignored: [1]std.c.Kevent = undefined;
        const rc = std.c.kevent(
            self.kq_fd,
            @ptrCast(&change),
            1,
            @ptrCast(&ignored),
            0,
            null,
        );
        if (rc < 0) return error.RegisterFailed;

        try self.fds.append(self.allocator, fd);
    }

    fn remove(self: *KqueuePoller, fd: posix.fd_t) void {
        if (!containsFd(self.fds.items, fd)) return;

        var change = makeReadChange(fd, std.c.EV.DELETE);
        var ignored: [1]std.c.Kevent = undefined;
        _ = std.c.kevent(
            self.kq_fd,
            @ptrCast(&change),
            1,
            @ptrCast(&ignored),
            0,
            null,
        );
        removeFd(&self.fds, fd);
    }

    fn wait(self: *KqueuePoller, timeout_ms: c_int, ready_fds: []posix.fd_t) ![]posix.fd_t {
        var events: [Poller.max_fds]std.c.Kevent = undefined;
        var ignored_changes: [1]std.c.Kevent = undefined;
        var timeout: std.c.timespec = .{
            .sec = @intCast(@divTrunc(timeout_ms, 1000)),
            .nsec = @intCast(@mod(timeout_ms, 1000) * std.time.ns_per_ms),
        };
        const timeout_ptr = if (timeout_ms < 0) null else &timeout;

        const rc = std.c.kevent(
            self.kq_fd,
            @ptrCast(&ignored_changes),
            0,
            @ptrCast(&events),
            @intCast(@min(events.len, ready_fds.len)),
            timeout_ptr,
        );
        if (rc < 0) switch (posix.errno(rc)) {
            .INTR => return ready_fds[0..0],
            else => return error.WaitFailed,
        };

        const ready_len: usize = @intCast(rc);
        for (events[0..ready_len], 0..) |event, idx| {
            ready_fds[idx] = @intCast(event.ident);
        }
        return ready_fds[0..ready_len];
    }

    fn makeReadChange(fd: posix.fd_t, flags: u16) std.c.Kevent {
        return .{
            .ident = @intCast(fd),
            .filter = std.c.EVFILT.READ,
            .flags = flags,
            .fflags = 0,
            .data = 0,
            .udata = 0,
        };
    }
} else struct {
    fn init(_: std.mem.Allocator) !@This() {
        unreachable;
    }
    fn deinit(_: *@This()) void {
        unreachable;
    }
    fn add(_: *@This(), _: posix.fd_t) !void {
        unreachable;
    }
    fn remove(_: *@This(), _: posix.fd_t) void {
        unreachable;
    }
    fn wait(_: *@This(), _: c_int, _: []posix.fd_t) ![]posix.fd_t {
        unreachable;
    }
};

const EpollPoller = if (builtin.os.tag == .linux) struct {
    allocator: std.mem.Allocator,
    epoll_fd: posix.fd_t,
    fds: std.ArrayListAligned(posix.fd_t, null) = .empty,

    const linux = std.os.linux;

    fn init(allocator: std.mem.Allocator) !EpollPoller {
        const epoll_fd = std.c.epoll_create1(linux.EPOLL.CLOEXEC);
        if (epoll_fd < 0) return error.CreateFailed;
        return .{
            .allocator = allocator,
            .epoll_fd = epoll_fd,
        };
    }

    fn deinit(self: *EpollPoller) void {
        self.fds.deinit(self.allocator);
        _ = std.c.close(self.epoll_fd);
    }

    fn add(self: *EpollPoller, fd: posix.fd_t) !void {
        if (containsFd(self.fds.items, fd)) return;
        if (self.fds.items.len >= Poller.max_fds) return error.TooManyFds;

        var event = std.c.epoll_event{
            .events = linux.EPOLL.IN | linux.EPOLL.ERR | linux.EPOLL.HUP | linux.EPOLL.RDHUP,
            .data = .{ .fd = fd },
        };
        if (std.c.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &event) != 0) {
            return error.RegisterFailed;
        }

        try self.fds.append(self.allocator, fd);
    }

    fn remove(self: *EpollPoller, fd: posix.fd_t) void {
        if (!containsFd(self.fds.items, fd)) return;
        _ = std.c.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null);
        removeFd(&self.fds, fd);
    }

    fn wait(self: *EpollPoller, timeout_ms: c_int, ready_fds: []posix.fd_t) ![]posix.fd_t {
        var events: [Poller.max_fds]std.c.epoll_event = undefined;
        const rc = std.c.epoll_wait(
            self.epoll_fd,
            (&events)[0..].ptr,
            @intCast(@min(events.len, ready_fds.len)),
            timeout_ms,
        );
        if (rc < 0) switch (posix.errno(rc)) {
            .INTR => return ready_fds[0..0],
            else => return error.WaitFailed,
        };

        const ready_len: usize = @intCast(rc);
        for (events[0..ready_len], 0..) |event, idx| {
            ready_fds[idx] = event.data.fd;
        }
        return ready_fds[0..ready_len];
    }
} else struct {
    fn init(_: std.mem.Allocator) !@This() {
        unreachable;
    }
    fn deinit(_: *@This()) void {
        unreachable;
    }
    fn add(_: *@This(), _: posix.fd_t) !void {
        unreachable;
    }
    fn remove(_: *@This(), _: posix.fd_t) void {
        unreachable;
    }
    fn wait(_: *@This(), _: c_int, _: []posix.fd_t) ![]posix.fd_t {
        unreachable;
    }
};

fn containsFd(fds: []const posix.fd_t, fd: posix.fd_t) bool {
    for (fds) |item| {
        if (item == fd) return true;
    }
    return false;
}

fn removeFd(fds: *std.ArrayListAligned(posix.fd_t, null), fd: posix.fd_t) void {
    for (fds.items, 0..) |item, idx| {
        if (item == fd) {
            _ = fds.swapRemove(idx);
            return;
        }
    }
}

const poll_events: i16 = 0x0001;
const ready_events_mask: i16 = 0x0001 | 0x0008 | 0x0010 | 0x0020;

test "poller reports readable pipe fd" {
    var poller = try Poller.init(std.testing.allocator);
    defer poller.deinit();

    var pipe_fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe_fds));
    defer _ = std.c.close(pipe_fds[0]);
    defer _ = std.c.close(pipe_fds[1]);

    try poller.add(pipe_fds[0]);

    const payload = "x";
    try std.testing.expectEqual(@as(isize, payload.len), std.c.write(pipe_fds[1], payload.ptr, payload.len));

    var ready: [Poller.max_fds]posix.fd_t = undefined;
    const ready_fds = try poller.wait(100, &ready);
    try std.testing.expect(ready_fds.len >= 1);
    try std.testing.expectEqual(pipe_fds[0], ready_fds[0]);
}
