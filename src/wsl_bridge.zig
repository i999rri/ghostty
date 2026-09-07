//! Windows side of the WSL direct pty bridge (GhosttyWin32#206).
//!
//! ConPTY re-renders the VT stream, so a WSL session driven through it
//! never delivers the bytes applications actually wrote. The bridge
//! instead spawns `wsl.exe` running ghostty-wsl-helper (see
//! src/wsl_helper/main.zig), which owns a real Linux pty and relays its
//! bytes over stdio untouched.
//!
//! This struct provides the pipe plumbing on the Windows side. Output
//! is a straight passthrough: termio reads the helper's stdout raw.
//! Input needs translation, because the helper's stdin is a frame
//! stream (data/resize) while termio writes raw bytes; a pump thread
//! reads termio's raw writes and reframes them. Resize frames are
//! written directly by `setSize`, serialized with the pump by a mutex.
//!
//!   termio write -> in_pipe -> [pump: frame] -> wsl.exe -> helper pty
//!   termio read  <- out_pipe <---------------- wsl.exe <- helper pty

const std = @import("std");
const windows = @import("os/main.zig").windows;
const ptypkg = @import("pty.zig");
const winsize = ptypkg.winsize;

const log = std.log.scoped(.wsl_bridge);

const frame_data: u8 = 0;
const frame_resize: u8 = 1;
const frame_hangup: u8 = 2;
const max_frame_payload = std.math.maxInt(u16);

