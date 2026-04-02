const std = @import("std");
const builtin = @import("builtin");
const event_loop = @import("../core/event_loop.zig");

/// io_uring-based event loop for Linux.
pub const IoUringEventLoop = if (builtin.os.tag == .linux) struct {
    ring: std.os.linux.IoUring,
    callbacks: std.AutoHashMap(i32, event_loop.Callback),
    timer_callbacks: std.AutoHashMap(u64, event_loop.TimerCallback),
    next_timer_id: u64,
    running: bool,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) !IoUringEventLoop {
        return .{
            .ring = try std.os.linux.IoUring.init(256, 0),
            .callbacks = std.AutoHashMap(i32, event_loop.Callback).init(alloc),
            .timer_callbacks = std.AutoHashMap(u64, event_loop.TimerCallback).init(alloc),
            .next_timer_id = 1,
            .running = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *IoUringEventLoop) void {
        self.ring.deinit();
        self.callbacks.deinit();
        self.timer_callbacks.deinit();
    }

    pub fn addFd(self: *IoUringEventLoop, fd: std.posix.fd_t, ev: event_loop.EventType, cb: event_loop.Callback) !void {
        try self.callbacks.put(fd, cb);
        // Submit poll_add SQE
        const poll_mask: u32 = switch (ev) {
            .read => 0x001, // POLLIN
            .write => 0x004, // POLLOUT
            .read_write => 0x001 | 0x004,
        };
        _ = self.ring.poll_add(@intCast(fd), poll_mask, @intCast(fd)) catch {};
        _ = self.ring.submit() catch {};
    }

    pub fn removeFd(self: *IoUringEventLoop, fd: std.posix.fd_t) void {
        _ = self.callbacks.remove(fd);
    }

    pub fn addTimer(self: *IoUringEventLoop, timeout_ms: u64, _: bool, cb: event_loop.TimerCallback) !event_loop.TimerHandle {
        const id = self.next_timer_id;
        self.next_timer_id += 1;
        try self.timer_callbacks.put(id, cb);
        // Submit timeout SQE
        const ts = std.os.linux.kernel_timespec{
            .sec = @intCast(timeout_ms / 1000),
            .nsec = @intCast((timeout_ms % 1000) * 1_000_000),
        };
        _ = self.ring.timeout(&ts, 0, 0) catch {};
        _ = self.ring.submit() catch {};
        return .{ .id = id };
    }

    pub fn removeTimer(self: *IoUringEventLoop, handle: event_loop.TimerHandle) void {
        _ = self.timer_callbacks.remove(handle.id);
    }

    pub fn run(self: *IoUringEventLoop) !void {
        self.running = true;
        while (self.running) {
            var cqe = self.ring.copy_cqe() catch continue;
            const user_data = cqe.user_data;
            self.ring.cqe_seen(&cqe);

            // Dispatch based on user_data (fd for poll events)
            if (self.callbacks.get(@intCast(user_data))) |cb| {
                cb.invoke(@intCast(user_data), .read);
                // Re-arm poll
                _ = self.ring.poll_add(@intCast(user_data), 0x001, user_data) catch {};
                _ = self.ring.submit() catch {};
            }
        }
    }

    pub fn stop(self: *IoUringEventLoop) void {
        self.running = false;
    }

    /// Return as EventLoop interface.
    pub fn asEventLoop(self: *IoUringEventLoop) event_loop.EventLoop {
        _ = self;
        // TODO: implement VTable wrapper
        return undefined;
    }
} else struct {
    // Stub for non-Linux platforms
    pub fn init(_: std.mem.Allocator) !@This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
};
