//! The supervisor every mode shares (docs/design/zig_gate_runner.md, 2.1):
//! one child C in a session of its own, a tether Q outside it, and a loop
//! that sees C exit at once and checks the memory cap and the time limit on
//! a 100 ms tick.
//!
//!   * C calls setsid(), waits for the go byte, moves its descriptors and
//!     working directory into place and executes the program with an
//!     environment the caller built: nothing of the tool's own state comes
//!     from the environment.
//!   * Q is forked first, leads a session of its own (so a kill of the
//!     tool's process group does not reach it), learns C's pid through a
//!     pipe whose only writer is the tool, and kills group C when that pipe
//!     reaches end of file: when the tool exits, however it exits, SIGKILL
//!     included. Q is not below C, so the cap and the limit neither count it
//!     nor kill it, and a test that calls wait() cannot reap it.
//!   * On Linux, C's exit is read with waitid(WNOWAIT): C stays a zombie
//!     while its group is killed, so the group id cannot be reused by
//!     another process before the kill. Then Q is ended and reaped, and only
//!     then is C reaped. (macOS: waitpid, which reaps; the group is killed
//!     right after.)
//!   * SIGHUP, SIGINT and SIGTERM reach the loop through a self-pipe; the
//!     loop kills group C and the caller exits 128+N.
//!
//! Every call that a test must be able to fail or observe goes through
//! `plat` (Platform): the exec of the program, kill, the clock, the process
//! table and the /proc self check.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const proctab = @import("proctab.zig");

pub const ExecFn = *const fn (path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn;

pub const Platform = struct {
    exec: ExecFn = realExec,
    kill: *const fn (pid: sys.pid_t, sig: u8) void = sys.kill,
    now_ms: *const fn () ?u64 = sys.monotonicMs,
    read_table: *const fn (alloc: std.mem.Allocator) ?proctab.Table = proctab.read,
    group_members: *const fn (alloc: std.mem.Allocator, pgid: i32) ?[]proctab.Member = proctab.groupMembers,
    self_seen: *const fn () [2]i64 = proctab.selfSeen,
    /// Whether this platform has a /proc to read resident memory from.
    has_proc: bool = sys.is_linux,
};

/// The platform every mode uses; tests replace fields of it.
pub var plat: Platform = .{};

pub fn realExec(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) noreturn {
    const err = posix.execveZ(path, argv, envp);
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "gate: cannot run {s}: {s}\n", .{ std.mem.span(path), @errorName(err) }) catch "gate: cannot run the program\n";
    sys.writeAll(2, msg);
    posix.exit(if (err == error.FileNotFound) 127 else 126);
}

/// What the loop does when the time limit passes.
pub const Limit = union(enum) {
    none,
    /// A test's limit (test_deadline.sh's): SIGSTOP, then SIGKILL, C and
    /// every process below it; where /proc cannot be read, or when C is
    /// still alive 10 s later, its whole group.
    deadline_ms: u64,
    /// A coverage run's: SIGKILL to the whole group, then the survivor scan.
    group_ms: u64,
    /// A mutation step's: SIGTERM to the group, 2 s, SIGKILL to the group.
    term_kill_ms: u64,
    /// A Rust harness run's: SIGALRM to C alone (busybox `timeout -s ALRM`).
    alarm_ms: u64,
};

pub const Spec = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8 = null,
    stdout_fd: sys.fd_t,
    stderr_fd: sys.fd_t,
    /// The memory cap in KiB of resident memory of C and its descendants.
    cap_kib: ?u64 = null,
    limit: Limit = .none,
};

