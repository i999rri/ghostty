const std = @import("std");

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

dx_handle: ?*anyopaque = null, // DxSampler*

pub fn init(opts: Options) Error!Self {
    _ = opts;
    // TODO: call dx_create_sampler when device is available
    return .{};
}

pub fn deinit(self: Self) void {
    _ = self;
    // TODO: dx_destroy_sampler
}
