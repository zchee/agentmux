const std = @import("std");
const protocol = @import("../protocol.zig");
const config_parser = @import("../config/parser.zig");
const binding_mod = @import("../keybind/bindings.zig");
const key_string = @import("../keybind/string.zig");
const paste_mod = @import("../copy/paste.zig");
const copy_mod = @import("../copy/copy.zig");
const tree_mod = @import("../mode/tree.zig");
const screen_mod = @import("../screen/screen.zig");
const Pty = @import("../pane.zig").Pty;
const Session = @import("../session.zig").Session;
const Window = @import("../window.zig").Window;
const Pane = @import("../window.zig").Pane;
const PromptState = @import("../window.zig").PromptState;
const ChooseTreeState = @import("../window.zig").ChooseTreeState;
const ChooseTreeItem = @import("../window.zig").ChooseTreeItem;
const CellType = @import("../layout/layout.zig").CellType;
const Server = @import("../server.zig").Server;

/// Command execution context.
pub const Context = struct {
    server: *Server,
    session: ?*Session,
    window: ?*Window,
    pane: ?*Pane,
    client_index: ?usize = null,
    allocator: std.mem.Allocator,
    reply_fd: ?std.c.fd_t = null,
    registry: ?*const Registry = null,
    binding_manager: ?*binding_mod.BindingManager = null,
};

/// Command handler function type.
pub const Handler = *const fn (ctx: *Context, args: []const []const u8) CmdError!void;

pub const CmdError = error{
    InvalidArgs,
    SessionNotFound,
    WindowNotFound,
    PaneNotFound,
    BufferNotFound,
    CommandFailed,
    OutOfMemory,
};

/// A registered command.
pub const CommandDef = struct {
    name: []const u8,
    alias: ?[]const u8,
    min_args: u8,
    max_args: u8,
    usage: []const u8,
    handler: Handler,
};

