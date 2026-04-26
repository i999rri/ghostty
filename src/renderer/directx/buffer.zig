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

/// What `Buffer.sync` needs to do for a given (current state, incoming data)
/// pair. Extracted from the imperative path so the size arithmetic — the
/// part that historically went wrong — can be unit-tested without a GPU.
pub const SyncPlan = union(enum) {
    /// No work: data is empty.
    nothing,
    /// Existing buffer has room; just upload.
    update_only: UpdateOnly,
    /// No buffer or existing one too small: destroy + create + upload.
    create_then_update: CreateThenUpdate,

    pub const UpdateOnly = struct {
        /// Bytes to upload, equal to `data.len * @sizeOf(T)`.
        byte_size: u32,
    };

    pub const CreateThenUpdate = struct {
        /// New buffer capacity in elements (becomes the new `Buffer.len`).
        alloc_len: usize,
        /// New buffer capacity in bytes; passed to `dx_create_buffer`.
        alloc_size: u32,
        /// Bytes to upload, always `<= alloc_size`.
        byte_size: u32,
    };
};

/// Pure function: figure out what `sync` should do given the current state
/// of the buffer and the incoming data length. Has no side effects, takes
/// no GPU handles — exists so tests can pin down the size arithmetic.
///
/// The historical bug here was passing `alloc_size` as the buffer's
/// `ByteWidth` while only providing `byte_size` worth of bytes — the
/// driver then memcpy'd `alloc_size` bytes from a too-short pointer and
/// AVed in `nvwgf2umx.dll`. Codifying the (alloc_size, byte_size) pair as
/// a value here, with the invariant `byte_size <= alloc_size`, makes the
/// mismatch easy to assert in tests.
pub fn planSync(
    comptime T: type,
    opts: Options,
    has_buffer: bool,
    current_len: usize,
    data_len: usize,
) SyncPlan {
    if (data_len == 0) return .nothing;

    const byte_size: u32 = @intCast(data_len * @sizeOf(T));

    // Existing buffer with room → in-place update.
    if (has_buffer and data_len <= current_len) {
        return .{ .update_only = .{ .byte_size = byte_size } };
    }

    // Need a new buffer. Headroom: 2x for non-uniform (amortizes future
    // growth to amortized O(1) updates); exactly 1x for uniform/CBuffer
    // since they're typically fixed-size and CBuffer requires a multiple
    // of 16 bytes.
    const alloc_len = if (opts.target == .uniform) data_len else data_len * 2;
    var alloc_size: u32 = @intCast(alloc_len * @sizeOf(T));
    if (opts.target == .uniform) {
        alloc_size = (alloc_size + 15) & ~@as(u32, 15);
    }

    return .{ .create_then_update = .{
        .alloc_len = alloc_len,
        .alloc_size = alloc_size,
        .byte_size = byte_size,
    } };
}

/// Type-safe wrapper around `dx_update_buffer`: takes a slice so the
/// (pointer, byte_size) pair is always self-consistent. Direct callers
/// of `dx.dx_update_buffer` could pass a longer length than the actual
/// data — same bug class as the old `dx_create_buffer` initial_data.
inline fn dxUpdateBuffer(dev: *dx.DxDevice, buf: ?*dx.DxBuffer, bytes: []const u8) void {
    if (bytes.len == 0) return;
    dx.dx_update_buffer(dev, buf, bytes.ptr, @intCast(bytes.len));
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
            const plan = planSync(T, self.opts, self.buffer != null, self.len, data.len);
            switch (plan) {
                .nothing => return,
                .update_only => {
                    dxUpdateBuffer(dev, self.buffer, std.mem.sliceAsBytes(data));
                },
                .create_then_update => |c| {
                    if (self.buffer) |buf| {
                        log.warn("buffer recreate (sync): target={s} {} -> {}", .{
                            @tagName(self.opts.target), self.len, c.alloc_len,
                        });
                        dx.dx_destroy_buffer(buf);
                        self.buffer = null;
                    }
                    self.buffer = dx.dx_create_buffer(
                        dev,
                        bindFlags(self.opts.target),
                        c.alloc_size,
                    );
                    if (self.buffer == null) {
                        log.err("dx_create_buffer failed: size={}", .{c.alloc_size});
                        return;
                    }
                    dxUpdateBuffer(dev, self.buffer, std.mem.sliceAsBytes(data));
                    self.len = c.alloc_len;
                },
            }
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
                if (self.buffer != null) {
                    log.warn("buffer recreate (lists): target={s} {} -> {}", .{
                        @tagName(self.opts.target), self.len, total_len * 2,
                    });
                }
                if (self.buffer) |buf| dx.dx_destroy_buffer(buf);
                self.len = total_len * 2;
                const alloc_size: u32 = @intCast(self.len * @sizeOf(T));
                self.buffer = dx.dx_create_buffer(
                    dev,
                    bindFlags(self.opts.target),
                    alloc_size,
                );
                if (self.buffer == null) log.err("dx_create_buffer failed: size={}", .{alloc_size});
            }

            if (self.buffer == null) return 0;

            // Copy all lists into a contiguous temporary buffer, then upload.
            // Stack for small payloads, heap for large.
            if (byte_size <= 65536) {
                var tmp: [65536]u8 = undefined;
                var offset: usize = 0;
                for (lists) |list| {
                    const items_bytes = std.mem.sliceAsBytes(list.items);
                    @memcpy(tmp[offset..][0..items_bytes.len], items_bytes);
                    offset += items_bytes.len;
                }
                dxUpdateBuffer(dev, self.buffer, tmp[0..byte_size]);
            } else {
                const alloc = std.heap.page_allocator;
                const tmp = alloc.alloc(u8, byte_size) catch return 0;
                defer alloc.free(tmp);
                var offset: usize = 0;
                for (lists) |list| {
                    const items_bytes = std.mem.sliceAsBytes(list.items);
                    @memcpy(tmp[offset..][0..items_bytes.len], items_bytes);
                    offset += items_bytes.len;
                }
                dxUpdateBuffer(dev, self.buffer, tmp);
            }

            return total_len;
        }
    };
}

