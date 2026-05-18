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

/// DirectX targets a scRGB swap chain (R16G16B16A16_FLOAT + sRGB
/// primaries, linear gamma) on the composition-surface path so DWM
/// color-manages output to the display. That format expects the
/// fragment shader to write linear values, so we force
/// `use_linear_blending = true` regardless of the user's
/// `alpha-blending` config. `native` (sRGB-space) blending would
/// require an extra unlinearize at the end of every fragment shader —
/// not implemented.
pub const force_linear_blending = true;

/// Called by the renderer when occlusion changes. Toggles the
/// DirectComposition visual so the GPU can stop compositing hidden surfaces.
/// Safe to call from the renderer thread.
pub fn setVisible(self: *DirectX, visible: bool) void {
    const dev = self.presentation.device orelse return;
    dx.dx_set_visible(dev, visible);
}

/// Returns the IDXGISwapChain1* for SwapChainPanel integration.
/// Returns null if no device exists. Caller does NOT own the reference.
pub fn getSwapChain(self: *DirectX) ?*anyopaque {
    const dev = self.presentation.device orelse return null;
    return dx.dx_get_swap_chain(dev);
}

/// Called from the apprt updateSize path (main thread) to update the
/// device's window size synchronously. This avoids the renderer thread
/// needing to do a cross-thread GetClientRect on the HWND.
/// Writes an atomic field; safe from any thread.
pub fn notifyResize(self: *DirectX, w: u32, h: u32) void {
    const dev = self.presentation.device orelse return;
    dx.dx_set_window_size(dev, w, h);
}

/// Use a native Windows render loop instead of xev.
/// xev's IOCP event loop stalls after D3D11 device creation.
pub const native_render_loop = true;

const log = std.log.scoped(.directx);

// C API from d3d11_impl.c — imported via build-system TranslateC for type safety
pub const dx = @import("d3d11-c");

alloc: std.mem.Allocator,
blending: configpkg.Config.AlphaBlending,
last_target: ?Target = null,

/// Heap-allocated runtime state for this surface's renderer.
///
/// HELP NAMING: tentative — picked because the D3D11 domain term for
/// "submit a frame to the screen" is Present, and this struct collects
/// everything needed to do that for one surface (the device that
/// produces frames, plus the callback that fires after the first Present
/// completes). If a clearer noun for "the runtime resources tied to one
/// surface's renderer thread" comes to mind, rename freely — the
/// concept and the lifetime are what matter, not the label.
///
/// Why heap-allocated:
///   1. Address stability across the value-moves of `DirectX` that
///      happen during `Renderer.init`. Buffer/Texture/Sampler instances
///      created in `FrameState.init` capture `&presentation.device` as
///      their late-binding cell pointer; `threadEnter` later writes
///      the real device pointer into that same cell on the renderer
///      thread, and every consumer sees the value through the shared
///      pointer.
///   2. Avoids `@constCast(self)` in `threadEnter`. The renderer
///      contract gives us `*const DirectX`, but we need to write the
///      device and the readiness callback when the renderer thread
///      first runs. Writing through `self.presentation.*` goes through
///      the pointer, not through the const struct, so it's spec-clean.
presentation: *Presentation = undefined,

/// HELP NAMING: see the comment on the `presentation` field above.
const Presentation = struct {
    /// The active D3D11 device for this surface, or null until
    /// `threadEnter` has run on the renderer thread.
    device: ?*dx.DxDevice = null,

    /// "First present completed" callback. Fired exactly once:
    /// either after the renderer's first real `dx_present`
    /// (drawFrameEnd), or from `DirectX.deinit` if no frame was ever
    /// presented (e.g. a surface that was created and destroyed too
    /// fast). The "first present" semantic lets the host defer making
    /// the SwapChainPanel visible until the swap chain actually has
    /// content.
    ready_cb: ?*const fn (?*anyopaque) callconv(.c) void = null,
    ready_userdata: ?*anyopaque = null,
    ready_fired: bool = false,
};

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !DirectX {
    log.info("initializing DirectX 11 renderer", .{});
    const presentation = try alloc.create(Presentation);
    presentation.* = .{};
    return .{
        .alloc = alloc,
        .blending = opts.config.blending,
        .presentation = presentation,
    };
}

