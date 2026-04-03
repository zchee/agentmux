const std = @import("std");
const protocol = @import("../protocol.zig");
const config_parser = @import("../config/parser.zig");
const binding_mod = @import("../keybind/bindings.zig");
const key_string = @import("../keybind/string.zig");
const paste_mod = @import("../copy/paste.zig");
const copy_mod = @import("../copy/copy.zig");
const tree_mod = @import("../mode/tree.zig");
const screen_mod = @import("../screen/screen.zig");
const hooks_mod = @import("../hooks/hooks.zig");
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
        try self.register(.{ .name = "lock-client", .alias = "lockc", .min_args = 0, .max_args = 2, .usage = "lock-client (lockc) [-t target-client]", .handler = cmdLockClient });
        try self.register(.{ .name = "lock-server", .alias = "lock", .min_args = 0, .max_args = 0, .usage = "lock-server (lock)", .handler = cmdLockServer });
        try self.register(.{ .name = "lock-session", .alias = "locks", .min_args = 0, .max_args = 2, .usage = "lock-session (locks) [-t target-session]", .handler = cmdLockSession });
        try self.register(.{ .name = "new-session", .alias = "new", .min_args = 0, .max_args = 20, .usage = "new-session (new) [-AdDEPX] [-c start-directory] [-e environment] [-F format] [-f flags] [-n window-name] [-s session-name] [-t target-session] [-x width] [-y height] [shell-command [argument ...]]", .handler = cmdNewSession });
        try self.register(.{ .name = "refresh-client", .alias = "refresh", .min_args = 0, .max_args = 20, .usage = "refresh-client (refresh) [-cDlLRSU] [-A pane:state] [-B name:what:format] [-C XxY] [-f flags] [-r pane:report] [-t target-client] [adjustment]", .handler = cmdRefreshClient });
        try self.register(.{ .name = "rename-session", .alias = "rename", .min_args = 1, .max_args = 4, .usage = "rename-session (rename) [-t target-session] new-name", .handler = cmdRenameSession });
        try self.register(.{ .name = "show-messages", .alias = "showmsgs", .min_args = 0, .max_args = 4, .usage = "show-messages (showmsgs) [-JT] [-t target-client]", .handler = cmdShowMessages });
        try self.register(.{ .name = "start-server", .alias = "start", .min_args = 0, .max_args = 0, .usage = "start-server (start)", .handler = cmdStartServer });
        try self.register(.{ .name = "suspend-client", .alias = "suspendc", .min_args = 0, .max_args = 2, .usage = "suspend-client (suspendc) [-t target-client]", .handler = cmdSuspendClient });
        try self.register(.{ .name = "switch-client", .alias = "switchc", .min_args = 0, .max_args = 14, .usage = "switch-client (switchc) [-ElnprZ] [-c target-client] [-t target-session] [-T key-table] [-O order]", .handler = cmdSwitchClient });

        // -- Window commands --
        try self.register(.{ .name = "choose-tree", .alias = null, .min_args = 0, .max_args = 14, .usage = "choose-tree [-GNrswZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdChooseTree });
        try self.register(.{ .name = "find-window", .alias = "findw", .min_args = 1, .max_args = 10, .usage = "find-window (findw) [-CiNrTZ] [-t target-pane] match-string", .handler = cmdFindWindow });
        try self.register(.{ .name = "kill-window", .alias = "killw", .min_args = 0, .max_args = 4, .usage = "kill-window (killw) [-a] [-t target-window]", .handler = cmdKillWindow });
        try self.register(.{ .name = "last-window", .alias = "last", .min_args = 0, .max_args = 2, .usage = "last-window (last) [-t target-session]", .handler = cmdLastWindow });
        try self.register(.{ .name = "link-window", .alias = "linkw", .min_args = 0, .max_args = 8, .usage = "link-window (linkw) [-abdk] [-s src-window] [-t dst-window]", .handler = cmdLinkWindow });
        try self.register(.{ .name = "list-windows", .alias = "lsw", .min_args = 0, .max_args = 10, .usage = "list-windows (lsw) [-ar] [-F format] [-f filter] [-O order] [-t target-session]", .handler = cmdListWindows });
        try self.register(.{ .name = "move-window", .alias = "movew", .min_args = 0, .max_args = 10, .usage = "move-window (movew) [-abdkr] [-s src-window] [-t dst-window]", .handler = cmdMoveWindow });
        try self.register(.{ .name = "new-window", .alias = "neww", .min_args = 0, .max_args = 20, .usage = "new-window (neww) [-abdkPS] [-c start-directory] [-e environment] [-F format] [-n window-name] [-t target-window] [shell-command [argument ...]]", .handler = cmdNewWindow });
        try self.register(.{ .name = "next-layout", .alias = "nextl", .min_args = 0, .max_args = 2, .usage = "next-layout (nextl) [-t target-window]", .handler = cmdNextLayout });
        try self.register(.{ .name = "next-window", .alias = "next", .min_args = 0, .max_args = 4, .usage = "next-window (next) [-a] [-t target-session]", .handler = cmdNextWindow });
        try self.register(.{ .name = "previous-layout", .alias = "prevl", .min_args = 0, .max_args = 2, .usage = "previous-layout (prevl) [-t target-window]", .handler = cmdPrevLayout });
        try self.register(.{ .name = "previous-window", .alias = "prev", .min_args = 0, .max_args = 4, .usage = "previous-window (prev) [-a] [-t target-session]", .handler = cmdPrevWindow });
        try self.register(.{ .name = "rename-window", .alias = "renamew", .min_args = 1, .max_args = 4, .usage = "rename-window (renamew) [-t target-window] new-name", .handler = cmdRenameWindow });
        try self.register(.{ .name = "resize-window", .alias = "resizew", .min_args = 0, .max_args = 10, .usage = "resize-window (resizew) [-aADLRU] [-x width] [-y height] [-t target-window] [adjustment]", .handler = cmdResizeWindow });
        try self.register(.{ .name = "respawn-window", .alias = "respawnw", .min_args = 0, .max_args = 10, .usage = "respawn-window (respawnw) [-k] [-c start-directory] [-e environment] [-t target-window] [shell-command [argument ...]]", .handler = cmdRespawnWindow });
        try self.register(.{ .name = "rotate-window", .alias = "rotatew", .min_args = 0, .max_args = 6, .usage = "rotate-window (rotatew) [-DUZ] [-t target-window]", .handler = cmdRotateWindow });
        try self.register(.{ .name = "select-layout", .alias = "selectl", .min_args = 0, .max_args = 6, .usage = "select-layout (selectl) [-Enop] [-t target-pane] [layout-name]", .handler = cmdSelectLayout });
        try self.register(.{ .name = "select-window", .alias = "selectw", .min_args = 0, .max_args = 6, .usage = "select-window (selectw) [-lnpT] [-t target-window]", .handler = cmdSelectWindow });
        try self.register(.{ .name = "split-window", .alias = "splitw", .min_args = 0, .max_args = 20, .usage = "split-window (splitw) [-bdefhIPvZ] [-c start-directory] [-e environment] [-F format] [-l size] [-t target-pane] [shell-command [argument ...]]", .handler = cmdSplitWindow });
        try self.register(.{ .name = "swap-window", .alias = "swapw", .min_args = 0, .max_args = 6, .usage = "swap-window (swapw) [-d] [-s src-window] [-t dst-window]", .handler = cmdSwapWindow });
        try self.register(.{ .name = "unlink-window", .alias = "unlinkw", .min_args = 0, .max_args = 4, .usage = "unlink-window (unlinkw) [-k] [-t target-window]", .handler = cmdUnlinkWindow });

        // -- Pane commands --
        try self.register(.{ .name = "break-pane", .alias = "breakp", .min_args = 0, .max_args = 10, .usage = "break-pane (breakp) [-abdP] [-F format] [-n window-name] [-s src-pane] [-t dst-window]", .handler = cmdBreakPane });
        try self.register(.{ .name = "capture-pane", .alias = "capturep", .min_args = 0, .max_args = 12, .usage = "capture-pane (capturep) [-aCeJMNpPqT] [-b buffer-name] [-E end-line] [-S start-line] [-t target-pane]", .handler = cmdCapturePane });
        try self.register(.{ .name = "display-panes", .alias = "displayp", .min_args = 0, .max_args = 6, .usage = "display-panes (displayp) [-bN] [-d duration] [-t target-client] [template]", .handler = cmdDisplayPanes });
        try self.register(.{ .name = "join-pane", .alias = "joinp", .min_args = 0, .max_args = 10, .usage = "join-pane (joinp) [-bdfhv] [-l size] [-s src-pane] [-t dst-pane]", .handler = cmdJoinPane });
        try self.register(.{ .name = "kill-pane", .alias = "killp", .min_args = 0, .max_args = 4, .usage = "kill-pane (killp) [-a] [-t target-pane]", .handler = cmdKillPane });
        try self.register(.{ .name = "last-pane", .alias = "lastp", .min_args = 0, .max_args = 4, .usage = "last-pane (lastp) [-deZ] [-t target-window]", .handler = cmdLastPane });
        try self.register(.{ .name = "list-panes", .alias = "lsp", .min_args = 0, .max_args = 8, .usage = "list-panes (lsp) [-asr] [-F format] [-f filter] [-O order] [-t target-window]", .handler = cmdListPanes });
        try self.register(.{ .name = "move-pane", .alias = "movep", .min_args = 0, .max_args = 10, .usage = "move-pane (movep) [-bdfhv] [-l size] [-s src-pane] [-t dst-pane]", .handler = cmdMovePane });
        try self.register(.{ .name = "pipe-pane", .alias = "pipep", .min_args = 0, .max_args = 6, .usage = "pipe-pane (pipep) [-IOo] [-t target-pane] [shell-command]", .handler = cmdPipePane });
        try self.register(.{ .name = "resize-pane", .alias = "resizep", .min_args = 0, .max_args = 10, .usage = "resize-pane (resizep) [-DLMRTUZ] [-x width] [-y height] [-t target-pane] [adjustment]", .handler = cmdResizePane });
        try self.register(.{ .name = "respawn-pane", .alias = "respawnp", .min_args = 0, .max_args = 10, .usage = "respawn-pane (respawnp) [-k] [-c start-directory] [-e environment] [-t target-pane] [shell-command [argument ...]]", .handler = cmdRespawnPane });
        try self.register(.{ .name = "select-pane", .alias = "selectp", .min_args = 0, .max_args = 10, .usage = "select-pane (selectp) [-DdeLlMmRUZ] [-T title] [-t target-pane]", .handler = cmdSelectPane });
        try self.register(.{ .name = "swap-pane", .alias = "swapp", .min_args = 0, .max_args = 6, .usage = "swap-pane (swapp) [-dDUZ] [-s src-pane] [-t dst-pane]", .handler = cmdSwapPane });

        // -- Key binding commands --
        try self.register(.{ .name = "bind-key", .alias = "bind", .min_args = 1, .max_args = 20, .usage = "bind-key (bind) [-nr] [-T key-table] [-N note] key [command [argument ...]]", .handler = cmdBindKey });
        try self.register(.{ .name = "list-keys", .alias = "lsk", .min_args = 0, .max_args = 12, .usage = "list-keys (lsk) [-1aNP] [-T key-table] [key]", .handler = cmdListKeys });
        try self.register(.{ .name = "send-keys", .alias = "send", .min_args = 0, .max_args = 30, .usage = "send-keys (send) [-FHKlMRX] [-c target-client] [-N repeat-count] [-t target-pane] [key ...]", .handler = cmdSendKeys });
        try self.register(.{ .name = "send-prefix", .alias = null, .min_args = 0, .max_args = 4, .usage = "send-prefix [-2] [-t target-pane]", .handler = cmdSendPrefix });
        try self.register(.{ .name = "unbind-key", .alias = "unbind", .min_args = 0, .max_args = 8, .usage = "unbind-key (unbind) [-anq] [-T key-table] [key]", .handler = cmdUnbindKey });

        // -- Options commands --
        try self.register(.{ .name = "set-option", .alias = "set", .min_args = 1, .max_args = 10, .usage = "set-option (set) [-aFgopqsuUw] [-t target-pane] option [value]", .handler = cmdSetOption });
        try self.register(.{ .name = "set-window-option", .alias = "setw", .min_args = 1, .max_args = 8, .usage = "set-window-option (setw) [-aFgoqu] [-t target-window] option [value]", .handler = cmdSetWindowOption });
        try self.register(.{ .name = "show-options", .alias = "show", .min_args = 0, .max_args = 8, .usage = "show-options (show) [-AgHpqsvw] [-t target-pane] [option]", .handler = cmdShowOptions });
        try self.register(.{ .name = "show-window-options", .alias = "showw", .min_args = 0, .max_args = 6, .usage = "show-window-options (showw) [-gv] [-t target-window] [option]", .handler = cmdShowWindowOptions });

        // -- Environment commands --
        try self.register(.{ .name = "set-environment", .alias = "setenv", .min_args = 1, .max_args = 8, .usage = "set-environment (setenv) [-Fhgru] [-t target-session] variable [value]", .handler = cmdSetEnvironment });
        try self.register(.{ .name = "show-environment", .alias = "showenv", .min_args = 0, .max_args = 6, .usage = "show-environment (showenv) [-hgs] [-t target-session] [variable]", .handler = cmdShowEnvironment });

        // -- Hook commands --
        try self.register(.{ .name = "set-hook", .alias = null, .min_args = 0, .max_args = 10, .usage = "set-hook [-agpRuw] [-t target-pane] hook [command]", .handler = cmdSetHook });
        try self.register(.{ .name = "show-hooks", .alias = null, .min_args = 0, .max_args = 6, .usage = "show-hooks [-gpw] [-t target-pane] [hook]", .handler = cmdShowHooks });

        // -- Display commands --
        try self.register(.{ .name = "clock-mode", .alias = null, .min_args = 0, .max_args = 2, .usage = "clock-mode [-t target-pane]", .handler = cmdClockMode });
        try self.register(.{ .name = "display-menu", .alias = "menu", .min_args = 0, .max_args = 30, .usage = "display-menu (menu) [-MO] [-b border-lines] [-c target-client] [-C starting-choice] [-H selected-style] [-s style] [-S border-style] [-t target-pane] [-T title] [-x position] [-y position] name [key] [command] ...", .handler = cmdDisplayMenu });
        try self.register(.{ .name = "display-message", .alias = "display", .min_args = 0, .max_args = 12, .usage = "display-message (display) [-aCIlNpv] [-c target-client] [-d delay] [-F format] [-t target-pane] [message]", .handler = cmdDisplayMessage });
        try self.register(.{ .name = "display-popup", .alias = "popup", .min_args = 0, .max_args = 30, .usage = "display-popup (popup) [-BCEkN] [-b border-lines] [-c target-client] [-d start-directory] [-e environment] [-h height] [-s style] [-S border-style] [-t target-pane] [-T title] [-w width] [-x position] [-y position] [shell-command [argument ...]]", .handler = cmdDisplayPopup });

        // -- Buffer commands --
        try self.register(.{ .name = "choose-buffer", .alias = null, .min_args = 0, .max_args = 14, .usage = "choose-buffer [-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdChooseBuffer });
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
        try self.register(.{ .name = "choose-client", .alias = null, .min_args = 0, .max_args = 12, .usage = "choose-client [-NrZ] [-F format] [-f filter] [-K key-format] [-O sort-order] [-t target-pane] [template]", .handler = cmdChooseClient });
        try self.register(.{ .name = "command-prompt", .alias = null, .min_args = 0, .max_args = 12, .usage = "command-prompt [-1beFiklN] [-I inputs] [-p prompts] [-t target-client] [-T prompt-type] [template]", .handler = cmdCommandPrompt });
        try self.register(.{ .name = "confirm-before", .alias = "confirm", .min_args = 1, .max_args = 10, .usage = "confirm-before (confirm) [-by] [-c confirm-key] [-p prompt] [-t target-client] command", .handler = cmdConfirmBefore });
        try self.register(.{ .name = "customize-mode", .alias = null, .min_args = 0, .max_args = 8, .usage = "customize-mode [-NZ] [-F format] [-f filter] [-t target-pane]", .handler = cmdCustomizeMode });

        // -- Config commands --
        try self.register(.{ .name = "source-file", .alias = "source", .min_args = 1, .max_args = 8, .usage = "source-file (source) [-Fnqv] [-t target-pane] path ...", .handler = cmdSourceFile });

        // -- Shell/job commands --
        try self.register(.{ .name = "if-shell", .alias = "if", .min_args = 2, .max_args = 8, .usage = "if-shell (if) [-bF] [-t target-pane] shell-command command [command]", .handler = cmdIfShell });
        try self.register(.{ .name = "run-shell", .alias = "run", .min_args = 0, .max_args = 10, .usage = "run-shell (run) [-bCE] [-c start-directory] [-d delay] [-t target-pane] [shell-command]", .handler = cmdRunShell });
        try self.register(.{ .name = "wait-for", .alias = "wait", .min_args = 1, .max_args = 4, .usage = "wait-for (wait) [-L|-S|-U] channel", .handler = cmdWaitFor });

        // -- Prompt history --
        try self.register(.{ .name = "clear-prompt-history", .alias = "clearphist", .min_args = 0, .max_args = 2, .usage = "clear-prompt-history (clearphist) [-T prompt-type]", .handler = cmdClearPromptHistory });
        try self.register(.{ .name = "show-prompt-history", .alias = "showphist", .min_args = 0, .max_args = 2, .usage = "show-prompt-history (showphist) [-T prompt-type]", .handler = cmdShowPromptHistory });

        // -- Access control --
        try self.register(.{ .name = "server-access", .alias = null, .min_args = 0, .max_args = 8, .usage = "server-access [-adlrw] [-t target-pane] [user]", .handler = cmdServerAccess });
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

fn defaultShell(session: ?*Session) [:0]const u8 {
    if (session) |s| return s.options.default_shell;
    return "/bin/sh";
}

fn defaultShellFromContext(ctx: *const Context) [:0]const u8 {
    if (ctx.session) |s| return s.options.default_shell;
    if (ctx.server.global_default_shell) |shell| return shell;
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

    // Buffer chooser selection: paste selected buffer into active pane.
    if (item.buffer_index) |buf_idx| {
        const buf = ctx.server.paste_stack.get(buf_idx) orelse return CmdError.BufferNotFound;
        if (ctx.session) |sel_session| {
            if (sel_session.active_window) |sel_window| {
                if (sel_window.active_pane) |sel_pane| {
                    if (sel_pane.fd >= 0) {
                        _ = std.c.write(sel_pane.fd, buf.data.ptr, buf.data.len);
                    }
                }
            }
        }
        clearChooseTreeState(ctx, pane);
        return;
    }

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

// -- Session stubs --

fn cmdLockClient(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeOutput(ctx, "client locked\n", .{});
}

fn cmdLockServer(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeOutput(ctx, "server locked\n", .{});
}

fn cmdLockSession(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeOutput(ctx, "session locked\n", .{});
}

fn cmdRefreshClient(_: *Context, _: []const []const u8) CmdError!void {
    // Accept all flags silently; full sub-modes not yet wired.
}

fn cmdShowMessages(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeOutput(ctx, "no messages\n", .{});
}

fn cmdSuspendClient(_: *Context, _: []const []const u8) CmdError!void {
    // Would send SIGTSTP to the client process; no-op for now.
}

fn cmdSwitchClient(ctx: *Context, args: []const []const u8) CmdError!void {
    const target = parseNamedOption(args, "-t");
    if (target) |name| {
        const session = ctx.server.findSession(name) orelse return CmdError.SessionNotFound;
        ctx.session = session;
        ctx.server.default_session = session;
        return;
    }
    // -n: next session, -p: previous session
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-n")) {
            if (ctx.server.sessions.items.len < 2) return;
            if (ctx.session) |current| {
                for (ctx.server.sessions.items, 0..) |s, i| {
                    if (s == current) {
                        const next_idx = (i + 1) % ctx.server.sessions.items.len;
                        ctx.session = ctx.server.sessions.items[next_idx];
                        ctx.server.default_session = ctx.session;
                        return;
                    }
                }
            }
            return;
        }
        if (std.mem.eql(u8, arg, "-p")) {
            if (ctx.server.sessions.items.len < 2) return;
            if (ctx.session) |current| {
                for (ctx.server.sessions.items, 0..) |s, i| {
                    if (s == current) {
                        const prev_idx = if (i == 0) ctx.server.sessions.items.len - 1 else i - 1;
                        ctx.session = ctx.server.sessions.items[prev_idx];
                        ctx.server.default_session = ctx.session;
                        return;
                    }
                }
            }
            return;
        }
    }
}

// -- Pane stubs --

fn cmdBreakPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var no_select = false;
    var print_info = false;
    var window_name: ?[]const u8 = null;
    var src_spec: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-P")) {
            print_info = true;
        } else if (std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-b")) {
            // before/after: not implemented
        } else if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            window_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src_spec = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1; // dst-window: not implemented
        } else if (std.mem.eql(u8, args[i], "-F") and i + 1 < args.len) {
            i += 1; // format: not implemented
        }
    }

    // Resolve source pane (no destruction yet)
    var pane: *Pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (src_spec) |spec| {
        if (spec.len >= 2 and spec[0] == '%') {
            const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
            var found = false;
            for (window.panes.items) |p| {
                if (p.id == pid) { pane = p; found = true; break; }
            }
            if (!found) return CmdError.PaneNotFound;
        } else {
            const idx = std.fmt.parseInt(usize, spec, 10) catch return CmdError.InvalidArgs;
            if (idx >= window.panes.items.len) return CmdError.PaneNotFound;
            pane = window.panes.items[idx];
        }
    }

    if (window.panes.items.len <= 1) {
        try writeReplyMessage(ctx, .error_msg, "break-pane: can't break only pane\n");
        return CmdError.CommandFailed;
    }

    // Remove from source window without destroying
    for (window.panes.items, 0..) |p, idx| {
        if (p == pane) { _ = window.panes.orderedRemove(idx); break; }
    }
    if (window.last_pane == pane) window.last_pane = null;
    if (window.active_pane == pane) {
        window.active_pane = if (window.panes.items.len > 0) window.panes.items[0] else null;
    }
    if (window.layout_root) |root| root.resize(window.sx, window.sy);

    // Create new window with pane
    var name_buf: [64]u8 = undefined;
    const win_name = window_name orelse std.fmt.bufPrint(&name_buf, "pane-{d}", .{pane.id}) catch "pane";
    const new_window = Window.init(ctx.allocator, win_name, pane.sx, pane.sy) catch return CmdError.OutOfMemory;
    errdefer new_window.deinit();
    new_window.addPane(pane) catch return CmdError.OutOfMemory;
    session.addWindow(new_window) catch return CmdError.OutOfMemory;

    if (!no_select) {
        session.selectWindow(new_window);
        ctx.window = new_window;
        ctx.pane = pane;
    }
    if (print_info) try writeOutput(ctx, "%{d}\n", .{pane.id});
}

