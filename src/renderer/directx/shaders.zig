const std = @import("std");
const Allocator = std.mem.Allocator;
const math = @import("../../math.zig");

const Pipeline = @import("Pipeline.zig");

const log = std.log.scoped(.directx);

// Embed HLSL source at comptime (with #include resolved)
const hlsl_common = @embedFile("../shaders/hlsl/common.hlsl");
const hlsl_bg_color = hlsl_common ++ @embedFile("../shaders/hlsl/bg_color.hlsl");
const hlsl_cell_bg = hlsl_common ++ @embedFile("../shaders/hlsl/cell_bg.hlsl");
const hlsl_cell_text = hlsl_common ++ @embedFile("../shaders/hlsl/cell_text.hlsl");
const hlsl_image = hlsl_common ++ @embedFile("../shaders/hlsl/image.hlsl");
const hlsl_bg_image = hlsl_common ++ @embedFile("../shaders/hlsl/bg_image.hlsl");

// GPU data types (must match HLSL constant buffer layouts)
pub const Uniforms = extern struct {
    projection_matrix: math.Mat align(16),
    screen_size: [2]f32 align(8),
    cell_size: [2]f32 align(8),
    grid_size: [2]u16 align(4),
    grid_padding: [4]f32 align(16),
    padding_extend: PaddingExtend align(4),
    min_contrast: f32 align(4),
    cursor_pos: [2]u16 align(4),
    cursor_color: [4]u8 align(4),
    bg_color: [4]u8 align(4),
    bools: Bools align(4),

    const Bools = packed struct(u32) {
        cursor_wide: bool,
        use_display_p3: bool,
        use_linear_blending: bool,
        use_linear_correction: bool = false,
        _padding: u28 = 0,
    };

    const PaddingExtend = packed struct(u32) {
        left: bool = false,
        right: bool = false,
        up: bool = false,
        down: bool = false,
        _padding: u28 = 0,
    };
};

pub const CellText = extern struct {
    glyph_pos: [2]u32 align(8) = .{ 0, 0 },
    glyph_size: [2]u32 align(8) = .{ 0, 0 },
    bearings: [2]i16 align(4) = .{ 0, 0 },
    grid_pos: [2]u16 align(4),
    color: [4]u8 align(4),
    atlas: Atlas align(1),
    bools: packed struct(u8) {
        no_min_contrast: bool = false,
        is_cursor_glyph: bool = false,
        _padding: u6 = 0,
    } align(1) = .{},

    pub const Atlas = enum(u8) {
        grayscale = 0,
        color = 1,
    };
};

pub const CellBg = [4]u8;

pub const Image = extern struct {
    grid_pos: [2]f32 align(8),
    cell_offset: [2]f32 align(8),
    source_rect: [4]f32 align(16),
    dest_size: [2]f32 align(8),
};

pub const BgImage = extern struct {
    opacity: f32 align(4),
    info: Info align(1),

    pub const Info = packed struct(u8) {
        position: Position,
        fit: Fit,
        repeat: bool,
        _padding: u1 = 0,

        pub const Position = enum(u4) {
            tl = 0, tc = 1, tr = 2,
            ml = 3, mc = 4, mr = 5,
            bl = 6, bc = 7, br = 8,
        };

        pub const Fit = enum(u2) {
            contain = 0, cover = 1, stretch = 2, none = 3,
        };
    };
};

