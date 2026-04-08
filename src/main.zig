const std = @import("std");

pub const core = struct {
    pub const allocator_mod = @import("core/allocator.zig");
    pub const colour = @import("core/colour.zig");
    pub const environ = @import("core/environ.zig");
    pub const log = @import("core/log.zig");
    pub const utf8 = @import("core/utf8.zig");
};

pub const platform = struct {
    pub const core = @import("platform/platform.zig");
    pub const std_io = @import("platform/std_io.zig");
};
pub const protocol = @import("protocol.zig");
pub const startup_probe = @import("startup_probe.zig");
pub const layout = struct {
    pub const core = @import("layout/layout.zig");
    pub const set = @import("layout/set.zig");
    pub const custom = @import("layout/custom.zig");
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
    pub const path = @import("config/path.zig");
    pub const options = @import("config/options.zig");
    pub const options_table = @import("config/options_table.zig");
};
pub const input_handler = @import("input_handler.zig");
pub const client_terminal = @import("client_terminal.zig");
pub const server_loop = @import("server_loop.zig");
pub const signals = @import("signals.zig");
pub const clipboard_mod = @import("clipboard.zig");
pub const pane_mod = @import("pane.zig");
pub const server_mod = @import("server.zig");
pub const client_mod = @import("client.zig");
pub const cmd = @import("cmd/cmd.zig");
pub const keybind = struct {
    pub const bindings = @import("keybind/bindings.zig");
    pub const string = @import("keybind/string.zig");
};
pub const render = struct {
    pub const renderer_mod = @import("render/renderer.zig");
    pub const atlas = @import("render/atlas.zig");
    pub const metal = @import("render/metal.zig");
    pub const vulkan = @import("render/vulkan.zig");
    pub const image = @import("render/image.zig");
    pub const sixel = @import("render/sixel.zig");
    pub const kitty = @import("render/kitty.zig");
    pub const shaders = @import("render/shaders.zig");
    pub const font = @import("render/font.zig");
};
pub const mode = struct {
    pub const tree = @import("mode/tree.zig");
};
pub const control = @import("control/control.zig");
pub const hooks = struct {
    pub const hooks_mod = @import("hooks/hooks.zig");
    pub const notify = @import("hooks/notify.zig");
    pub const job = @import("hooks/job.zig");
};
pub const status = struct {
    pub const style = @import("status/style.zig");
    pub const format_mod = @import("status/format.zig");
    pub const status_mod = @import("status/status.zig");
};
pub const copy = struct {
    pub const copy_mod = @import("copy/copy.zig");
    pub const paste = @import("copy/paste.zig");
};
pub const tabs = struct {
    pub const tabs_mod = @import("tabs/tabs.zig");
};

const cmd_tmux_equivalent_test = @import("cmd/tmux_equivalent_test.zig");
const cmd_window_commands_test = @import("cmd/window_commands_test.zig");
const cmd_buffer_commands_test = @import("cmd/buffer_commands_test.zig");
const cmd_key_commands_test = @import("cmd/key_commands_test.zig");
const cmd_display_commands_test = @import("cmd/display_commands_test.zig");
const cmd_option_commands_test = @import("cmd/option_commands_test.zig");
const cmd_config_shell_test = @import("cmd/config_shell_test.zig");
const cmd_pane_commands_test = @import("cmd/pane_commands_test.zig");
const log = core.log;

const version_string = "zmux 0.1.0";
const default_socket_name = "default";

fn writeStdout(s: []const u8) void {
    _ = std.c.write(1, s.ptr, s.len);
}

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
    print_help: bool = false,
    remaining: std.ArrayListAligned([:0]const u8, null),

    fn deinit(self: *Flags, alloc: std.mem.Allocator) void {
        self.remaining.deinit(alloc);
    }
};

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.sliceTo(value, 0);
}

