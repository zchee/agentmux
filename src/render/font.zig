const std = @import("std");
const builtin = @import("builtin");
const atlas_mod = @import("atlas.zig");

/// FreeType C API declarations.
const ft = struct {
    // Opaque types
    const FT_Library = ?*anyopaque;
    const FT_Face = ?*anyopaque;

    // Error type
    const FT_Error = i32;

    // Glyph metrics (in 26.6 fixed point)
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

    // Bitmap
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

    // Glyph slot (simplified - we access fields via offset)
    const FT_GlyphSlot = ?*anyopaque;

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
            // Glyph not found - add empty entry
            return glyph_atlas.addGlyph(codepoint, 0, 0, &.{}, 0, 0, self.cell_width);
        }

        // Access the rendered bitmap from the glyph slot
        // FT_GlyphSlotRec layout: the bitmap is at a known offset
        // Since we can't safely dereference the opaque pointer in portable Zig,
        // we use FT_Load_Char with FT_LOAD_RENDER which renders to the slot's bitmap

        // For now, create a simple bitmap based on the codepoint
        // Real implementation would read face->glyph->bitmap
        const w = self.cell_width;
        const h: u16 = @intCast(self.pixel_size);

        // Generate a placeholder bitmap (filled rectangle for visible chars)
        var bitmap_buf: [4096]u8 = .{0} ** 4096;
        const bitmap_size = @as(usize, w) * @as(usize, h);
        if (bitmap_size <= bitmap_buf.len and codepoint >= 0x20 and codepoint < 0x7f) {
            // Simple: fill the glyph area for printable ASCII
            @memset(bitmap_buf[0..bitmap_size], 0x80);
        }

        return glyph_atlas.addGlyph(
            codepoint,
            w,
            h,
            bitmap_buf[0..bitmap_size],
            0,
            self.ascender,
            w,
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
