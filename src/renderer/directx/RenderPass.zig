const std = @import("std");
const Pipeline = @import("Pipeline.zig");
const Texture = @import("Texture.zig");
const Sampler = @import("Sampler.zig");
const Target = @import("Target.zig");
const bufferpkg = @import("buffer.zig");

const Self = @This();

pub const Options = struct {
    attachments: []const Attachment,

    pub const Attachment = struct {
        target: union(enum) {
            texture: Texture,
            target: Target,
        },
        clear_color: ?[4]f32 = null,
    };
};

pub const Step = struct {
    pipeline: Pipeline,
    uniforms: ?bufferpkg.RawBuffer = null,
    buffers: []const ?bufferpkg.RawBuffer = &.{},
    textures: []const ?Texture = &.{},
    samplers: []const ?Sampler = &.{},
    draw: Draw,

    pub const Draw = struct {
        type: PrimitiveType,
        vertex_count: usize,
        instance_count: usize = 1,

        pub const PrimitiveType = enum {
            triangle,
            triangle_strip,
        };
    };
};

pub fn begin(opts: Options) Self {
    _ = opts;
    return .{};
}

pub fn step(self: *Self, s: Step) void {
    _ = self;
    _ = s;
    // TODO: Record draw commands to D3D11 device context
}

pub fn complete(self: *Self) void {
    _ = self;
    // TODO: Execute recorded draw commands
}
