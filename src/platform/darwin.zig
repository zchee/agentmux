const std = @import("std");
const builtin = @import("builtin");
const event_loop = @import("../core/event_loop.zig");

/// GCD-based event loop for macOS.
pub const GcdEventLoop = if (builtin.os.tag == .macos) struct {
    // libdispatch types (opaque pointers)
    const dispatch_queue_t = ?*anyopaque;
    const dispatch_source_t = ?*anyopaque;
    const dispatch_object_t = ?*anyopaque;
    const dispatch_function_t = *const fn (?*anyopaque) callconv(.C) void;
    const dispatch_time_t = u64;

    const DISPATCH_SOURCE_TYPE_READ: ?*anyopaque = gcd.dispatch_source_type_read;
    const DISPATCH_SOURCE_TYPE_WRITE: ?*anyopaque = gcd.dispatch_source_type_write;
    const DISPATCH_SOURCE_TYPE_TIMER: ?*anyopaque = gcd.dispatch_source_type_timer;
    const DISPATCH_TIME_NOW: dispatch_time_t = 0;

    const gcd = struct {
        extern "c" fn dispatch_queue_create(label: ?[*:0]const u8, attr: ?*anyopaque) dispatch_queue_t;
        extern "c" fn dispatch_source_create(source_type: ?*anyopaque, handle: usize, mask: usize, queue: dispatch_queue_t) dispatch_source_t;
        extern "c" fn dispatch_source_set_event_handler_f(source: dispatch_source_t, handler: dispatch_function_t) void;
        extern "c" fn dispatch_source_set_cancel_handler_f(source: dispatch_source_t, handler: ?dispatch_function_t) void;
        extern "c" fn dispatch_set_context(obj: dispatch_object_t, context: ?*anyopaque) void;
        extern "c" fn dispatch_resume(obj: dispatch_object_t) void;
        extern "c" fn dispatch_suspend(obj: dispatch_object_t) void;
        extern "c" fn dispatch_source_cancel(source: dispatch_source_t) void;
        extern "c" fn dispatch_release(obj: dispatch_object_t) void;
        extern "c" fn dispatch_main() noreturn;
        extern "c" fn dispatch_get_main_queue() dispatch_queue_t;
        extern "c" fn dispatch_source_set_timer(source: dispatch_source_t, start: dispatch_time_t, interval: u64, leeway: u64) void;
        extern "c" fn dispatch_time(when: dispatch_time_t, delta: i64) dispatch_time_t;
        extern "c" var dispatch_source_type_read: ?*anyopaque;
        extern "c" var dispatch_source_type_write: ?*anyopaque;
        extern "c" var dispatch_source_type_timer: ?*anyopaque;
    };

    queue: dispatch_queue_t,
    fd_sources: std.AutoHashMap(i32, FdSource),
    timer_sources: std.AutoHashMap(u64, TimerSource),
    next_timer_id: u64,
    running: bool,
    allocator: std.mem.Allocator,

    const FdSource = struct {
        source: dispatch_source_t,
        callback: event_loop.Callback,
    };

    const TimerSource = struct {
        source: dispatch_source_t,
        callback: event_loop.TimerCallback,
    };

    pub fn init(alloc: std.mem.Allocator) GcdEventLoop {
        return .{
            .queue = gcd.dispatch_queue_create("com.zmux.eventloop", null),
            .fd_sources = std.AutoHashMap(i32, FdSource).init(alloc),
            .timer_sources = std.AutoHashMap(u64, TimerSource).init(alloc),
            .next_timer_id = 1,
            .running = false,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *GcdEventLoop) void {
        // Cancel all sources
        var fd_iter = self.fd_sources.iterator();
        while (fd_iter.next()) |entry| {
            if (entry.value_ptr.source) |s| {
                gcd.dispatch_source_cancel(s);
                gcd.dispatch_release(s);
            }
        }
        var timer_iter = self.timer_sources.iterator();
        while (timer_iter.next()) |entry| {
            if (entry.value_ptr.source) |s| {
                gcd.dispatch_source_cancel(s);
                gcd.dispatch_release(s);
            }
        }
        self.fd_sources.deinit();
        self.timer_sources.deinit();
        if (self.queue) |q| gcd.dispatch_release(q);
    }

    pub fn addFd(self: *GcdEventLoop, fd: std.posix.fd_t, event_type: event_loop.EventType, cb: event_loop.Callback) !void {
        const source_type: ?*anyopaque = switch (event_type) {
            .read => DISPATCH_SOURCE_TYPE_READ,
            .write => DISPATCH_SOURCE_TYPE_WRITE,
            .read_write => DISPATCH_SOURCE_TYPE_READ, // TODO: create two sources
        };
        const source = gcd.dispatch_source_create(source_type, @intCast(fd), 0, self.queue);
        if (source == null) return error.SourceCreateFailed;

        // Store callback context
        const entry = FdSource{ .source = source, .callback = cb };
        try self.fd_sources.put(fd, entry);

        gcd.dispatch_source_set_event_handler_f(source, &fdEventHandler);
        gcd.dispatch_set_context(source, cb.context);
        gcd.dispatch_resume(source);
    }

    pub fn removeFd(self: *GcdEventLoop, fd: std.posix.fd_t) void {
        if (self.fd_sources.fetchRemove(fd)) |entry| {
            if (entry.value.source) |s| {
                gcd.dispatch_source_cancel(s);
                gcd.dispatch_release(s);
            }
        }
    }

    pub fn addTimer(self: *GcdEventLoop, timeout_ms: u64, repeat: bool, cb: event_loop.TimerCallback) !event_loop.TimerHandle {
        const id = self.next_timer_id;
        self.next_timer_id += 1;

        const source = gcd.dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
        if (source == null) return error.SourceCreateFailed;

        const ns = timeout_ms * 1_000_000;
        const start = gcd.dispatch_time(DISPATCH_TIME_NOW, @intCast(ns));
        const interval: u64 = if (repeat) ns else 0; // 0 = one-shot (DISPATCH_TIME_FOREVER)
        gcd.dispatch_source_set_timer(source, start, interval, ns / 10);

        gcd.dispatch_source_set_event_handler_f(source, &timerEventHandler);
        gcd.dispatch_set_context(source, cb.context);

        try self.timer_sources.put(id, .{ .source = source, .callback = cb });
        gcd.dispatch_resume(source);

        return .{ .id = id };
    }

    pub fn removeTimer(self: *GcdEventLoop, handle: event_loop.TimerHandle) void {
        if (self.timer_sources.fetchRemove(handle.id)) |entry| {
            if (entry.value.source) |s| {
                gcd.dispatch_source_cancel(s);
                gcd.dispatch_release(s);
            }
        }
    }

    pub fn run(_: *GcdEventLoop) void {
        // dispatch_main() never returns
        gcd.dispatch_main();
    }

    pub fn stop(self: *GcdEventLoop) void {
        self.running = false;
        // TODO: signal the dispatch queue to stop
    }

    fn fdEventHandler(context: ?*anyopaque) callconv(.C) void {
        if (context) |ctx| {
            const cb = event_loop.Callback{
                .context = ctx,
                .func = undefined, // Retrieved from fd_sources
            };
            _ = cb;
            // In practice, we'd look up the callback from stored context
        }
    }

    fn timerEventHandler(context: ?*anyopaque) callconv(.C) void {
        if (context) |ctx| {
            const cb = event_loop.TimerCallback{
                .context = ctx,
                .func = undefined,
            };
            _ = cb;
        }
    }

    const SourceCreateError = error{SourceCreateFailed};
} else struct {
    // Stub for non-macOS
    pub fn init(_: std.mem.Allocator) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
};