pub const Outcome = struct {
    /// C's status, shell style (128+N for signal N).
    status: u8 = 0,
    /// The tool was sent this signal: group C is killed; exit 128+N.
    signal: u8 = 0,
    /// The cap killed C's tree at this resident sum (KiB).
    capped_kib: ?u64 = null,
    /// The time limit passed.
    limit_hit: bool = false,
    /// Three readings in a row could not be used (M4): the group was killed.
    unreadable: bool = false,
    /// The clock could not be read: the group was killed (D5).
    timer_failed: bool = false,
    /// group_ms only, after its kill: /proc does not show this process as
    /// its own (the two pids read), so the survivor scan would be blind.
    blind: ?[2]i64 = null,
    /// group_ms only: members of the group still alive (not zombies) 10 s
    /// after its kill. They are killed again.
    survivors: []const proctab.Member = &.{},
    /// C's pid (process group id), for messages.
    pid: sys.pid_t = 0,
};

var sig_pipe: [2]sys.fd_t = .{ -1, -1 };

fn onSignal(sig: i32) callconv(.C) void {
    const b = [1]u8{@intCast(sig & 0xff)};
    _ = posix.system.write(sig_pipe[1], &b, 1);
}

fn installSignals() !void {
    if (sig_pipe[0] != -1) return;
    sig_pipe = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    const act = posix.Sigaction{ .handler = .{ .handler = onSignal }, .mask = posix.empty_sigset, .flags = 0 };
    for ([_]u6{ posix.SIG.HUP, posix.SIG.INT, posix.SIG.TERM }) |s| try posix.sigaction(s, &act, null);
    if (sys.is_darwin) {
        // macOS: C's exit wakes the loop through SIGCHLD (byte 0 is not a
        // signal the loop acts on; it only checks for an exit).
        const chld = posix.Sigaction{ .handler = .{ .handler = onChild }, .mask = posix.empty_sigset, .flags = posix.SA.NOCLDSTOP };
        try posix.sigaction(posix.SIG.CHLD, &chld, null);
    }
}

fn onChild(_: i32) callconv(.C) void {
    const b = [1]u8{0};
    _ = posix.system.write(sig_pipe[1], &b, 1);
}

/// Pending signal from the self-pipe, 0 for none (or a SIGCHLD wake-up).
fn takeSignal() u8 {
    var got: u8 = 0;
    var b: [16]u8 = undefined;
    while (true) {
        const n = posix.read(sig_pipe[0], &b) catch break;
        if (n == 0) break;
        for (b[0..n]) |s| {
            if (s != 0 and got == 0) got = s;
        }
    }
    return got;
}

/// Closes, in a forked child, every descriptor the tool opened for itself.
fn closeOwn(extra: []const sys.fd_t) void {
    for (sig_pipe) |fd| if (fd >= 0) posix.close(fd);
    for (extra) |fd| if (fd >= 0) posix.close(fd);
}

const Child = struct {
    c: sys.pid_t,
    q: sys.pid_t,
    tether_w: sys.fd_t,
    pidfd: ?sys.fd_t,
    reaped: ?u8 = null,
};

fn spawn(spec: Spec) !Child {
    const tether = try posix.pipe2(.{ .CLOEXEC = true });
    const go = try posix.pipe2(.{ .CLOEXEC = true });

    // Q, the tether: outside C's session, the read end of `tether` only.
    const q = try posix.fork();
    if (q == 0) {
        sys.defaultSignals();
        sys.setsid();
        closeOwn(&.{ tether[1], go[0], go[1] });
        sys.devNullOnto(0, false);
        sys.devNullOnto(1, true);
        sys.devNullOnto(2, true);
        var pid_bytes: [4]u8 = undefined;
        if (sys.readFull(tether[0], &pid_bytes) == 4) {
            const pid = std.mem.readInt(i32, &pid_bytes, .little);
            var sink: [64]u8 = undefined;
            while (true) {
                const n = posix.read(tether[0], &sink) catch |e| switch (e) {
                    else => break,
                };
                if (n == 0) break;
            }
            if (pid > 0) sys.kill(-pid, posix.SIG.KILL);
        }
        posix.exit(0);
    }
    posix.close(tether[0]);

    const c = posix.fork() catch |e| {
        posix.close(tether[1]);
        _ = sys.waitpid(q, false);
        return e;
    };
    if (c == 0) {
        sys.defaultSignals();
        sys.setsid();
        closeOwn(&.{ tether[1], go[1] });
        var b: [1]u8 = undefined;
        // End of file: the tool is gone before it said go; run nothing.
        if (sys.readFull(go[0], &b) != 1) posix.exit(127);
        posix.close(go[0]);
        sys.devNullOnto(0, false);
        if (spec.stdout_fd != 1) posix.dup2(spec.stdout_fd, 1) catch posix.exit(127);
        if (spec.stderr_fd != 2) posix.dup2(spec.stderr_fd, 2) catch posix.exit(127);
        if (spec.cwd) |d| {
            posix.chdirZ(d) catch {
                sys.writeAll(2, "gate: cannot change to the test's directory\n");
                posix.exit(2);
            };
        }
        plat.exec(spec.path, spec.argv, spec.envp);
    }
    posix.close(go[0]);
    var pid_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &pid_bytes, c, .little);
    sys.writeAll(tether[1], &pid_bytes);
    sys.writeAll(go[1], "g");
    posix.close(go[1]);
    return .{ .c = c, .q = q, .tether_w = tether[1], .pidfd = sys.pidfdOpen(c) };
}

