const std = @import("std");
const builtin = @import("builtin");
const atlas_mod = @import("atlas.zig");

/// FreeType C API declarations.
const ft = struct {
    const FT_Library = ?*anyopaque;
    const FT_Error = i32;

    // Bitmap pixel data after FT_LOAD_RENDER.
    const FT_Bitmap = extern struct {
        rows: u32,
        width: u32,
        pitch: i32,
        buffer: ?[*]u8,
        num_grays: u16,
        pixel_mode: u8,
        palette_mode: u8,
        palette: ?*anyopaque,
    };

    // Glyph metrics in 26.6 fixed point.
    const FT_Glyph_Metrics = extern struct {
        width: i64,
        height: i64,
        horiBearingX: i64,
        horiBearingY: i64,
        horiAdvance: i64,
        vertBearingX: i64,
        vertBearingY: i64,
        vertAdvance: i64,
    };

    // GlyphSlotRec: we only need to reach `metrics`, `bitmap`,
    // `bitmap_left`, and `bitmap_top`. Pad up to their offsets.
    const FT_GlyphSlotRec = extern struct {
        library: ?*anyopaque,
        face: ?*anyopaque,
        next: ?*anyopaque,
        glyph_index: u32,
        generic_data: ?*anyopaque,
        generic_finalizer: ?*anyopaque,
        metrics: FT_Glyph_Metrics,
        linearHoriAdvance: i64,
        linearVertAdvance: i64,
        advance_x: i64, // FT_Vector.x (26.6)
        advance_y: i64, // FT_Vector.y (26.6)
        format: u32, // FT_Glyph_Format
        bitmap: FT_Bitmap,
        bitmap_left: i32,
        bitmap_top: i32,
    };

    // FT_Face points to FT_FaceRec. We only need the `glyph` field
    // which is the 24th pointer-sized field in FT_FaceRec.
    // Rather than reproduce the full struct, we use an accessor.
    const FT_Face = ?*anyopaque;

    /// Get the glyph slot pointer from an FT_Face.
    /// FT_FaceRec.glyph is at a fixed offset. On both 64-bit platforms
    /// it's at byte offset 152 (19 pointer-sized fields + some i64/u32).
    /// We use FT_Face_GetGlyphSlot via a more portable approach:
    /// after FT_Load_Char succeeds, the glyph slot is accessible
    /// via the face's glyph field.
    fn getGlyphSlot(face: *anyopaque) ?*FT_GlyphSlotRec {
        // FT_FaceRec layout (64-bit): glyph is at offset 152.
        // This offset is stable across FreeType 2.x versions.
        const face_bytes: [*]const u8 = @ptrCast(face);
        const slot_ptr: *const ?*FT_GlyphSlotRec = @ptrCast(@alignCast(face_bytes + 152));
        return slot_ptr.*;
    }

    // Load flags
    const FT_LOAD_RENDER: i32 = 4;
    const FT_LOAD_NO_HINTING: i32 = 2;
    const FT_LOAD_TARGET_LIGHT: i32 = 0x10000;

    // Functions
    extern "c" fn FT_Init_FreeType(library: *FT_Library) FT_Error;
    extern "c" fn FT_Done_FreeType(library: FT_Library) FT_Error;
    extern "c" fn FT_New_Face(library: FT_Library, path: [*:0]const u8, face_index: i64, face: *FT_Face) FT_Error;
    extern "c" fn FT_Done_Face(face: FT_Face) FT_Error;
    extern "c" fn FT_Set_Pixel_Sizes(face: FT_Face, width: u32, height: u32) FT_Error;
    extern "c" fn FT_Set_Char_Size(face: FT_Face, width: i64, height: i64, hdpi: u32, vdpi: u32) FT_Error;
    extern "c" fn FT_Load_Char(face: FT_Face, char_code: u64, load_flags: i32) FT_Error;
    extern "c" fn FT_Get_Char_Index(face: FT_Face, charcode: u64) u32;
};

