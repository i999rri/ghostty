const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;

const Self = @This();

pub const Error = error{DirectXFailed};

pub const Options = struct {
    min_filter: Filter = .linear,
    mag_filter: Filter = .linear,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,

    pub const Filter = enum { nearest, linear };
    pub const Wrap = enum { clamp_to_edge, repeat };
};

// D3D11 filter modes
const D3D11_FILTER_MIN_MAG_MIP_POINT: u32 = 0;
const D3D11_FILTER_MIN_MAG_MIP_LINEAR: u32 = 0x15;
// D3D11 address modes
const D3D11_TEXTURE_ADDRESS_CLAMP: u32 = 3;
const D3D11_TEXTURE_ADDRESS_WRAP: u32 = 1;

dx_handle: ?*anyopaque = null,

pub fn init(opts: Options) Error!Self {
    const dev = DirectX.current_device;
    var handle: ?*anyopaque = null;

    if (dev != null) {
        const filter: u32 = if (opts.min_filter == .nearest and opts.mag_filter == .nearest)
            D3D11_FILTER_MIN_MAG_MIP_POINT
        else
            D3D11_FILTER_MIN_MAG_MIP_LINEAR;

        const address: u32 = if (opts.wrap_s == .repeat)
            D3D11_TEXTURE_ADDRESS_WRAP
        else
            D3D11_TEXTURE_ADDRESS_CLAMP;

        handle = dx.dx_create_sampler(dev, filter, address);
    }

    return .{ .dx_handle = handle };
}

pub fn deinit(self: Self) void {
    if (self.dx_handle) |h| dx.dx_destroy_sampler(h);
}
