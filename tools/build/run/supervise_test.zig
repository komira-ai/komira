//! The supervisor through `gate mojo` (M1-M6, D1-D6, C1, and the deliberate
//! changes of docs/design/zig_gate_runner.md section 3): the memory cap, the
//! test time limit, the coverage run's limit, signals, the tether, and that
//! no process group id is reused. Each test names the defect it catches.

const std = @import("std");
const posix = std.posix;
const kit = @import("testkit.zig");
const sys = @import("sys.zig");
const supervise = @import("supervise.zig");
const proctab = @import("proctab.zig");

const label = "//x:y";
const banner137 = "GATED TEST FAILED: //x:y (exit 137)\n";

const Env = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    dir: []const u8,
    bb: []const u8,

    fn init() !*Env {
        const e = try std.heap.page_allocator.create(Env);
        e.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        e.a = e.arena.allocator();
        e.dir = try kit.tempDir(e.a);
        e.bb = try kit.busybox(e.a);
        return e;
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        std.heap.page_allocator.destroy(e);
    }

    fn args(e: *Env, what: []const u8, extra: []const []const u8) ![]const []const u8 {
        var l = std.ArrayList([]const u8).init(e.a);
        try l.appendSlice(&.{ "mojo", "--busybox", e.bb, "--runtime-lib", "rt/lib", "--label", label, "--test" });
        try l.append(try std.fmt.allocPrint(e.a, "root/bin/{s}", .{what}));
        try l.appendSlice(&.{ "--marker", "passed" });
        try l.appendSlice(extra);
        return l.items;
    }

    fn pidFile(e: *Env, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(e.a, "{s}/{s}", .{ e.dir, name });
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn before(hay: []const u8, first: []const u8, second: []const u8) bool {
    const i = std.mem.indexOf(u8, hay, first) orelse return false;
    const j = std.mem.indexOf(u8, hay, second) orelse return false;
    return i < j;
}

// M2, M3. Mutants: `>=` for `>` (not caught here: the sums are far from
// the cap; see the boundary test below), spare C (the single-process hog
// survives its cap and passes after 3 s), or print the cap's line before
// the banner.
test "M3 cap: a hog over its cap is killed (137), the banner first, then the MEMORY CAP line" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("hog", &.{ "--mem-cap-mib", "32", "--arg", "64", "--arg", "3" }), .{});
    try std.testing.expectEqual(@as(u8, 137), r.status);
    try std.testing.expect(contains(r.err, "hog holds 64 MiB"));
    try std.testing.expect(before(r.err, banner137, "MEMORY CAP: killed //x:y at "));
    try std.testing.expect(contains(r.err, " MiB resident, over its cap of 32 MiB\n"));
    try std.testing.expect(!kit.exists(try e.pidFile("passed")));
}

test "M3 cap: a test under its cap passes" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("hog", &.{ "--mem-cap-mib", "64", "--arg", "16", "--arg", "1" }), .{});
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("", r.err);
}

var boundary_kib: u64 = 0;
fn tableAtCap(alloc: std.mem.Allocator) ?proctab.Table {
    const t = proctab.read(alloc) orelse return null;
    // Every process of the run reads as the cap exactly: the sum is over the
    // cap only by more than the cap.
    for (t.procs) |*p| p.rss_kib = 0;
    var c: i32 = 0;
    for (t.procs) |p| {
        if (p.ppid == sys.getpid()) c = @max(c, p.pid);
    }
    for (t.procs) |*p| {
        if (p.pid == c) p.rss_kib = boundary_kib;
    }
    return t;
}

// M3: strictly over. Mutant: `>=` (a test exactly at its cap is killed).
test "M3 cap: a test exactly at its cap is not over it" {
    const e = try Env.init();
    defer e.deinit();
    const setup = struct {
        fn f() void {
            boundary_kib = 32 * 1024;
            supervise.plat.read_table = tableAtCap;
        }
    }.f;
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "32", "--arg", "1" }), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 0), r.status);
    const setup2 = struct {
        fn f() void {
            boundary_kib = 32 * 1024 + 1;
            supervise.plat.read_table = tableAtCap;
        }
    }.f;
    const r2 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "32", "--arg", "5" }), .{ .setup = setup2 });
    try std.testing.expectEqual(@as(u8, 137), r2.status);
    try std.testing.expect(contains(r2.err, "MEMORY CAP: killed //x:y at 32 MiB resident, over its cap of 32 MiB\n"));
}