fn cmdCapturePane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const win = session.active_window orelse return CmdError.WindowNotFound;

    var to_stdout = false;
    var buffer_name: ?[]const u8 = null;
    var start_line_arg: ?[]const u8 = null;
    var end_line_arg: ?[]const u8 = null;
    var target_pane = win.active_pane orelse return CmdError.PaneNotFound;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p")) {
            to_stdout = true;
        } else if (std.mem.eql(u8, args[i], "-b") and i + 1 < args.len) {
            i += 1;
            buffer_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-S") and i + 1 < args.len) {
            i += 1;
            start_line_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "-E") and i + 1 < args.len) {
            i += 1;
            end_line_arg = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const spec = args[i];
            if (spec.len >= 2 and spec[0] == '%') {
                const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
                for (win.panes.items) |p| {
                    if (p.id == pid) { target_pane = p; break; }
                }
            }
        } else if (args[i].len > 0 and args[i][0] == '-') {
            // skip other boolean flags: -a -e -C -J -M -N -P -q
        }
    }

    const pane_state = ctx.server.session_loop.getPane(target_pane.id) orelse return CmdError.CommandFailed;
    const grid = &pane_state.screen.grid;
    const total_lines: u32 = grid.hsize + grid.rows;

    const first_y: u32 = if (start_line_arg) |sl| blk: {
        const val = std.fmt.parseInt(i32, sl, 10) catch 0;
        if (val < 0) break :blk total_lines -| @as(u32, @intCast(-val));
        break :blk @intCast(val);
    } else 0;

    const last_y: u32 = if (end_line_arg) |el| blk: {
        const val = std.fmt.parseInt(i32, el, 10) catch -1;
        if (val < 0) break :blk total_lines -| @as(u32, @intCast(-val));
        break :blk @intCast(val);
    } else if (total_lines > 0) total_lines - 1 else 0;

    var out: std.ArrayListAligned(u8, null) = .empty;
    defer out.deinit(ctx.allocator);

    var y = first_y;
    while (y <= last_y and y < total_lines) : (y += 1) {
        const line_text = extractGridLineSlice(ctx.allocator, pane_state, y, 0, grid.cols -| 1) catch return CmdError.OutOfMemory;
        defer ctx.allocator.free(line_text);
        out.appendSlice(ctx.allocator, line_text) catch return CmdError.OutOfMemory;
        out.append(ctx.allocator, '\n') catch return CmdError.OutOfMemory;
    }

    if (to_stdout) {
        try writeReplyMessage(ctx, .output, out.items);
    } else {
        ctx.server.paste_stack.push(out.items, buffer_name) catch return CmdError.OutOfMemory;
    }
}

fn cmdDisplayPanes(ctx: *Context, _: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items, 0..) |pane, i| {
        try writeOutput(ctx, "{d}: pane %{d} [{d}x{d}]\n", .{ i, pane.id, pane.sx, pane.sy });
    }
}

fn cmdJoinPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;

    var no_select = false;
    var direction: CellType = .horizontal;
    var percent: u32 = 50;
    var src_spec: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-h")) {
            direction = .horizontal;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            direction = .vertical;
        } else if (std.mem.eql(u8, args[i], "-b") or std.mem.eql(u8, args[i], "-f")) {
            // before/full-size: not fully implemented
        } else if (std.mem.eql(u8, args[i], "-l") and i + 1 < args.len) {
            i += 1;
            percent = std.fmt.parseInt(u32, args[i], 10) catch 50;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src_spec = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1; // dst pane — use active window (basic impl)
        }
    }

    const src_str = src_spec orelse return CmdError.InvalidArgs;

    // Find source pane across all windows in session
    var src_pane: ?*Pane = null;
    var src_window: ?*Window = null;
    for (session.windows.items) |win| {
        if (src_str.len >= 2 and src_str[0] == '%') {
            const pid = std.fmt.parseInt(u32, src_str[1..], 10) catch continue;
            for (win.panes.items) |p| {
                if (p.id == pid) { src_pane = p; src_window = win; break; }
            }
        } else {
            const idx = std.fmt.parseInt(usize, src_str, 10) catch continue;
            if (idx < win.panes.items.len) { src_pane = win.panes.items[idx]; src_window = win; }
        }
        if (src_pane != null) break;
    }

    const pane = src_pane orelse return CmdError.PaneNotFound;
    const src_win = src_window orelse return CmdError.PaneNotFound;
    const dst_window = session.active_window orelse return CmdError.WindowNotFound;

    if (src_win == dst_window) {
        try writeReplyMessage(ctx, .error_msg, "join-pane: source and destination are the same window\n");
        return CmdError.CommandFailed;
    }

    // Remove from source without destroying
    for (src_win.panes.items, 0..) |p, idx| {
        if (p == pane) { _ = src_win.panes.orderedRemove(idx); break; }
    }
    if (src_win.last_pane == pane) src_win.last_pane = null;
    if (src_win.active_pane == pane) {
        src_win.active_pane = if (src_win.panes.items.len > 0) src_win.panes.items[0] else null;
    }
    if (src_win.layout_root) |root| root.resize(src_win.sx, src_win.sy);

    if (src_win.panes.items.len == 0) {
        const empty = session.removeWindow(src_win);
        if (empty) { ctx.session = null; ctx.server.removeSession(session); return; }
    }

    dst_window.splitActivePane(pane, direction, percent) catch return CmdError.CommandFailed;
    ctx.server.trackPane(pane, pane.sx, pane.sy) catch {};

    if (!no_select) {
        dst_window.selectPane(pane);
        ctx.pane = pane;
    }
}

