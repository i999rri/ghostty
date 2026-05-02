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
//
// All access to `sources`, `next_id`, `device_handles`, and `blob_cache`
// must be guarded by `pipeline_mutex` — every renderer thread (one per
// surface) hits these arrays concurrently for getHandle/storeSource and
// during teardown for invalidateDevice. Without the mutex, two renderers
// racing on the same free slot would each create a pipeline and only one
// would be cached (the other leaks), and a teardown can clear a slot
// mid-scan in another thread's getHandle.

const MAX_DEVICES = 8;

const DeviceHandle = struct {
    device: ?*dx.DxDevice = null,
    handle: ?*dx.DxPipeline = null,
};

var pipeline_mutex: std.Thread.Mutex = .{};

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
    pipeline_mutex.lock();
    defer pipeline_mutex.unlock();
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
    pipeline_mutex.lock();
    defer pipeline_mutex.unlock();
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

    pipeline_mutex.lock();
    defer pipeline_mutex.unlock();

    // Look up existing handle for this device.
    const slots = &device_handles[self.id];
    var free_slot: ?usize = null;
    for (slots, 0..) |*slot, idx| {
        if (slot.device == device) return slot.handle;
        if (free_slot == null and slot.device == null) free_slot = idx;
    }

    // Use precompiled shader blobs (CSO). No runtime D3DCompile.
    const cache = &blob_cache[self.id];
    const vs_bytecode = cache.vs_bytecode orelse return null;
    const vs_size = cache.vs_size;
    const ps_bytecode = cache.ps_bytecode orelse return null;
    const ps_size = cache.ps_size;

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
    // No-op: the pipeline cache is keyed by device, not by Pipeline
    // instance, so cleanup happens in invalidateDevice() driven from
    // DirectX.deinit (one call per dying device). Leaving this method
    // in place so Shaders.deinit can still call it generically across
    // backends.
    _ = self;
}

/// Drop every cached pipeline created against `device` and free their
/// underlying D3D11 shader objects. Called from DirectX.deinit just
/// before the device itself is destroyed, so any future device that
/// ends up with the same heap address can never see a stale handle
/// from the previous lifetime.
pub fn invalidateDevice(device: ?*dx.DxDevice) void {
    if (device == null) return;
    pipeline_mutex.lock();
    defer pipeline_mutex.unlock();
    var i: usize = 0;
    while (i < MAX_SOURCES) : (i += 1) {
        for (&device_handles[i]) |*slot| {
            if (slot.device == device) {
                if (slot.handle) |h| dx.dx_destroy_pipeline(h);
                slot.* = .{};
            }
        }
    }
}
