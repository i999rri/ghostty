//! WSL-side relay for the GhosttyWin32 direct pty bridge.
//!
//! Runs inside the WSL distro, spawned by the Windows host through
//! `wsl.exe`. Opens a real Linux pty, executes the requested command
//! on its slave side, and relays bytes between the pty master and the
//! stdio pipes that `wsl.exe` extends to the Windows side. This gives
//! the Windows terminal a byte-exact VT stream, bypassing ConPTY's
//! re-rendering entirely.
//!
//! Both stdio directions carry the frames described in protocol.zig;
//! stderr stays plain text for diagnostics.
//!
//! Linux only. std's POSIX layer moved behind std.Io in Zig 0.16, so
//! this program talks to the kernel through std.os.linux directly.

const std = @import("std");
const linux = std.os.linux;
const protocol = @import("protocol.zig");

const fd_t = linux.fd_t;
const pid_t = linux.pid_t;
/// The environment block as the loader hands it over.
const Environ = [:null]const ?[*:0]const u8;

const stdin_fd: fd_t = linux.STDIN_FILENO;
const stdout_fd: fd_t = linux.STDOUT_FILENO;

const Args = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    term: ?[:0]const u8 = null,
    command: []const [*:0]const u8 = &.{},
};

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ghostty-wsl-bridge: " ++ fmt ++ "\n", args);
    linux.exit(1);
}

/// The errno of a raw syscall result, or null when it succeeded.
fn failed(rc: usize) ?linux.E {
    const e = linux.errno(rc);
    return if (e == .SUCCESS) null else e;
}

fn parseArgs(argv: []const [*:0]const u8) Args {
    var result: Args = .{};
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--")) {
            result.command = argv[i + 1 ..];
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

/// The value of `name` in the environment block, if set.
fn envGet(environ: Environ, name: []const u8) ?[:0]const u8 {
    for (environ) |entry_opt| {
        const entry = entry_opt orelse break;
        const s = std.mem.span(entry);
        if (s.len > name.len and s[name.len] == '=' and std.mem.eql(u8, s[0..name.len], name)) {
            return s[name.len + 1 ..];
        }
    }
    return null;
}

const Pty = struct {
    master: fd_t,
    slave_path: [32:0]u8,

    fn open(cols: u16, rows: u16) Pty {
        const rc = linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0);
        if (failed(rc)) |e| fatal("opening /dev/ptmx failed: {t}", .{e});
        const master: fd_t = @intCast(rc);

        var unlock: c_int = 0;
        if (failed(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != null)
            fatal("unlocking pty failed", .{});

        var pts_num: c_uint = 0;
        if (failed(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&pts_num))) != null)
            fatal("querying pts number failed", .{});

        var result: Pty = .{ .master = master, .slave_path = undefined };
        _ = std.fmt.bufPrintZ(&result.slave_path, "/dev/pts/{d}", .{pts_num}) catch
            unreachable;

        result.setSize(cols, rows, 0, 0);
        return result;
    }

    fn setSize(self: *const Pty, cols: u16, rows: u16, xpixel: u16, ypixel: u16) void {
        const ws: std.posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = xpixel,
            .ypixel = ypixel,
        };
        _ = linux.ioctl(self.master, linux.T.IOCSWINSZ, @intFromPtr(&ws));
    }
};

/// Read a whole file into memory, up to `max_bytes`.
fn readFileAlloc(alloc: std.mem.Allocator, path: [*:0]const u8, max_bytes: usize) ![]u8 {
    const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
    if (failed(rc) != null) return error.OpenFailed;
    const fd: fd_t = @intCast(rc);
    defer _ = linux.close(fd);

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    while (true) {
        try list.ensureUnusedCapacity(alloc, 4096);
        const spare = list.unusedCapacitySlice();
        const n = linux.read(fd, spare.ptr, spare.len);
        if (failed(n)) |e| switch (e) {
            .INTR => continue,
            else => return error.ReadFailed,
        };
        if (n == 0) break;
        list.items.len += n;
        if (list.items.len > max_bytes) return error.FileTooBig;
    }
    return list.toOwnedSlice(alloc);
}