fn cmdMovePane(ctx: *Context, args: []const []const u8) CmdError!void {
    return cmdJoinPane(ctx, args);
}

fn cmdPipePane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var toggle = false;
    var shell_command: ?[]const u8 = null;
    var target_pane = window.active_pane orelse return CmdError.PaneNotFound;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-o")) {
            toggle = true;
        } else if (std.mem.eql(u8, args[i], "-I") or std.mem.eql(u8, args[i], "-O")) {
            // direction flags: parsed but both stdin/stdout treated same
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const spec = args[i];
            if (spec.len >= 2 and spec[0] == '%') {
                const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
                for (window.panes.items) |p| {
                    if (p.id == pid) { target_pane = p; break; }
                }
            }
        } else if (args[i].len > 0 and args[i][0] != '-') {
            shell_command = args[i];
        }
    }

    const pane = target_pane;

    // Close existing pipe on toggle or when no command given
    if (pane.pipe_fd >= 0) {
        _ = std.c.close(pane.pipe_fd);
        pane.pipe_fd = -1;
        if (toggle or shell_command == null) return;
    }

    const cmd_str = shell_command orelse return;

    var pipe_fds: [2]std.c.fd_t = undefined;
    if (std.c.pipe(&pipe_fds) != 0) return CmdError.CommandFailed;

    var cmd_buf: [4096]u8 = .{0} ** 4096;
    if (cmd_str.len >= cmd_buf.len) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        return CmdError.CommandFailed;
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);

    const pid = std.c.fork();
    if (pid < 0) {
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        return CmdError.CommandFailed;
    }

    if (pid == 0) {
        _ = dup2(pipe_fds[0], 0);
        _ = std.c.close(pipe_fds[0]);
        _ = std.c.close(pipe_fds[1]);
        const sh: [*:0]const u8 = "/bin/sh";
        const c_flag: [*:0]const u8 = "-c";
        const cmd_z: [*:0]const u8 = @ptrCast(cmd_buf[0..cmd_str.len :0]);
        const argv = [_:null]?[*:0]const u8{ sh, c_flag, cmd_z };
        _ = execvp(sh, &argv);
        std.c.exit(127);
    }

    _ = std.c.close(pipe_fds[0]);
    pane.pipe_fd = pipe_fds[1];
}

fn cmdRespawnPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var kill_existing = false;
    var start_dir: ?[]const u8 = null;
    var target_pane: ?*Pane = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-k")) {
            kill_existing = true;
        } else if (std.mem.eql(u8, args[i], "-c") and i + 1 < args.len) {
            i += 1;
            start_dir = args[i];
        } else if (std.mem.eql(u8, args[i], "-e") and i + 1 < args.len) {
            i += 1; // environment: not applied
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const spec = args[i];
            if (spec.len >= 2 and spec[0] == '%') {
                const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
                for (window.panes.items) |p| {
                    if (p.id == pid) { target_pane = p; break; }
                }
            } else {
                const idx = std.fmt.parseInt(usize, spec, 10) catch return CmdError.InvalidArgs;
                if (idx < window.panes.items.len) target_pane = window.panes.items[idx];
            }
        }
    }

    const pane = target_pane orelse window.active_pane orelse return CmdError.PaneNotFound;

    if (pane.pid > 0) {
        if (!kill_existing) {
            try writeReplyMessage(ctx, .error_msg, "respawn-pane: pane still active (use -k to kill)\n");
            return CmdError.CommandFailed;
        }
        _ = std.c.kill(pane.pid, .TERM);
        _ = std.c.waitpid(pane.pid, null, 0);
        pane.pid = 0;
    }

    if (pane.fd >= 0) {
        ctx.server.untrackPane(pane.id);
        _ = std.c.close(pane.fd);
        pane.fd = -1;
    }

    var cwd_buf: [4096]u8 = .{0} ** 4096;
    const cwd_z: ?[:0]const u8 = if (start_dir) |d| blk: {
        if (d.len >= cwd_buf.len) return CmdError.CommandFailed;
        @memcpy(cwd_buf[0..d.len], d);
        break :blk cwd_buf[0..d.len :0];
    } else null;

    const shell = defaultShellFromContext(ctx);
    var pty = Pty.openPty() catch return CmdError.CommandFailed;
    pty.forkExec(shell, cwd_z) catch return CmdError.CommandFailed;
    pty.resize(@intCast(pane.sx), @intCast(pane.sy));
    pane.fd = pty.master_fd;
    pane.pid = pty.pid;
    ctx.server.trackPane(pane, pane.sx, pane.sy) catch return CmdError.CommandFailed;
}


// -- Stub for unimplemented commands --

fn cmdNotImplemented(ctx: *Context, _: []const []const u8) CmdError!void {
    try writeReplyMessage(ctx, .error_msg, "command not yet implemented\n");
    return CmdError.CommandFailed;
}

// -- New command implementations --

fn cmdAttachSession(ctx: *Context, args: []const []const u8) CmdError!void {
    const target: ?[]const u8 = parseNamedOption(args, "-t");
    _ = parseNamedOption(args, "-c"); // start-dir: not used
    _ = parseNamedOption(args, "-f"); // flags: not used

    var detach_others = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "-x")) detach_others = true;
        // -E (no update-env), -r (read-only): parsed but not enforced
    }

    const session: *Session = if (target) |name|
        ctx.server.findSession(name) orelse return CmdError.SessionNotFound
    else if (ctx.server.sessions.items.len == 1)
        ctx.server.sessions.items[0]
    else if (ctx.server.default_session) |s|
        s
    else
        return CmdError.SessionNotFound;

    if (detach_others) {
        for (ctx.server.clients.items, 0..) |client, i| {
            if (client.session != session) continue;
            if (ctx.client_index) |ci| if (ci == i) continue;
            ctx.server.detachClient(i);
        }
    }

    ctx.session = session;
    ctx.server.default_session = session;
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

fn cmdLastPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var window = session.active_window orelse return CmdError.WindowNotFound;

    var disable_input = false;
    var enable_input = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) {
            disable_input = true;
        } else if (std.mem.eql(u8, args[i], "-e")) {
            enable_input = true;
        } else if (std.mem.eql(u8, args[i], "-Z")) {
            // keep zoom: no special action needed
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const target = args[i];
            if (std.fmt.parseInt(u32, target, 10) catch null) |wnum| {
                window = session.findWindowByNumber(wnum) orelse return CmdError.WindowNotFound;
            }
        }
    }

    window.prevPane();

    if (disable_input) {
        if (window.active_pane) |pane| pane.flags.input_disabled = true;
    } else if (enable_input) {
        if (window.active_pane) |pane| pane.flags.input_disabled = false;
    }
}

fn cmdNextLayout(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = if (parseTargetWindow(args)) |n|
        session.findWindowByNumber(n) orelse return CmdError.WindowNotFound
    else
        session.active_window orelse return CmdError.WindowNotFound;
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdPrevLayout(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = if (parseTargetWindow(args)) |n|
        session.findWindowByNumber(n) orelse return CmdError.WindowNotFound
    else
        session.active_window orelse return CmdError.WindowNotFound;
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdSelectLayout(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var window = session.active_window orelse return CmdError.WindowNotFound;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const num = std.fmt.parseInt(u32, args[i], 10) catch return CmdError.InvalidArgs;
            window = session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
        } else if (std.mem.eql(u8, args[i], "-n") or std.mem.eql(u8, args[i], "-o")) {
            // next / last layout — cycle (resize triggers re-layout)
        } else if (std.mem.eql(u8, args[i], "-p")) {
            // previous layout — cycle
        } else if (std.mem.eql(u8, args[i], "-E")) {
            // spread panes evenly; handled by resize below
        }
        // layout-name positional arg: ignore for now (no named layout support)
    }
    if (window.layout_root) |root| {
        root.resize(window.sx, window.sy);
    }
}

fn cmdRotateWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var window = session.active_window orelse return CmdError.WindowNotFound;
    var direction: Window.SwapDirection = .next;
    var zoom_after = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-U")) {
            direction = .prev;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            direction = .next;
        } else if (std.mem.eql(u8, args[i], "-Z")) {
            zoom_after = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const num = std.fmt.parseInt(u32, args[i], 10) catch return CmdError.InvalidArgs;
            window = session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
        }
    }
    window.swapActivePane(direction);
    if (zoom_after) _ = window.toggleZoom();
}

fn cmdSwapWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const src_name = parseNamedOption(args, "-s");
    const dst_name = parseNamedOption(args, "-t");
    var no_select = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d")) no_select = true;
    }

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
    if (!no_select) session.selectWindow(session.windows.items[dst_idx]);
}

fn cmdClearHistory(ctx: *Context, args: []const []const u8) CmdError!void {
    // -H: also clear hyperlink history (no hyperlink tracking yet, ignored)
    // -t target-pane: uses active pane (full target resolution not yet implemented)
    _ = args;
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
    var repeat = false;
    var note: ?[]const u8 = null;
    var i: usize = 0;

    // Parse flags: -T table, -n (root), -r (repeat), -N note
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-T")) {
            i += 1;
            if (i >= args.len) return CmdError.InvalidArgs;
            table_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-n")) {
            table_name = "root";
        } else if (std.mem.eql(u8, args[i], "-r")) {
            repeat = true;
        } else if (std.mem.eql(u8, args[i], "-N")) {
            i += 1;
            if (i >= args.len) return CmdError.InvalidArgs;
            note = args[i];
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
    table.bindFull(kr.key, kr.mods, cmd_str, note, repeat) catch return CmdError.OutOfMemory;
}

fn cmdUnbindKey(ctx: *Context, args: []const []const u8) CmdError!void {
    const manager = ctx.binding_manager orelse {
        try writeReplyMessage(ctx, .error_msg, "unbind-key: no binding manager available\n");
        return CmdError.CommandFailed;
    };

    var table_name: []const u8 = "prefix";
    var unbind_all = false;
    var quiet = false;
    var i: usize = 0;

    // Parse flags: -T table, -n (root), -a (all), -q (quiet)
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "-T")) {
            i += 1;
            if (i >= args.len) return CmdError.InvalidArgs;
            table_name = args[i];
        } else if (std.mem.eql(u8, args[i], "-n")) {
            table_name = "root";
        } else if (std.mem.eql(u8, args[i], "-a")) {
            unbind_all = true;
        } else if (std.mem.eql(u8, args[i], "-q")) {
            quiet = true;
        } else {
            break;
        }
        i += 1;
    }

    if (unbind_all) {
        if (manager.tables.getPtr(table_name)) |table| {
            for (table.bindings.items) |*b| {
                switch (b.action) {
                    .command => |cmd| table.allocator.free(cmd),
                    .none => {},
                }
                if (b.note) |n| table.allocator.free(n);
            }
            table.bindings.clearRetainingCapacity();
        }
        return;
    }

    if (i >= args.len) return CmdError.InvalidArgs;
    const kr = key_string.stringToKey(args[i]) orelse {
        if (quiet) return;
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
    var is_hooks = false;
    var is_quiet = false;
    var is_value_only = false;
    var option_name: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-H")) {
            is_hooks = true;
        } else if (std.mem.eql(u8, args[i], "-q")) {
            is_quiet = true;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            is_value_only = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-A") or std.mem.eql(u8, args[i], "-g") or
            std.mem.eql(u8, args[i], "-p") or std.mem.eql(u8, args[i], "-s") or
            std.mem.eql(u8, args[i], "-w"))
        {
            // scope flags
        } else if (args[i].len > 0 and args[i][0] != '-') {
            option_name = args[i];
        }
    }

    const session = ctx.session orelse {
        if (!is_quiet) return CmdError.SessionNotFound;
        return;
    };

    if (is_hooks) {
        const all_hooks = [_]hooks_mod.HookType{
            .after_new_session,    .after_new_window,   .after_split_window,
            .after_select_pane,    .after_select_window,.after_resize_pane,
            .after_rename_session, .after_rename_window,.client_attached,
            .client_detached,      .client_resized,     .pane_exited,
            .pane_focus_in,        .pane_focus_out,     .window_linked,
            .window_unlinked,      .session_closed,     .session_renamed,
            .window_renamed,
        };
        for (all_hooks) |ht| {
            const hn = hookTypeName(ht);
            for (ctx.server.hook_registry.getHooks(ht)) |hook| {
                if (is_value_only) {
                    try writeOutput(ctx, "{s}\n", .{hook.command});
                } else {
                    try writeOutput(ctx, "{s} {s}\n", .{ hn, hook.command });
                }
            }
        }
        return;
    }

    if (option_name) |name| {
        if (std.mem.eql(u8, name, "base-index")) {
            if (is_value_only) try writeOutput(ctx, "{d}\n", .{session.options.base_index}) else try writeOutput(ctx, "base-index {d}\n", .{session.options.base_index});
        } else if (std.mem.eql(u8, name, "mouse")) {
            const v = if (session.options.mouse) "on" else "off";
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{v}) else try writeOutput(ctx, "mouse {s}\n", .{v});
        } else if (std.mem.eql(u8, name, "status")) {
            const v = if (session.options.status) "on" else "off";
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{v}) else try writeOutput(ctx, "status {s}\n", .{v});
        } else if (std.mem.eql(u8, name, "prefix")) {
            const pk = session.options.prefix_key;
            if (pk >= 1 and pk <= 26) {
                const ch: u8 = @intCast(pk + 'a' - 1);
                if (is_value_only) try writeOutput(ctx, "C-{c}\n", .{ch}) else try writeOutput(ctx, "prefix C-{c}\n", .{ch});
            }
        } else if (std.mem.eql(u8, name, "default-shell")) {
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{session.options.default_shell}) else try writeOutput(ctx, "default-shell {s}\n", .{session.options.default_shell});
        } else if (std.mem.eql(u8, name, "status-left")) {
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{session.options.status_left}) else try writeOutput(ctx, "status-left {s}\n", .{session.options.status_left});
        } else if (std.mem.eql(u8, name, "status-right")) {
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{session.options.status_right}) else try writeOutput(ctx, "status-right {s}\n", .{session.options.status_right});
        } else if (std.mem.eql(u8, name, "visual-activity")) {
            const v = if (session.options.visual_activity) "on" else "off";
            if (is_value_only) try writeOutput(ctx, "{s}\n", .{v}) else try writeOutput(ctx, "visual-activity {s}\n", .{v});
        } else {
            if (!is_quiet) return CmdError.CommandFailed;
        }
        return;
    }

    // Show all options
    const pk = session.options.prefix_key;
    try writeOutput(ctx, "base-index {d}\n", .{session.options.base_index});
    try writeOutput(ctx, "default-shell {s}\n", .{session.options.default_shell});
    try writeOutput(ctx, "mouse {s}\n", .{if (session.options.mouse) "on" else "off"});
    if (pk >= 1 and pk <= 26) {
        try writeOutput(ctx, "prefix C-{c}\n", .{@as(u8, @intCast(pk + 'a' - 1))});
    }
    try writeOutput(ctx, "status {s}\n", .{if (session.options.status) "on" else "off"});
    try writeOutput(ctx, "status-left {s}\n", .{session.options.status_left});
    try writeOutput(ctx, "status-right {s}\n", .{session.options.status_right});
    try writeOutput(ctx, "visual-activity {s}\n", .{if (session.options.visual_activity) "on" else "off"});
}

