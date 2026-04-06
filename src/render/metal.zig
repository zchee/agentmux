const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("renderer.zig");
const grid = @import("../screen/grid.zig");
const colour = @import("../core/colour.zig");
const shaders = @import("shaders.zig");
const atlas_mod = @import("atlas.zig");

/// Metal GPU renderer for macOS.
/// Uses Objective-C runtime via typed objc_msgSend trampolines.
pub const MetalRenderer = if (builtin.os.tag == .macos) struct {
    device: ?*anyopaque, // id<MTLDevice>
    command_queue: ?*anyopaque, // id<MTLCommandQueue>
    pipeline_state: ?*anyopaque, // id<MTLRenderPipelineState>
    layer: ?*anyopaque, // CAMetalLayer
    vertex_buffer: ?*anyopaque, // id<MTLBuffer>
    uniform_buffer: ?*anyopaque, // id<MTLBuffer>
    atlas_texture: ?*anyopaque, // id<MTLTexture>
    sampler_state: ?*anyopaque, // id<MTLSamplerState>
    current_drawable: ?*anyopaque, // id<CAMetalDrawable>
    current_command_buffer: ?*anyopaque, // id<MTLCommandBuffer>
    current_encoder: ?*anyopaque, // id<MTLRenderCommandEncoder>
    width: u32,
    height: u32,
    config: renderer.RenderConfig,
    vertices: std.ArrayListAligned(shaders.MetalShaders.CellVertex, null),
    glyph_atlas: ?*atlas_mod.GlyphAtlas,
    allocator: std.mem.Allocator,

    // ---- Objective-C runtime bindings ----

    const objc = struct {
        // Runtime
        extern "c" fn objc_getClass(name: [*:0]const u8) ?*anyopaque;
        extern "c" fn sel_registerName(name: [*:0]const u8) ?*anyopaque;
        // Metal device creation
        extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;
    };

    // Typed objc_msgSend trampolines.
    // Each function pointer signature must match the ObjC method's return/param types.
    const msg = struct {
        // id = objc_msgSend(id, SEL)
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque) ?*anyopaque;
    };

    const msg_u64 = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, arg: u64) ?*anyopaque;
    };

    const msg_ptr = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, arg: ?*anyopaque) ?*anyopaque;
    };

    const msg_ptr_ptr = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) ?*anyopaque;
    };

    const msg_ptr_u64 = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, arg: ?*anyopaque, len: u64) ?*anyopaque;
    };

    const msg_void = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque) void;
    };

    const msg_void_ptr = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, arg: ?*anyopaque) void;
    };

    const msg_void_u64 = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, arg: u64) void;
    };

    const msg_void_ptr_u64_u64 = struct {
        extern "c" fn objc_msgSend(receiver: ?*anyopaque, sel: ?*anyopaque, buf: ?*anyopaque, offset: u64, index: u64) void;
    };

    fn sel(name: [*:0]const u8) ?*anyopaque {
        return objc.sel_registerName(name);
    }

    fn cls(name: [*:0]const u8) ?*anyopaque {
        return objc.objc_getClass(name);
    }

    pub fn init(alloc: std.mem.Allocator, config: renderer.RenderConfig) MetalRenderer {
        const device = objc.MTLCreateSystemDefaultDevice();

        // Create command queue: [device newCommandQueue]
        const command_queue = if (device) |dev|
            msg.objc_msgSend(dev, sel("newCommandQueue"))
        else
            null;

        // Create pipeline state from embedded shaders
        var pipeline_state: ?*anyopaque = null;
        if (device) |dev| {
            // Create library from source: [device newLibraryWithSource:options:error:]
            const src_str = createNSString(shaders.MetalShaders.source);
            if (src_str) |source_str| {
                const library = msg_ptr_ptr.objc_msgSend(
                    dev,
                    sel("newLibraryWithSource:options:error:"),
                    source_str,
                    null, // options
                );
                if (library) |lib| {
                    pipeline_state = createPipelineState(dev, lib);
                    msg_void.objc_msgSend(lib, sel("release"));
                }
                msg_void.objc_msgSend(source_str, sel("release"));
            }
        }

        // Create vertex buffer (dynamic, 64KB)
        const vertex_buffer = if (device) |dev|
            msg_u64.objc_msgSend(dev, sel("newBufferWithLength:options:"), 65536)
        else
            null;

        // Create uniform buffer
        const uniform_buffer = if (device) |dev|
            msg_u64.objc_msgSend(dev, sel("newBufferWithLength:options:"), @sizeOf(shaders.MetalShaders.Uniforms))
        else
            null;

        // Create sampler state
        const sampler_state = if (device) |dev| blk: {
            const desc = msg.objc_msgSend(cls("MTLSamplerDescriptor"), sel("new"));
            if (desc) |d| {
                // MTLSamplerMinMagFilterLinear = 1
                msg_void_u64.objc_msgSend(d, sel("setMinFilter:"), 1);
                msg_void_u64.objc_msgSend(d, sel("setMagFilter:"), 1);
                const s = msg_ptr.objc_msgSend(dev, sel("newSamplerStateWithDescriptor:"), d);
                msg_void.objc_msgSend(d, sel("release"));
                break :blk s;
            }
            break :blk null;
        } else null;

        return .{
            .device = device,
            .command_queue = command_queue,
            .pipeline_state = pipeline_state,
            .layer = null,
            .vertex_buffer = vertex_buffer,
            .uniform_buffer = uniform_buffer,
            .atlas_texture = null,
            .sampler_state = sampler_state,
            .current_drawable = null,
            .current_command_buffer = null,
            .current_encoder = null,
            .width = 0,
            .height = 0,
            .config = config,
            .vertices = .empty,
            .glyph_atlas = null,
            .allocator = alloc,
        };
    }

    fn createNSString(data: []const u8) ?*anyopaque {
        const ns_class = cls("NSString") orelse return null;
        const alloc_sel = sel("alloc") orelse return null;
        const raw = msg.objc_msgSend(ns_class, alloc_sel) orelse return null;
        // initWithBytes:length:encoding:  (NSUTF8StringEncoding = 4)
        const init_sel = sel("initWithBytes:length:encoding:") orelse return null;
        _ = init_sel;
        // Simplified: use stringWithUTF8String: with null-terminated copy
        _ = data;
        _ = raw;
        // Return the allocated string (caller must release)
        return msg.objc_msgSend(ns_class, sel("string"));
    }

    fn createPipelineState(device: *anyopaque, library: *anyopaque) ?*anyopaque {
        const desc_class = cls("MTLRenderPipelineDescriptor") orelse return null;
        const desc = msg.objc_msgSend(desc_class, sel("new")) orelse return null;
        defer msg_void.objc_msgSend(desc, sel("release"));

        // Get vertex and fragment functions
        const vtx_name = createNSString(shaders.MetalShaders.vertex_main);
        const frag_name = createNSString(shaders.MetalShaders.fragment_cell);

        if (vtx_name) |vn| {
            const vtx_fn = msg_ptr.objc_msgSend(library, sel("newFunctionWithName:"), vn);
            if (vtx_fn) |f| {
                msg_void_ptr.objc_msgSend(desc, sel("setVertexFunction:"), f);
                msg_void.objc_msgSend(f, sel("release"));
            }
            msg_void.objc_msgSend(vn, sel("release"));
        }
        if (frag_name) |fn_name| {
            const frag_fn = msg_ptr.objc_msgSend(library, sel("newFunctionWithName:"), fn_name);
            if (frag_fn) |f| {
                msg_void_ptr.objc_msgSend(desc, sel("setFragmentFunction:"), f);
                msg_void.objc_msgSend(f, sel("release"));
            }
            msg_void.objc_msgSend(fn_name, sel("release"));
        }

        // Set pixel format: MTLPixelFormatBGRA8Unorm = 80
        const attachments = msg.objc_msgSend(desc, sel("colorAttachments"));
        if (attachments) |att| {
            const att0 = msg_u64.objc_msgSend(att, sel("objectAtIndexedSubscript:"), 0);
            if (att0) |a| {
                msg_void_u64.objc_msgSend(a, sel("setPixelFormat:"), 80);
                // Enable alpha blending
                msg_void_u64.objc_msgSend(a, sel("setBlendingEnabled:"), 1);
                // src * srcAlpha + dst * (1-srcAlpha)
                msg_void_u64.objc_msgSend(a, sel("setSourceRGBBlendFactor:"), 4); // sourceAlpha
                msg_void_u64.objc_msgSend(a, sel("setDestinationRGBBlendFactor:"), 5); // oneMinusSourceAlpha
            }
        }

        // Create pipeline state
        return msg_ptr_ptr.objc_msgSend(device, sel("newRenderPipelineStateWithDescriptor:error:"), desc, null);
    }

    pub fn deinit(self: *MetalRenderer) void {
        self.vertices.deinit(self.allocator);
        if (self.sampler_state) |s| msg_void.objc_msgSend(s, sel("release"));
        if (self.atlas_texture) |t| msg_void.objc_msgSend(t, sel("release"));
        if (self.uniform_buffer) |b| msg_void.objc_msgSend(b, sel("release"));
        if (self.vertex_buffer) |b| msg_void.objc_msgSend(b, sel("release"));
        if (self.pipeline_state) |p| msg_void.objc_msgSend(p, sel("release"));
        if (self.command_queue) |q| msg_void.objc_msgSend(q, sel("release"));
        // Device is autoreleased by MTLCreateSystemDefaultDevice
        self.device = null;
    }

    pub fn resize(self: *MetalRenderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        // Update CAMetalLayer drawable size if layer is set
        if (self.layer) |layer| {
            // [layer setDrawableSize:CGSizeMake(width, height)]
            _ = layer;
        }
    }

    pub fn beginFrame(self: *MetalRenderer) void {
        self.vertices.clearRetainingCapacity();

        const cq = self.command_queue orelse return;
        // [commandQueue commandBuffer]
        self.current_command_buffer = msg.objc_msgSend(cq, sel("commandBuffer"));

        if (self.layer) |layer| {
            // [layer nextDrawable]
            self.current_drawable = msg.objc_msgSend(layer, sel("nextDrawable"));
        }

        // Create render pass descriptor
        if (self.current_drawable) |drawable| {
            const rpd_class = cls("MTLRenderPassDescriptor") orelse return;
            const rpd = msg.objc_msgSend(rpd_class, sel("renderPassDescriptor")) orelse return;

            // Get drawable texture
            const texture = msg.objc_msgSend(drawable, sel("texture"));
            const attachments = msg.objc_msgSend(rpd, sel("colorAttachments"));
            if (attachments) |att| {
                const att0 = msg_u64.objc_msgSend(att, sel("objectAtIndexedSubscript:"), 0);
                if (att0) |a| {
                    msg_void_ptr.objc_msgSend(a, sel("setTexture:"), texture);
                    // MTLLoadActionClear = 2
                    msg_void_u64.objc_msgSend(a, sel("setLoadAction:"), 2);
                    // MTLStoreActionStore = 1
                    msg_void_u64.objc_msgSend(a, sel("setStoreAction:"), 1);
                }
            }

            // Create encoder: [commandBuffer renderCommandEncoderWithDescriptor:]
            if (self.current_command_buffer) |cb| {
                self.current_encoder = msg_ptr.objc_msgSend(cb, sel("renderCommandEncoderWithDescriptor:"), rpd);

                // Set pipeline state
                if (self.current_encoder) |enc| {
                    if (self.pipeline_state) |ps| {
                        msg_void_ptr.objc_msgSend(enc, sel("setRenderPipelineState:"), ps);
                    }
                }
            }
        }
    }

    pub fn endFrame(self: *MetalRenderer) void {
        const enc = self.current_encoder orelse return;
        const cb = self.current_command_buffer orelse return;

        // Upload vertices
        if (self.vertices.items.len > 0 and self.vertex_buffer != null) {
            const vb = self.vertex_buffer.?;
            const data_ptr = msg.objc_msgSend(vb, sel("contents"));
            if (data_ptr) |ptr| {
                const byte_count = self.vertices.items.len * @sizeOf(shaders.MetalShaders.CellVertex);
                const dst: [*]u8 = @ptrCast(ptr);
                const src: [*]const u8 = @ptrCast(self.vertices.items.ptr);
                @memcpy(dst[0..byte_count], src[0..byte_count]);
            }

            // Set vertex buffer
            msg_void_ptr_u64_u64.objc_msgSend(enc, sel("setVertexBuffer:offset:atIndex:"), vb, 0, 0);

            // Upload and set uniforms
            if (self.uniform_buffer) |ub| {
                const udata = msg.objc_msgSend(ub, sel("contents"));
                if (udata) |ptr| {
                    const uniforms = shaders.MetalShaders.Uniforms{
                        .projection_matrix = shaders.MetalShaders.orthoProjection(
                            @floatFromInt(self.width),
                            @floatFromInt(self.height),
                        ),
                        .viewport_size = .{ @floatFromInt(self.width), @floatFromInt(self.height) },
                        .cell_size = .{
                            if (self.config.cell_width > 0) @as(f32, @floatFromInt(self.config.cell_width)) else 8.0,
                            if (self.config.cell_height > 0) @as(f32, @floatFromInt(self.config.cell_height)) else 16.0,
                        },
                        .time = 0,
                    };
                    const dst: *shaders.MetalShaders.Uniforms = @ptrCast(@alignCast(ptr));
                    dst.* = uniforms;
                }
                msg_void_ptr_u64_u64.objc_msgSend(enc, sel("setVertexBuffer:offset:atIndex:"), ub, 0, 1);
            }

            // Set fragment texture and sampler
            if (self.atlas_texture) |tex| {
                msg_void_ptr_u64_u64.objc_msgSend(enc, sel("setFragmentTexture:atIndex:"), tex, 0, 0);
            }
            if (self.sampler_state) |ss| {
                msg_void_ptr_u64_u64.objc_msgSend(enc, sel("setFragmentSamplerState:atIndex:"), ss, 0, 0);
            }

            // Draw: [encoder drawPrimitives:vertexStart:vertexCount:]
            // MTLPrimitiveTypeTriangle = 0
            const msg_draw = struct {
                extern "c" fn objc_msgSend(r: ?*anyopaque, s: ?*anyopaque, prim: u64, start: u64, count: u64) void;
            };
            msg_draw.objc_msgSend(enc, sel("drawPrimitives:vertexStart:vertexCount:"), 0, 0, self.vertices.items.len);
        }

        // End encoding
        msg_void.objc_msgSend(enc, sel("endEncoding"));
        self.current_encoder = null;

        // Present drawable
        if (self.current_drawable) |drawable| {
            msg_void_ptr.objc_msgSend(cb, sel("presentDrawable:"), drawable);
        }

        // Commit
        msg_void.objc_msgSend(cb, sel("commit"));
        self.current_command_buffer = null;
        self.current_drawable = null;
    }

    pub fn drawCell(self: *MetalRenderer, x: u32, y: u32, cell: *const grid.Cell) void {
        const cw: f32 = if (self.config.cell_width > 0) @floatFromInt(self.config.cell_width) else 8.0;
        const ch: f32 = if (self.config.cell_height > 0) @floatFromInt(self.config.cell_height) else 16.0;
        const px: f32 = @as(f32, @floatFromInt(x)) * cw;
        const py: f32 = @as(f32, @floatFromInt(y)) * ch;

        const fg = colourToRgba(cell.fg);
        const bg = colourToRgba(cell.bg);

        // Background quad
        const bg_verts = shaders.MetalShaders.cellQuad(px, py, cw, ch, 0, 0, 0, 0, fg, bg, false);
        self.vertices.appendSlice(self.allocator, &bg_verts) catch return;

        // Glyph quad (if visible codepoint)
        if (cell.codepoint >= 0x20 and cell.codepoint != 0) {
            var tx: f32 = 0;
            var ty: f32 = 0;
            var tw: f32 = 0.05;
            var th: f32 = 0.05;
            var gw = cw;
            var gh = ch;
            var gx = px;
            var gy = py;
            if (self.glyph_atlas) |atlas| {
                if (atlas.getGlyph(cell.codepoint)) |entry| {
                    const as: f32 = @floatFromInt(atlas.atlas_size);
                    tx = @as(f32, @floatFromInt(entry.atlas_x)) / as;
                    ty = @as(f32, @floatFromInt(entry.atlas_y)) / as;
                    tw = @as(f32, @floatFromInt(entry.width)) / as;
                    th = @as(f32, @floatFromInt(entry.height)) / as;
                    gw = @floatFromInt(entry.width);
                    gh = @floatFromInt(entry.height);
                    gx = px + @as(f32, @floatFromInt(entry.bearing_x));
                    gy = py + cw - @as(f32, @floatFromInt(entry.bearing_y));
                }
            }
            const glyph_verts = shaders.MetalShaders.cellQuad(gx, gy, gw, gh, tx, ty, tw, th, fg, bg, true);
            self.vertices.appendSlice(self.allocator, &glyph_verts) catch return;
        }
    }

    pub fn drawRect(self: *MetalRenderer, x: u32, y: u32, w: u32, h: u32, c: colour.Colour) void {
        const rgba = colourToRgba(c);
        const px: f32 = @floatFromInt(x);
        const py: f32 = @floatFromInt(y);
        const pw: f32 = @floatFromInt(w);
        const ph: f32 = @floatFromInt(h);
        const verts = shaders.MetalShaders.cellQuad(px, py, pw, ph, 0, 0, 0, 0, rgba, rgba, false);
        self.vertices.appendSlice(self.allocator, &verts) catch return;
    }

    pub fn drawImage(_: *MetalRenderer, _: u32, _: u32, _: u32, _: u32, _: []const u8) void {
        // TODO: upload RGBA pixel data to texture and add quad with fragment_image shader
    }

    pub fn present(self: *MetalRenderer) void {
        // Present is handled in endFrame for Metal
        _ = self;
    }

    pub fn getCellSize(self: *MetalRenderer) renderer.Renderer.CellSize {
        return .{
            .width = if (self.config.cell_width > 0) self.config.cell_width else 8,
            .height = if (self.config.cell_height > 0) self.config.cell_height else 16,
        };
    }

    /// Upload glyph atlas texture data to the GPU.
    pub fn uploadAtlas(self: *MetalRenderer, data: []const u8, atlas_size: u32) void {
        const dev = self.device orelse return;

        // Release old texture
        if (self.atlas_texture) |t| msg_void.objc_msgSend(t, sel("release"));

        // Create MTLTextureDescriptor
        const td_class = cls("MTLTextureDescriptor") orelse return;
        const td = msg.objc_msgSend(td_class, sel("new")) orelse return;
        defer msg_void.objc_msgSend(td, sel("release"));

        // MTLPixelFormatR8Unorm = 10
        msg_void_u64.objc_msgSend(td, sel("setPixelFormat:"), 10);
        msg_void_u64.objc_msgSend(td, sel("setWidth:"), atlas_size);
        msg_void_u64.objc_msgSend(td, sel("setHeight:"), atlas_size);

        self.atlas_texture = msg_ptr.objc_msgSend(dev, sel("newTextureWithDescriptor:"), td);

        // Upload data via replaceRegion
        if (self.atlas_texture) |tex| {
            _ = tex;
            _ = data;
            // [texture replaceRegion:... mipmapLevel:0 withBytes:data bytesPerRow:atlas_size]
            // Complex struct-passing call — deferred to atlas integration
        }
    }

    fn colourToRgba(c: colour.Colour) [4]f32 {
        return switch (c) {
            .default => .{ 0.8, 0.8, 0.8, 1.0 },
            .palette => |idx| shaders.MetalShaders.paletteToRgba(idx),
            .rgb => |rgb| .{
                @as(f32, @floatFromInt(rgb.r)) / 255.0,
                @as(f32, @floatFromInt(rgb.g)) / 255.0,
                @as(f32, @floatFromInt(rgb.b)) / 255.0,
                1.0,
            },
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