pub const Shaders = struct {
    pipelines: PipelineCollection,
    post_pipelines: []const Pipeline,
    defunct: bool = false,
    device: ?*anyopaque = null,

    pub const PipelineCollection = struct {
        bg_color: Pipeline,
        cell_bg: Pipeline,
        cell_text: Pipeline,
        image: Pipeline,
        bg_image: Pipeline,
    };

    pub fn init(
        alloc: Allocator,
        custom_shaders: []const [:0]const u8,
    ) !Shaders {
        _ = alloc;
        _ = custom_shaders;
        return .{
            .pipelines = .{
                .bg_color = try Pipeline.init(null, .{
                    .vertex_fn = "vs_main",
                    .fragment_fn = "ps_main",
                    .blending_enabled = false,
                }),
                .cell_bg = try Pipeline.init(null, .{
                    .vertex_fn = "vs_main",
                    .fragment_fn = "ps_main",
                }),
                .cell_text = try Pipeline.init(CellText, .{
                    .vertex_fn = "vs_main",
                    .fragment_fn = "ps_main",
                    .step_fn = .per_instance,
                }),
                .image = try Pipeline.init(Image, .{
                    .vertex_fn = "vs_main",
                    .fragment_fn = "ps_main",
                    .step_fn = .per_instance,
                }),
                .bg_image = try Pipeline.init(BgImage, .{
                    .vertex_fn = "vs_main",
                    .fragment_fn = "ps_main",
                    .step_fn = .per_instance,
                }),
            },
            .post_pipelines = &.{},
        };
    }

    /// Compile all HLSL shaders on the D3D11 device.
    /// Called once when the device is available.
    /// Step 1: Compile HLSL to bytecode (no device needed).
    pub fn storeSource(self: *Shaders) void {
        self.pipelines.bg_color.storeSource(hlsl_bg_color, hlsl_bg_color);
        self.pipelines.cell_bg.storeSource(hlsl_cell_bg, hlsl_cell_bg);
        self.pipelines.cell_text.storeSource(hlsl_cell_text, hlsl_cell_text);
        self.pipelines.image.storeSource(hlsl_image, hlsl_image);
        self.pipelines.bg_image.storeSource(hlsl_bg_image, hlsl_bg_image);
    }

    /// Step 2: Create D3D11 shader objects from bytecode (needs device, renderer thread).
    pub fn createDeviceObjects(self: *Shaders, device: ?*anyopaque) void {
        if (device == null) return;
        self.device = device;
        self.pipelines.bg_color.createDeviceObjects(device);
        self.pipelines.cell_bg.createDeviceObjects(device);
        self.pipelines.cell_text.createDeviceObjects(device);
        self.pipelines.image.createDeviceObjects(device);
        self.pipelines.bg_image.createDeviceObjects(device);
    }

    pub fn deinit(self: *Shaders, alloc: Allocator) void {
        _ = alloc;
        self.pipelines.bg_color.deinit();
        self.pipelines.cell_bg.deinit();
        self.pipelines.cell_text.deinit();
        self.pipelines.image.deinit();
        self.pipelines.bg_image.deinit();
        self.defunct = true;
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

test "Uniforms cbuffer layout matches HLSL" {
    // These offsets must match common.hlsl cbuffer Globals : register(b1).
    // Any mismatch silently breaks all rendering.
    const testing = std.testing;

    // Total size (must be 16-byte aligned for constant buffers)
    try testing.expectEqual(@as(usize, 144), @sizeOf(Uniforms));
    try testing.expect(@sizeOf(Uniforms) % 16 == 0);

    // projection_matrix: float4x4 at offset 0 (64 bytes)
    try testing.expectEqual(@as(usize, 0), @offsetOf(Uniforms, "projection_matrix"));
    try testing.expectEqual(@as(usize, 64), @sizeOf(math.Mat));

    // screen_size: float2 at offset 64
    try testing.expectEqual(@as(usize, 64), @offsetOf(Uniforms, "screen_size"));

    // cell_size: float2 at offset 72
    try testing.expectEqual(@as(usize, 72), @offsetOf(Uniforms, "cell_size"));

    // grid_size_packed_2u16: uint at offset 80
    try testing.expectEqual(@as(usize, 80), @offsetOf(Uniforms, "grid_size"));

    // grid_padding: float4 at offset 96 (16-byte aligned, 12 bytes padding after grid_size)
    try testing.expectEqual(@as(usize, 96), @offsetOf(Uniforms, "grid_padding"));

    // padding_extend: uint at offset 112
    try testing.expectEqual(@as(usize, 112), @offsetOf(Uniforms, "padding_extend"));

    // min_contrast: float at offset 116
    try testing.expectEqual(@as(usize, 116), @offsetOf(Uniforms, "min_contrast"));

    // cursor_pos_packed_2u16: uint at offset 120
    try testing.expectEqual(@as(usize, 120), @offsetOf(Uniforms, "cursor_pos"));

    // cursor_color_packed_4u8: uint at offset 124
    try testing.expectEqual(@as(usize, 124), @offsetOf(Uniforms, "cursor_color"));

    // bg_color_packed_4u8: uint at offset 128
    try testing.expectEqual(@as(usize, 128), @offsetOf(Uniforms, "bg_color"));

    // bools: uint at offset 132
    try testing.expectEqual(@as(usize, 132), @offsetOf(Uniforms, "bools"));
}

test "Uniforms packed structs are u32" {
    const testing = std.testing;
    try testing.expectEqual(@as(usize, 4), @sizeOf(Uniforms.Bools));
    try testing.expectEqual(@as(usize, 4), @sizeOf(Uniforms.PaddingExtend));
}

test "CellText layout matches D3D11 input layout" {
    // Must match dx_create_cell_text_pipeline input element desc offsets.
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 32), @sizeOf(CellText));

    // GLYPH_POS: R32G32_UINT at offset 0
    try testing.expectEqual(@as(usize, 0), @offsetOf(CellText, "glyph_pos"));
    // GLYPH_SIZE: R32G32_UINT at offset 8
    try testing.expectEqual(@as(usize, 8), @offsetOf(CellText, "glyph_size"));
    // BEARINGS: R16G16_SINT at offset 16
    try testing.expectEqual(@as(usize, 16), @offsetOf(CellText, "bearings"));
    // GRID_POS: R16G16_UINT at offset 20
    try testing.expectEqual(@as(usize, 20), @offsetOf(CellText, "grid_pos"));
    // COLOR: R8G8B8A8_UINT at offset 24
    try testing.expectEqual(@as(usize, 24), @offsetOf(CellText, "color"));
    // ATLAS: R8_UINT at offset 28
    try testing.expectEqual(@as(usize, 28), @offsetOf(CellText, "atlas"));
    // GLYPH_BOOLS: R8_UINT at offset 29
    try testing.expectEqual(@as(usize, 29), @offsetOf(CellText, "bools"));
}