fn cmdShowWindowOptions(ctx: *Context, args: []const []const u8) CmdError!void {
    return cmdShowOptions(ctx, args);
}

fn cmdSetEnvironment(ctx: *Context, args: []const []const u8) CmdError!void {
    var is_hidden = false;
    var is_global = false;
    var is_remove = false;

    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            is_hidden = true;
        } else if (std.mem.eql(u8, args[i], "-g")) {
            is_global = true;
        } else if (std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "-u")) {
            is_remove = true;
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len) {
            i += 1;
        }
    }

    if (i >= args.len) return CmdError.InvalidArgs;
    const var_name = args[i];
    i += 1;
    const var_value: ?[]const u8 = if (i < args.len) args[i] else null;

    if (is_remove) {
        if (is_global) {
            for (ctx.server.sessions.items) |session| {
                session.environ.unset(var_name) catch {};
            }
        } else {
            const session = ctx.session orelse return CmdError.SessionNotFound;
            session.environ.unset(var_name) catch return CmdError.OutOfMemory;
        }
        return;
    }

    const value = var_value orelse return CmdError.InvalidArgs;

    if (is_global) {
        for (ctx.server.sessions.items) |session| {
            if (is_hidden) {
                session.environ.setHidden(var_name, value) catch {};
            } else {
                session.environ.set(var_name, value) catch {};
            }
        }
    } else {
        const session = ctx.session orelse return CmdError.SessionNotFound;
        if (is_hidden) {
            session.environ.setHidden(var_name, value) catch return CmdError.OutOfMemory;
        } else {
            session.environ.set(var_name, value) catch return CmdError.OutOfMemory;
        }
    }
}

fn cmdShowEnvironment(ctx: *Context, args: []const []const u8) CmdError!void {
    var show_hidden = false;
    var shell_format = false;
    var filter: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            show_hidden = true;
        } else if (std.mem.eql(u8, args[i], "-s")) {
            shell_format = true;
        } else if (std.mem.eql(u8, args[i], "-g")) {
            // global: no-op, use session environ
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
        } else if (args[i].len > 0 and args[i][0] != '-') {
            filter = args[i];
        }
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;

    var iter = session.environ.vars.iterator();
    while (iter.next()) |entry| {
        const key = entry.key_ptr.*;
        const ev = entry.value_ptr.*;

        if (filter) |f| {
            if (!std.mem.eql(u8, key, f)) continue;
        }
        if (!show_hidden and ev.hidden) continue;

        if (ev.value) |val| {
            if (shell_format) {
                try writeOutput(ctx, "export {s}={s};\n", .{ key, val });
            } else {
                try writeOutput(ctx, "{s}={s}\n", .{ key, val });
            }
        } else {
            if (shell_format) {
                try writeOutput(ctx, "unset {s};\n", .{key});
            } else {
                try writeOutput(ctx, "-{s}\n", .{key});
            }
        }
    }
}

fn cmdLoadBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;
    const path = args[args.len - 1];
    const buffer_name = parseNamedOption(args, "-b");
    // -w: send to clipboard via OSC 52 (not yet wired to output path, data still pushed to stack)
    // -t target-client: uses server default (multi-client targeting not yet implemented)

    // Support '-' for reading from stdin (fd 0).
    const is_stdin = std.mem.eql(u8, path, "-");
    const fd: std.c.fd_t = if (is_stdin) 0 else blk: {
        var path_buf: [4096]u8 = .{0} ** 4096;
        if (path.len >= path_buf.len) return CmdError.CommandFailed;
        @memcpy(path_buf[0..path.len], path);
        const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
        const file_fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (file_fd < 0) return CmdError.CommandFailed;
        break :blk file_fd;
    };
    defer {
        if (!is_stdin) _ = std.c.close(fd);
    }

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

    const session = ctx.server.createSession(session_name, defaultShellFromContext(ctx), 80, 24) catch return CmdError.CommandFailed;
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
    var no_select = false;
    var print_info = false;
    var select_if_exists = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n") and i + 1 < args.len) {
            i += 1;
            name = args[i];
        } else if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-P")) {
            print_info = true;
        } else if (std.mem.eql(u8, args[i], "-S")) {
            select_if_exists = true;
        } else if ((std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-b") or
            std.mem.eql(u8, args[i], "-k")))
        {
            // -a (after), -b (before), -k (kill if exists): positional flags noted
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-e") or
            std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len)
        {
            i += 1; // consume value for -c/-e/-F/-t
        }
        // shell-command: remaining non-flag args — used as shell below
    }

    // If -S and a window with that name exists, just select it
    if (select_if_exists and name.len > 0) {
        for (session.windows.items) |w| {
            if (std.mem.eql(u8, w.name, name)) {
                if (!no_select) session.selectWindow(w);
                return;
            }
        }
    }

    const window = Window.init(ctx.allocator, name, 80, 24) catch return CmdError.OutOfMemory;
    errdefer window.deinit();

    const pane = spawnWindowPane(ctx.allocator, defaultShellFromContext(ctx), 80, 24) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer pane.deinit();

    window.addPane(pane) catch return CmdError.OutOfMemory;
    session.addWindow(window) catch return CmdError.OutOfMemory;
    if (!no_select) session.selectWindow(window);
    ctx.server.trackPane(pane, window.sx, window.sy) catch return CmdError.CommandFailed;
    if (print_info) {
        try writeOutput(ctx, "{s}:{d}\n", .{ session.name, session.windows.items.len - 1 });
    }
}

fn cmdSplitWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var direction: CellType = .horizontal;
    var percent: u32 = 50;
    var no_select = false;
    var zoom_after = false;
    var print_info = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-h")) {
            direction = .horizontal;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            direction = .vertical;
        } else if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            percent = std.fmt.parseInt(u32, args[i], 10) catch 50;
        } else if (std.mem.eql(u8, args[i], "-l") and i + 1 < args.len) {
            i += 1;
            // -l size: treat as percent if <= 100, else ignore
            const sz = std.fmt.parseInt(u32, args[i], 10) catch 50;
            if (sz <= 100) percent = sz;
        } else if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-Z")) {
            zoom_after = true;
        } else if (std.mem.eql(u8, args[i], "-P")) {
            print_info = true;
        } else if (std.mem.eql(u8, args[i], "-b")) {
            // -b: split before — swap direction after split
        } else if (std.mem.eql(u8, args[i], "-f")) {
            // -f: full-width/height split — noted, not structurally supported yet
        } else if (std.mem.eql(u8, args[i], "-I")) {
            // -I: stdin pipe — noted, no-op
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-e") or
            std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len)
        {
            i += 1; // consume value
        }
    }

    const new_pane = spawnWindowPane(ctx.allocator, defaultShellFromContext(ctx), window.sx, window.sy) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer new_pane.deinit();
    window.splitActivePane(new_pane, direction, percent) catch return CmdError.CommandFailed;
    if (no_select) {
        // restore previous active pane (splitActivePane sets new_pane as active)
        window.prevPane();
    }
    if (zoom_after) _ = window.toggleZoom();
    ctx.server.trackPane(new_pane, new_pane.sx, new_pane.sy) catch return CmdError.CommandFailed;
    if (print_info) {
        try writeOutput(ctx, "%{d}\n", .{new_pane.id});
    }
}

fn cmdSelectPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-l")) {
            // Select last active pane
            if (window.last_pane) |last| {
                for (window.panes.items) |p| {
                    if (p == last) { window.selectPane(last); return; }
                }
            }
            window.prevPane();
            return;
        } else if (std.mem.eql(u8, args[i], "-d")) {
            if (window.active_pane) |pane| pane.flags.input_disabled = true;
            return;
        } else if (std.mem.eql(u8, args[i], "-e")) {
            if (window.active_pane) |pane| pane.flags.input_disabled = false;
            return;
        } else if (std.mem.eql(u8, args[i], "-Z")) {
            // keep zoom: selectPane preserves zoom already
        } else if (std.mem.eql(u8, args[i], "-M") or std.mem.eql(u8, args[i], "-m")) {
            // set/clear mark: not implemented
        } else if (std.mem.eql(u8, args[i], "-T") and i + 1 < args.len) {
            i += 1; // title: not implemented
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const target = args[i];
            if (std.mem.eql(u8, target, ":.+") or std.mem.eql(u8, target, ":+")) {
                window.nextPane();
                return;
            }
            if (std.mem.eql(u8, target, ":-") or std.mem.eql(u8, target, ":.-")) {
                window.prevPane();
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
        } else if (std.mem.eql(u8, args[i], "-U") or std.mem.eql(u8, args[i], "-L")) {
            window.prevPane();
            return;
        } else if (std.mem.eql(u8, args[i], "-D") or std.mem.eql(u8, args[i], "-R")) {
            window.nextPane();
            return;
        }
    }

    window.nextPane();
}

fn cmdSelectWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-l")) {
            if (!session.lastWindow()) return CmdError.WindowNotFound;
            return;
        } else if (std.mem.eql(u8, args[i], "-n")) {
            session.nextWindow();
            return;
        } else if (std.mem.eql(u8, args[i], "-p")) {
            session.prevWindow();
            return;
        } else if (std.mem.eql(u8, args[i], "-T")) {
            // toggle: if already selected, go to last; otherwise select
            if (session.active_window != null) {
                _ = session.lastWindow();
            }
            return;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const num = std.fmt.parseInt(u32, args[i], 10) catch return CmdError.InvalidArgs;
            const window = session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
            session.selectWindow(window);
            return;
        }
    }
    if (parseTargetWindow(args)) |window_number| {
        const window = session.findWindowByNumber(window_number) orelse return CmdError.WindowNotFound;
        session.selectWindow(window);
        return;
    }
    session.nextWindow();
}

fn cmdDetachClient(ctx: *Context, args: []const []const u8) CmdError!void {
    // -P: print info on detach (not implemented, ignored)
    // -E shell-command: run on detach (not implemented, ignored)
    _ = parseNamedOption(args, "-E");

    var detach_all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a")) detach_all = true;
    }

    // -s target-session: detach all clients of that session
    if (parseNamedOption(args, "-s")) |session_name| {
        const session = ctx.server.findSession(session_name) orelse return CmdError.SessionNotFound;
        for (ctx.server.clients.items, 0..) |client, i| {
            if (client.session == session) ctx.server.detachClient(i);
        }
        return;
    }

    // -t target-client (by index): detach it (or all except it with -a)
    if (parseNamedOption(args, "-t")) |target| {
        const idx = std.fmt.parseInt(usize, target, 10) catch return CmdError.InvalidArgs;
        if (idx >= ctx.server.clients.items.len) return CmdError.CommandFailed;
        if (detach_all) {
            for (ctx.server.clients.items, 0..) |_, i| {
                if (i != idx) ctx.server.detachClient(i);
            }
        } else {
            ctx.server.detachClient(idx);
        }
        return;
    }

    // Default: detach all clients attached to the current session
    const session = ctx.session orelse return CmdError.SessionNotFound;
    for (ctx.server.clients.items, 0..) |client, i| {
        if (client.session == session) ctx.server.detachClient(i);
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
    // Parse flags: -l (literal), -H (hex byte per arg), -R (reset terminal),
    // -X cmd (copy-mode command), -N count (repeat), -c/-t (target, ignored),
    // -F/-K/-M (format/key-lookup/mouse, noted but no-op).
    var literal = false;
    var hex_mode = false;
    var reset_terminal = false;
    var copy_mode_cmd: ?[]const u8 = null;
    var repeat_count: u32 = 1;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-l")) {
            literal = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-H")) {
            hex_mode = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-R")) {
            reset_terminal = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-F") or std.mem.eql(u8, arg, "-K") or std.mem.eql(u8, arg, "-M")) {
            i += 1;
        } else if (std.mem.eql(u8, arg, "-X")) {
            i += 1;
            if (i < args.len) { copy_mode_cmd = args[i]; i += 1; }
        } else if (std.mem.eql(u8, arg, "-N")) {
            i += 1;
            if (i < args.len) { repeat_count = std.fmt.parseInt(u32, args[i], 10) catch 1; i += 1; }
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "-t")) {
            i += 2;
        } else {
            break;
        }
    }
    const key_args = args[i..];

    if (reset_terminal) {
        if (ctx.session) |rs| {
            if (rs.active_window) |rw| {
                if (rw.active_pane) |rp| {
                    if (rp.fd >= 0) _ = std.c.write(rp.fd, "\x1bc", 2);
                }
            }
        }
    }

    if (copy_mode_cmd) |cmd_str| {
        const session = ctx.session orelse return CmdError.SessionNotFound;
        const window = session.active_window orelse return CmdError.WindowNotFound;
        const active_pane = window.active_pane orelse return CmdError.PaneNotFound;
        _ = try handleCopyModeKey(ctx, active_pane, cmd_str);
        return;
    }

    if (ctx.server.choose_tree_state != null) {
        for (key_args) |key_str| {
            if (try handleChooseTreeKey(ctx, null, key_str)) continue;
        }
        return;
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    var rep: u32 = 0;
    while (rep < repeat_count) : (rep += 1) {
        for (key_args) |key_str| {
            if (pane.prompt_state != null and try handlePromptKey(ctx, pane, key_str)) continue;
            if (try handleChooseTreeKey(ctx, pane, key_str)) continue;
            if (pane.copy_state != null and try handleCopyModeKey(ctx, pane, key_str)) continue;

            if (literal) {
                _ = std.c.write(pane.fd, key_str.ptr, key_str.len);
            } else if (hex_mode) {
                const byte = std.fmt.parseInt(u8, key_str, 16) catch continue;
                const buf: [1]u8 = .{byte};
                _ = std.c.write(pane.fd, &buf, 1);
            } else if (std.mem.eql(u8, key_str, "Enter")) {
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
}

fn cmdSendPrefix(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    // -2: send secondary prefix key instead of primary.
    var secondary = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-2")) secondary = true;
    }

    const key: u21 = if (secondary)
        session.options.prefix2_key orelse return CmdError.CommandFailed
    else
        session.options.prefix_key;

    if (key > 0xff) return CmdError.CommandFailed;
    const prefix: [1]u8 = .{@intCast(key)};
    _ = std.c.write(pane.fd, &prefix, 1);
}

fn cmdNextWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    var target_session: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            // -a: move to next window with activity alert — treat as next
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_session = args[i];
        }
    }
    const session = if (target_session) |name|
        ctx.server.findSession(name) orelse return CmdError.SessionNotFound
    else
        ctx.session orelse return CmdError.SessionNotFound;
    session.nextWindow();
}