/// Command registry.
pub const Registry = struct {
    commands: std.StringHashMap(CommandDef),

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .commands = std.StringHashMap(CommandDef).init(alloc) };
    }

    pub fn deinit(self: *Registry) void {
        self.commands.deinit();
    }

    pub fn register(self: *Registry, def: CommandDef) !void {
        try self.commands.put(def.name, def);
        if (def.alias) |alias| {
            try self.commands.put(alias, def);
        }
    }

    pub fn find(self: *const Registry, name: []const u8) ?CommandDef {
        return self.commands.get(name);
    }

    /// Return a sorted, deduplicated list of all commands (aliases excluded).
    pub fn listAll(self: *const Registry, alloc: std.mem.Allocator) ![]CommandDef {
        var seen = std.StringHashMap(void).init(alloc);
        defer seen.deinit();
        var list: std.ArrayListAligned(CommandDef, null) = .empty;
        defer list.deinit(alloc);

        var iter = self.commands.iterator();
        while (iter.next()) |entry| {
            const def = entry.value_ptr.*;
            if (seen.contains(def.name)) continue;
            try seen.put(def.name, {});
            try list.append(alloc, def);
        }

        const items = try alloc.dupe(CommandDef, list.items);
        std.mem.sort(CommandDef, items, {}, struct {
            fn lessThan(_: void, a: CommandDef, b: CommandDef) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        return items;
    }

    /// Execute a command by name with arguments.
    pub fn execute(self: *const Registry, ctx: *Context, name: []const u8, args: []const []const u8) CmdError!void {
        const def = self.find(name) orelse return CmdError.CommandFailed;
        if (args.len < def.min_args or (def.max_args > 0 and args.len > def.max_args)) {
            return CmdError.InvalidArgs;
        }
        return def.handler(ctx, args);
    }

    pub fn executeParsed(self: *const Registry, ctx: *Context, command: *const config_parser.Command) CmdError!void {
        return self.execute(ctx, command.name, command.args.items);
    }

    /// Register all built-in commands.
    pub fn registerBuiltins(self: *Registry) !void {
        // -- Session commands --
        try self.register(.{ .name = "attach-session", .alias = "attach", .min_args = 0, .max_args = 10, .usage = "attach-session (attach) [-dErx] [-c working-directory] [-f flags] [-t target-session]", .handler = cmdAttachSession });
        try self.register(.{ .name = "detach-client", .alias = "detach", .min_args = 0, .max_args = 8, .usage = "detach-client (detach) [-aP] [-E shell-command] [-s target-session] [-t target-client]", .handler = cmdDetachClient });
        try self.register(.{ .name = "has-session", .alias = "has", .min_args = 0, .max_args = 2, .usage = "has-session (has) [-t target-session]", .handler = cmdHasSession });
        try self.register(.{ .name = "kill-server", .alias = null, .min_args = 0, .max_args = 0, .usage = "kill-server", .handler = cmdKillServer });
        try self.register(.{ .name = "kill-session", .alias = null, .min_args = 0, .max_args = 4, .usage = "kill-session [-aC] [-t target-session]", .handler = cmdKillSession });
        try self.register(.{ .name = "list-clients", .alias = "lsc", .min_args = 0, .max_args = 8, .usage = "list-clients (lsc) [-F format] [-f filter] [-O order] [-t target-session]", .handler = cmdListClients });
        try self.register(.{ .name = "list-commands", .alias = "lscm", .min_args = 0, .max_args = 4, .usage = "list-commands (lscm) [-F format] [command]", .handler = cmdListCommands });
        try self.register(.{ .name = "list-sessions", .alias = "ls", .min_args = 0, .max_args = 8, .usage = "list-sessions (ls) [-r] [-F format] [-f filter] [-O order]", .handler = cmdListSessions });
        try self.register(.{ .name = "lock-client", .alias = "lockc", .min_args = 0, .max_args = 2, .usage = "lock-client (lockc) [-t target-client]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "lock-server", .alias = "lock", .min_args = 0, .max_args = 0, .usage = "lock-server (lock)", .handler = cmdNotImplemented });
        try self.register(.{ .name = "lock-session", .alias = "locks", .min_args = 0, .max_args = 2, .usage = "lock-session (locks) [-t target-session]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "new-session", .alias = "new", .min_args = 0, .max_args = 20, .usage = "new-session (new) [-AdDEPX] [-c start-directory] [-e environment] [-F format] [-f flags] [-n window-name] [-s session-name] [-t target-session] [-x width] [-y height] [shell-command [argument ...]]", .handler = cmdNewSession });
        try self.register(.{ .name = "refresh-client", .alias = "refresh", .min_args = 0, .max_args = 20, .usage = "refresh-client (refresh) [-cDlLRSU] [-A pane:state] [-B name:what:format] [-C XxY] [-f flags] [-r pane:report] [-t target-client] [adjustment]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "rename-session", .alias = "rename", .min_args = 1, .max_args = 4, .usage = "rename-session (rename) [-t target-session] new-name", .handler = cmdRenameSession });
        try self.register(.{ .name = "show-messages", .alias = "showmsgs", .min_args = 0, .max_args = 4, .usage = "show-messages (showmsgs) [-JT] [-t target-client]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "start-server", .alias = "start", .min_args = 0, .max_args = 0, .usage = "start-server (start)", .handler = cmdStartServer });
        try self.register(.{ .name = "suspend-client", .alias = "suspendc", .min_args = 0, .max_args = 2, .usage = "suspend-client (suspendc) [-t target-client]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "switch-client", .alias = "switchc", .min_args = 0, .max_args = 14, .usage = "switch-client (switchc) [-ElnprZ] [-c target-client] [-t target-session] [-T key-table] [-O order]", .handler = cmdNotImplemented });

        // -- Window commands --
        try self.register(.{ .name = "choose-tree", .alias = null, .min_args = 0, .max_args = 14, .usage = "choose-tree [-GNrswZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdChooseTree });
        try self.register(.{ .name = "find-window", .alias = "findw", .min_args = 1, .max_args = 10, .usage = "find-window (findw) [-CiNrTZ] [-t target-pane] match-string", .handler = cmdNotImplemented });
        try self.register(.{ .name = "kill-window", .alias = "killw", .min_args = 0, .max_args = 4, .usage = "kill-window (killw) [-a] [-t target-window]", .handler = cmdKillWindow });
        try self.register(.{ .name = "last-window", .alias = "last", .min_args = 0, .max_args = 2, .usage = "last-window (last) [-t target-session]", .handler = cmdLastWindow });
        try self.register(.{ .name = "link-window", .alias = "linkw", .min_args = 0, .max_args = 8, .usage = "link-window (linkw) [-abdk] [-s src-window] [-t dst-window]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "list-windows", .alias = "lsw", .min_args = 0, .max_args = 8, .usage = "list-windows (lsw) [-ar] [-F format] [-f filter] [-O order] [-t target-session]", .handler = cmdListWindows });
        try self.register(.{ .name = "move-window", .alias = "movew", .min_args = 0, .max_args = 10, .usage = "move-window (movew) [-abdkr] [-s src-window] [-t dst-window]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "new-window", .alias = "neww", .min_args = 0, .max_args = 20, .usage = "new-window (neww) [-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-window] [shell-command [argument ...]]", .handler = cmdNewWindow });
        try self.register(.{ .name = "next-layout", .alias = "nextl", .min_args = 0, .max_args = 2, .usage = "next-layout (nextl) [-t target-window]", .handler = cmdNextLayout });
        try self.register(.{ .name = "next-window", .alias = "next", .min_args = 0, .max_args = 4, .usage = "next-window (next) [-a] [-t target-session]", .handler = cmdNextWindow });
        try self.register(.{ .name = "previous-layout", .alias = "prevl", .min_args = 0, .max_args = 2, .usage = "previous-layout (prevl) [-t target-window]", .handler = cmdPrevLayout });
        try self.register(.{ .name = "previous-window", .alias = "prev", .min_args = 0, .max_args = 4, .usage = "previous-window (prev) [-a] [-t target-session]", .handler = cmdPrevWindow });
        try self.register(.{ .name = "rename-window", .alias = "renamew", .min_args = 1, .max_args = 4, .usage = "rename-window (renamew) [-t target-window] new-name", .handler = cmdRenameWindow });
        try self.register(.{ .name = "resize-window", .alias = "resizew", .min_args = 0, .max_args = 10, .usage = "resize-window (resizew) [-aADLRU] [-x width] [-y height] [-t target-window] [adjustment]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "respawn-window", .alias = "respawnw", .min_args = 0, .max_args = 10, .usage = "respawn-window (respawnw) [-k] [-c start-directory] [-e environment] [-t target-window] [shell-command [argument ...]]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "rotate-window", .alias = "rotatew", .min_args = 0, .max_args = 4, .usage = "rotate-window (rotatew) [-DUZ] [-t target-window]", .handler = cmdRotateWindow });
        try self.register(.{ .name = "select-layout", .alias = "selectl", .min_args = 0, .max_args = 6, .usage = "select-layout (selectl) [-Enop] [-t target-pane] [layout-name]", .handler = cmdSelectLayout });
        try self.register(.{ .name = "select-window", .alias = "selectw", .min_args = 0, .max_args = 4, .usage = "select-window (selectw) [-lnpT] [-t target-window]", .handler = cmdSelectWindow });
        try self.register(.{ .name = "split-window", .alias = "splitw", .min_args = 0, .max_args = 20, .usage = "split-window (splitw) [-bdefhIPvZ] [-c start-directory] [-e environment] [-F format] [-l size] [-t target-pane] [shell-command [argument ...]]", .handler = cmdSplitWindow });
        try self.register(.{ .name = "swap-window", .alias = "swapw", .min_args = 0, .max_args = 6, .usage = "swap-window (swapw) [-d] [-s src-window] [-t dst-window]", .handler = cmdSwapWindow });
        try self.register(.{ .name = "unlink-window", .alias = "unlinkw", .min_args = 0, .max_args = 4, .usage = "unlink-window (unlinkw) [-k] [-t target-window]", .handler = cmdNotImplemented });

        // -- Pane commands --
        try self.register(.{ .name = "break-pane", .alias = "breakp", .min_args = 0, .max_args = 10, .usage = "break-pane (breakp) [-abdP] [-F format] [-n window-name] [-s src-pane] [-t dst-window]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "capture-pane", .alias = "capturep", .min_args = 0, .max_args = 12, .usage = "capture-pane (capturep) [-aCeJMNpPqT] [-b buffer-name] [-E end-line] [-S start-line] [-t target-pane]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "display-panes", .alias = "displayp", .min_args = 0, .max_args = 6, .usage = "display-panes (displayp) [-bN] [-d duration] [-t target-client] [template]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "join-pane", .alias = "joinp", .min_args = 0, .max_args = 10, .usage = "join-pane (joinp) [-bdfhv] [-l size] [-s src-pane] [-t dst-pane]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "kill-pane", .alias = "killp", .min_args = 0, .max_args = 4, .usage = "kill-pane (killp) [-a] [-t target-pane]", .handler = cmdKillPane });
        try self.register(.{ .name = "last-pane", .alias = "lastp", .min_args = 0, .max_args = 4, .usage = "last-pane (lastp) [-deZ] [-t target-window]", .handler = cmdLastPane });
        try self.register(.{ .name = "list-panes", .alias = "lsp", .min_args = 0, .max_args = 8, .usage = "list-panes (lsp) [-asr] [-F format] [-f filter] [-O order] [-t target-window]", .handler = cmdListPanes });
        try self.register(.{ .name = "move-pane", .alias = "movep", .min_args = 0, .max_args = 10, .usage = "move-pane (movep) [-bdfhv] [-l size] [-s src-pane] [-t dst-pane]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "pipe-pane", .alias = "pipep", .min_args = 0, .max_args = 6, .usage = "pipe-pane (pipep) [-IOo] [-t target-pane] [shell-command]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "resize-pane", .alias = "resizep", .min_args = 0, .max_args = 10, .usage = "resize-pane (resizep) [-DLMRTUZ] [-x width] [-y height] [-t target-pane] [adjustment]", .handler = cmdResizePane });
        try self.register(.{ .name = "respawn-pane", .alias = "respawnp", .min_args = 0, .max_args = 10, .usage = "respawn-pane (respawnp) [-k] [-c start-directory] [-e environment] [-t target-pane] [shell-command [argument ...]]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "select-pane", .alias = "selectp", .min_args = 0, .max_args = 10, .usage = "select-pane (selectp) [-DdeLlMmRUZ] [-T title] [-t target-pane]", .handler = cmdSelectPane });
        try self.register(.{ .name = "swap-pane", .alias = "swapp", .min_args = 0, .max_args = 6, .usage = "swap-pane (swapp) [-dDUZ] [-s src-pane] [-t dst-pane]", .handler = cmdSwapPane });

        // -- Key binding commands --
        try self.register(.{ .name = "bind-key", .alias = "bind", .min_args = 1, .max_args = 20, .usage = "bind-key (bind) [-nr] [-T key-table] [-N note] key [command [argument ...]]", .handler = cmdBindKey });
        try self.register(.{ .name = "list-keys", .alias = "lsk", .min_args = 0, .max_args = 8, .usage = "list-keys (lsk) [-1aNr] [-F format] [-O order] [-P prefix-string] [-T key-table] [key]", .handler = cmdListKeys });
        try self.register(.{ .name = "send-keys", .alias = "send", .min_args = 1, .max_args = 20, .usage = "send-keys (send) [-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] [key ...]", .handler = cmdSendKeys });
        try self.register(.{ .name = "send-prefix", .alias = null, .min_args = 0, .max_args = 4, .usage = "send-prefix [-2] [-t target-pane]", .handler = cmdSendPrefix });
        try self.register(.{ .name = "unbind-key", .alias = "unbind", .min_args = 1, .max_args = 6, .usage = "unbind-key (unbind) [-anq] [-T key-table] key", .handler = cmdUnbindKey });

        // -- Options commands --
        try self.register(.{ .name = "set-option", .alias = "set", .min_args = 1, .max_args = 10, .usage = "set-option (set) [-aFgopqsuUw] [-t target-pane] option [value]", .handler = cmdSetOption });
        try self.register(.{ .name = "set-window-option", .alias = "setw", .min_args = 1, .max_args = 8, .usage = "set-window-option (setw) [-aFgoqu] [-t target-window] option [value]", .handler = cmdSetWindowOption });
        try self.register(.{ .name = "show-options", .alias = "show", .min_args = 0, .max_args = 8, .usage = "show-options (show) [-AgHpqsvw] [-t target-pane] [option]", .handler = cmdShowOptions });
        try self.register(.{ .name = "show-window-options", .alias = "showw", .min_args = 0, .max_args = 6, .usage = "show-window-options (showw) [-gv] [-t target-window] [option]", .handler = cmdShowWindowOptions });

        // -- Environment commands --
        try self.register(.{ .name = "set-environment", .alias = "setenv", .min_args = 1, .max_args = 8, .usage = "set-environment (setenv) [-Fhgru] [-t target-session] variable [value]", .handler = cmdSetEnvironment });
        try self.register(.{ .name = "show-environment", .alias = "showenv", .min_args = 0, .max_args = 6, .usage = "show-environment (showenv) [-hgs] [-t target-session] [variable]", .handler = cmdShowEnvironment });

        // -- Hook commands --
        try self.register(.{ .name = "set-hook", .alias = null, .min_args = 0, .max_args = 10, .usage = "set-hook [-agpRuw] [-t target-pane] hook [command]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "show-hooks", .alias = null, .min_args = 0, .max_args = 6, .usage = "show-hooks [-gpw] [-t target-pane] [hook]", .handler = cmdNotImplemented });

        // -- Display commands --
        try self.register(.{ .name = "clock-mode", .alias = null, .min_args = 0, .max_args = 2, .usage = "clock-mode [-t target-pane]", .handler = cmdClockMode });
        try self.register(.{ .name = "display-menu", .alias = "menu", .min_args = 0, .max_args = 30, .usage = "display-menu (menu) [-MO] [-b border-lines] [-c target-client] [-C starting-choice] [-H selected-style] [-s style] [-S border-style] [-t target-pane] [-T title] [-x position] [-y position] name [key] [command] ...", .handler = cmdNotImplemented });
        try self.register(.{ .name = "display-message", .alias = "display", .min_args = 0, .max_args = 12, .usage = "display-message (display) [-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]", .handler = cmdDisplayMessage });
        try self.register(.{ .name = "display-popup", .alias = "popup", .min_args = 0, .max_args = 30, .usage = "display-popup (popup) [-BCEkN] [-b border-lines] [-c target-client] [-d start-directory] [-e environment] [-h height] [-s style] [-S border-style] [-t target-pane] [-T title] [-w width] [-x position] [-y position] [shell-command [argument ...]]", .handler = cmdNotImplemented });

        // -- Buffer commands --
        try self.register(.{ .name = "choose-buffer", .alias = null, .min_args = 0, .max_args = 12, .usage = "choose-buffer [-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "clear-history", .alias = "clearhist", .min_args = 0, .max_args = 4, .usage = "clear-history (clearhist) [-H] [-t target-pane]", .handler = cmdClearHistory });
        try self.register(.{ .name = "delete-buffer", .alias = "deleteb", .min_args = 0, .max_args = 2, .usage = "delete-buffer (deleteb) [-b buffer-name]", .handler = cmdDeleteBuffer });
        try self.register(.{ .name = "list-buffers", .alias = "lsb", .min_args = 0, .max_args = 6, .usage = "list-buffers (lsb) [-F format] [-f filter] [-O order]", .handler = cmdListBuffers });
        try self.register(.{ .name = "load-buffer", .alias = "loadb", .min_args = 1, .max_args = 6, .usage = "load-buffer (loadb) [-b buffer-name] [-t target-client] path", .handler = cmdLoadBuffer });
        try self.register(.{ .name = "paste-buffer", .alias = "pasteb", .min_args = 0, .max_args = 8, .usage = "paste-buffer (pasteb) [-dprS] [-s separator] [-b buffer-name] [-t target-pane]", .handler = cmdPasteBuffer });
        try self.register(.{ .name = "save-buffer", .alias = "saveb", .min_args = 1, .max_args = 6, .usage = "save-buffer (saveb) [-a] [-b buffer-name] path", .handler = cmdSaveBuffer });
        try self.register(.{ .name = "set-buffer", .alias = "setb", .min_args = 1, .max_args = 8, .usage = "set-buffer (setb) [-aw] [-b buffer-name] [-n new-buffer-name] [-t target-client] [data]", .handler = cmdSetBuffer });
        try self.register(.{ .name = "show-buffer", .alias = "showb", .min_args = 0, .max_args = 2, .usage = "show-buffer (showb) [-b buffer-name]", .handler = cmdShowBuffer });

        // -- Copy/paste commands --
        try self.register(.{ .name = "copy-mode", .alias = null, .min_args = 0, .max_args = 8, .usage = "copy-mode [-deHMqSu] [-s src-pane] [-t target-pane]", .handler = cmdCopyMode });

        // -- Interactive/mode commands --
        try self.register(.{ .name = "choose-client", .alias = null, .min_args = 0, .max_args = 12, .usage = "choose-client [-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "command-prompt", .alias = null, .min_args = 0, .max_args = 12, .usage = "command-prompt [-1beFiklN] [-I inputs] [-p prompts] [-t target-client] [-T prompt-type] [template]", .handler = cmdCommandPrompt });
        try self.register(.{ .name = "confirm-before", .alias = "confirm", .min_args = 1, .max_args = 10, .usage = "confirm-before (confirm) [-by] [-c confirm-key] [-p prompt] [-t target-client] command", .handler = cmdNotImplemented });
        try self.register(.{ .name = "customize-mode", .alias = null, .min_args = 0, .max_args = 8, .usage = "customize-mode [-NZ] [-F format] [-f filter] [-t target-pane]", .handler = cmdNotImplemented });

        // -- Config commands --
        try self.register(.{ .name = "source-file", .alias = "source", .min_args = 1, .max_args = 8, .usage = "source-file (source) [-Fnqv] [-t target-pane] path ...", .handler = cmdSourceFile });

        // -- Shell/job commands --
        try self.register(.{ .name = "if-shell", .alias = "if", .min_args = 2, .max_args = 8, .usage = "if-shell (if) [-bF] [-t target-pane] shell-command command [command]", .handler = cmdIfShell });
        try self.register(.{ .name = "run-shell", .alias = "run", .min_args = 0, .max_args = 10, .usage = "run-shell (run) [-bCE] [-c start-directory] [-d delay] [-t target-pane] [shell-command]", .handler = cmdRunShell });
        try self.register(.{ .name = "wait-for", .alias = "wait", .min_args = 1, .max_args = 4, .usage = "wait-for (wait) [-L|-S|-U] channel", .handler = cmdNotImplemented });

        // -- Prompt history --
        try self.register(.{ .name = "clear-prompt-history", .alias = "clearphist", .min_args = 0, .max_args = 2, .usage = "clear-prompt-history (clearphist) [-T prompt-type]", .handler = cmdNotImplemented });
        try self.register(.{ .name = "show-prompt-history", .alias = "showphist", .min_args = 0, .max_args = 2, .usage = "show-prompt-history (showphist) [-T prompt-type]", .handler = cmdNotImplemented });

        // -- Access control --
        try self.register(.{ .name = "server-access", .alias = null, .min_args = 0, .max_args = 8, .usage = "server-access [-adlrw] [-t target-pane] [user]", .handler = cmdNotImplemented });
    }
};

fn writeReplyMessage(ctx: *Context, msg_type: protocol.MessageType, message: []const u8) CmdError!void {
    if (ctx.reply_fd) |fd| {
        protocol.sendMessage(fd, msg_type, message) catch return CmdError.CommandFailed;
        return;
    }

    const target_fd: std.c.fd_t = switch (msg_type) {
        .error_msg => 2,
        else => 1,
    };
    _ = std.c.write(target_fd, message.ptr, message.len);
}

fn writeOutput(ctx: *Context, comptime fmt: []const u8, args: anytype) CmdError!void {
    var buf: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, fmt, args) catch return CmdError.CommandFailed;
    try writeReplyMessage(ctx, .output, message);
}

fn spawnWindowPane(alloc: std.mem.Allocator, shell: [:0]const u8, sx: u32, sy: u32) CmdError!*Pane {
    const pane = Pane.init(alloc, sx, sy) catch return CmdError.OutOfMemory;
    errdefer pane.deinit();

    var pty = Pty.openPty() catch return CmdError.CommandFailed;
    pty.forkExec(shell, null) catch return CmdError.CommandFailed;
    pty.resize(@intCast(sx), @intCast(sy));
    pane.fd = pty.master_fd;
    pane.pid = pty.pid;
    return pane;
}

fn parseTargetWindow(args: []const []const u8) ?u32 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i], "-t") or i + 1 >= args.len) continue;
        i += 1;
        const target = args[i];
        if (target.len >= 2 and target[0] == ':') {
            return std.fmt.parseInt(u32, target[1..], 10) catch null;
        }
        return std.fmt.parseInt(u32, target, 10) catch null;
    }
    return null;
}

fn defaultShell(_: ?*Session) [:0]const u8 {
    return "/bin/sh";
}

const ClockTm = extern struct {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
};

extern "c" fn time(timer: ?*i64) i64;
extern "c" fn localtime(timer: *const i64) ?*ClockTm;

fn parseNamedOption(args: []const []const u8, flag: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], flag) and i + 1 < args.len) {
            return args[i + 1];
        }
    }
    return null;
}

fn parseBooleanValue(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.mem.eql(u8, value, "1"))
    {
        return true;
    }
    if (std.ascii.eqlIgnoreCase(value, "off") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.mem.eql(u8, value, "0"))
    {
        return false;
    }
    return null;
}

fn parsePrefixValue(value: []const u8) ?u21 {
    const parsed = key_string.stringToKey(value) orelse return null;
    if (parsed.mods.meta or parsed.mods.shift) return null;
    if (!parsed.mods.ctrl) return parsed.key;

    if (parsed.key == ' ') return 0;
    if (parsed.key >= 'a' and parsed.key <= 'z') return parsed.key - 'a' + 1;
    if (parsed.key >= 'A' and parsed.key <= 'Z') return parsed.key - 'A' + 1;
    return null;
}

fn resolvePasteBuffer(ctx: *Context, name: ?[]const u8) CmdError!*paste_mod.PasteBuffer {
    if (name) |buffer_name| {
        return ctx.server.paste_stack.getByName(buffer_name) orelse CmdError.BufferNotFound;
    }
    return ctx.server.paste_stack.get(0) orelse CmdError.BufferNotFound;
}

fn extractGridLineSlice(alloc: std.mem.Allocator, pane_state: anytype, absolute_y: u32, start_x: u32, end_x: u32) ![]u8 {
    const grid = &pane_state.screen.grid;
    const total_lines = grid.hsize + grid.rows;
    if (absolute_y >= total_lines) return try alloc.dupe(u8, "");

    const line = if (absolute_y < grid.hsize)
        grid.getHistoryLine(absolute_y)
    else
        grid.getLine(absolute_y - grid.hsize);

    const max_x = @min(end_x, grid.cols -| 1);
    if (start_x > max_x) return try alloc.dupe(u8, "");

    var buf: std.ArrayListAligned(u8, null) = .empty;
    defer buf.deinit(alloc);
    var x = start_x;
    while (x <= max_x) : (x += 1) {
        const cell = line.getCell(x);
        const ch: u8 = if (cell.codepoint == 0)
            ' '
        else if (cell.codepoint < 0x80)
            @truncate(cell.codepoint)
        else
            '?';
        try buf.append(alloc, ch);
    }

    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == ' ') {
        _ = buf.pop();
    }
    return try buf.toOwnedSlice(alloc);
}

fn extractCopySelection(alloc: std.mem.Allocator, pane_state: anytype, state: *const copy_mod.CopyState) ![]u8 {
    const grid = &pane_state.screen.grid;
    const total_lines = grid.hsize + grid.rows;
    if (total_lines == 0) return try alloc.dupe(u8, "");

    const start_y = @min(state.sel_start_y, state.cy);
    const end_y = @min(@max(state.sel_start_y, state.cy), total_lines - 1);
    const start_x = @min(state.sel_start_x, state.cx);
    const end_x = @max(state.sel_start_x, state.cx);

    var out: std.ArrayListAligned(u8, null) = .empty;
    errdefer out.deinit(alloc);

    var y = start_y;
    while (y <= end_y) : (y += 1) {
        const line_text = if (state.mode == .visual_line)
            try extractGridLineSlice(alloc, pane_state, y, 0, grid.cols -| 1)
        else if (start_y == end_y)
            try extractGridLineSlice(alloc, pane_state, y, start_x, end_x)
        else if (y == start_y)
            try extractGridLineSlice(alloc, pane_state, y, start_x, grid.cols -| 1)
        else if (y == end_y)
            try extractGridLineSlice(alloc, pane_state, y, 0, end_x)
        else
            try extractGridLineSlice(alloc, pane_state, y, 0, grid.cols -| 1);
        defer alloc.free(line_text);

        try out.appendSlice(alloc, line_text);
        if (y != end_y) try out.append(alloc, '\n');
    }

    return try out.toOwnedSlice(alloc);
}

fn handleCopyModeAction(ctx: *Context, pane: *Pane, pane_state: anytype, action: copy_mod.CopyAction) CmdError!void {
    switch (action) {
        .move_cursor, .start_selection, .search_next, .search_prev => {},
        .scroll_up => if (pane.copy_state) |*state| {
            if (state.cy > 0) state.cy -= 1;
        },
        .scroll_down => if (pane.copy_state) |*state| {
            const max_y = pane_state.screen.grid.hsize + pane_state.screen.grid.rows -| 1;
            state.cy = @min(max_y, state.cy + 1);
        },
        .page_up => if (pane.copy_state) |*state| {
            const step = pane_state.screen.grid.rows;
            state.cy = state.cy -| step;
        },
        .page_down => if (pane.copy_state) |*state| {
            const step = pane_state.screen.grid.rows;
            const max_y = pane_state.screen.grid.hsize + pane_state.screen.grid.rows -| 1;
            state.cy = @min(max_y, state.cy + step);
        },
        .cancel => pane.copy_state = null,
        .copy_selection => {
            const state = pane.copy_state orelse return;
            const text = extractCopySelection(ctx.allocator, pane_state, &state) catch return CmdError.CommandFailed;
            defer ctx.allocator.free(text);
            ctx.server.paste_stack.push(text, null) catch return CmdError.OutOfMemory;
            pane.copy_state = null;
        },
    }
}

fn handleCopyModeKey(ctx: *Context, pane: *Pane, key_arg: []const u8) CmdError!bool {
    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return false;
    var handled = false;

    if (key_string.stringToKey(key_arg)) |result| {
        if (pane.copy_state) |*state| {
            const mods: copy_mod.Modifiers = .{
                .ctrl = result.mods.ctrl,
                .meta = result.mods.meta,
                .shift = result.mods.shift,
            };
            if (state.handleKey(result.key, mods)) |action| {
                try handleCopyModeAction(ctx, pane, pane_state, action);
            }
            handled = true;
        }
    } else if (pane.copy_state) |*state| {
        for (key_arg) |byte| {
            if (state.handleKey(byte, .{})) |action| {
                try handleCopyModeAction(ctx, pane, pane_state, action);
            }
        }
        handled = true;
    }

    return handled;
}

fn appendPromptBytes(state: *PromptState, bytes: []const u8) void {
    const remaining = state.buffer.len - state.len;
    const copy_len = @min(remaining, bytes.len);
    if (copy_len == 0) return;
    @memcpy(state.buffer[state.len .. state.len + copy_len], bytes[0..copy_len]);
    state.len += copy_len;
}

fn executeCommandString(ctx: *Context, command_text: []const u8) CmdError!void {
    const registry = ctx.registry orelse return CmdError.CommandFailed;
    if (command_text.len == 0) return;

    var parser = config_parser.ConfigParser.init(ctx.allocator, command_text);
    var commands = parser.parseAll() catch return CmdError.CommandFailed;
    defer {
        for (commands.items) |*command| command.deinit(ctx.allocator);
        commands.deinit(ctx.allocator);
    }
    if (commands.items.len == 0) return CmdError.InvalidArgs;

    for (commands.items) |*command| {
        try registry.executeParsed(ctx, command);
    }
}

fn executePromptBuffer(ctx: *Context, pane: *Pane) CmdError!void {
    const prompt_state = pane.prompt_state orelse return;
    const command_text = prompt_state.buffer[0..prompt_state.len];

    pane.prompt_state = null;
    try executeCommandString(ctx, command_text);
}

fn handlePromptKey(ctx: *Context, pane: *Pane, key_arg: []const u8) CmdError!bool {
    var prompt_state = &(pane.prompt_state orelse return false);

    if (std.mem.eql(u8, key_arg, "Enter")) {
        try executePromptBuffer(ctx, pane);
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Escape")) {
        pane.prompt_state = null;
        return true;
    }
    if (std.mem.eql(u8, key_arg, "BSpace")) {
        if (prompt_state.len > 0) prompt_state.len -= 1;
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Space")) {
        appendPromptBytes(prompt_state, " ");
        return true;
    }
    if (std.mem.eql(u8, key_arg, "Tab")) {
        appendPromptBytes(prompt_state, "\t");
        return true;
    }

    appendPromptBytes(prompt_state, key_arg);
    return true;
}

fn addChooseTreeEntry(state: *ChooseTreeState, label: []const u8, depth: u8, has_children: bool, session: *Session, window: ?*Window, pane: ?*Pane) CmdError!void {
    const owned_label = state.allocator.dupe(u8, label) catch return CmdError.OutOfMemory;
    errdefer state.allocator.free(owned_label);
    state.labels.append(state.allocator, owned_label) catch return CmdError.OutOfMemory;
    state.tree.addItem(.{
        .label = owned_label,
        .depth = depth,
        .expanded = true,
        .has_children = has_children,
        .tag = @intCast(state.items.items.len),
    }) catch return CmdError.OutOfMemory;
    state.items.append(state.allocator, .{
        .session = @ptrCast(session),
        .window = if (window) |w| @ptrCast(w) else null,
        .pane = if (pane) |p| @ptrCast(p) else null,
    }) catch return CmdError.OutOfMemory;
}

fn currentChooseTreeState(ctx: *Context, pane: ?*Pane) ?*ChooseTreeState {
    if (ctx.server.choose_tree_state) |*state| return state;
    if (ctx.client_index) |client_index| {
        if (client_index < ctx.server.clients.items.len) {
            if (ctx.server.clients.items[client_index].choose_tree_state) |*state| return state;
        }
    }
    if (pane) |p| {
        if (p.choose_tree_state) |*state| return state;
    }
    return null;
}

fn clearChooseTreeState(ctx: *Context, pane: ?*Pane) void {
    if (ctx.server.choose_tree_state) |*state| {
        state.deinit();
        ctx.server.choose_tree_state = null;
    }
    if (ctx.client_index) |client_index| {
        if (client_index < ctx.server.clients.items.len) {
            if (ctx.server.clients.items[client_index].choose_tree_state) |*state| {
                state.deinit();
            }
            ctx.server.clients.items[client_index].choose_tree_state = null;
        }
    }
    if (pane) |p| {
        if (p.choose_tree_state) |*state| {
            state.deinit();
        }
        p.choose_tree_state = null;
    }
}

fn renderChooseTree(ctx: *Context, pane: ?*Pane) CmdError!void {
    const state = currentChooseTreeState(ctx, pane) orelse return CmdError.CommandFailed;
    const rendered = state.tree.render(ctx.allocator) catch return CmdError.OutOfMemory;
    defer ctx.allocator.free(rendered);
    try writeOutput(ctx, "{s}", .{rendered});
}

fn handleChooseTreeSelect(ctx: *Context, pane: ?*Pane, item_index: usize) CmdError!void {
    const state = currentChooseTreeState(ctx, pane) orelse return CmdError.CommandFailed;
    if (item_index >= state.items.items.len) return CmdError.InvalidArgs;
    const item = state.items.items[item_index];
    const session: *Session = @ptrCast(@alignCast(item.session orelse return CmdError.SessionNotFound));
    ctx.session = session;
    ctx.server.default_session = session;
    if (item.window) |window_ptr| {
        const window: *Window = @ptrCast(@alignCast(window_ptr));
        session.selectWindow(window);
        ctx.window = window;
        if (item.pane) |pane_ptr| {
            const selected_pane: *Pane = @ptrCast(@alignCast(pane_ptr));
            window.selectPane(selected_pane);
            ctx.pane = selected_pane;
        } else {
            ctx.pane = window.active_pane;
        }
    } else {
        ctx.window = session.active_window;
        ctx.pane = if (ctx.window) |window| window.active_pane else null;
    }
    clearChooseTreeState(ctx, pane);
}

fn handleChooseTreeKey(ctx: *Context, pane: ?*Pane, key_arg: []const u8) CmdError!bool {
    if (currentChooseTreeState(ctx, pane) == null) return false;

    const key: u21 = if (key_string.stringToKey(key_arg)) |result|
        result.key
    else if (key_arg.len == 1)
        key_arg[0]
    else
        return false;

    var state = currentChooseTreeState(ctx, pane) orelse return false;
    switch (state.tree.handleKey(key)) {
        .none => {
            try renderChooseTree(ctx, pane);
            return true;
        },
        .cancel => {
            clearChooseTreeState(ctx, pane);
            return true;
        },
        .select, .toggle_expand => {
            const selected = state.tree.selected;
            try handleChooseTreeSelect(ctx, pane, selected);
            return true;
        },
    }
}

fn formatBindingKey(buf: []u8, key: u21, mods: binding_mod.Modifiers) []const u8 {
    var pos: usize = 0;
    if (mods.ctrl) {
        @memcpy(buf[pos .. pos + 2], "C-");
        pos += 2;
    }
    if (mods.meta) {
        @memcpy(buf[pos .. pos + 2], "M-");
        pos += 2;
    }
    if (mods.shift) {
        @memcpy(buf[pos .. pos + 2], "S-");
        pos += 2;
    }

    const special: ?[]const u8 = switch (key) {
        '\r' => "Enter",
        0x1b => "Escape",
        ' ' => "Space",
        '\t' => "Tab",
        0x7f => "BSpace",
        0x100 => "Up",
        0x101 => "Down",
        0x102 => "Left",
        0x103 => "Right",
        else => null,
    };

    if (special) |name| {
        @memcpy(buf[pos .. pos + name.len], name);
        pos += name.len;
        return buf[0..pos];
    }

    if (key < 0x80) {
        buf[pos] = @truncate(key);
        pos += 1;
        return buf[0..pos];
    }

    const rendered = std.fmt.bufPrint(buf[pos..], "U+{X}", .{key}) catch "?";
    return buf[0 .. pos + rendered.len];
}

fn spawnShellChild(command: []const u8) CmdError!std.c.pid_t {
    var cmd_buf: [4096]u8 = .{0} ** 4096;
    if (command.len >= cmd_buf.len) return CmdError.CommandFailed;
    @memcpy(cmd_buf[0..command.len], command);

    const pid = std.c.fork();
    if (pid < 0) return CmdError.CommandFailed;

    if (pid == 0) {
        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..command.len :0]);
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z };
        _ = execvp(sh, &argv);
        std.c.exit(127);
    }

    return pid;
}

fn waitForChildExit(pid: std.c.pid_t) CmdError!i32 {
    var status: i32 = 0;
    if (std.c.waitpid(pid, &status, 0) < 0) return CmdError.CommandFailed;
    return status;
}

fn childExitCode(status: i32) i32 {
    return @divTrunc(status, 256);
}

// -- Stub for unimplemented commands --

fn cmdNotImplemented(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeReplyMessage(ctx, .error_msg, "command not yet implemented\n");
    return CmdError.CommandFailed;
}

// -- New command implementations --

fn cmdAttachSession(ctx: *Context, args: []const []const u8) CmdError!void {
    const target: ?[]const u8 = parseNamedOption(args, "-t");
    if (target) |name| {
        const session = ctx.server.findSession(name) orelse return CmdError.SessionNotFound;
        ctx.session = session;
        ctx.server.default_session = session;
    } else if (ctx.server.sessions.items.len == 1) {
        ctx.session = ctx.server.sessions.items[0];
        ctx.server.default_session = ctx.session;
    } else if (ctx.server.default_session) |session| {
        ctx.session = session;
    } else {
        return CmdError.SessionNotFound;
    }
}

fn cmdHasSession(ctx: *Context, args: []const []const u8) CmdError!void {
    const target = parseNamedOption(args, "-t") orelse {
        if (ctx.session != null) return;
        return CmdError.SessionNotFound;
    };
    if (ctx.server.findSession(target) == null) return CmdError.SessionNotFound;
}

fn cmdStartServer(_: *Context, _: []const []const u8) CmdError!void {
    // No-op: server is already running if this command was received.
}

fn cmdListClients(ctx: *Context, _: []const []const u8) CmdError!void {
    for (ctx.server.clients.items, 0..) |client, i| {
        const session_name = if (client.session) |s| s.name else "(none)";
        try writeOutput(ctx, "{d}: {s}\n", .{ i, session_name });
    }
}

fn cmdListCommands(ctx: *Context, args: []const []const u8) CmdError!void {
    const registry = ctx.registry orelse return CmdError.CommandFailed;

    // Single command lookup.
    if (args.len > 0) {
        const name = args[args.len - 1];
        if (name.len > 0 and name[0] != '-') {
            const def = registry.find(name) orelse {
                try writeReplyMessage(ctx, .error_msg, "unknown command\n");
                return CmdError.CommandFailed;
            };
            try writeOutput(ctx, "{s}\n", .{def.usage});
            return;
        }
    }

    // List all commands.
    const all = registry.listAll(ctx.allocator) catch return CmdError.OutOfMemory;
    defer ctx.allocator.free(all);
    for (all) |def| {
        try writeOutput(ctx, "{s}\n", .{def.usage});
    }
}

fn cmdLastPane(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    window.prevPane();
}

fn cmdNextLayout(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdPrevLayout(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdSelectLayout(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    _ = args;
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdRotateWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    var direction: Window.SwapDirection = .next;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-U")) direction = .prev;
    }
    window.swapActivePane(direction);
}

fn cmdSwapWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const src_name = parseNamedOption(args, "-s");
    const dst_name = parseNamedOption(args, "-t");

    const src_idx: usize = if (src_name) |name| blk: {
        const num = std.fmt.parseInt(u32, name, 10) catch return CmdError.InvalidArgs;
        const base = session.options.base_index;
        break :blk if (num >= base) @intCast(num - base) else return CmdError.WindowNotFound;
    } else if (session.active_window) |aw| blk: {
        for (session.windows.items, 0..) |w, i| {
            if (w == aw) break :blk i;
        }
        return CmdError.WindowNotFound;
    } else return CmdError.WindowNotFound;

    const dst_idx: usize = if (dst_name) |name| blk: {
        const num = std.fmt.parseInt(u32, name, 10) catch return CmdError.InvalidArgs;
        const base = session.options.base_index;
        break :blk if (num >= base) @intCast(num - base) else return CmdError.WindowNotFound;
    } else return CmdError.InvalidArgs;

    if (src_idx >= session.windows.items.len or dst_idx >= session.windows.items.len) return CmdError.WindowNotFound;
    const tmp = session.windows.items[src_idx];
    session.windows.items[src_idx] = session.windows.items[dst_idx];
    session.windows.items[dst_idx] = tmp;
}

fn cmdClearHistory(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return CmdError.CommandFailed;
    pane_state.screen.grid.hsize = 0;
}

fn cmdBindKey(ctx: *Context, args: []const []const u8) CmdError!void {
    const manager = ctx.binding_manager orelse {
        try writeReplyMessage(ctx, .error_msg, "bind-key: no binding manager available\n");
        return CmdError.CommandFailed;
    };

    var table_name: []const u8 = "prefix";
    var i: usize = 0;

    // Parse flags: -T table_name, -n (root table)
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-T")) {
            i += 1;
            if (i >= args.len) return CmdError.InvalidArgs;
            table_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-n")) {
            table_name = "root";
        } else {
            break;
        }
        i += 1;
    }

    // Next arg is the key string
    if (i >= args.len) return CmdError.InvalidArgs;
    const kr = key_string.stringToKey(args[i]) orelse {
        try writeReplyMessage(ctx, .error_msg, "bind-key: unknown key\n");
        return CmdError.CommandFailed;
    };
    i += 1;

    // Remaining args form the command
    if (i >= args.len) return CmdError.InvalidArgs;
    const cmd_parts = args[i..];

    // Join command parts with spaces
    var total_len: usize = 0;
    for (cmd_parts, 0..) |part, idx| {
        total_len += part.len;
        if (idx < cmd_parts.len - 1) total_len += 1;
    }
    const cmd_str = ctx.allocator.alloc(u8, total_len) catch return CmdError.OutOfMemory;
    defer ctx.allocator.free(cmd_str);
    var pos: usize = 0;
    for (cmd_parts, 0..) |part, idx| {
        @memcpy(cmd_str[pos..][0..part.len], part);
        pos += part.len;
        if (idx < cmd_parts.len - 1) {
            cmd_str[pos] = ' ';
            pos += 1;
        }
    }

    const table = manager.getOrCreateTable(table_name) catch return CmdError.OutOfMemory;
    table.bind(kr.key, kr.mods, cmd_str) catch return CmdError.OutOfMemory;
}

fn cmdUnbindKey(ctx: *Context, args: []const []const u8) CmdError!void {
    const manager = ctx.binding_manager orelse {
        try writeReplyMessage(ctx, .error_msg, "unbind-key: no binding manager available\n");
        return CmdError.CommandFailed;
    };

    var table_name: []const u8 = "prefix";
    var i: usize = 0;

    // Parse flags: -T table_name, -n (root table)
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-T")) {
            i += 1;
            if (i >= args.len) return CmdError.InvalidArgs;
            table_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-n")) {
            table_name = "root";
        } else {
            break;
        }
        i += 1;
    }

    if (i >= args.len) return CmdError.InvalidArgs;
    const kr = key_string.stringToKey(args[i]) orelse {
        try writeReplyMessage(ctx, .error_msg, "unbind-key: unknown key\n");
        return CmdError.CommandFailed;
    };

    const table = manager.getOrCreateTable(table_name) catch return CmdError.OutOfMemory;
    table.unbind(kr.key, kr.mods);
}

fn cmdSetWindowOption(ctx: *Context, args: []const []const u8) CmdError!void {
    return cmdSetOption(ctx, args);
}

fn cmdShowOptions(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (args.len > 0) {
        const name = args[args.len - 1];
        if (name.len > 0 and name[0] != '-') {
            if (std.mem.eql(u8, name, "base-index")) {
                try writeOutput(ctx, "base-index {d}\n", .{session.options.base_index});
            } else if (std.mem.eql(u8, name, "mouse")) {
                try writeOutput(ctx, "mouse {s}\n", .{if (session.options.mouse) "on" else "off"});
            } else if (std.mem.eql(u8, name, "status")) {
                try writeOutput(ctx, "status {s}\n", .{if (session.options.status) "on" else "off"});
            } else if (std.mem.eql(u8, name, "prefix")) {
                try writeOutput(ctx, "prefix C-{c}\n", .{@as(u8, @intCast(session.options.prefix_key + 'a' - 1))});
            } else {
                return CmdError.CommandFailed;
            }
            return;
        }
    }
    try writeOutput(ctx, "base-index {d}\n", .{session.options.base_index});
    try writeOutput(ctx, "mouse {s}\n", .{if (session.options.mouse) "on" else "off"});
    try writeOutput(ctx, "status {s}\n", .{if (session.options.status) "on" else "off"});
}

fn cmdShowWindowOptions(ctx: *Context, args: []const []const u8) CmdError!void {
    return cmdShowOptions(ctx, args);
}

fn cmdSetEnvironment(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeReplyMessage(ctx, .error_msg, "set-environment: not yet implemented\n");
    return CmdError.CommandFailed;
}

fn cmdShowEnvironment(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeReplyMessage(ctx, .error_msg, "show-environment: not yet implemented\n");
    return CmdError.CommandFailed;
}

fn cmdLoadBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];
    const buffer_name = parseNamedOption(args, "-b");

    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return CmdError.CommandFailed;
    defer _ = std.c.close(fd);

    var content_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < content_buf.len) {
        const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    ctx.server.paste_stack.push(content_buf[0..total], buffer_name) catch return CmdError.OutOfMemory;
}

fn cmdSaveBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];
    const buffer = try resolvePasteBuffer(ctx, parseNamedOption(args, "-b"));

    var append = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a")) append = true;
    }

    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);

    const flags: std.c.O = if (append)
        .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }
    else
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true };

    const fd = std.c.open(cpath, flags, @as(std.c.mode_t, 0o644));
    if (fd < 0) return CmdError.CommandFailed;
    defer _ = std.c.close(fd);

    _ = std.c.write(fd, buffer.data.ptr, buffer.data.len);
}

