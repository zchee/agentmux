const std = @import("std");
const Window = @import("window.zig").Window;
const Pane = @import("window.zig").Pane;
const Environ = @import("core/environ.zig").Environ;
const Style = @import("status/style.zig").Style;

/// An agentmux session. Contains windows and tracks attached clients.
pub const Session = struct {
    id: u32,
    name: []const u8,

    windows: std.ArrayListAligned(*Window, null),
    active_window: ?*Window,
    last_window: ?*Window,

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
        default_shell: [:0]u8,
        status: bool = true,
        mouse: bool = false,
        prefix_key: u21 = 0x02, // C-b
        prefix2_key: ?u21 = null,
        prefix_string: []u8,
        status_style: Style = .{
            .fg = .green,
            .bg = .black,
            .attrs = .{},
        },
        status_left: []u8,
        status_right: []u8,
        visual_activity: bool = false,
    };

    var next_id: u32 = 0;

    pub fn init(alloc: std.mem.Allocator, name: []const u8) !*Session {
        const s = try alloc.create(Session);
        errdefer alloc.destroy(s);

        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const default_shell = try alloc.dupeZ(u8, "/bin/sh");
        errdefer alloc.free(default_shell);
        const prefix_string = try alloc.dupe(u8, "C-b");
        errdefer alloc.free(prefix_string);
        const status_left = try alloc.dupe(u8, "[#S]");
        errdefer alloc.free(status_left);
        const status_right = try alloc.dupe(u8, "#H");
        errdefer alloc.free(status_right);

        s.* = .{
            .id = next_id,
            .name = owned_name,
            .windows = .empty,
            .active_window = null,
            .last_window = null,
            .attached = 0,
            .flags = .{},
            .options = .{
                .default_shell = default_shell,
                .prefix_string = prefix_string,
                .status_left = status_left,
                .status_right = status_right,
            },
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
        self.allocator.free(self.options.default_shell);
        self.allocator.free(self.options.prefix_string);
        self.allocator.free(self.options.status_left);
        self.allocator.free(self.options.status_right);
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

    /// Find a window by its displayed number (base-index-adjusted position).
    pub fn findWindowByNumber(self: *const Session, number: u32) ?*Window {
        if (number < self.options.base_index) return null;
        const offset = number - self.options.base_index;
        if (offset >= self.windows.items.len) return null;
        return self.windows.items[offset];
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

    /// Select a specific window, tracking the previous one.
    pub fn selectWindow(self: *Session, window: *Window) void {
        if (self.active_window) |current| {
            if (current != window) {
                self.last_window = current;
            }
        }
        self.active_window = window;
    }

    /// Switch to the last active window.
    pub fn lastWindow(self: *Session) bool {
        if (self.last_window) |last| {
            // Verify it's still in the window list
            for (self.windows.items) |w| {
                if (w == last) {
                    self.selectWindow(last);
                    return true;
                }
            }
            self.last_window = null;
        }
        return false;
    }

    /// Remove and destroy a window. Returns true if the session has no windows left.
    pub fn removeWindow(self: *Session, window: *Window) bool {
        // If this was the last_window, clear it
        if (self.last_window == window) {
            self.last_window = null;
        }

        for (self.windows.items, 0..) |w, i| {
            if (w == window) {
                _ = self.windows.orderedRemove(i);
                break;
            }
        }

        // If active window was removed, select another
        if (self.active_window == window) {
            self.active_window = if (self.windows.items.len > 0) self.windows.items[0] else null;
        }

        window.deinit();
        return self.windows.items.len == 0;
    }

    /// Rename the session.
    pub fn rename(self: *Session, new_name: []const u8) !void {
        const owned = try self.allocator.dupe(u8, new_name);
        self.allocator.free(self.name);
        self.name = owned;
    }

    pub fn setDefaultShell(self: *Session, shell: []const u8) !void {
        const owned = try self.allocator.dupeZ(u8, shell);
        self.allocator.free(self.options.default_shell);
        self.options.default_shell = owned;
    }

    pub fn setPrefix(self: *Session, prefix_string: []const u8, prefix_key: u21) !void {
        const owned = try self.allocator.dupe(u8, prefix_string);
        self.allocator.free(self.options.prefix_string);
        self.options.prefix_string = owned;
        self.options.prefix_key = prefix_key;
    }

    pub fn setStatusLeft(self: *Session, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.status_left);
        self.options.status_left = owned;
    }

    pub fn setStatusRight(self: *Session, value: []const u8) !void {
        const owned = try self.allocator.dupe(u8, value);
        self.allocator.free(self.options.status_right);
        self.options.status_right = owned;
    }
};

test "findWindowByNumber uses base index" {
    const alloc = std.testing.allocator;
    var session = try Session.init(alloc, "demo");
    defer session.deinit();
    session.options.base_index = 1;

    var w1 = try Window.init(alloc, "one", 80, 24);
    var w2 = try Window.init(alloc, "two", 80, 24);

    const p1 = try Pane.init(alloc, 80, 24);
    const p2 = try Pane.init(alloc, 80, 24);
    try w1.addPane(p1);
    try w2.addPane(p2);
    try session.addWindow(w1);
    try session.addWindow(w2);

    try std.testing.expect(session.findWindowByNumber(0) == null);
    try std.testing.expect(session.findWindowByNumber(1) == w1);
    try std.testing.expect(session.findWindowByNumber(2) == w2);
}