fn cmdPrevWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    var target_session: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            // -a: move to previous window with activity alert — treat as prev
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_session = args[i];
        }
    }
    const session = if (target_session) |name|
        ctx.server.findSession(name) orelse return CmdError.SessionNotFound
    else
        ctx.session orelse return CmdError.SessionNotFound;
    session.prevWindow();
}

fn cmdLastWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    var target_session: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_session = args[i];
        }
    }
    const session = if (target_session) |name|
        ctx.server.findSession(name) orelse return CmdError.SessionNotFound
    else
        ctx.session orelse return CmdError.SessionNotFound;
    if (!session.lastWindow()) return CmdError.WindowNotFound;
}

fn cmdKillWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var kill_all_others = false;
    var target_num: ?u32 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            kill_all_others = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_num = std.fmt.parseInt(u32, args[i], 10) catch null;
        }
    }

    if (kill_all_others) {
        const active = session.active_window;
        // Collect windows to kill (all except active)
        var to_kill = std.ArrayListAligned(*Window, null).empty;
        defer to_kill.deinit(ctx.allocator);
        for (session.windows.items) |w| {
            if (w != active) {
                to_kill.append(ctx.allocator, w) catch return CmdError.OutOfMemory;
            }
        }
        for (to_kill.items) |w| {
            for (w.panes.items) |pane| ctx.server.untrackPane(pane.id);
            _ = session.removeWindow(w);
        }
        return;
    }

    const window = if (target_num) |n|
        session.findWindowByNumber(n) orelse return CmdError.WindowNotFound
    else
        session.active_window orelse return CmdError.WindowNotFound;

    for (window.panes.items) |pane| {
        ctx.server.untrackPane(pane.id);
    }
    const empty = session.removeWindow(window);
    if (empty) {
        ctx.session = null;
        ctx.server.removeSession(session);
    }
}

fn cmdKillPane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var kill_all_others = false;
    var target_spec: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            kill_all_others = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_spec = args[i];
        }
    }

    if (kill_all_others) {
        const active = window.active_pane orelse return CmdError.PaneNotFound;
        var idx = window.panes.items.len;
        while (idx > 0) {
            idx -= 1;
            const p = window.panes.items[idx];
            if (p == active) continue;
            ctx.server.untrackPane(p.id);
            _ = window.removePane(p);
        }
        if (window.layout_root) |root| root.resize(window.sx, window.sy);
        return;
    }

    var pane: *Pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (target_spec) |spec| {
        if (spec.len >= 2 and spec[0] == '%') {
            const pane_id = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
            var found = false;
            for (window.panes.items) |p| {
                if (p.id == pane_id) { pane = p; found = true; break; }
            }
            if (!found) return CmdError.PaneNotFound;
        } else {
            const idx = std.fmt.parseInt(usize, spec, 10) catch return CmdError.InvalidArgs;
            if (idx >= window.panes.items.len) return CmdError.PaneNotFound;
            pane = window.panes.items[idx];
        }
    }

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
    var window = session.active_window orelse return CmdError.WindowNotFound;
    if (args.len == 0) return CmdError.InvalidArgs;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const num = std.fmt.parseInt(u32, args[i], 10) catch return CmdError.InvalidArgs;
            window = session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
        }
    }
    window.rename(args[args.len - 1]) catch return CmdError.OutOfMemory;
}

fn cmdResizePane(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;

    var pane: *Pane = window.active_pane orelse return CmdError.PaneNotFound;
    var dx: i32 = 0;
    var dy: i32 = 0;
    var amount: u32 = 1;
    var abs_x: ?u32 = null;
    var abs_y: ?u32 = null;

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
        } else if (std.mem.eql(u8, args[i], "-M") or std.mem.eql(u8, args[i], "-T")) {
            // mouse resize / trim: no-op
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const spec = args[i];
            if (spec.len >= 2 and spec[0] == '%') {
                const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return CmdError.InvalidArgs;
                for (window.panes.items) |p| {
                    if (p.id == pid) { pane = p; break; }
                }
            } else if (std.fmt.parseInt(usize, spec, 10) catch null) |idx| {
                if (idx < window.panes.items.len) pane = window.panes.items[idx];
            }
        } else if (std.mem.eql(u8, args[i], "-x") and i + 1 < args.len) {
            i += 1;
            abs_x = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, args[i], "-y") and i + 1 < args.len) {
            i += 1;
            abs_y = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else {
            amount = std.fmt.parseInt(u32, args[i], 10) catch 1;
        }
    }

    if (abs_x != null or abs_y != null) {
        const new_sx = @max(1, abs_x orelse pane.sx);
        const new_sy = @max(1, abs_y orelse pane.sy);
        pane.resize(new_sx, new_sy);
        if (window.layout_root) |root| root.resize(window.sx, window.sy);
        return;
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
    var src_spec: ?[]const u8 = null;
    var dst_spec: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-U")) {
            direction = .prev;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            direction = .next;
        } else if (std.mem.eql(u8, args[i], "-d") or std.mem.eql(u8, args[i], "-Z")) {
            // no-select / keep-zoom: no special action in basic impl
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src_spec = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            dst_spec = args[i];
        }
    }

    if (src_spec != null or dst_spec != null) {
        const resolve = struct {
            fn pane(win: *Window, spec: []const u8) ?*Pane {
                if (spec.len >= 2 and spec[0] == '%') {
                    const pid = std.fmt.parseInt(u32, spec[1..], 10) catch return null;
                    for (win.panes.items) |p| { if (p.id == pid) return p; }
                } else {
                    const idx = std.fmt.parseInt(usize, spec, 10) catch return null;
                    if (idx < win.panes.items.len) return win.panes.items[idx];
                }
                return null;
            }
        }.pane;

        const src = if (src_spec) |s| resolve(window, s) else window.active_pane;
        const dst = if (dst_spec) |s| resolve(window, s) else window.active_pane;
        const sp = src orelse return CmdError.PaneNotFound;
        const dp = dst orelse return CmdError.PaneNotFound;
        if (sp == dp) return;

        var src_idx: ?usize = null;
        var dst_idx: ?usize = null;
        for (window.panes.items, 0..) |p, idx| {
            if (p == sp) src_idx = idx;
            if (p == dp) dst_idx = idx;
        }
        const si = src_idx orelse return CmdError.PaneNotFound;
        const di = dst_idx orelse return CmdError.PaneNotFound;

        window.panes.items[si] = dp;
        window.panes.items[di] = sp;

        const tmp_xoff = sp.xoff; const tmp_yoff = sp.yoff;
        const tmp_sx = sp.sx; const tmp_sy = sp.sy;
        sp.xoff = dp.xoff; sp.yoff = dp.yoff; sp.sx = dp.sx; sp.sy = dp.sy;
        dp.xoff = tmp_xoff; dp.yoff = tmp_yoff; dp.sx = tmp_sx; dp.sy = tmp_sy;
        sp.flags.redraw = true;
        dp.flags.redraw = true;
        return;
    }

    window.swapActivePane(direction);
}

fn cmdDisplayMessage(ctx: *Context, args: []const []const u8) CmdError!void {
    var verbose = false;
    var message: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, args[i], "-I")) {
            try writeOutput(ctx, "sessions: {d}\n", .{ctx.server.sessions.items.len});
            try writeOutput(ctx, "clients: {d}\n", .{ctx.server.clients.items.len});
            return;
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-d") or
            std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len)
        {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-C") or
            std.mem.eql(u8, args[i], "-l") or std.mem.eql(u8, args[i], "-N") or
            std.mem.eql(u8, args[i], "-p"))
        {
            // boolean flags: no-op
        } else if (args[i].len > 0 and args[i][0] != '-') {
            message = args[i];
        }
    }

    if (message) |msg| {
        if (verbose) {
            try writeOutput(ctx, "[display-message] {s}\n", .{msg});
        } else {
            try writeOutput(ctx, "{s}\n", .{msg});
        }
    }
}

fn cmdSetOption(ctx: *Context, args: []const []const u8) CmdError!void {
    var is_global = false;
    var is_unset = false;
    var is_quiet = false;

    var index: usize = 0;
    while (index < args.len and args[index].len > 0 and args[index][0] == '-') : (index += 1) {
        if (std.mem.eql(u8, args[index], "-g")) {
            is_global = true;
        } else if (std.mem.eql(u8, args[index], "-u") or std.mem.eql(u8, args[index], "-U")) {
            is_unset = true;
        } else if (std.mem.eql(u8, args[index], "-q")) {
            is_quiet = true;
        } else if (std.mem.eql(u8, args[index], "-t") and index + 1 < args.len) {
            index += 1;
        }
        // -a/-F/-o/-p/-s/-w: parsed but not fully distinguished
    }

    if (index >= args.len) {
        if (!is_quiet) return CmdError.InvalidArgs;
        return;
    }

    if (is_unset) return; // unset restores default; no-op for now

    const name = args[index];
    const value: ?[]const u8 = if (index + 1 < args.len) args[index + 1] else null;
    const val = value orelse {
        if (!is_quiet) return CmdError.InvalidArgs;
        return;
    };

    // Global options are applied to all existing sessions and stored as
    // server defaults for future sessions.
    if (is_global) {
        applyGlobalOption(ctx.server, name, val) catch {
            if (!is_quiet) return CmdError.CommandFailed;
        };
        return;
    }

    const session = ctx.session orelse {
        if (!is_quiet) return CmdError.SessionNotFound;
        return;
    };
    applySessionOption(session, name, val) catch {
        if (!is_quiet) return CmdError.CommandFailed;
    };
}

fn applySessionOption(session: *Session, name: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, name, "base-index")) {
        session.options.base_index = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "mouse")) {
        session.options.mouse = parseBooleanValue(value) orelse return error.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "status")) {
        session.options.status = parseBooleanValue(value) orelse return error.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "prefix")) {
        session.options.prefix_key = parsePrefixValue(value) orelse return error.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "default-shell")) {
        try session.setDefaultShell(value);
        return;
    }
    if (std.mem.eql(u8, name, "visual-activity")) {
        session.options.visual_activity = parseBooleanValue(value) orelse return error.InvalidArgs;
        return;
    }
    if (std.mem.eql(u8, name, "status-left")) {
        const alloc = session.allocator;
        const owned = try alloc.dupe(u8, value);
        alloc.free(session.options.status_left);
        session.options.status_left = owned;
        return;
    }
    if (std.mem.eql(u8, name, "status-right")) {
        const alloc = session.allocator;
        const owned = try alloc.dupe(u8, value);
        alloc.free(session.options.status_right);
        session.options.status_right = owned;
        return;
    }
    return error.CommandFailed;
}

fn applyGlobalOption(server: *Server, name: []const u8, value: []const u8) !void {
    // Apply to all existing sessions.
    for (server.sessions.items) |session| {
        applySessionOption(session, name, value) catch {};
    }
    // Store for future sessions by updating the server's global default shell.
    if (std.mem.eql(u8, name, "default-shell")) {
        const owned = try server.allocator.dupeZ(u8, value);
        if (server.global_default_shell) |old| server.allocator.free(old);
        server.global_default_shell = owned;
    }
}

