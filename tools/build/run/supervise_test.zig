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
        var l = std.ArrayList([]const u8).empty;
        try l.appendSlice(e.a, &.{ "mojo", "--busybox", e.bb, "--runtime-lib", "rt/lib", "--label", label, "--test" });
        try l.append(e.a, try std.fmt.allocPrint(e.a, "root/bin/{s}", .{what}));
        try l.appendSlice(e.a, &.{ "--marker", "passed" });
        try l.appendSlice(e.a, extra);
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

// The MiB that the MEMORY CAP line reports, null when there is none.
fn cappedMib(err: []const u8) ?u64 {
    const key = "MEMORY CAP: killed //x:y at ";
    const i = std.mem.indexOf(u8, err, key) orelse return null;
    const rest = err[i + key.len ..];
    const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
    return std.fmt.parseInt(u64, rest[0..sp], 10) catch null;
}

// M3 for a hog of 64 MiB under a cap of 32 MiB. With `stop` (MiB) the hog
// says it is up after that many MiB and holds there, so the cap's kill
// comes while it is still touching and it never reaches "hog holds"; the
// run must read the same as one whose hog has finished growing. Without it
// the cap may kill the hog at any tick once it is over 32 MiB, so the only
// line of the hog's that the test relies on is the one it prints before it
// touches anything. The hog holds for an hour: only the cap ends it.
fn capKillsHog(stop: []const u8) !void {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("hog", &.{ "--mem-cap-mib", "32", "--arg", "64", "--arg", "3600", "--arg", stop }), .{});
    try std.testing.expectEqual(@as(u8, 137), r.status);
    // The banner, then the log's tail (the hog's first line), then the cap's line.
    try std.testing.expect(before(r.err, banner137, "hog touches 64 MiB\n"));
    try std.testing.expect(before(r.err, "hog touches 64 MiB\n", "MEMORY CAP: killed //x:y at "));
    try std.testing.expect(contains(r.err, " MiB resident, over its cap of 32 MiB\n"));
    // The reading is the hog's own memory: over the cap, as resident.
    const mib = cappedMib(r.err) orelse return error.NoCapReading;
    try std.testing.expect(mib >= 32);
    if (!std.mem.eql(u8, stop, "0")) {
        // Held at 40 MiB: the reading is below the 64 of a finished hog.
        try std.testing.expect(mib < 64);
        try std.testing.expect(!contains(r.err, "hog holds"));
    }
    try std.testing.expect(!kit.exists(try e.pidFile("passed")));
}

// M2, M3. Mutants: `>=` for `>` (not caught here: the sums are far from
// the cap; see the boundary test below), spare C (the single-process hog
// survives its cap: exit 0 after 30 s), or print the cap's line before
// the banner.
test "M3 cap: a hog over its cap is killed (137), the banner first, then the MEMORY CAP line" {
    try capKillsHog("0");
}

// M3 with the hog held part-way: the cap kills it in the middle of its
// touching, long before it could print "hog holds". Defect caught: a test
// (or a supervisor) that only works when the hog has finished growing before
// the first tick over the cap. Mutants: those of the test above.
test "M3 cap: a hog killed while its pages are still being touched reads the same" {
    try capKillsHog("40");
}

test "M3 cap: a test under its cap passes" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("hog", &.{ "--mem-cap-mib", "64", "--arg", "16", "--arg", "1" }), .{});
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("", r.err);
}

