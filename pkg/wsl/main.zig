//! WSL integration for libghostty on Windows. Each feature is its own
//! namespace; `bridge` is the direct pty bridge (GhosttyWin32#206).

pub const bridge = @import("bridge/main.zig");