fn parseArgs(alloc: std.mem.Allocator, init_args: std.process.Args) Flags {
    var flags = Flags{ .remaining = .empty };
    var args = std.process.Args.Iterator.init(init_args);
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
                'h' => flags.print_help = true,
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

fn resolveSocketPath(alloc: std.mem.Allocator, flags: *const Flags) ![]u8 {
    if (flags.socket_path) |path| {
        return try alloc.dupe(u8, path);
    }
    if (getenv("ZMUX_SOCKET_PATH")) |path| {
        return try alloc.dupe(u8, path);
    }

    const socket_dir = try platform.core.defaultSocketDir(alloc);
    defer alloc.free(socket_dir);
    const socket_name = if (flags.socket_name) |sn|
        sn
    else if (getenv("ZMUX_SOCKET_NAME")) |sn|
        sn
    else
        default_socket_name;

    return try std.fmt.allocPrint(alloc, "{s}/zmux-{d}/{s}", .{
        socket_dir,
        std.c.getuid(),
        socket_name,
    });
}

fn determineTerminalName() []const u8 {
    return getenv("TERM") orelse "xterm-256color";
}

fn runServer(alloc: std.mem.Allocator, socket_path: []const u8, daemonize_server: bool, config_file: ?[:0]const u8) !void {
    if (daemonize_server) {
        try signals.daemonize();
    }
    signals.SignalHandler.install();
    var server = try server_mod.Server.init(alloc, socket_path);
    defer server.deinit();
    if (config_file) |cf| server.config_file = cf;
    try server.listen();
    server.loadDefaultConfig();
    try server.run();
}

fn waitForServer(alloc: std.mem.Allocator, socket_path: []const u8) !void {
    var attempt: usize = 0;
    while (attempt < 100) : (attempt += 1) {
        var probe = client_mod.Client.init(alloc, socket_path);
        if (probe.connect()) {
            probe.disconnect();
            return;
        } else |_| {
            var delay = std.c.timespec{
                .sec = 0,
                .nsec = 50 * std.time.ns_per_ms,
            };
            _ = std.c.nanosleep(&delay, null);
        }
    }
    return error.ServerStartTimeout;
}

fn autostartServer(alloc: std.mem.Allocator, socket_path: []const u8, config_file: ?[:0]const u8) !void {
    const pid = std.c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        detachStdio();
        runServer(std.heap.c_allocator, socket_path, false, config_file) catch {};
        std.c.exit(0);
    }
    try waitForServer(alloc, socket_path);
}

fn detachStdio() void {
    _ = std.c.setsid();
    _ = std.c.close(0);
    _ = std.c.close(1);
    _ = std.c.close(2);

    const devnull: [*:0]const u8 = "/dev/null";
    const fd = std.c.open(devnull, .{ .ACCMODE = .RDWR }, @as(std.c.mode_t, 0));
    if (fd < 0) return;
    _ = std.c.dup2(fd, 0);
    _ = std.c.dup2(fd, 1);
    _ = std.c.dup2(fd, 2);
    if (fd > 2) _ = std.c.close(fd);
}

fn runCommandMode(alloc: std.mem.Allocator, flags: *const Flags, socket_path: []const u8) !void {
    var client = client_mod.Client.init(alloc, socket_path);
    client.identify_flags = .{
        .utf8 = flags.utf8_flag,
        .control_mode = flags.control_mode,
        .terminal_256 = flags.force_256,
    };
    client.connect() catch |err| switch (err) {
        error.ConnectFailed => {
            try autostartServer(alloc, socket_path, flags.config_file);
            try client.connect();
        },
        else => return err,
    };
    defer client.disconnect();

    var cols: u16 = 80;
    var rows: u16 = 24;
    if (client_terminal.getTerminalSize(0)) |ts| {
        cols = ts.cols;
        rows = ts.rows;
    }
    try client.identify(determineTerminalName(), cols, rows);

    var startup_raw: ?client_terminal.RawTerminal = null;
    const prearm_startup_relay = client_mod.commandStartsStartupRelay(flags.remaining.items, flags.control_mode);
    if (prearm_startup_relay) {
        startup_raw = client_terminal.RawTerminal.init(0) catch null;
        if (startup_raw) |*raw| {
            raw.enableRaw() catch {
                startup_raw = null;
            };
        }
    }

    const result = try client.requestCommand(flags.remaining.items);
    if (result.attached) {
        try client.interactiveLoop(if (startup_raw) |*raw| raw else null);
        return;
    }
    if (startup_raw) |*raw| raw.restore();
    if (result.exit_code != 0) {
        std.c.exit(result.exit_code);
    }
}

