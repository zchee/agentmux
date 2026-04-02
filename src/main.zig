const std = @import("std");
const builtin = @import("builtin");

pub const core = struct {
    pub const allocator_mod = @import("core/allocator.zig");
    pub const colour = @import("core/colour.zig");
    pub const environ = @import("core/environ.zig");
    pub const event_loop = @import("core/event_loop.zig");
    pub const log = @import("core/log.zig");
    pub const utf8 = @import("core/utf8.zig");
};

pub const platform = @import("platform/platform.zig");
pub const protocol = @import("protocol.zig");
pub const layout = struct {
    pub const core = @import("layout/layout.zig");
    pub const set = @import("layout/set.zig");
};
pub const window_mod = @import("window.zig");
pub const session_mod = @import("session.zig");
pub const terminal = struct {
    pub const acs = @import("terminal/acs.zig");
    pub const features = @import("terminal/features.zig");
    pub const input = @import("terminal/input.zig");
    pub const keys = @import("terminal/keys.zig");
    pub const output = @import("terminal/output.zig");
    pub const terminfo = @import("terminal/terminfo.zig");
};
pub const screen = struct {
    pub const grid = @import("screen/grid.zig");
    pub const screen_mod = @import("screen/screen.zig");
    pub const writer = @import("screen/writer.zig");
    pub const redraw = @import("screen/redraw.zig");
};
pub const config = struct {
    pub const parser = @import("config/parser.zig");
    pub const options = @import("config/options.zig");
    pub const options_table = @import("config/options_table.zig");
};
pub const pane_mod = @import("pane.zig");
pub const server_mod = @import("server.zig");
pub const client_mod = @import("client.zig");
pub const cmd = @import("cmd/cmd.zig");
pub const keybind = @import("keybind/bindings.zig");
pub const mode = struct {
    pub const tree = @import("mode/tree.zig");
};
pub const control = @import("control/control.zig");
pub const status = struct {
    pub const style = @import("status/style.zig");
    pub const format_mod = @import("status/format.zig");
    pub const status_mod = @import("status/status.zig");
};
pub const copy = struct {
    pub const copy_mod = @import("copy/copy.zig");
    pub const paste = @import("copy/paste.zig");
};

const log = core.log;

const version_string = "zmux 0.1.0";
const default_socket_name = "default";

/// Write a string to stdout.
fn writeStdout(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

/// Write a string to stderr.
fn writeStderr(s: []const u8) void {
    _ = std.c.write(2, s.ptr, s.len);
}

/// Command-line flags.
const Flags = struct {
    force_256: bool = false,
    control_mode: bool = false,
    shell_command: ?[:0]const u8 = null,
    no_daemon: bool = false,
    config_file: ?[:0]const u8 = null,
    socket_name: ?[:0]const u8 = null,
    socket_path: ?[:0]const u8 = null,
    utf8_flag: bool = false,
    verbose: u8 = 0,
    print_version: bool = false,
    remaining: std.ArrayListAligned([:0]const u8, null),

    fn deinit(self: *Flags, alloc: std.mem.Allocator) void {
        self.remaining.deinit(alloc);
    }
};

fn parseArgs(alloc: std.mem.Allocator, init_args: std.process.Args) Flags {
    var flags = Flags{ .remaining = .empty };
    var args = std.process.Args.Iterator.init(init_args);

    // Skip argv[0]
    _ = args.next();

    while (args.next()) |arg| {
        if (arg.len < 2 or arg[0] != '-') {
            flags.remaining.append(alloc, arg) catch {};
            while (args.next()) |rest| {
                flags.remaining.append(alloc, rest) catch {};
            }
            break;
        }
        for (arg[1..]) |c| {
            switch (c) {
                '2' => flags.force_256 = true,
                'C' => flags.control_mode = true,
                'D' => flags.no_daemon = true,
                'u' => flags.utf8_flag = true,
                'v' => flags.verbose +|= 1,
                'V' => flags.print_version = true,
                'c' => {
                    flags.shell_command = args.next();
                    break;
                },
                'f' => {
                    flags.config_file = args.next();
                    break;
                },
                'L' => {
                    flags.socket_name = args.next();
                    break;
                },
                'S' => {
                    flags.socket_path = args.next();
                    break;
                },
                else => {},
            }
        }
    }
    return flags;
}

pub fn main(init: std.process.Init.Minimal) !void {
    var zmux_alloc = core.allocator_mod.ZmuxAllocator.init();
    defer zmux_alloc.deinit();
    const alloc = zmux_alloc.allocator();

    var flags = parseArgs(alloc, init.args);
    defer flags.deinit(alloc);

    if (flags.print_version) {
        writeStdout(version_string ++ "\n");
        return;
    }

    // Initialize logging
    const log_level: log.Level = switch (flags.verbose) {
        0 => .info,
        else => .debug,
    };
    log.init(log_level, null, flags.verbose > 0);
    defer log.deinit();

    log.info("zmux starting (pid={d})", .{std.c.getpid()});

    // Determine socket path
    const socket_dir = try platform.defaultSocketDir(alloc);
    defer alloc.free(socket_dir);

    const socket_name: []const u8 = if (flags.socket_name) |sn| sn else default_socket_name;
    const socket_path = if (flags.socket_path) |p|
        try alloc.dupe(u8, p)
    else
        try std.fmt.allocPrint(alloc, "{s}/zmux-{d}/{s}", .{
            socket_dir,
            std.c.getuid(),
            socket_name,
        });
    defer alloc.free(socket_path);

    log.info("socket path: {s}", .{socket_path});

    // TODO: Dispatch to server or client based on command.
    const msg = try std.fmt.allocPrint(alloc, "{s} - socket: {s}\n", .{ version_string, socket_path });
    defer alloc.free(msg);
    writeStdout(msg);
}

test {
    _ = core.utf8;
    _ = core.colour;
    _ = core.environ;
    _ = protocol;
    _ = layout.core;
    _ = layout.set;
    _ = window_mod;
    _ = terminal.input;
    _ = terminal.keys;
    _ = screen.grid;
    _ = screen.screen_mod;
    _ = screen.writer;
    _ = config.parser;
    _ = config.options;
    _ = config.options_table;
    _ = cmd;
    _ = keybind;
    _ = terminal.acs;
    _ = terminal.features;
    _ = mode.tree;
    _ = copy.copy_mod;
    _ = copy.paste;
    _ = control;
    _ = status.style;
    _ = status.format_mod;
    _ = status.status_mod;
    _ = screen.redraw;
}
