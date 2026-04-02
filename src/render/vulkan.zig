const std = @import("std");
const builtin = @import("builtin");
const renderer = @import("renderer.zig");
const grid = @import("../screen/grid.zig");
const colour = @import("../core/colour.zig");

/// Vulkan GPU renderer for Linux.
pub const VulkanRenderer = if (builtin.os.tag == .linux) struct {
    instance: ?*anyopaque, // VkInstance
    physical_device: ?*anyopaque, // VkPhysicalDevice
    device: ?*anyopaque, // VkDevice
    queue: ?*anyopaque, // VkQueue
    swapchain: ?*anyopaque, // VkSwapchainKHR
    render_pass: ?*anyopaque, // VkRenderPass
    pipeline: ?*anyopaque, // VkPipeline
    command_pool: ?*anyopaque, // VkCommandPool
    width: u32,
    height: u32,
    config: renderer.RenderConfig,

    const vk = struct {
        extern "c" fn vkCreateInstance(create_info: *const anyopaque, allocator: ?*const anyopaque, instance: *?*anyopaque) i32;
        extern "c" fn vkDestroyInstance(instance: ?*anyopaque, allocator: ?*const anyopaque) void;
        extern "c" fn vkEnumeratePhysicalDevices(instance: ?*anyopaque, count: *u32, devices: ?[*]?*anyopaque) i32;
    };

    pub fn init(config: renderer.RenderConfig) VulkanRenderer {
        return .{
            .instance = null,
            .physical_device = null,
            .device = null,
            .queue = null,
            .swapchain = null,
            .render_pass = null,
            .pipeline = null,
            .command_pool = null,
            .width = 0,
            .height = 0,
            .config = config,
        };
    }

    pub fn deinit(self: *VulkanRenderer) void {
        if (self.instance) |inst| vk.vkDestroyInstance(inst, null);
        self.* = .init(self.config);
    }

    pub fn resize(self: *VulkanRenderer, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }

    pub fn beginFrame(_: *VulkanRenderer) void {}
    pub fn endFrame(_: *VulkanRenderer) void {}
    pub fn drawCell(_: *VulkanRenderer, _: u32, _: u32, _: *const grid.Cell) void {}
    pub fn drawRect(_: *VulkanRenderer, _: u32, _: u32, _: u32, _: u32, _: colour.Colour) void {}
    pub fn drawImage(_: *VulkanRenderer, _: u32, _: u32, _: u32, _: u32, _: []const u8) void {}
    pub fn present(_: *VulkanRenderer) void {}

    pub fn getCellSize(self: *VulkanRenderer) renderer.Renderer.CellSize {
        return .{
            .width = if (self.config.cell_width > 0) self.config.cell_width else 8,
            .height = if (self.config.cell_height > 0) self.config.cell_height else 16,
        };
    }
} else void;
