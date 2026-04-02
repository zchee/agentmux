const std = @import("std");
const builtin = @import("builtin");

/// Terminal raw mode state.
/// Saves the original termios settings and restores them on deinit.
pub const RawTerminal = struct {
    original: Termios,
    fd: std.c.fd_t,
    active: bool,

    const Termios = std.c.termios;

    const tcgetattr_fn = struct {
        extern "c" fn tcgetattr(fd: std.c.fd_t, termios_p: *Termios) i32;
    };
    const tcsetattr_fn = struct {
        extern "c" fn tcsetattr(fd: std.c.fd_t, optional_actions: i32, termios_p: *const Termios) i32;
    };

    // tcsetattr optional_actions
    const TCSANOW: i32 = 0;
    const TCSAFLUSH: i32 = 2;

    pub fn init(fd: std.c.fd_t) !RawTerminal {
        var original: Termios = undefined;
        if (tcgetattr_fn.tcgetattr(fd, &original) != 0) {
            return error.TcGetAttrFailed;
        }
        return .{
            .original = original,
            .fd = fd,
            .active = false,
        };
    }

    /// Enter raw mode.
    pub fn enableRaw(self: *RawTerminal) !void {
        var raw = self.original;

        // Input flags: disable break signal, CR->NL, parity, strip, flow control
        raw.iflag &= ~@as(std.c.tc_iflag_t, @bitCast(std.c.IFLAG{
            .BRKINT = true,
            .ICRNL = true,
            .INPCK = true,
            .ISTRIP = true,
            .IXON = true,
        }));

        // Output flags: disable post-processing
        raw.oflag &= ~@as(std.c.tc_oflag_t, @bitCast(std.c.OFLAG{
            .OPOST = true,
        }));

        // Control flags: set 8-bit chars
        raw.cflag |= @as(std.c.tc_cflag_t, @bitCast(std.c.CFLAG{
            .CS8 = true,
        }));

        // Local flags: disable echo, canonical mode, signals, extended input
        raw.lflag &= ~@as(std.c.tc_lflag_t, @bitCast(std.c.LFLAG{
            .ECHO = true,
            .ICANON = true,
            .IEXTEN = true,
            .ISIG = true,
        }));

        // Control chars: read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;

        if (tcsetattr_fn.tcsetattr(self.fd, TCSAFLUSH, &raw) != 0) {
            return error.TcSetAttrFailed;
        }
        self.active = true;
    }

    /// Restore original terminal settings.
    pub fn restore(self: *RawTerminal) void {
        if (self.active) {
            _ = tcsetattr_fn.tcsetattr(self.fd, TCSAFLUSH, &self.original);
            self.active = false;
        }
    }

    /// Deinit restores terminal.
    pub fn deinit(self: *RawTerminal) void {
        self.restore();
    }
};

/// Get the current terminal size.
pub fn getTerminalSize(fd: std.c.fd_t) ?struct { cols: u16, rows: u16 } {
    const TIOCGWINSZ = if (builtin.os.tag == .linux)
        @as(i32, 0x5413)
    else
        @as(i32, @bitCast(@as(u32, 0x40087468)));

    var ws = std.posix.winsize{ .col = 0, .row = 0, .xpixel = 0, .ypixel = 0 };
    if (std.c.ioctl(fd, TIOCGWINSZ, @intFromPtr(&ws)) == 0) {
        if (ws.col > 0 and ws.row > 0) {
            return .{ .cols = ws.col, .rows = ws.row };
        }
    }
    return null;
}

/// Simple I/O relay: read from src_fd, write to dst_fd.
pub fn relay(src_fd: std.c.fd_t, dst_fd: std.c.fd_t) usize {
    var buf: [4096]u8 = undefined;
    const n = std.c.read(src_fd, &buf, buf.len);
    if (n <= 0) return 0;
    const len: usize = @intCast(n);
    _ = std.c.write(dst_fd, &buf, len);
    return len;
}

test "get terminal size" {
    // Just verify the function compiles and doesn't crash
    _ = getTerminalSize(0);
}
