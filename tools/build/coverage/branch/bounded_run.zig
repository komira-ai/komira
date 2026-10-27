//! bounded_run: run one command, wait for it with an optional time limit
//! (under which it leads a session of its own), and report how it ended.
//!
//! What the coverage actions do in shell today, once: cov_branch_run (no
//! limit: the release gate's runner, waited for alone), cov_run (a limit,
//! then SIGKILL to the whole process group and a scan of /proc for members
//! that survived it) and mut_step.sh (a limit, then SIGTERM to the group, a
//! grace period, and SIGKILL). The module is pure std (no import of its own)
//! so that a tool in another package can take it as a module.
//!
//! The command:
//!   - `argv[0]` is a path, run with execve: no PATH search, so a tool runs
//!     exactly the program it was given;
//!   - `envp` is the whole environment it gets (nothing is inherited);
//!   - stdin, stdout and stderr are inherited, or a file each (stdin read,
//!     the others created or truncated; `stderr_to_stdout` gives stderr the
//!     stdout descriptor, so the two interleave in one file as `>f 2>&1`);
//!   - with a limit, it calls setsid() before execve, so its pid is its
//!     process group's id and everything it starts (that does not leave the
//!     group) is a member the limit's kill reaches;
//!   - with no limit, it stays in the caller's process group and session, as
//!     a command a shell runs does: whatever stops the caller's group (an
//!     executor's timeout) stops the command too.
//!
//! Waiting: with no limit, a blocking wait for the command alone (like the
//! shell's `wait`): processes it left running are not waited for, and not
//! killed. With a limit, the command is polled; once `limit_ms` has passed
//! the group is sent SIGKILL (or SIGTERM, then after `term_grace_ms`, SIGKILL)
//! and the command is reaped. With `check_survivors`, the group's members
//! that are not zombies are then listed from /proc, polled every 100 ms for
//! up to `survivor_wait_ms` (SIGKILL is delivered when a process next runs).
//! The leader stays a zombie (waitid WNOWAIT) until that scan is done, so its
//! pid, the group's id, cannot be reused while the group is read.
//!
//! The scan trusts /proc only when it is this process's own: /proc/<pid>/stat
//! and /proc/self/stat must both start with this process's pid. A /proc of
//! another PID namespace, or one hiding processes, would list none of the
//! group and pass without checking; that is error.ProcNotOwn.
//!
//! An execve that fails is reported by the child on its stderr ("bounded_run:
//! cannot run <argv0>: <error>") with exit status 127, as a shell reports a
//! command it cannot run.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// The time and the signals of a run, in one place so that a test can give
/// them its own: a clock it moves itself and a kill it records. The default
/// is the monotonic clock, nanosleep and kill(2).
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    /// Monotonic nanoseconds, null when the clock cannot be read.
    now_ns: *const fn (?*anyopaque) ?u64 = realNow,
    sleep_ns: *const fn (?*anyopaque, u64) void = realSleep,
    kill: *const fn (?*anyopaque, i32, i32) void = realKill,
};

