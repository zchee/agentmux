const std = @import("std");

const ClockTm = extern struct {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
};

extern "c" fn time(timer: ?*i64) i64;
extern "c" fn localtime(timer: *const i64) ?*ClockTm;
extern "c" fn strftime(buf: [*]u8, maxsize: usize, format: [*:0]const u8, tm: *const ClockTm) usize;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Context for format string expansion.
pub const FormatContext = struct {
    session_name: []const u8 = "",
    session_id: u32 = 0,
    window_name: []const u8 = "",
    window_index: u32 = 0,
    window_active: bool = false,
    window_flags: []const u8 = "",
    pane_index: u32 = 0,
    pane_title: []const u8 = "",
    pane_current_path: []const u8 = "",
    pane_pid: i32 = 0,
    host: []const u8 = "",
    client_name: []const u8 = "",
};

/// Expand a tmux format string.
/// Supports: #S (session), #W (window), #I (window index), #P (pane index),
/// #T (title), #H (hostname), #{variable_name} long form,
/// #{?var,true,false} conditional, #{==:a,b} equality, #{l:str} string length.
pub fn expand(alloc: std.mem.Allocator, fmt: []const u8, ctx: *const FormatContext) ![]u8 {
    var result: std.ArrayListAligned(u8, null) = .empty;
    errdefer result.deinit(alloc);

    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] == '%') {
            const start = i;
            while (i < fmt.len and fmt[i] != '#') : (i += 1) {}
            try appendTimeFormatSegment(alloc, &result, fmt[start..i]);
            continue;
        }

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
            'F' => {
                try result.appendSlice(alloc, ctx.window_flags);
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
                // Long form: #{variable_name}, #{?var,true,false}, #{==:a,b}, #{l:str}
                i += 1;
                const start = i;
                // Find matching '}', tracking nesting depth.
                var depth: u32 = 1;
                while (i < fmt.len and depth > 0) : (i += 1) {
                    if (fmt[i] == '{') depth += 1;
                    if (fmt[i] == '}') depth -= 1;
                }
                if (start < i) {
                    const content = fmt[start .. i - 1];
                    if (content.len > 0 and content[0] == '?') {
                        // Conditional: #{?var,true_value,false_value}
                        const body = content[1..];
                        if (findComma(body)) |comma1| {
                            const var_name = body[0..comma1];
                            const rest = body[comma1 + 1 ..];
                            if (findComma(rest)) |comma2| {
                                const true_val = rest[0..comma2];
                                const false_val = rest[comma2 + 1 ..];
                                const resolved = resolveVariable(var_name, ctx);
                                const truthy = resolved.len > 0 and !std.mem.eql(u8, resolved, "0");
                                const branch = if (truthy) true_val else false_val;
                                const expanded = try expand(alloc, branch, ctx);
                                defer alloc.free(expanded);
                                try result.appendSlice(alloc, expanded);
                            }
                        }
                    } else if (content.len > 3 and std.mem.startsWith(u8, content, "==:")) {
                        // Comparison: #{==:a,b}
                        const body = content[3..];
                        if (findComma(body)) |comma| {
                            const a_raw = body[0..comma];
                            const b_raw = body[comma + 1 ..];
                            const a_exp = try expand(alloc, a_raw, ctx);
                            defer alloc.free(a_exp);
                            const b_exp = try expand(alloc, b_raw, ctx);
                            defer alloc.free(b_exp);
                            try result.append(alloc, if (std.mem.eql(u8, a_exp, b_exp)) '1' else '0');
                        }
                    } else if (content.len > 2 and std.mem.startsWith(u8, content, "l:")) {
                        // Length: #{l:string} -- expand the argument first
                        const body = content[2..];
                        const s_exp = try expand(alloc, body, ctx);
                        defer alloc.free(s_exp);
                        var buf: [16]u8 = undefined;
                        const s = std.fmt.bufPrint(&buf, "{d}", .{s_exp.len}) catch "?";
                        try result.appendSlice(alloc, s);
                    } else {
                        // Plain variable (including numeric fields).
                        try appendVariable(alloc, &result, content, ctx);
                    }
                }
            },
            '[' => {
                // Style: #[fg=red] — pass through for style processing
                try result.append(alloc, '#');
                try result.append(alloc, '[');
                i += 1;
            },
            '(' => {
                if (findCommandEnd(fmt, i + 1)) |end| {
                    const output = try runShellCommand(alloc, fmt[i + 1 .. end]);
                    defer alloc.free(output);
                    try result.appendSlice(alloc, output);
                    i = end + 1;
                } else {
                    try result.appendSlice(alloc, "#(");
                    i += 1;
                }
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

fn appendVariable(alloc: std.mem.Allocator, result: *std.ArrayListAligned(u8, null), name: []const u8, ctx: *const FormatContext) !void {
    if (std.mem.eql(u8, name, "session_id")) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.session_id}) catch "?";
        try result.appendSlice(alloc, s);
    } else if (std.mem.eql(u8, name, "window_index")) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.window_index}) catch "?";
        try result.appendSlice(alloc, s);
    } else if (std.mem.eql(u8, name, "pane_index")) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.pane_index}) catch "?";
        try result.appendSlice(alloc, s);
    } else if (std.mem.eql(u8, name, "pane_pid")) {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{ctx.pane_pid}) catch "?";
        try result.appendSlice(alloc, s);
    } else {
        try result.appendSlice(alloc, resolveVariable(name, ctx));
    }
}

