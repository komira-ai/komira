//! What the gate's tests share (not part of the tool).
//!
//! `runGate` forks a child H that calls `gate.entry` with the given argv in
//! a working directory of the test's own, its stdout and stderr in files, and
//! the platform's exec replaced by `fixture`: the "test" the gate supervises
//! is then a child of the test binary that runs a behaviour picked by its
//! program name (the path's last component) and its arguments, with the
//! argv and environment the gate built for it. No shell stand-in is used.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const gate = @import("gate.zig");
const supervise = @import("supervise.zig");
const proctab = @import("proctab.zig");
const proctab_darwin = if (sys.is_darwin) @import("proctab_darwin.zig") else struct {};

pub const Result = struct {
    status: u8,
    out: []const u8,
    err: []const u8,
    /// What H's kill and sleep calls did, one line each, in order:
    /// `t=<fake ms> <SIG> <target>` and `t=<fake ms> sleep <ms>`. The
    /// target is `C` (the program), `-C` (its group), `M<k>` (a process the
    /// tree kill stopped, in order) or `other`. `t` is 0 without `clock`.
    events: []const u8,
};

pub const Opts = struct {
    /// Called in H before the gate runs: replace `supervise.plat` fields.
    setup: ?*const fn () void = null,
    /// H's environment; null keeps the test binary's.
    env: ?[]const []const u8 = null,
    /// Sent to H once the fixture says it is up (`announceReady`).
    signal: ?u8 = null,
    /// Run H on a clock the test owns: `supervise.plat.now_ms` reads it and
    /// the loop's tick and the survivor scan's nap move it. It moves only
    /// after the fixture has said it is up, and a tick that finds C exited
    /// or a signal pending does not move it. Nothing in the run waits for
    /// real time, so the time-dependent decisions (the limits, the grace
    /// periods, the survivor wait) are made on exact millisecond values.
    clock: bool = false,
};

/// A fresh directory under $TMPDIR.
pub fn tempDir(alloc: std.mem.Allocator) ![]const u8 {
    const base = std.posix.getenv("TMPDIR") orelse "/tmp";
    var suffix: [6]u8 = undefined;
    sys.randomSuffix(&suffix);
    const p = try std.fmt.allocPrint(alloc, "{s}/gate_test.{s}", .{ base, suffix });
    try std.fs.cwd().makePath(p);
    return p;
}

pub fn writeFile(path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(bytes);
}

pub fn readFile(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, 1 << 28);
}

pub fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// The busybox the zig_test action's PATH holds applets of.
pub fn busybox(alloc: std.mem.Allocator) ![]const u8 {
    const path = std.posix.getenv("PATH") orelse return error.NoPath;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |d| {
        const sh = try std.fmt.allocPrint(alloc, "{s}/sh", .{d});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const target = std.fs.cwd().readLink(sh, &buf) catch continue;
        return alloc.dupe(u8, target);
    }
    return error.NoBusybox;
}

// ---- the test's clock and event record (in H and below it) -----------------

/// Set by runGate before the fork, so H and the fixture see them.
var run_dir: ?[]const u8 = null;
var ready_r: sys.fd_t = -1;
var ready_w: sys.fd_t = -1;
var fake_now: u64 = 0;
var latched = false;
var group_killed = false;
var stopped: [64]i32 = undefined;
var stopped_n: usize = 0;

fn appendTo(name: []const u8, line: []const u8) void {
    const dir = run_dir orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, name }) catch return;
    const f = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    f.writeAll(line) catch return;
}

/// The program's pid, for the event record (a gate run may start the program
/// more than once: the last one is the one a kill is named for).
fn writeCpid() void {
    const dir = run_dir orelse return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/cpid", .{dir}) catch return;
    var pb: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&pb, "{d}\n", .{sys.getpid()}) catch return;
    const f = std.fs.cwd().createFile(path, .{}) catch return;
    defer f.close();
    f.writeAll(text) catch return;
}

