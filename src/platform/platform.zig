const std = @import("std");
const builtin = @import("builtin");

pub const darwin = @import("darwin.zig");

pub const Os = enum {
    macos,
    linux,
    unsupported,
};

pub const os: Os = switch (builtin.os.tag) {
    .macos => .macos,
    .linux => .linux,
    else => .unsupported,
};

/// Get an environment variable as a Zig slice.
fn getenv(name: [:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(val, 0);
}

const SocketDirEnv = struct {
    zmux_tmpdir: ?[]const u8 = null,
    xdg_runtime_dir: ?[]const u8 = null,
    tmpdir: ?[]const u8 = null,
};

fn defaultSocketDirFromEnv(alloc: std.mem.Allocator, target_os: Os, env: SocketDirEnv) ![]const u8 {
    const dir = env.zmux_tmpdir orelse switch (target_os) {
        .linux => env.xdg_runtime_dir orelse env.tmpdir orelse "/tmp",
        else => env.tmpdir orelse "/tmp",
    };
    return try alloc.dupe(u8, dir);
}

/// Get the default socket path for zmux.
/// Uses $ZMUX_TMPDIR, Linux $XDG_RUNTIME_DIR, $TMPDIR, or /tmp.
pub fn defaultSocketDir(alloc: std.mem.Allocator) ![]const u8 {
    return defaultSocketDirFromEnv(alloc, os, .{
        .zmux_tmpdir = getenv("ZMUX_TMPDIR"),
        .xdg_runtime_dir = getenv("XDG_RUNTIME_DIR"),
        .tmpdir = getenv("TMPDIR"),
    });
}

/// Get the process name for a given PID.
pub fn getProcessName(alloc: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
    return switch (os) {
        .macos => getProcessNameDarwin(alloc, pid),
        .linux => getProcessNameLinux(alloc, pid),
        .unsupported => null,
    };
}

fn getProcessNameDarwin(alloc: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
    // Use proc_name() from libproc (available via libc on macOS).
    const proc_name_fn = struct {
        extern "c" fn proc_name(pid: i32, buffer: [*]u8, buffersize: u32) i32;
    };
    var name_buf: [256]u8 = undefined;
    const len = proc_name_fn.proc_name(@intCast(pid), &name_buf, name_buf.len);
    if (len <= 0) return null;
    return try alloc.dupe(u8, name_buf[0..@intCast(len)]);
}

fn getProcessNameLinux(alloc: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
    var path_buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    // Use libc to read the file
    var name_buf: [256]u8 = undefined;
    var cpath_buf: [256]u8 = undefined;
    if (path.len >= cpath_buf.len) return null;
    @memcpy(cpath_buf[0..path.len], path);
    cpath_buf[path.len] = 0;
    const cpath: [*:0]const u8 = @ptrCast(cpath_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const n = std.c.read(fd, &name_buf, name_buf.len);
    if (n <= 0) return null;
    const len: usize = @intCast(n);
    const end = if (len > 0 and name_buf[len - 1] == '\n') len - 1 else len;
    return try alloc.dupe(u8, name_buf[0..end]);
}

/// Get the current working directory of a process.
pub fn getProcessCwd(alloc: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
    return switch (os) {
        .macos => getProcessCwdDarwin(alloc, pid),
        .linux => getProcessCwdLinux(alloc, pid),
        .unsupported => null,
    };
}

fn getProcessCwdDarwin(_: std.mem.Allocator, _: std.posix.pid_t) !?[]const u8 {
    return null;
}

fn getProcessCwdLinux(alloc: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
    var buf: [64]u8 = undefined;
    const link = std.fmt.bufPrint(&buf, "/proc/{d}/cwd", .{pid}) catch return null;
    var cpath_buf: [64]u8 = undefined;
    if (link.len >= cpath_buf.len) return null;
    @memcpy(cpath_buf[0..link.len], link);
    cpath_buf[link.len] = 0;
    const cpath: [*:0]const u8 = @ptrCast(cpath_buf[0..link.len :0]);
    var target_buf: [4096]u8 = undefined;
    const n = std.c.readlink(cpath, &target_buf, target_buf.len);
    if (n < 0) return null;
    const len: usize = @intCast(n);
    return try alloc.dupe(u8, target_buf[0..len]);
}

test "defaultSocketDir prefers Linux XDG runtime dir before TMPDIR" {
    const alloc = std.testing.allocator;
    const dir = try defaultSocketDirFromEnv(alloc, .linux, .{
        .xdg_runtime_dir = "/run/user/1000",
        .tmpdir = "/tmp/zmux-test",
    });
    defer alloc.free(dir);

    try std.testing.expectEqualStrings("/run/user/1000", dir);
}

test "defaultSocketDir ignores Linux XDG runtime dir on macOS" {
    const alloc = std.testing.allocator;
    const dir = try defaultSocketDirFromEnv(alloc, .macos, .{
        .xdg_runtime_dir = "/run/user/1000",
        .tmpdir = "/var/folders/zmux-test",
    });
    defer alloc.free(dir);

    try std.testing.expectEqualStrings("/var/folders/zmux-test", dir);
}

test "defaultSocketDir always honors ZMUX_TMPDIR first" {
    const alloc = std.testing.allocator;
    const dir = try defaultSocketDirFromEnv(alloc, .linux, .{
        .zmux_tmpdir = "/custom/zmux",
        .xdg_runtime_dir = "/run/user/1000",
        .tmpdir = "/tmp/zmux-test",
    });
    defer alloc.free(dir);

    try std.testing.expectEqualStrings("/custom/zmux", dir);
}
