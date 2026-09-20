//! Windows side of the WSL direct pty bridge.
//!
//! The pipe plumbing termio plugs into. wsl.exe runs the in-distro half
//! (helper.zig), which owns a real Linux pty and relays its bytes over
//! stdio untouched. Both stdio directions of the helper are frame
//! streams while termio only speaks raw bytes, so a pump thread sits on
//! each side: the input pump reframes termio's raw writes, the output
//! pump deframes the helper's stdout into pty data for termio and
//! captures out-of-band reports (the foreground process name). wsl.exe's
//! stderr is plain diagnostics text and is relayed into the terminal
//! stream as-is. Resize frames are written directly by `setSize`,
//! serialized with the input pump by a mutex.
//!
//!   termio write -> in_pipe -> [pump: frame] ---> wsl.exe -> helper pty
//!   termio read  <- out_pipe <- [pump: deframe] <- wsl.exe <- helper pty

const Pty = @This();

const std = @import("std");
const windows = std.os.windows;
const w32 = @import("windows.zig");
const protocol = @import("protocol.zig");

const log = std.log.scoped(.wsl_bridge);

/// Terminal size, laid out like the POSIX struct so termio's pty size
/// literals coerce to it.
pub const winsize = extern struct {
    ws_row: u16 = 100,
    ws_col: u16 = 80,
    ws_xpixel: u16 = 800,
    ws_ypixel: u16 = 600,
};

// Process-wide counter for pipe names, kept separate from
// WindowsPty's so neither can collide with the other.
var pipe_name_counter = std.atomic.Value(u32).init(1);

/// The mutexes below block through this Io.
io: std.Io,

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

write_mutex: std.Io.Mutex,
/// Serializes out_write between the output pump and the stderr relay.
out_mutex: std.Io.Mutex,
pump: ?std.Thread,
out_pump: ?std.Thread,
err_pump: ?std.Thread,
size: winsize,

/// Latest foreground process name reported by the helper, for the
/// host's tab-title poll. A Windows-side pid lookup cannot see into
/// the distro, so the helper resolves the name and reports it.
fg_mutex: std.Io.Mutex,
fg_name: [256]u8,
fg_name_len: usize,

/// A kill-on-close job holding wsl.exe. When this process exits —
/// cleanly or by crash — the OS closes this handle, the job empties,
/// and wsl.exe dies, which the helper detects (stdout POLLERR) and
/// tears its pty down. Without it a hard kill orphans the whole
/// wsl.exe tree and leaves the helper running in the distro.
job: ?windows.HANDLE,

pub const OpenError = w32.Error || std.Thread.SpawnError;