fn realNow(_: ?*anyopaque) ?u64 {
    const ts = posix.clock_gettime(.MONOTONIC) catch return null;
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn realSleep(_: ?*anyopaque, ns: u64) void {
    std.Thread.sleep(ns);
}

fn realKill(_: ?*anyopaque, pid: i32, sig: i32) void {
    _ = linux.kill(pid, sig);
}

pub const Spec = struct {
    /// argv[0] is the program's path.
    argv: []const []const u8,
    /// NAME=VALUE entries: the command's whole environment.
    env: []const []const u8,
    stdin_path: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null,
    /// Ignored when `stderr_to_stdout` is set (the file is still created).
    stderr_path: ?[]const u8 = null,
    /// stderr gets the stdout descriptor; it wins over `stderr_path`.
    stderr_to_stdout: bool = false,
    /// null: no limit, and the command stays in the caller's process group.
    limit_ms: ?u64 = null,
    /// null: SIGKILL at the limit; n: SIGTERM, n ms, then SIGKILL.
    term_grace_ms: ?u64 = null,
    /// After a limit's kill, list the group's members still running.
    check_survivors: bool = false,
    survivor_wait_ms: u64 = 10_000,
    /// The process table the scan reads; tests give a directory of their own.
    proc_root: []const u8 = "/proc",
    clock: Clock = .{},
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,
};

pub const Survivor = struct {
    pid: i32,
    state: u8,
    comm: []const u8,
};

pub const Outcome = struct {
    status: Status,
    timed_out: bool,
    /// With a limit, the command's pid, which is its process group's id;
    /// null with none (the command is in the caller's group).
    pgid: ?i32,
    /// Members of the group not a zombie after the kill (check_survivors).
    survivors: []const Survivor,

    /// The status a shell gives it: the exit code, or 128 + the signal.
    pub fn shellStatus(self: Outcome) u8 {
        return switch (self.status) {
            .exited => |c| c,
            .signaled => |s| 128 +% s,
        };
    }
};

pub const Error = error{
    /// /proc is not this process's own (see the module comment).
    ProcNotOwn,
    Unexpected,
} || std.mem.Allocator.Error || posix.OpenError || posix.ForkError;

fn sysErr(rc: usize) linux.E {
    return linux.E.init(rc);
}

/// NAME=VALUE entries of `map`, sorted by name (a fixed order, so a command's
/// environment does not depend on the map's).
pub fn envFromMap(alloc: std.mem.Allocator, map: *const std.process.EnvMap) ![]const []const u8 {
    var names = std.ArrayList([]const u8).empty;
    var it = map.iterator();
    while (it.next()) |e| try names.append(alloc, e.key_ptr.*);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    const out = try alloc.alloc([]const u8, names.items.len);
    for (names.items, 0..) |n, i| out[i] = try std.fmt.allocPrint(alloc, "{s}={s}", .{ n, map.get(n).? });
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn zArray(alloc: std.mem.Allocator, items: []const []const u8) ![:null]?[*:0]const u8 {
    const out = try alloc.allocSentinel(?[*:0]const u8, items.len, null);
    for (items, 0..) |s, i| out[i] = (try alloc.dupeZ(u8, s)).ptr;
    return out;
}

fn openFor(path: []const u8, write: bool) posix.OpenError!posix.fd_t {
    const flags: posix.O = if (write)
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }
    else
        .{ .ACCMODE = .RDONLY, .CLOEXEC = true };
    return posix.open(path, flags, 0o644);
}

/// Runs `spec` (module comment). Allocations (the survivors among them) are
/// `alloc`'s: give it an arena.
pub fn run(alloc: std.mem.Allocator, spec: Spec) Error!Outcome {
    std.debug.assert(spec.argv.len > 0);
    const argv = try zArray(alloc, spec.argv);
    const envp = try zArray(alloc, spec.env);
    const msg = try std.fmt.allocPrint(alloc, "bounded_run: cannot run {s}: ", .{spec.argv[0]});

    // Opened before the fork: the child only moves descriptors and execs.
    const in_fd: ?posix.fd_t = if (spec.stdin_path) |p| try openFor(p, false) else null;
    defer if (in_fd) |fd| posix.close(fd);
    const out_fd: ?posix.fd_t = if (spec.stdout_path) |p| try openFor(p, true) else null;
    defer if (out_fd) |fd| posix.close(fd);
    const err_fd: ?posix.fd_t = if (spec.stderr_path) |p| try openFor(p, true) else null;
    defer if (err_fd) |fd| posix.close(fd);

    const pid = try posix.fork();
    const own_group = spec.limit_ms != null;
    if (pid == 0) child(argv, envp, msg, in_fd, out_fd, err_fd, spec.stderr_to_stdout, own_group);

    if (!own_group) {
        return .{ .status = reap(pid), .timed_out = false, .pgid = null, .survivors = &.{} };
    }
    const clock = spec.clock;
    const start = clock.now_ns(clock.ctx) orelse return error.Unexpected;
    var nap: u64 = std.time.ns_per_ms;
    while (true) {
        if (exitedNoReap(pid, false)) {
            return .{ .status = reap(pid), .timed_out = false, .pgid = pid, .survivors = &.{} };
        }
        const now = clock.now_ns(clock.ctx) orelse return error.Unexpected;
        if (now -| start >= spec.limit_ms.? * std.time.ns_per_ms) break;
        clock.sleep_ns(clock.ctx, nap);
        nap = @min(nap * 2, 50 * std.time.ns_per_ms);
    }

    // The limit has passed: the whole group, not the leader alone. The
    // leader is also signalled by its pid, so one that has not yet left the
    // caller's group (setsid not yet run) is killed all the same, and the
    // wait below cannot block on it.
    if (spec.term_grace_ms) |grace| {
        clock.kill(clock.ctx, -pid, linux.SIG.TERM);
        clock.kill(clock.ctx, pid, linux.SIG.TERM);
        // The whole grace period, as it always was: members of the group
        // other than the leader may need it after the leader has left.
        clock.sleep_ns(clock.ctx, grace * std.time.ns_per_ms);
    }
    clock.kill(clock.ctx, -pid, linux.SIG.KILL);
    clock.kill(clock.ctx, pid, linux.SIG.KILL);
    // The leader stays a zombie while the group is read.
    _ = exitedNoReap(pid, true);
    var survivors: []const Survivor = &.{};
    var scan_err: ?Error = null;
    if (spec.check_survivors) {
        if (survivorsAfterKillOn(alloc, spec.proc_root, pid, spec.survivor_wait_ms, clock)) |left| {
            survivors = left;
        } else |e| scan_err = e;
    }
    const status = reap(pid);
    if (scan_err) |e| return e;
    return .{ .status = status, .timed_out = true, .pgid = pid, .survivors = survivors };
}

/// After a kill of group `pgid`: its members still running once they have
/// had up to `wait_ms` to die, read from `root` (which must be this
/// process's own /proc). Whatever survived is sent SIGKILL again; the caller
/// reports it.
pub fn survivorsAfterKill(alloc: std.mem.Allocator, root: []const u8, pgid: i32, wait_ms: u64) Error![]const Survivor {
    return survivorsAfterKillOn(alloc, root, pgid, wait_ms, .{});
}

/// `survivorsAfterKill` with the naps and the kill on `clock`.
pub fn survivorsAfterKillOn(alloc: std.mem.Allocator, root: []const u8, pgid: i32, wait_ms: u64, clock: Clock) Error![]const Survivor {
    try procIsOwn(alloc, root);
    var waited: u64 = 0;
    while (true) {
        const left = try groupLeft(alloc, root, pgid);
        if (left.len == 0 or waited >= wait_ms) {
            if (left.len != 0) clock.kill(clock.ctx, -pgid, linux.SIG.KILL);
            return left;
        }
        clock.sleep_ns(clock.ctx, 100 * std.time.ns_per_ms);
        waited += 100;
    }
}

fn child(
    argv: [:null]?[*:0]const u8,
    envp: [:null]?[*:0]const u8,
    msg: []const u8,
    in_fd: ?posix.fd_t,
    out_fd: ?posix.fd_t,
    err_fd: ?posix.fd_t,
    err_to_out: bool,
    own_group: bool,
) noreturn {
    if (own_group) _ = linux.setsid();
    if (in_fd) |fd| _ = linux.dup2(fd, 0);
    if (out_fd) |fd| _ = linux.dup2(fd, 1);
    if (err_to_out) {
        _ = linux.dup2(1, 2);
    } else if (err_fd) |fd| _ = linux.dup2(fd, 2);
    const rc = linux.execve(argv[0].?, argv.ptr, envp.ptr);
    // No allocation after the fork: the number is formatted on the stack.
    var buf: [32]u8 = undefined;
    const tail = std.fmt.bufPrint(&buf, "errno {d}\n", .{@intFromEnum(sysErr(rc))}) catch "errno ?\n";
    _ = linux.write(2, msg.ptr, msg.len);
    _ = linux.write(2, tail.ptr, tail.len);
    linux.exit_group(127);
}

/// Whether `pid` has exited, leaving it a zombie (WNOWAIT). `block`: wait.
fn exitedNoReap(pid: i32, block: bool) bool {
    while (true) {
        var info = std.mem.zeroes(linux.siginfo_t);
        const flags: u32 = linux.W.EXITED | linux.W.NOWAIT | (if (block) @as(u32, 0) else linux.W.NOHANG);
        const rc = linux.waitid(.PID, pid, &info, flags);
        switch (sysErr(rc)) {
            .SUCCESS => return info.fields.common.first.piduid.pid != 0,
            .INTR => continue,
            // Not ours, or already reaped: nothing to wait for.
            else => return true,
        }
    }
}

fn reap(pid: i32) Status {
    while (true) {
        var st: u32 = 0;
        const rc = linux.wait4(pid, &st, 0, null);
        switch (sysErr(rc)) {
            .SUCCESS => return decode(st),
            .INTR => continue,
            // Cannot happen for our own child; read as SIGKILL, never as a pass.
            else => return .{ .signaled = linux.SIG.KILL },
        }
    }
}

pub fn decode(st: u32) Status {
    if (linux.W.IFEXITED(st)) return .{ .exited = linux.W.EXITSTATUS(st) };
    return .{ .signaled = @intCast(linux.W.TERMSIG(st)) };
}

/// /proc/<getpid()>/stat and /proc/self/stat both start with getpid().
pub fn procIsOwn(alloc: std.mem.Allocator, root: []const u8) error{ProcNotOwn}!void {
    const me = linux.getpid();
    var buf: [32]u8 = undefined;
    const mine = std.fmt.bufPrint(&buf, "{d}", .{me}) catch unreachable;
    const by_pid = std.fmt.allocPrint(alloc, "{s}/{s}/stat", .{ root, mine }) catch return error.ProcNotOwn;
    const by_self = std.fmt.allocPrint(alloc, "{s}/self/stat", .{root}) catch return error.ProcNotOwn;
    for ([_][]const u8{ by_pid, by_self }) |p| {
        const first = firstField(alloc, p) orelse return error.ProcNotOwn;
        if (!std.mem.eql(u8, first, mine)) return error.ProcNotOwn;
    }
}

fn firstField(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const text = std.fs.cwd().readFileAlloc(alloc, path, 1 << 16) catch return null;
    const end = std.mem.indexOfScalar(u8, text, ' ') orelse return null;
    return text[0..end];
}

/// One /proc/<pid>/stat line, read as cov_run reads it: the fields after
/// the LAST ')' (comm may hold one) are state, ppid and pgrp.
pub fn parseStat(line: []const u8) ?struct { pid: i32, comm: []const u8, state: u8, pgrp: i32 } {
    const open = std.mem.indexOfScalar(u8, line, '(') orelse return null;
    const close = std.mem.lastIndexOfScalar(u8, line, ')') orelse return null;
    if (close < open or open == 0) return null;
    const pid = std.fmt.parseInt(i32, std.mem.trim(u8, line[0..open], " "), 10) catch return null;
    var it = std.mem.tokenizeScalar(u8, line[close + 1 ..], ' ');
    const state = it.next() orelse return null;
    _ = it.next() orelse return null; // ppid
    const pgrp_s = it.next() orelse return null;
    const pgrp = std.fmt.parseInt(i32, pgrp_s, 10) catch return null;
    if (state.len == 0) return null;
    return .{ .pid = pid, .comm = line[open + 1 .. close], .state = state[0], .pgrp = pgrp };
}

/// The processes of group `pgid` under `root` that are not zombies (Z) or
/// dead (X). A process that exits while this reads is skipped.
pub fn groupLeft(alloc: std.mem.Allocator, root: []const u8, pgid: i32) ![]const Survivor {
    var out = std.ArrayList(Survivor).empty;
    var dir = std.fs.cwd().openDir(root, .{ .iterate = true }) catch return out.toOwnedSlice(alloc);
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |e| {
        if (e.name.len == 0 or !std.ascii.isDigit(e.name[0])) continue;
        const p = try std.fmt.allocPrint(alloc, "{s}/{s}/stat", .{ root, e.name });
        const text = std.fs.cwd().readFileAlloc(alloc, p, 1 << 16) catch continue;
        const s = parseStat(std.mem.trimRight(u8, text, "\n")) orelse continue;
        if (s.pgrp != pgid or s.state == 'Z' or s.state == 'X') continue;
        try out.append(alloc, .{ .pid = s.pid, .state = s.state, .comm = s.comm });
    }
    std.mem.sort(Survivor, out.items, {}, byPid);
    return out.toOwnedSlice(alloc);
}

fn byPid(_: void, a: Survivor, b: Survivor) bool {
    return a.pid < b.pid;
}

// ---- tests ------------------------------------------------------------------
// They run under `zig test` in a build action whose PATH holds the busybox
// applets (tools/build/mojo/toolchain.bzl, zig_test): `sh` and `sleep` are
// found there, by the test, since the module itself searches no PATH.

const testing = std.testing;

fn which(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = std.posix.getenv("PATH") orelse return error.FileNotFound;
    var it = std.mem.tokenizeScalar(u8, path, ':');
    while (it.next()) |d| {
        const p = try std.fs.path.join(alloc, &.{ d, name });
        std.fs.cwd().access(p, .{}) catch continue;
        return p;
    }
    return error.FileNotFound;
}

/// A clock a test moves itself. Time moves only when `run` or the scan naps,
/// and by the nap, so every decision made on it is on exact values; nothing
/// in a run waits for real time. Every nap and kill is recorded.
const Fake = struct {
    const Ev = struct { t: u64, what: enum { nap, kill }, pid: i32 = 0, sig: i32 = 0, ns: u64 = 0 };

    now: u64 = 0,
    /// A FIFO the command writes to once it is up: the first nap waits for
    /// that byte (a progress wait with no limit of its own) before time moves.
    ready: ?[:0]const u8 = null,
    started: bool = false,
    /// Time never moves; a nap only yields (for a command that must finish
    /// by itself before any limit could be reached).
    frozen: bool = false,
    /// After a SIGTERM to the group, a nap first waits for the leader's exit
    /// (so a trap has run before the SIGKILL), then moves time.
    term_waits_for_exit: bool = false,
    /// After a SIGKILL to the group, a nap waits for the group's running
    /// members under `root` to be gone before time moves: the kill cannot
    /// be refused, so they will be.
    settle_root: ?[]const u8 = null,
    leader: i32 = 0,
    termed: bool = false,
    killed: bool = false,
    events: [512]Ev = undefined,
    n: usize = 0,

    fn clock(f: *Fake) Clock {
        return .{ .ctx = f, .now_ns = nowFn, .sleep_ns = napFn, .kill = killFn };
    }

    fn of(ctx: ?*anyopaque) *Fake {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn record(f: *Fake, ev: Ev) void {
        if (f.n < f.events.len) {
            f.events[f.n] = ev;
            f.n += 1;
        }
    }

    fn nowFn(ctx: ?*anyopaque) ?u64 {
        return of(ctx).now;
    }

    fn killFn(ctx: ?*anyopaque, pid: i32, sig: i32) void {
        const f = of(ctx);
        f.record(.{ .t = f.now, .what = .kill, .pid = pid, .sig = sig });
        if (pid < 0 and sig == linux.SIG.TERM) {
            f.termed = true;
            f.leader = -pid;
        }
        if (pid < 0 and sig == linux.SIG.KILL) {
            f.killed = true;
            f.leader = -pid;
        }
        _ = linux.kill(pid, sig);
    }

    fn napFn(ctx: ?*anyopaque, ns: u64) void {
        const f = of(ctx);
        f.record(.{ .t = f.now, .what = .nap, .ns = ns });
        if (f.frozen) {
            std.Thread.yield() catch {};
            return;
        }
        if (!f.started) {
            f.started = true;
            if (f.ready) |path| {
                const fd = posix.open(path, .{ .ACCMODE = .RDONLY }, 0) catch return;
                defer posix.close(fd);
                var b: [1]u8 = undefined;
                _ = posix.read(fd, &b) catch {};
            }
        }
        if (f.termed and !f.killed and f.term_waits_for_exit) {
            _ = exitedNoReap(f.leader, true);
        }
        if (f.killed) if (f.settle_root) |root| {
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const left = groupLeft(arena.allocator(), root, f.leader) catch &.{};
            for (left) |m| waitPidExit(m.pid);
        };
        f.now += ns;
    }

    fn killTime(f: *const Fake, pid: i32, sig: i32) ?u64 {
        for (f.events[0..f.n]) |e| {
            if (e.what == .kill and e.pid == pid and e.sig == sig) return e.t;
        }
        return null;
    }

    fn naps(f: *const Fake) usize {
        var c: usize = 0;
        for (f.events[0..f.n]) |e| {
            if (e.what == .nap) c += 1;
        }
        return c;
    }
};

/// Blocks until `pid` has exited (a zombie has), with no limit of its own.
fn waitPidExit(pid: i32) void {
    const rc = linux.pidfd_open(pid, 0);
    if (sysErr(rc) != .SUCCESS) return;
    const fd: posix.fd_t = @intCast(rc);
    defer posix.close(fd);
    var p = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    while (true) {
        const got = posix.poll(&p, -1) catch continue;
        if (got > 0) return;
    }
}

/// A FIFO in `dir` named `name`, for a command to say it is up through.
fn makeFifo(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![:0]const u8 {
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    if (sysErr(linux.mknodat(linux.AT.FDCWD, path, linux.S.IFIFO | 0o600, 0)) != .SUCCESS) return error.Unexpected;
    return path;
}

fn shSpec(alloc: std.mem.Allocator, script: []const u8) !Spec {
    const sh = try which(alloc, "sh");
    const path = try std.fmt.allocPrint(alloc, "PATH={s}", .{std.posix.getenv("PATH").?});
    return .{ .argv = try alloc.dupe([]const u8, &.{ sh, "-c", script }), .env = try alloc.dupe([]const u8, &.{path}) };
}

test "an exit status is the command's own, and 128 + N for a signal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try run(a, try shSpec(a, "exit 0"));
    try testing.expectEqual(Status{ .exited = 0 }, ok.status);
    const three = try run(a, try shSpec(a, "exit 3"));
    try testing.expectEqual(Status{ .exited = 3 }, three.status);
    try testing.expectEqual(@as(u8, 3), three.shellStatus());
    try testing.expect(!three.timed_out);
    const killed = try run(a, try shSpec(a, "kill -9 $$"));
    try testing.expectEqual(Status{ .signaled = 9 }, killed.status);
    try testing.expectEqual(@as(u8, 137), killed.shellStatus());
}

/// The process group and session of a /proc/<pid>/stat line.
fn groupAndSession(text: []const u8) ![2]i32 {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return error.BadStat;
    var it = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = it.next(); // state
    _ = it.next(); // ppid
    const pgrp = try std.fmt.parseInt(i32, it.next() orelse return error.BadStat, 10);
    const session = try std.fmt.parseInt(i32, it.next() orelse return error.BadStat, 10);
    return .{ pgrp, session };
}

/// Runs `cat /proc/self/stat` under `sh` with `limit_ms`; the command's
/// outcome and cat's process group and session.
fn catStat(a: std.mem.Allocator, limit_ms: ?u64) !struct { o: Outcome, gs: [2]i32 } {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const out = try std.fs.path.join(a, &.{ dir, "stat" });
    var spec = try shSpec(a, "cat /proc/self/stat");
    spec.stdout_path = out;
    spec.limit_ms = limit_ms;
    // A clock that does not move: the limit cannot be reached, whatever the
    // host's speed; the command ends by itself.
    var fake = Fake{ .frozen = true };
    spec.clock = fake.clock();
    const o = try run(a, spec);
    try testing.expectEqual(Status{ .exited = 0 }, o.status);
    try testing.expect(!o.timed_out);
    // `cat` runs in the shell's group and session.
    return .{ .o = o, .gs = try groupAndSession(try std.fs.cwd().readFileAlloc(a, out, 4096)) };
}

test "with a limit, the command leads a session and process group of its own" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try catStat(a, 20_000);
    const pgid = r.o.pgid.?;
    try testing.expectEqual(pgid, r.gs[0]);
    try testing.expectEqual(pgid, r.gs[1]);
}

test "with no limit, the command stays in the caller's process group and session" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = try catStat(a, null);
    try testing.expect(r.o.pgid == null);
    // Ours, from this process's own stat: a kill of our group reaches it.
    const mine = try groupAndSession(try std.fs.cwd().readFileAlloc(a, "/proc/self/stat", 4096));
    try testing.expectEqual(mine[0], r.gs[0]);
    try testing.expectEqual(mine[1], r.gs[1]);
}

