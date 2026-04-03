const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const event_loop = @import("../core/event_loop.zig");

/// GCD-based event loop for macOS.
pub const GcdEventLoop = if (builtin.os.tag == .macos) struct {
    // libdispatch opaque pointer types
    const dispatch_queue_t = ?*anyopaque;
    const dispatch_source_t = ?*anyopaque;
    const dispatch_object_t = ?*anyopaque;
    const dispatch_function_t = *const fn (?*anyopaque) callconv(.c) void;
    const dispatch_time_t = u64;
    const dispatch_semaphore_t = ?*anyopaque;

    const DISPATCH_TIME_NOW: dispatch_time_t = 0;
    const DISPATCH_TIME_FOREVER: dispatch_time_t = ~@as(dispatch_time_t, 0);

    // Declare source type globals as u8 externals so &var gives a correct pointer.
    // The C macro DISPATCH_SOURCE_TYPE_READ expands to &_dispatch_source_type_read.
    // extern "c" maps the symbol with the C underscore-prefix convention on macOS.
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
        extern "c" fn dispatch_source_set_timer(source: dispatch_source_t, start: dispatch_time_t, interval: u64, leeway: u64) void;
        extern "c" fn dispatch_time(when: dispatch_time_t, delta: i64) dispatch_time_t;
        extern "c" fn dispatch_semaphore_create(value: i64) dispatch_semaphore_t;
        extern "c" fn dispatch_semaphore_wait(dsema: dispatch_semaphore_t, timeout: dispatch_time_t) i64;
        extern "c" fn dispatch_semaphore_signal(dsema: dispatch_semaphore_t) i64;
        // Source type globals: the dylib symbols are __dispatch_source_type_*
        // (double underscore). Zig's extern "c" adds one underscore on macOS,
        // so we declare with a leading underscore to produce the correct symbol.
        extern "c" var _dispatch_source_type_read: u8;
        extern "c" var _dispatch_source_type_write: u8;
        extern "c" var _dispatch_source_type_timer: u8;
    };

    fn sourceTypeRead() ?*anyopaque {
        return @ptrCast(&gcd._dispatch_source_type_read);
    }
    fn sourceTypeWrite() ?*anyopaque {
        return @ptrCast(&gcd._dispatch_source_type_write);
    }
    fn sourceTypeTimer() ?*anyopaque {
        return @ptrCast(&gcd._dispatch_source_type_timer);
    }

    // Heap-allocated context passed through dispatch_set_context so C callbacks
    // can recover both the fd/event-type and the full Callback struct.
    const FdContext = struct {
        fd: posix.fd_t,
        event_type: event_loop.EventType, // always .read or .write (never .read_write)
        callback: event_loop.Callback,
        source: dispatch_source_t,
    };

    // Per-fd pair: a fd may have an independent read source, write source, or both.
    const FdSourcePair = struct {
        read: ?*FdContext = null,
        write: ?*FdContext = null,
    };

    // Heap-allocated context for timer callbacks.
    const TimerContext = struct {
        callback: event_loop.TimerCallback,
        repeat: bool,
        source: dispatch_source_t,
    };

    // ---- VTable trampoline functions ----------------------------------------

    fn vtAddFd(ptr: *anyopaque, fd: posix.fd_t, ev: event_loop.EventType, cb: event_loop.Callback) anyerror!void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        return self.addFd(fd, ev, cb);
    }
    fn vtRemoveFd(ptr: *anyopaque, fd: posix.fd_t) void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        self.removeFd(fd);
    }
    fn vtAddTimer(ptr: *anyopaque, timeout_ms: u64, repeat: bool, cb: event_loop.TimerCallback) anyerror!event_loop.TimerHandle {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        return self.addTimer(timeout_ms, repeat, cb);
    }
    fn vtRemoveTimer(ptr: *anyopaque, handle: event_loop.TimerHandle) void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        self.removeTimer(handle);
    }
    fn vtRun(ptr: *anyopaque) anyerror!void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        return self.run();
    }
    fn vtStop(ptr: *anyopaque) void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        self.stop();
    }
    fn vtDeinit(ptr: *anyopaque) void {
        const self: *GcdEventLoop = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    const vtable = event_loop.EventLoop.VTable{
        .addFd = vtAddFd,
        .removeFd = vtRemoveFd,
        .addTimer = vtAddTimer,
        .removeTimer = vtRemoveTimer,
        .run = vtRun,
        .stop = vtStop,
        .deinit = vtDeinit,
    };

    // ---- C-callable event handlers ------------------------------------------

    fn fdReadHandler(ctx: ?*anyopaque) callconv(.c) void {
        const fc: *FdContext = @ptrCast(@alignCast(ctx.?));
        fc.callback.invoke(fc.fd, .read);
    }

    fn fdWriteHandler(ctx: ?*anyopaque) callconv(.c) void {
        const fc: *FdContext = @ptrCast(@alignCast(ctx.?));
        fc.callback.invoke(fc.fd, .write);
    }

    fn timerHandler(ctx: ?*anyopaque) callconv(.c) void {
        const tc: *TimerContext = @ptrCast(@alignCast(ctx.?));
        tc.callback.invoke();
        if (!tc.repeat) {
            gcd.dispatch_source_cancel(tc.source);
        }
    }

    // ---- Struct fields ------------------------------------------------------

    allocator: std.mem.Allocator,
    queue: dispatch_queue_t,
    stop_sem: dispatch_semaphore_t,
    fd_sources: std.AutoHashMap(posix.fd_t, FdSourcePair),
    timer_sources: std.AutoHashMap(u64, *TimerContext),
    next_timer_id: u64,
    running: bool,

    // ---- Public API ---------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator) GcdEventLoop {
        return .{
            .allocator = alloc,
            .queue = gcd.dispatch_queue_create("com.agentmux.eventloop", null),
            .stop_sem = gcd.dispatch_semaphore_create(0),
            .fd_sources = std.AutoHashMap(posix.fd_t, FdSourcePair).init(alloc),
            .timer_sources = std.AutoHashMap(u64, *TimerContext).init(alloc),
            .next_timer_id = 1,
            .running = false,
        };
    }

    /// Return the platform-agnostic EventLoop interface backed by this GCD loop.
    pub fn eventLoop(self: *GcdEventLoop) event_loop.EventLoop {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn addFd(self: *GcdEventLoop, fd: posix.fd_t, ev: event_loop.EventType, cb: event_loop.Callback) !void {
        const gop = try self.fd_sources.getOrPut(fd);
        if (!gop.found_existing) gop.value_ptr.* = .{};

        if (ev == .read or ev == .read_write) {
            if (gop.value_ptr.read) |old| cancelFdContext(old);
            const fc = try self.allocator.create(FdContext);
            const src = gcd.dispatch_source_create(sourceTypeRead(), @intCast(fd), 0, self.queue);
            if (src == null) {
                self.allocator.destroy(fc);
                return error.SourceCreateFailed;
            }
            fc.* = .{ .fd = fd, .event_type = .read, .callback = cb, .source = src };
            gcd.dispatch_set_context(src, fc);
            gcd.dispatch_source_set_event_handler_f(src, fdReadHandler);
            gcd.dispatch_resume(src);
            gop.value_ptr.read = fc;
        }
        if (ev == .write or ev == .read_write) {
            if (gop.value_ptr.write) |old| cancelFdContext(old);
            const fc = try self.allocator.create(FdContext);
            const src = gcd.dispatch_source_create(sourceTypeWrite(), @intCast(fd), 0, self.queue);
            if (src == null) {
                self.allocator.destroy(fc);
                return error.SourceCreateFailed;
            }
            fc.* = .{ .fd = fd, .event_type = .write, .callback = cb, .source = src };
            gcd.dispatch_set_context(src, fc);
            gcd.dispatch_source_set_event_handler_f(src, fdWriteHandler);
            gcd.dispatch_resume(src);
            gop.value_ptr.write = fc;
        }
    }

    pub fn removeFd(self: *GcdEventLoop, fd: posix.fd_t) void {
        const kv = self.fd_sources.fetchRemove(fd) orelse return;
        if (kv.value.read) |fc| {
            cancelFdContext(fc);
            self.allocator.destroy(fc);
        }
        if (kv.value.write) |fc| {
            cancelFdContext(fc);
            self.allocator.destroy(fc);
        }
    }

    pub fn addTimer(self: *GcdEventLoop, timeout_ms: u64, repeat: bool, cb: event_loop.TimerCallback) !event_loop.TimerHandle {
        const id = self.next_timer_id;
        self.next_timer_id += 1;

        const tc = try self.allocator.create(TimerContext);
        const src = gcd.dispatch_source_create(sourceTypeTimer(), 0, 0, self.queue);
        if (src == null) {
            self.allocator.destroy(tc);
            return error.SourceCreateFailed;
        }
        tc.* = .{ .callback = cb, .repeat = repeat, .source = src };

        const ns: i64 = @intCast(timeout_ms * std.time.ns_per_ms);
        const start = gcd.dispatch_time(DISPATCH_TIME_NOW, ns);
        const interval: u64 = if (repeat) @intCast(ns) else DISPATCH_TIME_FOREVER;
        gcd.dispatch_source_set_timer(src, start, interval, 0);
        gcd.dispatch_set_context(src, tc);
        gcd.dispatch_source_set_event_handler_f(src, timerHandler);
        gcd.dispatch_resume(src);

        try self.timer_sources.put(id, tc);
        return .{ .id = id };
    }

    pub fn removeTimer(self: *GcdEventLoop, handle: event_loop.TimerHandle) void {
        const kv = self.timer_sources.fetchRemove(handle.id) orelse return;
        gcd.dispatch_source_cancel(kv.value.source);
        gcd.dispatch_release(kv.value.source);
        self.allocator.destroy(kv.value);
    }

    /// Block until stop() is called. Dispatch sources fire on the queue in the background.
    pub fn run(self: *GcdEventLoop) !void {
        self.running = true;
        _ = gcd.dispatch_semaphore_wait(self.stop_sem, DISPATCH_TIME_FOREVER);
        self.running = false;
    }

    pub fn stop(self: *GcdEventLoop) void {
        _ = gcd.dispatch_semaphore_signal(self.stop_sem);
    }

    pub fn deinit(self: *GcdEventLoop) void {
        var fd_it = self.fd_sources.iterator();
        while (fd_it.next()) |kv| {
            if (kv.value_ptr.read) |fc| {
                cancelFdContext(fc);
                self.allocator.destroy(fc);
            }
            if (kv.value_ptr.write) |fc| {
                cancelFdContext(fc);
                self.allocator.destroy(fc);
            }
        }
        self.fd_sources.deinit();

        var timer_it = self.timer_sources.iterator();
        while (timer_it.next()) |kv| {
            gcd.dispatch_source_cancel(kv.value_ptr.*.source);
            gcd.dispatch_release(kv.value_ptr.*.source);
            self.allocator.destroy(kv.value_ptr.*);
        }
        self.timer_sources.deinit();

        if (self.stop_sem) |s| gcd.dispatch_release(s);
        if (self.queue) |q| gcd.dispatch_release(q);
    }

    // ---- Helpers ------------------------------------------------------------

    fn cancelFdContext(fc: *FdContext) void {
        gcd.dispatch_source_cancel(fc.source);
        gcd.dispatch_release(fc.source);
    }

    const SourceCreateError = error{SourceCreateFailed};
} else struct {
    pub fn init(_: std.mem.Allocator) @This() {
        return .{};
    }
    pub fn deinit(_: *@This()) void {}
};