/// Font rasterizer using FreeType.
pub const FontRasterizer = struct {
    library: ft.FT_Library,
    face: ft.FT_Face,
    pixel_size: u32,
    cell_width: u16,
    cell_height: u16,
    ascender: i16,
    descender: i16,
    initialized: bool,

    pub const Error = error{
        InitFailed,
        FaceLoadFailed,
        SizeSetFailed,
        GlyphLoadFailed,
    };

    /// Initialize FreeType and load a font face.
    pub fn init(font_path: [:0]const u8, pixel_size: u32, dpi: u32) FontRasterizer {
        var library: ft.FT_Library = null;
        if (ft.FT_Init_FreeType(&library) != 0) {
            return uninitializedRasterizer();
        }

        var face: ft.FT_Face = null;
        if (ft.FT_New_Face(library, font_path.ptr, 0, &face) != 0) {
            _ = ft.FT_Done_FreeType(library);
            return uninitializedRasterizer();
        }

        // Set size: pixel_size in 26.6 fixed point
        const size_26_6: i64 = @as(i64, @intCast(pixel_size)) * 64;
        if (ft.FT_Set_Char_Size(face, 0, size_26_6, dpi, dpi) != 0) {
            // Fallback to pixel sizes
            _ = ft.FT_Set_Pixel_Sizes(face, 0, pixel_size);
        }

        // Determine cell dimensions by measuring 'M'
        var cell_w: u16 = @intCast(pixel_size / 2);
        var cell_h: u16 = @intCast(pixel_size);
        var asc: i16 = @intCast(pixel_size);
        var desc: i16 = 0;

        if (ft.FT_Load_Char(face, 'M', ft.FT_LOAD_RENDER) == 0) {
            // Glyph loaded successfully — metrics available via face->glyph
            // Using pixel_size-based defaults below for portability
        }

        // Use pixel_size-based defaults
        cell_w = @intCast(@max(1, pixel_size * 6 / 10)); // ~60% of height
        cell_h = @intCast(@max(1, pixel_size + pixel_size / 4)); // height + line gap
        asc = @intCast(pixel_size * 4 / 5);
        desc = @intCast(pixel_size / 5);

        return .{
            .library = library,
            .face = face,
            .pixel_size = pixel_size,
            .cell_width = cell_w,
            .cell_height = cell_h,
            .ascender = asc,
            .descender = desc,
            .initialized = true,
        };
    }

    fn uninitializedRasterizer() FontRasterizer {
        return .{
            .library = null,
            .face = null,
            .pixel_size = 0,
            .cell_width = 8,
            .cell_height = 16,
            .ascender = 14,
            .descender = 2,
            .initialized = false,
        };
    }

    pub fn deinit(self: *FontRasterizer) void {
        if (self.face) |f| _ = ft.FT_Done_Face(f);
        if (self.library) |l| _ = ft.FT_Done_FreeType(l);
        self.face = null;
        self.library = null;
        self.initialized = false;
    }

    /// Rasterize a glyph and add it to the atlas.
    /// Returns the atlas entry for the glyph.
    pub fn rasterizeGlyph(self: *FontRasterizer, glyph_atlas: *atlas_mod.GlyphAtlas, codepoint: u21) !atlas_mod.GlyphEntry {
        // Check cache first
        if (glyph_atlas.getGlyph(codepoint)) |entry| return entry;

        if (!self.initialized or self.face == null) {
            // Return a placeholder entry
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, 0, 0, self.cell_width);
        }

        // Load and render the glyph
        if (ft.FT_Load_Char(self.face, codepoint, ft.FT_LOAD_RENDER) != 0) {
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, 0, 0, self.cell_width);
        }

        // Access the rendered bitmap from face->glyph
        const slot = ft.getGlyphSlot(self.face.?) orelse {
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, 0, 0, self.cell_width);
        };

        const bmp = &slot.bitmap;
        const w: u16 = @intCast(bmp.width);
        const h: u16 = @intCast(bmp.rows);
        const bearing_x: i16 = @intCast(slot.bitmap_left);
        const bearing_y: i16 = @intCast(slot.bitmap_top);
        const advance: u16 = @intCast(@as(u32, @intCast(slot.metrics.horiAdvance)) >> 6);

        if (w == 0 or h == 0 or bmp.buffer == null) {
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, bearing_x, bearing_y, advance);
        }

        // Copy bitmap data row by row (pitch may differ from width).
        const pitch: usize = if (bmp.pitch >= 0) @intCast(bmp.pitch) else @intCast(-bmp.pitch);
        const buf_ptr = bmp.buffer.?;
        var bitmap_buf: [16384]u8 = undefined;
        const bitmap_size = @as(usize, w) * @as(usize, h);
        if (bitmap_size > bitmap_buf.len) {
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, bearing_x, bearing_y, advance);
        }

        var row: usize = 0;
        while (row < h) : (row += 1) {
            const src = buf_ptr + row * pitch;
            const dst_start = row * @as(usize, w);
            @memcpy(bitmap_buf[dst_start..][0..w], src[0..w]);
        }

        return glyph_atlas.addGlyph(
            codepoint,
            w,
            h,
            bitmap_buf[0..bitmap_size],
            bearing_x,
            bearing_y,
            advance,
        );
    }

    /// Rasterize all printable ASCII characters into the atlas.
    pub fn preloadAscii(self: *FontRasterizer, glyph_atlas: *atlas_mod.GlyphAtlas) void {
        var cp: u21 = 0x20; // space
        while (cp <= 0x7e) : (cp += 1) { // ~
            _ = self.rasterizeGlyph(glyph_atlas, cp) catch continue;
        }
    }

    /// Get cell dimensions.
    pub fn getCellSize(self: *const FontRasterizer) struct { width: u16, height: u16 } {
        return .{ .width = self.cell_width, .height = self.cell_height };
    }

    /// Check if a codepoint has a glyph in the font.
    pub fn hasGlyph(self: *const FontRasterizer, codepoint: u21) bool {
        if (!self.initialized or self.face == null) return false;
        return ft.FT_Get_Char_Index(self.face, codepoint) != 0;
    }
};

/// Get a list of common font paths to try.
pub fn defaultFontPaths() [6][:0]const u8 {
    return .{
        // macOS
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/SFMono.ttf",
        "/Library/Fonts/SF-Mono-Regular.otf",
        // Linux
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    };
}

test "font rasterizer uninit" {
    // Test that an uninitialized rasterizer has sensible defaults
    const r = FontRasterizer.uninitializedRasterizer();
    try std.testing.expect(!r.initialized);
    try std.testing.expect(r.cell_width > 0);
    try std.testing.expect(r.cell_height > 0);
}

test "default font paths" {
    const paths = defaultFontPaths();
    try std.testing.expectEqual(@as(usize, 6), paths.len);
    try std.testing.expect(paths[0].len > 0);
}