test "the environment is exactly the one given" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const out = try std.fs.path.join(a, &.{ dir, "env" });
    const sh = try which(a, "sh");
    const env_exe = try which(a, "env");
    const spec = Spec{
        .argv = &.{ sh, "-c", "exec \"$0\"", env_exe },
        .env = &.{ "ONLY=1", "B=two words" },
        .stdout_path = out,
    };
    const o = try run(a, spec);
    try testing.expectEqual(Status{ .exited = 0 }, o.status);
    const text = try std.fs.cwd().readFileAlloc(a, out, 4096);
    // busybox sh adds PWD (and may add others it sets itself); none of the
    // test's own environment (its TMPDIR) reaches the command.
    try testing.expect(std.mem.indexOf(u8, text, "ONLY=1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "B=two words\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "TMPDIR=") == null);
}

test "stdout and stderr go to their files, or interleave in one" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const o1 = try std.fs.path.join(a, &.{ dir, "o1" });
    const e1 = try std.fs.path.join(a, &.{ dir, "e1" });
    var spec = try shSpec(a, "echo out; echo err >&2; echo out2");
    spec.stdout_path = o1;
    spec.stderr_path = e1;
    _ = try run(a, spec);
    try testing.expectEqualStrings("out\nout2\n", try std.fs.cwd().readFileAlloc(a, o1, 4096));
    try testing.expectEqualStrings("err\n", try std.fs.cwd().readFileAlloc(a, e1, 4096));
    const both = try std.fs.path.join(a, &.{ dir, "both" });
    spec.stdout_path = both;
    spec.stderr_path = null;
    spec.stderr_to_stdout = true;
    _ = try run(a, spec);
    try testing.expectEqualStrings("out\nerr\nout2\n", try std.fs.cwd().readFileAlloc(a, both, 4096));
}