// -- Original command implementations --

fn cmdNewSession(ctx: *Context, args: []const []const u8) CmdError!void {
    var session_name: []const u8 = "0";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            session_name = args[i];
        }
    }

    const session = ctx.server.createSession(session_name, defaultShell(ctx.session), 80, 24) catch return CmdError.CommandFailed;
    ctx.session = session;
}

fn cmdKillServer(ctx: *Context, _: []const []const u8) CmdError!void {
    ctx.server.stop();
}

fn cmdKillSession(ctx: *Context, args: []const []const u8) CmdError!void {
    var target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        }
    }

    if (target) |name| {
        const session = ctx.server.findSession(name) orelse return CmdError.SessionNotFound;
        ctx.server.removeSession(session);
    } else if (ctx.session) |session| {
        ctx.session = null;
        ctx.server.removeSession(session);
    } else {
        return CmdError.SessionNotFound;
    }
}

fn cmdNewWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var name: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        }
    }

    const window = Window.init(ctx.allocator, name, 80, 24) catch return CmdError.OutOfMemory;
    errdefer window.deinit();

    const pane = spawnWindowPane(ctx.allocator, defaultShell(ctx.session), 80, 24) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer pane.deinit();

    window.addPane(pane) catch return CmdError.OutOfMemory;
    session.addWindow(window) catch return CmdError.OutOfMemory;
    session.selectWindow(window);
    ctx.server.trackPane(pane, window.sx, window.sy) catch return CmdError.CommandFailed;
}

