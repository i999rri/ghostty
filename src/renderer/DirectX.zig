//! Graphics API wrapper for DirectX 11.
//! Uses a C implementation (d3d11_impl.c) for the COM-based D3D11 API.
pub const DirectX = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const shadertoy = @import("shadertoy.zig");
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(DirectX);

pub const GraphicsAPI = DirectX;
pub const Target = @import("directx/Target.zig");
pub const Frame = @import("directx/Frame.zig");
pub const RenderPass = @import("directx/RenderPass.zig");
pub const Pipeline = @import("directx/Pipeline.zig");
const bufferpkg = @import("directx/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("directx/Sampler.zig");
pub const Texture = @import("directx/Texture.zig");
pub const shaders = @import("directx/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .glsl;
pub const custom_shader_y_is_down = true;
pub const swap_chain_count = 2;

const log = std.log.scoped(.directx);

/// Global device handle, accessible by Buffer/Texture/etc.
pub var current_device: ?*anyopaque = null;
/// HWND stored from surfaceInit for device creation in threadEnter.
var stored_hwnd: ?*anyopaque = null;

// C API from d3d11_impl.c
pub const dx = struct {
    pub extern fn dx_create(?*anyopaque, u32, u32) ?*anyopaque;
    pub extern fn dx_destroy(?*anyopaque) void;
    pub extern fn dx_resize(?*anyopaque, u32, u32) void;
    pub extern fn dx_present(?*anyopaque, bool) void;
    pub extern fn dx_clear(?*anyopaque, f32, f32, f32, f32) void;
    pub extern fn dx_set_viewport(?*anyopaque, u32, u32) void;
    pub extern fn dx_bind_backbuffer(?*anyopaque) void;
    pub extern fn dx_set_blend_enabled(?*anyopaque, bool) void;
    pub extern fn dx_clear_shader_resources(?*anyopaque) void;
    pub extern fn dx_ensure_default_sampler(?*anyopaque) void;
    pub extern fn dx_get_backbuffer_size(?*anyopaque, *u32, *u32) void;
    pub extern fn dx_draw(?*anyopaque, u32, u32, u32) void;
    pub extern fn dx_draw_instanced(?*anyopaque, u32, u32, u32, u32, u32) void;
    pub extern fn dx_test_draw(?*anyopaque) void;

    pub const CompiledShader = extern struct { bytecode: ?*anyopaque, size: u32 };
    pub extern fn dx_compile_shader(?[*]const u8, u32, [*:0]const u8, [*:0]const u8) CompiledShader;
    pub extern fn dx_free_compiled_shader(CompiledShader) void;

    pub extern fn dx_create_buffer(?*anyopaque, u32, u32, ?*const anyopaque) ?*anyopaque;
    pub extern fn dx_destroy_buffer(?*anyopaque) void;
    pub extern fn dx_update_buffer(?*anyopaque, ?*anyopaque, ?*const anyopaque, u32) void;
    pub extern fn dx_bind_vertex_buffer(?*anyopaque, ?*anyopaque, u32, u32) void;
    pub extern fn dx_bind_constant_buffer(?*anyopaque, ?*anyopaque, u32, bool, bool) void;
    pub extern fn dx_bind_srv_buffer(?*anyopaque, ?*anyopaque, u32, u32) void;

    pub extern fn dx_create_texture(?*anyopaque, u32, u32, u32, ?*const anyopaque) ?*anyopaque;
    pub extern fn dx_destroy_texture(?*anyopaque) void;
    pub extern fn dx_update_texture_region(?*anyopaque, ?*anyopaque, u32, u32, u32, u32, ?*const anyopaque) void;
    pub extern fn dx_bind_texture(?*anyopaque, ?*anyopaque, u32) void;

    pub extern fn dx_create_sampler(?*anyopaque, u32, u32) ?*anyopaque;
    pub extern fn dx_destroy_sampler(?*anyopaque) void;
    pub extern fn dx_bind_sampler(?*anyopaque, ?*anyopaque, u32) void;

    pub extern fn dx_create_pipeline(?*anyopaque, ?*anyopaque, u32, ?*anyopaque, u32, ?*anyopaque, u32) ?*anyopaque;
    pub extern fn dx_create_cell_text_pipeline(?*anyopaque, ?*anyopaque, u32, ?*anyopaque, u32) ?*anyopaque;
    pub extern fn dx_create_bg_image_pipeline(?*anyopaque, ?*anyopaque, u32, ?*anyopaque, u32) ?*anyopaque;
    pub extern fn dx_create_image_pipeline(?*anyopaque, ?*anyopaque, u32, ?*anyopaque, u32) ?*anyopaque;
    pub extern fn dx_destroy_pipeline(?*anyopaque) void;
    pub extern fn dx_bind_pipeline(?*anyopaque, ?*anyopaque) void;

    pub extern fn dx_create_render_target(?*anyopaque, u32, u32, u32) ?*anyopaque;
    pub extern fn dx_destroy_render_target(?*anyopaque) void;
    pub extern fn dx_bind_render_target(?*anyopaque, ?*anyopaque) void;
};

alloc: std.mem.Allocator,
blending: configpkg.Config.AlphaBlending,
last_target: ?Target = null,
device: ?*anyopaque = null,
frame_rendered: bool = false,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!DirectX {
    log.info("initializing DirectX 11 renderer", .{});
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *DirectX) void {
    if (self.device) |dev| dx.dx_destroy(dev);
    self.* = undefined;
}

pub fn surfaceInit(surface: *apprt.Surface) !void {
    // Store HWND for device creation in threadEnter (must be on renderer thread).
    if (comptime builtin.os.tag != .windows) return;
    stored_hwnd = @ptrCast(surface.platform.windows.hwnd);
}

pub fn finalizeSurfaceInit(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = surface;
    // Create D3D11 device on renderer thread. The immediate context
    // must only be used from this thread.
    const hwnd = stored_hwnd orelse return;
    const w32 = struct {
        const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
        extern "user32" fn GetClientRect(?*anyopaque, *RECT) callconv(.winapi) i32;
    };
    var rect: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &rect);
    const w: u32 = @intCast(rect.right - rect.left);
    const h: u32 = @intCast(rect.bottom - rect.top);

    const dev = dx.dx_create(hwnd, w, h) orelse {
        return error.DirectXFailed;
    };
    const self_mut: *DirectX = @constCast(self);
    self_mut.device = dev;
    current_device = dev;
}

pub fn threadExit(self: *const DirectX) void {
    _ = self;
}

pub fn displayRealized(self: *const DirectX) void {
    _ = self;
}

pub fn drawFrameStart(self: *DirectX) void {
    self.frame_rendered = false;
    // Use global device - self.device may not persist due to value copy semantics
    const dev = current_device orelse return;
    self.device = dev;
    var w: u32 = 0;
    var h: u32 = 0;
    dx.dx_get_backbuffer_size(dev, &w, &h);
    dx.dx_set_viewport(dev, w, h);
    dx.dx_bind_backbuffer(dev);
    dx.dx_set_blend_enabled(dev, false);
    dx.dx_ensure_default_sampler(dev);
    dx.dx_clear(dev, 0.0, 0.0, 0.0, 1.0);
}

pub fn drawFrameEnd(self: *DirectX) void {
    const dev = current_device orelse return;
    self.frame_rendered = true;
    dx.dx_present(dev, false);
}

pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    _ = self;
    const dev = current_device orelse return .{ .width = 960, .height = 640 };
    var w: u32 = 0;
    var h: u32 = 0;
    dx.dx_get_backbuffer_size(dev, &w, &h);
    return .{ .width = w, .height = h };
}