// M2: the cap counts the test and every descendant. Neither process is over
// the cap alone (16 and 24 MiB under 32); together they are. Mutants: sum
// the test's own memory only (`rss(pids[0..1])`), or take the largest
// process instead of the sum (both runs pass after 5 s).
test "M2 cap: a test whose child pushes the tree's total over the cap is killed (137) with the MEMORY CAP line" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("treehog", &.{ "--mem-cap-mib", "32", "--arg", "16", "--arg", "24", "--arg", "3600" }), .{});
    try std.testing.expectEqual(@as(u8, 137), r.status);
    try std.testing.expect(before(r.err, banner137, "MEMORY CAP: killed //x:y at "));
    try std.testing.expect(contains(r.err, " MiB resident, over its cap of 32 MiB\n"));
    try std.testing.expect(!kit.exists(try e.pidFile("passed")));
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
    const r2 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "32", "--arg", "3600" }), .{ .setup = setup2 });
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
    kit.waitGone(pids);
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
    var out = std.ArrayList(proctab.Proc).empty;
    for (t.procs) |p| {
        if (p.pid != sys.getpid()) out.append(alloc, p) catch return null;
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
    const r = try kit.runGate(e.a, e.dir, try e.args("pid", &.{ "--mem-cap-mib", "512", "--arg", f, "--arg", "sleep", "--arg", "3600" }), .{ .setup = three, .clock = true });
    try std.testing.expectEqual(@as(u8, 2), r.status);
    try std.testing.expect(contains(r.err, "mem_cap: cannot read the process tree of //x:y from /proc; killed it rather than run it uncapped\n"));
    // The third unreadable tick (3 x 100 ms on the test's clock) kills the group.
    try std.testing.expect(kit.hasEvents(r.events, &.{"t=300 KILL -C"}));
    try std.testing.expectEqual(@as(?u64, 300), kit.firstTime(r.events, " KILL -C"));
    kit.waitGone(try kit.pidsFrom(e.a, f, 1));

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
    const r3 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--mem-cap-mib", "512", "--arg", "3600" }), .{ .setup = blind });
    try std.testing.expectEqual(@as(u8, 2), r3.status);
    try std.testing.expect(contains(r3.err, "mem_cap: cannot read the process tree"));
}

// D2. Mutant: wait for the limit before returning the status.
test "D2 prompt exit: exit 7 under a 30 s limit returns at once, with no decision made at the limit" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, try e.args("exit", &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--arg", "7" }), .{ .clock = true });
    try std.testing.expectEqual(@as(u8, 7), r.status);
    // The test's clock never moved: every kill is the end-of-run cleanup at t=0.
    try std.testing.expectEqual(@as(usize, 0), kit.countEvents(r.events, "STOP"));
    try std.testing.expectEqual(@as(usize, 0), kit.countEvents(r.events, "sleep"));
    var lines = std.mem.splitScalar(u8, r.events, '\n');
    while (lines.next()) |l| try std.testing.expect(l.len == 0 or std.mem.startsWith(u8, l, "t=0 "));
    try std.testing.expect(!contains(r.err, "TEST TIME LIMIT"));
}

// D3 (change 2: everything below the tool, C included, is killed). Mutant:
// spare C (the sleeper passes after 6 s), or print the line first.
test "D3 deadline: a sleeper past its limit is killed (137), the banner, then the TEST TIME LIMIT line" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("d3.pids");
    const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--deadline-s", "2", "--runner-timeout-s", "62", "--arg", f }), .{ .clock = true });
    try std.testing.expectEqual(@as(u8, 137), r.status);
    // At 2000 ms on the test's clock: the tree is stopped (C, then its child)
    // and then killed, C included, and the group after.
    try std.testing.expect(kit.hasEvents(r.events, &.{ "t=2000 STOP C", "t=2000 STOP M1", "t=2000 KILL C", "t=2000 KILL M1", "t=2000 KILL -C" }));
    try std.testing.expect(before(r.err, banner137, "TEST TIME LIMIT: killed //x:y after 2 s, under the test runner's timeout of 62 s (komira.test_timeout_s)\n"));
    kit.waitGone(try kit.pidsFrom(e.a, f, 2));
}

