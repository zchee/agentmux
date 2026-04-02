const std = @import("std");

/// Context for format string expansion.
pub const FormatContext = struct {
    session_name: []const u8 = "",
    session_id: u32 = 0,
    window_name: []const u8 = "",
    window_index: u32 = 0,
    window_active: bool = false,
    pane_index: u32 = 0,
    pane_title: []const u8 = "",
    pane_current_path: []const u8 = "",
    pane_pid: i32 = 0,
    host: []const u8 = "",
    client_name: []const u8 = "",
};

/// Expand a tmux format string.
/// Supports: #S (session), #W (window), #I (window index), #P (pane index),
/// #T (title), #H (hostname), #{variable_name} long form.
pub fn expand(alloc: std.mem.Allocator, fmt: []const u8, ctx: *const FormatContext) ![]u8 {
    var result: std.ArrayListAligned(u8, null) = .empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '#') {
            try result.append(alloc, fmt[i]);
            i += 1;
            continue;
        }

        i += 1; // skip #
        if (i >= fmt.len) break;

        switch (fmt[i]) {
            '#' => {
                try result.append(alloc, '#');
                i += 1;
            },
            'S' => {
                try result.appendSlice(alloc, ctx.session_name);
                i += 1;
            },
            'W' => {
                try result.appendSlice(alloc, ctx.window_name);
                i += 1;
            },
            'I' => {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.window_index}) catch "?";
                try result.appendSlice(alloc, s);
                i += 1;
            },
            'P' => {
                var buf: [16]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.pane_index}) catch "?";
                try result.appendSlice(alloc, s);
                i += 1;
            },
            'T' => {
                try result.appendSlice(alloc, ctx.pane_title);
                i += 1;
            },
            'H' => {
                try result.appendSlice(alloc, ctx.host);
                i += 1;
            },
            '{' => {
                // Long form: #{variable_name}
                i += 1;
                const start = i;
                while (i < fmt.len and fmt[i] != '}') : (i += 1) {}
                if (i < fmt.len) {
                    const var_name = fmt[start..i];
                    i += 1; // skip }
                    try result.appendSlice(alloc, resolveVariable(var_name, ctx));
                }
            },
            '[' => {
                // Style: #[fg=red] — pass through for style processing
                try result.append(alloc, '#');
                try result.append(alloc, '[');
                i += 1;
            },
            else => {
                try result.append(alloc, '#');
                try result.append(alloc, fmt[i]);
                i += 1;
            },
        }
    }

    return try result.toOwnedSlice(alloc);
}

fn resolveVariable(name: []const u8, ctx: *const FormatContext) []const u8 {
    if (std.mem.eql(u8, name, "session_name")) return ctx.session_name;
    if (std.mem.eql(u8, name, "session_id")) return "";
    if (std.mem.eql(u8, name, "window_name")) return ctx.window_name;
    if (std.mem.eql(u8, name, "window_index")) return "";
    if (std.mem.eql(u8, name, "pane_index")) return "";
    if (std.mem.eql(u8, name, "pane_title")) return ctx.pane_title;
    if (std.mem.eql(u8, name, "pane_current_path")) return ctx.pane_current_path;
    if (std.mem.eql(u8, name, "host")) return ctx.host;
    if (std.mem.eql(u8, name, "client_name")) return ctx.client_name;
    return "";
}

test "expand simple" {
    const ctx = FormatContext{
        .session_name = "main",
        .window_name = "vim",
        .window_index = 2,
    };
    const result = try expand(std.testing.allocator, "[#S] #I:#W", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("[main] 2:vim", result);
}

test "expand long form" {
    const ctx = FormatContext{
        .session_name = "dev",
        .pane_current_path = "/home/user",
    };
    const result = try expand(std.testing.allocator, "#{session_name} - #{pane_current_path}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("dev - /home/user", result);
}

test "expand escape hash" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "##literal", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("#literal", result);
}
