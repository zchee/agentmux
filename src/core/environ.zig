const std = @import("std");
const Allocator = std.mem.Allocator;

/// Environment variable store.
/// Manages a set of key=value pairs, with support for inheritance
/// from the system environment and per-session overrides.
pub const Environ = struct {
    vars: std.StringHashMap(Entry),

    pub const Entry = struct {
        value: ?[]const u8,
        hidden: bool,
    };

    pub fn init(alloc: Allocator) Environ {
        return .{
            .vars = std.StringHashMap(Entry).init(alloc),
        };
    }

    pub fn deinit(self: *Environ) void {
        const alloc = self.vars.allocator;
        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            alloc.free(entry.key_ptr.*);
            if (entry.value_ptr.value) |v| {
                alloc.free(v);
            }
        }
        self.vars.deinit();
    }

    /// Set a variable. Overwrites if it already exists.
    pub fn set(self: *Environ, key: []const u8, value: []const u8) !void {
        const alloc = self.vars.allocator;
        const owned_key = try alloc.dupe(u8, key);
        errdefer alloc.free(owned_key);
        const owned_val = try alloc.dupe(u8, value);
        errdefer alloc.free(owned_val);

        const result = try self.vars.getOrPut(owned_key);
        if (result.found_existing) {
            alloc.free(result.key_ptr.*);
            if (result.value_ptr.value) |old_val| {
                alloc.free(old_val);
            }
            result.key_ptr.* = owned_key;
        }
        result.value_ptr.* = .{ .value = owned_val, .hidden = false };
    }

    /// Mark a variable as unset.
    pub fn unset(self: *Environ, key: []const u8) !void {
        const alloc = self.vars.allocator;
        const owned_key = try alloc.dupe(u8, key);
        errdefer alloc.free(owned_key);

        const result = try self.vars.getOrPut(owned_key);
        if (result.found_existing) {
            alloc.free(result.key_ptr.*);
            if (result.value_ptr.value) |old_val| {
                alloc.free(old_val);
            }
            result.key_ptr.* = owned_key;
        }
        result.value_ptr.* = .{ .value = null, .hidden = false };
    }

    /// Get a variable's value.
    pub fn get(self: *const Environ, key: []const u8) ?[]const u8 {
        const entry = self.vars.get(key) orelse return null;
        return entry.value;
    }

    /// Build an envp array suitable for execve.
    pub fn toEnvp(self: *const Environ, alloc: Allocator) ![:null]const ?[*:0]const u8 {
        var list: std.ArrayListAligned(?[*:0]const u8, null) = .empty;
        errdefer {
            for (list.items) |item| {
                if (item) |ptr| alloc.free(std.mem.sliceTo(ptr, 0));
            }
            list.deinit(alloc);
        }

        var iter = self.vars.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.hidden) continue;
            const val = entry.value_ptr.value orelse continue;
            const s = try std.fmt.allocPrintZ(alloc, "{s}={s}", .{ entry.key_ptr.*, val });
            try list.append(alloc, s);
        }
        return try list.toOwnedSliceSentinel(alloc, null);
    }
};

test "set and get" {
    var env = Environ.init(std.testing.allocator);
    defer env.deinit();
    try env.set("FOO", "bar");
    try std.testing.expectEqualStrings("bar", env.get("FOO").?);
}

test "unset" {
    var env = Environ.init(std.testing.allocator);
    defer env.deinit();
    try env.set("FOO", "bar");
    try env.unset("FOO");
    try std.testing.expect(env.get("FOO") == null);
}