/// C's status if it has exited (not reaped on Linux).
fn exited(ch: *Child) ?u8 {
    if (ch.reaped) |s| return s;
    if (sys.is_linux) return sys.exitedNoReap(ch.c);
    ch.reaped = sys.waitpid(ch.c, true);
    return ch.reaped;
}

/// Waits up to `ms` for C's exit or a signal.
fn waitEvent(ch: *Child, ms: i32) void {
    var fds = [2]posix.pollfd{
        .{ .fd = sig_pipe[0], .events = posix.POLL.IN, .revents = 0 },
        .{ .fd = ch.pidfd orelse -1, .events = posix.POLL.IN, .revents = 0 },
    };
    const n: usize = if (ch.pidfd != null) 2 else 1;
    _ = posix.poll(fds[0..n], ms) catch {};
}

fn groupKill(c: sys.pid_t) void {
    plat.kill(-c, posix.SIG.KILL);
}

/// Stops, then kills, C and every process below it; false when the table
/// cannot be read as this process's own (or C is not in it).
fn treeKill(alloc: std.mem.Allocator, c: sys.pid_t) bool {
    const self = sys.getpid();
    const t1 = plat.read_table(alloc) orelse return false;
    if (!t1.has(self)) return false;
    const first = t1.tree(alloc, c) orelse return false;
    for (first) |p| plat.kill(p, posix.SIG.STOP);
    var victims = first;
    if (plat.read_table(alloc)) |t2| {
        if (t2.has(self)) {
            if (t2.tree(alloc, c)) |again| victims = again;
        }
    }
    for (victims) |p| plat.kill(p, posix.SIG.KILL);
    return true;
}

/// Ends the run: kills group C while C is unreaped, ends and reaps Q, then
/// reaps C.
fn finish(ch: *Child) void {
    groupKill(ch.c);
    posix.close(ch.tether_w);
    plat.kill(ch.q, posix.SIG.KILL);
    _ = sys.waitpid(ch.q, false);
    if (ch.reaped == null) ch.reaped = sys.waitpid(ch.c, false);
    if (ch.pidfd) |fd| posix.close(fd);
}

/// The time to wait for a killed group to be gone from /proc.
const survivor_wait_ms = 10_000;
/// D4's wait for C after the tree kill.
const deadline_grace_ms = 10_000;
/// S4's wait between SIGTERM and SIGKILL.
const term_grace_ms = 2_000;