test "stderr_to_stdout wins over stderr_path, whose file is still created empty" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const o = try std.fs.path.join(a, &.{ dir, "o" });
    const e = try std.fs.path.join(a, &.{ dir, "e" });
    try tmp.dir.writeFile(.{ .sub_path = "e", .data = "stale\n" });
    var spec = try shSpec(a, "echo out; echo err >&2");
    spec.stdout_path = o;
    spec.stderr_path = e;
    spec.stderr_to_stdout = true;
    _ = try run(a, spec);
    try testing.expectEqualStrings("out\nerr\n", try std.fs.cwd().readFileAlloc(a, o, 4096));
    try testing.expectEqualStrings("", try std.fs.cwd().readFileAlloc(a, e, 4096));
}

test "a program that cannot be run is exit 127 with its name on stderr" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const e = try std.fs.path.join(a, &.{ dir, "e" });
    const missing = try std.fs.path.join(a, &.{ dir, "no-such-program" });
    const o = try run(a, .{ .argv = &.{missing}, .env = &.{}, .stderr_path = e });
    try testing.expectEqual(Status{ .exited = 127 }, o.status);
    const text = try std.fs.cwd().readFileAlloc(a, e, 4096);
    try testing.expect(std.mem.indexOf(u8, text, "bounded_run: cannot run ") != null);
    try testing.expect(std.mem.indexOf(u8, text, "no-such-program: errno 2\n") != null);
}

