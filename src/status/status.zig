const std = @import("std");
const format = @import("format.zig");
const style_mod = @import("style.zig");
const utf8 = @import("../core/utf8.zig");

fn decodeVisibleChar(text: []const u8, index: usize) ?utf8.Char {
    if (index >= text.len) return null;
    return utf8.decode(text[index..]);
}

fn visibleLen(text: []const u8) usize {
    var len: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (style_mod.markerEnd(text, i)) |end| {
            i = end;
            continue;
        }

        if (decodeVisibleChar(text, i)) |ch| {
            len += ch.width();
            i += ch.len;
        } else {
            len += 1;
            i += 1;
        }
    }
    return len;
}

fn appendVisiblePrefix(
    alloc: std.mem.Allocator,
    out: *std.ArrayListAligned(u8, null),
    text: []const u8,
    max_visible: usize,
) !usize {
    var visible: usize = 0;
    var i: usize = 0;
    while (i < text.len and visible < max_visible) {
        if (style_mod.markerEnd(text, i)) |end| {
            try out.appendSlice(alloc, text[i..end]);
            i = end;
            continue;
        }

        if (decodeVisibleChar(text, i)) |ch| {
            const width = ch.width();
            if (visible + width > max_visible) break;
            try out.appendSlice(alloc, ch.slice());
            i += ch.len;
            visible += width;
        } else {
            try out.append(alloc, text[i]);
            i += 1;
            visible += 1;
        }
    }
    return visible;
}

fn endsWithVisibleSpace(text: []const u8) bool {
    var saw_visible = false;
    var last_space = false;
    var i: usize = 0;
    while (i < text.len) {
        if (style_mod.markerEnd(text, i)) |end| {
            i = end;
            continue;
        }

        if (decodeVisibleChar(text, i)) |ch| {
            if (ch.width() > 0) {
                saw_visible = true;
                last_space = std.ascii.isWhitespace(ch.bytes[0]) and ch.len == 1;
            }
            i += ch.len;
        } else {
            saw_visible = true;
            last_space = std.ascii.isWhitespace(text[i]);
            i += 1;
        }
    }

    return saw_visible and last_space;
}

fn startsWithVisibleSpace(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (style_mod.markerEnd(text, i)) |end| {
            i = end;
            continue;
        }

        if (decodeVisibleChar(text, i)) |ch| {
            if (ch.width() == 0) {
                i += ch.len;
                continue;
            }
            return std.ascii.isWhitespace(ch.bytes[0]) and ch.len == 1;
        }

        return std.ascii.isWhitespace(text[i]);
    }

    return false;
}

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

        return self.renderSections(alloc, cols, left, "", right);
    }

    /// Render the status bar with explicit left/window-list/right sections.
    pub fn renderSections(
        self: *const StatusBar,
        alloc: std.mem.Allocator,
        cols: u32,
        left: []const u8,
        center: []const u8,
        right: []const u8,
    ) ![]u8 {
        if (!self.enabled or cols == 0) {
            return try alloc.alloc(u8, 0);
        }

        var leading: std.ArrayListAligned(u8, null) = .empty;
        defer leading.deinit(alloc);

        if (left.len > 0) {
            try leading.appendSlice(alloc, left);
        }
        if (center.len > 0) {
            if (leading.items.len > 0 and !endsWithVisibleSpace(leading.items) and !startsWithVisibleSpace(center)) {
                try leading.append(alloc, ' ');
            }
            try leading.appendSlice(alloc, center);
        }

        var line: std.ArrayListAligned(u8, null) = .empty;
        errdefer line.deinit(alloc);

        const right_len = @min(visibleLen(right), cols);
        const leading_budget = cols - right_len;
        const leading_len = @min(visibleLen(leading.items), leading_budget);
        var rendered_leading = try appendVisiblePrefix(alloc, &line, leading.items, leading_len);

        while (rendered_leading < leading_budget) {
            try line.append(alloc, ' ');
            rendered_leading += 1;
        }

        _ = try appendVisiblePrefix(alloc, &line, right, right_len);

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

test "status bar render sections keeps window list between left and right" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();

    const result = try bar.renderSections(alloc, 32, "[demo]", "0:editor* 1:shell-", "12:34");
    defer alloc.free(result);

    try std.testing.expectEqual(@as(usize, 32), result.len);
    try std.testing.expect(std.mem.indexOf(u8, result, "0:editor* 1:shell-") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "12:34"));
}

test "status bar render sections ignores inline style markers for width" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();

    const result = try bar.renderSections(alloc, 20, "#[fg=green]LEFT", "", "#[bold]RIGHT");
    defer alloc.free(result);

    try std.testing.expectEqual(@as(usize, 20), visibleLen(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "#[fg=green]LEFT") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "#[bold]RIGHT") != null);
}

test "status bar render sections does not add duplicate separator when left already ends with space" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();

    const result = try bar.renderSections(alloc, 16, "LEFT ", "CENTER", "");
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "LEFT  CENTER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "LEFT CENTER") != null);
}

test "status bar render sections preserves separator when left lacks trailing space" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();

    const result = try bar.renderSections(alloc, 16, "LEFT", "CENTER", "");
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "LEFTCENTER") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "LEFT CENTER") != null);
}

test "status bar render sections counts utf8 glyph width instead of bytes" {
    const alloc = std.testing.allocator;
    const bar = StatusBar.init();

    const result = try bar.renderSections(alloc, 8, "A", "", "BC");
    defer alloc.free(result);

    try std.testing.expectEqual(@as(usize, 8), visibleLen(result));
    try std.testing.expect(std.mem.indexOf(u8, result, "A") != null);
    try std.testing.expect(std.mem.endsWith(u8, result, "BC"));
}
