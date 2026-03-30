const std = @import("std");

const Self = @This();

pub const Options = struct {
    internal_format: InternalFormat,
    width: usize,
    height: usize,

    pub const InternalFormat = enum { rgba, srgba };
};

width: u32,
height: u32,
// TODO: ID3D11RenderTargetView, ID3D11Texture2D

pub fn init(opts: Options) !Self {
    return .{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
    };
}

pub fn deinit(self: *Self) void {
    self.* = undefined;
}