pub const WslBridgePty = struct {
    // Process-wide counter for pipe names, kept separate from
    // WindowsPty's so neither can collide with the other.
    var pipe_name_counter = std.atomic.Value(u32).init(1);

    /// Raw helper output, read by termio.
    out_pipe: windows.HANDLE,
    /// Raw terminal input, written by termio (overlapped named pipe,
    /// required by libxev's IOCP backend).
    in_pipe: windows.HANDLE,

    /// The ends wsl.exe inherits as its stdio.
    child_stdin: windows.HANDLE,
    child_stdout: windows.HANDLE,

    /// Frame stream into wsl.exe, shared by the pump and setSize.
    helper_in: windows.HANDLE,
    /// Raw input read side for the pump.
    raw_in: windows.HANDLE,

    write_mutex: std.Thread.Mutex,
    pump: ?std.Thread,
    size: winsize,

    pub const OpenError = error{Unexpected} || std.Thread.SpawnError;

    pub fn open(size: winsize) OpenError!WslBridgePty {
        var self: WslBridgePty = .{
            .out_pipe = undefined,
            .in_pipe = undefined,
            .child_stdin = undefined,
            .child_stdout = undefined,
            .helper_in = undefined,
            .raw_in = undefined,
            .write_mutex = .{},
            .pump = null,
            .size = size,
        };

        // The termio write side must support overlapped I/O, which
        // anonymous pipes do not, so it is a named pipe exactly like
        // WindowsPty's in_pipe.
        var pipe_path_buf: [128]u8 = undefined;
        var pipe_path_buf_w: [128]u16 = undefined;
        const pipe_path = std.fmt.bufPrintZ(
            &pipe_path_buf,
            "\\\\.\\pipe\\LOCAL\\ghostty-wsl-bridge-{d}-{d}",
            .{
                windows.GetCurrentProcessId(),
                pipe_name_counter.fetchAdd(1, .monotonic),
            },
        ) catch unreachable;
        const pipe_path_w_len = std.unicode.utf8ToUtf16Le(
            &pipe_path_buf_w,
            pipe_path,
        ) catch unreachable;
        pipe_path_buf_w[pipe_path_w_len] = 0;
        const pipe_path_w = pipe_path_buf_w[0..pipe_path_w_len :0];

        const security_attributes = windows.SECURITY_ATTRIBUTES{
            .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
            .bInheritHandle = windows.FALSE,
            .lpSecurityDescriptor = null,
        };

        self.in_pipe = windows.kernel32.CreateNamedPipeW(
            pipe_path_w.ptr,
            windows.PIPE_ACCESS_OUTBOUND |
                windows.exp.FILE_FLAG_FIRST_PIPE_INSTANCE |
                windows.FILE_FLAG_OVERLAPPED,
            windows.PIPE_TYPE_BYTE,
            1,
            4096,
            4096,
            0,
            &security_attributes,
        );
        if (self.in_pipe == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(self.in_pipe);

        var security_attributes_read = security_attributes;
        self.raw_in = windows.kernel32.CreateFileW(
            pipe_path_w.ptr,
            windows.GENERIC_READ,
            0,
            &security_attributes_read,
            windows.OPEN_EXISTING,
            windows.FILE_ATTRIBUTE_NORMAL,
            null,
        );
        if (self.raw_in == windows.INVALID_HANDLE_VALUE) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer _ = windows.CloseHandle(self.raw_in);

        // wsl.exe stdin: helper_in (frames) -> child_stdin.
        if (windows.exp.kernel32.CreatePipe(&self.child_stdin, &self.helper_in, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(self.child_stdin);
            _ = windows.CloseHandle(self.helper_in);
        }

        // wsl.exe stdout: child_stdout -> out_pipe (raw).
        if (windows.exp.kernel32.CreatePipe(&self.out_pipe, &self.child_stdout, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(self.out_pipe);
            _ = windows.CloseHandle(self.child_stdout);
        }

        // Only the two child ends may leak into wsl.exe; CreateProcessW
        // is called with bInheritHandles=TRUE.
        try windows.SetHandleInformation(self.child_stdin, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT);
        try windows.SetHandleInformation(self.child_stdout, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT);
        try windows.SetHandleInformation(self.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.helper_in, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.raw_in, windows.HANDLE_FLAG_INHERIT, 0);

        return self;
    }

    /// Start the input pump. Split from `open` so the caller can close
    /// the child-side handles after spawning wsl.exe first.
    pub fn startPump(self: *WslBridgePty) std.Thread.SpawnError!void {
        self.pump = try std.Thread.spawn(.{}, pumpThread, .{self});
    }

    /// Close our copies of the ends wsl.exe inherited, so pipe EOF
    /// tracks the child process and not this side.
    pub fn closeChildSide(self: *WslBridgePty) void {
        _ = windows.CloseHandle(self.child_stdin);
        _ = windows.CloseHandle(self.child_stdout);
        self.child_stdin = windows.INVALID_HANDLE_VALUE;
        self.child_stdout = windows.INVALID_HANDLE_VALUE;
    }

    pub fn deinit(self: *WslBridgePty) void {
        // Orderly teardown for a still-alive session: the helper turns
        // this frame into a SIGHUP for its child.
        self.write_mutex.lock();
        writeAll(self.helper_in, &.{ frame_hangup, 0, 0 }) catch {};
        self.write_mutex.unlock();

        // Closing the termio write side unblocks the pump's read.
        _ = windows.CloseHandle(self.in_pipe);
        if (self.pump) |t| t.join();
        _ = windows.CloseHandle(self.helper_in);
        _ = windows.CloseHandle(self.raw_in);

        _ = windows.CloseHandle(self.out_pipe);
        if (self.child_stdin != windows.INVALID_HANDLE_VALUE) self.closeChildSide();
        self.* = undefined;
    }

    pub fn getSize(self: WslBridgePty) winsize {
        return self.size;
    }

    pub const SetSizeError = error{ResizeFailed};

    pub fn setSize(self: *WslBridgePty, size: winsize) SetSizeError!void {
        var frame: [11]u8 = undefined;
        frame[0] = frame_resize;
        std.mem.writeInt(u16, frame[1..3], 8, .little);
        std.mem.writeInt(u16, frame[3..5], size.ws_col, .little);
        std.mem.writeInt(u16, frame[5..7], size.ws_row, .little);
        std.mem.writeInt(u16, frame[7..9], size.ws_xpixel, .little);
        std.mem.writeInt(u16, frame[9..11], size.ws_ypixel, .little);

        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        writeAll(self.helper_in, &frame) catch return error.ResizeFailed;
        self.size = size;
    }

    fn pumpThread(self: *WslBridgePty) void {
        var buf: [32 * 1024]u8 = undefined;
        pump: while (true) {
            const n = windows.ReadFile(self.raw_in, &buf, null) catch break;
            if (n == 0) break;

            var remaining: []const u8 = buf[0..n];
            while (remaining.len > 0) {
                const take = @min(remaining.len, max_frame_payload);
                var header: [3]u8 = undefined;
                header[0] = frame_data;
                std.mem.writeInt(u16, header[1..3], @intCast(take), .little);

                self.write_mutex.lock();
                defer self.write_mutex.unlock();
                writeAll(self.helper_in, &header) catch break :pump;
                writeAll(self.helper_in, remaining[0..take]) catch break :pump;
                remaining = remaining[take..];
            }
        }
    }

    fn writeAll(handle: windows.HANDLE, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            off += try windows.WriteFile(handle, bytes[off..], null);
        }
    }
};
