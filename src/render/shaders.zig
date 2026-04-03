const std = @import("std");
const builtin = @import("builtin");

/// Metal shader source embedded at compile time.
/// On non-macOS, this is an empty struct.
pub const MetalShaders = if (builtin.os.tag == .macos) struct {
    /// Embedded MSL shader source.
    pub const source = @embedFile("shaders/terminal.metal");

    /// Vertex function names.
    pub const vertex_main = "vertex_main";
    pub const vertex_fullscreen = "vertex_fullscreen";

    /// Fragment function names.
    pub const fragment_background = "fragment_background";
    pub const fragment_glyph = "fragment_glyph";
    pub const fragment_cell = "fragment_cell";
    pub const fragment_cursor = "fragment_cursor";
    pub const fragment_selection = "fragment_selection";
    pub const fragment_image = "fragment_image";

    /// Vertex attribute indices (must match VertexIn in MSL).
    pub const attr_position = 0;
    pub const attr_texcoord = 1;
    pub const attr_fg_color = 2;
    pub const attr_bg_color = 3;
    pub const attr_is_glyph = 4;

    /// Buffer indices.
    pub const buffer_vertices = 0;
    pub const buffer_uniforms = 1;

    /// Texture indices.
    pub const texture_atlas = 0;

    /// Vertex data layout for a cell quad.
    pub const CellVertex = extern struct {
        position: [2]f32,
        tex_coord: [2]f32,
        fg_color: [4]f32,
        bg_color: [4]f32,
        is_glyph: f32,
    };

    /// Uniform buffer layout (must match Uniforms in MSL).
    pub const Uniforms = extern struct {
        projection_matrix: [4][4]f32,
        viewport_size: [2]f32,
        cell_size: [2]f32,
        time: f32,
        _padding: [3]f32 = .{ 0, 0, 0 },
    };

    /// Build an orthographic projection matrix for 2D rendering.
    pub fn orthoProjection(width: f32, height: f32) [4][4]f32 {
        // Maps (0,0)-(width,height) to (-1,-1)-(1,1) clip space
        return .{
            .{ 2.0 / width, 0, 0, 0 },
            .{ 0, -2.0 / height, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ -1, 1, 0, 1 },
        };
    }

    /// Generate 6 vertices (2 triangles) for a cell quad.
    pub fn cellQuad(
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        tex_x: f32,
        tex_y: f32,
        tex_w: f32,
        tex_h: f32,
        fg: [4]f32,
        bg: [4]f32,
        is_glyph: bool,
    ) [6]CellVertex {
        const g: f32 = if (is_glyph) 1.0 else 0.0;
        return .{
            // Triangle 1
            .{ .position = .{ x, y }, .tex_coord = .{ tex_x, tex_y }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
            .{ .position = .{ x + w, y }, .tex_coord = .{ tex_x + tex_w, tex_y }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
            .{ .position = .{ x, y + h }, .tex_coord = .{ tex_x, tex_y + tex_h }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
            // Triangle 2
            .{ .position = .{ x + w, y }, .tex_coord = .{ tex_x + tex_w, tex_y }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
            .{ .position = .{ x + w, y + h }, .tex_coord = .{ tex_x + tex_w, tex_y + tex_h }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
            .{ .position = .{ x, y + h }, .tex_coord = .{ tex_x, tex_y + tex_h }, .fg_color = fg, .bg_color = bg, .is_glyph = g },
        };
    }

    /// Convert a colour palette index to RGBA float.
    pub fn paletteToRgba(idx: u8) [4]f32 {
        // Standard 16-color palette
        const palette = [16][3]f32{
            .{ 0, 0, 0 }, // black
            .{ 0.8, 0, 0 }, // red
            .{ 0, 0.8, 0 }, // green
            .{ 0.8, 0.8, 0 }, // yellow
            .{ 0, 0, 0.8 }, // blue
            .{ 0.8, 0, 0.8 }, // magenta
            .{ 0, 0.8, 0.8 }, // cyan
            .{ 0.75, 0.75, 0.75 }, // white
            .{ 0.5, 0.5, 0.5 }, // bright black
            .{ 1, 0, 0 }, // bright red
            .{ 0, 1, 0 }, // bright green
            .{ 1, 1, 0 }, // bright yellow
            .{ 0, 0, 1 }, // bright blue
            .{ 1, 0, 1 }, // bright magenta
            .{ 0, 1, 1 }, // bright cyan
            .{ 1, 1, 1 }, // bright white
        };

        if (idx < 16) {
            return .{ palette[idx][0], palette[idx][1], palette[idx][2], 1.0 };
        }

        if (idx < 232) {
            // 216-color cube: 6x6x6
            const ci = idx - 16;
            const r: f32 = @as(f32, @floatFromInt(ci / 36)) / 5.0;
            const g: f32 = @as(f32, @floatFromInt((ci / 6) % 6)) / 5.0;
            const b: f32 = @as(f32, @floatFromInt(ci % 6)) / 5.0;
            return .{ r, g, b, 1.0 };
        }

        // Grayscale ramp: 24 shades
        const gray: f32 = (@as(f32, @floatFromInt(idx - 232)) * 10.0 + 8.0) / 255.0;
        return .{ gray, gray, gray, 1.0 };
    }
} else struct {
    // Non-macOS stub
    pub const source = "";
};

test "ortho projection" {
    if (builtin.os.tag != .macos) return;
    const proj = MetalShaders.orthoProjection(800, 600);
    // Top-left corner should map to (-1, 1)
    try std.testing.expect(proj[0][0] != 0);
    try std.testing.expect(proj[1][1] != 0);
}

test "cell quad vertices" {
    if (builtin.os.tag != .macos) return;
    const quad = MetalShaders.cellQuad(
        0,
        0,
        8,
        16,
        0,
        0,
        0.1,
        0.1,
        .{ 1, 1, 1, 1 },
        .{ 0, 0, 0, 1 },
        true,
    );
    try std.testing.expectEqual(@as(usize, 6), quad.len);
    try std.testing.expectEqual(@as(f32, 1.0), quad[0].is_glyph);
}

test "palette to rgba" {
    if (builtin.os.tag != .macos) return;
    const black = MetalShaders.paletteToRgba(0);
    try std.testing.expectEqual(@as(f32, 0), black[0]);
    try std.testing.expectEqual(@as(f32, 1.0), black[3]);

    const white = MetalShaders.paletteToRgba(15);
    try std.testing.expectEqual(@as(f32, 1.0), white[0]);
}