fn cpid() i32 {
    const dir = run_dir orelse return 0;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/cpid", .{dir}) catch return 0;
    var b: [32]u8 = undefined;
    const f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    const n = f.readAll(&b) catch return 0;
    return std.fmt.parseInt(i32, std.mem.trim(u8, b[0..n], "\n"), 10) catch 0;
}

fn sigName(sig: u8, buf: []u8) []const u8 {
    return switch (sig) {
        posix.SIG.STOP => "STOP",
        posix.SIG.KILL => "KILL",
        posix.SIG.TERM => "TERM",
        posix.SIG.ALRM => "ALRM",
        else => std.fmt.bufPrint(buf, "SIG{d}", .{sig}) catch "SIG",
    };
}

/// The `kill` of H: records the call, then does it. A test that replaces
/// `plat.kill` calls this for the signals it lets through.
pub fn killRecorded(pid: sys.pid_t, sig: u8) void {
    var nb: [16]u8 = undefined;
    var tb: [32]u8 = undefined;
    const c = cpid();
    const target: []const u8 = blk: {
        if (c != 0 and pid == c) break :blk "C";
        if (c != 0 and pid == -c) {
            if (sig == posix.SIG.KILL) group_killed = true;
            break :blk "-C";
        }
        if (pid > 0) {
            if (sig == posix.SIG.STOP and stopped_n < stopped.len) {
                stopped[stopped_n] = pid;
                stopped_n += 1;
            }
            for (stopped[0..stopped_n], 0..) |m, k| {
                if (m == pid) break :blk std.fmt.bufPrint(&tb, "M{d}", .{k + 1}) catch "M";
            }
        }
        break :blk "other";
    };
    var lb: [96]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "t={d} {s} {s}\n", .{ fake_now, sigName(sig, &nb), target }) catch return;
    appendTo("events", line);
    sys.kill(pid, sig);
    // A SIGKILL cannot be refused: wait for the target to have died, so the
    // next tick of the test's clock is not spent while it is dying. (The
    // group kill waits for C, whose death is the loop's event.)
    if (sig == posix.SIG.KILL) {
        if (std.mem.eql(u8, target, "-C")) {
            waitExit(c);
        } else if (std.mem.eql(u8, target, "C") or target[0] == 'M') {
            waitExit(pid);
        }
    }
}

fn fakeNow() ?u64 {
    return fake_now;
}

fn fakeSleep(ms: u64) void {
    var lb: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&lb, "t={d} sleep {d}\n", .{ fake_now, ms }) catch return;
    appendTo("events", line);
    fake_now += ms;
}

