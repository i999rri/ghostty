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

    // Clear previous SRV bindings (prevent slot conflicts between steps)
    dx.dx_clear_shader_resources(dev);

    // Bind uniform constant buffer at slot 1
    if (s.uniforms) |buf| {
        dx.dx_bind_constant_buffer(dev, buf, 1, true, true);
    } else {
        // Log once that uniforms is null
        const k32 = struct {
            extern "kernel32" fn OutputDebugStringA([*:0]const u8) callconv(.winapi) void;
            var logged: bool = false;
        };
        if (!k32.logged) {
            k32.OutputDebugStringA("RenderPass: uniforms buffer is NULL\n");
            k32.logged = true;
        }
    }

    // Determine vertex stride from pipeline layout type
    const vertex_stride: u32 = switch (s.pipeline.layout_type) {
        .cell_text => 32, // sizeof(CellText)
        .bg_image => 8,   // sizeof(BgImage): f32(4) + u8(1) + 3 padding = 8 (4-byte aligned)
        .image => 40,     // sizeof(Image): 2+2+4+2 floats = 40 bytes
        .none => 0,
    };

    // Bind buffers
    const has_vertex_data = (s.pipeline.layout_type != .none);
    for (s.buffers, 0..) |buf_opt, i| {
        if (buf_opt) |buf| {
            if (i == 0 and has_vertex_data and vertex_stride > 0) {
                // First buffer is vertex/instance data when pipeline has input layout
                dx.dx_bind_vertex_buffer(dev, buf, vertex_stride, 0);
            } else {
                // SRV buffer: slot depends on whether first buffer was VB
                const srv_slot: u32 = if (has_vertex_data)
                    @intCast(i) // VB at 0, SRVs start at buffer index
                else
                    @intCast(i + 1); // no VB, SRVs at slot i+1
                dx.dx_bind_srv_buffer(dev, buf, srv_slot, 4);
            }
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
    const topology: u32 = switch (s.draw.type) {
        .triangle => 4, // D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST
        .triangle_strip => 5, // D3D11_PRIMITIVE_TOPOLOGY_TRIANGLESTRIP
    };
    if (s.draw.instance_count > 1) {
        dx.dx_draw_instanced(dev,
            @intCast(s.draw.vertex_count),
            @intCast(s.draw.instance_count),
            0, 0, topology);
    } else {
        dx.dx_draw(dev, @intCast(s.draw.vertex_count), 0, topology);
    }
}

pub fn complete(self: *Self) void {
    _ = self;
}