test "no limit: the command is waited for alone, and nothing is killed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const out = try std.fs.path.join(a, &.{ dir, "pid" });
    // The shell leaves a sleeper behind, says its pid, and exits at once. The
    // sleeper outlasts any test: if the run waited for it (the group, not the
    // command alone), the run would not return.
    var spec = try shSpec(a, "sleep 3600 & echo $!; exit 0");
    spec.stdout_path = out;
    const o = try run(a, spec);
    try testing.expectEqual(Status{ .exited = 0 }, o.status);
    // The sleeper is still running (it is in our group: only it is killed).
    const text = try std.fs.cwd().readFileAlloc(a, out, 64);
    const sleeper = try std.fmt.parseInt(i32, std.mem.trimRight(u8, text, "\n"), 10);
    defer _ = linux.kill(sleeper, linux.SIG.KILL);
    const p = try std.fmt.allocPrint(a, "/proc/{d}/stat", .{sleeper});
    const s = parseStat(std.mem.trimRight(u8, try std.fs.cwd().readFileAlloc(a, p, 4096), "\n")).?;
    try testing.expect(s.state != 'Z' and s.state != 'X');
}

test "a limit kills the whole group, and the scan finds no survivor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const fifo = try makeFifo(a, dir, "up");
    // A background sleeper and a foreground one, both for an hour; the
    // shell says they are up before the clock moves.
    var spec = try shSpec(a, try std.fmt.allocPrint(a, "sleep 3600 & echo r >{s}; sleep 3600; exit 0", .{fifo}));
    spec.stderr_path = "/dev/null";
    spec.limit_ms = 300;
    spec.check_survivors = true;
    spec.survivor_wait_ms = 2000;
    var fake = Fake{ .ready = fifo, .settle_root = "/proc" };
    spec.clock = fake.clock();
    const o = try run(a, spec);
    try testing.expect(o.timed_out);
    try testing.expectEqual(Status{ .signaled = 9 }, o.status);
    try testing.expectEqual(@as(usize, 0), o.survivors.len);
    // Not the leader alone: the background sleeper is gone too.
    try testing.expectEqual(@as(usize, 0), (try groupLeft(a, "/proc", o.pgid.?)).len);
    // The group was killed (and the leader by its pid) at the first nap
    // boundary at or after the limit, and not before it.
    const at = fake.killTime(-o.pgid.?, linux.SIG.KILL).?;
    try testing.expect(at >= 300 * std.time.ns_per_ms and at < 350 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u64, at), fake.killTime(o.pgid.?, linux.SIG.KILL));
}