fn cmdSplitWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var direction: CellType = .horizontal;
    var percent: u32 = 50;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            direction = .horizontal;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            direction = .vertical;
        } else if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            percent = std.fmt.parseInt(u32, args[i], 10) catch 50;
        }
    }

    const new_pane = spawnWindowPane(ctx.allocator, defaultShell(ctx.session), window.sx, window.sy) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer new_pane.deinit();
    window.splitActivePane(new_pane, direction, percent) catch return CmdError.CommandFailed;
    ctx.server.trackPane(new_pane, new_pane.sx, new_pane.sy) catch return CmdError.CommandFailed;
}

fn cmdSelectPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const target = args[i];
            if (std.mem.eql(u8, target, ":.+") or std.mem.eql(u8, target, ":+")) {
                window.nextPane();
                return;
            }
            if (target.len >= 2 and target[0] == '%') {
                const pane_id = std.fmt.parseInt(u32, target[1..], 10) catch return CmdError.InvalidArgs;
                if (!window.selectPaneById(pane_id)) return CmdError.PaneNotFound;
                return;
            }
            const pane_index = std.fmt.parseInt(usize, target, 10) catch return CmdError.InvalidArgs;
            if (!window.selectPaneByIndex(pane_index)) return CmdError.PaneNotFound;
            return;
        }
        if (std.mem.eql(u8, args[i], "-U") or std.mem.eql(u8, args[i], "-L")) {
            window.prevPane();
            return;
        }
        if (std.mem.eql(u8, args[i], "-D") or std.mem.eql(u8, args[i], "-R")) {
            window.nextPane();
            return;
        }
    }

    window.nextPane();
}