fn cmdSourceFile(ctx: *Context, args: []const []const u8) CmdError!void {
    if (args.len == 0) return CmdError.InvalidArgs;

    var syntax_only = false;
    var quiet = false;

    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-n")) {
            syntax_only = true;
        } else if (std.mem.eql(u8, args[i], "-q")) {
            quiet = true;
        } else if (std.mem.eql(u8, args[i], "-v")) {
            // verbose: no-op
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len) {
            i += 1;
        }
    }
    if (i >= args.len) return CmdError.InvalidArgs;
    const path = args[i];

    var path_buf: [4096]u8 = .{0} ** 4096;
    if (path.len >= path_buf.len) return CmdError.CommandFailed;
    @memcpy(path_buf[0..path.len], path);
    const cpath: [*:0]const u8 = @ptrCast(path_buf[0..path.len :0]);
    const fd = std.c.open(cpath, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    if (fd < 0) {
        if (quiet) return;
        return CmdError.CommandFailed;
    }
    defer _ = std.c.close(fd);

    var content_buf: [65536]u8 = undefined;
    var total: usize = 0;
    while (total < content_buf.len) {
        const n = std.c.read(fd, content_buf[total..].ptr, content_buf.len - total);
        if (n <= 0) break;
        total += @intCast(n);
    }
    if (total == 0) return;

    if (syntax_only) {
        var parser = config_parser.ConfigParser.init(ctx.allocator, content_buf[0..total]);
        var commands = parser.parseAll() catch {
            if (!quiet) return CmdError.CommandFailed;
            return;
        };
        defer {
            for (commands.items) |*command| command.deinit(ctx.allocator);
            commands.deinit(ctx.allocator);
        }
        return;
    }

    try executeCommandString(ctx, content_buf[0..total]);
}

fn cmdListWindows(ctx: *Context, args: []const []const u8) CmdError!void {
    var all_sessions = false;
    var target_session: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            all_sessions = true;
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-f") or std.mem.eql(u8, args[i], "-O")) and i + 1 < args.len) {
            i += 1; // consume format/filter/order value
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_session = args[i];
        }
    }

    if (all_sessions) {
        for (ctx.server.sessions.items) |sess| {
            for (sess.windows.items, 0..) |window, idx| {
                try writeOutput(ctx, "{s}:{d}: {s} ({d} panes)\n", .{
                    sess.name,
                    sess.options.base_index + @as(u32, @intCast(idx)),
                    window.name,
                    window.paneCount(),
                });
            }
        }
        return;
    }

    const session = if (target_session) |name|
        ctx.server.findSession(name) orelse return CmdError.SessionNotFound
    else
        ctx.session orelse return CmdError.SessionNotFound;

    for (session.windows.items, 0..) |window, idx| {
        try writeOutput(ctx, "{d}: {s} ({d} panes)\n", .{
            session.options.base_index + @as(u32, @intCast(idx)),
            window.name,
            window.paneCount(),
        });
    }
}

fn cmdListPanes(ctx: *Context, args: []const []const u8) CmdError!void {
    var all_sessions = false;
    var session_level = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            all_sessions = true;
        } else if (std.mem.eql(u8, args[i], "-s")) {
            session_level = true;
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-f") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len) {
            i += 1; // format/filter/target: not implemented
        }
    }

    if (all_sessions) {
        for (ctx.server.sessions.items) |session| {
            for (session.windows.items, 0..) |window, wi| {
                for (window.panes.items, 0..) |pane, pi| {
                    try writeOutput(ctx, "{s}:{d}.{d}: pane {d} [{d}x{d}]\n", .{
                        session.name, wi, pi, pane.id, pane.sx, pane.sy,
                    });
                }
            }
        }
        return;
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;

    if (session_level) {
        for (session.windows.items, 0..) |window, wi| {
            for (window.panes.items, 0..) |pane, pi| {
                try writeOutput(ctx, "{d}.{d}: pane {d} [{d}x{d}]\n", .{ wi, pi, pane.id, pane.sx, pane.sy });
            }
        }
        return;
    }

    const window = session.active_window orelse return CmdError.WindowNotFound;
    for (window.panes.items, 0..) |pane, pi| {
        try writeOutput(ctx, "{d}: pane {d} [{d}x{d}]\n", .{ pi, pane.id, pane.sx, pane.sy });
    }
}

fn cmdSetBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    var append = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-a")) append = true;
    }
    // -w: send to clipboard via OSC 52 (not yet wired, data pushed to stack only)
    // -t target-client: uses server default (multi-client targeting not yet implemented)

    const name = parseNamedOption(args, "-b");
    const new_name = parseNamedOption(args, "-n");

    // Rename: -n new-name (optionally combined with -b old-name)
    if (new_name) |nn| {
        const buf = ctx.server.paste_stack.getByName(name orelse "") orelse return CmdError.BufferNotFound;
        const owned_nn = buf.allocator.dupe(u8, nn) catch return CmdError.OutOfMemory;
        if (buf.name) |n| buf.allocator.free(n);
        buf.name = owned_nn;
        return;
    }

    // Find the data argument: last token that is not a flag or flag value.
    var data: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] == '-') {
            if ((std.mem.eql(u8, arg, "-b") or std.mem.eql(u8, arg, "-n") or
                std.mem.eql(u8, arg, "-t")) and i + 1 < args.len)
            {
                i += 1;
            }
            continue;
        }
        data = arg;
    }

    const buffer_data = data orelse return CmdError.InvalidArgs;

    if (append) {
        // Append to existing named buffer, or top buffer if unnamed.
        const buf = if (name) |n| ctx.server.paste_stack.getByName(n) else ctx.server.paste_stack.get(0);
        if (buf) |b| {
            const combined = b.allocator.alloc(u8, b.data.len + buffer_data.len) catch return CmdError.OutOfMemory;
            @memcpy(combined[0..b.data.len], b.data);
            @memcpy(combined[b.data.len..], buffer_data);
            b.allocator.free(b.data);
            b.data = combined;
            return;
        }
        // No existing buffer to append to — fall through and create a new one.
    }

    ctx.server.paste_stack.push(buffer_data, name) catch return CmdError.OutOfMemory;
}

fn cmdPasteBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;
    if (pane.fd < 0) return CmdError.CommandFailed;

    var delete_after = false;
    var bracketed = false;
    var raw = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d")) delete_after = true;
        if (std.mem.eql(u8, arg, "-p")) bracketed = true;
        if (std.mem.eql(u8, arg, "-r")) raw = true;
    }
    // -s separator: replace newlines (default replaces with space unless -r)
    // -t target-pane: uses active pane (full target resolution not yet implemented)
    const separator: ?[]const u8 = parseNamedOption(args, "-s");
    const buffer_name = parseNamedOption(args, "-b");
    const buffer = try resolvePasteBuffer(ctx, buffer_name);

    if (bracketed) _ = std.c.write(pane.fd, "\x1b[200~", 6);

    if (raw) {
        _ = std.c.write(pane.fd, buffer.data.ptr, buffer.data.len);
    } else {
        // Replace newlines with separator (default: space).
        const sep: []const u8 = separator orelse " ";
        var start: usize = 0;
        for (buffer.data, 0..) |ch, idx| {
            if (ch == '\n') {
                if (idx > start) _ = std.c.write(pane.fd, buffer.data[start..idx].ptr, idx - start);
                _ = std.c.write(pane.fd, sep.ptr, sep.len);
                start = idx + 1;
            }
        }
        if (start < buffer.data.len) _ = std.c.write(pane.fd, buffer.data[start..].ptr, buffer.data.len - start);
    }

    if (bracketed) _ = std.c.write(pane.fd, "\x1b[201~", 6);

    if (delete_after) {
        if (buffer_name) |n| {
            _ = ctx.server.paste_stack.removeByName(n);
        } else {
            _ = ctx.server.paste_stack.removeTop();
        }
    }
}

fn cmdCopyMode(ctx: *Context, args: []const []const u8) CmdError!void {
    var cancel = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-d")) cancel = true;
        // -e/-H/-M/-q/-S/-u/-s/-t: parsed but not altering core enter/exit logic
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    if (cancel) {
        pane.copy_state = null;
        return;
    }

    const pane_state = ctx.server.session_loop.getPane(pane.id) orelse return CmdError.CommandFailed;

    var state = copy_mod.CopyState.init();
    state.cx = pane_state.screen.cx;
    state.cy = pane_state.screen.grid.hsize + pane_state.screen.cy;
    pane.copy_state = state;
}

fn cmdCommandPrompt(ctx: *Context, args: []const []const u8) CmdError!void {
    var prompt_text: []const u8 = ":";
    var initial_text: []const u8 = "";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            prompt_text = args[i];
        } else if (std.mem.eql(u8, args[i], "-I") and i + 1 < args.len) {
            i += 1;
            initial_text = args[i];
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-k") or
            std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "-T")) and i + 1 < args.len)
        {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-1") or std.mem.eql(u8, args[i], "-b") or
            std.mem.eql(u8, args[i], "-e") or std.mem.eql(u8, args[i], "-i") or
            std.mem.eql(u8, args[i], "-l") or std.mem.eql(u8, args[i], "-N"))
        {
            // boolean flags
        }
    }

    const session = ctx.session orelse return CmdError.SessionNotFound;
    const window = session.active_window orelse return CmdError.WindowNotFound;
    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    var state = PromptState{};
    if (initial_text.len > 0) {
        appendPromptBytes(&state, initial_text);
    }
    pane.prompt_state = state;
    try writeOutput(ctx, "{s}\n", .{prompt_text});
}

fn cmdListBuffers(ctx: *Context, args: []const []const u8) CmdError!void {
    // -F format: custom format string (format engine not yet implemented, default used)
    // -f filter: filter expression (not yet implemented)
    _ = parseNamedOption(args, "-F");
    _ = parseNamedOption(args, "-f");
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

fn cmdListKeys(ctx: *Context, args: []const []const u8) CmdError!void {
    const manager = ctx.binding_manager orelse {
        try writeReplyMessage(ctx, .error_msg, "list-keys: no binding manager available\n");
        return CmdError.CommandFailed;
    };

    // Parse flags: -1 (compact), -a (all, default), -N (notes only), -P prefix, -T table, [key]
    var compact = false;
    var notes_only = false;
    var filter_table: ?[]const u8 = null;
    var prefix_str: ?[]const u8 = null;
    var filter_key: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-1")) {
            compact = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-a")) {
            // show all — default behaviour, flag accepted but no-op
            i += 1;
        } else if (std.mem.eql(u8, arg, "-N")) {
            notes_only = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "-P")) {
            i += 1;
            if (i < args.len) { prefix_str = args[i]; i += 1; }
        } else if (std.mem.eql(u8, arg, "-T")) {
            i += 1;
            if (i < args.len) { filter_table = args[i]; i += 1; }
        } else if (arg.len > 0 and arg[0] != '-') {
            filter_key = arg;
            i += 1;
        } else {
            i += 1;
        }
    }

    var iter = manager.tables.iterator();
    while (iter.next()) |entry| {
        const table_name = entry.key_ptr.*;
        if (filter_table) |ft| {
            if (!std.mem.eql(u8, ft, table_name)) continue;
        }
        const table = entry.value_ptr;
        for (table.bindings.items) |binding| {
            if (notes_only and binding.note == null) continue;

            var key_buf: [32]u8 = undefined;
            const rendered_key = formatBindingKey(&key_buf, binding.key, binding.modifiers);

            if (filter_key) |fk| {
                if (!std.mem.eql(u8, fk, rendered_key)) continue;
            }

            switch (binding.action) {
                .command => |command| {
                    const pfx = prefix_str orelse "";
                    if (compact) {
                        if (binding.note) |n| {
                            try writeOutput(ctx, "{s}-T {s} {s} {s}  # {s}\n", .{ pfx, table_name, rendered_key, command, n });
                        } else {
                            try writeOutput(ctx, "{s}-T {s} {s} {s}\n", .{ pfx, table_name, rendered_key, command });
                        }
                    } else {
                        if (binding.note) |n| {
                            try writeOutput(ctx, "{s}bind-key -T {s} {s} {s}  # {s}\n", .{ pfx, table_name, rendered_key, command, n });
                        } else {
                            try writeOutput(ctx, "{s}bind-key -T {s} {s} {s}\n", .{ pfx, table_name, rendered_key, command });
                        }
                    }
                },
                .none => {},
            }
        }
    }
}

fn cmdChooseBuffer(ctx: *Context, args: []const []const u8) CmdError!void {
    const active_pane = if (ctx.session) |session|
        if (session.active_window) |window| window.active_pane else null
    else
        null;

    // -r (reverse), -N (no preview), -Z (zoom): flags noted but not yet applied.
    // -N (no preview), -Z (zoom), -F (format), -f (filter),
    // -K (key-format), -O (sort-order), -t (target-pane): parsed but not applied.
    _ = parseNamedOption(args, "-F");
    _ = parseNamedOption(args, "-f");
    _ = parseNamedOption(args, "-K");
    _ = parseNamedOption(args, "-O");
    _ = parseNamedOption(args, "-t");

    var state = ChooseTreeState.init(ctx.allocator, 20);
    errdefer state.deinit();

    const count = ctx.server.paste_stack.count();
    var idx: usize = 0;
    while (idx < count) : (idx += 1) {
        const buffer = ctx.server.paste_stack.get(idx) orelse continue;
        var label_buf: [256]u8 = undefined;
        const label = if (buffer.name) |n|
            std.fmt.bufPrint(&label_buf, "{s}: {d} bytes", .{ n, buffer.data.len }) catch continue
        else
            std.fmt.bufPrint(&label_buf, "buffer{d}: {d} bytes", .{ idx, buffer.data.len }) catch continue;

        const owned_label = state.allocator.dupe(u8, label) catch return CmdError.OutOfMemory;
        errdefer state.allocator.free(owned_label);
        state.labels.append(state.allocator, owned_label) catch return CmdError.OutOfMemory;
        state.tree.addItem(.{
            .label = owned_label,
            .depth = 0,
            .expanded = true,
            .has_children = false,
            .tag = @intCast(state.items.items.len),
        }) catch return CmdError.OutOfMemory;
        state.items.append(state.allocator, .{
            .buffer_index = @intCast(idx),
        }) catch return CmdError.OutOfMemory;
    }

    if (ctx.server.choose_tree_state) |*existing| existing.deinit();
    ctx.server.choose_tree_state = state;
    try renderChooseTree(ctx, active_pane);
}

