const std = @import("std");
const format = @import("format.zig");
const style_mod = @import("style.zig");

/// Status bar configuration and rendering.
pub const StatusBar = struct {
    left: []const u8,
    right: []const u8,
    style: style_mod.Style,
    interval: u32, // refresh interval in seconds
    enabled: bool,

    pub const default_left = "[#S] ";
    pub const default_right = " %H:%M %d-%b-%y";

    pub fn init() StatusBar {
        return .{
            .left = default_left,
            .right = default_right,
            .style = style_mod.Style.default,
            .interval = 15,
            .enabled = true,
        };
    }

    /// Render the status bar for a given width.
    pub fn render(self: *const StatusBar, alloc: std.mem.Allocator, cols: u32, ctx: *const format.FormatContext) ![]u8 {
        if (!self.enabled or cols == 0) {
            return try alloc.alloc(u8, 0);
        }

        const left = try format.expand(alloc, self.left, ctx);
        defer alloc.free(left);
        const right = try format.expand(alloc, self.right, ctx);
        defer alloc.free(right);

        // Build the status line: left + padding + right
        var line: std.ArrayListAligned(u8, null) = .empty;
        errdefer line.deinit(alloc);

        // Add left section
        const left_len = @min(left.len, cols);
        try line.appendSlice(alloc, left[0..left_len]);

        // Calculate padding
        const right_len = @min(right.len, cols);
        const used = left_len + right_len;
        if (used < cols) {
            // Fill middle with spaces
            const padding = cols - @as(u32, @intCast(used));
            var p: u32 = 0;
            while (p < padding) : (p += 1) {
                try line.append(alloc, ' ');
            }
        }

        // Add right section
        try line.appendSlice(alloc, right[0..right_len]);

        return try line.toOwnedSlice(alloc);
    }
};

test "status bar render" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();
    const ctx = format.FormatContext{
        .session_name = "main",
    };

    const result = try bar.render(alloc, 40, &ctx);
    defer alloc.free(result);

    // Should start with [main]
    try std.testing.expect(std.mem.startsWith(u8, result, "[main] "));
    try std.testing.expectEqual(@as(usize, 40), result.len);
}

test "status bar disabled" {
    const alloc = std.testing.allocator;
    var bar = StatusBar.init();
    bar.enabled = false;
    const ctx = format.FormatContext{};

    const result = try bar.render(alloc, 80, &ctx);
    defer alloc.free(result);
    try std.testing.expectEqual(@as(usize, 0), result.len);
}
