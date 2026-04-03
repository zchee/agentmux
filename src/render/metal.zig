const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("renderer.zig");
const grid = @import("../screen/grid.zig");
const colour = @import("../core/colour.zig");

/// Metal GPU renderer for macOS.
/// Uses Objective-C runtime via extern C functions.
pub const MetalRenderer = if (builtin.os.tag == .macos) struct {
    device: ?*anyopaque, // id<MTLDevice>
    command_queue: ?*anyopaque, // id<MTLCommandQueue>
    pipeline_state: ?*anyopaque, // id<MTLRenderPipelineState>
    layer: ?*anyopaque, // CAMetalLayer
    width: u32,
    height: u32,
    config: renderer.RenderConfig,

    const objc = struct {
        // Objective-C runtime
        extern "c" fn objc_msgSend() void;
        extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
        extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
        // Metal
        extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
    };

    pub fn init(config: renderer.RenderConfig) MetalRenderer {
        const device = objc.MTLCreateSystemDefaultDevice();
        return .{
            .device = device,
            .command_queue = null, // Created via objc_msgSend
            .pipeline_state = null,
            .layer = null,
            .width = 0,
            .height = 0,
            .config = config,
        };
    }

    pub fn deinit(self: *MetalRenderer) void {
        // Release Metal objects via objc_msgSend
        self.device = null;
        self.command_queue = null;
        self.pipeline_state = null;
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        // Update CAMetalLayer drawable size
    }

    pub fn beginFrame(_: *MetalRenderer) void {
        // Get next drawable from CAMetalLayer
        // Create command buffer
    }

    pub fn endFrame(_: *MetalRenderer) void {
        // End render encoding
    }

    pub fn drawCell(_: *MetalRenderer, _: u32, _: u32, _: *const grid.Cell) void {
        // Add vertex data for cell quad:
        // - Background rect with bg color
        // - Glyph texture quad with fg color
    }

    pub fn drawRect(_: *MetalRenderer, _: u32, _: u32, _: u32, _: u32, _: colour.Colour) void {
        // Add colored rect vertices
    }

    pub fn drawImage(_: *MetalRenderer, _: u32, _: u32, _: u32, _: u32, _: []const u8) void {
        // Upload image to texture and draw quad
    }

    pub fn present(_: *MetalRenderer) void {
        // Commit command buffer, present drawable
    }

    pub fn getCellSize(self: *MetalRenderer) renderer.Renderer.CellSize {
        return .{
            .width = if (self.config.cell_width > 0) self.config.cell_width else 8,
            .height = if (self.config.cell_height > 0) self.config.cell_height else 16,
        };
    }

    /// Create a Renderer interface from this MetalRenderer.
    pub fn asRenderer(self: *MetalRenderer) renderer.Renderer {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = renderer.Renderer.VTable{
        .deinit = @ptrCast(&deinitVt),
        .resize = @ptrCast(&resizeVt),
        .beginFrame = @ptrCast(&beginFrameVt),
        .endFrame = @ptrCast(&endFrameVt),
        .drawCell = @ptrCast(&drawCellVt),
        .drawRect = @ptrCast(&drawRectVt),
        .drawImage = @ptrCast(&drawImageVt),
        .present = @ptrCast(&presentVt),
        .getCellSize = @ptrCast(&getCellSizeVt),
    };

    fn deinitVt(self: *MetalRenderer) void {
        self.deinit();
    }
    fn resizeVt(self: *MetalRenderer, w: u32, h: u32) void {
        self.resize(w, h);
    }
    fn beginFrameVt(self: *MetalRenderer) void {
        self.beginFrame();
    }
    fn endFrameVt(self: *MetalRenderer) void {
        self.endFrame();
    }
    fn drawCellVt(self: *MetalRenderer, x: u32, y: u32, cell: *const grid.Cell) void {
        self.drawCell(x, y, cell);
    }
    fn drawRectVt(self: *MetalRenderer, x: u32, y: u32, w: u32, h: u32, c: colour.Colour) void {
        self.drawRect(x, y, w, h, c);
    }
    fn drawImageVt(self: *MetalRenderer, x: u32, y: u32, w: u32, h: u32, px: []const u8) void {
        self.drawImage(x, y, w, h, px);
    }
    fn presentVt(self: *MetalRenderer) void {
        self.present();
    }
    fn getCellSizeVt(self: *MetalRenderer) renderer.Renderer.CellSize {
        return self.getCellSize();
    }
} else void;
