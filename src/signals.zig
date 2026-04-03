const std = @import("std");
const builtin = @import("builtin");
const log = @import("core/log.zig");

/// Signal handler state.
pub const SignalHandler = struct {
    winch_received: bool = false,
    term_received: bool = false,
    hup_received: bool = false,
    usr1_received: bool = false,

    // C signal handler declarations
    const sigaction_fn = struct {
        const Sigaction = extern struct {
            handler: ?*const fn (i32) callconv(.c) void,
            mask: [4]u32 = .{ 0, 0, 0, 0 },
            flags: i32 = 0,
        };
        extern "c" fn sigaction(sig: i32, act: ?*const Sigaction, oact: ?*Sigaction) i32;
    };

    // Signal numbers
    const SIGWINCH: i32 = if (builtin.os.tag == .linux) 28 else 28;
    const SIGTERM: i32 = 15;
    const SIGHUP: i32 = 1;
    const SIGUSR1: i32 = if (builtin.os.tag == .linux) 10 else 30;
    const SIGPIPE: i32 = 13;

    // Global state for C signal handlers (must be global since C callbacks have no context)
    var global: SignalHandler = .{};

    fn handleWinch(_: i32) callconv(.c) void {
        global.winch_received = true;
    }

    fn handleTerm(_: i32) callconv(.c) void {
        global.term_received = true;
    }

    fn handleHup(_: i32) callconv(.c) void {
        global.hup_received = true;
    }

    fn handleUsr1(_: i32) callconv(.c) void {
        global.usr1_received = true;
    }

    /// Install signal handlers.
    pub fn install() void {
        const winch_act = sigaction_fn.Sigaction{ .handler = handleWinch };
        const term_act = sigaction_fn.Sigaction{ .handler = handleTerm };
        const hup_act = sigaction_fn.Sigaction{ .handler = handleHup };
        const usr1_act = sigaction_fn.Sigaction{ .handler = handleUsr1 };
        _ = sigaction_fn.sigaction(SIGWINCH, &winch_act, null);
        _ = sigaction_fn.sigaction(SIGTERM, &term_act, null);
        _ = sigaction_fn.sigaction(SIGHUP, &hup_act, null);
        _ = sigaction_fn.sigaction(SIGUSR1, &usr1_act, null);
        _ = sigaction_fn.sigaction(SIGPIPE, null, null);
    }

    /// Check and clear SIGWINCH.
    pub fn checkWinch() bool {
        if (global.winch_received) {
            global.winch_received = false;
            return true;
        }
        return false;
    }

    /// Check and clear SIGTERM.
    pub fn checkTerm() bool {
        if (global.term_received) {
            global.term_received = false;
            return true;
        }
        return false;
    }

    /// Check and clear SIGHUP.
    pub fn checkHup() bool {
        if (global.hup_received) {
            global.hup_received = false;
            return true;
        }
        return false;
    }

    /// Check if any termination signal was received.
    pub fn shouldExit() bool {
        return global.term_received or global.hup_received;
    }

    /// Reset all signal flags.
    pub fn reset() void {
        global = .{};
    }
};

/// Daemonize the server process.
/// Forks, creates new session, closes stdio.
pub fn daemonize() !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid > 0) {
        // Parent exits
        std.c.exit(0);
    }

    // Child: create new session
    _ = std.c.setsid();

    // Second fork to prevent controlling terminal acquisition
    const pid2 = std.c.fork();
    if (pid2 < 0) return error.ForkFailed;
    if (pid2 > 0) {
        std.c.exit(0);
    }

    // Close standard file descriptors
    _ = std.c.close(0);
    _ = std.c.close(1);
    _ = std.c.close(2);

    // Redirect to /dev/null
    const devnull: [*:0]const u8 = "/dev/null";
    _ = std.c.open(devnull, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    _ = std.c.dup2(0, 1);
    _ = std.c.dup2(0, 2);
}

test "signal handler install" {
    // Just verify it compiles and doesn't crash
    SignalHandler.reset();
    try std.testing.expect(!SignalHandler.checkWinch());
    try std.testing.expect(!SignalHandler.checkTerm());
    try std.testing.expect(!SignalHandler.shouldExit());
}
