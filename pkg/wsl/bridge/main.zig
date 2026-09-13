//! The WSL direct pty bridge (GhosttyWin32#206).
//!
//! ConPTY re-renders the VT stream, so a WSL session driven through it
//! never delivers the bytes applications actually wrote. The bridge has
//! two halves: `helper.zig` runs inside the distro, owns a real Linux
//! pty and relays its bytes over the stdio that wsl.exe extends to
//! Windows; `Pty` is the Windows side that termio plugs into. Both
//! speak the frame protocol in `protocol.zig`.

pub const Pty = @import("Pty.zig");
pub const protocol = @import("protocol.zig");
pub const winsize = Pty.winsize;