fn cmdSelectWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (parseTargetWindow(args)) |window_number| {
        const window = session.findWindowByNumber(window_number) orelse return CmdError.WindowNotFound;
        session.selectWindow(window);
        return;
    }
    session.nextWindow();
}

fn cmdDetachClient(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (ctx.server.clients.items, 0..) |client, i| {
        if (client.session == session) {
            ctx.server.detachClient(i);
        }
    }
}

fn cmdListSessions(ctx: *Context, _: []const []const u8) CmdError!void {
    for (ctx.server.sessions.items) |session| {
        try writeOutput(ctx, "{s}: {d} windows (attached: {d})\n", .{
            session.name,
            session.windowCount(),
            session.attached,
        });
    }
}

fn cmdSendKeys(ctx: *Context, args: []const []const u8) CmdError!void {
    if (ctx.server.choose_tree_state != null) {
        for (args) |key_str| {
            if (try handleChooseTreeKey(ctx, null, key_str)) continue;
        }
        return;
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    for (args) |key_str| {
        if (pane.prompt_state != null and try handlePromptKey(ctx, pane, key_str)) {
            continue;
        }
        if (try handleChooseTreeKey(ctx, pane, key_str)) {
            continue;
        }
        if (pane.copy_state != null and try handleCopyModeKey(ctx, pane, key_str)) {
            continue;
        }
        if (std.mem.eql(u8, key_str, "Enter")) {
            _ = std.c.write(pane.fd, "\n", 1);
        } else if (std.mem.eql(u8, key_str, "Escape")) {
            _ = std.c.write(pane.fd, "\x1b", 1);
        } else if (std.mem.eql(u8, key_str, "Tab")) {
            _ = std.c.write(pane.fd, "\t", 1);
        } else if (std.mem.eql(u8, key_str, "Space")) {
            _ = std.c.write(pane.fd, " ", 1);
        } else if (std.mem.eql(u8, key_str, "BSpace")) {
            _ = std.c.write(pane.fd, "\x7f", 1);
        } else if (key_str.len == 3 and key_str[0] == 'C' and key_str[1] == '-') {
            const ch = key_str[2];
            if (ch >= 'a' and ch <= 'z') {
                const ctrl: [1]u8 = .{ch - 'a' + 1};
                _ = std.c.write(pane.fd, &ctrl, 1);
            } else if (ch >= 'A' and ch <= 'Z') {
                const ctrl: [1]u8 = .{ch - 'A' + 1};
                _ = std.c.write(pane.fd, &ctrl, 1);
            } else {
                _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
            }
        } else {
            _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
        }
    }
}

fn cmdSendPrefix(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0 or session.options.prefix_key > 0xff) return CmdError.CommandFailed;

    const prefix: [1]u8 = .{@intCast(session.options.prefix_key)};
    _ = std.c.write(pane.fd, &prefix, 1);
}