/// Find the first top-level comma in s, respecting nested #{} depth.
fn findComma(s: []const u8) ?usize {
    var depth: usize = 0;
    var j: usize = 0;
    while (j < s.len) {
        if (s[j] == '#' and j + 1 < s.len and s[j + 1] == '{') {
            depth += 1;
            j += 2;
            continue;
        }
        if (s[j] == '}' and depth > 0) {
            depth -= 1;
            j += 1;
            continue;
        }
        if (s[j] == ',' and depth == 0) return j;
        j += 1;
    }
    return null;
}

fn resolveVariable(name: []const u8, ctx: *const FormatContext) []const u8 {
    if (std.mem.eql(u8, name, "session_name")) return ctx.session_name;
    if (std.mem.eql(u8, name, "window_name")) return ctx.window_name;
    if (std.mem.eql(u8, name, "window_flags")) return ctx.window_flags;
    if (std.mem.eql(u8, name, "pane_title")) return ctx.pane_title;
    if (std.mem.eql(u8, name, "pane_current_path")) return ctx.pane_current_path;
    if (std.mem.eql(u8, name, "host")) return ctx.host;
    if (std.mem.eql(u8, name, "client_name")) return ctx.client_name;
    return "";
}

fn appendTimeFormatSegment(alloc: std.mem.Allocator, result: *std.ArrayListAligned(u8, null), fmt_segment: []const u8) !void {
    if (fmt_segment.len == 0) return;

    const fmt_z = try alloc.dupeZ(u8, fmt_segment);
    defer alloc.free(fmt_z);

    var now: i64 = 0;
    _ = time(&now);
    const tm = localtime(&now) orelse {
        try result.appendSlice(alloc, fmt_segment);
        return;
    };

    var buf: [128]u8 = undefined;
    const written = strftime(&buf, buf.len, fmt_z, tm);
    if (written == 0) {
        try result.appendSlice(alloc, fmt_segment);
        return;
    }
    try result.appendSlice(alloc, buf[0..written]);
}

fn findCommandEnd(fmt: []const u8, start: usize) ?usize {
    var depth: usize = 1;
    var i = start;
    var quote: ?u8 = null;
    var escaped = false;

    while (i < fmt.len) : (i += 1) {
        const ch = fmt[i];
        if (escaped) {
            escaped = false;
            continue;
        }

        if (ch == '\\') {
            escaped = true;
            continue;
        }

        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }

        if (ch == '\'' or ch == '"' or ch == '`') {
            quote = ch;
            continue;
        }

        if (ch == '(') {
            depth += 1;
            continue;
        }

        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }

    return null;
}

fn runShellCommand(alloc: std.mem.Allocator, command: []const u8) ![]u8 {
    if (command.len == 0) return try alloc.alloc(u8, 0);

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return error.PipeFailed;
    errdefer {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
    }

    const cmd_z = try alloc.dupeZ(u8, command);
    defer alloc.free(cmd_z);

    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;

    if (pid == 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.dup2(pipe_fds[1], 1);
        _ = std.c.close(pipe_fds[1]);

        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z.ptr };
        _ = execvp(sh, &argv);
        std.c.exit(127);
    }

    _ = std.c.close(pipe_fds[1]);

    var output: std.ArrayListAligned(u8, null) = .empty;
    errdefer output.deinit(alloc);

    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(pipe_fds[0], &buf, buf.len);
        if (n <= 0) break;
        try output.appendSlice(alloc, buf[0..@intCast(n)]);
    }
    _ = std.c.close(pipe_fds[0]);

    var status: i32 = 0;
    _ = std.c.waitpid(pid, &status, 0);

    const sanitized = sanitizeCommandOutput(output.items);
    const owned = try alloc.dupe(u8, sanitized);
    output.deinit(alloc);
    return owned;
}

fn sanitizeCommandOutput(raw: []const u8) []const u8 {
    const newline = std.mem.indexOfAny(u8, raw, "\r\n") orelse raw.len;
    var end = newline;
    while (end > 0 and (raw[end - 1] == ' ' or raw[end - 1] == '\t')) : (end -= 1) {}
    return raw[0..end];
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

test "expand conditional true" {
    const ctx = FormatContext{
        .session_name = "main",
    };
    const result = try expand(std.testing.allocator, "#{?session_name,yes,no}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("yes", result);
}

test "expand conditional false" {
    const ctx = FormatContext{
        .session_name = "",
    };
    const result = try expand(std.testing.allocator, "#{?session_name,yes,no}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("no", result);
}

test "expand comparison equal" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "#{==:foo,foo}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("1", result);
}

test "expand comparison not equal" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "#{==:foo,bar}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("0", result);
}

test "expand string length" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "#{l:hello}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("5", result);
}

test "expand numeric long form" {
    const ctx = FormatContext{
        .window_index = 3,
        .pane_index = 1,
        .session_id = 7,
    };
    const result = try expand(std.testing.allocator, "#{window_index}.#{pane_index} s#{session_id}", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("3.1 s7", result);
}

test "expand window flags token" {
    const ctx = FormatContext{
        .window_index = 2,
        .window_name = "shell",
        .window_flags = "*",
    };
    const result = try expand(std.testing.allocator, "#I:#W#F", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("2:shell*", result);
}

test "expand strftime segment" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, " %H:%M", &ctx);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqual(@as(usize, 6), result.len);
    try std.testing.expectEqual(@as(u8, ' '), result[0]);
    try std.testing.expectEqual(@as(u8, ':'), result[3]);
}

test "expand shell command segment" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "#(printf status-ok)", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("status-ok", result);
}

test "expand shell command preserves inline styles around output" {
    const ctx = FormatContext{};
    const result = try expand(std.testing.allocator, "#[fg=green]#(printf up)#[default]", &ctx);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings("#[fg=green]up#[default]", result);
}
