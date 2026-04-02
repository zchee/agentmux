const std = @import("std");
const Window = @import("window.zig").Window;
const Environ = @import("core/environ.zig").Environ;

/// A zmux session. Contains windows and tracks attached clients.
pub const Session = struct {
    id: u32,
    name: []const u8,

    windows: std.ArrayListAligned(*Window, null),
    active_window: ?*Window,

    attached: u32,
    flags: Flags,

    options: Options,
    environ: Environ,

    allocator: std.mem.Allocator,

    pub const Flags = packed struct(u8) {
        alerted: bool = false,
        _padding: u7 = 0,
    };

    pub const Options = struct {
        base_index: u32 = 0,
        default_shell: ?[]const u8 = null,
        status: bool = true,
        mouse: bool = false,
        prefix_key: u21 = 0x02, // C-b
    };

    var next_id: u32 = 0;

    pub fn init(alloc: std.mem.Allocator, name: []const u8) !*Session {
        const s = try alloc.create(Session);
        const owned_name = try alloc.dupe(u8, name);
        s.* = .{
            .id = next_id,
            .name = owned_name,
            .windows = .empty,
            .active_window = null,
            .attached = 0,
            .flags = .{},
            .options = .{},
            .environ = Environ.init(alloc),
            .allocator = alloc,
        };
        next_id += 1;
        return s;
    }

    pub fn deinit(self: *Session) void {
        for (self.windows.items) |w| {
            w.deinit();
        }
        self.windows.deinit(self.allocator);
        self.environ.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Add a window to the session.
    pub fn addWindow(self: *Session, window: *Window) !void {
        try self.windows.append(self.allocator, window);
        if (self.active_window == null) {
            self.active_window = window;
        }
    }

    /// Find a window by index.
    pub fn findWindow(self: *const Session, index: u32) ?*Window {
        for (self.windows.items) |w| {
            if (w.id == index) return w;
        }
        return null;
    }

    /// Get the number of windows.
    pub fn windowCount(self: *const Session) usize {
        return self.windows.items.len;
    }

    /// Select the next window.
    pub fn nextWindow(self: *Session) void {
        if (self.windows.items.len == 0) return;
        if (self.active_window) |active| {
            for (self.windows.items, 0..) |w, i| {
                if (w == active) {
                    const next_idx = (i + 1) % self.windows.items.len;
                    self.active_window = self.windows.items[next_idx];
                    return;
                }
            }
        }
        self.active_window = self.windows.items[0];
    }

    /// Select the previous window.
    pub fn prevWindow(self: *Session) void {
        if (self.windows.items.len == 0) return;
        if (self.active_window) |active| {
            for (self.windows.items, 0..) |w, i| {
                if (w == active) {
                    const prev_idx = if (i == 0) self.windows.items.len - 1 else i - 1;
                    self.active_window = self.windows.items[prev_idx];
                    return;
                }
            }
        }
    }

    /// Rename the session.
    pub fn rename(self: *Session, new_name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = owned;
    }
};