test "a command that ends within its limit is not timed out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var spec = try shSpec(a, "exit 5");
    spec.limit_ms = 20_000;
    var fake = Fake{ .frozen = true };
    spec.clock = fake.clock();
    const o = try run(a, spec);
    try testing.expect(!o.timed_out);
    try testing.expectEqual(Status{ .exited = 5 }, o.status);
}

test "a term grace sends SIGTERM first: a command that traps it exits its own way, and the grace is still waited out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fifo = try makeFifo(a, try tmp.dir.realpathAlloc(a, "."), "up");
    var spec = try shSpec(a, try std.fmt.allocPrint(a, "trap 'exit 7' TERM; echo r >{s}; while :; do sleep 1; done", .{fifo}));
    spec.stderr_path = "/dev/null";
    spec.limit_ms = 300;
    spec.term_grace_ms = 1000;
    var fake = Fake{ .ready = fifo, .term_waits_for_exit = true };
    spec.clock = fake.clock();
    const o = try run(a, spec);
    try testing.expect(o.timed_out);
    try testing.expectEqual(Status{ .exited = 7 }, o.status);
    // The group is sent SIGTERM at the limit, and the SIGKILL that follows
    // (for whatever else is left in the group) comes after the whole grace.
    const termed = fake.killTime(-o.pgid.?, linux.SIG.TERM).?;
    try testing.expect(termed >= 300 * std.time.ns_per_ms);
    try testing.expectEqual(@as(?u64, termed + 1000 * std.time.ns_per_ms), fake.killTime(-o.pgid.?, linux.SIG.KILL));
}