// M5: after C exits, its group is killed. Mutant: no group kill after the
// exit (the daemonized child lives on).
test "M5 a child left in the group by a passing test is killed when the test exits" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("daemon.pids");
    const r = try kit.runGate(e.a, e.dir, try e.args("daemon", &.{ "--mem-cap-mib", "512", "--arg", f, "--arg", "hog" }), .{});
    try std.testing.expectEqual(@as(u8, 0), r.status);
    const pids = try kit.pidsFrom(e.a, f, 1);
    try std.testing.expect(kit.goneWithin(pids, 5000));
}

var fail_reads: u32 = 0;
var reads: u32 = 0;
fn flakyTable(alloc: std.mem.Allocator) ?proctab.Table {
    reads += 1;
    if (reads <= fail_reads) return null;
    return proctab.read(alloc);
}
fn blindTable(alloc: std.mem.Allocator) ?proctab.Table {
    const t = proctab.read(alloc) orelse return null;
    var out = std.ArrayList(proctab.Proc).init(alloc);
    for (t.procs) |p| {
        if (p.pid != sys.getpid()) out.append(p) catch return null;
    }
    return .{ .procs = out.items };
}

// M4. Mutant: accept a reading that does not show the tool's own pid (the
// blind case runs uncapped and passes).
test "M4 unreadable: three failed readings kill the group and exit 2; two do not; a blind one counts" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("m4.pids");
    const three = struct {
        fn s() void {
            fail_reads = 1000;
            supervise.plat.read_table = flakyTable;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("pid", &.{ "--mem-cap-mib", "512", "--arg", f, "--arg", "sleep", "--arg", "30" }), .{ .setup = three });
    try std.testing.expectEqual(@as(u8, 2), r.status);
    try std.testing.expect(contains(r.err, "mem_cap: cannot read the process tree of //x:y from /proc; killed it rather than run it uncapped\n"));
    try std.testing.expect(r.ms < 10_000);
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 1), 2000));

    const two = struct {
        fn s() void {
            fail_reads = 2;
            supervise.plat.read_table = flakyTable;
        }
    }.s;
    const r2 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "512", "--arg", "1" }), .{ .setup = two });
    try std.testing.expectEqual(@as(u8, 0), r2.status);

    const blind = struct {
        fn s() void {
            supervise.plat.read_table = blindTable;
        }
    }.s;
    const r3 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "512", "--arg", "30" }), .{ .setup = blind });
    try std.testing.expectEqual(@as(u8, 2), r3.status);
    try std.testing.expect(contains(r3.err, "mem_cap: cannot read the process tree"));
}

// D2. Mutant: wait for the limit before returning the status.
test "D2 prompt exit: exit 7 under a 30 s limit returns at once" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("exit", &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--arg", "7" }), .{});
    try std.testing.expectEqual(@as(u8, 7), r.status);
    try std.testing.expect(r.ms < 2000);
    try std.testing.expect(!contains(r.err, "TEST TIME LIMIT"));
}

// D3 (change 2: everything below the tool, C included, is killed). Mutant:
// spare C (the sleeper passes after 6 s), or print the line first.
test "D3 deadline: a sleeper past its limit is killed (137), the banner, then the TEST TIME LIMIT line" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("d3.pids");
    const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--deadline-s", "2", "--runner-timeout-s", "62", "--arg", f }), .{});
    try std.testing.expectEqual(@as(u8, 137), r.status);
    try std.testing.expect(before(r.err, banner137, "TEST TIME LIMIT: killed //x:y after 2 s, under the test runner's timeout of 62 s (komira.test_timeout_s)\n"));
    try std.testing.expect(r.ms < 6000);
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 2000));
}

var c_pid: i32 = 0;
fn sparingKill(pid: sys.pid_t, sig: u8) void {
    // The tree kill's signals to C itself are lost (as if C were stopped
    // where they cannot reach it); a group kill still arrives.
    if (pid > 0 and (sig == posix.SIG.KILL or sig == posix.SIG.STOP)) {
        if (c_pid == 0) c_pid = pid;
        if (pid == c_pid) return;
    }
    sys.kill(pid, sig);
}

