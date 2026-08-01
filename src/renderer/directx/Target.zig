const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;

const Self = @This();

pub const Options = struct {
    internal_format: InternalFormat,
    width: usize,
    height: usize,

    pub const InternalFormat = enum { rgba, srgba };
};

width: u32,
height: u32,
rt_handle: ?*dx.DxRenderTarget = null,

pub fn init(opts: Options) !Self {
    return .{
        .width = @intCast(opts.width),
        .height = @intCast(opts.height),
    };
}

pub fn deinit(self: *Self) void {
    if (self.rt_handle) |h| dx.dx_destroy_render_target(h);
    self.* = undefined;
}
