const std = @import("std");
const posix = std.posix;

/// File descriptor event types.
pub const EventType = enum {
    read,
    write,
    read_write,
};

/// Callback context for I/O events.
pub const Callback = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque, fd: posix.fd_t, event: EventType) void,

    pub fn invoke(self: Callback, fd: posix.fd_t, event: EventType) void {
        self.func(self.context, fd, event);
    }
};

/// Timer callback.
pub const TimerCallback = struct {
    context: *anyopaque,
    func: *const fn (context: *anyopaque) void,

    pub fn invoke(self: TimerCallback) void {
        self.func(self.context);
    }
};

/// Timer handle returned by addTimer.
pub const TimerHandle = struct {
    id: u64,
};

/// Platform-agnostic event loop interface.
/// Concrete implementations live in platform/darwin.zig (GCD)
/// and platform/linux.zig (io_uring).
pub const EventLoop = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        addFd: *const fn (ptr: *anyopaque, fd: posix.fd_t, event: EventType, cb: Callback) anyerror!void,
        removeFd: *const fn (ptr: *anyopaque, fd: posix.fd_t) void,
        addTimer: *const fn (ptr: *anyopaque, timeout_ms: u64, repeat: bool, cb: TimerCallback) anyerror!TimerHandle,
        removeTimer: *const fn (ptr: *anyopaque, handle: TimerHandle) void,
        run: *const fn (ptr: *anyopaque) anyerror!void,
        stop: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    /// Register a file descriptor for event monitoring.
    pub fn addFd(self: EventLoop, fd: posix.fd_t, event: EventType, cb: Callback) !void {
        return self.vtable.addFd(self.ptr, fd, event, cb);
    }

    /// Remove a file descriptor from monitoring.
    pub fn removeFd(self: EventLoop, fd: posix.fd_t) void {
        self.vtable.removeFd(self.ptr, fd);
    }

    /// Add a timer.
    pub fn addTimer(self: EventLoop, timeout_ms: u64, repeat: bool, cb: TimerCallback) !TimerHandle {
        return self.vtable.addTimer(self.ptr, timeout_ms, repeat, cb);
    }

    /// Remove a timer.
    pub fn removeTimer(self: EventLoop, handle: TimerHandle) void {
        self.vtable.removeTimer(self.ptr, handle);
    }

    /// Run the event loop (blocks until stop is called).
    pub fn run(self: EventLoop) !void {
        return self.vtable.run(self.ptr);
    }

    /// Signal the event loop to stop.
    pub fn stop(self: EventLoop) void {
        self.vtable.stop(self.ptr);
    }

    /// Clean up resources.
    pub fn deinit(self: EventLoop) void {
        self.vtable.deinit(self.ptr);
    }
};
