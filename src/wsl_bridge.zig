//! Windows side of the WSL direct pty bridge (GhosttyWin32#206).
//!
//! ConPTY re-renders the VT stream, so a WSL session driven through it
//! never delivers the bytes applications actually wrote. The bridge
//! instead spawns `wsl.exe` running ghostty-wsl-helper (see
//! src/wsl_helper/main.zig), which owns a real Linux pty and relays its
//! bytes over stdio untouched.
//!
//! This struct provides the pipe plumbing on the Windows side. Both
//! stdio directions of the helper are frame streams while termio only
//! speaks raw bytes, so a pump thread sits on each side: the input
//! pump reframes termio's raw writes, the output pump deframes the
//! helper's stdout into pty data for termio and captures out-of-band
//! reports (the foreground process name). wsl.exe's stderr is plain
//! diagnostics text and is relayed into the terminal stream as-is.
//! Resize frames are written directly by `setSize`, serialized with
//! the input pump by a mutex.
//!
//!   termio write -> in_pipe -> [pump: frame] ---> wsl.exe -> helper pty
//!   termio read  <- out_pipe <- [pump: deframe] <- wsl.exe <- helper pty

const std = @import("std");
const windows = @import("os/main.zig").windows;
const ptypkg = @import("pty.zig");
const winsize = ptypkg.winsize;

const log = std.log.scoped(.wsl_bridge);

const frame_data: u8 = 0;
const frame_resize: u8 = 1;
const frame_hangup: u8 = 2;
const frame_fg_name: u8 = 3;
const max_frame_payload = std.math.maxInt(u16);

