//! Graphics API wrapper for DirectX 11.
//! This is a native Windows renderer that translates the Ghostty renderer
//! interface to Direct3D 11 API calls.
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
// DirectX uses Y-down coordinate system (same as Metal)
pub const custom_shader_y_is_down = true;

/// DirectX uses a swap chain for presentation (double buffering)
pub const swap_chain_count = 2;

const log = std.log.scoped(.directx);

alloc: std.mem.Allocator,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The most recently presented target
last_target: ?Target = null,

// TODO: Direct3D 11 resources
// device: *ID3D11Device,
// context: *ID3D11DeviceContext,
// swap_chain: *IDXGISwapChain,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!DirectX {
    log.info("initializing DirectX 11 renderer", .{});
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *DirectX) void {
    self.* = undefined;
}

pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
    // TODO: Create D3D11 device and swap chain from HWND
    log.info("DirectX surface init", .{});
}

pub fn finalizeSurfaceInit(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
    // TODO: D3D11 is single-threaded by default, may need deferred context
}

pub fn threadExit(self: *const DirectX) void {
    _ = self;
}

pub fn displayRealized(self: *const DirectX) void {
    _ = self;
}

pub fn drawFrameStart(self: *DirectX) void {
    _ = self;
    // TODO: Begin frame, clear render target
}

pub fn drawFrameEnd(self: *DirectX) void {
    _ = self;
    // TODO: Present swap chain
}

pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    _ = self;
    // TODO: Query swap chain back buffer size
    return .{ .width = 960, .height = 640 };
}

pub fn initShaders(
    self: *const DirectX,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    _ = self;
    return try shaders.Shaders.init(alloc, custom_shaders);
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
    // TODO: Present to swap chain
}

pub fn presentLastTarget(self: *DirectX) !void {
    _ = self;
    // TODO: Re-present previous frame
}

pub fn initAtlasTexture(self: *const DirectX, atlas: anytype) !Texture {
    _ = self;
    const format: Texture.Options.Format = switch (atlas.format) {
        .grayscale => .red,
        .bgra => .bgra,
        else => .rgba,
    };
    return Texture.init(.{
        .format = format,
    }, atlas.size, atlas.size, atlas.data);
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
    return .{ .target = .shader_storage, .usage = .dynamic_draw };
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
