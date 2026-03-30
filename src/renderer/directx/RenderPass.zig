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
    const dev = device orelse return .{ .device = null };

    // Clear attachments if requested
    for (opts.attachments) |att| {
        if (att.clear_color) |color| {
            switch (att.target) {
                .target => |t| {
                    if (t.rt_handle) |rt| {
                        dx.dx_bind_render_target(dev, rt);
                        dx.dx_clear(dev, color[0], color[1], color[2], color[3]);
                    }
                },
                .texture => {},
            }
        }
    }

    return .{ .device = dev };
}

pub fn step(self: *Self, s: Step) void {
    const dev = self.device orelse return;

    // Bind pipeline
    if (s.pipeline.handle) |pipe| {
        dx.dx_bind_pipeline(dev, pipe);
    }

    // Set blend state
    dx.dx_set_blend_enabled(dev, s.pipeline.blending_enabled);

    // Bind uniform constant buffer (slot 1 to match HLSL register(b1))
    if (s.uniforms) |buf| {
        dx.dx_bind_constant_buffer(dev, buf, 1, true, true);
    }

    // Bind structured buffers / vertex buffers
    for (s.buffers, 0..) |buf_opt, i| {
        if (buf_opt) |buf| {
            dx.dx_bind_srv_buffer(dev, buf, @intCast(i + 1), 4);
        }
    }

    // Bind textures
    for (s.textures, 0..) |tex_opt, i| {
        if (tex_opt) |tex| {
            if (tex.dx_handle) |handle| {
                dx.dx_bind_texture(dev, handle, @intCast(i));
            }
        }
    }

    // Bind samplers
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