// -- planSync tests ----------------------------------------------------------
//
// Pin down the size arithmetic that, when wrong, manifests as NVIDIA driver
// AVs at unpredictable points many tabs into stress testing. These run on
// any platform — `planSync` is pure and never touches D3D11.

test "planSync: empty data is a no-op" {
    try std.testing.expectEqual(SyncPlan.nothing, planSync(u32, .{}, false, 0, 0));
    try std.testing.expectEqual(SyncPlan.nothing, planSync(u32, .{}, true, 100, 0));
}

test "planSync: first call (no buffer) on .array target allocates 2x" {
    const plan = planSync(u32, .{ .target = .array }, false, 0, 5);
    try std.testing.expectEqual(SyncPlan{ .create_then_update = .{
        .alloc_len = 10,
        .alloc_size = 40, // 10 * 4 bytes
        .byte_size = 20, // 5 * 4 bytes
    } }, plan);
}

test "planSync: existing buffer with room → update_only (no recreate)" {
    const plan = planSync(u32, .{ .target = .array }, true, 100, 50);
    try std.testing.expectEqual(SyncPlan{ .update_only = .{
        .byte_size = 200, // 50 * 4 bytes
    } }, plan);
}

test "planSync: data fits exactly → still update_only (boundary)" {
    const plan = planSync(u32, .{ .target = .array }, true, 50, 50);
    try std.testing.expectEqual(SyncPlan{ .update_only = .{
        .byte_size = 200,
    } }, plan);
}

test "planSync: existing buffer outgrown → recreate at 2x of new size" {
    const plan = planSync(u32, .{ .target = .array }, true, 5, 10);
    try std.testing.expectEqual(SyncPlan{ .create_then_update = .{
        .alloc_len = 20,
        .alloc_size = 80,
        .byte_size = 40,
    } }, plan);
}

test "planSync: .uniform target uses 1x with 16-byte alignment" {
    // 5 u32 = 20 bytes, rounded up to 32 (next multiple of 16).
    const plan = planSync(u32, .{ .target = .uniform }, false, 0, 5);
    try std.testing.expectEqual(SyncPlan{ .create_then_update = .{
        .alloc_len = 5,
        .alloc_size = 32,
        .byte_size = 20,
    } }, plan);
}

test "planSync: .uniform with already-aligned size stays put" {
    // 4 u32 = 16 bytes, already a multiple of 16.
    const plan = planSync(u32, .{ .target = .uniform }, false, 0, 4);
    try std.testing.expectEqual(SyncPlan{ .create_then_update = .{
        .alloc_len = 4,
        .alloc_size = 16,
        .byte_size = 16,
    } }, plan);
}

test "planSync invariant: byte_size <= alloc_size for every (target, data_len)" {
    // The exact regression: under the old code, `alloc_size` was passed as
    // ByteWidth to the driver while only `byte_size` bytes were actually
    // available behind the data pointer. Driver then read past the end.
    // This test fails loudly if planSync ever returns a plan that would
    // require uploading more bytes than the buffer holds.
    const targets = [_]Options.Target{ .array, .element_array, .uniform, .shader_storage };
    const data_lens = [_]usize{ 1, 2, 5, 16, 100, 1000, 10000 };

    inline for (targets) |target| {
        for (data_lens) |dl| {
            const plans = [_]SyncPlan{
                planSync(u32, .{ .target = target }, false, 0, dl),
                // existing-but-too-small forces the same recreate path
                planSync(u32, .{ .target = target }, true, if (dl > 0) dl - 1 else 0, dl),
            };
            for (plans) |plan| switch (plan) {
                .create_then_update => |c| {
                    try std.testing.expect(c.byte_size <= c.alloc_size);
                    try std.testing.expect(c.alloc_len * @sizeOf(u32) <= c.alloc_size);
                    try std.testing.expect(dl <= c.alloc_len);
                },
                else => {},
            };
        }
    }
}

test "planSync invariant: .uniform alloc_size is always a multiple of 16" {
    const data_lens = [_]usize{ 1, 2, 3, 4, 5, 7, 8, 13, 16, 64, 100 };
    for (data_lens) |dl| {
        const plan = planSync(u32, .{ .target = .uniform }, false, 0, dl);
        switch (plan) {
            .create_then_update => |c| try std.testing.expectEqual(@as(u32, 0), c.alloc_size % 16),
            else => unreachable,
        }
    }
}
