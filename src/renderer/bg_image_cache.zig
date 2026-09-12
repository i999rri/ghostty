//! Process-wide cache of the decoded background image.
//!
//! Decoding a large PNG takes hundreds of milliseconds, and every
//! surface used to decode the configured image itself, on the thread
//! that creates the surface — the UI thread in libghostty hosts, which
//! froze for that long on every new tab. One decode is shared instead;
//! callers take a copy they own, because Image frees its pending data
//! after the GPU upload.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");
const FileType = @import("../file_type.zig").FileType;

const log = std.log.scoped(.bg_image_cache);

pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Owned by the caller.
    data: []u8,
};

const Entry = struct {
    alloc: Allocator,
    path: []u8,
    size: u64,
    mtime: i128,
    width: u32,
    height: u32,
    data: []u8,

    fn deinit(self: *Entry) void {
        self.alloc.free(self.path);
        self.alloc.free(self.data);
    }

    /// The same file, unchanged since it was decoded.
    fn matches(self: Entry, path: []const u8, stat: std.fs.File.Stat) bool {
        return std.mem.eql(u8, self.path, path) and
            self.size == stat.size and
            self.mtime == stat.mtime;
    }
};

var mutex: std.Thread.Mutex = .{};
var entry: ?Entry = null;

/// Load the image at `path`, decoding it only when the cache does not
/// already hold this exact file. The returned data is a copy the
/// caller owns. Open, read and file-type problems are logged here and
/// reported as named errors so the caller can skip the image; decode
/// errors propagate as they are.
pub fn load(alloc: Allocator, path: []const u8) !Decoded {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        log.warn("error opening background image file \"{s}\": {}", .{ path, err });
        return error.OpenFailed;
    };
    defer file.close();
    const stat = file.stat() catch |err| {
        log.warn("error reading background image file \"{s}\": {}", .{ path, err });
        return error.ReadFailed;
    };

    // Held across the decode on purpose: concurrent surface inits then
    // wait for the one decode instead of each running their own.
    mutex.lock();
    defer mutex.unlock();

    if (entry) |*e| {
        if (!e.matches(path, stat)) {
            e.deinit();
            entry = null;
        }
    }
    if (entry == null) entry = try decode(alloc, file, path, stat);

    const e = entry.?;
    return .{
        .width = e.width,
        .height = e.height,
        .data = try alloc.dupe(u8, e.data),
    };
}

fn decode(alloc: Allocator, file: std.fs.File, path: []const u8, stat: std.fs.File.Stat) !Entry {
    const contents = file.readToEndAlloc(
        alloc,
        std.math.maxInt(u32), // Max size of 4 GiB, for now.
    ) catch |err| {
        log.warn("error reading background image file \"{s}\": {}", .{ path, err });
        return error.ReadFailed;
    };
    defer alloc.free(contents);

    const file_type = switch (FileType.detect(contents)) {
        .unknown => FileType.guessFromExtension(std.fs.path.extension(path)),
        else => |t| t,
    };

    const image = switch (file_type) {
        .png => try wuffs.png.decode(alloc, contents),
        .jpeg => try wuffs.jpeg.decode(alloc, contents),
        .unknown => {
            log.warn("Cannot determine file type for background image file \"{s}\"!", .{path});
            return error.UnknownFileType;
        },
        else => |f| {
            log.warn("Unsupported file type {} for background image file \"{s}\"!", .{ f, path });
            return error.UnsupportedFileType;
        },
    };
    errdefer alloc.free(image.data);

    return .{
        .alloc = alloc,
        .path = try alloc.dupe(u8, path),
        .size = stat.size,
        .mtime = stat.mtime,
        .width = image.width,
        .height = image.height,
        .data = image.data,
    };
}
