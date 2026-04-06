const std = @import("std");

/// Control mode client state.
/// In control mode, tmux/zmux outputs machine-readable notifications
/// instead of terminal rendering. Used by tmux plugins and integrations.
pub const ControlClient = struct {
    fd: std.c.fd_t,
    active: bool,
    pause_age: u32,

    pub fn init(fd: std.c.fd_t) ControlClient {
        return .{
            .fd = fd,
            .active = true,
            .pause_age = 0,
        };
    }

    /// Write a control mode line.
    fn writeLine(self: *ControlClient, line: []const u8) void {
        if (!self.active) return;
        _ = std.c.write(self.fd, line.ptr, line.len);
        _ = std.c.write(self.fd, "\n", 1);
    }

    fn sendGuard(self: *ControlClient, comptime prefix: []const u8, time_val: i64, number: u32, flags: u32) void {
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{s} {d} {d} {d}", .{ prefix, time_val, number, flags }) catch return;
        self.writeLine(line);
    }

    /// Send a %begin guard.
    pub fn sendBegin(self: *ControlClient, time_val: i64, number: u32, flags: u32) void {
        self.sendGuard("%begin", time_val, number, flags);
    }

    /// Send an %end guard.
    pub fn sendEnd(self: *ControlClient, time_val: i64, number: u32, flags: u32) void {
        self.sendGuard("%end", time_val, number, flags);
    }

    /// Send a %error guard.
    pub fn sendError(self: *ControlClient, time_val: i64, number: u32, flags: u32) void {
        self.sendGuard("%error", time_val, number, flags);
    }

    /// Send %output notification.
    pub fn sendOutput(self: *ControlClient, pane_id: u32, data: []const u8) void {
        var buf: [64]u8 = undefined;
        const header = std.fmt.bufPrint(&buf, "%output %{d} ", .{pane_id}) catch return;
        _ = std.c.write(self.fd, header.ptr, header.len);
        // Encode data: escape special characters
        for (data) |byte| {
            if (byte == '\\') {
                _ = std.c.write(self.fd, "\\\\", 2);
            } else if (byte < 0x20 or byte == 0x7f) {
                var esc: [4]u8 = undefined;
                const s = std.fmt.bufPrint(&esc, "\\{o:0>3}", .{byte}) catch continue;
                _ = std.c.write(self.fd, s.ptr, s.len);
            } else {
                _ = std.c.write(self.fd, &.{byte}, 1);
            }
        }
        _ = std.c.write(self.fd, "\n", 1);
    }

    /// Send %session-changed notification.
    pub fn sendSessionChanged(self: *ControlClient, session_id: u32, session_name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%session-changed ${d} {s}", .{ session_id, session_name }) catch return;
        self.writeLine(line);
    }

    /// Send %window-add notification.
    pub fn sendWindowAdd(self: *ControlClient, window_id: u32) void {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%window-add @{d}", .{window_id}) catch return;
        self.writeLine(line);
    }

    /// Send %window-close notification.
    pub fn sendWindowClose(self: *ControlClient, window_id: u32) void {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%window-close @{d}", .{window_id}) catch return;
        self.writeLine(line);
    }

    /// Send %window-renamed notification.
    pub fn sendWindowRenamed(self: *ControlClient, window_id: u32, new_name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%window-renamed @{d} {s}", .{ window_id, new_name }) catch return;
        self.writeLine(line);
    }

    /// Send %layout-change notification.
    pub fn sendLayoutChange(self: *ControlClient, window_id: u32, layout_str: []const u8) void {
        var buf: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%layout-change @{d} {s}", .{ window_id, layout_str }) catch return;
        self.writeLine(line);
    }

    /// Send %client-detached notification.
    pub fn sendClientDetached(self: *ControlClient, client_name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%client-detached {s}", .{client_name}) catch return;
        self.writeLine(line);
    }

    /// Send %client-session-changed notification.
    pub fn sendClientSessionChanged(self: *ControlClient, client_name: []const u8, session_id: u32, session_name: []const u8) void {
        var buf: [256]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%client-session-changed {s} ${d} {s}", .{ client_name, session_id, session_name }) catch return;
        self.writeLine(line);
    }

    /// Send %pane-mode-changed notification.
    pub fn sendPaneModeChanged(self: *ControlClient, pane_id: u32) void {
        var buf: [64]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "%pane-mode-changed %{d}", .{pane_id}) catch return;
        self.writeLine(line);
    }

    /// Send %exit notification (server shutting down).
    pub fn sendExit(self: *ControlClient) void {
        self.writeLine("%exit");
    }

    /// Deactivate control mode.
    pub fn deactivate(self: *ControlClient) void {
        self.active = false;
    }
};

test "control output encoding" {
    // Just verify the struct compiles and methods exist
    var ctrl = ControlClient.init(1);
    try std.testing.expect(ctrl.active);
    ctrl.deactivate();
    try std.testing.expect(!ctrl.active);
}

test "control guards and exit use tmux-like line format" {
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctrl = ControlClient.init(fds[1]);
    ctrl.sendBegin(123, 7, 0);
    ctrl.sendEnd(123, 7, 0);
    ctrl.sendError(123, 7, 0);
    ctrl.sendExit();

    var buf: [256]u8 = undefined;
    const n = std.c.read(fds[0], &buf, buf.len);
    try std.testing.expect(n > 0);
    const output = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, output, "%begin 123 7 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "%end 123 7 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "%error 123 7 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "%exit\n") != null);
}
