//! WSL-side relay for the GhosttyWin32 direct pty bridge.
//!
//! Runs inside the WSL distro, spawned by the Windows host through
//! `wsl.exe`. Opens a real Linux pty, executes the requested command
//! on its slave side, and relays bytes between the pty master and the
//! stdio pipes that `wsl.exe` extends to the Windows side. This gives
//! the Windows terminal a byte-exact VT stream, bypassing ConPTY's
//! re-rendering entirely.
//!
//! Wire protocol: stdout carries raw pty output. stdin carries frames,
//! because resize has no side channel over a pipe:
//!
//!   [type: u8][len: u16 LE][payload: len bytes]
//!
//!   type 0 = data:   payload is written to the pty as-is
//!   type 1 = resize: payload is 4x u16 LE (cols, rows, xpixel, ypixel)
//!
//! Unknown frame types are skipped so the protocol can grow without
//! breaking older helpers.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const frame_data: u8 = 0;
const frame_resize: u8 = 1;

const frame_header_len = 3;
const max_frame_payload = std.math.maxInt(u16);

const Args = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    term: ?[:0]const u8 = null,
    command: []const [*:0]const u8 = &.{},
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ghostty-wsl-helper: " ++ fmt ++ "\n", args);
    posix.exit(1);
}

fn parseArgs() Args {
    var result: Args = .{};
    const argv = std.os.argv;
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--")) {
            result.command = @ptrCast(argv[i + 1 ..]);
            break;
        } else if (std.mem.eql(u8, arg, "--cols")) {
            i += 1;
            if (i >= argv.len) fatal("--cols requires a value", .{});
            result.cols = std.fmt.parseInt(u16, std.mem.span(argv[i]), 10) catch
                fatal("invalid --cols value", .{});
        } else if (std.mem.eql(u8, arg, "--rows")) {
            i += 1;
            if (i >= argv.len) fatal("--rows requires a value", .{});
            result.rows = std.fmt.parseInt(u16, std.mem.span(argv[i]), 10) catch
                fatal("invalid --rows value", .{});
        } else if (std.mem.eql(u8, arg, "--term")) {
            i += 1;
            if (i >= argv.len) fatal("--term requires a value", .{});
            result.term = std.mem.span(argv[i]);
        } else {
            fatal("unknown argument: {s}", .{arg});
        }
    }

    return result;
}

const Pty = struct {
    master: posix.fd_t,
    slave_path: [32:0]u8,

    fn open(cols: u16, rows: u16) Pty {
        const master = posix.open(
            "/dev/ptmx",
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        ) catch |err| fatal("opening /dev/ptmx failed: {}", .{err});

        var unlock: c_int = 0;
        if (linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)) != 0)
            fatal("unlocking pty failed", .{});

        var pts_num: c_uint = 0;
        if (linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pts_num)) != 0)
            fatal("querying pts number failed", .{});

        var result: Pty = .{ .master = master, .slave_path = undefined };
        _ = std.fmt.bufPrintZ(&result.slave_path, "/dev/pts/{d}", .{pts_num}) catch
            unreachable;

        result.setSize(cols, rows, 0, 0);
        return result;
    }

    fn setSize(self: *const Pty, cols: u16, rows: u16, xpixel: u16, ypixel: u16) void {
        const ws: posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = xpixel,
            .ypixel = ypixel,
        };
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }
};

/// Build the child's environment: the inherited one, with TERM replaced
/// when the host asked for a specific value.
fn childEnv(alloc: std.mem.Allocator, term: ?[:0]const u8) [*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (std.os.environ) |entry| {
        if (term != null and std.mem.startsWith(u8, std.mem.span(entry), "TERM="))
            continue;
        list.append(alloc, entry) catch fatal("out of memory", .{});
    }
    if (term) |value| {
        const entry = std.fmt.allocPrintSentinel(alloc, "TERM={s}", .{value}, 0) catch
            fatal("out of memory", .{});
        list.append(alloc, entry) catch fatal("out of memory", .{});
    }
    list.append(alloc, null) catch fatal("out of memory", .{});
    return @ptrCast(list.items.ptr);
}

