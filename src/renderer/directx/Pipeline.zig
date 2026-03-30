const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;

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

// D3D11 pipeline handle (DxPipeline*)
handle: ?*anyopaque = null,
blending_enabled: bool = true,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = VertexAttributes;
    // Pipeline creation is deferred to createOnDevice (needs DxDevice*)
    return .{
        .blending_enabled = opts.blending_enabled,
    };
}

/// Create the actual D3D11 pipeline objects using the device.
/// Called lazily when the device is available.
pub fn createOnDevice(self: *Self, device: ?*anyopaque, vs_source: []const u8, ps_source: []const u8) !void {
    if (self.handle != null) return; // Already created
    if (device == null) return;

    // Compile vertex shader
    const vs = dx.dx_compile_shader(vs_source.ptr, @intCast(vs_source.len), "vs_main", "vs_5_0");
    defer dx.dx_free_compiled_shader(vs);
    if (vs.bytecode == null) return error.DirectXFailed;

    // Compile pixel shader
    const ps = dx.dx_compile_shader(ps_source.ptr, @intCast(ps_source.len), "ps_main", "ps_5_0");
    defer dx.dx_free_compiled_shader(ps);
    if (ps.bytecode == null) return error.DirectXFailed;

    // Create pipeline (input layout created from VS reflection)
    self.handle = dx.dx_create_pipeline(device, vs.bytecode, vs.size, ps.bytecode, ps.size, null, 0);
}

pub fn deinit(self: *const Self) void {
    if (self.handle) |h| dx.dx_destroy_pipeline(h);
}
