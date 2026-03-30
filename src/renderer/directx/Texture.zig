const std = @import("std");

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

width: usize,
height: usize,
dx_handle: ?*anyopaque = null, // DxTexture*

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    _ = opts;
    _ = data;
    // TODO: call dx_create_texture when device is available
    return .{
        .width = width,
        .height = height,
    };
}

pub fn deinit(self: Self) void {
    _ = self;
    // TODO: dx_destroy_texture
}

pub fn replaceRegion(self: *Self, offset_x: usize, offset_y: usize, rep_width: usize, rep_height: usize, data: []const u8) !void {
    _ = self;
    _ = offset_x;
    _ = offset_y;
    _ = rep_width;
    _ = rep_height;
    _ = data;
    // TODO: dx_update_texture_region
}