fn spawnChild(pty: *const Pty, args: Args, alloc: std.mem.Allocator) posix.pid_t {
    // Resolve argv before forking; allocation after fork is unsafe.
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    if (args.command.len > 0) {
        for (args.command) |arg| argv.append(alloc, arg) catch fatal("out of memory", .{});
    } else {
        const shell = posix.getenvZ("SHELL") orelse "/bin/sh";
        argv.append(alloc, shell.ptr) catch fatal("out of memory", .{});
    }
    argv.append(alloc, null) catch fatal("out of memory", .{});
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);
    const envp = childEnv(alloc, args.term);

    const pid = posix.fork() catch |err| fatal("fork failed: {}", .{err});
    if (pid != 0) return pid;

    // Child: new session, slave pty as controlling terminal and stdio.
    if (linux.setsid() < 0) posix.exit(1);
    const slave = posix.openZ(
        &pty.slave_path,
        .{ .ACCMODE = .RDWR },
        0,
    ) catch posix.exit(1);
    if (linux.ioctl(slave, linux.T.IOCSCTTY, 0) != 0) posix.exit(1);
    posix.dup2(slave, 0) catch posix.exit(1);
    posix.dup2(slave, 1) catch posix.exit(1);
    posix.dup2(slave, 2) catch posix.exit(1);
    if (slave > 2) posix.close(slave);
    posix.close(pty.master);

    const err = posix.execvpeZ(argv_z[0].?, argv_z, envp);
    std.debug.print("ghostty-wsl-helper: exec failed: {}\n", .{err});
    posix.exit(127);
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        off += try posix.write(fd, bytes[off..]);
    }
}

/// Incremental parser for the stdin frame stream. Frames can split
/// across reads, so bytes accumulate here until a frame completes.
const FrameParser = struct {
    buf: [frame_header_len + max_frame_payload]u8 = undefined,
    len: usize = 0,

    fn feed(self: *FrameParser, pty: *const Pty, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const space = self.buf.len - self.len;
            const take = @min(space, remaining.len);
            @memcpy(self.buf[self.len..][0..take], remaining[0..take]);
            self.len += take;
            remaining = remaining[take..];
            try self.drain(pty);
        }
    }

    fn drain(self: *FrameParser, pty: *const Pty) !void {
        var start: usize = 0;
        while (self.len - start >= frame_header_len) {
            const header = self.buf[start..][0..frame_header_len];
            const payload_len = std.mem.readInt(u16, header[1..3], .little);
            if (self.len - start < frame_header_len + payload_len) break;

            const payload = self.buf[start + frame_header_len ..][0..payload_len];
            switch (header[0]) {
                frame_data => try writeAll(pty.master, payload),
                frame_resize => if (payload_len >= 8) pty.setSize(
                    std.mem.readInt(u16, payload[0..2], .little),
                    std.mem.readInt(u16, payload[2..4], .little),
                    std.mem.readInt(u16, payload[4..6], .little),
                    std.mem.readInt(u16, payload[6..8], .little),
                ),
                else => {}, // Unknown type: skip for forward compatibility.
            }
            start += frame_header_len + payload_len;
        }

        if (start > 0) {
            std.mem.copyForwards(u8, self.buf[0 .. self.len - start], self.buf[start..self.len]);
            self.len -= start;
        }
    }
};

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();

    const args = parseArgs();
    const pty = Pty.open(args.cols, args.rows);
    const child = spawnChild(&pty, args, alloc);

    var parser: FrameParser = .{};
    var buf: [64 * 1024]u8 = undefined;

    // A broken stdout means the Windows side is gone; that surfaces as
    // an EPIPE from writeAll rather than a fatal SIGPIPE.
    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(posix.SIG.PIPE, &sa, null);

    // Entry 0 is the pty master so the loop can keep polling it alone
    // after stdin reaches EOF: EOF only ends the input side, while the
    // child keeps running and its remaining output still matters.
    var fds = [_]posix.pollfd{
        .{ .fd = pty.master, .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 },
    };
    var nfds: usize = fds.len;

    relay: while (true) {
        _ = posix.poll(fds[0..nfds], -1) catch |err| switch (err) {
            error.SystemResources => continue,
            else => break :relay,
        };

        // Drain the pty first so pending output survives child exit.
        if (fds[0].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            while (true) {
                const n = posix.read(pty.master, &buf) catch break :relay;
                if (n == 0) break :relay;
                writeAll(posix.STDOUT_FILENO, buf[0..n]) catch break :relay;
                if (n < buf.len) break;
            }
        }

        if (nfds > 1 and fds[1].revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR) != 0) {
            const n = posix.read(posix.STDIN_FILENO, &buf) catch 0;
            if (n == 0) {
                nfds = 1;
            } else {
                parser.feed(&pty, buf[0..n]) catch break :relay;
            }
        }
    }

    // Closing the master hangs up the child's terminal if it is still
    // alive, so the waitpid below cannot block forever.
    posix.close(pty.master);
    const res = posix.waitpid(child, 0);
    if (posix.W.IFEXITED(res.status)) posix.exit(posix.W.EXITSTATUS(res.status));
    if (posix.W.IFSIGNALED(res.status)) posix.exit(128 +| @as(u8, @truncate(posix.W.TERMSIG(res.status))));
    posix.exit(1);
}
