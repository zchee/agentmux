const std = @import("std");

/// Image source type.
pub const Source = enum {
    sixel,
    kitty,
    inline_data,
};

/// Placement of an image in a pane.
pub const Placement = struct {
    pane_id: u32,
    x: u32,
    y: u32,
    cols: u32,
    rows: u32,
};

/// A managed image.
pub const Image = struct {
    id: u32,
    width: u32,
    height: u32,
    pixels: []u8, // RGBA data
    placement: Placement,
    source: Source,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Image) void {
        self.allocator.free(self.pixels);
    }
};

/// Image lifecycle manager.
pub const ImageManager = struct {
    images: std.AutoHashMap(u32, Image),
    next_id: u32,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) ImageManager {
        return .{
            .images = std.AutoHashMap(u32, Image).init(alloc),
            .next_id = 1,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *ImageManager) void {
        var iter = self.images.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.allocator.free(entry.value_ptr.pixels);
        }
        self.images.deinit();
    }

    /// Add an image. Takes ownership of pixels.
    pub fn addImage(self: *ImageManager, width: u32, height: u32, pixels: []u8, source: Source, placement: Placement) !u32 {
        const id = self.next_id;
        self.next_id += 1;
        try self.images.put(id, .{
            .id = id,
            .width = width,
            .height = height,
            .pixels = pixels,
            .placement = placement,
            .source = source,
            .allocator = self.allocator,
        });
        return id;
    }

    /// Remove an image by ID.
    pub fn removeImage(self: *ImageManager, id: u32) void {
        if (self.images.fetchRemove(id)) |entry| {
            var img = entry.value;
            img.deinit();
        }
    }

    /// Get an image by ID.
    pub fn getImage(self: *const ImageManager, id: u32) ?*const Image {
        return if (self.images.getPtr(id)) |ptr| ptr else null;
    }

    /// Count images.
    pub fn count(self: *const ImageManager) usize {
        return self.images.count();
    }

    /// Remove all images for a pane.
    pub fn clearPane(self: *ImageManager, pane_id: u32) void {
        var to_remove: [64]u32 = undefined;
        var remove_count: usize = 0;

        var iter = self.images.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.placement.pane_id == pane_id and remove_count < to_remove.len) {
                to_remove[remove_count] = entry.key_ptr.*;
                remove_count += 1;
            }
        }

        for (to_remove[0..remove_count]) |id| {
            self.removeImage(id);
        }
    }

    /// Clear all images.
    pub fn clear(self: *ImageManager) void {
        var iter = self.images.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.allocator.free(entry.value_ptr.pixels);
        }
        self.images.clearAndFree();
        self.next_id = 1;
    }
};

test "image manager add and get" {
    const alloc = std.testing.allocator;
    var mgr = ImageManager.init(alloc);
    defer mgr.deinit();

    const pixels = try alloc.alloc(u8, 4 * 10 * 10); // 10x10 RGBA
    @memset(pixels, 0xFF);

    const id = try mgr.addImage(10, 10, pixels, .sixel, .{
        .pane_id = 0,
        .x = 0,
        .y = 0,
        .cols = 5,
        .rows = 5,
    });

    try std.testing.expectEqual(@as(usize, 1), mgr.count());
    const img = mgr.getImage(id).?;
    try std.testing.expectEqual(@as(u32, 10), img.width);
    try std.testing.expectEqual(@as(u32, 10), img.height);
}

test "image manager remove" {
    const alloc = std.testing.allocator;
    var mgr = ImageManager.init(alloc);
    defer mgr.deinit();

    const pixels = try alloc.alloc(u8, 16);
    @memset(pixels, 0);
    const id = try mgr.addImage(2, 2, pixels, .kitty, .{ .pane_id = 0, .x = 0, .y = 0, .cols = 1, .rows = 1 });

    mgr.removeImage(id);
    try std.testing.expectEqual(@as(usize, 0), mgr.count());
    try std.testing.expect(mgr.getImage(id) == null);
}