// D4. Mutant: omit the 10 s group-kill fallback (the run never ends; the
// test's own timeout fails it).
test "D4 deadline: a test the tree kill misses dies by the group kill 10 s later, and is reported" {
    const e = try Env.init();
    defer e.deinit();
    const setup = struct {
        fn s() void {
            c_pid = 0;
            supervise.plat.kill = sparingKill;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--deadline-s", "1", "--runner-timeout-s", "61", "--arg", "60" }), .{ .setup = setup, .timeout_ms = 25_000 });
    try std.testing.expectEqual(@as(u8, 137), r.status);
    try std.testing.expect(r.ms >= 10_000 and r.ms < 14_000);
    try std.testing.expect(before(r.err, banner137, "TEST TIME LIMIT: killed //x:y after 1 s"));
}

var clock_calls: u32 = 0;
fn failingClock() ?u64 {
    clock_calls += 1;
    if (clock_calls > 1) return null;
    return sys.monotonicMs();
}
fn deadClock() ?u64 {
    return null;
}

// D5. Mutant: ignore the clock's failure (the test runs without its limit
// and passes).
test "D5 timer: a clock that fails gives exit 2 and the D5 message" {
    const e = try Env.init();
    defer e.deinit();
    const later = struct {
        fn s() void {
            clock_calls = 0;
            supervise.plat.now_ms = failingClock;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--arg", "2" }), .{ .setup = later });
    try std.testing.expectEqual(@as(u8, 2), r.status);
    try std.testing.expectEqualStrings("test_deadline: the timer of //x:y failed, so the test ran without its limit of 30 s\n", r.err);
    const at_start = struct {
        fn s() void {
            supervise.plat.now_ms = deadClock;
        }
    }.s;
    const r2 = try kit.runGate(e.a, e.dir, try e.args("exit", &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--arg", "0" }), .{ .setup = at_start });
    try std.testing.expectEqual(@as(u8, 2), r2.status);
}

// M5, D6. Mutant: exit 0 on a signal (or leave the session running).
test "M5 D6 signals: SIGTERM and SIGINT kill the session and exit 143 and 130" {
    const e = try Env.init();
    defer e.deinit();
    for ([_][2]u8{ .{ posix.SIG.TERM, 143 }, .{ posix.SIG.INT, 130 }, .{ posix.SIG.HUP, 129 } }) |sr| {
        const f = try std.fmt.allocPrint(e.a, "{s}/sig{d}.pids", .{ e.dir, sr[0] });
        const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--mem-cap-mib", "512", "--arg", f }), .{ .signal = .{ .sig = sr[0], .after_ms = 1000 } });
        try std.testing.expectEqual(sr[1], r.status);
        try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 5000));
        try std.testing.expect(!kit.exists(try e.pidFile("passed")));
    }
}

// M6. Mutant: the tether inside C's session (the tree kill or the group
// kill reaches it), or no tether.
test "M6 tether: SIGKILL to the tool ends the session within 5 s" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("m6.pids");
    const r = kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--arg", f }), .{ .signal = .{ .sig = posix.SIG.KILL, .after_ms = 1000 } });
    try std.testing.expectEqual(@as(u8, 137), (try r).status);
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 5000));
}

var zombie_seen: u8 = 0;
var exit_seen_pid: i32 = 0;
fn recordingKill(pid: sys.pid_t, sig: u8) void {
    if (pid < 0 and sig == posix.SIG.KILL and zombie_seen == 0) {
        var buf: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "/proc/{d}/stat", .{-pid}) catch "";
        var b: [512]u8 = undefined;
        if (std.fs.cwd().openFile(p, .{})) |file| {
            defer file.close();
            const n = file.readAll(&b) catch 0;
            if (proctab.parseStat(b[0..n])) |s| zombie_seen = s.state;
        } else |_| zombie_seen = '-';
        const out = std.fmt.bufPrint(&buf, "group kill: C was {c}\n", .{zombie_seen}) catch "";
        sys.writeAll(2, out);
    }
    sys.kill(pid, sig);
}

