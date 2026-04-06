const std = @import("std");
const colour = @import("../core/colour.zig");

/// Terminal output writer.
/// Buffers escape sequences and text to be written to a file descriptor.
pub const Output = struct {
    buf: [8192]u8 = undefined,
    len: usize = 0,
    fd: std.c.fd_t,

    pub fn init(fd: std.c.fd_t) Output {
        return .{ .fd = fd };
    }

    /// Flush buffered output to the fd.
    pub fn flush(self: *Output) void {
        if (self.len == 0) return;
        _ = std.c.write(self.fd, &self.buf, self.len);
        self.len = 0;
    }

    /// Write raw bytes, flushing if buffer is full.
    pub fn writeBytes(self: *Output, data: []const u8) void {
        var remaining = data;
        while (remaining.len > 0) {
            const space = self.buf.len - self.len;
            if (space == 0) {
                self.flush();
                continue;
            }
            const n = @min(remaining.len, space);
            @memcpy(self.buf[self.len..][0..n], remaining[0..n]);
            self.len += n;
            remaining = remaining[n..];
        }
    }

    /// Write a formatted string.
    pub fn print(self: *Output, comptime fmt: []const u8, args: anytype) void {
        var tmp: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, fmt, args) catch return;
        self.writeBytes(s);
    }

    // -- Cursor movement --

    /// Move cursor to (col, row), 0-based.
    pub fn cursorTo(self: *Output, col: u32, row: u32) void {
        self.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    /// Move cursor up by n.
    pub fn cursorUp(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}A", .{n});
    }

    /// Move cursor down by n.
    pub fn cursorDown(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}B", .{n});
    }

    /// Move cursor forward by n.
    pub fn cursorForward(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}C", .{n});
    }

    /// Move cursor back by n.
    pub fn cursorBack(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}D", .{n});
    }

    // -- Attributes --

    /// Reset all attributes.
    pub fn attrReset(self: *Output) void {
        self.writeBytes("\x1b[0m");
    }

    /// Set foreground color.
    pub fn setFg(self: *Output, c: colour.Colour) void {
        self.writeSgrColour(c, true);
    }

    /// Set background color.
    pub fn setBg(self: *Output, c: colour.Colour) void {
        self.writeSgrColour(c, false);
    }

    fn writeSgrColour(self: *Output, c: colour.Colour, is_fg: bool) void {
        var tmp: [32]u8 = undefined;
        const s = switch (c) {
            .default => std.fmt.bufPrint(&tmp, "\x1b[{d}m", .{if (is_fg) @as(u8, 39) else @as(u8, 49)}) catch return,
            .palette => |idx| blk: {
                if (idx < 8) {
                    break :blk std.fmt.bufPrint(&tmp, "\x1b[{d}m", .{(if (is_fg) @as(u8, 30) else @as(u8, 40)) + idx}) catch return;
                } else if (idx < 16) {
                    break :blk std.fmt.bufPrint(&tmp, "\x1b[{d}m", .{(if (is_fg) @as(u8, 90) else @as(u8, 100)) + idx - 8}) catch return;
                } else {
                    const base: u8 = if (is_fg) 38 else 48;
                    break :blk std.fmt.bufPrint(&tmp, "\x1b[{d};5;{d}m", .{ base, idx }) catch return;
                }
            },
            .rgb => |rgb| blk: {
                const base: u8 = if (is_fg) 38 else 48;
                break :blk std.fmt.bufPrint(&tmp, "\x1b[{d};2;{d};{d};{d}m", .{ base, rgb.r, rgb.g, rgb.b }) catch return;
            },
        };
        self.writeBytes(s);
    }

    /// Set attributes (bold, italic, etc.).
    pub fn setAttrs(self: *Output, attrs: colour.Attributes) void {
        if (attrs.bold) self.writeBytes("\x1b[1m");
        if (attrs.dim) self.writeBytes("\x1b[2m");
        if (attrs.italic) self.writeBytes("\x1b[3m");
        if (attrs.underline) self.writeBytes("\x1b[4m");
        if (attrs.blink) self.writeBytes("\x1b[5m");
        if (attrs.reverse) self.writeBytes("\x1b[7m");
        if (attrs.hidden) self.writeBytes("\x1b[8m");
        if (attrs.strikethrough) self.writeBytes("\x1b[9m");
    }

    // -- Screen operations --

    /// Clear entire screen.
    pub fn clearScreen(self: *Output) void {
        self.writeBytes("\x1b[2J");
    }

    /// Clear from cursor to end of screen.
    pub fn clearToEnd(self: *Output) void {
        self.writeBytes("\x1b[J");
    }

    /// Clear from cursor to end of line.
    pub fn clearToEol(self: *Output) void {
        self.writeBytes("\x1b[K");
    }

    /// Clear entire line.
    pub fn clearLine(self: *Output) void {
        self.writeBytes("\x1b[2K");
    }

    /// Set scroll region.
    pub fn setScrollRegion(self: *Output, top: u32, bottom: u32) void {
        self.print("\x1b[{d};{d}r", .{ top + 1, bottom + 1 });
    }

    /// Scroll up by n lines.
    pub fn scrollUp(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}S", .{n});
    }

    /// Scroll down by n lines.
    pub fn scrollDown(self: *Output, n: u32) void {
        if (n > 0) self.print("\x1b[{d}T", .{n});
    }

    // -- Cursor visibility --

    pub fn hideCursor(self: *Output) void {
        self.writeBytes("\x1b[?25l");
    }

    pub fn showCursor(self: *Output) void {
        self.writeBytes("\x1b[?25h");
    }

    /// Set cursor style via DECSCUSR (ESC [ Ps SP q).
    pub fn setCursorStyle(self: *Output, style: u3) void {
        self.print("\x1b[{d} q", .{@as(u32, style)});
    }

    // -- Alternate screen buffer --

    pub fn enterAltScreen(self: *Output) void {
        self.writeBytes("\x1b[?1049h");
    }

    pub fn leaveAltScreen(self: *Output) void {
        self.writeBytes("\x1b[?1049l");
    }

    // -- Mouse --

    pub fn enableMouseSGR(self: *Output) void {
        self.writeBytes("\x1b[?1006h");
    }

    pub fn disableMouseSGR(self: *Output) void {
        self.writeBytes("\x1b[?1006l");
    }

    pub fn enableMouseAll(self: *Output) void {
        self.writeBytes("\x1b[?1003h");
    }

    pub fn disableMouseAll(self: *Output) void {
        self.writeBytes("\x1b[?1003l");
    }

    // -- Bracketed paste --

    pub fn enableBracketedPaste(self: *Output) void {
        self.writeBytes("\x1b[?2004h");
    }

    pub fn disableBracketedPaste(self: *Output) void {
        self.writeBytes("\x1b[?2004l");
    }

    // -- Title --

    pub fn setTitle(self: *Output, title: []const u8) void {
        self.writeBytes("\x1b]0;");
        self.writeBytes(title);
        self.writeBytes("\x07");
    }
};
