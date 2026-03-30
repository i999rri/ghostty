const std = @import("std");

const Self = @This();

pub const Options = struct {
    vertex_fn: [:0]const u8,
    fragment_fn: [:0]const u8,
    vertex_attributes: ?type = null,
    step_fn: StepFunction = .per_vertex,
    blending_enabled: bool = true,

    pub const StepFunction = enum {
        constant,
        per_vertex,
        per_instance,
    };
};

// TODO: ID3D11VertexShader, ID3D11PixelShader, ID3D11InputLayout

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = VertexAttributes;
    _ = opts;
    // TODO: Compile HLSL shaders, create input layout
    return .{};
}

pub fn deinit(self: *const Self) void {
    _ = self;
}
