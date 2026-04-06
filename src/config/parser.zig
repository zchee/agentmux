const std = @import("std");

/// A parsed command from the tmux config language.
pub const Command = struct {
    name: []const u8,
    args: std.ArrayListAligned([]const u8, null),

    pub fn deinit(self: *Command, alloc: std.mem.Allocator) void {
        for (self.args.items) |arg| {
            alloc.free(arg);
        }
        self.args.deinit(alloc);
        alloc.free(self.name);
    }
};

/// Token types for the config lexer.
const TokenType = enum {
    word,
    string_single,
    string_double,
    semicolon,
    newline,
    comment,
    eof,
};

const Token = struct {
    kind: TokenType,
    value: []const u8,
};

/// Recursive descent parser for tmux-compatible config language.
/// Supports:
///   set -g option value
///   bind-key -T prefix key command
///   if-shell "test" "command1" "command2"
///   source-file path
///   # comments
///   ; as command separator
///   'single quoted strings'
///   "double quoted strings with \escapes"
pub const ConfigParser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, source: []const u8) ConfigParser {
        return .{
            .source = source,
            .pos = 0,
            .allocator = alloc,
        };
    }

    /// Parse all commands from the source.
    pub fn parseAll(self: *ConfigParser) !std.ArrayListAligned(Command, null) {
        var commands: std.ArrayListAligned(Command, null) = .empty;
        errdefer {
            for (commands.items) |*cmd| cmd.deinit(self.allocator);
            commands.deinit(self.allocator);
        }

        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            // Skip comments
            if (self.peek() == '#') {
                self.skipLine();
                continue;
            }
            // Skip empty lines and semicolons
            if (self.peek() == '\n' or self.peek() == ';') {
                self.pos += 1;
                continue;
            }

            if (try self.parseCommand()) |cmd| {
                try commands.append(self.allocator, cmd);
            }
        }
        return commands;
    }

    /// Parse a single command.
    fn parseCommand(self: *ConfigParser) !?Command {
        self.skipWhitespace();
        if (self.pos >= self.source.len) return null;
        if (self.peek() == '#' or self.peek() == '\n') return null;

        // First token is the command name
        const name_tok = try self.nextToken() orelse return null;
        if (name_tok.kind == .newline or name_tok.kind == .semicolon or name_tok.kind == .comment) {
            return null;
        }

        const name = try self.dupTokenValue(name_tok);
        errdefer self.allocator.free(name);

        var args: std.ArrayListAligned([]const u8, null) = .empty;
        errdefer {
            for (args.items) |a| self.allocator.free(a);
            args.deinit(self.allocator);
        }

        // Collect arguments until end of command
        while (true) {
            self.skipInlineWhitespace();
            if (self.pos >= self.source.len) break;
            if (self.peek() == '\\' and self.peekNext() == '\n') {
                self.skipLineContinuation();
                continue;
            }
            if (self.peek() == '\n' or self.peek() == ';' or self.peek() == '#') break;

            const tok = try self.nextToken() orelse break;
            if (tok.kind == .newline or tok.kind == .semicolon or tok.kind == .comment or tok.kind == .eof) break;

            const arg = try self.dupTokenValue(tok);
            try args.append(self.allocator, arg);
        }

        return .{ .name = name, .args = args };
    }

    fn nextToken(self: *ConfigParser) !?Token {
        if (self.pos >= self.source.len) return null;

        const c = self.source[self.pos];

        if (c == '\n') {
            self.pos += 1;
            return .{ .kind = .newline, .value = "\n" };
        }
        if (c == ';') {
            self.pos += 1;
            return .{ .kind = .semicolon, .value = ";" };
        }
        if (c == '#') {
            const start = self.pos;
            self.skipLine();
            return .{ .kind = .comment, .value = self.source[start..self.pos] };
        }
        if (c == '\'') return self.parseSingleQuoted();
        if (c == '"') return self.parseDoubleQuoted();

        return self.parseWord();
    }

    fn parseWord(self: *ConfigParser) Token {
        const start = self.pos;
        while (self.pos < self.source.len) {
            const ch = self.source[self.pos];
            if (ch == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2;
                continue;
            }
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == ';' or ch == '#' or ch == '"' or ch == '\'') break;
            self.pos += 1;
        }
        return .{ .kind = .word, .value = self.source[start..self.pos] };
    }

    fn parseSingleQuoted(self: *ConfigParser) Token {
        self.pos += 1; // skip opening '
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '\'') {
            self.pos += 1;
        }
        const value = self.source[start..self.pos];
        if (self.pos < self.source.len) self.pos += 1; // skip closing '
        return .{ .kind = .string_single, .value = value };
    }

    fn parseDoubleQuoted(self: *ConfigParser) Token {
        self.pos += 1; // skip opening "
        const start = self.pos;
        while (self.pos < self.source.len and self.source[self.pos] != '"') {
            if (self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                self.pos += 2; // skip escape
            } else {
                self.pos += 1;
            }
        }
        const value = self.source[start..self.pos];
        if (self.pos < self.source.len) self.pos += 1; // skip closing "
        return .{ .kind = .string_double, .value = value };
    }

    fn peek(self: *const ConfigParser) u8 {
        if (self.pos >= self.source.len) return 0;
        return self.source[self.pos];
    }

    fn peekNext(self: *const ConfigParser) u8 {
        if (self.pos + 1 >= self.source.len) return 0;
        return self.source[self.pos + 1];
    }

    fn skipWhitespace(self: *ConfigParser) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipInlineWhitespace(self: *ConfigParser) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipLineContinuation(self: *ConfigParser) void {
        if (self.peek() != '\\' or self.peekNext() != '\n') return;
        self.pos += 2;
        self.skipInlineWhitespace();
    }

    fn skipLine(self: *ConfigParser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1; // skip newline
    }

    fn dupTokenValue(self: *ConfigParser, tok: Token) ![]u8 {
        if (tok.kind == .string_single or std.mem.indexOfScalar(u8, tok.value, '\\') == null) {
            return self.allocator.dupe(u8, tok.value);
        }

        var out: std.ArrayListAligned(u8, null) = .empty;
        errdefer out.deinit(self.allocator);

        var i: usize = 0;
        while (i < tok.value.len) {
            if (tok.value[i] == '\\' and i + 1 < tok.value.len) {
                const next = tok.value[i + 1];
                if (next == '\n') {
                    i += 2;
                    while (i < tok.value.len and (tok.value[i] == ' ' or tok.value[i] == '\t')) {
                        i += 1;
                    }
                    continue;
                }

                switch (next) {
                    ';', '#', '\\', '"', '\'', ' ' => {
                        try out.append(self.allocator, next);
                        i += 2;
                        continue;
                    },
                    else => {},
                }
            }

            try out.append(self.allocator, tok.value[i]);
            i += 1;
        }

        return out.toOwnedSlice(self.allocator);
    }
};

