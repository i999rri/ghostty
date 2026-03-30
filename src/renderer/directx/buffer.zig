const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;

pub const RawBuffer = ?*anyopaque;

pub const Options = struct {
    target: Target = .array,
    usage: Usage = .dynamic_draw,

    pub const Target = enum {
        array,
        element_array,
        uniform,
        shader_storage,
    };

    pub const Usage = enum {
        static_draw,
        dynamic_draw,
        stream_draw,
    };
};

// D3D11 bind flags matching Options.Target
const D3D11_BIND_VERTEX_BUFFER: u32 = 0x1;
const D3D11_BIND_INDEX_BUFFER: u32 = 0x2;
const D3D11_BIND_CONSTANT_BUFFER: u32 = 0x4;
const D3D11_BIND_SHADER_RESOURCE: u32 = 0x8;

fn bindFlags(target: Options.Target) u32 {
    return switch (target) {
        .array => D3D11_BIND_VERTEX_BUFFER,
        .element_array => D3D11_BIND_INDEX_BUFFER,
        .uniform => D3D11_BIND_CONSTANT_BUFFER,
        .shader_storage => D3D11_BIND_SHADER_RESOURCE,
    };
}

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: RawBuffer = null,
        opts: Options,
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            return .{
                .opts = opts,
                .len = len,
            };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            var self = Self{
                .opts = opts,
                .len = data.len,
            };
            try self.sync(data);
            return self;
        }

        pub fn deinit(self: Self) void {
            if (self.buffer) |buf| dx.dx_destroy_buffer(buf);
        }

        pub fn sync(self: *Self, data: []const T) !void {
            const dev = DirectX.current_device orelse return;
            const byte_size: u32 = @intCast(data.len * @sizeOf(T));
            if (byte_size == 0) return;

            if (self.buffer) |buf| {
                // Update existing buffer
                dx.dx_update_buffer(dev, buf, @ptrCast(data.ptr), byte_size);
            } else {
                // Create new buffer
                // Constant buffers must be 16-byte aligned
                var aligned_size = byte_size;
                if (self.opts.target == .uniform) {
                    aligned_size = (byte_size + 15) & ~@as(u32, 15);
                }
                self.buffer = dx.dx_create_buffer(
                    dev,
                    bindFlags(self.opts.target),
                    aligned_size,
                    @ptrCast(data.ptr),
                );
            }
            self.len = data.len;
        }

        pub fn syncFromArrayLists(self: *Self, lists: anytype) !usize {
            _ = self;
            var total: usize = 0;
            for (lists) |list| {
                total += list.items.len;
            }
            return total;
        }
    };
}