fn cmdNextWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    session.nextWindow();
}

fn cmdPrevWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    session.prevWindow();
}

fn cmdLastWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (!session.lastWindow()) return CmdError.WindowNotFound;
}

fn cmdKillWindow(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items) |pane| {
        ctx.server.untrackPane(pane.id);
    }
    const empty = session.removeWindow(window);
    if (empty) {
        ctx.session = null;
        ctx.server.removeSession(session);
    }
}

fn cmdKillPane(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    ctx.server.untrackPane(pane.id);
    const window_empty = window.removePane(pane);
    if (window_empty) {
        const session_empty = session.removeWindow(window);
        if (session_empty) {
            ctx.session = null;
            ctx.server.removeSession(session);
        }
    } else if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdRenameSession(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (args.len == 0) return CmdError.InvalidArgs;
    session.rename(args[args.len - 1]) catch return CmdError.OutOfMemory;
}

fn cmdRenameWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    if (args.len == 0) return CmdError.InvalidArgs;
    window.rename(args[args.len - 1]) catch return CmdError.OutOfMemory;
}

fn cmdResizePane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    var dx: i32 = 0;
    var dy: i32 = 0;
    var amount: u32 = 1;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-Z")) {
            _ = window.toggleZoom();
            return;
        } else if (std.mem.eql(u8, args[i], "-U")) {
            dy = -1;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            dy = 1;
        } else if (std.mem.eql(u8, args[i], "-L")) {
            dx = -1;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            dx = 1;
        } else {
            amount = std.fmt.parseInt(u32, args[i], 10) catch 1;
        }
    }

    if (dx == 0 and dy == 0) return;

    const new_sx = if (dx < 0)
        @max(1, pane.sx -| amount)
    else if (dx > 0)
        pane.sx + amount
    else
        pane.sx;

    const new_sy = if (dy < 0)
        @max(1, pane.sy -| amount)
    else if (dy > 0)
        pane.sy + amount
    else
        pane.sy;

    pane.resize(new_sx, new_sy);
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdSwapPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var direction: Window.SwapDirection = .next;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-U")) {
            direction = .prev;
        } else if (std.mem.eql(u8, arg, "-D")) {
            direction = .next;
        }
    }

    window.swapActivePane(direction);
}

