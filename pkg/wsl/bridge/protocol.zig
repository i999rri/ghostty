//! Frame protocol between the two halves of the bridge.
//!
//! wsl.exe extends the helper's stdio to Windows as plain pipes, which
//! carry no out-of-band channel. Both directions are therefore framed:
//! stdin because resize needs a side channel, stdout because reports
//! such as the foreground process name must not pollute the pty byte
//! stream. stderr stays plain diagnostics text.
//!
//!   [type: u8][len: u16 LE][payload: len bytes]
//!
//! stdin (host -> helper):
//!   data:    payload is written to the pty as-is
//!   resize:  payload is `Resize` (4x u16 LE: cols, rows, xpixel, ypixel)
//!   hangup:  no payload; close the pty (SIGHUP) and exit
//!
//! stdout (helper -> host):
//!   data:    raw pty output, byte-exact inside the payload
//!   fg_name: the foreground process's comm name
//!
//! Unknown types are skipped so the protocol can grow without breaking
//! an older peer.

const std = @import("std");

pub const header_len = 3;
pub const max_payload = std.math.maxInt(u16);

pub const Type = enum(u8) {
    data = 0,
    resize = 1,
    hangup = 2,
    fg_name = 3,
    _,
};

pub const Frame = struct {
    kind: Type,
    payload: []const u8,
};

/// The header that precedes `len` payload bytes of the given type.
pub fn header(kind: Type, len: usize) [header_len]u8 {
    var result: [header_len]u8 = undefined;
    result[0] = @intFromEnum(kind);
    std.mem.writeInt(u16, result[1..3], @intCast(len), .little);
    return result;
}

/// Payload of a resize frame.
pub const Resize = struct {
    cols: u16,
    rows: u16,
    xpixel: u16,
    ypixel: u16,

    pub const payload_len = 8;

    pub fn encode(self: Resize) [payload_len]u8 {
        var result: [payload_len]u8 = undefined;
        std.mem.writeInt(u16, result[0..2], self.cols, .little);
        std.mem.writeInt(u16, result[2..4], self.rows, .little);
        std.mem.writeInt(u16, result[4..6], self.xpixel, .little);
        std.mem.writeInt(u16, result[6..8], self.ypixel, .little);
        return result;
    }

    /// Null when the payload is too short to be a resize.
    pub fn decode(payload: []const u8) ?Resize {
        if (payload.len < payload_len) return null;
        return .{
            .cols = std.mem.readInt(u16, payload[0..2], .little),
            .rows = std.mem.readInt(u16, payload[2..4], .little),
            .xpixel = std.mem.readInt(u16, payload[4..6], .little),
            .ypixel = std.mem.readInt(u16, payload[6..8], .little),
        };
    }
};

/// Incremental frame parser. Frames can split across reads, so bytes
/// accumulate here until a frame completes:
///
///   while (remaining.len > 0) {
///       remaining = remaining[parser.push(remaining)..];
///       while (parser.next()) |frame| handle(frame);
///   }
///
/// A returned frame's payload points into the parser and is valid until
/// the next `push`.
pub const Parser = struct {
    buf: [header_len + max_payload]u8 = undefined,
    /// Bytes held, including already-returned frames up to `read`.
    len: usize = 0,
    /// Start of the first frame not yet returned.
    read: usize = 0,

    /// Append as many bytes as fit and return how many were taken. The
    /// buffer holds at least one maximal frame, so after draining with
    /// `next` it always accepts more.
    pub fn push(self: *Parser, bytes: []const u8) usize {
        self.compact();
        const take = @min(self.buf.len - self.len, bytes.len);
        @memcpy(self.buf[self.len..][0..take], bytes[0..take]);
        self.len += take;
        return take;
    }

    /// The next complete frame, or null when more bytes are needed.
    pub fn next(self: *Parser) ?Frame {
        const avail = self.len - self.read;
        if (avail < header_len) return null;
        const head = self.buf[self.read..][0..header_len];
        // Widen before adding: a maximal payload plus the header does
        // not fit in the u16 the length is carried in.
        const payload_len: usize = std.mem.readInt(u16, head[1..3], .little);
        if (avail < header_len + payload_len) return null;

        const frame: Frame = .{
            .kind = @enumFromInt(head[0]),
            .payload = self.buf[self.read + header_len ..][0..payload_len],
        };
        self.read += header_len + payload_len;
        return frame;
    }

    /// Drop returned frames so the tail moves to the front.
    fn compact(self: *Parser) void {
        if (self.read == 0) return;
        std.mem.copyForwards(u8, self.buf[0 .. self.len - self.read], self.buf[self.read..self.len]);
        self.len -= self.read;
        self.read = 0;
    }
};

test "header and resize round-trip" {
    const testing = std.testing;
    const h = header(.resize, Resize.payload_len);
    try testing.expectEqual(@as(u8, 1), h[0]);
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, h[1..3], .little));

    const size: Resize = .{ .cols = 132, .rows = 50, .xpixel = 1920, .ypixel = 1080 };
    try testing.expectEqual(size, Resize.decode(&size.encode()).?);
    try testing.expectEqual(@as(?Resize, null), Resize.decode(&[_]u8{ 1, 2, 3 }));
}

test "parser yields frames split across pushes" {
    const testing = std.testing;
    var parser: Parser = .{};

    const first = header(.data, 5) ++ "hello".*;
    const second = header(.hangup, 0);
    const stream = first ++ second;

    // Split in the middle of the first payload.
    try testing.expectEqual(@as(usize, 5), parser.push(stream[0..5]));
    try testing.expectEqual(@as(?Frame, null), parser.next());

    try testing.expectEqual(stream.len - 5, parser.push(stream[5..]));
    const data = parser.next().?;
    try testing.expectEqual(Type.data, data.kind);
    try testing.expectEqualStrings("hello", data.payload);
    const hangup = parser.next().?;
    try testing.expectEqual(Type.hangup, hangup.kind);
    try testing.expectEqual(@as(usize, 0), hangup.payload.len);
    try testing.expectEqual(@as(?Frame, null), parser.next());

    // Everything was consumed, so the next push starts from empty.
    _ = parser.push(&header(.data, 0));
    try testing.expectEqual(@as(usize, 0), parser.len - parser.read - header_len);
}

test "parser passes unknown types through" {
    const testing = std.testing;
    var parser: Parser = .{};
    const frame = [_]u8{ 200, 2, 0, 0xAA, 0xBB };
    _ = parser.push(&frame);
    const got = parser.next().?;
    try testing.expectEqual(@as(u8, 200), @intFromEnum(got.kind));
    try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, got.payload);
}

test "parser takes only what fits and accepts more after draining" {
    const testing = std.testing;
    var parser: Parser = .{};

    // Two maximal data frames back to back exceed the buffer.
    const frame_len = header_len + max_payload;
    const stream = try testing.allocator.alloc(u8, 2 * frame_len);
    defer testing.allocator.free(stream);
    @memset(stream, 'x');
    stream[0..header_len].* = header(.data, max_payload);
    stream[frame_len..][0..header_len].* = header(.data, max_payload);

    var remaining: []const u8 = stream;
    var frames: usize = 0;
    while (remaining.len > 0) {
        remaining = remaining[parser.push(remaining)..];
        while (parser.next()) |f| {
            try testing.expectEqual(@as(usize, max_payload), f.payload.len);
            frames += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2), frames);
}
