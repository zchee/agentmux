const std = @import("std");
const layout_mod = @import("layout.zig");
const LayoutCell = layout_mod.LayoutCell;
const CellType = layout_mod.CellType;

/// Preset layout types matching tmux.
pub const LayoutPreset = enum {
    even_horizontal,
    even_vertical,
    main_horizontal,
    main_vertical,
    tiled,
};

/// Apply a preset layout to a set of panes.
pub fn applyPreset(
    alloc: std.mem.Allocator,
    preset: LayoutPreset,
    pane_ids: []const u32,
    sx: u32,
    sy: u32,
) !*LayoutCell {
    return switch (preset) {
        .even_horizontal => evenHorizontal(alloc, pane_ids, sx, sy),
        .even_vertical => evenVertical(alloc, pane_ids, sx, sy),
        .main_horizontal => mainHorizontal(alloc, pane_ids, sx, sy),
        .main_vertical => mainVertical(alloc, pane_ids, sx, sy),
        .tiled => tiled(alloc, pane_ids, sx, sy),
    };
}

/// Even horizontal: all panes side-by-side with equal width.
fn evenHorizontal(alloc: std.mem.Allocator, pane_ids: []const u32, sx: u32, sy: u32) !*LayoutCell {
    if (pane_ids.len <= 1) {
        return LayoutCell.initLeaf(alloc, if (pane_ids.len > 0) pane_ids[0] else 0, sx, sy, 0, 0);
    }

    const root = try LayoutCell.initBranch(alloc, .horizontal, sx, sy, 0, 0);
    const n: u32 = @intCast(pane_ids.len);
    const borders = n - 1;
    const available = if (sx > borders) sx - borders else n;
    var xoff: u32 = 0;

    for (pane_ids, 0..) |pid, i| {
        const is_last = i == pane_ids.len - 1;
        const w = if (is_last) sx - xoff else available / n;
        const child = try LayoutCell.initLeaf(alloc, pid, w, sy, xoff, 0);
        try root.addChild(child);
        xoff += w + 1; // +1 for border
    }
    return root;
}

/// Even vertical: all panes stacked with equal height.
fn evenVertical(alloc: std.mem.Allocator, pane_ids: []const u32, sx: u32, sy: u32) !*LayoutCell {
    if (pane_ids.len <= 1) {
        return LayoutCell.initLeaf(alloc, if (pane_ids.len > 0) pane_ids[0] else 0, sx, sy, 0, 0);
    }

    const root = try LayoutCell.initBranch(alloc, .vertical, sx, sy, 0, 0);
    const n: u32 = @intCast(pane_ids.len);
    const borders = n - 1;
    const available = if (sy > borders) sy - borders else n;
    var yoff: u32 = 0;

    for (pane_ids, 0..) |pid, i| {
        const is_last = i == pane_ids.len - 1;
        const h = if (is_last) sy - yoff else available / n;
        const child = try LayoutCell.initLeaf(alloc, pid, sx, h, 0, yoff);
        try root.addChild(child);
        yoff += h + 1;
    }
    return root;
}

/// Main horizontal: first pane takes full width on top, rest split below.
fn mainHorizontal(alloc: std.mem.Allocator, pane_ids: []const u32, sx: u32, sy: u32) !*LayoutCell {
    if (pane_ids.len <= 1) {
        return LayoutCell.initLeaf(alloc, if (pane_ids.len > 0) pane_ids[0] else 0, sx, sy, 0, 0);
    }

    const root = try LayoutCell.initBranch(alloc, .vertical, sx, sy, 0, 0);
    const main_height = sy * 2 / 3; // main pane gets 2/3
    const rest_height = sy - main_height - 1; // -1 for border

    // Main pane
    const main_pane = try LayoutCell.initLeaf(alloc, pane_ids[0], sx, main_height, 0, 0);
    try root.addChild(main_pane);

    // Rest of panes split horizontally below
    if (pane_ids.len == 2) {
        const child = try LayoutCell.initLeaf(alloc, pane_ids[1], sx, rest_height, 0, main_height + 1);
        try root.addChild(child);
    } else {
        const bottom = try LayoutCell.initBranch(alloc, .horizontal, sx, rest_height, 0, main_height + 1);
        const rest = pane_ids[1..];
        const n: u32 = @intCast(rest.len);
        const borders = n - 1;
        const available = if (sx > borders) sx - borders else n;
        var xoff: u32 = 0;

        for (rest, 0..) |pid, i| {
            const is_last = i == rest.len - 1;
            const w = if (is_last) sx - xoff else available / n;
            const child = try LayoutCell.initLeaf(alloc, pid, w, rest_height, xoff, main_height + 1);
            try bottom.addChild(child);
            xoff += w + 1;
        }
        try root.addChild(bottom);
    }
    return root;
}

