const std = @import("std");
const layout_mod = @import("layout.zig");
const LayoutCell = layout_mod.LayoutCell;
const CellType = layout_mod.CellType;

/// Compute the tmux layout checksum (same algorithm as tmux's layout_checksum).
/// Applied to the serialized string without the "XXXX," prefix.
fn layoutChecksum(s: []const u8) u16 {
    var csum: u16 = 0;
    for (s) |c| {
        csum = (csum >> 1) | ((csum & 1) << 15);
        csum +%= c;
    }
    return csum;
}

/// Recursively append a cell's layout string (without checksum prefix) to buf.
fn serializeCell(buf: *std.ArrayListAligned(u8, null), alloc: std.mem.Allocator, cell: *const LayoutCell) !void {
    const dims = try std.fmt.allocPrint(alloc, "{d}x{d},{d},{d}", .{
        cell.sx, cell.sy, cell.xoff, cell.yoff,
    });
    defer alloc.free(dims);
    try buf.appendSlice(alloc, dims);

    switch (cell.cell_type) {
        .pane => {},
        .horizontal => {
            try buf.append(alloc, '{');
            for (cell.children.items, 0..) |child, i| {
                if (i > 0) try buf.append(alloc, ',');
                try serializeCell(buf, alloc, child);
            }
            try buf.append(alloc, '}');
        },
        .vertical => {
            try buf.append(alloc, '[');
            for (cell.children.items, 0..) |child, i| {
                if (i > 0) try buf.append(alloc, ',');
                try serializeCell(buf, alloc, child);
            }
            try buf.append(alloc, ']');
        },
    }
}

/// Serialize a layout cell tree to a tmux layout string.
///
/// Format: "XXXX,WxH,X,Y{...}" where XXXX is the 4-hex-digit checksum over
/// everything after the first comma.  Horizontal splits use `{...}`, vertical
/// splits use `[...]`.  Caller owns the returned slice.
pub fn serialize(alloc: std.mem.Allocator, cell: *const LayoutCell) ![]u8 {
    var buf: std.ArrayListAligned(u8, null) = .empty;
    errdefer buf.deinit(alloc);

    try serializeCell(&buf, alloc, cell);

    const inner = try buf.toOwnedSlice(alloc);
    defer alloc.free(inner);

    const csum = layoutChecksum(inner);
    return std.fmt.allocPrint(alloc, "{x:0>4},{s}", .{ csum, inner });
}

/// Recursive-descent parser for tmux layout strings.
const Parser = struct {
    input: []const u8,
    pos: usize,
    next_pane_id: u32,

    fn init(input: []const u8) Parser {
        return .{ .input = input, .pos = 0, .next_pane_id = 0 };
    }

    fn peek(self: *const Parser) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn expect(self: *Parser, c: u8) !void {
        if (self.peek() != c) return error.InvalidFormat;
        self.advance();
    }

    fn parseU32(self: *Parser) !u32 {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c < '0' or c > '9') break;
            self.pos += 1;
        }
        if (self.pos == start) return error.InvalidFormat;
        return std.fmt.parseInt(u32, self.input[start..self.pos], 10) catch
            error.InvalidFormat;
    }

    /// Parse one cell starting at the current position.
    /// Assigns sequential pane IDs to leaf nodes.
    fn parseCell(self: *Parser, alloc: std.mem.Allocator) !*LayoutCell {
        const w = try self.parseU32();
        try self.expect('x');
        const h = try self.parseU32();
        try self.expect(',');
        const x = try self.parseU32();
        try self.expect(',');
        const y = try self.parseU32();

        const open = self.peek() orelse 0;
        if (open == '{') {
            self.advance();
            const cell = try LayoutCell.initBranch(alloc, .horizontal, w, h, x, y);
            errdefer cell.deinit();
            while (true) {
                const child = try self.parseCell(alloc);
                // On addChild failure, free child explicitly before returning.
                cell.addChild(child) catch |err| {
                    child.deinit();
                    return err;
                };
                const sep = self.peek() orelse return error.InvalidFormat;
                if (sep == '}') {
                    self.advance();
                    break;
                }
                if (sep == ',') {
                    self.advance();
                    continue;
                }
                return error.InvalidFormat;
            }
            return cell;
        } else if (open == '[') {
            self.advance();
            const cell = try LayoutCell.initBranch(alloc, .vertical, w, h, x, y);
            errdefer cell.deinit();
            while (true) {
                const child = try self.parseCell(alloc);
                cell.addChild(child) catch |err| {
                    child.deinit();
                    return err;
                };
                const sep = self.peek() orelse return error.InvalidFormat;
                if (sep == ']') {
                    self.advance();
                    break;
                }
                if (sep == ',') {
                    self.advance();
                    continue;
                }
                return error.InvalidFormat;
            }
            return cell;
        } else {
            // Leaf pane: assign next sequential ID.
            const pane_id = self.next_pane_id;
            self.next_pane_id += 1;
            return LayoutCell.initLeaf(alloc, pane_id, w, h, x, y);
        }
    }
};