pub fn deinit(self: *DirectX) void {
    // If no frame was ever presented, fire the ready callback here so
    // the host can clean up its userdata. Without this, a tab opened
    // and immediately closed would leak whatever the host attached to
    // ready_userdata. The host's implementation should already handle
    // "fired but tab is being torn down" via its own cancel mechanism
    // (see GhosttyWin32 SwapChainAttachRequest::cancelled).
    if (!self.presentation.ready_fired) {
        self.presentation.ready_fired = true;
        if (self.presentation.ready_cb) |cb| {
            cb(self.presentation.ready_userdata);
        }
    }
    if (self.presentation.device) |dev| {
        // Drop every Pipeline cache entry that was compiled against this
        // device BEFORE we destroy the device itself. Skipping this step
        // leaves stale (device_ptr, pipeline*) slots in Pipeline.zig's
        // global cache; if the heap allocator later hands a new device
        // the same address, getHandle would match the dead slot and
        // return a pipeline whose underlying ID3D11VertexShader/PixelShader
        // belongs to the destroyed device — which trips the
        // "First parameter does not match device" D3D11 corruption seen
        // when many tabs are torn down in sequence.
        Pipeline.invalidateDevice(dev);
        dx.dx_destroy(dev);
    }
    self.alloc.destroy(self.presentation);
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

    // We never mutate `self` directly — every write goes through the
    // `presentation` pointer into heap memory, so the renderer's
    // `*const DirectX` contract holds without `@constCast`.

    // If a device already exists, this call is from Surface.deinit on the
    // UI thread ("become the active rendering thread again") purely to
    // satisfy the lifecycle contract — Buffer/Texture/Sampler read their
    // device from `self.presentation.device` directly, so no thread-local
    // fixup is needed. Mirror OpenGL.zig's wglMakeCurrent semantics —
    // attach to the existing device, no D3D churn. Without this short-
    // circuit, every tab close would waste one D3D11CreateDevice +
    // dx_destroy pair (driver alloc/free at 2x the rate it would
    // otherwise be), which crashes NVIDIA's user-mode driver under stress.
    if (self.presentation.device != null) return;

    const hwnd: ?*anyopaque = @ptrCast(surface.platform.windows.hwnd);
    if (hwnd == null) {
        log.err("HWND not set on surface — surfaceInit was not called", .{});
        return error.HWNDNotSet;
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
    const used_composition_surface = platform.composition_surface_handle != null;
    const dev = if (used_composition_surface)
        dx.dx_create_for_composition_surface(platform.composition_surface_handle, w, h)
    else if (platform.d3d_device != null and platform.swap_chain != null)
        dx.dx_create_from_swap_chain(platform.d3d_device, platform.swap_chain, w, h)
    else
        dx.dx_create(hwnd, w, h);
    if (dev == null) return;
    self.presentation.device = dev;
    dx.dx_set_window_size(dev, w, h);

    // Composition-surface path: stash the host's "ready" callback so we
    // can fire it once the renderer has actually presented its first
    // frame (see drawFrameEnd). Firing here at swap-chain-creation would
    // be premature — the back buffer is undefined memory until the first
    // present, so the host attaching it to a panel would briefly composite
    // garbage / transparency. By deferring, the host can wait until the
    // swap chain has displayable content before making the panel visible.
    if (used_composition_surface) {
        self.presentation.ready_cb = platform.swap_chain_ready_cb;
        self.presentation.ready_userdata = platform.swap_chain_ready_userdata;
    }
}

pub fn threadExit(self: *const DirectX) void {
    _ = self;
}

pub fn displayRealized(self: *const DirectX) void {
    _ = self;
}

pub fn drawFrameStart(self: *DirectX) void {
    const dev = self.presentation.device orelse return;
    // Wait for DXGI to be ready for the next frame. Throttles CPU based
    // on GPU/composition pace. No-op for swap chains without waitable.
    dx.dx_wait_frame_latency(dev);
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
    const dev = self.presentation.device orelse return;
    // VSync to match SwapChainPanel/DComp composition cadence.
    // With FRAME_LATENCY_WAITABLE_OBJECT, vsync prevents tearing/flicker.
    dx.dx_present(dev, true);

    // First-present notification. The swap chain back buffer is undefined
    // memory until something is presented, so we wait until here — after
    // the first real frame is on screen — to tell the host its panel can
    // be made visible without flicker. Fired exactly once per surface.
    if (!self.presentation.ready_fired) {
        self.presentation.ready_fired = true;
        if (self.presentation.ready_cb) |cb| {
            cb(self.presentation.ready_userdata);
        }
    }
}

pub fn surfaceSize(self: *const DirectX) !struct { width: u32, height: u32 } {
    const dev = self.presentation.device orelse return .{ .width = 960, .height = 640 };

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
    const format: Texture.Options.Format = switch (atlas.format) {
        .grayscale => .red,
        .bgra => .bgra,
        else => @panic("unsupported atlas format for DirectX texture"),
    };
    return Texture.init(
        .{ .device_cell = &self.presentation.device, .format = format },
        atlas.size,
        atlas.size,
        atlas.data,
    );
}

pub fn initTexture(self: *const DirectX, opts: anytype) !Texture {
    return Texture.init(.{ .device_cell = &self.presentation.device }, opts.width, opts.height, opts.data);
}

pub inline fn bufferOptions(self: DirectX) bufferpkg.Options {
    return .{ .device_cell = &self.presentation.device, .target = .array, .usage = .dynamic_draw };
}

pub inline fn uniformBufferOptions(self: DirectX) bufferpkg.Options {
    return .{ .device_cell = &self.presentation.device, .target = .uniform, .usage = .dynamic_draw };
}

pub inline fn fgBufferOptions(self: DirectX) bufferpkg.Options {
    // In D3D11, foreground cell data is used as vertex buffer (per-instance)
    return .{ .device_cell = &self.presentation.device, .target = .array, .usage = .dynamic_draw };
}

pub inline fn bgBufferOptions(self: DirectX) bufferpkg.Options {
    return .{ .device_cell = &self.presentation.device, .target = .shader_storage, .usage = .dynamic_draw };
}

pub inline fn bgImageBufferOptions(self: DirectX) bufferpkg.Options {
    return .{ .device_cell = &self.presentation.device, .target = .array, .usage = .dynamic_draw };
}

pub inline fn imageBufferOptions(self: DirectX) bufferpkg.Options {
    return .{ .device_cell = &self.presentation.device, .target = .array, .usage = .dynamic_draw };
}

pub inline fn imageTextureOptions(self: DirectX, format: anytype, linear: bool) Texture.Options {
    _ = format;
    _ = linear;
    return .{ .device_cell = &self.presentation.device };
}

pub inline fn textureOptions(self: DirectX) Texture.Options {
    return .{ .device_cell = &self.presentation.device };
}

pub inline fn samplerOptions(self: DirectX) Sampler.Options {
    return .{ .device_cell = &self.presentation.device };
}