pub fn initShaders(
    _: *const DirectX,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    var s = try shaders.Shaders.init(alloc, custom_shaders);
    s.storeSource();
    // Device objects created later in threadEnter via drawFrameStart
    return s;
}

pub fn initTarget(self: *const DirectX, width: usize, height: usize) !Target {
    return Target.init(.{
        .internal_format = if (self.blending.isLinear()) .srgba else .rgba,
        .width = width,
        .height = height,
    });
}

pub fn beginFrame(self: *DirectX, renderer: *Renderer, target: *Target) !Frame {
    _ = self;
    return Frame.begin(renderer, target);
}

pub fn present(self: *DirectX, target: Target) !void {
    self.last_target = target;
}

pub fn presentLastTarget(self: *DirectX) !void {
    // With DXGI_SWAP_EFFECT_DISCARD, backbuffer content is undefined after Present.
    // We can't re-present the last frame. Just present what's there.
    // The real fix is to always redraw, but for now this avoids a second Present call.
    _ = self;
}

pub fn initAtlasTexture(self: *const DirectX, atlas: anytype) !Texture {
    _ = self;
    const format: Texture.Options.Format = switch (atlas.format) {
        .grayscale => .red,
        .bgra => .bgra,
        else => .rgba,
    };
    return Texture.init(.{ .format = format }, atlas.size, atlas.size, atlas.data);
}

pub fn initTexture(self: *const DirectX, opts: anytype) !Texture {
    _ = self;
    return Texture.init(.{}, opts.width, opts.height, opts.data);
}

pub inline fn bufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    return .{ .target = .array, .usage = .dynamic_draw };
}

pub inline fn uniformBufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    return .{ .target = .uniform, .usage = .dynamic_draw };
}

pub inline fn fgBufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    // In D3D11, foreground cell data is used as vertex buffer (per-instance)
    return .{ .target = .array, .usage = .dynamic_draw };
}

pub inline fn bgBufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    return .{ .target = .shader_storage, .usage = .dynamic_draw };
}

pub inline fn bgImageBufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    return .{ .target = .array, .usage = .dynamic_draw };
}

pub inline fn imageBufferOptions(self: DirectX) bufferpkg.Options {
    _ = self;
    return .{ .target = .array, .usage = .dynamic_draw };
}

pub inline fn imageTextureOptions(self: DirectX, format: anytype, linear: bool) Texture.Options {
    _ = self;
    _ = format;
    _ = linear;
    return .{};
}

pub inline fn textureOptions(self: DirectX) Texture.Options {
    _ = self;
    return .{};
}

pub inline fn samplerOptions(self: DirectX) Sampler.Options {
    _ = self;
    return .{};
}
