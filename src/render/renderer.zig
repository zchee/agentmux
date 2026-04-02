const std = @import("std");
const colour = @import("../core/colour.zig");
const grid = @import("../screen/grid.zig");

/// GPU rendering backend type.
pub const Backend = enum {
    metal,
    vulkan,
    software,
};

/// Renderer configuration.
pub const RenderConfig = struct {
    font_size: f32 = 14.0,
    font_path: ?[]const u8 = null,
    dpi: f32 = 96.0,
    cell_width: u16 = 0, // auto-detect from font
    cell_height: u16 = 0,
    background: colour.Colour = .default,
};

/// Abstract renderer interface.
/// Metal and Vulkan backends implement this via VTable.
pub const Renderer = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        resize: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
        beginFrame: *const fn (ptr: *anyopaque) void,
        endFrame: *const fn (ptr: *anyopaque) void,
        drawCell: *const fn (ptr: *anyopaque, x: u32, y: u32, cell: *const grid.Cell) void,
        drawRect: *const fn (ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32, col: colour.Colour) void,
        drawImage: *const fn (ptr: *anyopaque, x: u32, y: u32, w: u32, h: u32, pixels: []const u8) void,
        present: *const fn (ptr: *anyopaque) void,
        getCellSize: *const fn (ptr: *anyopaque) CellSize,
    };

    pub const CellSize = struct {
        width: u16,
        height: u16,
    };

    pub fn deinit(self: Renderer) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn resize(self: Renderer, width: u32, height: u32) void {
        self.vtable.resize(self.ptr, width, height);
    }

    pub fn beginFrame(self: Renderer) void {
        self.vtable.beginFrame(self.ptr);
    }

    pub fn endFrame(self: Renderer) void {
        self.vtable.endFrame(self.ptr);
    }

    pub fn drawCell(self: Renderer, x: u32, y: u32, cell: *const grid.Cell) void {
        self.vtable.drawCell(self.ptr, x, y, cell);
    }

    pub fn drawRect(self: Renderer, x: u32, y: u32, w: u32, h: u32, col: colour.Colour) void {
        self.vtable.drawRect(self.ptr, x, y, w, h, col);
    }

    pub fn drawImage(self: Renderer, x: u32, y: u32, w: u32, h: u32, pixels: []const u8) void {
        self.vtable.drawImage(self.ptr, x, y, w, h, pixels);
    }

    pub fn present(self: Renderer) void {
        self.vtable.present(self.ptr);
    }

    pub fn getCellSize(self: Renderer) CellSize {
        return self.vtable.getCellSize(self.ptr);
    }
};
