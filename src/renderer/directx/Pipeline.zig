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

handle: ?*dx.DxPipeline = null,
blending_enabled: bool = true,
id: u8 = 0,
layout_type: LayoutType = .none,

const LayoutType = enum { none, cell_text, bg_image, image };

const MAX_PIPELINES = 16;

const SourceEntry = struct {
    vs: ?[*]const u8 = null,
    vs_len: u32 = 0,
    ps: ?[*]const u8 = null,
    ps_len: u32 = 0,
};

var sources: [MAX_PIPELINES]SourceEntry = [_]SourceEntry{.{}} ** MAX_PIPELINES;
var handles: [MAX_PIPELINES]?*dx.DxPipeline = [_]?*dx.DxPipeline{null} ** MAX_PIPELINES;
var next_id: u8 = 1;

pub fn init(comptime VertexAttributes: ?type, opts: Options) !Self {
    const shaders_mod = @import("shaders.zig");
    const lt: LayoutType = if (VertexAttributes) |VA| blk: {
        if (VA == shaders_mod.CellText) break :blk .cell_text;
        if (VA == shaders_mod.BgImage) break :blk .bg_image;
        if (VA == shaders_mod.Image) break :blk .image;
        break :blk .none;
    } else .none;
    return .{
        .blending_enabled = opts.blending_enabled,
        .layout_type = lt,
    };
}

/// Store HLSL source pointers (comptime data, always valid). No compilation yet.
pub fn storeSource(self: *Self, vs_source: []const u8, ps_source: []const u8) void {
    const id = next_id;
    next_id += 1;
    self.id = id;
    sources[id] = .{
        .vs = vs_source.ptr,
        .vs_len = @intCast(vs_source.len),
        .ps = ps_source.ptr,
        .ps_len = @intCast(ps_source.len),
    };
}

/// Get D3D11 pipeline handle. Compiles HLSL + creates shaders on first call (renderer thread).
pub fn getHandle(self: Self, device: ?*dx.DxDevice) ?*dx.DxPipeline {
    if (self.id == 0 or self.id >= MAX_PIPELINES) return null;
    if (handles[self.id]) |h| return h;
    if (device == null) return null;

    const src = &sources[self.id];
    if (src.vs == null or src.ps == null) return null;

    // Compile + create entirely on renderer thread
    const vs = dx.dx_compile_shader(src.vs, src.vs_len, "vs_main", "vs_5_0");
    const ps = dx.dx_compile_shader(src.ps, src.ps_len, "ps_main", "ps_5_0");
    defer dx.dx_free_compiled_shader(vs);
    defer dx.dx_free_compiled_shader(ps);

    if (vs.bytecode == null or ps.bytecode == null) return null;

    const h = switch (self.layout_type) {
        .cell_text => dx.dx_create_cell_text_pipeline(device, vs.bytecode, vs.size, ps.bytecode, ps.size),
        .bg_image => dx.dx_create_bg_image_pipeline(device, vs.bytecode, vs.size, ps.bytecode, ps.size),
        .image => dx.dx_create_image_pipeline(device, vs.bytecode, vs.size, ps.bytecode, ps.size),
        .none => dx.dx_create_pipeline(device, vs.bytecode, vs.size, ps.bytecode, ps.size, null, 0),
    };
    handles[self.id] = h;
    return h;
}

pub fn deinit(self: *const Self) void {
    if (self.id > 0 and self.id < MAX_PIPELINES) {
        if (handles[self.id]) |h| {
            dx.dx_destroy_pipeline(h);
            handles[self.id] = null;
        }
    }
}
