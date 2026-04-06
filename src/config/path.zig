const std = @import("std");

/// Expand a leading `~/` against the current HOME environment variable.
/// Returns an owned slice regardless of whether expansion occurred.
pub fn expandHomePath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len < 2 or path[0] != '~' or path[1] != '/') {
        return alloc.dupe(u8, path);
    }

    const home = std.c.getenv("HOME") orelse return alloc.dupe(u8, path);
    const home_slice = std.mem.sliceTo(home, 0);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ home_slice, path[1..] });
}

test "expandHomePath leaves absolute path unchanged" {
    const expanded = try expandHomePath(std.testing.allocator, "/tmp/example.conf");
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("/tmp/example.conf", expanded);
}

test "expandHomePath leaves non-home tilde path unchanged" {
    const expanded = try expandHomePath(std.testing.allocator, "~otheruser/.tmux.conf");
    defer std.testing.allocator.free(expanded);

    try std.testing.expectEqualStrings("~otheruser/.tmux.conf", expanded);
}