pub const WslBridgePty = struct {
    // Process-wide counter for pipe names, kept separate from
    // WindowsPty's so neither can collide with the other.
    var pipe_name_counter = std.atomic.Value(u32).init(1);

    /// Raw pty output, read by termio; the pumps fill it via out_write.
    out_pipe: windows.HANDLE,
    out_write: windows.HANDLE,
    /// Raw terminal input, written by termio (overlapped named pipe,
    /// required by libxev's IOCP backend).
    in_pipe: windows.HANDLE,

    /// The ends wsl.exe inherits as its stdio.
    child_stdin: windows.HANDLE,
    child_stdout: windows.HANDLE,
    child_stderr: windows.HANDLE,

    /// Frame stream into wsl.exe, shared by the pump and setSize.
    helper_in: windows.HANDLE,
    /// Raw input read side for the input pump.
    raw_in: windows.HANDLE,
    /// Frame stream out of wsl.exe, read by the output pump.
    wsl_out: windows.HANDLE,
    /// wsl.exe/helper diagnostics, relayed into the terminal stream.
    wsl_err: windows.HANDLE,

    write_mutex: std.Thread.Mutex,
    /// Serializes out_write between the output pump and the stderr relay.
    out_mutex: std.Thread.Mutex,
    pump: ?std.Thread,
    out_pump: ?std.Thread,
    err_pump: ?std.Thread,
    size: winsize,

    /// Latest foreground process name reported by the helper, for the
    /// host's tab-title poll. A Windows-side pid lookup cannot see into
    /// the distro, so the helper resolves the name and reports it.
    fg_mutex: std.Thread.Mutex,
    fg_name: [256]u8,
    fg_name_len: usize,

    /// A kill-on-close job holding wsl.exe. When this process exits —
    /// cleanly or by crash — the OS closes this handle, the job empties,
    /// and wsl.exe dies, which the helper detects (stdout POLLERR) and
    /// tears its pty down. Without it a hard kill orphans the whole
    /// wsl.exe tree and leaves the helper running in the distro.
    job: ?windows.HANDLE,

    pub const OpenError = error{Unexpected} || std.Thread.SpawnError;

    pub fn open(size: winsize) OpenError!WslBridgePty {
        var self: WslBridgePty = .{
            .job = null,
            .out_pipe = undefined,
            .out_write = undefined,
            .in_pipe = undefined,
            .child_stdin = undefined,
            .child_stdout = undefined,
            .child_stderr = undefined,
            .helper_in = undefined,
            .raw_in = undefined,
            .wsl_out = undefined,
            .wsl_err = undefined,
            .write_mutex = .{},
            .out_mutex = .{},
            .pump = null,
            .out_pump = null,
            .err_pump = null,
            .size = size,
            .fg_mutex = .{},
            .fg_name = undefined,
            .fg_name_len = 0,
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

        // wsl.exe stdout: child_stdout -> wsl_out (frame stream).
        if (windows.exp.kernel32.CreatePipe(&self.wsl_out, &self.child_stdout, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(self.wsl_out);
            _ = windows.CloseHandle(self.child_stdout);
        }

        // wsl.exe stderr: child_stderr -> wsl_err (diagnostics text).
        if (windows.exp.kernel32.CreatePipe(&self.wsl_err, &self.child_stderr, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(self.wsl_err);
            _ = windows.CloseHandle(self.child_stderr);
        }

        // termio-facing output: pumps write deframed bytes to out_write,
        // termio reads out_pipe raw.
        if (windows.exp.kernel32.CreatePipe(&self.out_pipe, &self.out_write, null, 0) == 0) {
            return windows.unexpectedError(windows.kernel32.GetLastError());
        }
        errdefer {
            _ = windows.CloseHandle(self.out_pipe);
            _ = windows.CloseHandle(self.out_write);
        }

        // Only the three child ends may leak into wsl.exe; CreateProcessW
        // is called with bInheritHandles=TRUE.
        try windows.SetHandleInformation(self.child_stdin, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT);
        try windows.SetHandleInformation(self.child_stdout, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT);
        try windows.SetHandleInformation(self.child_stderr, windows.HANDLE_FLAG_INHERIT, windows.HANDLE_FLAG_INHERIT);
        try windows.SetHandleInformation(self.out_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.out_write, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.helper_in, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.in_pipe, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.raw_in, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.wsl_out, windows.HANDLE_FLAG_INHERIT, 0);
        try windows.SetHandleInformation(self.wsl_err, windows.HANDLE_FLAG_INHERIT, 0);

        return self;
    }

    /// Start the pumps. Split from `open` so the caller can close the
    /// child-side handles after spawning wsl.exe first. On a partial
    /// failure the started threads stay recorded; deinit joins them
    /// after the caller has killed wsl.exe.
    pub fn startPump(self: *WslBridgePty) std.Thread.SpawnError!void {
        self.pump = try std.Thread.spawn(.{}, pumpThread, .{self});
        self.out_pump = try std.Thread.spawn(.{}, outPumpThread, .{self});
        self.err_pump = try std.Thread.spawn(.{}, errPumpThread, .{self});
    }

    /// Latest helper-reported foreground process name, copied into
    /// `out`. Returns the copied length (0 = nothing reported yet).
    pub fn foregroundName(self: *WslBridgePty, out: []u8) usize {
        self.fg_mutex.lock();
        defer self.fg_mutex.unlock();
        const n = @min(out.len, self.fg_name_len);
        @memcpy(out[0..n], self.fg_name[0..n]);
        return n;
    }

    /// Put wsl.exe into a kill-on-close job so it dies with this
    /// process. Best-effort: a failure only forfeits crash cleanup, so
    /// it is logged and swallowed rather than failing the session.
    pub fn superviseProcess(self: *WslBridgePty, process: windows.HANDLE) void {
        const job = windows.exp.kernel32.CreateJobObjectW(null, null) orelse {
            log.warn("wsl bridge: CreateJobObject failed, no crash cleanup", .{});
            return;
        };
        var info: windows.exp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
            windows.exp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        );
        info.BasicLimitInformation.LimitFlags = windows.exp.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (windows.exp.kernel32.SetInformationJobObject(
            job,
            windows.exp.JobObjectExtendedLimitInformation,
            &info,
            @sizeOf(windows.exp.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == 0 or windows.exp.kernel32.AssignProcessToJobObject(job, process) == 0) {
            log.warn("wsl bridge: job setup failed, no crash cleanup", .{});
            _ = windows.CloseHandle(job);
            return;
        }
        self.job = job;
    }

    /// Close our copies of the ends wsl.exe inherited, so pipe EOF
    /// tracks the child process and not this side.
    pub fn closeChildSide(self: *WslBridgePty) void {
        _ = windows.CloseHandle(self.child_stdin);
        _ = windows.CloseHandle(self.child_stdout);
        _ = windows.CloseHandle(self.child_stderr);
        self.child_stdin = windows.INVALID_HANDLE_VALUE;
        self.child_stdout = windows.INVALID_HANDLE_VALUE;
        self.child_stderr = windows.INVALID_HANDLE_VALUE;
    }

    pub fn deinit(self: *WslBridgePty) void {
        // Orderly teardown for a still-alive session: the helper turns
        // this frame into a SIGHUP for its child.
        self.write_mutex.lock();
        writeAll(self.helper_in, &.{ frame_hangup, 0, 0 }) catch {};
        self.write_mutex.unlock();

        // Closing the termio write side unblocks the input pump's read.
        // The output pumps end on their own once wsl.exe is dead (the
        // caller kills it before deinit) and their pipes break.
        _ = windows.CloseHandle(self.in_pipe);
        if (self.pump) |t| t.join();
        if (self.out_pump) |t| t.join();
        if (self.err_pump) |t| t.join();
        _ = windows.CloseHandle(self.helper_in);
        _ = windows.CloseHandle(self.raw_in);
        _ = windows.CloseHandle(self.wsl_out);
        _ = windows.CloseHandle(self.wsl_err);

        _ = windows.CloseHandle(self.out_write);
        _ = windows.CloseHandle(self.out_pipe);
        if (self.child_stdin != windows.INVALID_HANDLE_VALUE) self.closeChildSide();

        // Closing the job here kills wsl.exe if it is still alive; on a
        // clean close the hangup above already wound it down.
        if (self.job) |job| _ = windows.CloseHandle(job);
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

    /// Deframes wsl.exe's stdout: pty data goes to out_write for
    /// termio, foreground-name reports go to the fg_name slot.
    fn outPumpThread(self: *WslBridgePty) void {
        var parser: OutParser = .{};
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            const n = windows.ReadFile(self.wsl_out, &buf, null) catch break;
            if (n == 0) break;
            parser.feed(self, buf[0..n]) catch break;
        }
    }

    /// wsl.exe's stderr is plain diagnostics text (a distro-not-found
    /// error, a helper fatal); relay it into the terminal stream so
    /// failures stay visible.
    fn errPumpThread(self: *WslBridgePty) void {
        var buf: [4 * 1024]u8 = undefined;
        while (true) {
            const n = windows.ReadFile(self.wsl_err, &buf, null) catch break;
            if (n == 0) break;
            self.writeOut(buf[0..n]) catch break;
        }
    }

    fn writeOut(self: *WslBridgePty, bytes: []const u8) !void {
        self.out_mutex.lock();
        defer self.out_mutex.unlock();
        try writeAll(self.out_write, bytes);
    }

    /// Incremental parser for the helper's stdout frame stream; frames
    /// can split across reads. Mirror of the helper's stdin parser.
    const OutParser = struct {
        buf: [3 + max_frame_payload]u8 = undefined,
        len: usize = 0,

        fn feed(self: *OutParser, bridge: *WslBridgePty, bytes: []const u8) !void {
            var remaining = bytes;
            while (remaining.len > 0) {
                const space = self.buf.len - self.len;
                const take = @min(space, remaining.len);
                @memcpy(self.buf[self.len..][0..take], remaining[0..take]);
                self.len += take;
                remaining = remaining[take..];
                try self.drain(bridge);
            }
        }

        fn drain(self: *OutParser, bridge: *WslBridgePty) !void {
            var start: usize = 0;
            while (self.len - start >= 3) {
                const header = self.buf[start..][0..3];
                const payload_len = std.mem.readInt(u16, header[1..3], .little);
                if (self.len - start < 3 + payload_len) break;

                const payload = self.buf[start + 3 ..][0..payload_len];
                switch (header[0]) {
                    frame_data => try bridge.writeOut(payload),
                    frame_fg_name => {
                        bridge.fg_mutex.lock();
                        defer bridge.fg_mutex.unlock();
                        const n = @min(bridge.fg_name.len, payload.len);
                        @memcpy(bridge.fg_name[0..n], payload[0..n]);
                        bridge.fg_name_len = n;
                    },
                    else => {}, // Unknown type: skip for forward compatibility.
                }
                start += 3 + payload_len;
            }

            if (start > 0) {
                std.mem.copyForwards(u8, self.buf[0 .. self.len - start], self.buf[start..self.len]);
                self.len -= start;
            }
        }
    };

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
