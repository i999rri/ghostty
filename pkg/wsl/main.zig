//! WSL integration for libghostty on Windows. Each feature is its own
//! namespace; `bridge` is the direct pty bridge (GhosttyWin32#206). What
//! lives here directly is knowledge of wsl.exe's own command line.

const std = @import("std");

pub const bridge = @import("bridge/main.zig");

/// True when `program` is wsl.exe by name (case-insensitive): the
/// command users type to enter a distro.
pub fn isCommand(program: []const u8) bool {
    const base = std.fs.path.basename(program);
    return std.ascii.eqlIgnoreCase(base, "wsl") or
        std.ascii.eqlIgnoreCase(base, "wsl.exe");
}

/// The parts of a `wsl [args]` command line that matter for running a
/// session in the distro.
pub const Invocation = struct {
    distribution: ?[:0]const u8 = null,
    /// The in-distro command; empty means the login shell.
    command: []const [:0]const u8 = &.{},

    /// Re-interpret the user's `wsl [args]` (argv[0] is wsl itself): a
    /// leading `-d`/`--distribution NAME` selects the distro and the rest
    /// is the in-distro command. A lone `~` (from `wsl ~`) just means the
    /// home directory, i.e. a plain login shell, so it carries no command.
    pub fn parse(argv: []const [:0]const u8) Invocation {
        var result: Invocation = .{};
        var i: usize = 1;
        while (i < argv.len) : (i += 1) {
            const arg = argv[i];
            if ((std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--distribution")) and
                i + 1 < argv.len)
            {
                result.distribution = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, arg, "--")) {
                result.command = argv[i + 1 ..];
                break;
            } else if (std.mem.eql(u8, arg, "~")) {
                // login shell in home; nothing to run
            } else {
                result.command = argv[i..];
                break;
            }
        }
        return result;
    }
};

test isCommand {
    const testing = std.testing;
    try testing.expect(isCommand("wsl"));
    try testing.expect(isCommand("WSL.EXE"));
    try testing.expect(isCommand("C:\\Windows\\System32\\wsl.exe"));
    try testing.expect(!isCommand("wslconfig.exe"));
    try testing.expect(!isCommand("pwsh"));
}

test "Invocation.parse" {
    const testing = std.testing;

    const bare = Invocation.parse(&[_][:0]const u8{"wsl"});
    try testing.expectEqual(@as(?[:0]const u8, null), bare.distribution);
    try testing.expectEqual(@as(usize, 0), bare.command.len);

    const home = Invocation.parse(&[_][:0]const u8{ "wsl", "-d", "NixOS", "~" });
    try testing.expectEqualStrings("NixOS", home.distribution.?);
    try testing.expectEqual(@as(usize, 0), home.command.len);

    const explicit = Invocation.parse(&[_][:0]const u8{ "wsl", "--distribution", "NixOS", "--", "htop", "-d", "5" });
    try testing.expectEqualStrings("NixOS", explicit.distribution.?);
    try testing.expectEqual(@as(usize, 3), explicit.command.len);
    try testing.expectEqualStrings("htop", explicit.command[0]);
    try testing.expectEqualStrings("5", explicit.command[2]);

    // Without `--` the first non-option token starts the command, and
    // a later -d belongs to that command rather than to wsl.
    const implicit = Invocation.parse(&[_][:0]const u8{ "wsl", "htop", "-d", "5" });
    try testing.expectEqual(@as(?[:0]const u8, null), implicit.distribution);
    try testing.expectEqual(@as(usize, 3), implicit.command.len);
}

test {
    _ = bridge;
}
