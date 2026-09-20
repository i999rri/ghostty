const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;
const log = std.log.scoped(.directx);

const Self = @This();

pub const Error = error{DirectXFailed};

pub const Options = struct {
    /// Pointer to the renderer's heap-allocated device cell.
    ///
    /// Same rationale as `buffer.Options.device_cell`: textures are
    /// constructed during `FrameState.init` before the D3D11 device
    /// has been created in `threadEnter`, so we hold a stable pointer
    /// to the cell and dereference it at create / `replaceRegion`
    /// time instead of capturing the `null` value that was sitting in
    /// the cell at init time.
    device_cell: ?*const ?*dx.DxDevice = null,
    format: Format = .rgba,
    internal_format: InternalFormat = .rgba,
    target: TextureTarget = .texture_2d,
    min_filter: MinFilter = .linear,
    mag_filter: MagFilter = .linear,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,

    pub const Format = enum { rgba, bgra, red, red_integer };
    pub const InternalFormat = enum { rgba, srgba, red, r8, r32ui };
    pub const TextureTarget = enum { texture_2d, texture_2d_array, texture_rectangle };
    pub const MinFilter = enum { nearest, linear };
    pub const MagFilter = enum { nearest, linear };
    pub const Wrap = enum { clamp_to_edge, repeat };
};

// DXGI formats
const DXGI_FORMAT_R8G8B8A8_UNORM: u32 = 28;
const DXGI_FORMAT_B8G8R8A8_UNORM: u32 = 87;
const DXGI_FORMAT_R8_UNORM: u32 = 61;

fn dxgiFormat(format: Options.Format) u32 {
    return switch (format) {
        .rgba => DXGI_FORMAT_R8G8B8A8_UNORM,
        .bgra => DXGI_FORMAT_B8G8R8A8_UNORM,
        .red => DXGI_FORMAT_R8_UNORM,
        .red_integer => DXGI_FORMAT_R8_UNORM,
    };
}

/// Bytes per pixel for a given format. Mirrors the bpp logic in
/// `d3d11_impl.c::dx_create_texture`. Lifted to Zig so the same
/// arithmetic can be unit-tested without spinning up D3D11.
pub fn bytesPerPixel(format: Options.Format) u32 {
    return switch (format) {
        .rgba, .bgra => 4,
        .red, .red_integer => 1,
    };
}

/// Pure function: validate that `data` is large enough to back a
/// texture of the given size and format. Returns the exact byte
/// count the GPU is going to read on `CreateTexture2D` /
/// `UpdateSubresource`.
///
/// This exists for the same reason `buffer.planSync` exists — D3D11
/// reads `height * width * bpp` bytes from the supplied pointer with
/// no way to bound the read. Calling it with a too-short buffer
/// causes the driver to walk past the allocation and AV inside
/// `nvwgf2umx.dll` (same bug class as the buffer over-read fixed in
/// 85e6e936b). Codifying the size relationship as a single function
/// — and asserting `data.len >= bytes_required` here — turns the
/// failure into a typed error at the boundary instead of a silent
/// driver crash.
pub const UploadError = error{
    InsufficientData,
    DimensionOverflow,
};

pub fn planTextureUpload(
    format: Options.Format,
    width: u32,
    height: u32,
    data_len: usize,
) UploadError!u32 {
    const bpp = bytesPerPixel(format);
    // Use checked u32 arithmetic — width * height * bpp can plausibly
    // exceed 2^32 if a caller passes garbage, and we never want to
    // wrap and then pass a truncated size to the GPU.
    const wh = std.math.mul(u32, width, height) catch
        return UploadError.DimensionOverflow;
    const required = std.math.mul(u32, wh, bpp) catch
        return UploadError.DimensionOverflow;
    if (data_len < required) return UploadError.InsufficientData;
    return required;
}

width: usize,
height: usize,
/// Stashed so `replaceRegion` can recompute `bytes_per_pixel` without
/// the caller re-supplying it. Set from `Options.format` at init.
format: Options.Format = .rgba,
/// Stash the cell pointer from Options so `replaceRegion` can read
/// the current device without re-deriving it. The cell itself lives
/// in the renderer; we only hold the pointer.
device_cell: ?*const ?*dx.DxDevice = null,
dx_handle: ?*dx.DxTexture = null,

