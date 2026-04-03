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

// D3D11 pipeline handle
handle: ?*anyopaque = null,
blending_enabled: bool = true,

// Compiled bytecode (stored until device is available)
vs_bytecode: ?*anyopaque = null,
vs_size: u32 = 0,
ps_bytecode: ?*anyopaque = null,
ps_size: u32 = 0,

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    _ = VertexAttributes;
    return .{
        .blending_enabled = opts.blending_enabled,
    };
}

/// Compile HLSL source to bytecode. Does NOT need a D3D11 device.
pub fn compileBytecode(self: *Self, vs_source: []const u8, ps_source: []const u8) void {
    if (self.vs_bytecode != null) return; // Already compiled

    const vs = dx.dx_compile_shader(vs_source.ptr, @intCast(vs_source.len), "vs_main", "vs_5_0");
    if (vs.bytecode != null) {
        self.vs_bytecode = vs.bytecode;
        self.vs_size = vs.size;
    }

    const ps = dx.dx_compile_shader(ps_source.ptr, @intCast(ps_source.len), "ps_main", "ps_5_0");
    if (ps.bytecode != null) {
        self.ps_bytecode = ps.bytecode;
        self.ps_size = ps.size;
    }
}

/// Create D3D11 shader objects from bytecode. Needs device.
pub fn createDeviceObjects(self: *Self, device: ?*anyopaque) void {
    if (self.handle != null) return; // Already created
    if (device == null or self.vs_bytecode == null or self.ps_bytecode == null) return;

    self.handle = dx.dx_create_pipeline(device, self.vs_bytecode, self.vs_size, self.ps_bytecode, self.ps_size, null, 0);

    // Free bytecode after creating device objects
    dx.dx_free_compiled_shader(.{ .bytecode = self.vs_bytecode, .size = self.vs_size });
    dx.dx_free_compiled_shader(.{ .bytecode = self.ps_bytecode, .size = self.ps_size });
    self.vs_bytecode = null;
    self.ps_bytecode = null;
}

pub fn deinit(self: *const Self) void {
    if (self.handle) |h| dx.dx_destroy_pipeline(h);
    if (self.vs_bytecode) |b| dx.dx_free_compiled_shader(.{ .bytecode = b, .size = self.vs_size });
    if (self.ps_bytecode) |b| dx.dx_free_compiled_shader(.{ .bytecode = b, .size = self.ps_size });
}
