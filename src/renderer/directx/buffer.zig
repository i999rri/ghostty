const std = @import("std");
const DirectX = @import("../DirectX.zig");
const dx = DirectX.dx;
const log = std.log.scoped(.directx);

pub const RawBuffer = ?*dx.DxBuffer;

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

            // If buffer exists but is too small, recreate it
            if (self.buffer != null and data.len > self.len) {
                if (self.buffer) |buf| dx.dx_destroy_buffer(buf);
                self.buffer = null;
            }

            if (self.buffer) |buf| {
                // Update existing buffer
                dx.dx_update_buffer(dev, buf, @ptrCast(data.ptr), byte_size);
            } else {
                // Create new buffer with 2x capacity
                const alloc_len = if (self.opts.target == .uniform) data.len else data.len * 2;
                var alloc_size: u32 = @intCast(alloc_len * @sizeOf(T));
                if (self.opts.target == .uniform) {
                    alloc_size = (alloc_size + 15) & ~@as(u32, 15);
                }
                self.buffer = dx.dx_create_buffer(
                    dev,
                    bindFlags(self.opts.target),
                    alloc_size,
                    @ptrCast(data.ptr),
                );
                if (self.buffer == null) log.err("dx_create_buffer failed: size={}", .{alloc_size});
                self.len = alloc_len;
                return;
            }
            self.len = @max(self.len, data.len);
        }

        pub fn syncFromArrayLists(self: *Self, lists: []const std.ArrayListUnmanaged(T)) !usize {
            const dev = DirectX.current_device orelse return 0;

            var total_len: usize = 0;
            for (lists) |list| {
                total_len += list.items.len;
            }
            if (total_len == 0) return 0;

            const byte_size: u32 = @intCast(total_len * @sizeOf(T));

            // If buffer doesn't exist or is too small, recreate
            if (self.buffer == null or total_len > self.len) {
                if (self.buffer) |buf| dx.dx_destroy_buffer(buf);
                self.len = total_len * 2;
                const alloc_size: u32 = @intCast(self.len * @sizeOf(T));
                self.buffer = dx.dx_create_buffer(
                    dev,
                    bindFlags(self.opts.target),
                    alloc_size,
                    null,
                );
                if (self.buffer == null) log.err("dx_create_buffer failed: size={}", .{alloc_size});
            }

            if (self.buffer == null) return 0;

            // Copy all lists into a contiguous temporary buffer, then upload
            // For efficiency with small data, stack-allocate up to 64KB
            if (byte_size <= 65536) {
                var tmp: [65536]u8 = undefined;
                var offset: usize = 0;
                for (lists) |list| {
                    const items_bytes = std.mem.sliceAsBytes(list.items);
                    @memcpy(tmp[offset..][0..items_bytes.len], items_bytes);
                    offset += items_bytes.len;
                }
                dx.dx_update_buffer(dev, self.buffer, &tmp, byte_size);
            } else {
                // Large data: use heap allocation
                const alloc = std.heap.page_allocator;
                const tmp = alloc.alloc(u8, byte_size) catch return 0;
                defer alloc.free(tmp);
                var offset: usize = 0;
                for (lists) |list| {
                    const items_bytes = std.mem.sliceAsBytes(list.items);
                    @memcpy(tmp[offset..][0..items_bytes.len], items_bytes);
                    offset += items_bytes.len;
                }
                dx.dx_update_buffer(dev, self.buffer, tmp.ptr, byte_size);
            }

            return total_len;
        }
    };
}