var c_pid: i32 = 0;
fn sparingKill(pid: sys.pid_t, sig: u8) void {
    // The tree kill's signals to C itself are lost (as if C were stopped
    // where they cannot reach it); a group kill still arrives.
    if (pid > 0 and (sig == posix.SIG.KILL or sig == posix.SIG.STOP)) {
        if (c_pid == 0) c_pid = pid;
        if (pid == c_pid) return;
    }
    kit.killRecorded(pid, sig);
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
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--deadline-s", "1", "--runner-timeout-s", "61", "--arg", "3600" }), .{ .setup = setup, .clock = true });
    try std.testing.expectEqual(@as(u8, 137), r.status);
    // The tree kill at 1000 ms never reached C; the group kill comes
    // exactly deadline_grace (10 s) later.
    try std.testing.expectEqual(@as(?u64, 11_000), kit.firstTime(r.events, " KILL -C"));
    try std.testing.expect(before(r.err, banner137, "TEST TIME LIMIT: killed //x:y after 1 s"));
}

var clock_calls: u32 = 0;
fn failingClock() ?u64 {
    clock_calls += 1;
    if (clock_calls > 1) return null;
    return 0;
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
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--deadline-s", "30", "--runner-timeout-s", "90", "--arg", "3600" }), .{ .setup = later });
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
        const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--mem-cap-mib", "512", "--arg", f }), .{ .signal = sr[0] });
        try std.testing.expectEqual(sr[1], r.status);
        kit.waitGone(try kit.pidsFrom(e.a, f, 2));
        try std.testing.expect(!kit.exists(try e.pidFile("passed")));
    }
}

// M6. Mutant: the tether inside C's session (the tree kill or the group
// kill reaches it), or no tether.
test "M6 tether: SIGKILL to the tool ends the session" {
    const e = try Env.init();
    defer e.deinit();
    const f = try e.pidFile("m6.pids");
    const r = kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--arg", f }), .{ .signal = posix.SIG.KILL });
    try std.testing.expectEqual(@as(u8, 137), (try r).status);
    kit.waitGone(try kit.pidsFrom(e.a, f, 2));
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
    kit.killRecorded(pid, sig);
}

// 2.1 step 4. Mutant: reap C before its group is killed (its /proc entry is
// gone, so its group id could already be another process's). Linux only:
// macOS has no waitid(WNOWAIT), so there C is reaped (waitpid) and its group
// killed right after (supervise.zig, `exited`).
test "no pid reuse: C is still a zombie when its group is killed" {
    if (!sys.is_linux) return error.SkipZigTest;
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
    const r = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--limit-s", "2", "--limit-report", "coverage", "--arg", f }), .{ .clock = true });
    try std.testing.expectEqual(@as(u8, 1), r.status);
    // The whole group is killed at the limit, and the scan, which waits for
    // the killed members to be gone, finds none and never has to nap.
    try std.testing.expect(kit.hasEvents(r.events, &.{"t=2000 KILL -C"}));
    try std.testing.expectEqual(@as(usize, 0), kit.countEvents(r.events, "sleep"));
    try std.testing.expect(!contains(r.err, "survived the kill"));
    try std.testing.expect(contains(r.err, "------------------------------------------------------------------ output (last 200 lines)\n"));
    try std.testing.expect(contains(r.err, "==================================================================\nCOVERAGE RUN FAILED: //x:y\nThe test left processes running or did not finish within 2 s under kcov, and every process of the run was killed: kcov waits for every process the test started, where the release gate waits for the test alone. A test must wait for (or kill) every child it starts.\n==================================================================\n"));
    try std.testing.expect(!contains(r.err, "GATED TEST FAILED"));
    kit.waitGone(try kit.pidsFrom(e.a, f, 2));
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
    const r = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--limit-s", "1", "--limit-report", "coverage", "--arg", "3600" }), .{ .setup = surv, .clock = true });
    try std.testing.expectEqual(@as(u8, 1), r.status);
    try std.testing.expect(contains(r.err, "After the time limit (1 s), processes of the coverage run survived the kill of its process group "));
    try std.testing.expect(contains(r.err, "(pid state comm: 4242 S stuck;)"));
    // The scan waited survivor_wait (10 s) in 1 s naps on the test's clock,
    // from the group kill at 1000 ms, before it gave the member up.
    try std.testing.expectEqual(@as(usize, 10), kit.countEvents(r.events, " sleep 1000"));
    try std.testing.expect(kit.hasEvents(r.events, &.{ "t=1000 KILL -C", "t=1000 sleep 1000", "t=10000 sleep 1000" }));
    const blind = struct {
        fn s() void {
            supervise.plat.self_seen = blindSelf;
        }
    }.s;
    const r2 = try kit.runGate(e.a, e.dir, try e.args("sleep", &.{ "--limit-s", "1", "--limit-report", "coverage", "--arg", "3600" }), .{ .setup = blind, .clock = true });
    try std.testing.expectEqual(@as(u8, 1), r2.status);
    try std.testing.expect(contains(r2.err, "/proc is not readable as this run's own"));
}