fn cmdDisplayMessage(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len > 0) {
        try writeOutput(ctx, "{s}\n", .{args[args.len - 1]});
    }
}

fn cmdSetOption(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    if (args.len < 2) return CmdError.InvalidArgs;

    var index: usize = 0;
    while (index < args.len and args[index].len > 0 and args[index][0] == '-') : (index += 1) {
        if (!std.mem.eql(u8, args[index], "-g")) return CmdError.InvalidArgs;
    }
    if (index + 2 != args.len) return CmdError.InvalidArgs;

    const name = args[index];
    const value = args[index + 1];

    if (std.mem.eql(u8, name, "base-index")) {
        session.options.base_index = std.fmt.parseInt(u32, value, 10) catch return CmdError.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "mouse")) {
        session.options.mouse = parseBooleanValue(value) orelse return CmdError.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "status")) {
        session.options.status = parseBooleanValue(value) orelse return CmdError.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "prefix")) {
        session.options.prefix_key = parsePrefixValue(value) orelse return CmdError.InvalidArgs;
        return;
    }

    return CmdError.CommandFailed;
}

fn cmdSourceFile(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];

    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) return CmdError.CommandFailed;
    defer _ = std.c.close(fd);

    var content_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < content_buf.len) {
        const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    try executeCommandString(ctx, content_buf[0..total]);
}

fn cmdListWindows(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (session.windows.items, 0..) |window, i| {
        try writeOutput(ctx, "{d}: {s} ({d} panes)\n", .{
            session.options.base_index + @as(u32, @intCast(i)),
            window.name,
            window.paneCount(),
        });
    }
}

fn cmdListPanes(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items, 0..) |pane, i| {
        try writeOutput(ctx, "{d}: pane {d} [{d}x{d}]\n", .{ i, pane.id, pane.sx, pane.sy });
    }
}

fn cmdSetBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const name = parseNamedOption(args, "-b");
    var data: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b") and i + 1 < args.len) {
            i += 1;
            continue;
        }
        data = args[i];
    }

    const buffer_data = data orelse return CmdError.InvalidArgs;
    ctx.server.paste_stack.push(buffer_data, name) catch return CmdError.OutOfMemory;
}

fn cmdPasteBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    const buffer = try resolvePasteBuffer(ctx, parseNamedOption(args, "-b"));
    _ = std.c.write(pane.fd, buffer.data.ptr, buffer.data.len);
}

fn cmdCopyMode(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return CmdError.CommandFailed;

    var state = copy_mod.CopyState.init();
    state.cx = pane_state.screen.cx;
    state.cy = pane_state.screen.grid.hsize + pane_state.screen.cy;
    pane.copy_state = state;
}

fn cmdCommandPrompt(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    var state = PromptState{};
    for (args, 0..) |arg, i| {
        if (i > 0) appendPromptBytes(&state, " ");
        appendPromptBytes(&state, arg);
    }
    pane.prompt_state = state;
    try writeOutput(ctx, ":\n", .{});
}

fn cmdListBuffers(ctx: *Context, _: []const []const u8) CmdError!void {
    const count = ctx.server.paste_stack.count();
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const buffer = ctx.server.paste_stack.get(index) orelse continue;
        if (buffer.name) |name| {
            try writeOutput(ctx, "{d}: {s} ({d} bytes)\n", .{ index, name, buffer.data.len });
        } else {
            try writeOutput(ctx, "{d}: buffer{d} ({d} bytes)\n", .{ index, index, buffer.data.len });
        }
    }
}

fn cmdShowBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const buffer = try resolvePasteBuffer(ctx, parseNamedOption(args, "-b"));
    try writeOutput(ctx, "{s}\n", .{buffer.data});
}

fn cmdDeleteBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    if (parseNamedOption(args, "-b")) |name| {
        if (!ctx.server.paste_stack.removeByName(name)) return CmdError.BufferNotFound;
        return;
    }
    if (!ctx.server.paste_stack.removeTop()) return CmdError.BufferNotFound;
}

fn cmdListKeys(ctx: *Context, _: []const []const u8) CmdError!void {
    const manager = ctx.binding_manager orelse {
        try writeReplyMessage(ctx, .error_msg, "list-keys: no binding manager available\n");
        return CmdError.CommandFailed;
    };

    var iter = manager.tables.iterator();
    while (iter.next()) |entry| {
        const table_name = entry.key_ptr.*;
        const table = entry.value_ptr;
        for (table.bindings.items) |binding| {
            var key_buf: [32]u8 = undefined;
            const rendered_key = formatBindingKey(&key_buf, binding.key, binding.modifiers);
            switch (binding.action) {
                .command => |command| try writeOutput(ctx, "-T {s} {s} {s}\n", .{ table_name, rendered_key, command }),
                .none => {},
            }
        }
    }
}

fn cmdChooseTree(ctx: *Context, args: []const []const u8) CmdError!void {
    const pane = if (ctx.session) |session|
        if (session.active_window) |window| window.active_pane else null
    else
        null;

    var sessions_only = false;
    var windows_only = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-s")) sessions_only = true;
        if (std.mem.eql(u8, arg, "-w")) windows_only = true;
    }

    var state = ChooseTreeState.init(ctx.allocator, 20);
    errdefer state.deinit();

    for (ctx.server.sessions.items) |tree_session| {
        try addChooseTreeEntry(&state, tree_session.name, 0, !sessions_only, tree_session, null, null);
        if (sessions_only) continue;

        for (tree_session.windows.items, 0..) |tree_window, window_idx| {
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d}: {s} ({d} panes)", .{
                tree_session.options.base_index + @as(u32, @intCast(window_idx)),
                tree_window.name,
                tree_window.paneCount(),
            }) catch return CmdError.CommandFailed;
            try addChooseTreeEntry(&state, label, 1, !windows_only and tree_window.paneCount() > 0, tree_session, tree_window, null);
            if (windows_only) continue;

            for (tree_window.panes.items, 0..) |tree_pane, pane_idx| {
                var pane_label_buf: [256]u8 = undefined;
                const pane_label = std.fmt.bufPrint(&pane_label_buf, "{d}: pane {d} [{d}x{d}]", .{
                    pane_idx,
                    tree_pane.id,
                    tree_pane.sx,
                    tree_pane.sy,
                }) catch return CmdError.CommandFailed;
                try addChooseTreeEntry(&state, pane_label, 2, false, tree_session, tree_window, tree_pane);
            }
        }
    }

    if (ctx.server.choose_tree_state) |*existing| existing.deinit();
    ctx.server.choose_tree_state = state;
    try renderChooseTree(ctx, pane);
}