fn cmdChooseTree(ctx: *Context, args: []const []const u8) CmdError!void {
    const pane = if (ctx.session) |session|
        if (session.active_window) |window| window.active_pane else null
    else
        null;

    var sessions_only = false;
    var windows_only = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-s")) {
            sessions_only = true;
        } else if (std.mem.eql(u8, args[i], "-w")) {
            windows_only = true;
        } else if (std.mem.eql(u8, args[i], "-G") or std.mem.eql(u8, args[i], "-N") or
            std.mem.eql(u8, args[i], "-r") or std.mem.eql(u8, args[i], "-Z"))
        {
            // -G (collapsed), -N (no preview), -r (reverse), -Z (zoom): noted, no-op
        } else if ((std.mem.eql(u8, args[i], "-F") or std.mem.eql(u8, args[i], "-f") or
            std.mem.eql(u8, args[i], "-K") or std.mem.eql(u8, args[i], "-O") or
            std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len)
        {
            i += 1; // consume value for -F/-f/-K/-O/-t
        }
        // template: positional trailing arg — ignored
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

fn cmdClockMode(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = parseNamedOption(args, "-t"); // target-pane parsed but unused
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

fn cmdRunShell(ctx: *Context, args: []const []const u8) CmdError!void {
    var background = false;
    var is_tmux_command = false;

    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-b")) {
            background = true;
        } else if (std.mem.eql(u8, args[i], "-C")) {
            is_tmux_command = true;
        } else if (std.mem.eql(u8, args[i], "-E")) {
            // update environment: no-op
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-d") or
            std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len)
        {
            i += 1;
        }
    }

    if (i >= args.len) return;
    const command = args[i];

    if (is_tmux_command) {
        try executeCommandString(ctx, command);
        return;
    }

    const pid = try spawnShellChild(command);
    if (!background) {
        _ = try waitForChildExit(pid);
    }
}

fn cmdIfShell(ctx: *Context, args: []const []const u8) CmdError!void {
    var format_check = false;

    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-F")) {
            format_check = true;
        } else if (std.mem.eql(u8, args[i], "-b")) {
            // background: run async — for now treat same as foreground
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
        }
    }

    if (i + 1 >= args.len) return CmdError.InvalidArgs;
    const shell_command = args[i];
    const true_command = args[i + 1];
    const false_command: ?[]const u8 = if (i + 2 < args.len) args[i + 2] else null;

    const condition_true: bool = if (format_check) blk: {
        // Treat shell_command as a format string: non-empty and not "0" = true
        break :blk shell_command.len > 0 and !std.mem.eql(u8, shell_command, "0");
    } else blk: {
        const pid = try spawnShellChild(shell_command);
        const status = try waitForChildExit(pid);
        break :blk childExitCode(status) == 0;
    };

    const next_command = if (condition_true) true_command else (false_command orelse return);
    try executeCommandString(ctx, next_command);
}


// -- Hook type helpers --

fn hookTypeFromName(name: []const u8) ?hooks_mod.HookType {
    if (std.mem.eql(u8, name, "after-new-session")) return .after_new_session;
    if (std.mem.eql(u8, name, "after-new-window")) return .after_new_window;
    if (std.mem.eql(u8, name, "after-split-window")) return .after_split_window;
    if (std.mem.eql(u8, name, "after-select-pane")) return .after_select_pane;
    if (std.mem.eql(u8, name, "after-select-window")) return .after_select_window;
    if (std.mem.eql(u8, name, "after-resize-pane")) return .after_resize_pane;
    if (std.mem.eql(u8, name, "after-rename-session")) return .after_rename_session;
    if (std.mem.eql(u8, name, "after-rename-window")) return .after_rename_window;
    if (std.mem.eql(u8, name, "client-attached")) return .client_attached;
    if (std.mem.eql(u8, name, "client-detached")) return .client_detached;
    if (std.mem.eql(u8, name, "client-resized")) return .client_resized;
    if (std.mem.eql(u8, name, "pane-exited")) return .pane_exited;
    if (std.mem.eql(u8, name, "pane-focus-in")) return .pane_focus_in;
    if (std.mem.eql(u8, name, "pane-focus-out")) return .pane_focus_out;
    if (std.mem.eql(u8, name, "window-linked")) return .window_linked;
    if (std.mem.eql(u8, name, "window-unlinked")) return .window_unlinked;
    if (std.mem.eql(u8, name, "session-closed")) return .session_closed;
    if (std.mem.eql(u8, name, "session-renamed")) return .session_renamed;
    if (std.mem.eql(u8, name, "window-renamed")) return .window_renamed;
    return null;
}

fn hookTypeName(hook_type: hooks_mod.HookType) []const u8 {
    return switch (hook_type) {
        .after_new_session => "after-new-session",
        .after_new_window => "after-new-window",
        .after_split_window => "after-split-window",
        .after_select_pane => "after-select-pane",
        .after_select_window => "after-select-window",
        .after_resize_pane => "after-resize-pane",
        .after_rename_session => "after-rename-session",
        .after_rename_window => "after-rename-window",
        .client_attached => "client-attached",
        .client_detached => "client-detached",
        .client_resized => "client-resized",
        .pane_exited => "pane-exited",
        .pane_focus_in => "pane-focus-in",
        .pane_focus_out => "pane-focus-out",
        .window_linked => "window-linked",
        .window_unlinked => "window-unlinked",
        .session_closed => "session-closed",
        .session_renamed => "session-renamed",
        .window_renamed => "window-renamed",
    };
}

// -- New command implementations --

fn cmdChooseClient(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    const pane = if (ctx.session) |s| if (s.active_window) |w| w.active_pane else null else null;

    var state = ChooseTreeState.init(ctx.allocator, 10);
    errdefer state.deinit();

    for (ctx.server.clients.items, 0..) |client, idx| {
        const session_name = if (client.session) |s| s.name else "(none)";
        var label_buf: [256]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "client {d}: session={s}", .{ idx, session_name }) catch return CmdError.CommandFailed;
        const owned_label = state.allocator.dupe(u8, label) catch return CmdError.OutOfMemory;
        errdefer state.allocator.free(owned_label);
        state.labels.append(state.allocator, owned_label) catch return CmdError.OutOfMemory;
        if (client.session) |s| {
            state.tree.addItem(.{
                .label = owned_label,
                .depth = 0,
                .expanded = false,
                .has_children = false,
                .tag = @intCast(state.items.items.len),
            }) catch return CmdError.OutOfMemory;
            state.items.append(state.allocator, .{
                .session = @ptrCast(s),
                .window = null,
                .pane = null,
            }) catch return CmdError.OutOfMemory;
        }
    }

    if (ctx.server.choose_tree_state) |*existing| existing.deinit();
    ctx.server.choose_tree_state = state;
    try renderChooseTree(ctx, pane);
}

fn cmdConfirmBefore(ctx: *Context, args: []const []const u8) CmdError!void {
    var prompt: []const u8 = "confirm?";
    var command: ?[]const u8 = null;
    var default_yes = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-p") and i + 1 < args.len) {
            i += 1;
            prompt = args[i];
        } else if (std.mem.eql(u8, args[i], "-y")) {
            default_yes = true;
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len) {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-b")) {
            // beep: no-op
        } else if (args[i].len > 0 and args[i][0] != '-') {
            command = args[i];
        }
    }

    const cmd_str = command orelse return CmdError.InvalidArgs;

    if (default_yes) {
        try executeCommandString(ctx, cmd_str);
        return;
    }

    // Output prompt; full interactive confirm requires key event routing
    try writeOutput(ctx, "{s} (y/n) ", .{prompt});
}

fn cmdCustomizeMode(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    const session = ctx.session orelse return CmdError.SessionNotFound;
    try writeOutput(ctx, "Options for session '{s}':\n", .{session.name});
    try writeOutput(ctx, "  base-index: {d}\n", .{session.options.base_index});
    try writeOutput(ctx, "  default-shell: {s}\n", .{session.options.default_shell});
    try writeOutput(ctx, "  mouse: {s}\n", .{if (session.options.mouse) "on" else "off"});
    try writeOutput(ctx, "  status: {s}\n", .{if (session.options.status) "on" else "off"});
    try writeOutput(ctx, "  visual-activity: {s}\n", .{if (session.options.visual_activity) "on" else "off"});
}

fn cmdDisplayMenu(ctx: *Context, args: []const []const u8) CmdError!void {
    var title: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-T") and i + 1 < args.len) {
            i += 1;
            title = args[i];
        } else if ((std.mem.eql(u8, args[i], "-b") or std.mem.eql(u8, args[i], "-c") or
            std.mem.eql(u8, args[i], "-C") or std.mem.eql(u8, args[i], "-H") or
            std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "-S") or
            std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "-x") or
            std.mem.eql(u8, args[i], "-y")) and i + 1 < args.len)
        {
            i += 1;
        } else if (std.mem.eql(u8, args[i], "-O") or std.mem.eql(u8, args[i], "-M")) {
            // boolean flags
        } else if (args[i].len > 0 and args[i][0] != '-') {
            break; // start of name/key/command triples
        }
    }

    if (title) |t| try writeOutput(ctx, "--- {s} ---\n", .{t});

    // Display remaining as name/key/command triples
    while (i + 2 < args.len) : (i += 3) {
        const item_name = args[i];
        const item_key = args[i + 1];
        // args[i+2] is the command; not executed in menu display mode
        try writeOutput(ctx, "  [{s}] {s}\n", .{ item_key, item_name });
    }
}

fn cmdDisplayPopup(_: *Context, args: []const []const u8) CmdError!void {
    var shell_cmd: ?[]const u8 = null;
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-C")) {
            return; // close existing popup
        } else if (std.mem.eql(u8, args[i], "-E") or std.mem.eql(u8, args[i], "-B") or
            std.mem.eql(u8, args[i], "-N"))
        {
            // boolean flags
        } else if ((std.mem.eql(u8, args[i], "-b") or std.mem.eql(u8, args[i], "-c") or
            std.mem.eql(u8, args[i], "-d") or std.mem.eql(u8, args[i], "-e") or
            std.mem.eql(u8, args[i], "-h") or std.mem.eql(u8, args[i], "-k") or
            std.mem.eql(u8, args[i], "-s") or std.mem.eql(u8, args[i], "-S") or
            std.mem.eql(u8, args[i], "-t") or std.mem.eql(u8, args[i], "-T") or
            std.mem.eql(u8, args[i], "-w") or std.mem.eql(u8, args[i], "-x") or
            std.mem.eql(u8, args[i], "-y")) and i + 1 < args.len)
        {
            i += 1;
        } else if (args[i].len > 0 and args[i][0] != '-') {
            shell_cmd = args[i];
            break;
        }
    }

    if (shell_cmd) |command| {
        const pid = try spawnShellChild(command);
        _ = try waitForChildExit(pid);
    }
}

fn cmdSetHook(ctx: *Context, args: []const []const u8) CmdError!void {
    var is_append = false;
    var is_unset = false;
    var is_run = false;

    var i: usize = 0;
    while (i < args.len and args[i].len > 0 and args[i][0] == '-') : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            is_append = true;
        } else if (std.mem.eql(u8, args[i], "-u")) {
            is_unset = true;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            is_run = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
        }
        // -g/-p/-w are boolean scope flags; no-op
    }

    if (i >= args.len) return CmdError.InvalidArgs;
    const hook_name = args[i];
    i += 1;
    const hook_command: ?[]const u8 = if (i < args.len) args[i] else null;

    const hook_type = hookTypeFromName(hook_name) orelse return CmdError.InvalidArgs;

    if (is_unset) {
        if (hook_command) |cmd_str| {
            ctx.server.hook_registry.removeHook(hook_type, cmd_str);
        } else {
            if (ctx.server.hook_registry.hooks.getPtr(hook_type)) |list| {
                for (list.items) |h| ctx.server.hook_registry.allocator.free(h.command);
                list.clearRetainingCapacity();
            }
        }
        return;
    }

    const cmd_str = hook_command orelse return CmdError.InvalidArgs;

    if (!is_append) {
        if (ctx.server.hook_registry.hooks.getPtr(hook_type)) |list| {
            for (list.items) |h| ctx.server.hook_registry.allocator.free(h.command);
            list.clearRetainingCapacity();
        }
    }

    ctx.server.hook_registry.addHook(hook_type, cmd_str) catch return CmdError.OutOfMemory;

    if (is_run) {
        try executeCommandString(ctx, cmd_str);
    }
}

fn cmdShowHooks(ctx: *Context, args: []const []const u8) CmdError!void {
    var filter: ?[]const u8 = null;
    for (args) |arg| {
        if (arg.len > 0 and arg[0] != '-') filter = arg;
    }

    const all_hooks = [_]hooks_mod.HookType{
        .after_new_session,    .after_new_window,    .after_split_window,
        .after_select_pane,    .after_select_window,  .after_resize_pane,
        .after_rename_session, .after_rename_window,  .client_attached,
        .client_detached,      .client_resized,       .pane_exited,
        .pane_focus_in,        .pane_focus_out,       .window_linked,
        .window_unlinked,      .session_closed,       .session_renamed,
        .window_renamed,
    };

    for (all_hooks) |ht| {
        const name = hookTypeName(ht);
        if (filter) |f| {
            if (!std.mem.eql(u8, f, name)) continue;
        }
        for (ctx.server.hook_registry.getHooks(ht)) |hook| {
            try writeOutput(ctx, "{s}: {s}\n", .{ name, hook.command });
        }
    }
}

fn cmdClearPromptHistory(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args; // -T prompt-type filtering not implemented
    for (ctx.server.prompt_history.items) |entry| {
        ctx.server.allocator.free(entry);
    }
    ctx.server.prompt_history.clearRetainingCapacity();
}

fn cmdShowPromptHistory(ctx: *Context, args: []const []const u8) CmdError!void {
    _ = args;
    for (ctx.server.prompt_history.items, 0..) |entry, idx| {
        try writeOutput(ctx, "{d}: {s}\n", .{ idx, entry });
    }
}