test "parse simple command" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "set -g status on\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqualStrings("set", cmds.items[0].name);
    try std.testing.expectEqual(@as(usize, 3), cmds.items[0].args.items.len);
    try std.testing.expectEqualStrings("-g", cmds.items[0].args.items[0]);
    try std.testing.expectEqualStrings("status", cmds.items[0].args.items[1]);
    try std.testing.expectEqualStrings("on", cmds.items[0].args.items[2]);
}

test "parse multiple commands" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "set -g status on\nbind-key C-a send-prefix\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), cmds.items.len);
    try std.testing.expectEqualStrings("set", cmds.items[0].name);
    try std.testing.expectEqualStrings("bind-key", cmds.items[1].name);
}

test "parse with comments and blank lines" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "# This is a comment\n\nset -g mouse on\n# Another comment\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqualStrings("set", cmds.items[0].name);
}

test "parse quoted strings" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "set -g status-style 'fg=white,bg=black'\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqualStrings("fg=white,bg=black", cmds.items[0].args.items[2]);
}

test "parse semicolon separator" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "set -g status on ; set -g mouse on\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 2), cmds.items.len);
}

test "parse escaped semicolon as argument" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "bind-key r source-file ~/.tmux.conf \\; display-message 'reloaded'\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqualStrings("bind-key", cmds.items[0].name);
    try std.testing.expectEqual(@as(usize, 6), cmds.items[0].args.items.len);
    try std.testing.expectEqualStrings(";", cmds.items[0].args.items[3]);
    try std.testing.expectEqualStrings("display-message", cmds.items[0].args.items[4]);
    try std.testing.expectEqualStrings("reloaded", cmds.items[0].args.items[5]);
}

test "parse backslash newline continuation in same command" {
    const alloc = std.testing.allocator;
    var parser = ConfigParser.init(alloc, "bind-key r \\\n  send-prefix\n");
    var cmds = try parser.parseAll();
    defer {
        for (cmds.items) |*c| c.deinit(alloc);
        cmds.deinit(alloc);
    }

    try std.testing.expectEqual(@as(usize, 1), cmds.items.len);
    try std.testing.expectEqualStrings("bind-key", cmds.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), cmds.items[0].args.items.len);
    try std.testing.expectEqualStrings("r", cmds.items[0].args.items[0]);
    try std.testing.expectEqualStrings("send-prefix", cmds.items[0].args.items[1]);
}