/// The loop's tick on the test's clock. Until the fixture has said it is
/// up this waits (with no limit of its own) for C's exit, a signal, or that
/// word; afterwards a tick with nothing pending moves the clock by `ms`.
fn fakeWait(fds: supervise.WaitFds, ms: u32) void {
    while (true) {
        var p = [3]posix.pollfd{
            .{ .fd = fds.sig, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = fds.pidfd orelse -1, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = if (latched) -1 else ready_r, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&p, if (latched) 0 else -1) catch {};
        if (!latched and p[2].revents & posix.POLL.IN != 0) {
            var sink: [64]u8 = undefined;
            _ = posix.read(ready_r, &sink) catch {};
            latched = true;
        }
        if (p[0].revents != 0 or p[1].revents != 0) return;
        if (latched) {
            fake_now += ms;
            return;
        }
    }
}

/// Blocks until `pid` has exited (a zombie has exited), with no limit of
/// its own: the caller knows the process was sent a kill.
pub fn waitExit(pid: i32) void {
    if (sys.is_linux) {
        const fd = sys.pidfdOpen(pid) orelse return;
        defer posix.close(fd);
        var p = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        while (true) {
            const n = posix.poll(&p, -1) catch continue;
            if (n > 0) return;
        }
    } else if (sys.is_darwin) {
        const kq = posix.kqueue() catch return;
        defer posix.close(kq);
        var change = [1]posix.Kevent{.{
            .ident = @intCast(pid),
            .filter = std.c.EVFILT.PROC,
            .flags = std.c.EV.ADD | std.c.EV.ONESHOT,
            .fflags = std.c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
        }};
        var got: [1]posix.Kevent = undefined;
        // A process already gone is reported as an error event, which
        // also returns.
        _ = posix.kevent(kq, &change, &got, null) catch return;
    }
}

/// The group scan of H once a group kill has been sent: the kill cannot be
/// refused, so the scan waits (with no limit of its own) for every member to
/// have died before it reads the group, and a member that is still there
/// then is a survivor. Without a recorded group kill it reads at once.
fn settledMembers(alloc: std.mem.Allocator, pgid: i32) ?[]proctab.Member {
    const first = proctab.groupMembers(alloc, pgid) orelse return null;
    if (!group_killed or first.len == 0) return first;
    for (first) |m| waitExit(m.pid);
    return proctab.groupMembers(alloc, pgid);
}

/// Called by a fixture that has reached the state its test waits for
/// (sleepers started, pages touched, pid file written).
pub fn announceReady() void {
    if (ready_w >= 0) sys.writeAll(ready_w, "r");
}

pub fn runGate(alloc: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, opts: Opts) !Result {
    const io = try tempDir(alloc);
    const out_path = try std.fmt.allocPrint(alloc, "{s}/out", .{io});
    const err_path = try std.fmt.allocPrint(alloc, "{s}/err", .{io});
    const ev_path = try std.fmt.allocPrint(alloc, "{s}/events", .{io});
    const ready = try posix.pipe2(.{});
    run_dir = io;
    ready_r = ready[0];
    ready_w = ready[1];
    const h = try posix.fork();
    if (h == 0) {
        posix.chdir(cwd) catch posix.exit(250);
        const o = posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        const e = posix.open(err_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(250);
        posix.dup2(o, 1) catch posix.exit(250);
        posix.dup2(e, 2) catch posix.exit(250);
        sys.devNullOnto(0, false);
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        const a = arena.allocator();
        if (opts.env) |env| {
            const z = a.alloc([*:0]u8, env.len + 1) catch posix.exit(250);
            for (env, 0..) |kv, i| z[i] = (a.dupeZ(u8, kv) catch posix.exit(250)).ptr;
            std.os.environ = z[0..env.len];
        }
        fake_now = 0;
        latched = false;
        group_killed = false;
        stopped_n = 0;
        supervise.plat = .{ .exec = fixture, .kill = killRecorded };
        if (opts.clock) {
            supervise.plat.now_ms = fakeNow;
            supervise.plat.wait = fakeWait;
            supervise.plat.sleep_ms = fakeSleep;
            supervise.plat.group_members = settledMembers;
        }
        if (opts.setup) |f| f();
        posix.exit(gate.entry(a, argv));
    }
    posix.close(ready[1]);
    defer {
        run_dir = null;
        ready_r = -1;
        ready_w = -1;
    }
    if (opts.signal) |sig| {
        // Wait for the fixture's word (or for every holder of the pipe to
        // be gone), then signal H.
        var b: [1]u8 = undefined;
        _ = sys.readFull(ready[0], &b);
        sys.kill(h, sig);
    }
    posix.close(ready[0]);
    const status = sys.waitpid(h, false) orelse 250;
    return .{
        .status = status,
        .out = try readFile(alloc, out_path),
        .err = try readFile(alloc, err_path),
        .events = readFile(alloc, ev_path) catch "",
    };
}

/// Whether `events` holds `lines` in this order (other lines may lie
/// between them).
pub fn hasEvents(events: []const u8, lines: []const []const u8) bool {
    var it = std.mem.splitScalar(u8, events, '\n');
    var k: usize = 0;
    while (it.next()) |l| {
        if (k < lines.len and std.mem.eql(u8, l, lines[k])) k += 1;
    }
    return k == lines.len;
}

/// The `t` of the first event line that ends with `suffix`.
pub fn firstTime(events: []const u8, suffix: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, events, '\n');
    while (it.next()) |l| {
        if (!std.mem.startsWith(u8, l, "t=") or !std.mem.endsWith(u8, l, suffix)) continue;
        const sp = std.mem.indexOfScalar(u8, l, ' ') orelse continue;
        return std.fmt.parseInt(u64, l[2..sp], 10) catch null;
    }
    return null;
}

pub fn countEvents(events: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, events, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) n += 1;
    }
    return n;
}