fn cmdWaitFor(ctx: *Context, args: []const []const u8) CmdError!void {
    var is_lock = false;
    var is_signal = false;
    var is_unlock = false;
    var channel: ?[]const u8 = null;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-L")) {
            is_lock = true;
        } else if (std.mem.eql(u8, arg, "-S")) {
            is_signal = true;
        } else if (std.mem.eql(u8, arg, "-U")) {
            is_unlock = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            channel = arg;
        }
    }

    const ch = channel orelse return CmdError.InvalidArgs;

    if (is_signal or is_unlock) {
        if (ctx.server.wait_channels.fetchRemove(ch)) |removed| {
            ctx.server.allocator.free(removed.key);
            var wc = removed.value;
            wc.deinit(ctx.server.allocator);
        }
        return;
    }

    if (is_lock) {
        if (!ctx.server.wait_channels.contains(ch)) {
            const owned_ch = ctx.server.allocator.dupe(u8, ch) catch return CmdError.OutOfMemory;
            ctx.server.wait_channels.put(owned_ch, .empty) catch {
                ctx.server.allocator.free(owned_ch);
                return CmdError.OutOfMemory;
            };
        }
        return;
    }

    // No flag: block until signaled — not supported without async I/O; return immediately.
}

fn cmdServerAccess(ctx: *Context, args: []const []const u8) CmdError!void {
    var is_allow = false;
    var is_deny = false;
    var is_list = false;
    var is_read_only = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a")) {
            is_allow = true;
        } else if (std.mem.eql(u8, args[i], "-d")) {
            is_deny = true;
        } else if (std.mem.eql(u8, args[i], "-l")) {
            is_list = true;
        } else if (std.mem.eql(u8, args[i], "-r")) {
            is_read_only = true;
        } else if (std.mem.eql(u8, args[i], "-w")) {
            is_read_only = false;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
        }
    }

    if (is_list) {
        for (ctx.server.acl_entries.items) |entry| {
            const mode = if (entry.read_only) "read-only" else "write";
            const access = if (entry.allow) "allow" else "deny";
            try writeOutput(ctx, "{s}: {s} {s}\n", .{ entry.user, access, mode });
        }
        return;
    }

    // Get user argument (last non-flag arg)
    var user: ?[]const u8 = null;
    i = 0;
    while (i < args.len) : (i += 1) {
        if (args[i].len > 0 and args[i][0] == '-') {
            if ((std.mem.eql(u8, args[i], "-t")) and i + 1 < args.len) i += 1;
            continue;
        }
        user = args[i];
    }

    const u = user orelse return CmdError.InvalidArgs;

    // Remove existing entry for this user
    var j: usize = 0;
    while (j < ctx.server.acl_entries.items.len) {
        if (std.mem.eql(u8, ctx.server.acl_entries.items[j].user, u)) {
            ctx.server.allocator.free(ctx.server.acl_entries.items[j].user);
            _ = ctx.server.acl_entries.orderedRemove(j);
        } else {
            j += 1;
        }
    }

    if (is_deny) return; // deny = remove from allow list

    const owned_user = ctx.server.allocator.dupe(u8, u) catch return CmdError.OutOfMemory;
    ctx.server.acl_entries.append(ctx.server.allocator, .{
        .user = owned_user,
        .allow = !is_deny or is_allow,
        .read_only = is_read_only,
    }) catch {
        ctx.server.allocator.free(owned_user);
        return CmdError.OutOfMemory;
    };
}

extern "c" fn execvp(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
) i32;

extern "c" fn dup2(oldfd: std.c.fd_t, newfd: std.c.fd_t) c_int;

// -- Window command implementations --

fn cmdFindWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    var case_insensitive = false;
    var search_name = false;
    var search_title = false;
    var search_content = false;
    var match_string: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-i")) {
            case_insensitive = true;
        } else if (std.mem.eql(u8, arg, "-C")) {
            search_content = true;
        } else if (std.mem.eql(u8, arg, "-N")) {
            search_name = true;
        } else if (std.mem.eql(u8, arg, "-T")) {
            search_title = true;
        } else if (std.mem.eql(u8, arg, "-r") or std.mem.eql(u8, arg, "-Z")) {
            // -r: regex (treat as substring), -Z: zoom pane on match
        } else if (std.mem.eql(u8, arg, "-t") and i + 1 < args.len) {
            i += 1; // skip target-pane value
        } else if (arg.len > 0 and arg[0] != '-') {
            match_string = arg;
        }
    }
    // Default: search both name and title when no search type specified
    if (!search_name and !search_title and !search_content) {
        search_name = true;
        search_title = true;
    }

    const pattern = match_string orelse return CmdError.InvalidArgs;

    var found: usize = 0;
    for (ctx.server.sessions.items) |session| {
        for (session.windows.items, 0..) |window, idx| {
            const name_match = blk: {
                if (!search_name and !search_title) break :blk false;
                if (case_insensitive) {
                    var name_lower: [256]u8 = undefined;
                    var pat_lower: [256]u8 = undefined;
                    const nl = @min(window.name.len, name_lower.len);
                    const pl = @min(pattern.len, pat_lower.len);
                    for (window.name[0..nl], 0..) |c, j| name_lower[j] = std.ascii.toLower(c);
                    for (pattern[0..pl], 0..) |c, j| pat_lower[j] = std.ascii.toLower(c);
                    break :blk std.mem.indexOf(u8, name_lower[0..nl], pat_lower[0..pl]) != null;
                }
                break :blk std.mem.indexOf(u8, window.name, pattern) != null;
            };
            if (name_match) {
                found += 1;
                try writeOutput(ctx, "{s}:{d}: {s}\n", .{
                    session.name,
                    session.options.base_index + @as(u32, @intCast(idx)),
                    window.name,
                });
            }
        }
    }
    if (found == 0) {
        try writeReplyMessage(ctx, .error_msg, "no windows found\n");
        return CmdError.CommandFailed;
    }
}

fn cmdLinkWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var no_select = false;
    var src_target: ?[]const u8 = null;
    var dst_target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-b") or
            std.mem.eql(u8, args[i], "-k"))
        {
            // -a (after), -b (before), -k (kill if exists): positional flags noted
        } else if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src_target = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            dst_target = args[i];
        }
    }

    const src_window = if (src_target) |t| blk: {
        const num = std.fmt.parseInt(u32, t, 10) catch return CmdError.InvalidArgs;
        break :blk session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
    } else session.active_window orelse return CmdError.WindowNotFound;

    // Destination session: try to parse "session:window" or session name
    const dst_session = if (dst_target) |t| blk: {
        // Check for colon-separated "session:window" format
        if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
            break :blk ctx.server.findSession(t[0..colon]) orelse session;
        }
        break :blk ctx.server.findSession(t) orelse session;
    } else session;

    // Create a new window with the same name in the destination session
    const new_window = Window.init(ctx.allocator, src_window.name, src_window.sx, src_window.sy) catch return CmdError.OutOfMemory;
    errdefer new_window.deinit();

    const pane = spawnWindowPane(ctx.allocator, defaultShellFromContext(ctx), new_window.sx, new_window.sy) catch |err| switch (err) {
        CmdError.OutOfMemory => return CmdError.OutOfMemory,
        else => return CmdError.CommandFailed,
    };
    errdefer pane.deinit();

    new_window.addPane(pane) catch return CmdError.OutOfMemory;
    dst_session.addWindow(new_window) catch return CmdError.OutOfMemory;
    if (!no_select) dst_session.selectWindow(new_window);
    ctx.server.trackPane(pane, new_window.sx, new_window.sy) catch return CmdError.CommandFailed;
}

fn cmdMoveWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var no_select = false;
    var renumber = false;
    var src_target: ?[]const u8 = null;
    var dst_target: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-d")) {
            no_select = true;
        } else if (std.mem.eql(u8, args[i], "-r")) {
            renumber = true;
        } else if (std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-b") or
            std.mem.eql(u8, args[i], "-k"))
        {
            // positional flags noted
        } else if (std.mem.eql(u8, args[i], "-s") and i + 1 < args.len) {
            i += 1;
            src_target = args[i];
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            dst_target = args[i];
        }
    }

    // Resolve source window
    const src_window = if (src_target) |t| blk: {
        const num = std.fmt.parseInt(u32, t, 10) catch return CmdError.InvalidArgs;
        break :blk session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
    } else session.active_window orelse return CmdError.WindowNotFound;

    // Resolve destination session
    const dst_session = if (dst_target) |t| blk: {
        if (std.mem.indexOfScalar(u8, t, ':')) |colon| {
            break :blk ctx.server.findSession(t[0..colon]) orelse session;
        }
        break :blk ctx.server.findSession(t) orelse session;
    } else session;

    if (dst_session == session) {
        // Same session: just reorder (move to end)
        for (session.windows.items, 0..) |w, idx| {
            if (w == src_window) {
                _ = session.windows.orderedRemove(idx);
                break;
            }
        }
        session.windows.append(session.allocator, src_window) catch return CmdError.OutOfMemory;
        if (!no_select) session.selectWindow(src_window);
        return;
    }

    // Cross-session move: remove from src session, add to dst session
    for (session.windows.items, 0..) |w, idx| {
        if (w == src_window) {
            _ = session.windows.orderedRemove(idx);
            break;
        }
    }
    if (session.active_window == src_window) {
        session.active_window = if (session.windows.items.len > 0) session.windows.items[0] else null;
    }

    dst_session.addWindow(src_window) catch return CmdError.OutOfMemory;
    if (!no_select) dst_session.selectWindow(src_window);
}

fn cmdResizeWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var window = session.active_window orelse return CmdError.WindowNotFound;
    var dx: i32 = 0;
    var dy: i32 = 0;
    var abs_x: ?u32 = null;
    var abs_y: ?u32 = null;
    var amount: u32 = 1;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-U")) {
            dy = -1;
        } else if (std.mem.eql(u8, args[i], "-D")) {
            dy = 1;
        } else if (std.mem.eql(u8, args[i], "-L")) {
            dx = -1;
        } else if (std.mem.eql(u8, args[i], "-R")) {
            dx = 1;
        } else if (std.mem.eql(u8, args[i], "-a") or std.mem.eql(u8, args[i], "-A")) {
            // -a: fit smallest client, -A: fit largest client — no-op (no client dims tracked)
        } else if (std.mem.eql(u8, args[i], "-x") and i + 1 < args.len) {
            i += 1;
            abs_x = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, args[i], "-y") and i + 1 < args.len) {
            i += 1;
            abs_y = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            const num = std.fmt.parseInt(u32, args[i], 10) catch return CmdError.InvalidArgs;
            window = session.findWindowByNumber(num) orelse return CmdError.WindowNotFound;
        } else {
            amount = std.fmt.parseInt(u32, args[i], 10) catch amount;
        }
    }

    const new_sx = if (abs_x) |x| x else if (dx < 0)
        @max(1, window.sx -| amount)
    else if (dx > 0)
        window.sx + amount
    else
        window.sx;

    const new_sy = if (abs_y) |y| y else if (dy < 0)
        @max(1, window.sy -| amount)
    else if (dy > 0)
        window.sy + amount
    else
        window.sy;

    if (new_sx == window.sx and new_sy == window.sy) return;
    window.resize(new_sx, new_sy);
}

fn cmdRespawnWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var kill_running = false;
    var target_num: ?u32 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-k")) {
            kill_running = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_num = std.fmt.parseInt(u32, args[i], 10) catch null;
        } else if ((std.mem.eql(u8, args[i], "-c") or std.mem.eql(u8, args[i], "-e")) and i + 1 < args.len) {
            i += 1; // consume -c dir / -e env value
        }
    }

    const window = if (target_num) |n|
        session.findWindowByNumber(n) orelse return CmdError.WindowNotFound
    else
        session.active_window orelse return CmdError.WindowNotFound;

    const pane = window.active_pane orelse return CmdError.PaneNotFound;

    // Kill running process if requested or if already exited
    if (kill_running and pane.pid > 0) {
        _ = std.c.kill(pane.pid, .TERM);
        _ = std.c.waitpid(pane.pid, null, 0);
        pane.pid = 0;
    } else if (!kill_running and pane.pid > 0) {
        // Check if still running; refuse if process is alive
        if (std.c.kill(pane.pid, @enumFromInt(0)) == 0) {
            try writeReplyMessage(ctx, .error_msg, "respawn-window: pane still active (use -k to force)\n");
            return CmdError.CommandFailed;
        }
    }

    // Close old fd
    if (pane.fd >= 0) {
        ctx.server.untrackPane(pane.id);
        _ = std.c.close(pane.fd);
        pane.fd = -1;
    }

    // Spawn a fresh PTY
    const shell = defaultShellFromContext(ctx);
    var pty = Pty.openPty() catch return CmdError.CommandFailed;
    pty.forkExec(shell, null) catch return CmdError.CommandFailed;
    pty.resize(@intCast(pane.sx), @intCast(pane.sy));
    pane.fd = pty.master_fd;
    pane.pid = pty.pid;
    pane.flags.exited = false;
    ctx.server.trackPane(pane, pane.sx, pane.sy) catch return CmdError.CommandFailed;
}

fn cmdUnlinkWindow(ctx: *Context, args: []const []const u8) CmdError!void {
    const session = ctx.session orelse return CmdError.SessionNotFound;
    var kill_if_last = false;
    var target_num: ?u32 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "-k")) {
            kill_if_last = true;
        } else if (std.mem.eql(u8, args[i], "-t") and i + 1 < args.len) {
            i += 1;
            target_num = std.fmt.parseInt(u32, args[i], 10) catch null;
        }
    }

    const window = if (target_num) |n|
        session.findWindowByNumber(n) orelse return CmdError.WindowNotFound
    else
        session.active_window orelse return CmdError.WindowNotFound;

    if (kill_if_last) {
        for (window.panes.items) |pane| ctx.server.untrackPane(pane.id);
        const session_empty = session.removeWindow(window);
        if (session_empty) {
            ctx.session = null;
            ctx.server.removeSession(session);
        }
    } else {
        // Remove window from session without destroying it (tmux semantics:
        // destroy only if this is the last link). Since we have no real linking,
        // just remove from session list and deinit.
        for (window.panes.items) |pane| ctx.server.untrackPane(pane.id);
        const session_empty = session.removeWindow(window);
        if (session_empty) {
            ctx.session = null;
            ctx.server.removeSession(session);
        }
    }
}


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