test "CellBg is 4 bytes (packed RGBA)" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(CellBg));
}

test "Image layout matches D3D11 input layout" {
    const testing = std.testing;

    // extern struct with align(16) on source_rect pads to 48
    try testing.expectEqual(@as(usize, 48), @sizeOf(Image));

    // GRID_POS: R32G32_FLOAT at offset 0
    try testing.expectEqual(@as(usize, 0), @offsetOf(Image, "grid_pos"));
    // CELL_OFFSET: R32G32_FLOAT at offset 8
    try testing.expectEqual(@as(usize, 8), @offsetOf(Image, "cell_offset"));
    // SOURCE_RECT: R32G32B32A32_FLOAT at offset 16
    try testing.expectEqual(@as(usize, 16), @offsetOf(Image, "source_rect"));
    // DEST_SIZE: R32G32_FLOAT at offset 32
    try testing.expectEqual(@as(usize, 32), @offsetOf(Image, "dest_size"));
}

test "BgImage layout matches D3D11 input layout" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 8), @sizeOf(BgImage));

    // OPACITY: R32_FLOAT at offset 0
    try testing.expectEqual(@as(usize, 0), @offsetOf(BgImage, "opacity"));
    // INFO: R8_UINT at offset 4
    try testing.expectEqual(@as(usize, 4), @offsetOf(BgImage, "info"));
}

test "BgImage.Info packed bit layout" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 1), @sizeOf(BgImage.Info));

    // cover fit, center position, no repeat
    const info = BgImage.Info{
        .position = .mc,
        .fit = .cover,
        .repeat = false,
    };
    const byte: u8 = @bitCast(info);
    // position(4bits) = mc(4), fit(2bits) = cover(1), repeat(1bit) = 0
    // Bit layout: _padding(1) | repeat(1) | fit(2) | position(4)
    try testing.expectEqual(@as(u4, 4), @intFromEnum(BgImage.Info.Position.mc));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(BgImage.Info.Fit.cover));
    // byte = 0b0_0_01_0100 = 0x14
    try testing.expectEqual(@as(u8, 0x14), byte);
}

test "HLSL sources are non-empty and contain expected keywords" {
    const testing = std.testing;

    // All shader sources must be non-trivial
    try testing.expect(hlsl_common.len > 50);
    try testing.expect(hlsl_bg_color.len > hlsl_common.len);
    try testing.expect(hlsl_cell_bg.len > hlsl_common.len);
    try testing.expect(hlsl_cell_text.len > hlsl_common.len);
    try testing.expect(hlsl_image.len > hlsl_common.len);
    try testing.expect(hlsl_bg_image.len > hlsl_common.len);

    // Common must contain the cbuffer declaration
    try testing.expect(std.mem.indexOf(u8, hlsl_common, "cbuffer Globals") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl_common, "register(b1)") != null);

    // Each shader must have vs_main and ps_main entry points
    try testing.expect(std.mem.indexOf(u8, hlsl_bg_color, "vs_main") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl_bg_color, "ps_main") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl_cell_text, "vs_main") != null);
    try testing.expect(std.mem.indexOf(u8, hlsl_cell_text, "ps_main") != null);
}

test "Uniforms Bools bit flags match HLSL constants" {
    // common.hlsl: CURSOR_WIDE=1, USE_DISPLAY_P3=2, USE_LINEAR_BLENDING=4, USE_LINEAR_CORRECTION=8
    const testing = std.testing;

    const cursor_wide: Uniforms.Bools = .{ .cursor_wide = true, .use_display_p3 = false, .use_linear_blending = false };
    const display_p3: Uniforms.Bools = .{ .cursor_wide = false, .use_display_p3 = true, .use_linear_blending = false };
    const linear_blend: Uniforms.Bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = true };
    const linear_correct: Uniforms.Bools = .{ .cursor_wide = false, .use_display_p3 = false, .use_linear_blending = false, .use_linear_correction = true };

    try testing.expectEqual(@as(u32, 1), @as(u32, @bitCast(cursor_wide)));
    try testing.expectEqual(@as(u32, 2), @as(u32, @bitCast(display_p3)));
    try testing.expectEqual(@as(u32, 4), @as(u32, @bitCast(linear_blend)));
    try testing.expectEqual(@as(u32, 8), @as(u32, @bitCast(linear_correct)));
}
