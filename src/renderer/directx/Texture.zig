const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;
const log = std.log.scoped(.directx);

const Self = @This();

pub const Error = error{DirectXFailed};

pub const Options = struct {
    format: Format = .rgba,
    internal_format: InternalFormat = .rgba,
    target: TextureTarget = .texture_2d,
    min_filter: MinFilter = .linear,
    mag_filter: MagFilter = .linear,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,

    pub const Format = enum { rgba, bgra, red, red_integer };
    pub const InternalFormat = enum { rgba, srgba, red, r8, r32ui };
    pub const TextureTarget = enum { texture_2d, texture_2d_array, texture_rectangle };
    pub const MinFilter = enum { nearest, linear };
    pub const MagFilter = enum { nearest, linear };
    pub const Wrap = enum { clamp_to_edge, repeat };
};

// DXGI formats
const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_FORMAT_R8_UNORM: u32 = 61;

fn dxgiFormat(format: Options.Format) u32 {
    return switch (format) {
        .rgba => DXGI_FORMAT_R8G8B8A8_UNORM,
        .bgra => DXGI_FORMAT_B8G8R8A8_UNORM,
        .red => DXGI_FORMAT_R8_UNORM,
        .red_integer => DXGI_FORMAT_R8_UNORM,
    };
}

width: usize,
height: usize,
dx_handle: ?*dx.DxTexture = null,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    const dev = DirectX.current_device;
    var handle: ?*dx.DxTexture = null;

    if (dev != null and width > 0 and height > 0) {
        const data_ptr: ?*const anyopaque = if (data) |d| @ptrCast(d.ptr) else null;
        handle = dx.dx_create_texture(dev, @intCast(width), @intCast(height), dxgiFormat(opts.format), data_ptr);
        if (handle == null) log.err("dx_create_texture failed: {}x{}", .{ width, height });
    }

    return .{
        .width = width,
        .height = height,
        .dx_handle = handle,
    };
}

pub fn deinit(self: Self) void {
    if (self.dx_handle) |h| dx.dx_destroy_texture(h);
}

pub fn replaceRegion(self: *Self, offset_x: usize, offset_y: usize, rep_width: usize, rep_height: usize, data: []const u8) !void {
    const dev = DirectX.current_device orelse return;
    if (self.dx_handle) |h| {
        dx.dx_update_texture_region(dev, h, @intCast(offset_x), @intCast(offset_y), @intCast(rep_width), @intCast(rep_height), @ptrCast(data.ptr));
    }
}
