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
const windows = @import("../os/windows.zig");
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

/// Called from C++ WM_SIZE to update window size without cross-thread deadlock.
/// Thin wrapper needed because Zig DLL only exports Zig `export fn`, not C functions.
export fn dx_notify_resize(w: u32, h: u32) void {
    dx.dx_set_window_size(w, h);
}

/// Set swap chain on a SwapChainPanel. Must be called from UI thread after surface creation.
/// Returns 0 on success.
export fn dx_set_panel_swap_chain(swap_chain_panel: ?*anyopaque) i32 {
    const dev = current_device orelse return -1;
    return dx.dx_set_swap_chain_on_panel(dev, swap_chain_panel);
}

/// Use a native Windows render loop instead of xev.
/// xev's IOCP event loop stalls after D3D11 device creation.
pub const native_render_loop = true;

const log = std.log.scoped(.directx);

/// Global device handle, accessible by Buffer/Texture/etc.
pub var current_device: ?*dx.DxDevice = null;
/// HWND stored from surfaceInit for device creation in threadEnter.
pub var stored_hwnd: ?*anyopaque = null;
/// ISwapChainPanelNative* for WinUI 3 mode (optional).
pub var stored_swap_chain_panel: ?*anyopaque = null;

// C API from d3d11_impl.c — imported via build-system TranslateC for type safety
pub const dx = @import("d3d11-c");

alloc: std.mem.Allocator,
blending: configpkg.Config.AlphaBlending,
last_target: ?Target = null,
device: ?*dx.DxDevice = null,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) error{}!DirectX {
    log.info("initializing DirectX 11 renderer", .{});
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
    };
}

pub fn deinit(self: *DirectX) void {
    if (self.device) |dev| dx.dx_destroy(dev);
    current_device = null;
    stored_hwnd = null;
    stored_swap_chain_panel = null;
    self.* = undefined;
}

pub fn surfaceInit(surface: *apprt.Surface) !void {
    if (comptime builtin.os.tag != .windows) return;
    const hwnd: ?*anyopaque = @ptrCast(surface.platform.windows.hwnd);
    stored_hwnd = hwnd;
    stored_swap_chain_panel = surface.platform.windows.swap_chain_panel;

    // Set initial window size (main thread, safe to call GetClientRect here)
    var rect: windows.exp.RECT = undefined;
    _ = windows.exp.user32.GetClientRect(hwnd, &rect);
    dx.dx_set_window_size(
        @intCast(@max(rect.right - rect.left, 1)),
        @intCast(@max(rect.bottom - rect.top, 1)),
    );
}

pub fn finalizeSurfaceInit(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

const InitError = error{
    HWNDNotSet,
    DeviceCreationFailed,
};

pub fn threadEnter(self: *const DirectX, surface: *apprt.Surface) InitError!void {
    _ = surface;
    const hwnd = stored_hwnd orelse {
        log.err("HWND not set — surfaceInit was not called before threadEnter", .{});
        return error.HWNDNotSet;
    };
    var rect: windows.exp.RECT = undefined;
    _ = windows.exp.user32.GetClientRect(hwnd, &rect);
    const w: u32 = @intCast(@max(rect.right - rect.left, 1));
    const h: u32 = @intCast(@max(rect.bottom - rect.top, 1));

    const use_composition = stored_swap_chain_panel != null;
    const dev = (if (stored_swap_chain_panel != null)
        dx.dx_create_for_composition(hwnd, w, h)
    else
        dx.dx_create_for_hwnd(hwnd, w, h)) orelse {
        if (use_composition)
            log.err("D3D11 device creation failed — CreateSwapChainForComposition or SetSwapChain returned null (invalid ISwapChainPanelNative pointer?)", .{})
        else
            log.err("D3D11 device creation failed — CreateSwapChainForHwnd returned null (invalid HWND or unsupported GPU?)", .{});
        return error.DeviceCreationFailed;
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
    _ = self;
    const dev = current_device orelse return;
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
    _ = self;
    const dev = current_device orelse return;
    dx.dx_present(dev, false);
}

pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    _ = self;
    const dev = current_device orelse return .{ .width = 960, .height = 640 };

    // Read window size set by main thread (WM_SIZE → dx_notify_resize).
    // Cannot call GetClientRect from renderer thread (cross-thread deadlock).
    var ww: u32 = 0;
    var wh: u32 = 0;
    dx.dx_get_window_size(&ww, &wh);
    if (ww > 0 and wh > 0) {
        var bbw: u32 = 0;
        var bbh: u32 = 0;
        dx.dx_get_backbuffer_size(dev, &bbw, &bbh);
        if (bbw != ww or bbh != wh) {
            dx.dx_resize(dev, ww, wh);
        }
        return .{ .width = ww, .height = wh };
    }

    // Fallback to backbuffer size
    var w: u32 = 0;
    var h: u32 = 0;
    dx.dx_get_backbuffer_size(dev, &w, &h);
    if (w == 0 or h == 0) return .{ .width = 960, .height = 640 };
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