/// Build the child's environment: the inherited one, with TERM replaced
/// when the host asked for a specific value.
fn childEnv(alloc: std.mem.Allocator, environ: Environ, term: ?[:0]const u8) [*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    for (environ) |entry_opt| {
        const entry = entry_opt orelse break;
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

/// The user's shell: $SHELL when set, else the passwd entry for the
/// current uid, else /bin/sh. `wsl.exe --exec` bypasses WSL's own
/// shell resolution, so the helper redoes it.
fn resolveShell(alloc: std.mem.Allocator, environ: Environ) [:0]const u8 {
    if (envGet(environ, "SHELL")) |shell| return shell;

    fallback: {
        const contents = readFileAlloc(alloc, "/etc/passwd", 1024 * 1024) catch
            break :fallback;
        const uid = linux.geteuid();
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            // name:password:uid:gid:gecos:home:shell
            var fields = std.mem.splitScalar(u8, line, ':');
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const entry_uid = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
            if (entry_uid != uid) continue;
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            _ = fields.next() orelse continue;
            const shell = fields.next() orelse continue;
            if (shell.len == 0) break :fallback;
            return alloc.dupeZ(u8, shell) catch break :fallback;
        }
    }

    return "/bin/sh";
}

/// Paths to try for `file` in order: the file itself when it names a
/// directory component, else each $PATH entry joined with it. Resolved
/// before forking so the child only has to loop over execve.
fn execCandidates(alloc: std.mem.Allocator, environ: Environ, file: [*:0]const u8) []const [*:0]const u8 {
    var list: std.ArrayList([*:0]const u8) = .empty;
    const name = std.mem.span(file);
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        list.append(alloc, file) catch fatal("out of memory", .{});
        return list.items;
    }

    const path_list = envGet(environ, "PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path_list, ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrintSentinel(alloc, "{s}/{s}", .{ dir, name }, 0) catch
            fatal("out of memory", .{});
        list.append(alloc, full) catch fatal("out of memory", .{});
    }
    return list.items;
}

fn spawnChild(pty: *const Pty, args: Args, alloc: std.mem.Allocator, environ: Environ) pid_t {
    // Resolve everything before forking; allocation after fork is unsafe.
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    var exec_file: [*:0]const u8 = undefined;
    if (args.command.len > 0) {
        for (args.command) |arg| argv.append(alloc, arg) catch fatal("out of memory", .{});
        exec_file = args.command[0];
    } else {
        const shell = resolveShell(alloc, environ);
        // Login shell convention: leading "-" in argv[0]. A terminal
        // session is expected to load the user's profile.
        const argv0 = std.fmt.allocPrintSentinel(alloc, "-{s}", .{std.fs.path.basename(shell)}, 0) catch
            fatal("out of memory", .{});
        argv.append(alloc, argv0) catch fatal("out of memory", .{});
        exec_file = shell;
    }
    argv.append(alloc, null) catch fatal("out of memory", .{});
    const argv_z: [*:null]const ?[*:0]const u8 = @ptrCast(argv.items.ptr);
    const envp = childEnv(alloc, environ, args.term);
    const candidates = execCandidates(alloc, environ, exec_file);

    const rc = linux.fork();
    if (failed(rc)) |e| fatal("fork failed: {t}", .{e});
    const pid: pid_t = @intCast(rc);
    if (pid != 0) return pid;

    // Child: new session, slave pty as controlling terminal and stdio.
    if (failed(linux.setsid()) != null) linux.exit(1);
    const slave_rc = linux.open(&pty.slave_path, .{ .ACCMODE = .RDWR }, 0);
    if (failed(slave_rc) != null) linux.exit(1);
    const slave: fd_t = @intCast(slave_rc);
    if (failed(linux.ioctl(slave, linux.T.IOCSCTTY, 0)) != null) linux.exit(1);
    if (failed(linux.dup2(slave, 0)) != null) linux.exit(1);
    if (failed(linux.dup2(slave, 1)) != null) linux.exit(1);
    if (failed(linux.dup2(slave, 2)) != null) linux.exit(1);
    if (slave > 2) _ = linux.close(slave);
    _ = linux.close(pty.master);

    // execve only returns on failure; the next candidate gets its turn.
    var last: linux.E = .NOENT;
    for (candidates) |path| {
        last = linux.errno(linux.execve(path, argv_z, envp));
    }
    std.debug.print("ghostty-wsl-bridge: exec failed: {t}\n", .{last});
    linux.exit(127);
}

fn writeAll(fd: fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = linux.write(fd, bytes[off..].ptr, bytes.len - off);
        if (failed(rc)) |e| switch (e) {
            .INTR => continue,
            else => return error.WriteFailed,
        };
        off += rc;
    }
}

fn writeFrame(fd: fd_t, kind: protocol.Type, payload: []const u8) !void {
    try writeAll(fd, &protocol.header(kind, payload.len));
    try writeAll(fd, payload);
}

fn writeDataFrames(fd: fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len > 0) {
        const take = @min(remaining.len, protocol.max_payload);
        try writeFrame(fd, .data, remaining[0..take]);
        remaining = remaining[take..];
    }
}