pub fn init(opts: Options, width: usize, height: usize, data: ?[]const u8) Error!Self {
    const dev: ?*dx.DxDevice = if (opts.device_cell) |cell| cell.* else null;
    var handle: ?*dx.DxTexture = null;

    if (dev != null and width > 0 and height > 0) {
        const w32: u32 = @intCast(width);
        const h32: u32 = @intCast(height);
        const data_ptr: ?*const anyopaque, const data_len: u32 = if (data) |d| blk: {
            // Validate that the slice covers a full texture's worth of
            // bytes for this format. On mismatch we refuse to call the
            // C side rather than letting D3D11 over-read.
            _ = planTextureUpload(opts.format, w32, h32, d.len) catch |err| {
                log.err("dx_create_texture skipped: {}x{} format={s} data.len={} err={s}", .{
                    width, height, @tagName(opts.format), d.len, @errorName(err),
                });
                break :blk .{ null, 0 };
            };
            break :blk .{ @ptrCast(d.ptr), @intCast(d.len) };
        } else .{ null, 0 };
        handle = dx.dx_create_texture(dev, w32, h32, dxgiFormat(opts.format), data_ptr, data_len);
        if (handle == null) log.err("dx_create_texture failed: {}x{}", .{ width, height });
    }

    return .{
        .width = width,
        .height = height,
        .format = opts.format,
        .device_cell = opts.device_cell,
        .dx_handle = handle,
    };
}

pub fn deinit(self: Self) void {
    if (self.dx_handle) |h| dx.dx_destroy_texture(h);
}

pub fn replaceRegion(self: *Self, offset_x: usize, offset_y: usize, rep_width: usize, rep_height: usize, data: []const u8) !void {
    const cell = self.device_cell orelse return;
    const dev = cell.* orelse return;
    const w32: u32 = @intCast(rep_width);
    const h32: u32 = @intCast(rep_height);
    _ = planTextureUpload(self.format, w32, h32, data.len) catch |err| {
        log.err("dx_update_texture_region skipped: region={}x{} format={s} data.len={} err={s}", .{
            rep_width, rep_height, @tagName(self.format), data.len, @errorName(err),
        });
        return;
    };
    if (self.dx_handle) |h| {
        dx.dx_update_texture_region(dev, h, @intCast(offset_x), @intCast(offset_y), w32, h32, @ptrCast(data.ptr), @intCast(data.len));
    }
}

// -- planTextureUpload tests -------------------------------------------------
// These tests pin down the size arithmetic the same way `planSync` tests pin
// down `buffer.planSync`. They run on any platform because they never touch
// D3D11.

test "bytesPerPixel: rgba and bgra are 4 bytes" {
    try std.testing.expectEqual(@as(u32, 4), bytesPerPixel(.rgba));
    try std.testing.expectEqual(@as(u32, 4), bytesPerPixel(.bgra));
}

test "bytesPerPixel: red formats are 1 byte" {
    try std.testing.expectEqual(@as(u32, 1), bytesPerPixel(.red));
    try std.testing.expectEqual(@as(u32, 1), bytesPerPixel(.red_integer));
}

test "planTextureUpload: rgba 2x2 needs 16 bytes" {
    try std.testing.expectEqual(
        @as(u32, 16),
        try planTextureUpload(.rgba, 2, 2, 16),
    );
}

test "planTextureUpload: red 4x4 needs 16 bytes" {
    try std.testing.expectEqual(
        @as(u32, 16),
        try planTextureUpload(.red, 4, 4, 16),
    );
}

test "planTextureUpload: oversized data is fine" {
    // We only require `data.len >= required`. A larger buffer is OK
    // because D3D11 only reads `required` bytes via SysMemPitch.
    try std.testing.expectEqual(
        @as(u32, 4),
        try planTextureUpload(.rgba, 1, 1, 1024),
    );
}

test "planTextureUpload: too-small data fails" {
    try std.testing.expectError(
        UploadError.InsufficientData,
        planTextureUpload(.rgba, 2, 2, 15),
    );
}

test "planTextureUpload: empty data with non-zero dims fails" {
    try std.testing.expectError(
        UploadError.InsufficientData,
        planTextureUpload(.rgba, 1, 1, 0),
    );
}

test "planTextureUpload: zero dims need zero bytes" {
    try std.testing.expectEqual(
        @as(u32, 0),
        try planTextureUpload(.rgba, 0, 0, 0),
    );
    try std.testing.expectEqual(
        @as(u32, 0),
        try planTextureUpload(.rgba, 0, 100, 0),
    );
}

test "planTextureUpload: width*height overflow is rejected" {
    // 2^16 * 2^16 = 2^32, doesn't fit in u32.
    try std.testing.expectError(
        UploadError.DimensionOverflow,
        planTextureUpload(.red, 65536, 65536, 0),
    );
}

test "planTextureUpload: width*height*bpp overflow is rejected" {
    // 2^15 * 2^15 = 2^30 fits, but * 4 = 2^32 doesn't.
    try std.testing.expectError(
        UploadError.DimensionOverflow,
        planTextureUpload(.rgba, 32768, 32768, 0),
    );
}