pub fn run(alloc: std.mem.Allocator, spec: Spec) !Outcome {
    try installSignals();
    _ = takeSignal();
    var out = Outcome{};
    const limit_ms: ?u64 = switch (spec.limit) {
        .none => null,
        .deadline_ms, .group_ms, .term_kill_ms, .alarm_ms => |v| v,
    };
    var start: u64 = 0;
    if (limit_ms != null) {
        start = plat.now_ms() orelse {
            out.timer_failed = true;
            return out;
        };
    }

    var ch = try spawn(spec);
    out.pid = ch.c;
    var unread: u32 = 0;
    var cap_on = spec.cap_kib != null;
    var limit_on = limit_ms != null;
    var fired = false;
    var second_kill_at: ?u64 = null;
    const self = sys.getpid();

    while (true) {
        waitEvent(&ch, 100);
        const sig = takeSignal();
        if (sig != 0) {
            out.signal = sig;
            finish(&ch);
            return out;
        }
        if (exited(&ch)) |st| {
            out.status = st;
            break;
        }
        var tick = std.heap.ArenaAllocator.init(alloc);
        defer tick.deinit();
        const a = tick.allocator();

        if (cap_on) {
            const tab = plat.read_table(a);
            if (tab == null or !tab.?.has(self)) {
                unread += 1;
                if (unread >= 3) {
                    out.unreadable = true;
                    groupKill(ch.c);
                    cap_on = false;
                    limit_on = false;
                }
            } else {
                unread = 0;
                if (tab.?.tree(a, ch.c)) |pids| {
                    const sum = tab.?.rss(pids);
                    if (sum > spec.cap_kib.?) {
                        out.capped_kib = sum;
                        cap_on = false;
                        if (!treeKill(a, ch.c)) groupKill(ch.c);
                    }
                }
            }
        }

        if (limit_on) {
            const now = plat.now_ms() orelse {
                out.timer_failed = true;
                groupKill(ch.c);
                limit_on = false;
                cap_on = false;
                continue;
            };
            if (!fired and now -| start >= limit_ms.?) {
                fired = true;
                out.limit_hit = true;
                switch (spec.limit) {
                    .none => {},
                    .deadline_ms => {
                        if (plat.has_proc and treeKill(a, ch.c)) {
                            second_kill_at = now + deadline_grace_ms;
                        } else {
                            groupKill(ch.c);
                        }
                    },
                    .group_ms => groupKill(ch.c),
                    .term_kill_ms => {
                        plat.kill(-ch.c, posix.SIG.TERM);
                        second_kill_at = now + term_grace_ms;
                    },
                    .alarm_ms => plat.kill(ch.c, posix.SIG.ALRM),
                }
            }
            if (second_kill_at) |at| {
                if (now >= at) {
                    groupKill(ch.c);
                    second_kill_at = null;
                }
            }
        }
    }

    if (spec.limit == .group_ms and out.limit_hit) {
        // C1: the kill must have reached every process of the group. The
        // scan reads /proc, so /proc must show this process as its own.
        const seen = plat.self_seen();
        if (seen[0] != self or seen[1] != self) {
            out.blind = seen;
        } else {
            const deadline = (sys.monotonicMs() orelse 0) + survivor_wait_ms;
            while (true) {
                const left: []const proctab.Member = plat.group_members(alloc, ch.c) orelse &.{};
                out.survivors = left;
                if (left.len == 0) break;
                if ((sys.monotonicMs() orelse deadline) >= deadline) break;
                sys.sleepMs(1000);
            }
        }
    }
    finish(&ch);
    return out;
}

/// Runs `argv` (argv[0] is the program) with the inherited environment and
/// waits for it: the one plain child the modes start (`busybox --install`).
pub fn runPlain(alloc: std.mem.Allocator, argv: []const []const u8) !u8 {
    const z = try alloc.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| z[i] = (try alloc.dupeZ(u8, a)).ptr;
    const env = try alloc.allocSentinel(?[*:0]const u8, std.os.environ.len, null);
    for (std.os.environ, 0..) |e, i| env[i] = e;
    const pid = try posix.fork();
    if (pid == 0) {
        sys.defaultSignals();
        closeOwn(&.{});
        sys.devNullOnto(0, false);
        const err = posix.execveZ(z[0].?, z, env);
        sys.writeAll(2, "gate: cannot run ");
        sys.writeAll(2, argv[0]);
        sys.writeAll(2, ": ");
        sys.writeAll(2, @errorName(err));
        sys.writeAll(2, "\n");
        posix.exit(127);
    }
    return sys.waitpid(pid, false) orelse 127;
}