/// Deserialize a tmux layout string into a LayoutCell tree.
///
/// The string must start with a 4-hex-digit checksum followed by a comma
/// (e.g. "a1b2,80x24,0,0{...}").  Pane IDs are assigned sequentially (0, 1, …)
/// in tree-traversal order.  Caller owns the returned root (call deinit on it).
pub fn deserialize(alloc: std.mem.Allocator, str: []const u8) !*LayoutCell {
    // Minimum: "XXXX," = 5 chars before the layout body.
    if (str.len < 5) return error.InvalidFormat;
    var parser = Parser.init(str[5..]);
    return parser.parseCell(alloc);
}

// --- Tests ---

test "serialize leaf cell" {
    const alloc = std.testing.allocator;
    const cell = try LayoutCell.initLeaf(alloc, 0, 80, 24, 0, 0);
    defer cell.deinit();

    const s = try serialize(alloc, cell);
    defer alloc.free(s);

    // Body after "XXXX," must be "80x24,0,0"
    try std.testing.expect(s.len >= 5);
    try std.testing.expectEqualStrings("80x24,0,0", s[5..]);
}

test "serialize horizontal split" {
    const alloc = std.testing.allocator;
    const root = try LayoutCell.initBranch(alloc, .horizontal, 80, 24, 0, 0);
    defer root.deinit();

    const left = try LayoutCell.initLeaf(alloc, 0, 39, 24, 0, 0);
    const right = try LayoutCell.initLeaf(alloc, 1, 40, 24, 40, 0);
    try root.addChild(left);
    try root.addChild(right);

    const s = try serialize(alloc, root);
    defer alloc.free(s);

    try std.testing.expectEqualStrings(
        "80x24,0,0{39x24,0,0,40x24,40,0}",
        s[5..],
    );
}

test "serialize vertical split" {
    const alloc = std.testing.allocator;
    const root = try LayoutCell.initBranch(alloc, .vertical, 80, 24, 0, 0);
    defer root.deinit();

    const top = try LayoutCell.initLeaf(alloc, 0, 80, 11, 0, 0);
    const bot = try LayoutCell.initLeaf(alloc, 1, 80, 12, 0, 12);
    try root.addChild(top);
    try root.addChild(bot);

    const s = try serialize(alloc, root);
    defer alloc.free(s);

    try std.testing.expectEqualStrings(
        "80x24,0,0[80x11,0,0,80x12,0,12]",
        s[5..],
    );
}

test "deserialize leaf" {
    const alloc = std.testing.allocator;
    const cell = try deserialize(alloc, "abcd,80x24,0,0");
    defer cell.deinit();

    try std.testing.expectEqual(CellType.pane, cell.cell_type);
    try std.testing.expectEqual(@as(u32, 80), cell.sx);
    try std.testing.expectEqual(@as(u32, 24), cell.sy);
    try std.testing.expectEqual(@as(u32, 0), cell.xoff);
    try std.testing.expectEqual(@as(u32, 0), cell.yoff);
    try std.testing.expectEqual(@as(?u32, 0), cell.pane_id);
}