fn noProc(alloc: std.mem.Allocator) ?proctab.Table {
    _ = alloc;
    return null;
}

// A platform with no process table (neither /proc nor libproc), through
// the platform interface. Mutant: run a capped test uncapped where there is
// no table.
test "no process table: a cap is refused with exit 2; the deadline group-kills and still prints the banner" {
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
    const r2 = try kit.runGate(e.a, e.dir, try e.args("spawnwait", &.{ "--deadline-s", "1", "--runner-timeout-s", "61", "--arg", f }), .{ .setup = setup, .clock = true });
    try std.testing.expectEqual(@as(u8, 137), r2.status);
    // No table: the group is killed at the limit, with no stop of the tree.
    try std.testing.expectEqual(@as(?u64, 1000), kit.firstTime(r2.events, " KILL -C"));
    try std.testing.expectEqual(@as(usize, 0), kit.countEvents(r2.events, "STOP"));
    try std.testing.expect(before(r2.err, banner137, "TEST TIME LIMIT: killed //x:y after 1 s"));
    kit.waitGone(try kit.pidsFrom(e.a, f, 2));
}

// The real table of this platform (/proc on Linux, libproc on macOS), read
// as the cap reads it: a forked child holding 32 MiB of touched memory is
// below this process, the tree's sum counts it, and once it has exited
// (unreaped) it is a zombie with no tree. Mutants (macOS): the parent pid
// read from the wrong field (the child is not below this process), the
// virtual size for the resident one (the sum is gigabytes), or a zombie
// read as alive.
test "the process table of this platform: a child's pages count toward its parent's tree; an exited child is a zombie" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const go = try posix.pipe();
    const pid = try posix.fork();
    if (pid == 0) {
        posix.close(go[0]);
        const mem = std.heap.page_allocator.alloc(u8, 32 << 20) catch posix.exit(99);
        var i: usize = 0;
        while (i < mem.len) : (i += 4096) mem[i] = 1;
        sys.writeAll(go[1], "r");
        sys.sleepMs(3_600_000);
        posix.exit(0);
    }
    posix.close(go[1]);
    var b: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), sys.readFull(go[0], &b));
    const me = sys.getpid();
    const t = proctab.read(a).?;
    try std.testing.expect(t.has(me));
    try std.testing.expectEqual(me, t.find(pid).?.ppid);
    const tree = t.tree(a, me).?;
    try std.testing.expect(std.mem.indexOfScalar(i32, tree, pid) != null);
    const child_kib = t.rss(&.{pid});
    try std.testing.expect(child_kib >= 32 * 1024);
    // Resident, not virtual: well under a gigabyte for a 32 MiB hog.
    try std.testing.expect(child_kib < 1024 * 1024);
    try std.testing.expect(t.rss(tree) >= child_kib);
    try std.testing.expect(kit.alive(pid));

    sys.kill(pid, posix.SIG.KILL);
    kit.waitExit(pid);
    const t2 = proctab.read(a).?;
    const gone = if (t2.find(pid)) |p| p.state == 'Z' else true;
    try std.testing.expect(gone);
    try std.testing.expect(!kit.alive(pid));
    try std.testing.expectEqual(@as(?[]i32, null), proctab.read(a).?.tree(a, pid));
    const seen = proctab.selfSeen();
    try std.testing.expectEqual(@as(i64, me), seen[0]);
    try std.testing.expectEqual(@as(i64, me), seen[1]);
    try std.testing.expectEqual(@as(?u8, 137), sys.waitpid(pid, false));
}