/// Whether `pid` is alive and not a zombie (a zombie has exited).
pub fn alive(pid: i32) bool {
    if (sys.is_darwin) return proctab_darwin.alive(pid);
    var buf: [64]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{pid}) catch return false;
    const f = std.fs.cwd().openFile(p, .{}) catch return false;
    defer f.close();
    var b: [512]u8 = undefined;
    const n = f.readAll(&b) catch return false;
    const close = std.mem.lastIndexOfScalar(u8, b[0..n], ')') orelse return false;
    if (close + 2 >= n) return false;
    return b[close + 2] != 'Z' and b[close + 2] != 'X';
}

/// Waits for every pid to be gone (killed processes: the wait has no limit
/// of its own).
pub fn waitGone(pids: []const i32) void {
    for (pids) |p| waitExit(p);
}

/// Reads the pids a fixture wrote (one per line) to `path`: the fixture
/// writes them before it says it is up, so they are there once the gate has
/// returned. Fewer than `n` is an error.
pub fn pidsFrom(alloc: std.mem.Allocator, path: []const u8, n: usize) ![]i32 {
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 4096);
    var out = std.ArrayList(i32).empty;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |t| try out.append(alloc, try std.fmt.parseInt(i32, t, 10));
    if (out.items.len < n) return error.NoPids;
    return out.items;
}

// ---- the fixture ------------------------------------------------------------

fn say(comptime fmt: []const u8, a: anytype) void {
    var buf: [8192]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, a) catch return;
    sys.writeAll(1, s);
}

fn num(s: ?[]const u8, default: u64) u64 {
    const v = s orelse return default;
    return std.fmt.parseInt(u64, v, 10) catch default;
}

fn appendPid(path: []const u8, pid: i32) void {
    const f = std.fs.cwd().openFile(path, .{ .mode = .write_only }) catch std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer f.close();
    f.seekFromEnd(0) catch return;
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}\n", .{pid}) catch return;
    f.writeAll(s) catch return;
}

