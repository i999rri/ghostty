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

device: ?*dx.DxDevice,

pub fn begin(device: ?*dx.DxDevice, opts: Options) Self {
    _ = opts;
    return .{ .device = device };
}

pub fn step(self: *Self, s: Step) void {
    const dev = self.device orelse return;

    // Get pipeline handle (lazy creation on renderer thread)
    const pipe = s.pipeline.getHandle(dev) orelse return;

    // Set D3D11 state (viewport/backbuffer already set by drawFrameStart)
    var w: u32 = 0;
    var h: u32 = 0;
    dx.dx_get_backbuffer_size(dev, &w, &h);
    dx.dx_set_viewport(dev, w, h);
    dx.dx_bind_backbuffer(dev);
    dx.dx_set_blend_enabled(dev, s.pipeline.blending_enabled);
    dx.dx_bind_pipeline(dev, pipe);

    // Clear previous SRV bindings (prevent slot conflicts between steps)
    dx.dx_clear_shader_resources(dev);

    // Bind uniform constant buffer at slot 1
    if (s.uniforms) |buf| {
        dx.dx_bind_constant_buffer(dev, buf, 1, true, true);
    }

    // Determine vertex stride from pipeline layout type using actual struct sizes
    const shaders_mod = @import("shaders.zig");
    const vertex_stride: u32 = switch (s.pipeline.layout_type) {
        .cell_text => @sizeOf(shaders_mod.CellText),
        .bg_image => @sizeOf(shaders_mod.BgImage),
        .image => @sizeOf(shaders_mod.Image),
        .none => 0,
    };

    // Bind vertex buffer (first buffer when pipeline has input layout)
    const has_vertex_data = (s.pipeline.layout_type != .none);
    if (has_vertex_data and s.buffers.len > 0) {
        if (s.buffers[0]) |buf| {
            if (vertex_stride > 0) {
                dx.dx_bind_vertex_buffer(dev, buf, vertex_stride, 0);
            }
        }
    }

    // Bind textures first (they occupy SRV slots 0..n-1)
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

    // Bind SRV buffers AFTER textures.
    // Slot = textures.len + srv_index (so they don't overlap texture slots).
    // For cell_bg (no textures): bg_cells at slot 0+1=1 (register t1)
    // For cell_text (2 textures): bg_colors at slot 2+0=2 (register t2)
    {
        const tex_count: u32 = @intCast(s.textures.len);
        var srv_index: u32 = 0;
        const start: usize = if (has_vertex_data) 1 else 0;
        for (s.buffers[start..]) |buf_opt| {
            if (buf_opt) |buf| {
                // Slot 0 is reserved (cbuffer at b0 convention or first texture),
                // so SRV buffers start at max(tex_count, 1) + srv_index
                const base_slot = if (tex_count > 0) tex_count else 1;
                dx.dx_bind_srv_buffer(dev, buf, base_slot + srv_index, 4);
                srv_index += 1;
            }
        }
    }

    // Draw
    const topology: u32 = switch (s.draw.type) {
        .triangle => 4, // D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST
        .triangle_strip => 5, // D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP
    };
    if (s.draw.instance_count > 1 or has_vertex_data) {
        const ic: u32 = @intCast(@max(s.draw.instance_count, 1));
        dx.dx_draw_instanced(dev,
            @intCast(s.draw.vertex_count),
            ic,
            0, 0, topology);
    } else {
        dx.dx_draw(dev, @intCast(s.draw.vertex_count), 0, topology);
    }
}

pub fn complete(self: *Self) void {
    _ = self;
}
