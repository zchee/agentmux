const std = @import("std");
const builtin = @import("builtin");
const Screen = @import("screen/screen.zig").Screen;
const log = @import("core/log.zig");

/// PTY management for a terminal pane.
/// Handles forking a child process with a pseudo-terminal.
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

    /// Open a new PTY pair without forking.
    pub fn openPty() !Pty {
        var master: std.c.fd_t = -1;
        var slave: std.c.fd_t = -1;
        var name_buf: [256]u8 = .{0} ** 256;

        const result = std.c.openpty(&master, &slave, &name_buf, null, null);
        if (result != 0) return Error.ForkptyFailed;

        // Set master to non-blocking
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
    /// The child will exec the given shell.
    pub fn forkExec(self: *Pty, shell: [:0]const u8, cwd: ?[:0]const u8) !void {
        const pid = std.c.fork();
        if (pid < 0) return Error.ForkptyFailed;

        if (pid == 0) {
            // Child process
            _ = std.c.close(self.master_fd);

            // Create new session
            _ = std.c.setsid();

            // Set controlling terminal
            _ = std.c.ioctl(self.slave_fd, std.posix.T.IOCSCTTY, @as(std.c.ulong, 0));

            // Redirect stdio to slave PTY
            _ = std.c.dup2(self.slave_fd, 0);
            _ = std.c.dup2(self.slave_fd, 1);
            _ = std.c.dup2(self.slave_fd, 2);
            if (self.slave_fd > 2) {
                _ = std.c.close(self.slave_fd);
            }

            // Change directory if requested
            if (cwd) |dir| {
                _ = std.c.chdir(dir);
            }

            // Exec shell
            const argv = [_:null]?[*:0]const u8{ shell.ptr, null };
            _ = std.c.execvp(shell.ptr, &argv);

            // If exec fails, exit
            std.c.exit(1);
        }

        // Parent process
        self.pid = pid;
        _ = std.c.close(self.slave_fd);
        self.slave_fd = -1;
    }

    /// Read data from the PTY master.
    /// Returns the number of bytes read, or 0 on EOF/EAGAIN.
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
        const ws = std.c.winsize{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = std.c.ioctl(self.master_fd, std.posix.T.IOCSWINSZ, @intFromPtr(&ws));
    }

    /// Close the PTY master fd and wait for the child.
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

    /// Get the tty name as a slice.
    pub fn ttyName(self: *const Pty) []const u8 {
        return self.tty_name[0..self.tty_name_len];
    }
};

fn setNonBlocking(fd: std.c.fd_t) !void {
    const flags = std.c.fcntl(fd, std.c.F.GETFL);
    if (flags < 0) return Pty.Error.SetNonBlockFailed;
    const result = std.c.fcntl(fd, std.c.F.SETFL, flags | @as(std.c.int, @bitCast(std.c.O{ .NONBLOCK = true })));
    if (result < 0) return Pty.Error.SetNonBlockFailed;
}

