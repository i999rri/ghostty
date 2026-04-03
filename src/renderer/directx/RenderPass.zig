const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;
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

device: ?*anyopaque,

pub fn begin(device: ?*anyopaque, opts: Options) Self {
    _ = opts;
    return .{ .device = device };
}

pub fn step(self: *Self, s: Step) void {
    const dev = self.device orelse return;

    // Get pipeline handle (lazy creation on renderer thread)
    const pipe = s.pipeline.getHandle(dev) orelse return;

    // Set full D3D11 state
    var w: u32 = 0;
    var h: u32 = 0;
    dx.dx_get_backbuffer_size(dev, &w, &h);
    dx.dx_set_viewport(dev, w, h);
    dx.dx_bind_backbuffer(dev);
    dx.dx_set_blend_enabled(dev, s.pipeline.blending_enabled);
    dx.dx_bind_pipeline(dev, pipe);

    // Bind resources
    if (s.uniforms) |buf| {
        dx.dx_bind_constant_buffer(dev, buf, 1, true, true);
    }

    for (s.buffers, 0..) |buf_opt, i| {
        if (buf_opt) |buf| {
            dx.dx_bind_srv_buffer(dev, buf, @intCast(i + 1), 4);
        }
    }

    for (s.textures, 0..) |tex_opt, i| {
        if (tex_opt) |tex| {
            if (tex.dx_handle) |handle| {
                dx.dx_bind_texture(dev, handle, @intCast(i));
            }
        }
    }

    for (s.samplers, 0..) |samp_opt, i| {
        if (samp_opt) |samp| {
            if (samp.dx_handle) |handle| {
                dx.dx_bind_sampler(dev, handle, @intCast(i));
            }
        }
    }

    // Draw
    if (s.draw.instance_count > 1) {
        dx.dx_draw_instanced(dev,
            @intCast(s.draw.vertex_count),
            @intCast(s.draw.instance_count),
            0, 0);
    } else {
        dx.dx_draw(dev, @intCast(s.draw.vertex_count), 0);
    }
}

pub fn complete(self: *Self) void {
    _ = self;
}