/// Says it starts (while it is still small, so the line is in the log
/// whenever the cap kills it mid-touch) and touches `mib` MiB. With `stop`
/// (MiB, 0: none) it says it is up and holds there, before it has touched the
/// rest, for `secs` s; otherwise it says it holds them, says it is up, and
/// sleeps `secs` s.
fn hold(mib: u64, secs: u64, stop: u64) noreturn {
    say("hog touches {d} MiB\n", .{mib});
    // Mapped, not allocated: a safe-mode allocator fills what it returns,
    // which would touch every page before the loop does.
    const mem = posix.mmap(null, mib << 20, posix.PROT.READ | posix.PROT.WRITE, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch posix.exit(99);
    var i: usize = 0;
    while (i < mem.len) : (i += 4096) {
        mem[i] = 1;
        if (stop > 0 and (i + 4096) == (stop << 20)) {
            announceReady();
            sys.sleepMs(secs * 1000);
            posix.exit(0);
        }
    }
    say("hog holds {d} MiB\n", .{mib});
    announceReady();
    sys.sleepMs(secs * 1000);
    posix.exit(0);
}

/// The supervised "test". Program names (the path's last component):
///   exit N             exits N
///   signal N           kills itself with signal N
///   sleep S [N]        says it is up, sleeps S s, exits N
///   hog MiB [S] [P]    says "hog touches MiB", touches MiB of memory, says
///                      "hog holds MiB", says it is up, holds them for S s
///                      (60), exits 0. With P (MiB): says it is up after P
///                      MiB and holds there, without the "holds" line
///   termproof          ignores SIGTERM, says it is up, sleeps an hour
///   daemon FILE KIND   forks a child (KIND: sleep or hog) that stays in the
///                      group, writes its pid to FILE, and exits 0 at once
///   spawnwait FILE     forks a 100 s sleeper, writes its pid, waits for it
///   treehog P C [S]    forks a child that holds C MiB for S s (5), then holds
///                      P MiB itself and waits for the child, exits 0 (the
///                      fork comes first, so neither counts the other's pages)
///   env [N]            prints its environment, exits N (default 3)
///   args               prints `[arg]` per argument (argv[0] too), exits 3
///   where              prints its cwd and the bytes on stdin, exits 3
///   lines N NL RC      prints `line 1`..`line N` (NL 0: no final newline), exits RC
///   pid FILE ...       writes its pid to FILE, then runs the next behaviour
///   rust_* ...         fake libtest harnesses (rust_test.zig)
pub fn fixture(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    sys.defaultSignals();
    writeCpid();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    var args = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (argv[i]) |p| : (i += 1) args.append(a, std.mem.span(p)) catch posix.exit(99);
    var env = std.ArrayList([]const u8).empty;
    i = 0;
    while (envp[i]) |p| : (i += 1) env.append(a, std.mem.span(p)) catch posix.exit(99);
    behave(a, std.fs.path.basename(std.mem.span(path)), args.items, env.items);
}

fn behave(a: std.mem.Allocator, name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const arg = struct {
        fn at(xs: []const []const u8, k: usize) ?[]const u8 {
            return if (k < xs.len) xs[k] else null;
        }
    }.at;
    if (std.mem.eql(u8, name, "exit")) posix.exit(@intCast(num(arg(args, 1), 0)));
    if (std.mem.eql(u8, name, "signal")) {
        posix.raise(@intCast(num(arg(args, 1), 9))) catch {};
        posix.exit(99);
    }
    if (std.mem.eql(u8, name, "sleep")) {
        announceReady();
        sys.sleepMs(num(arg(args, 1), 1) * 1000);
        posix.exit(@intCast(num(arg(args, 2), 0)));
    }
    if (std.mem.eql(u8, name, "hog")) hold(num(arg(args, 1), 64), num(arg(args, 2), 60), num(arg(args, 3), 0));
    if (std.mem.eql(u8, name, "termproof")) {
        // Ignores SIGTERM, says it is up, waits for the SIGKILL.
        const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
        posix.sigaction(posix.SIG.TERM, &ign, null);
        announceReady();
        sys.sleepMs(3_600_000);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "daemon")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const kind = arg(args, 2) orelse "sleep";
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            if (std.mem.eql(u8, kind, "hog")) hold(64, 60, 0);
            sys.sleepMs(3_600_000);
            posix.exit(0);
        }
        appendPid(file, pid);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "spawnwait")) {
        const file = arg(args, 1) orelse posix.exit(99);
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) {
            sys.sleepMs(3_600_000);
            posix.exit(0);
        }
        appendPid(file, sys.getpid());
        appendPid(file, pid);
        announceReady();
        _ = sys.waitpid(-1, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "treehog")) {
        const secs = num(arg(args, 3), 5);
        const pid = posix.fork() catch posix.exit(99);
        if (pid == 0) hold(num(arg(args, 2), 24), secs, 0);
        const mem = std.heap.page_allocator.alloc(u8, num(arg(args, 1), 16) << 20) catch posix.exit(99);
        var k: usize = 0;
        while (k < mem.len) : (k += 4096) mem[k] = 1;
        say("parent holds {d} MiB\n", .{mem.len >> 20});
        announceReady();
        _ = sys.waitpid(pid, false);
        posix.exit(0);
    }
    if (std.mem.eql(u8, name, "env")) {
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(@intCast(num(arg(args, 1), 3)));
    }
    if (std.mem.eql(u8, name, "args")) {
        for (args) |x| say("[{s}]\n", .{x});
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "where")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = posix.getcwd(&buf) catch "?";
        var b: [64]u8 = undefined;
        const n = posix.read(0, &b) catch 999;
        say("cwd {s}\nstdin {d}\n", .{ cwd, n });
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "rundir")) {
        // The run directory as the test sees it: TMPDIR, TEST_TMPDIR, what
        // TMPDIR holds, and whether the applets are installed beside it.
        var tmp: []const u8 = "";
        for (env) |kv| {
            if (std.mem.startsWith(u8, kv, "TMPDIR=")) tmp = kv["TMPDIR=".len..];
            if (std.mem.startsWith(u8, kv, "TMPDIR=") or std.mem.startsWith(u8, kv, "TEST_TMPDIR=")) say("{s}\n", .{kv});
        }
        var n: usize = 0;
        if (std.fs.openDirAbsolute(tmp, .{ .iterate = true })) |dir| {
            var d = dir;
            var it = d.iterate();
            while (it.next() catch null) |_| n += 1;
            d.close();
        } else |_| n = 999;
        say("entries {d}\n", .{n});
        const sh = std.fmt.allocPrint(a, "{s}/../bin/sh", .{tmp}) catch posix.exit(99);
        say("applets {}\n", .{exists(sh)});
        const mine = std.fmt.allocPrint(a, "{s}/left_by_test", .{tmp}) catch posix.exit(99);
        writeFile(mine, "x") catch {};
        posix.exit(3);
    }
    if (std.mem.eql(u8, name, "lines")) {
        const n = num(arg(args, 1), 0);
        const nl = num(arg(args, 2), 1);
        var k: u64 = 1;
        while (k <= n) : (k += 1) {
            if (k == n and nl == 0) say("line {d}", .{k}) else say("line {d}\n", .{k});
        }
        posix.exit(@intCast(num(arg(args, 3), 1)));
    }
    if (std.mem.eql(u8, name, "pid")) {
        appendPid(arg(args, 1) orelse posix.exit(99), sys.getpid());
        if (args.len < 3) posix.exit(99);
        behave(a, args[2], args[2..], env);
    }
    if (std.mem.startsWith(u8, name, "rust_")) rustFake(name, args, env);
    say("fixture: unknown behaviour {s}\n", .{name});
    posix.exit(98);
}