pub fn main(init: std.process.Init.Minimal) !void {
    var zmux_alloc = core.allocator_mod.ZmuxAllocator.init();
    defer zmux_alloc.deinit();
    const alloc = zmux_alloc.allocator();

    var flags = parseArgs(alloc, init.args);
    defer flags.deinit(alloc);

    if (flags.print_help) {
        writeStdout(
            \\usage: zmux [-2CDhuVv] [-c shell-command] [-f file] [-L socket-name]
            \\                [-S socket-path] [command [flags]]
            \\
            \\options:
            \\  -2            Force 256-color terminal
            \\  -C            Start in control mode
            \\  -c command    Execute shell-command using the default shell
            \\  -D            Do not start the server as a daemon
            \\  -f file       Specify an alternative configuration file
            \\  -h            Show this help message
            \\  -L name       Use a different socket name (default: default)
            \\  -S path       Specify a full alternative path to the server socket
            \\  -u            Set the client to UTF-8 mode
            \\  -V            Print version and exit
            \\  -v            Enable verbose logging (repeat for more)
            \\
            \\commands:
            \\  Run 'zmux list-commands' for a list of available commands.
            \\
        );
        return;
    }

    if (flags.print_version) {
        writeStdout(version_string ++ "\n");
        return;
    }

    const log_level: log.Level = switch (flags.verbose) {
        0 => .info,
        else => .debug,
    };
    log.init(log_level, null, flags.verbose > 0);
    defer log.deinit();

    const socket_path = try resolveSocketPath(alloc, &flags);
    defer alloc.free(socket_path);

    if (flags.remaining.items.len == 0) {
        // tmux-compatible default: create a new session and attach.
        // The server is auto-started by runCommandMode if needed.
        try flags.remaining.append(alloc, "new-session");
    }

    try runCommandMode(alloc, &flags, socket_path);
}

test {
    _ = core.utf8;
    _ = core.colour;
    _ = core.environ;
    _ = protocol;
    _ = startup_probe;
    _ = layout.core;
    _ = layout.set;
    _ = layout.custom;
    _ = window_mod;
    _ = terminal.input;
    _ = terminal.keys;
    _ = screen.grid;
    _ = screen.screen_mod;
    _ = screen.writer;
    _ = config.parser;
    _ = config.path;
    _ = config.options;
    _ = config.options_table;
    _ = cmd;
    _ = cmd_tmux_equivalent_test;
    _ = cmd_buffer_commands_test;
    _ = cmd_key_commands_test;
    _ = cmd_display_commands_test;
    _ = cmd_option_commands_test;
    _ = cmd_config_shell_test;
    _ = cmd_pane_commands_test;
    _ = keybind.bindings;
    _ = keybind.string;
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
    _ = hooks.hooks_mod;
    _ = hooks.notify;
    _ = hooks.job;
    _ = platform.std_io.Runtime;
    _ = tabs.tabs_mod;
    _ = render.atlas;
    _ = render.image;
    _ = render.sixel;
    _ = render.kitty;
    _ = render.shaders;
    _ = render.font;
    _ = input_handler;
    _ = client_terminal;
    _ = server_loop;
    _ = signals;
    _ = clipboard_mod;
}

test "protocol command args preserve argument boundaries" {
    const alloc = std.testing.allocator;
    const args = [_][:0]const u8{ "display-message", "hello world" };
    const encoded = try protocol.encodeCommandArgs(alloc, &args);
    defer alloc.free(encoded);
    try std.testing.expectEqualStrings("display-message", encoded[0.."display-message".len]);
    try std.testing.expectEqual(@as(u8, 0), encoded["display-message".len]);
    try std.testing.expectEqualStrings("hello world", encoded["display-message".len + 1 .. encoded.len - 1]);
    try std.testing.expectEqual(@as(u8, 0), encoded[encoded.len - 1]);
}
