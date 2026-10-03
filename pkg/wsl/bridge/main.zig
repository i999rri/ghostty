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

/// How to start the in-distro half through wsl.exe.
pub const Launch = struct {
    invocation: wsl.Invocation,
    /// Initial pty size; the pixel sizes follow over a resize frame.
    cols: u16,
    rows: u16,
    /// TERM inside the distro.
    term: []const u8,

    /// The name the in-distro half is started by. It is the user's to
    /// install, so it has to be on the distribution's PATH as the
    /// session sees it -- which is the environment of `wsl.exe --exec`,
    /// not of a login shell.
    pub const program = "ghostty-wsl-bridge";

    /// The wsl.exe command line. "$@" forwards the in-distro command,
    /// which the binary execs directly (none = login shell).
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
        try args.append(alloc, try std.fmt.allocPrintSentinel(
            alloc,
            "exec " ++ program ++ " --cols {d} --rows {d} --term '{s}' \"$@\"",
            .{ self.cols, self.rows, self.term },
            0,
        ));

        // sh -c takes $0 before the positional arguments, and uses it to
        // name the command in its own messages -- including the "not
        // found" the user sees when the binary is not installed.
        try args.append(alloc, program);

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
        "exec ghostty-wsl-bridge --cols 132 --rows 50 --term 'xterm-ghostty' \"$@\"",
        "ghostty-wsl-bridge",
        "--",
        "htop",
        "-d",
        "5",
    };
    try testing.expectEqual(expected.len, full.len);
    for (expected, full) |want, got| try testing.expectEqualStrings(want, got);

    // No distro and no command: the default distro's login shell, so
    // the line ends at $0.
    const bare = try (Launch{
        .invocation = .{},
        .cols = 80,
        .rows = 24,
        .term = "xterm-ghostty",
    }).argv(alloc);
    try testing.expectEqual(@as(usize, 6), bare.len);
    try testing.expectEqualStrings("--exec", bare[1]);
    try testing.expectEqualStrings(
        "exec ghostty-wsl-bridge --cols 80 --rows 24 --term 'xterm-ghostty' \"$@\"",
        bare[4],
    );
    try testing.expectEqualStrings("ghostty-wsl-bridge", bare[5]);
}

test {
    _ = protocol;
}