/// Fake libtest harnesses: `--list --format terse` lists, no argument runs.
fn rustFake(name: []const u8, args: []const []const u8, env: []const []const u8) noreturn {
    const listing = args.len > 1 and std.mem.eql(u8, args[1], "--list");
    const eq = std.mem.eql;
    if (eq(u8, name, "rust_ok")) {
        if (listing) {
            say("a::one: test\na::two: test\nb::three: test\n", .{});
        } else say("running 3 tests\ntest a::one ... ok\ntest result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_empty")) {
        if (listing) say("\n", .{}) else say("test result: ok. 0 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_listfails")) {
        if (listing) {
            sys.writeAll(2, "cannot list\n");
            posix.exit(5);
        }
        posix.exit(0);
    }
    if (eq(u8, name, "rust_ignored")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test a ... ok\ntest b ... ignored\ntest result: ok. 1 passed; 0 failed; 1 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_mismatch")) {
        if (listing) say("a: test\nb: test\n", .{}) else say("test result: ok. 1 passed; 0 failed; 0 ignored;\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_nosummary")) {
        if (listing) say("a: test\n", .{}) else say("test a ... ok\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_fails")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        say("test a ... FAILED\ntest result: FAILED. 0 passed; 1 failed; 0 ignored;\n", .{});
        posix.exit(101);
    }
    if (eq(u8, name, "rust_killed")) {
        if (!listing) posix.raise(posix.SIG.KILL) catch {};
        say("a: test\n", .{});
        posix.exit(0);
    }
    if (eq(u8, name, "rust_killedlist")) {
        posix.raise(posix.SIG.KILL) catch {};
        posix.exit(0);
    }
    if (eq(u8, name, "rust_hangs")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        announceReady();
        sys.sleepMs(3_600_000);
        posix.exit(0);
    }
    if (eq(u8, name, "rust_env")) {
        if (listing) {
            say("a: test\n", .{});
            posix.exit(0);
        }
        for (env) |kv| say("{s}\n", .{kv});
        posix.exit(7);
    }
    posix.exit(98);
}
