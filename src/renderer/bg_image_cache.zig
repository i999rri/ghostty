//! Process-wide cache of the decoded background image.
//!
//! Decoding a large PNG takes hundreds of milliseconds and yields tens
//! of megabytes of pixels. Every surface used to decode the configured
//! image itself, so one decode is shared instead and lent out under the
//! cache lock: the GPU upload copies the pixels, so a borrower needs no
//! copy of its own and releases the view right after.
const std = @import("std");
const Allocator = std.mem.Allocator;
const wuffs = @import("wuffs");
const FileType = @import("../file_type.zig").FileType;

const log = std.log.scoped(.bg_image_cache);

/// A borrowed view of the decoded image. The cache lock is held until
/// `release`, so keep it only for the upload.
pub const View = struct {
    width: u32,
    height: u32,
    data: []const u8,

    pub fn release(self: View) void {
        _ = self;
        mutex.unlock();
    }
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

/// Borrow the decoded image at `path`, decoding it only when the cache
/// does not already hold this exact file. Open, read and file-type
/// problems are logged here and reported as named errors so the caller
/// can skip the image; decode errors propagate as they are. On success
/// the cache lock is held until the view is released.
pub fn acquire(alloc: Allocator, path: []const u8) !View {
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        log.warn("error opening background image file \"{s}\": {}", .{ path, err });
        return error.OpenFailed;
    };
    defer file.close();
    const stat = file.stat() catch |err| {
        log.warn("error reading background image file \"{s}\": {}", .{ path, err });
        return error.ReadFailed;
    };

    mutex.lock();
    errdefer mutex.unlock();

    if (entry) |*e| {
        if (!e.matches(path, stat)) {
            e.deinit();
            entry = null;
        }
    }
    if (entry == null) entry = try decode(alloc, file, path, stat);

    const e = entry.?;
    return .{ .width = e.width, .height = e.height, .data = e.data };
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
