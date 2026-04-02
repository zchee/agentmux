const std = @import("std");
const builtin = @import("builtin");
const log = @import("core/log.zig");

// C functions not in std.c
const c = struct {
    extern "c" fn openpty(
        amaster: *std.c.fd_t,
        aslave: *std.c.fd_t,
        name: ?[*]u8,
        termp: ?*const anyopaque,
        winp: ?*const anyopaque,
    ) i32;

    extern "c" fn execvp(
        file: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
    ) i32;
};

/// PTY management for a terminal pane.
pub const Pty = struct {
    master_fd: std.c.fd_t,
    slave_fd: std.c.fd_t,
    pid: std.c.pid_t,
    tty_name: [256]u8,
    tty_name_len: usize,

    pub const Error = error{
        ForkptyFailed,
        ExecFailed,
        SetNonBlockFailed,
    };

    /// Open a new PTY pair.
    pub fn openPty() !Pty {
        var master: std.c.fd_t = -1;
        var slave: std.c.fd_t = -1;
        var name_buf: [256]u8 = .{0} ** 256;

        const result = c.openpty(&master, &slave, &name_buf, null, null);
        if (result != 0) return Error.ForkptyFailed;

        setNonBlocking(master) catch {
            _ = std.c.close(master);
            _ = std.c.close(slave);
            return Error.SetNonBlockFailed;
        };

        const name_len = std.mem.indexOfScalar(u8, &name_buf, 0) orelse name_buf.len;

        return .{
            .master_fd = master,
            .slave_fd = slave,
            .pid = 0,
            .tty_name = name_buf,
            .tty_name_len = name_len,
        };
    }

    /// Fork a child process attached to this PTY.
    pub fn forkExec(self: *Pty, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
        const pid = std.c.fork();
        if (pid < 0) return Error.ForkptyFailed;

        if (pid == 0) {
            // Child process
            _ = std.c.close(self.master_fd);
            _ = std.c.setsid();

            // Set controlling terminal (TIOCSCTTY)
            // TIOCSCTTY - set controlling terminal
            const TIOCSCTTY = if (builtin.os.tag == .linux) @as(i32, 0x540E) else @as(i32, @bitCast(@as(u32, 0x20007461)));
            _ = std.c.ioctl(self.slave_fd, TIOCSCTTY, @as(usize, 0));

            // Redirect stdio
            _ = std.c.dup2(self.slave_fd, 0);
            _ = std.c.dup2(self.slave_fd, 1);
            _ = std.c.dup2(self.slave_fd, 2);
            if (self.slave_fd > 2) {
                _ = std.c.close(self.slave_fd);
            }

            if (cwd) |dir| {
                _ = std.c.chdir(dir);
            }

            const argv = [_:null]?[*:0]const u8{shell.ptr};
            _ = c.execvp(shell.ptr, &argv);
            std.c.exit(1);
        }

        // Parent
        self.pid = pid;
        _ = std.c.close(self.slave_fd);
        self.slave_fd = -1;
    }

    /// Read data from the PTY master.
    pub fn read(self: *Pty, buf: []u8) usize {
        const n = std.c.read(self.master_fd, buf.ptr, buf.len);
        if (n <= 0) return 0;
        return @intCast(n);
    }

    /// Write data to the PTY master.
    pub fn write(self: *Pty, data: []const u8) usize {
        const n = std.c.write(self.master_fd, data.ptr, data.len);
        if (n <= 0) return 0;
        return @intCast(n);
    }

    /// Resize the PTY.
    pub fn resize(self: *Pty, cols: u16, rows: u16) void {
        const ws = std.posix.winsize{
            .col = cols,
            .row = rows,
            .xpixel = 0,
            .ypixel = 0,
        };
        // TIOCSWINSZ - set window size
        const TIOCSWINSZ = if (builtin.os.tag == .linux) @as(i32, 0x5414) else @as(i32, @bitCast(@as(u32, 0x80087467)));
        _ = std.c.ioctl(self.master_fd, TIOCSWINSZ, @intFromPtr(&ws));
    }

    /// Close the PTY and wait for child.
    pub fn close(self: *Pty) void {
        if (self.master_fd >= 0) {
            _ = std.c.close(self.master_fd);
            self.master_fd = -1;
        }
        if (self.slave_fd >= 0) {
            _ = std.c.close(self.slave_fd);
            self.slave_fd = -1;
        }
        if (self.pid > 0) {
            _ = std.c.waitpid(self.pid, null, 0);
            self.pid = 0;
        }
    }

    pub fn ttyName(self: *const Pty) []const u8 {
        return self.tty_name[0..self.tty_name_len];
    }
};

fn setNonBlocking(fd: std.c.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return Pty.Error.SetNonBlockFailed;
    const result = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(i32, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (result < 0) return Pty.Error.SetNonBlockFailed;
}
