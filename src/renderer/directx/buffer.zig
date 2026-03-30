const std = @import("std");

pub const RawBuffer = *anyopaque;

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

pub fn Buffer(comptime T: type) type {
    return struct {
        const Self = @This();

        buffer: ?RawBuffer = null,
        opts: Options,
        len: usize,

        pub fn init(opts: Options, len: usize) !Self {
            _ = opts;
            return .{
                .opts = .{},
                .len = len,
            };
        }

        pub fn initFill(opts: Options, data: []const T) !Self {
            _ = opts;
            return .{
                .opts = .{},
                .len = data.len,
            };
        }

        pub fn deinit(self: Self) void {
            _ = self;
        }

        pub fn sync(self: *Self, data: []const T) !void {
            _ = self;
            _ = data;
            // TODO: Map/Unmap D3D11 buffer
        }

        pub fn syncFromArrayLists(self: *Self, lists: anytype) !usize {
            _ = self;
            var total: usize = 0;
            for (lists) |list| {
                total += list.items.len;
            }
            return total;
        }

        pub fn rawBuffer(self: Self) ?RawBuffer {
            _ = self;
            return null;
        }
    };
}
