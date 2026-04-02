const std = @import("std");

/// A single paste buffer holding text data with an optional name.
pub const PasteBuffer = struct {
    data: []const u8,
    name: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, data: []const u8, name: ?[]const u8) !*PasteBuffer {
        const self = try alloc.create(PasteBuffer);
        self.* = .{
            .data = try alloc.dupe(u8, data),
            .name = if (name) |n| try alloc.dupe(u8, n) else null,
            .allocator = alloc,
        };
        return self;
    }

    pub fn deinit(self: *PasteBuffer) void {
        self.allocator.free(self.data);
        if (self.name) |n| self.allocator.free(n);
        self.allocator.destroy(self);
    }
};

/// Stack of paste buffers. Top of stack is the most recently pushed buffer.
pub const PasteStack = struct {
    buffers: std.ArrayListAligned(*PasteBuffer, null),
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) PasteStack {
        return .{
            .buffers = .empty,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *PasteStack) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.deinit(self.allocator);
    }

    /// Push a new buffer onto the top of the stack.
    pub fn push(self: *PasteStack, data: []const u8, name: ?[]const u8) !void {
        const buf = try PasteBuffer.init(self.allocator, data, name);
        try self.buffers.append(self.allocator, buf);
    }

    /// Remove and return the top buffer. Caller owns the returned buffer and must call deinit.
    pub fn pop(self: *PasteStack) ?*PasteBuffer {
        if (self.buffers.items.len == 0) return null;
        return self.buffers.pop();
    }

    /// Get buffer at logical index (0 = top of stack, most recent).
    pub fn get(self: *const PasteStack, index: usize) ?*PasteBuffer {
        if (index >= self.buffers.items.len) return null;
        const real_idx = self.buffers.items.len - 1 - index;
        return self.buffers.items[real_idx];
    }

    /// Find a buffer by name (searches from top of stack).
    pub fn getByName(self: *const PasteStack, name: []const u8) ?*PasteBuffer {
        var i = self.buffers.items.len;
        while (i > 0) {
            i -= 1;
            const buf = self.buffers.items[i];
            if (buf.name) |n| {
                if (std.mem.eql(u8, n, name)) return buf;
            }
        }
        return null;
    }

    /// Return the number of buffers.
    pub fn count(self: *const PasteStack) usize {
        return self.buffers.items.len;
    }

    /// Remove and free all buffers.
    pub fn clear(self: *PasteStack) void {
        for (self.buffers.items) |buf| {
            buf.deinit();
        }
        self.buffers.clearRetainingCapacity();
    }
};

test "paste buffer init and deinit" {
    const buf = try PasteBuffer.init(std.testing.allocator, "hello world", "test");
    defer buf.deinit();

    try std.testing.expectEqualStrings("hello world", buf.data);
    try std.testing.expectEqualStrings("test", buf.name.?);
}

test "paste buffer no name" {
    const buf = try PasteBuffer.init(std.testing.allocator, "data", null);
    defer buf.deinit();

    try std.testing.expectEqualStrings("data", buf.data);
    try std.testing.expect(buf.name == null);
}

test "paste stack push and pop" {
    var stack = PasteStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push("first", null);
    try stack.push("second", null);
    try stack.push("third", null);

    try std.testing.expectEqual(@as(usize, 3), stack.count());

    const top = stack.pop().?;
    defer top.deinit();
    try std.testing.expectEqualStrings("third", top.data);
    try std.testing.expectEqual(@as(usize, 2), stack.count());

    const next = stack.pop().?;
    defer next.deinit();
    try std.testing.expectEqualStrings("second", next.data);
}

test "paste stack pop empty" {
    var stack = PasteStack.init(std.testing.allocator);
    defer stack.deinit();

    try std.testing.expect(stack.pop() == null);
}

test "paste stack get by index" {
    var stack = PasteStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push("first", null);
    try stack.push("second", null);
    try stack.push("third", null);

    // Index 0 = top (most recent)
    try std.testing.expectEqualStrings("third", stack.get(0).?.data);
    try std.testing.expectEqualStrings("second", stack.get(1).?.data);
    try std.testing.expectEqualStrings("first", stack.get(2).?.data);
    try std.testing.expect(stack.get(3) == null);
}

test "paste stack get by name" {
    var stack = PasteStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push("unnamed data", null);
    try stack.push("named data", "mybuf");
    try stack.push("other data", "other");

    const found = stack.getByName("mybuf").?;
    try std.testing.expectEqualStrings("named data", found.data);

    try std.testing.expect(stack.getByName("missing") == null);
}

test "paste stack clear" {
    var stack = PasteStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push("a", null);
    try stack.push("b", null);
    stack.clear();

    try std.testing.expectEqual(@as(usize, 0), stack.count());
    try std.testing.expect(stack.pop() == null);
}
