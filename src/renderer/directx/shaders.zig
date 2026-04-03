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
    pub fn compileBytecode(self: *Shaders) void {
        self.pipelines.bg_color.compileBytecode(hlsl_bg_color, hlsl_bg_color);
        self.pipelines.cell_bg.compileBytecode(hlsl_cell_bg, hlsl_cell_bg);
        self.pipelines.cell_text.compileBytecode(hlsl_cell_text, hlsl_cell_text);
        self.pipelines.image.compileBytecode(hlsl_image, hlsl_image);
        self.pipelines.bg_image.compileBytecode(hlsl_bg_image, hlsl_bg_image);
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