/// A process's comm: the kernel's short command name, as read from
/// /proc/<pid>/comm. Held by value, so the tracker keeps names across
/// polls without an allocator; it changes when the process execs.
const Comm = struct {
    /// TASK_COMM_LEN, the kernel's limit including the trailing NUL.
    const max_len = 16;

    bytes: [max_len]u8 = undefined,
    len: usize = 0,

    const empty: Comm = .{};

    /// The comm of `pid`, or null when /proc has nothing for it.
    fn read(pid: i32) ?Comm {
        var path_buf: [64:0]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
        const rc = linux.open(path, .{ .ACCMODE = .RDONLY }, 0);
        if (failed(rc) != null) return null;
        const fd: fd_t = @intCast(rc);
        defer _ = linux.close(fd);

        var comm: Comm = .{};
        const n = linux.read(fd, &comm.bytes, comm.bytes.len);
        if (failed(n) != null) return null;
        comm.len = std.mem.trimEnd(u8, comm.bytes[0..n], "\n").len;
        if (comm.len == 0) return null;
        return comm;
    }

    fn slice(self: *const Comm) []const u8 {
        return self.bytes[0..self.len];
    }

    fn eql(self: *const Comm, other: *const Comm) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// The comm of the pty's foreground process, or null when the pty has
/// no foreground group or /proc has nothing for it.
fn readForegroundComm(master: fd_t) ?Comm {
    var pgrp: pid_t = 0;
    if (failed(linux.tcgetpgrp(master, &pgrp)) != null) return null;
    if (pgrp <= 0) return null;
    return Comm.read(pgrp);
}

/// Apply one stdin frame to the pty.
fn handleFrame(pty: *const Pty, frame: protocol.Frame) !void {
    switch (frame.kind) {
        .data => try writeAll(pty.master, frame.payload),
        .resize => if (protocol.Resize.decode(frame.payload)) |size| {
            pty.setSize(size.cols, size.rows, size.xpixel, size.ypixel);
        },
        .hangup => return error.Hangup,
        else => {}, // Unknown type: skip for forward compatibility.
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const environ: Environ = init.environ.block.slice;

    const args = parseArgs(init.args.vector);
    const pty = Pty.open(args.cols, args.rows);
    const child = spawnChild(&pty, args, alloc, environ);

    var parser: protocol.Parser = .{};
    var buf: [64 * 1024]u8 = undefined;

    // A broken stdout means the Windows side is gone; that surfaces as
    // an EPIPE from writeAll rather than a fatal SIGPIPE.
    const sa: linux.Sigaction = .{
        .handler = .{ .handler = linux.SIG.IGN },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };
    _ = linux.sigaction(.PIPE, &sa, null);

    // stdin EOF only ends the input side: the child keeps running and
    // its remaining output still matters, so the pty stays polled (the
    // stdin entry is parked at fd -1, which poll ignores). stdout is
    // watched with no events so its POLLERR still reports the Windows
    // side tearing the pipes down, e.g. by killing wsl.exe.
    var fds = [_]linux.pollfd{
        .{ .fd = pty.master, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stdin_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stdout_fd, .events = 0, .revents = 0 },
    };

    // The host titles the tab after the foreground comm, and a
    // Windows-side pid lookup cannot see into the distro, so the name
    // is resolved here and sent as fg_name frames.
    //
    // The helper's own comm is never sent: between fork and exec the
    // child still carries it, and a tab titled after the plumbing would
    // hide what the user is running.
    const helper_comm = Comm.read(linux.getpid()) orelse Comm.empty;
    // The comm last sent. It outlives one poll so the next one can tell
    // a change from a repeat; the host only hears about changes.
    var sent_comm: Comm = .empty;

    relay: while (true) {
        // The timeout doubles as the foreground-name poll cadence.
        if (failed(linux.poll(&fds, fds.len, 500))) |e| switch (e) {
            .INTR, .AGAIN => continue,
            else => break :relay,
        };
        // Read the foreground comm every poll, not only when the
        // foreground process group changes: a process keeps its pid
        // across exec, so a launcher that hands over to the real program
        // (NixOS wraps /bin/sh in a binary whose comm is "wrapper")
        // changes its comm without changing the group.
        fg: {
            const foreground = readForegroundComm(pty.master) orelse break :fg;
            const is_helper_itself = foreground.eql(&helper_comm);
            const already_sent = foreground.eql(&sent_comm);

            if (is_helper_itself or already_sent) break :fg;
            sent_comm = foreground;
            writeFrame(stdout_fd, .fg_name, foreground.slice()) catch break :relay;
        }

        if (fds[2].revents & (linux.POLL.HUP | linux.POLL.ERR) != 0) break :relay;

        // Drain the pty first so pending output survives child exit.
        if (fds[0].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            while (true) {
                const n = linux.read(pty.master, &buf, buf.len);
                if (failed(n) != null or n == 0) break :relay;
                writeDataFrames(stdout_fd, buf[0..n]) catch break :relay;
                if (n < buf.len) break;
            }
        }

        if (fds[1].fd >= 0 and fds[1].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) {
            const rc = linux.read(stdin_fd, &buf, buf.len);
            const n = if (failed(rc) != null) 0 else rc;
            if (n == 0) {
                fds[1].fd = -1;
            } else {
                var remaining: []const u8 = buf[0..n];
                while (remaining.len > 0) {
                    remaining = remaining[parser.push(remaining)..];
                    while (parser.next()) |frame| handleFrame(&pty, frame) catch break :relay;
                }
            }
        }
    }

    // Closing the master hangs up the child's terminal if it is still
    // alive, so the waitpid below cannot block forever.
    _ = linux.close(pty.master);
    var status: u32 = 0;
    _ = linux.waitpid(child, &status, 0);
    if (linux.W.IFEXITED(status)) linux.exit(linux.W.EXITSTATUS(status));
    if (linux.W.IFSIGNALED(status)) {
        const sig: u32 = @intFromEnum(linux.W.TERMSIG(status));
        linux.exit(@intCast(128 + (sig & 0x7f)));
    }
    linux.exit(1);
}