fn cmdClockMode(ctx: *Context, _: []const []const u8) CmdError!void {
    var now: i64 = 0;
    _ = time(&now);
    const tm_ptr = localtime(&now) orelse return CmdError.CommandFailed;

    var line_buf: [64]u8 = undefined;
    const clock = std.fmt.bufPrint(&line_buf, " {d:0>2}:{d:0>2}:{d:0>2} ", .{
        @as(u32, @intCast(tm_ptr.tm_hour)),
        @as(u32, @intCast(tm_ptr.tm_min)),
        @as(u32, @intCast(tm_ptr.tm_sec)),
    }) catch return CmdError.CommandFailed;

    try writeOutput(ctx, "┌──────────┐\n", .{});
    try writeOutput(ctx, "│{s}│\n", .{clock});
    try writeOutput(ctx, "└──────────┘\n", .{});
}

fn cmdRunShell(_: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const command = args[args.len - 1];
    const pid = try spawnShellChild(command);
    _ = try waitForChildExit(pid);
}

fn cmdIfShell(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len < 2) return CmdError.InvalidArgs;

    const pid = try spawnShellChild(args[0]);
    const status = try waitForChildExit(pid);
    const next_command = if (childExitCode(status) == 0)
        args[1]
    else if (args.len >= 3)
        args[2]
    else
        return;

    try executeCommandString(ctx, next_command);
}

extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) i32;

test "registry register and find" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.registerBuiltins();

    try std.testing.expect(reg.find("new-session") != null);
    try std.testing.expect(reg.find("new") != null);
    try std.testing.expect(reg.find("kill-server") != null);
    try std.testing.expect(reg.find("send-prefix") != null);
    try std.testing.expect(reg.find("if-shell") != null);
    try std.testing.expect(reg.find("if") != null);
    try std.testing.expect(reg.find("set-option") != null);
    try std.testing.expect(reg.find("set") != null);
    try std.testing.expect(reg.find("nonexistent") == null);
}

test "parse target window helper" {
    const args = [_][]const u8{ "-t", ":3" };
    try std.testing.expectEqual(@as(?u32, 3), parseTargetWindow(&args));
}

test "formatBindingKey renders ctrl meta modifiers" {
    var buf: [32]u8 = undefined;
    const rendered = formatBindingKey(&buf, 'b', .{ .ctrl = true, .meta = true });
    try std.testing.expectEqualStrings("C-M-b", rendered);
}

test "extractCopySelection reads visual line from screen history space" {
    var fake = struct {
        screen: screen_mod.Screen,
    }{
        .screen = screen_mod.Screen.init(std.testing.allocator, 20, 5, 10),
    };
    defer fake.screen.deinit();

    const line = fake.screen.grid.getLine(0);
    line.getCell(0).codepoint = 'h';
    line.getCell(1).codepoint = 'e';
    line.getCell(2).codepoint = 'l';
    line.getCell(3).codepoint = 'l';
    line.getCell(4).codepoint = 'o';

    var state = copy_mod.CopyState.init();
    state.mode = .visual_line;
    state.sel_start_y = 0;
    state.cy = 0;

    const text = try extractCopySelection(std.testing.allocator, &fake, &state);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello", text);
}

test "appendPromptBytes appends text" {
    var state = PromptState{};
    appendPromptBytes(&state, "display-message");
    appendPromptBytes(&state, " ");
    appendPromptBytes(&state, "ok");
    try std.testing.expectEqualStrings("display-message ok", state.buffer[0..state.len]);
}

test "addChooseTreeEntry stores pane metadata" {
    const alloc = std.testing.allocator;
    var choose_state = ChooseTreeState.init(alloc, 10);
    defer choose_state.deinit();

    const session = try Session.init(alloc, "demo");
    defer session.deinit();
    var window = try Window.init(alloc, "win", 80, 24);
    const pane = try Pane.init(alloc, 80, 24);
    try window.addPane(pane);
    try session.addWindow(window);

    try addChooseTreeEntry(&choose_state, "pane", 2, false, session, window, pane);
    try std.testing.expectEqual(@as(usize, 1), choose_state.items.items.len);
    try std.testing.expect(choose_state.items.items[0].pane != null);
}

test "if-shell executes success branch" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-if-shell-success.sock");
    defer server.deinit();

    var reg = Registry.init(alloc);
    defer reg.deinit();
    try reg.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = Context{
        .server = &server,
        .session = null,
        .window = null,
        .pane = null,
        .allocator = alloc,
        .reply_fd = fds[1],
        .registry = &reg,
    };

    try reg.execute(&ctx, "if-shell", &.{ "true", "display-message success", "display-message failure" });

    var msg = try protocol.recvMessageAlloc(alloc, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expectEqualStrings("success\n", msg.payload);
}

test "if-shell executes failure branch" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-if-shell-failure.sock");
    defer server.deinit();

    var reg = Registry.init(alloc);
    defer reg.deinit();
    try reg.registerBuiltins();

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    defer _ = std.c.close(fds[1]);

    var ctx = Context{
        .server = &server,
        .session = null,
        .window = null,
        .pane = null,
        .allocator = alloc,
        .reply_fd = fds[1],
        .registry = &reg,
    };

    try reg.execute(&ctx, "if-shell", &.{ "false", "display-message success", "display-message failure" });

    var msg = try protocol.recvMessageAlloc(alloc, fds[0]);
    defer msg.deinit();
    try std.testing.expectEqual(protocol.MessageType.output, msg.msg_type);
    try std.testing.expectEqualStrings("failure\n", msg.payload);
}

test "send-prefix writes configured prefix byte to active pane" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-send-prefix.sock");
    defer server.deinit();

    const session = try Session.init(alloc, "demo");
    try server.sessions.append(alloc, session);
    server.default_session = session;

    var window = try Window.init(alloc, "win", 80, 24);
    const pane = try Pane.init(alloc, 80, 24);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try window.addPane(pane);
    try session.addWindow(window);
    session.selectWindow(window);
    session.options.prefix_key = 0x01;

    var ctx = Context{
        .server = &server,
        .session = session,
        .window = window,
        .pane = pane,
        .allocator = alloc,
    };

    try cmdSendPrefix(&ctx, &.{});

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &buf, buf.len));
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}

test "set-option updates session base index" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-set-base-index.sock");
    defer server.deinit();

    const session = try Session.init(alloc, "demo");
    try server.sessions.append(alloc, session);

    var ctx = Context{
        .server = &server,
        .session = session,
        .window = null,
        .pane = null,
        .allocator = alloc,
    };

    try cmdSetOption(&ctx, &.{ "-g", "base-index", "3" });
    try std.testing.expectEqual(@as(u32, 3), session.options.base_index);
}

test "set-option updates session booleans" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-set-bool.sock");
    defer server.deinit();

    const session = try Session.init(alloc, "demo");
    try server.sessions.append(alloc, session);

    var ctx = Context{
        .server = &server,
        .session = session,
        .window = null,
        .pane = null,
        .allocator = alloc,
    };

    try cmdSetOption(&ctx, &.{ "-g", "mouse", "on" });
    try cmdSetOption(&ctx, &.{ "-g", "status", "off" });
    try std.testing.expect(session.options.mouse);
    try std.testing.expect(!session.options.status);
}

test "set-option updates prefix for send-prefix" {
    const alloc = std.testing.allocator;
    var server = try Server.init(alloc, "/tmp/agentmux-set-prefix.sock");
    defer server.deinit();

    var session = try Session.init(alloc, "demo");
    try server.sessions.append(alloc, session);
    server.default_session = session;

    var window = try Window.init(alloc, "win", 80, 24);
    const pane = try Pane.init(alloc, 80, 24);

    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(i32, 0), std.c.pipe(&fds));
    defer _ = std.c.close(fds[0]);
    pane.fd = fds[1];

    try window.addPane(pane);
    try session.addWindow(window);
    session.selectWindow(window);

    var ctx = Context{
        .server = &server,
        .session = session,
        .window = window,
        .pane = pane,
        .allocator = alloc,
    };

    try cmdSetOption(&ctx, &.{ "-g", "prefix", "C-a" });
    try cmdSendPrefix(&ctx, &.{});

    var buf: [1]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 1), std.c.read(fds[0], &buf, buf.len));
    try std.testing.expectEqual(@as(u8, 0x01), buf[0]);
}
