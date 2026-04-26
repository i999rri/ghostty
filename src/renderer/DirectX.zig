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

/// Called by the renderer when occlusion changes. Toggles the
/// DirectComposition visual so the GPU can stop compositing hidden surfaces.
/// Safe to call from the renderer thread.
pub fn setVisible(self: *DirectX, visible: bool) void {
    const dev = self.device orelse return;
    dx.dx_set_visible(dev, visible);
}

/// Returns the IDXGISwapChain1* for SwapChainPanel integration.
/// Returns null if no device exists. Caller does NOT own the reference.
pub fn getSwapChain(self: *DirectX) ?*anyopaque {
    const dev = self.device orelse return null;
    return dx.dx_get_swap_chain(dev);
}

/// Called from the apprt updateSize path (main thread) to update the
/// device's window size synchronously. This avoids the renderer thread
/// needing to do a cross-thread GetClientRect on the HWND.
/// Writes an atomic field; safe from any thread.
pub fn notifyResize(self: *DirectX, w: u32, h: u32) void {
    const dev = self.device orelse return;
    dx.dx_set_window_size(dev, w, h);
}

/// Use a native Windows render loop instead of xev.
/// xev's IOCP event loop stalls after D3D11 device creation.
pub const native_render_loop = true;

const log = std.log.scoped(.directx);

/// Per-thread device handle, accessible by Buffer/Texture/etc.
/// Each renderer thread sets its own copy in threadEnter.
pub threadlocal var current_device: ?*dx.DxDevice = null;

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
    self.device = null;
    // Clear the calling thread's threadlocal device pointer. Surface.deinit
    // calls renderer.threadEnter(rt_surface) on its own (non-renderer) thread
    // before invoking renderer.deinit, which sets current_device for that
    // thread to a fresh device. Without clearing here, that thread keeps a
    // dangling pointer to a freed device — the next surface's Renderer.init
    // running on the same thread reads it via Texture.init/Buffer.init and
    // crashes inside dx_create_texture / dx_create_buffer.
    current_device = null;
    self.* = undefined;
}

pub fn surfaceInit(surface: *apprt.Surface) !void {
    _ = surface;
    // Device creation and initial window size are handled in threadEnter.
}

pub fn finalizeSurfaceInit(self: *const DirectX, surface: *apprt.Surface) !void {
    _ = self;
    _ = surface;
}

pub fn threadEnter(self: *const DirectX, surface: *apprt.Surface) !void {
    if (comptime builtin.os.tag != .windows) return;
    const hwnd: ?*anyopaque = @ptrCast(surface.platform.windows.hwnd);
    if (hwnd == null) {
        log.err("HWND not set on surface — surfaceInit was not called", .{});
        return error.HWNDNotSet;
    }

    // Destroy any existing device first — DXGI flip-model only allows one
    // swap chain per HWND, so we must tear down the old one before creating
    // a new one (e.g. if threadEnter is called again after threadExit).
    const self_mut: *DirectX = @constCast(self);
    if (self_mut.device) |old| {
        dx.dx_destroy(old);
        self_mut.device = null;
        current_device = null;
    }

    const platform = surface.platform.windows;

    // Prefer caller-provided size (e.g. SwapChainPanel ActualWidth/Height) so
    // the swap chain is created at its final size from the start. Falls back
    // to the parent HWND's client rect when not supplied. Avoids an
    // immediate ResizeBuffers on the first frame.
    const w: u32, const h: u32 = blk: {
        if (platform.initial_width > 0 and platform.initial_height > 0) {
            break :blk .{ platform.initial_width, platform.initial_height };
        }
        var rect: windows.exp.RECT = undefined;
        _ = windows.exp.user32.GetClientRect(hwnd, &rect);
        break :blk .{
            @as(u32, @intCast(@max(rect.right - rect.left, 1))),
            @as(u32, @intCast(@max(rect.bottom - rect.top, 1))),
        };
    };

    // Three creation paths, in priority order:
    //  1. composition_surface_handle: ghostty owns device+swap chain on this
    //     thread (SINGLETHREADED, matches Windows Terminal AtlasEngine).
    //     Required for stable rendering on NVIDIA with SwapChainPanel.
    //  2. d3d_device + swap_chain: caller-provided externals (legacy path).
    //  3. hwnd only: ghostty creates its own DComp visual (standalone mode).
    const dev = if (platform.composition_surface_handle != null)
        dx.dx_create_for_composition_surface(platform.composition_surface_handle, w, h)
    else if (platform.d3d_device != null and platform.swap_chain != null)
        dx.dx_create_from_swap_chain(platform.d3d_device, platform.swap_chain, w, h)
    else
        dx.dx_create(hwnd, w, h);
    if (dev == null) return;
    self_mut.device = dev;
    current_device = dev;
    dx.dx_set_window_size(dev, w, h);
}

pub fn threadExit(self: *const DirectX) void {
    _ = self;
}

pub fn displayRealized(self: *const DirectX) void {
    _ = self;
}

pub fn drawFrameStart(self: *DirectX) void {
    const dev = self.device orelse return;
    // Wait for DXGI to be ready for the next frame. Throttles CPU based
    // on GPU/composition pace. No-op for swap chains without waitable.
    dx.dx_wait_frame_latency(dev);
    current_device = dev; // sync for Buffer/Texture/Sampler
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
    const dev = self.device orelse return;
    // VSync to match SwapChainPanel/DComp composition cadence.
    // With FRAME_LATENCY_WAITABLE_OBJECT, vsync prevents tearing/flicker.
    dx.dx_present(dev, true);
}

pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    const dev = self.device orelse return .{ .width = 960, .height = 640 };

    // Read window size set by main thread (WM_SIZE → dx_notify_resize).
    // Cannot call GetClientRect from renderer thread (cross-thread deadlock).
    var ww: u32 = 0;
    var wh: u32 = 0;
    dx.dx_get_window_size(dev, &ww, &wh);
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
