//! The WSL direct pty bridge (GhosttyWin32#206).
//!
//! ConPTY re-renders the VT stream, so a WSL session driven through it
//! never delivers the bytes applications actually wrote. The bridge has
//! two halves: `helper.zig` runs inside the distro, owns a real Linux
//! pty and relays its bytes over the stdio that wsl.exe extends to
//! Windows; `Pty` is the Windows side that termio plugs into. Both
//! speak the frame protocol in `protocol.zig`, and `Launch` builds the
//! wsl.exe command line that connects them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const wsl = @import("../main.zig");

pub const Pty = @import("Pty.zig");
pub const protocol = @import("protocol.zig");
pub const winsize = Pty.winsize;

/// Whether a path names the binary inside the distribution rather than
/// on a Windows drive. An absolute Linux path is the only form the
/// distribution has in common with nothing on this side: a Windows path
/// is a drive letter or a UNC root.
pub fn isDistroPath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

/// How to start the in-distro half through wsl.exe.
pub const Launch = struct {
    /// Where the in-distro binary is. A path inside the distribution is
    /// used as it stands; a Windows path is translated by wslpath, and
    /// backslashes are accepted there.
    helper_path: []const u8,
    invocation: wsl.Invocation,
    /// Initial pty size; the pixel sizes follow over a resize frame.
    cols: u16,
    rows: u16,
    /// TERM inside the distro.
    term: []const u8,

    /// The wsl.exe command line. A Windows path is translated to a Linux
    /// one inside the same invocation ($0), so no extra process is
    /// spawned for wslpath; "$@" forwards the in-distro command, which
    /// the binary execs directly (none = login shell).
    pub fn argv(self: Launch, alloc: Allocator) ![]const [:0]const u8 {
        var args: std.ArrayList([:0]const u8) = .empty;
        try args.append(alloc, "wsl.exe");
        if (self.invocation.distribution) |d| {
            try args.append(alloc, "--distribution");
            try args.append(alloc, d);
        }
        try args.append(alloc, "--exec");
        try args.append(alloc, "/bin/sh");
        try args.append(alloc, "-c");
        const in_distro = isDistroPath(self.helper_path);
        try args.append(alloc, try std.fmt.allocPrintSentinel(
            alloc,
            "exec {s} --cols {d} --rows {d} --term '{s}' \"$@\"",
            .{
                if (in_distro) "\"$0\"" else "\"$(wslpath -a \"$0\")\"",
                self.cols,
                self.rows,
                self.term,
            },
            0,
        ));

        const path = try alloc.dupeZ(u8, self.helper_path);
        // Only a Windows path needs the separators turned around.
        if (!in_distro) std.mem.replaceScalar(u8, path, '\\', '/');
        try args.append(alloc, path);

        if (self.invocation.command.len > 0) {
            try args.append(alloc, "--");
            for (self.invocation.command) |token| try args.append(alloc, token);
        }
        return try args.toOwnedSlice(alloc);
    }
};

test "Launch.argv" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const full = try (Launch{
        .helper_path = "C:\\app\\ghostty-wsl-bridge",
        .invocation = .{ .distribution = "NixOS", .command = &.{ "htop", "-d", "5" } },
        .cols = 132,
        .rows = 50,
        .term = "xterm-ghostty",
    }).argv(alloc);
    const expected = [_][]const u8{
        "wsl.exe",
        "--distribution",
        "NixOS",
        "--exec",
        "/bin/sh",
        "-c",
        "exec \"$(wslpath -a \"$0\")\" --cols 132 --rows 50 --term 'xterm-ghostty' \"$@\"",
        "C:/app/ghostty-wsl-bridge",
        "--",
        "htop",
        "-d",
        "5",
    };
    try testing.expectEqual(expected.len, full.len);
    for (expected, full) |want, got| try testing.expectEqualStrings(want, got);

    // No distro and no command: the default distro's login shell, so
    // the line ends at the binary's path.
    const bare = try (Launch{
        .helper_path = "C:/app/ghostty-wsl-bridge",
        .invocation = .{},
        .cols = 80,
        .rows = 24,
        .term = "xterm-ghostty",
    }).argv(alloc);
    try testing.expectEqual(@as(usize, 6), bare.len);
    try testing.expectEqualStrings("--exec", bare[1]);
    try testing.expectEqualStrings("C:/app/ghostty-wsl-bridge", bare[5]);

    // Installed in the distribution: wslpath has nothing to translate,
    // and the path goes through as it stands.
    const in_distro = try (Launch{
        .helper_path = "/usr/local/bin/ghostty-wsl-bridge",
        .invocation = .{},
        .cols = 80,
        .rows = 24,
        .term = "xterm-ghostty",
    }).argv(alloc);
    try testing.expectEqualStrings(
        "exec \"$0\" --cols 80 --rows 24 --term 'xterm-ghostty' \"$@\"",
        in_distro[4],
    );
    try testing.expectEqualStrings("/usr/local/bin/ghostty-wsl-bridge", in_distro[5]);
}

test "isDistroPath" {
    const testing = std.testing;
    try testing.expect(isDistroPath("/usr/local/bin/ghostty-wsl-bridge"));
    try testing.expect(isDistroPath("/home/u/.local/bin/ghostty-wsl-bridge"));
    try testing.expect(!isDistroPath("C:\\app\\ghostty-wsl-bridge"));
    try testing.expect(!isDistroPath("C:/app/ghostty-wsl-bridge"));
    // A UNC root reaches a Windows share, not the distribution.
    try testing.expect(!isDistroPath("\\\\server\\share\\ghostty-wsl-bridge"));
    try testing.expect(!isDistroPath(""));
}

test {
    _ = protocol;
}
