const std = @import("std");

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
            return .{
                .opts = opts,
                .len = data.len,
            };
        }

        pub fn deinit(self: Self) void {
            _ = self;
            // TODO: dx_destroy_buffer
        }

        pub fn sync(self: *Self, data: []const T) !void {
            _ = self;
            _ = data;
            // TODO: dx_update_buffer
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
