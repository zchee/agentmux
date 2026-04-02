const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

/// Zmux allocator wrapper with leak detection.
/// In debug builds, wraps DebugAllocator for leak tracking.
/// In release builds, uses the C allocator for performance.
pub const ZmuxAllocator = struct {
    backing: BackingAllocator,

    const BackingAllocator = if (builtin.mode == .Debug)
        std.heap.DebugAllocator(.{})
    else
        struct {
            pub fn allocator(_: *@This()) std.mem.Allocator {
                return std.heap.c_allocator;
            }
            pub fn deinit(_: *@This()) std.heap.Check {
                return .ok;
            }
        };

    pub fn init() ZmuxAllocator {
        return .{ .backing = if (builtin.mode == .Debug) .init else .{} };
    }

    pub fn allocator(self: *ZmuxAllocator) std.mem.Allocator {
        return self.backing.allocator();
    }

    pub fn deinit(self: *ZmuxAllocator) void {
        if (builtin.mode == .Debug) {
            const result = self.backing.deinit();
            if (result == .leak) {
                log.err("memory leak detected", .{});
            }
        }
    }
};

/// Create a fixed-buffer allocator for temporary operations.
pub fn scratchAllocator(buf: []u8) std.heap.FixedBufferAllocator {
    return std.heap.FixedBufferAllocator.init(buf);
}