// 2.1 step 4. Mutant: reap C before its group is killed (its /proc entry is
// gone, so its group id could already be another process's).
test "no pid reuse: C is still a zombie when its group is killed" {
    const e = try Env.init();
    defer e.deinit();
    const setup = struct {
        fn s() void {
            zombie_seen = 0;
            supervise.plat.kill = recordingKill;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("exit", &.{ "--arg", "5" }), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 5), r.status);
    try std.testing.expect(contains(r.err, "group kill: C was Z\n"));
}

// C1. Mutant: kill the leader only (the daemonized sleeper survives, and
// the scan reports it).
test "C1 coverage limit: the whole group is killed, exit 1, the log tail and the COVERAGE RUN FAILED text" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("c1.pids");
    const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--limit-s", "2", "--limit-report", "coverage", "--arg", f }), .{});
    try std.testing.expectEqual(@as(u8, 1), r.status);
    try std.testing.expect(!contains(r.err, "survived the kill"));
    try std.testing.expect(contains(r.err, "------------------------------------------------------------------ output (last 200 lines)\n"));
    try std.testing.expect(contains(r.err, "==================================================================\nCOVERAGE RUN FAILED: //x:y\nThe test left processes running or did not finish within 2 s under kcov, and every process of the run was killed: kcov waits for every process the test started, where the release gate waits for the test alone. A test must wait for (or kill) every child it starts.\n==================================================================\n"));
    try std.testing.expect(!contains(r.err, "GATED TEST FAILED"));
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 2000));
}

fn fakeSurvivor(alloc: std.mem.Allocator, pgid: i32) ?[]proctab.Member {
    _ = pgid;
    const m = alloc.alloc(proctab.Member, 1) catch return null;
    m[0] = .{ .pid = 4242, .state = 'S', .comm = "stuck" };
    return m;
}
fn blindSelf() [2]i64 {
    return .{ 1, sys.getpid() };
}

test "C1 coverage limit: a survivor of the kill and a blind /proc are each refused" {
    const e = try Env.init();
    defer e.deinit();
    const surv = struct {
        fn s() void {
            supervise.plat.group_members = fakeSurvivor;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--limit-s", "1", "--limit-report", "coverage", "--arg", "30" }), .{ .setup = surv, .timeout_ms = 30_000 });
    try std.testing.expectEqual(@as(u8, 1), r.status);
    try std.testing.expect(contains(r.err, "After the time limit (1 s), processes of the coverage run survived the kill of its process group "));
    try std.testing.expect(contains(r.err, "(pid state comm: 4242 S stuck;)"));
    const blind = struct {
        fn s() void {
            supervise.plat.self_seen = blindSelf;
        }
    }.s;
    const r2 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--limit-s", "1", "--limit-report", "coverage", "--arg", "30" }), .{ .setup = blind });
    try std.testing.expectEqual(@as(u8, 1), r2.status);
    try std.testing.expect(contains(r2.err, "/proc is not readable as this run's own"));
}

fn noProc(alloc: std.mem.Allocator) ?proctab.Table {
    _ = alloc;
    return null;
}

// macOS paths, on Linux through the platform interface. Mutant: run a
// capped test uncapped where there is no /proc.
test "no /proc (macOS): a cap is refused with exit 2; the deadline group-kills and still prints the banner" {
    const e = try Env.init();
    defer e.deinit();
    const setup = struct {
        fn s() void {
            supervise.plat.has_proc = false;
            supervise.plat.read_table = noProc;
        }
    }.s;
    const r = try kit.runGate(e.a, e.dir, try e.args("exit", &.{ "--mem-cap-mib", "32", "--arg", "0" }), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 2), r.status);
    try std.testing.expectEqualStrings("mem_cap: REFUSING: no /proc here to read resident memory from; //x:y would run uncapped\n", r.err);
    try std.testing.expect(!kit.exists(try e.pidFile("passed")));
    const f = try e.pidFile("noproc.pids");
    const r2 = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--deadline-s", "1", "--runner-timeout-s", "61", "--arg", f }), .{ .setup = setup });
    try std.testing.expectEqual(@as(u8, 137), r2.status);
    try std.testing.expect(r2.ms < 5000);
    try std.testing.expect(before(r2.err, banner137, "TEST TIME LIMIT: killed //x:y after 1 s"));
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 2000));
}