pub fn open(io: std.Io, size: winsize) OpenError!Pty {
    var self: Pty = .{
        .io = io,
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
        .write_mutex = .init,
        .out_mutex = .init,
        .pump = null,
        .out_pump = null,
        .err_pump = null,
        .size = size,
        .fg_mutex = .init,
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
        .bInheritHandle = w32.FALSE,
        .lpSecurityDescriptor = null,
    };

    self.in_pipe = w32.CreateNamedPipeW(
        pipe_path_w.ptr,
        w32.PIPE_ACCESS_OUTBOUND |
            w32.FILE_FLAG_FIRST_PIPE_INSTANCE |
            w32.FILE_FLAG_OVERLAPPED,
        // Same as WindowsPty's in_pipe: the pipe stands in for an
        // anonymous one and is connected below, by this process. Named
        // pipes take SMB clients unless told otherwise, and nothing off
        // this machine has any business racing for the keystrokes
        // written here.
        w32.PIPE_TYPE_BYTE | w32.PIPE_REJECT_REMOTE_CLIENTS,
        1,
        4096,
        4096,
        0,
        &security_attributes,
    );
    if (self.in_pipe == windows.INVALID_HANDLE_VALUE) return w32.lastError();
    errdefer windows.CloseHandle(self.in_pipe);

    var security_attributes_read = security_attributes;
    self.raw_in = w32.CreateFileW(
        pipe_path_w.ptr,
        w32.GENERIC_READ,
        0,
        &security_attributes_read,
        w32.OPEN_EXISTING,
        w32.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (self.raw_in == windows.INVALID_HANDLE_VALUE) return w32.lastError();
    errdefer windows.CloseHandle(self.raw_in);

    // wsl.exe stdin: helper_in (frames) -> child_stdin.
    if (w32.CreatePipe(&self.child_stdin, &self.helper_in, null, 0) == w32.FALSE) return w32.lastError();
    errdefer {
        windows.CloseHandle(self.child_stdin);
        windows.CloseHandle(self.helper_in);
    }

    // wsl.exe stdout: child_stdout -> wsl_out (frame stream).
    if (w32.CreatePipe(&self.wsl_out, &self.child_stdout, null, 0) == w32.FALSE) return w32.lastError();
    errdefer {
        windows.CloseHandle(self.wsl_out);
        windows.CloseHandle(self.child_stdout);
    }

    // wsl.exe stderr: child_stderr -> wsl_err (diagnostics text).
    if (w32.CreatePipe(&self.wsl_err, &self.child_stderr, null, 0) == w32.FALSE) return w32.lastError();
    errdefer {
        windows.CloseHandle(self.wsl_err);
        windows.CloseHandle(self.child_stderr);
    }

    // termio-facing output: pumps write deframed bytes to out_write,
    // termio reads out_pipe raw.
    if (w32.CreatePipe(&self.out_pipe, &self.out_write, null, 0) == w32.FALSE) return w32.lastError();
    errdefer {
        windows.CloseHandle(self.out_pipe);
        windows.CloseHandle(self.out_write);
    }

    // Only the three child ends may leak into wsl.exe; CreateProcessW
    // is called with bInheritHandles=TRUE.
    try w32.setHandleInformation(self.child_stdin, w32.HANDLE_FLAG_INHERIT, w32.HANDLE_FLAG_INHERIT);
    try w32.setHandleInformation(self.child_stdout, w32.HANDLE_FLAG_INHERIT, w32.HANDLE_FLAG_INHERIT);
    try w32.setHandleInformation(self.child_stderr, w32.HANDLE_FLAG_INHERIT, w32.HANDLE_FLAG_INHERIT);
    try w32.setHandleInformation(self.out_pipe, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.out_write, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.helper_in, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.in_pipe, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.raw_in, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.wsl_out, w32.HANDLE_FLAG_INHERIT, 0);
    try w32.setHandleInformation(self.wsl_err, w32.HANDLE_FLAG_INHERIT, 0);

    return self;
}

/// Start the pumps. Split from `open` so the caller can close the
/// child-side handles after spawning wsl.exe first. On a partial
/// failure the started threads stay recorded; deinit joins them
/// after the caller has killed wsl.exe.
pub fn startPump(self: *Pty) std.Thread.SpawnError!void {
    self.pump = try std.Thread.spawn(.{}, pumpThread, .{self});
    self.out_pump = try std.Thread.spawn(.{}, outPumpThread, .{self});
    self.err_pump = try std.Thread.spawn(.{}, errPumpThread, .{self});
}

/// Latest helper-reported foreground process name, copied into
/// `out`. Returns the copied length (0 = nothing reported yet).
pub fn foregroundName(self: *Pty, out: []u8) usize {
    self.fg_mutex.lockUncancelable(self.io);
    defer self.fg_mutex.unlock(self.io);
    const n = @min(out.len, self.fg_name_len);
    @memcpy(out[0..n], self.fg_name[0..n]);
    return n;
}

/// Put wsl.exe into a kill-on-close job so it dies with this
/// process. Best-effort: a failure only forfeits crash cleanup, so
/// it is logged and swallowed rather than failing the session.
pub fn superviseProcess(self: *Pty, process: windows.HANDLE) void {
    const job = w32.CreateJobObjectW(null, null) orelse {
        log.warn("wsl bridge: CreateJobObject failed, no crash cleanup", .{});
        return;
    };
    var info: w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
        w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    );
    info.BasicLimitInformation.LimitFlags = w32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (w32.SetInformationJobObject(
        job,
        w32.JobObjectExtendedLimitInformation,
        &info,
        @sizeOf(w32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == w32.FALSE or w32.AssignProcessToJobObject(job, process) == w32.FALSE) {
        log.warn("wsl bridge: job setup failed, no crash cleanup", .{});
        windows.CloseHandle(job);
        return;
    }
    self.job = job;
}

/// Close our copies of the ends wsl.exe inherited, so pipe EOF
/// tracks the child process and not this side.
pub fn closeChildSide(self: *Pty) void {
    windows.CloseHandle(self.child_stdin);
    windows.CloseHandle(self.child_stdout);
    windows.CloseHandle(self.child_stderr);
    self.child_stdin = windows.INVALID_HANDLE_VALUE;
    self.child_stdout = windows.INVALID_HANDLE_VALUE;
    self.child_stderr = windows.INVALID_HANDLE_VALUE;
}

pub fn deinit(self: *Pty) void {
    // Orderly teardown for a still-alive session: the helper turns
    // this frame into a SIGHUP for its child.
    self.write_mutex.lockUncancelable(self.io);
    writeAll(self.helper_in, &protocol.header(.hangup, 0)) catch {};
    self.write_mutex.unlock(self.io);

    // Closing the termio write side unblocks the input pump's read.
    // The output pumps end on their own once wsl.exe is dead (the
    // caller kills it before deinit) and their pipes break.
    windows.CloseHandle(self.in_pipe);
    if (self.pump) |t| t.join();
    if (self.out_pump) |t| t.join();
    if (self.err_pump) |t| t.join();
    windows.CloseHandle(self.helper_in);
    windows.CloseHandle(self.raw_in);
    windows.CloseHandle(self.wsl_out);
    windows.CloseHandle(self.wsl_err);

    windows.CloseHandle(self.out_write);
    windows.CloseHandle(self.out_pipe);
    if (self.child_stdin != windows.INVALID_HANDLE_VALUE) self.closeChildSide();

    // Closing the job here kills wsl.exe if it is still alive; on a
    // clean close the hangup above already wound it down.
    if (self.job) |job| windows.CloseHandle(job);
    self.* = undefined;
}

pub fn getSize(self: Pty) winsize {
    return self.size;
}

pub const SetSizeError = error{ResizeFailed};

pub fn setSize(self: *Pty, size: winsize) SetSizeError!void {
    const resize: protocol.Resize = .{
        .cols = size.ws_col,
        .rows = size.ws_row,
        .xpixel = size.ws_xpixel,
        .ypixel = size.ws_ypixel,
    };
    const frame = protocol.header(.resize, protocol.Resize.payload_len) ++ resize.encode();

    self.write_mutex.lockUncancelable(self.io);
    defer self.write_mutex.unlock(self.io);
    writeAll(self.helper_in, &frame) catch return error.ResizeFailed;
    self.size = size;
}

/// Deframes wsl.exe's stdout: pty data goes to out_write for
/// termio, foreground-name reports go to the fg_name slot.
fn outPumpThread(self: *Pty) void {
    var parser: protocol.Parser = .{};
    var buf: [64 * 1024]u8 = undefined;
    read: while (true) {
        const n = w32.readFile(self.wsl_out, &buf) catch break;
        if (n == 0) break;

        var remaining: []const u8 = buf[0..n];
        while (remaining.len > 0) {
            remaining = remaining[parser.push(remaining)..];
            while (parser.next()) |frame| self.handleFrame(frame) catch break :read;
        }
    }
}

/// Apply one stdout frame from the helper.
fn handleFrame(self: *Pty, frame: protocol.Frame) !void {
    switch (frame.kind) {
        .data => try self.writeOut(frame.payload),
        .fg_name => {
            self.fg_mutex.lockUncancelable(self.io);
            defer self.fg_mutex.unlock(self.io);
            const n = @min(self.fg_name.len, frame.payload.len);
            @memcpy(self.fg_name[0..n], frame.payload[0..n]);
            self.fg_name_len = n;
        },
        else => {}, // Unknown type: skip for forward compatibility.
    }
}

/// wsl.exe's stderr is plain diagnostics text (a distro-not-found
/// error, a helper fatal); relay it into the terminal stream so
/// failures stay visible.
fn errPumpThread(self: *Pty) void {
    var buf: [4 * 1024]u8 = undefined;
    while (true) {
        const n = w32.readFile(self.wsl_err, &buf) catch break;
        if (n == 0) break;
        self.writeOut(buf[0..n]) catch break;
    }
}

fn writeOut(self: *Pty, bytes: []const u8) !void {
    self.out_mutex.lockUncancelable(self.io);
    defer self.out_mutex.unlock(self.io);
    try writeAll(self.out_write, bytes);
}

fn pumpThread(self: *Pty) void {
    var buf: [32 * 1024]u8 = undefined;
    pump: while (true) {
        const n = w32.readFile(self.raw_in, &buf) catch break;
        if (n == 0) break;

        var remaining: []const u8 = buf[0..n];
        while (remaining.len > 0) {
            const take = @min(remaining.len, protocol.max_payload);

            self.write_mutex.lockUncancelable(self.io);
            defer self.write_mutex.unlock(self.io);
            writeAll(self.helper_in, &protocol.header(.data, take)) catch break :pump;
            writeAll(self.helper_in, remaining[0..take]) catch break :pump;
            remaining = remaining[take..];
        }
    }
}

fn writeAll(handle: windows.HANDLE, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try w32.writeFile(handle, bytes[off..]);
    }
}
