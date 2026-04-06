const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("renderer.zig");
const grid = @import("../screen/grid.zig");
const colour = @import("../core/colour.zig");
const shaders = @import("shaders.zig");

/// Vulkan GPU renderer for Linux.
/// Uses the Vulkan C API for GPU-accelerated terminal cell rendering.
pub const VulkanRenderer = if (builtin.os.tag == .linux) struct {
    instance: vk.VkInstance,
    physical_device: vk.VkPhysicalDevice,
    device: vk.VkDevice,
    queue: vk.VkQueue,
    command_pool: vk.VkCommandPool,
    command_buffer: vk.VkCommandBuffer,
    render_pass: vk.VkRenderPass,
    pipeline: vk.VkPipeline,
    pipeline_layout: vk.VkPipelineLayout,
    vertex_buffer: vk.VkBuffer,
    vertex_memory: vk.VkDeviceMemory,
    framebuffer: vk.VkFramebuffer,
    width: u32,
    height: u32,
    config: renderer.RenderConfig,
    vertices: std.ArrayListAligned(CellVertex, null),
    initialized: bool,
    allocator: std.mem.Allocator,

    // ---- Vulkan C API bindings ----

    const vk = struct {
        const VkInstance = ?*anyopaque;
        const VkPhysicalDevice = ?*anyopaque;
        const VkDevice = ?*anyopaque;
        const VkQueue = ?*anyopaque;
        const VkCommandPool = ?*anyopaque;
        const VkCommandBuffer = ?*anyopaque;
        const VkRenderPass = ?*anyopaque;
        const VkPipeline = ?*anyopaque;
        const VkPipelineLayout = ?*anyopaque;
        const VkBuffer = ?*anyopaque;
        const VkDeviceMemory = ?*anyopaque;
        const VkFramebuffer = ?*anyopaque;
        const VkShaderModule = ?*anyopaque;

        const VK_SUCCESS: i32 = 0;
        const VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO: u32 = 1;
        const VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO: u32 = 3;
        const VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO: u32 = 2;
        const VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO: u32 = 39;
        const VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO: u32 = 40;
        const VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO: u32 = 42;
        const VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO: u32 = 38;
        const VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO: u32 = 12;
        const VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO: u32 = 5;
        const VK_QUEUE_GRAPHICS_BIT: u32 = 1;
        const VK_BUFFER_USAGE_VERTEX_BUFFER_BIT: u32 = 0x80;
        const VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT: u32 = 2;
        const VK_MEMORY_PROPERTY_HOST_COHERENT_BIT: u32 = 4;
        const VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT: u32 = 2;
        const VK_COMMAND_BUFFER_LEVEL_PRIMARY: u32 = 0;

        // Core Vulkan functions
        extern "c" fn vkCreateInstance(create_info: *const anyopaque, allocator: ?*const anyopaque, instance: *VkInstance) i32;
        extern "c" fn vkDestroyInstance(instance: VkInstance, allocator: ?*const anyopaque) void;
        extern "c" fn vkEnumeratePhysicalDevices(instance: VkInstance, count: *u32, devices: ?[*]VkPhysicalDevice) i32;
        extern "c" fn vkGetPhysicalDeviceQueueFamilyProperties(device: VkPhysicalDevice, count: *u32, props: ?[*]anyopaque) void;
        extern "c" fn vkCreateDevice(physical_device: VkPhysicalDevice, create_info: *const anyopaque, allocator: ?*const anyopaque, device: *VkDevice) i32;
        extern "c" fn vkGetDeviceQueue(device: VkDevice, family: u32, index: u32, queue: *VkQueue) void;
        extern "c" fn vkDestroyDevice(device: VkDevice, allocator: ?*const anyopaque) void;
        extern "c" fn vkCreateCommandPool(device: VkDevice, create_info: *const anyopaque, allocator: ?*const anyopaque, pool: *VkCommandPool) i32;
        extern "c" fn vkDestroyCommandPool(device: VkDevice, pool: VkCommandPool, allocator: ?*const anyopaque) void;
        extern "c" fn vkAllocateCommandBuffers(device: VkDevice, alloc_info: *const anyopaque, buffers: *VkCommandBuffer) i32;
        extern "c" fn vkBeginCommandBuffer(buffer: VkCommandBuffer, begin_info: *const anyopaque) i32;
        extern "c" fn vkEndCommandBuffer(buffer: VkCommandBuffer) i32;
        extern "c" fn vkQueueSubmit(queue: VkQueue, count: u32, submits: *const anyopaque, fence: ?*anyopaque) i32;
        extern "c" fn vkQueueWaitIdle(queue: VkQueue) i32;
        extern "c" fn vkCreateBuffer(device: VkDevice, create_info: *const anyopaque, allocator: ?*const anyopaque, buffer: *VkBuffer) i32;
        extern "c" fn vkDestroyBuffer(device: VkDevice, buffer: VkBuffer, allocator: ?*const anyopaque) void;
        extern "c" fn vkGetBufferMemoryRequirements(device: VkDevice, buffer: VkBuffer, requirements: *anyopaque) void;
        extern "c" fn vkAllocateMemory(device: VkDevice, alloc_info: *const anyopaque, allocator: ?*const anyopaque, memory: *VkDeviceMemory) i32;
        extern "c" fn vkFreeMemory(device: VkDevice, memory: VkDeviceMemory, allocator: ?*const anyopaque) void;
        extern "c" fn vkBindBufferMemory(device: VkDevice, buffer: VkBuffer, memory: VkDeviceMemory, offset: u64) i32;
        extern "c" fn vkMapMemory(device: VkDevice, memory: VkDeviceMemory, offset: u64, size: u64, flags: u32, data: *?*anyopaque) i32;
        extern "c" fn vkUnmapMemory(device: VkDevice, memory: VkDeviceMemory) void;
        extern "c" fn vkGetPhysicalDeviceMemoryProperties(device: VkPhysicalDevice, props: *anyopaque) void;
        extern "c" fn vkCmdBindVertexBuffers(buffer: VkCommandBuffer, first: u32, count: u32, buffers: *const VkBuffer, offsets: *const u64) void;
        extern "c" fn vkCmdDraw(buffer: VkCommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void;
    };

    /// Vertex layout matching the Metal renderer for consistency.
    const CellVertex = extern struct {
        position: [2]f32,
        tex_coord: [2]f32,
        fg_color: [4]f32,
        bg_color: [4]f32,
        is_glyph: f32,
    };

    pub fn init(alloc: std.mem.Allocator, config: renderer.RenderConfig) VulkanRenderer {
        var self = VulkanRenderer{
            .instance = null,
            .physical_device = null,
            .device = null,
            .queue = null,
            .command_pool = null,
            .command_buffer = null,
            .render_pass = null,
            .pipeline = null,
            .pipeline_layout = null,
            .vertex_buffer = null,
            .vertex_memory = null,
            .framebuffer = null,
            .width = 0,
            .height = 0,
            .config = config,
            .vertices = .empty,
            .initialized = false,
            .allocator = alloc,
        };

        if (!self.initInstance()) return self;
        if (!self.pickPhysicalDevice()) return self;
        if (!self.createDevice()) return self;
        self.createCommandPool();
        self.createVertexBuffer();
        self.initialized = true;
        return self;
    }

    fn initInstance(self: *VulkanRenderer) bool {
        // VkApplicationInfo
        const app_info = extern struct {
            sType: u32 = 0, // VK_STRUCTURE_TYPE_APPLICATION_INFO
            pNext: ?*anyopaque = null,
            pApplicationName: [*:0]const u8 = "agentmux",
            applicationVersion: u32 = 1,
            pEngineName: [*:0]const u8 = "agentmux",
            engineVersion: u32 = 1,
            apiVersion: u32 = (1 << 22) | (0 << 12), // VK_API_VERSION_1_0
        }{};

        const create_info = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = 0,
            pApplicationInfo: *const anyopaque,
            enabledLayerCount: u32 = 0,
            ppEnabledLayerNames: ?*const anyopaque = null,
            enabledExtensionCount: u32 = 0,
            ppEnabledExtensionNames: ?*const anyopaque = null,
        }{ .pApplicationInfo = @ptrCast(&app_info) };

        const result = vk.vkCreateInstance(@ptrCast(&create_info), null, &self.instance);
        return result == vk.VK_SUCCESS;
    }

    fn pickPhysicalDevice(self: *VulkanRenderer) bool {
        var count: u32 = 0;
        _ = vk.vkEnumeratePhysicalDevices(self.instance, &count, null);
        if (count == 0) return false;

        var devices: [16]vk.VkPhysicalDevice = .{null} ** 16;
        const n = @min(count, 16);
        _ = vk.vkEnumeratePhysicalDevices(self.instance, &n, &devices);
        self.physical_device = devices[0]; // Pick first device
        return self.physical_device != null;
    }

    fn createDevice(self: *VulkanRenderer) bool {
        // Find graphics queue family
        var queue_count: u32 = 0;
        vk.vkGetPhysicalDeviceQueueFamilyProperties(self.physical_device, &queue_count, null);
        if (queue_count == 0) return false;

        const priority: f32 = 1.0;
        const queue_ci = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = 0,
            queueFamilyIndex: u32 = 0,
            queueCount: u32 = 1,
            pQueuePriorities: *const f32,
        }{ .pQueuePriorities = &priority };

        const device_ci = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = 0,
            queueCreateInfoCount: u32 = 1,
            pQueueCreateInfos: *const anyopaque,
            enabledLayerCount: u32 = 0,
            ppEnabledLayerNames: ?*const anyopaque = null,
            enabledExtensionCount: u32 = 0,
            ppEnabledExtensionNames: ?*const anyopaque = null,
            pEnabledFeatures: ?*const anyopaque = null,
        }{ .pQueueCreateInfos = @ptrCast(&queue_ci) };

        const result = vk.vkCreateDevice(self.physical_device, @ptrCast(&device_ci), null, &self.device);
        if (result != vk.VK_SUCCESS) return false;

        vk.vkGetDeviceQueue(self.device, 0, 0, &self.queue);
        return true;
    }

    fn createCommandPool(self: *VulkanRenderer) void {
        const dev = self.device orelse return;
        const ci = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            queueFamilyIndex: u32 = 0,
        }{};
        _ = vk.vkCreateCommandPool(dev, @ptrCast(&ci), null, &self.command_pool);

        // Allocate command buffer
        const pool = self.command_pool orelse return;
        const alloc_info = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            pNext: ?*anyopaque = null,
            commandPool: vk.VkCommandPool,
            level: u32 = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            commandBufferCount: u32 = 1,
        }{ .commandPool = pool };
        _ = vk.vkAllocateCommandBuffers(dev, @ptrCast(&alloc_info), &self.command_buffer);
    }

    fn createVertexBuffer(self: *VulkanRenderer) void {
        const dev = self.device orelse return;
        const buf_size: u64 = 65536 * @sizeOf(CellVertex);

        const ci = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = 0,
            size: u64,
            usage: u32 = vk.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            sharingMode: u32 = 0, // VK_SHARING_MODE_EXCLUSIVE
            queueFamilyIndexCount: u32 = 0,
            pQueueFamilyIndices: ?*const u32 = null,
        }{ .size = buf_size };

        _ = vk.vkCreateBuffer(dev, @ptrCast(&ci), null, &self.vertex_buffer);
    }

    pub fn deinit(self: *VulkanRenderer) void {
        self.vertices.deinit(self.allocator);
        if (self.device) |dev| {
            if (self.vertex_buffer) |vb| vk.vkDestroyBuffer(dev, vb, null);
            if (self.vertex_memory) |vm| vk.vkFreeMemory(dev, vm, null);
            if (self.command_pool) |cp| vk.vkDestroyCommandPool(dev, cp, null);
            vk.vkDestroyDevice(dev, null);
        }
        if (self.instance) |inst| vk.vkDestroyInstance(inst, null);
        self.initialized = false;
    }

    pub fn resize(self: *VulkanRenderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    pub fn beginFrame(self: *VulkanRenderer) void {
        self.vertices.clearRetainingCapacity();
        if (!self.initialized) return;

        const cb = self.command_buffer orelse return;
        const begin_info = extern struct {
            sType: u32 = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            pNext: ?*anyopaque = null,
            flags: u32 = 1, // VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
            pInheritanceInfo: ?*const anyopaque = null,
        }{};
        _ = vk.vkBeginCommandBuffer(cb, @ptrCast(&begin_info));
    }

    pub fn endFrame(self: *VulkanRenderer) void {
        if (!self.initialized) return;
        const cb = self.command_buffer orelse return;
        const q = self.queue orelse return;

        // Upload vertices
        if (self.vertices.items.len > 0) {
            if (self.vertex_buffer) |vb| {
                if (self.vertex_memory) |vm| {
                    var data: ?*anyopaque = null;
                    const byte_count = self.vertices.items.len * @sizeOf(CellVertex);
                    if (vk.vkMapMemory(self.device, vm, 0, byte_count, 0, &data) == vk.VK_SUCCESS) {
                        if (data) |ptr| {
                            const dst: [*]u8 = @ptrCast(ptr);
                            const src: [*]const u8 = @ptrCast(self.vertices.items.ptr);
                            @memcpy(dst[0..byte_count], src[0..byte_count]);
                        }
                        vk.vkUnmapMemory(self.device, vm);
                    }
                }

                // Bind vertex buffer and draw
                const offset: u64 = 0;
                vk.vkCmdBindVertexBuffers(cb, 0, 1, &vb, &offset);
                vk.vkCmdDraw(cb, @intCast(self.vertices.items.len), 1, 0, 0);
            }
        }

        _ = vk.vkEndCommandBuffer(cb);

        // Submit
        const submit_info = extern struct {
            sType: u32 = 36, // VK_STRUCTURE_TYPE_SUBMIT_INFO
            pNext: ?*anyopaque = null,
            waitSemaphoreCount: u32 = 0,
            pWaitSemaphores: ?*const anyopaque = null,
            pWaitDstStageMask: ?*const u32 = null,
            commandBufferCount: u32 = 1,
            pCommandBuffers: *const vk.VkCommandBuffer,
            signalSemaphoreCount: u32 = 0,
            pSignalSemaphores: ?*const anyopaque = null,
        }{ .pCommandBuffers = &cb };

        _ = vk.vkQueueSubmit(q, 1, @ptrCast(&submit_info), null);
        _ = vk.vkQueueWaitIdle(q);
    }

    pub fn drawCell(self: *VulkanRenderer, x: u32, y: u32, cell: *const grid.Cell) void {
        const cw: f32 = if (self.config.cell_width > 0) @floatFromInt(self.config.cell_width) else 8.0;
        const ch: f32 = if (self.config.cell_height > 0) @floatFromInt(self.config.cell_height) else 16.0;
        const px: f32 = @as(f32, @floatFromInt(x)) * cw;
        const py: f32 = @as(f32, @floatFromInt(y)) * ch;

        const fg = colourToRgba(cell.fg);
        const bg = colourToRgba(cell.bg);

        // Background quad (2 triangles = 6 vertices)
        appendQuad(self, px, py, cw, ch, .{ 0, 0 }, .{ 0, 0 }, fg, bg, 0);

        // Glyph quad
        if (cell.codepoint >= 0x20 and cell.codepoint != 0) {
            appendQuad(self, px, py, cw, ch, .{ 0, 0 }, .{ 0.05, 0.05 }, fg, bg, 1);
        }
    }

    pub fn drawRect(self: *VulkanRenderer, x: u32, y: u32, w: u32, h: u32, c: colour.Colour) void {
        const rgba = colourToRgba(c);
        appendQuad(self, @floatFromInt(x), @floatFromInt(y), @floatFromInt(w), @floatFromInt(h), .{ 0, 0 }, .{ 0, 0 }, rgba, rgba, 0);
    }

    pub fn drawImage(_: *VulkanRenderer, _: u32, _: u32, _: u32, _: u32, _: []const u8) void {
        // Image rendering requires texture upload — deferred to atlas integration.
    }

    pub fn present(self: *VulkanRenderer) void {
        // Present is handled in endFrame via queue submit.
        _ = self;
    }

    pub fn getCellSize(self: *VulkanRenderer) renderer.Renderer.CellSize {
        return .{
            .width = if (self.config.cell_width > 0) self.config.cell_width else 8,
            .height = if (self.config.cell_height > 0) self.config.cell_height else 16,
        };
    }

    fn appendQuad(self: *VulkanRenderer, x: f32, y: f32, w: f32, h: f32, tex_xy: [2]f32, tex_wh: [2]f32, fg: [4]f32, bg: [4]f32, is_glyph: f32) void {
        const verts = [6]CellVertex{
            .{ .position = .{ x, y }, .tex_coord = .{ tex_xy[0], tex_xy[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
            .{ .position = .{ x + w, y }, .tex_coord = .{ tex_xy[0] + tex_wh[0], tex_xy[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
            .{ .position = .{ x, y + h }, .tex_coord = .{ tex_xy[0], tex_xy[1] + tex_wh[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
            .{ .position = .{ x + w, y }, .tex_coord = .{ tex_xy[0] + tex_wh[0], tex_xy[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
            .{ .position = .{ x + w, y + h }, .tex_coord = .{ tex_xy[0] + tex_wh[0], tex_xy[1] + tex_wh[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
            .{ .position = .{ x, y + h }, .tex_coord = .{ tex_xy[0], tex_xy[1] + tex_wh[1] }, .fg_color = fg, .bg_color = bg, .is_glyph = is_glyph },
        };
        self.vertices.appendSlice(self.allocator, &verts) catch return;
    }

    fn colourToRgba(c: colour.Colour) [4]f32 {
        return switch (c) {
            .default => .{ 0.8, 0.8, 0.8, 1.0 },
            .palette => |idx| paletteToRgba(idx),
            .rgb => |rgb| .{
                @as(f32, @floatFromInt(rgb.r)) / 255.0,
                @as(f32, @floatFromInt(rgb.g)) / 255.0,
                @as(f32, @floatFromInt(rgb.b)) / 255.0,
                1.0,
            },
        };
    }

    fn paletteToRgba(idx: u8) [4]f32 {
        const palette = [16][3]f32{
            .{ 0, 0, 0 },
            .{ 0.8, 0, 0 },
            .{ 0, 0.8, 0 },
            .{ 0.8, 0.8, 0 },
            .{ 0, 0, 0.8 },
            .{ 0.8, 0, 0.8 },
            .{ 0, 0.8, 0.8 },
            .{ 0.75, 0.75, 0.75 },
            .{ 0.5, 0.5, 0.5 },
            .{ 1, 0, 0 },
            .{ 0, 1, 0 },
            .{ 1, 1, 0 },
            .{ 0, 0, 1 },
            .{ 1, 0, 1 },
            .{ 0, 1, 1 },
            .{ 1, 1, 1 },
        };
        if (idx < 16) return .{ palette[idx][0], palette[idx][1], palette[idx][2], 1.0 };
        if (idx < 232) {
            const ci = idx - 16;
            return .{ @as(f32, @floatFromInt(ci / 36)) / 5.0, @as(f32, @floatFromInt((ci / 6) % 6)) / 5.0, @as(f32, @floatFromInt(ci % 6)) / 5.0, 1.0 };
        }
        const gray: f32 = (@as(f32, @floatFromInt(idx - 232)) * 10.0 + 8.0) / 255.0;
        return .{ gray, gray, gray, 1.0 };
    }

    /// Create a Renderer interface from this VulkanRenderer.
    pub fn asRenderer(self: *VulkanRenderer) renderer.Renderer {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
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

    fn deinitVt(self: *VulkanRenderer) void { self.deinit(); }
    fn resizeVt(self: *VulkanRenderer, w: u32, h: u32) void { self.resize(w, h); }
    fn beginFrameVt(self: *VulkanRenderer) void { self.beginFrame(); }
    fn endFrameVt(self: *VulkanRenderer) void { self.endFrame(); }
    fn drawCellVt(self: *VulkanRenderer, x: u32, y: u32, cell: *const grid.Cell) void { self.drawCell(x, y, cell); }
    fn drawRectVt(self: *VulkanRenderer, x: u32, y: u32, w: u32, h: u32, c: colour.Colour) void { self.drawRect(x, y, w, h, c); }
    fn drawImageVt(self: *VulkanRenderer, x: u32, y: u32, w: u32, h: u32, px: []const u8) void { self.drawImage(x, y, w, h, px); }
    fn presentVt(self: *VulkanRenderer) void { self.present(); }
    fn getCellSizeVt(self: *VulkanRenderer) renderer.Renderer.CellSize { return self.getCellSize(); }
} else void;