test "deserialize horizontal split" {
    const alloc = std.testing.allocator;
    const cell = try deserialize(alloc, "abcd,80x24,0,0{39x24,0,0,40x24,40,0}");
    defer cell.deinit();

    try std.testing.expectEqual(CellType.horizontal, cell.cell_type);
    try std.testing.expectEqual(@as(u32, 80), cell.sx);
    try std.testing.expectEqual(@as(usize, 2), cell.children.items.len);

    const l = cell.children.items[0];
    const r = cell.children.items[1];
    try std.testing.expectEqual(@as(u32, 39), l.sx);
    try std.testing.expectEqual(@as(u32, 0), l.xoff);
    try std.testing.expectEqual(@as(u32, 40), r.sx);
    try std.testing.expectEqual(@as(u32, 40), r.xoff);
}

test "deserialize vertical split" {
    const alloc = std.testing.allocator;
    const cell = try deserialize(alloc, "abcd,80x24,0,0[80x11,0,0,80x12,0,12]");
    defer cell.deinit();

    try std.testing.expectEqual(CellType.vertical, cell.cell_type);
    try std.testing.expectEqual(@as(usize, 2), cell.children.items.len);
    try std.testing.expectEqual(@as(u32, 11), cell.children.items[0].sy);
    try std.testing.expectEqual(@as(u32, 12), cell.children.items[1].sy);
    try std.testing.expectEqual(@as(u32, 12), cell.children.items[1].yoff);
}

test "checksum is consistent" {
    const alloc = std.testing.allocator;
    const cell = try LayoutCell.initLeaf(alloc, 0, 80, 24, 5, 3);
    defer cell.deinit();

    // Serialize twice; checksums must be identical.
    const s1 = try serialize(alloc, cell);
    defer alloc.free(s1);
    const s2 = try serialize(alloc, cell);
    defer alloc.free(s2);

    try std.testing.expectEqualStrings(s1, s2);
    // First 4 bytes are hex checksum digits.
    try std.testing.expectEqualStrings(s1[0..4], s2[0..4]);
}

test "round-trip serialize/deserialize" {
    const alloc = std.testing.allocator;

    // Build: vertical root with two horizontal rows
    const root = try LayoutCell.initBranch(alloc, .vertical, 80, 24, 0, 0);
    defer root.deinit();

    const top_row = try LayoutCell.initBranch(alloc, .horizontal, 80, 11, 0, 0);
    try top_row.addChild(try LayoutCell.initLeaf(alloc, 0, 39, 11, 0, 0));
    try top_row.addChild(try LayoutCell.initLeaf(alloc, 1, 40, 11, 40, 0));
    try root.addChild(top_row);

    const bot_pane = try LayoutCell.initLeaf(alloc, 2, 80, 12, 0, 12);
    try root.addChild(bot_pane);

    const s = try serialize(alloc, root);
    defer alloc.free(s);

    const restored = try deserialize(alloc, s);
    defer restored.deinit();

    try std.testing.expectEqual(CellType.vertical, restored.cell_type);
    try std.testing.expectEqual(@as(u32, 80), restored.sx);
    try std.testing.expectEqual(@as(u32, 24), restored.sy);
    try std.testing.expectEqual(@as(usize, 2), restored.children.items.len);

    const r_top = restored.children.items[0];
    try std.testing.expectEqual(CellType.horizontal, r_top.cell_type);
    try std.testing.expectEqual(@as(usize, 2), r_top.children.items.len);
    try std.testing.expectEqual(@as(u32, 39), r_top.children.items[0].sx);
    try std.testing.expectEqual(@as(u32, 40), r_top.children.items[1].sx);

    const r_bot = restored.children.items[1];
    try std.testing.expectEqual(CellType.pane, r_bot.cell_type);
    try std.testing.expectEqual(@as(u32, 12), r_bot.sy);
    try std.testing.expectEqual(@as(u32, 12), r_bot.yoff);
}

test "deserialize invalid format" {
    try std.testing.expectError(error.InvalidFormat, deserialize(std.testing.allocator, "ab"));
    try std.testing.expectError(error.InvalidFormat, deserialize(std.testing.allocator, "abcd,bad"));
}
