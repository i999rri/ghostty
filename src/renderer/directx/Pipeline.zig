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

// --- Compiled shader blob cache (device-independent) ---
// D3DCompile output is the same regardless of device, so we cache it
// per source ID to avoid recompilation when creating new tabs/surfaces.

const BlobCache = struct {
    vs_bytecode: ?[*]const u8 = null,
    vs_size: u32 = 0,
    ps_bytecode: ?[*]const u8 = null,
    ps_size: u32 = 0,
};

var blob_cache: [MAX_SOURCES]BlobCache = [_]BlobCache{.{}} ** MAX_SOURCES;

/// Seed the blob cache with precompiled CSO data.
/// This must be called after storeSource so self.id is set.
pub fn seedBlobCache(self: *const Self, vs_cso: []const u8, ps_cso: []const u8) void {
    if (self.id == 0 or self.id >= MAX_SOURCES) return;
    const cache = &blob_cache[self.id];
    cache.vs_bytecode = vs_cso.ptr;
    cache.vs_size = @intCast(vs_cso.len);
    cache.ps_bytecode = ps_cso.ptr;
    cache.ps_size = @intCast(ps_cso.len);
}

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

    // Use cached compiled blobs if available, otherwise compile and cache.
    const cache = &blob_cache[self.id];
    var vs_bytecode = cache.vs_bytecode;
    var vs_size = cache.vs_size;
    var ps_bytecode = cache.ps_bytecode;
    var ps_size = cache.ps_size;

    var vs_compiled: dx.DxCompiledShader = .{ .bytecode = null, .size = 0 };
    var ps_compiled: dx.DxCompiledShader = .{ .bytecode = null, .size = 0 };

    if (vs_bytecode == null or ps_bytecode == null) {
        vs_compiled = dx.dx_compile_shader(src.vs, src.vs_len, "vs_main", "vs_5_0");
        ps_compiled = dx.dx_compile_shader(src.ps, src.ps_len, "ps_main", "ps_5_0");
        if (vs_compiled.bytecode != null and ps_compiled.bytecode != null) {
            // Cache the blobs (they persist for the process lifetime)
            cache.vs_bytecode = @ptrCast(vs_compiled.bytecode);
            cache.vs_size = vs_compiled.size;
            cache.ps_bytecode = @ptrCast(ps_compiled.bytecode);
            cache.ps_size = ps_compiled.size;
            vs_bytecode = cache.vs_bytecode;
            vs_size = cache.vs_size;
            ps_bytecode = cache.ps_bytecode;
            ps_size = cache.ps_size;
        }
    }

    if (vs_bytecode == null or ps_bytecode == null) {
        if (vs_compiled.bytecode != null) dx.dx_free_compiled_shader(vs_compiled);
        if (ps_compiled.bytecode != null) dx.dx_free_compiled_shader(ps_compiled);
        return null;
    }

    const h = switch (self.layout_type) {
        .cell_text => dx.dx_create_cell_text_pipeline(device, @ptrCast(@constCast(vs_bytecode)), vs_size, @ptrCast(@constCast(ps_bytecode)), ps_size),
        .bg_image => dx.dx_create_bg_image_pipeline(device, @ptrCast(@constCast(vs_bytecode)), vs_size, @ptrCast(@constCast(ps_bytecode)), ps_size),
        .image => dx.dx_create_image_pipeline(device, @ptrCast(@constCast(vs_bytecode)), vs_size, @ptrCast(@constCast(ps_bytecode)), ps_size),
        .none => dx.dx_create_pipeline(device, @ptrCast(@constCast(vs_bytecode)), vs_size, @ptrCast(@constCast(ps_bytecode)), ps_size, null, 0),
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
