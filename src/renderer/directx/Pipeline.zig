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

// --- Global source registry (comptime HLSL, deduplicated by pointer) ---

const MAX_SOURCES = 16;

const SourceEntry = struct {
    vs: ?[*]const u8 = null,
    vs_len: u32 = 0,
    ps: ?[*]const u8 = null,
    ps_len: u32 = 0,
};

var sources: [MAX_SOURCES]SourceEntry = [_]SourceEntry{.{}} ** MAX_SOURCES;
var next_id: u8 = 1;

// --- Per-device handle cache ---
// Each source ID can have a compiled pipeline on multiple devices.
// We store (device, handle) pairs so different surfaces (different devices)
// each get their own pipeline object without conflicting.

const MAX_DEVICES = 8;

const DeviceHandle = struct {
    device: ?*dx.DxDevice = null,
    handle: ?*dx.DxPipeline = null,
};

var device_handles: [MAX_SOURCES][MAX_DEVICES]DeviceHandle = [_][MAX_DEVICES]DeviceHandle{
    [_]DeviceHandle{.{}} ** MAX_DEVICES,
} ** MAX_SOURCES;

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

/// Register HLSL source. Deduplicates by pointer identity.
pub fn storeSource(self: *Self, vs_source: []const u8, ps_source: []const u8) void {
    // Check if already registered (comptime pointers are stable).
    var i: u8 = 1;
    while (i < next_id) : (i += 1) {
        if (sources[i].vs == vs_source.ptr and sources[i].ps == ps_source.ptr) {
            self.id = i;
            return;
        }
    }
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

/// Get or create pipeline for the given device. Pipelines are cached
/// per (source_id, device) pair so multiple surfaces work correctly.
pub fn getHandle(self: Self, device: ?*dx.DxDevice) ?*dx.DxPipeline {
    if (self.id == 0 or self.id >= MAX_SOURCES) return null;
    if (device == null) return null;

    // Look up existing handle for this device.
    const slots = &device_handles[self.id];
    var free_slot: ?usize = null;
    for (slots, 0..) |*slot, idx| {
        if (slot.device == device) return slot.handle;
        if (free_slot == null and slot.device == null) free_slot = idx;
    }

    const src = &sources[self.id];
    if (src.vs == null or src.ps == null) return null;

    // Compile + create on this device.
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

    // Cache for this device.
    if (free_slot) |slot_idx| {
        slots[slot_idx] = .{ .device = device, .handle = h };
    }
    return h;
}

pub fn deinit(self: *const Self) void {
    if (self.id == 0 or self.id >= MAX_SOURCES) return;
    // Destroy all device handles for this source ID.
    const slots = &device_handles[self.id];
    for (slots) |*slot| {
        if (slot.handle) |h| {
            dx.dx_destroy_pipeline(h);
        }
        slot.* = .{};
    }
}
