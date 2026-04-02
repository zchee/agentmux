const std = @import("std");

/// Log levels matching syslog severity.
pub const Level = enum(u3) {
    err = 3,
    warn = 4,
    info = 6,
    debug = 7,
};

var log_level: Level = .info;
var log_fd: std.c.fd_t = -1;
var log_stderr: bool = false;

pub fn init(level: Level, file_path: ?[]const u8, stderr: bool) void {
    log_level = level;
    log_stderr = stderr;
    if (file_path) |path| {
        // Open log file for append
        var path_buf: [4096]u8 = undefined;
        if (path.len < path_buf.len) {
            @memcpy(path_buf[0..path.len], path);
            path_buf[path.len] = 0;
            const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
            log_fd = std.c.open(cpath, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o644));
        }
    }
}

pub fn deinit() void {
    if (log_fd >= 0) {
        _ = std.c.close(log_fd);
        log_fd = -1;
    }
}

pub fn setLevel(level: Level) void {
    log_level = level;
}

fn writeFd(fd: std.c.fd_t, data: []const u8) void {
    _ = std.c.write(fd, data.ptr, data.len);
}

fn writeLog(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(level) > @intFromEnum(log_level)) return;

    const prefix = switch (level) {
        .err => "ERR",
        .warn => "WRN",
        .info => "INF",
        .debug => "DBG",
    };

    const fd: std.c.fd_t = if (log_fd >= 0)
        log_fd
    else if (log_stderr)
        2 // stderr
    else
        return;

    // Format into a stack buffer
    var buf: [4096]u8 = undefined;
    const header = std.fmt.bufPrint(&buf, "[{s}] ", .{prefix}) catch return;
    writeFd(fd, header);

    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    writeFd(fd, msg);
    writeFd(fd, "\n");
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    writeLog(.err, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    writeLog(.warn, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    writeLog(.info, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    writeLog(.debug, fmt, args);
}

/// Fatal logs an error and aborts.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    writeLog(.err, fmt, args);
    // Also write to stderr
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "fatal: " ++ fmt ++ "\n", args) catch "fatal: unknown error\n";
    writeFd(2, msg);
    std.c.abort();
}
