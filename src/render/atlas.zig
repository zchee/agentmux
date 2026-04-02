const std = @import("std");

/// A glyph entry in the atlas.
pub const GlyphEntry = struct {
    /// Position in the atlas texture.
    atlas_x: u16,
    atlas_y: u16,
    /// Glyph dimensions in pixels.
    width: u16,
    height: u16,
    /// Bearing (offset from baseline).
    bearing_x: i16,
    bearing_y: i16,
    /// Advance width.
    advance: u16,
};

/// Glyph atlas for caching rasterized font glyphs.
pub const GlyphAtlas = struct {
    /// Atlas texture data (single channel, alpha).
    texture: []u8,
    atlas_size: u32,
    /// Cached glyph entries.
    glyphs: std.AutoHashMap(u21, GlyphEntry),
    /// Current packing position.
    cursor_x: u16,
    cursor_y: u16,
    row_height: u16,
    allocator: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, atlas_size: u32) !GlyphAtlas {
        const texture = try alloc.alloc(u8, atlas_size * atlas_size);
        @memset(texture, 0);
        return .{
            .texture = texture,
            .atlas_size = atlas_size,
            .glyphs = std.AutoHashMap(u21, GlyphEntry).init(alloc),
            .cursor_x = 0,
            .cursor_y = 0,
            .row_height = 0,
            .allocator = alloc,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.allocator.free(self.texture);
        self.glyphs.deinit();
    }

    /// Get a cached glyph, or null if not yet rasterized.
    pub fn getGlyph(self: *const GlyphAtlas, codepoint: u21) ?GlyphEntry {
        return self.glyphs.get(codepoint);
    }

    /// Add a pre-rasterized glyph to the atlas.
    /// Returns the atlas entry, or error if atlas is full.
    pub fn addGlyph(self: *GlyphAtlas, codepoint: u21, width: u16, height: u16, bitmap: []const u8, bearing_x: i16, bearing_y: i16, advance: u16) !GlyphEntry {
        // Check if we need to wrap to next row
        if (self.cursor_x + width > self.atlas_size) {
            self.cursor_x = 0;
            self.cursor_y += self.row_height;
            self.row_height = 0;
        }

        // Check if atlas is full
        if (self.cursor_y + height > self.atlas_size) {
            return error.AtlasFull;
        }

        // Copy bitmap into atlas texture
        var y: u16 = 0;
        while (y < height) : (y += 1) {
            const src_offset = @as(usize, y) * @as(usize, width);
            const dst_offset = @as(usize, self.cursor_y + y) * @as(usize, @intCast(self.atlas_size)) + @as(usize, self.cursor_x);
            if (src_offset + width <= bitmap.len and dst_offset + width <= self.texture.len) {
                @memcpy(self.texture[dst_offset..][0..width], bitmap[src_offset..][0..width]);
            }
        }

        const entry = GlyphEntry{
            .atlas_x = self.cursor_x,
            .atlas_y = self.cursor_y,
            .width = width,
            .height = height,
            .bearing_x = bearing_x,
            .bearing_y = bearing_y,
            .advance = advance,
        };

        try self.glyphs.put(codepoint, entry);

        self.cursor_x += width + 1; // +1 padding
        self.row_height = @max(self.row_height, height);

        return entry;
    }

    /// Clear all cached glyphs.
    pub fn clear(self: *GlyphAtlas) void {
        self.glyphs.clearAndFree();
        @memset(self.texture, 0);
        self.cursor_x = 0;
        self.cursor_y = 0;
        self.row_height = 0;
    }

    /// Number of cached glyphs.
    pub fn count(self: *const GlyphAtlas) usize {
        return self.glyphs.count();
    }
};

test "atlas init and add glyph" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 256);
    defer atlas.deinit();

    try std.testing.expectEqual(@as(usize, 0), atlas.count());

    // Add a fake 8x16 glyph
    const bitmap = [_]u8{0xFF} ** (8 * 16);
    const entry = try atlas.addGlyph('A', 8, 16, &bitmap, 0, 14, 8);
    try std.testing.expectEqual(@as(u16, 0), entry.atlas_x);
    try std.testing.expectEqual(@as(u16, 0), entry.atlas_y);
    try std.testing.expectEqual(@as(usize, 1), atlas.count());

    // Retrieve it
    const got = atlas.getGlyph('A').?;
    try std.testing.expectEqual(@as(u16, 8), got.width);
    try std.testing.expectEqual(@as(u16, 16), got.height);
}

test "atlas row wrapping" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, 32);
    defer atlas.deinit();

    const bitmap = [_]u8{0xFF} ** (12 * 12);
    // Add 3 glyphs: 12px each + 1px padding = 13px, 2*13=26, 3rd at 26+12=38 > 32, wraps
    _ = try atlas.addGlyph('A', 12, 12, &bitmap, 0, 10, 12);
    _ = try atlas.addGlyph('B', 12, 12, &bitmap, 0, 10, 12);
    const c = try atlas.addGlyph('C', 12, 12, &bitmap, 0, 10, 12);
    // C should be on the next row
    try std.testing.expectEqual(@as(u16, 0), c.atlas_x);
    try std.testing.expect(c.atlas_y > 0);
}