test "a term grace is waited out for a command that ignores SIGTERM, then the group is sent SIGKILL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const fifo = try makeFifo(a, try tmp.dir.realpathAlloc(a, "."), "up");
    var spec = try shSpec(a, try std.fmt.allocPrint(a, "trap '' TERM; echo r >{s}; while :; do sleep 1; done", .{fifo}));
    spec.stderr_path = "/dev/null";
    spec.limit_ms = 300;
    spec.term_grace_ms = 1000;
    var fake = Fake{ .ready = fifo };
    spec.clock = fake.clock();
    const o = try run(a, spec);
    try testing.expect(o.timed_out);
    try testing.expectEqual(Status{ .signaled = 9 }, o.status);
    // Exactly the grace period (1000 ms) on the clock between the two.
    const termed = fake.killTime(-o.pgid.?, linux.SIG.TERM).?;
    const killed = fake.killTime(-o.pgid.?, linux.SIG.KILL).?;
    try testing.expectEqual(1000 * std.time.ns_per_ms, killed - termed);
}

fn writeStat(dir: std.fs.Dir, pid: []const u8, line: []const u8) !void {
    try dir.makePath(pid);
    const p = try std.fmt.allocPrint(testing.allocator, "{s}/stat", .{pid});
    defer testing.allocator.free(p);
    try dir.writeFile(.{ .sub_path = p, .data = line });
}

test "the survivor scan reads state and group after the last ')', and skips zombies" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeStat(tmp.dir, "10", "10 (kcov) S 1 500 500 0\n");
    try writeStat(tmp.dir, "11", "11 (a) b) (c) R 10 500 500 0\n");
    try writeStat(tmp.dir, "12", "12 (zombie) Z 10 500 500 0\n");
    try writeStat(tmp.dir, "13", "13 (dead) X 10 500 500 0\n");
    try writeStat(tmp.dir, "14", "14 (other) S 1 600 600 0\n");
    try writeStat(tmp.dir, "15", "15 (500) S 1 7 7 0\n");
    try tmp.dir.makePath("self");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const left = try groupLeft(a, root, 500);
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqual(@as(i32, 10), left[0].pid);
    try testing.expectEqual(@as(u8, 'S'), left[0].state);
    try testing.expectEqualStrings("kcov", left[0].comm);
    try testing.expectEqual(@as(i32, 11), left[1].pid);
    try testing.expectEqualStrings("a) b) (c", left[1].comm);
    try testing.expectEqual(@as(u8, 'R'), left[1].state);
}