/// Main vertical: first pane takes full height on left, rest split to the right.
fn mainVertical(alloc: std.mem.Allocator, pane_ids: []const u32, sx: u32, sy: u32) !*LayoutCell {
    if (pane_ids.len <= 1) {
        return LayoutCell.initLeaf(alloc, if (pane_ids.len > 0) pane_ids[0] else 0, sx, sy, 0, 0);
    }

    const root = try LayoutCell.initBranch(alloc, .horizontal, sx, sy, 0, 0);
    const main_width = sx * 2 / 3;
    const rest_width = sx - main_width - 1;

    const main_pane = try LayoutCell.initLeaf(alloc, pane_ids[0], main_width, sy, 0, 0);
    try root.addChild(main_pane);

    if (pane_ids.len == 2) {
        const child = try LayoutCell.initLeaf(alloc, pane_ids[1], rest_width, sy, main_width + 1, 0);
        try root.addChild(child);
    } else {
        const right = try LayoutCell.initBranch(alloc, .vertical, rest_width, sy, main_width + 1, 0);
        const rest = pane_ids[1..];
        const n: u32 = @intCast(rest.len);
        const borders = n - 1;
        const available = if (sy > borders) sy - borders else n;
        var yoff: u32 = 0;

        for (rest, 0..) |pid, i| {
            const is_last = i == rest.len - 1;
            const h = if (is_last) sy - yoff else available / n;
            const child = try LayoutCell.initLeaf(alloc, pid, rest_width, h, main_width + 1, yoff);
            try right.addChild(child);
            yoff += h + 1;
        }
        try root.addChild(right);
    }
    return root;
}

/// Tiled: arrange panes in a grid.
fn tiled(alloc: std.mem.Allocator, pane_ids: []const u32, sx: u32, sy: u32) !*LayoutCell {
    if (pane_ids.len <= 1) {
        return LayoutCell.initLeaf(alloc, if (pane_ids.len > 0) pane_ids[0] else 0, sx, sy, 0, 0);
    }
    // For 2-3 panes, use even_horizontal
    if (pane_ids.len <= 3) {
        return evenHorizontal(alloc, pane_ids, sx, sy);
    }
    // For 4+ panes, split into top and bottom rows
    const half = pane_ids.len / 2;
    const root = try LayoutCell.initBranch(alloc, .vertical, sx, sy, 0, 0);
    const top_height = sy / 2;
    const bottom_height = sy - top_height - 1;

    // Top row
    const top_panes = pane_ids[0..half];
    const top = try evenHorizontal(alloc, top_panes, sx, top_height);
    top.yoff = 0;
    try root.addChild(top);

    // Bottom row
    const bottom_panes = pane_ids[half..];
    const bottom = try evenHorizontal(alloc, bottom_panes, sx, bottom_height);
    bottom.yoff = top_height + 1;
    try root.addChild(bottom);

    return root;
}

test "even horizontal 3 panes" {
    const panes = [_]u32{ 0, 1, 2 };
    const root = try applyPreset(std.testing.allocator, .even_horizontal, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 3), root.countPanes());
    try std.testing.expect(root.findPane(0) != null);
    try std.testing.expect(root.findPane(1) != null);
    try std.testing.expect(root.findPane(2) != null);
}

test "even vertical 2 panes" {
    const panes = [_]u32{ 0, 1 };
    const root = try applyPreset(std.testing.allocator, .even_vertical, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 2), root.countPanes());
}

test "main horizontal 3 panes" {
    const panes = [_]u32{ 0, 1, 2 };
    const root = try applyPreset(std.testing.allocator, .main_horizontal, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 3), root.countPanes());
    // Main pane should be larger
    const main = root.findPane(0).?;
    try std.testing.expect(main.sy > 12);
}

test "main vertical 3 panes" {
    const panes = [_]u32{ 0, 1, 2 };
    const root = try applyPreset(std.testing.allocator, .main_vertical, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 3), root.countPanes());
    const main = root.findPane(0).?;
    try std.testing.expect(main.sx > 40);
}

test "tiled 4 panes" {
    const panes = [_]u32{ 0, 1, 2, 3 };
    const root = try applyPreset(std.testing.allocator, .tiled, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 4), root.countPanes());
}

test "single pane" {
    const panes = [_]u32{0};
    const root = try applyPreset(std.testing.allocator, .even_horizontal, &panes, 80, 24);
    defer root.deinit();
    try std.testing.expectEqual(@as(u32, 1), root.countPanes());
    try std.testing.expectEqual(@as(u32, 80), root.sx);
}