test "a /proc that is not this process's own is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    // Empty: neither file.
    try testing.expectError(error.ProcNotOwn, procIsOwn(a, root));
    const me = try std.fmt.allocPrint(a, "{d}", .{linux.getpid()});
    // Its own pid entry, but self is another process (another namespace).
    try writeStat(tmp.dir, me, try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    try writeStat(tmp.dir, "self", "1 (init) S 0 1 1 0\n");
    try testing.expectError(error.ProcNotOwn, procIsOwn(a, root));
    // Both right.
    try writeStat(tmp.dir, "self", try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    try procIsOwn(a, root);
    // The real one is ours.
    try procIsOwn(a, "/proc");
    // And a limit run with check_survivors refuses a blind table.
    var spec = try shSpec(a, "sleep 3600");
    spec.limit_ms = 100;
    spec.check_survivors = true;
    spec.proc_root = try std.fs.path.join(a, &.{ root, "missing" });
    var fake = Fake{};
    spec.clock = fake.clock();
    try testing.expectError(error.ProcNotOwn, run(a, spec));
}

test "a member that survives the kill is reported, after the wait" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const me = try std.fmt.allocPrint(a, "{d}", .{linux.getpid()});
    try writeStat(tmp.dir, me, try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    try writeStat(tmp.dir, "self", try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    // Group 2147483000: no real process has it, so the second kill reaches
    // nothing. One member in uninterruptible sleep, one zombie.
    try writeStat(tmp.dir, "4242", "4242 (stuck) D 1 2147483000 2147483000 0\n");
    try writeStat(tmp.dir, "4243", "4243 (gone) Z 1 2147483000 2147483000 0\n");
    var fake = Fake{};
    const left = try survivorsAfterKillOn(a, root, 2147483000, 300, fake.clock());
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(@as(i32, 4242), left[0].pid);
    try testing.expectEqual(@as(u8, 'D'), left[0].state);
    try testing.expectEqualStrings("stuck", left[0].comm);
    // It was given the wait before being reported: three naps of 100 ms
    // (300 ms in all), and only after them the second kill of the group.
    try testing.expectEqual(@as(usize, 3), fake.naps());
    try testing.expectEqual(@as(u64, 300 * std.time.ns_per_ms), fake.now);
    try testing.expectEqual(@as(?u64, 300 * std.time.ns_per_ms), fake.killTime(-2147483000, linux.SIG.KILL));
    // A group with only a zombie left has no survivor, at once: no nap, no kill.
    var fake2 = Fake{};
    const none = try survivorsAfterKillOn(a, root, 2147483001, 300, fake2.clock());
    try testing.expectEqual(@as(usize, 0), none.len);
    try testing.expectEqual(@as(usize, 0), fake2.n);
}

test "parseStat refuses lines it cannot read" {
    try testing.expect(parseStat("") == null);
    try testing.expect(parseStat("12 no parens S 1 2 3") == null);
    try testing.expect(parseStat("x (a) S 1 2 3") == null);
    try testing.expect(parseStat("12 (a) S 1") == null);
    const s = parseStat("12 (a) S 1 2 3").?;
    try testing.expectEqual(@as(i32, 2), s.pgrp);
}

test "survivors still running after the wait are sent SIGKILL again" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A real group: a leader L and a member M, both sleeping (each setpgid
    // is made on both sides of its fork, so the group exists before M joins
    // it and before the scan's kill). As in run(), where the leader is still
    // a zombie during the scan, the survivor is a member, never the leader:
    // only a kill of the whole group (-pgid) reaches it.
    const argv = try zArray(a, &.{ try which(a, "sleep"), "3600" });
    const envp = try zArray(a, &.{});
    const leader = try posix.fork();
    if (leader == 0) {
        _ = linux.syscall2(.setpgid, 0, 0);
        _ = linux.execve(argv[0].?, argv.ptr, envp.ptr);
        linux.exit_group(127);
    }
    _ = linux.syscall2(.setpgid, @intCast(leader), @intCast(leader));
    const member = try posix.fork();
    if (member == 0) {
        _ = linux.syscall2(.setpgid, 0, @intCast(leader));
        _ = linux.execve(argv[0].?, argv.ptr, envp.ptr);
        linux.exit_group(127);
    }
    _ = linux.syscall2(.setpgid, @intCast(member), @intCast(leader));
    // Whatever the outcome, neither sleeper outlives the test (and a pid
    // already reaped is not signalled: it may have been reused).
    var member_reaped = false;
    defer {
        if (!member_reaped) {
            _ = linux.kill(member, linux.SIG.KILL);
            _ = reap(member);
        }
        _ = linux.kill(leader, linux.SIG.KILL);
        _ = reap(leader);
    }
    // A table that shows the leader a zombie and the member running, never
    // dying: the scan reports the member after the wait, and its last kill
    // must reach the member through the real group.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const me = try std.fmt.allocPrint(a, "{d}", .{linux.getpid()});
    try writeStat(tmp.dir, me, try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    try writeStat(tmp.dir, "self", try std.fmt.allocPrint(a, "{s} (t) R 1 1 1 0\n", .{me}));
    const lid = try std.fmt.allocPrint(a, "{d}", .{leader});
    const mid = try std.fmt.allocPrint(a, "{d}", .{member});
    try writeStat(tmp.dir, lid, try std.fmt.allocPrint(a, "{s} (sleep) Z 1 {s} {s} 0\n", .{ lid, lid, lid }));
    try writeStat(tmp.dir, mid, try std.fmt.allocPrint(a, "{s} (sleep) S {s} {s} {s} 0\n", .{ mid, lid, lid, lid }));
    const left = try survivorsAfterKill(a, root, leader, 0);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqual(member, left[0].pid);
    // The member dies of the SIGKILL (a wait with no limit of its own: the
    // kill cannot be refused).
    _ = exitedNoReap(member, true);
    member_reaped = true;
    try testing.expectEqual(Status{ .signaled = linux.SIG.KILL }, reap(member));
}
