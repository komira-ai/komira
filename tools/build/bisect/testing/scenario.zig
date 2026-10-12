//! bisect's scenarios (README.md, "Tests"): each builds a throwaway
//! repository with the pinned git, runs the bisect under test against it with
//! fake_buck2.zig as its buck2, and checks the verdict, the exit code and
//! that nothing outside the probe worktrees changed. One build action per
//! scenario (defs.bzl, `bisect_scenario`); it writes `--out` only when every
//! check held.
//!
//! The repository: a `base` commit, then one candidate per pull request,
//! each a `--no-ff` merge `Merge pull request #<100+i> from example/side<i>`
//! of a one-commit side branch. Each commit's `bisect_fixture.txt` says
//! what fake_buck2 does there.
const std = @import("std");

const Good = enum { base, stray };
const Mode = enum { bisect, flake };

/// What one target's measurement must show (flake.zig).
const FlakeTarget = struct {
    target: []const u8,
    runs: i64,
    failures: i64,
    /// Builds, retries included; also what fake_buck2 must have seen.
    attempts: i64,
    /// Exact failing n; null when the base is the tool's own.
    failing_runs: ?[]const i64 = null,
    infra_runs: []const i64 = &.{},
    /// The excerpt groups, with the runs of the first.
    excerpts: usize = 0,
    first_excerpt_runs: ?[]const i64 = null,
    /// The measurement's `check` of the target, and how many check.bxl runs
    /// of it (with run 1's value) fake_buck2 saw.
    check: []const u8 = "measurable",
    checks: i64 = 1,
};

const Spec = struct {
    /// Fixture of each candidate, oldest first; the last is bad.
    states: []const []const u8,
    targets: []const []const u8 = &.{"root//t:a"},
    good: Good = .base,
    mode: Mode = .bisect,
    /// `bisect flake --runs`.
    runs: u32 = 0,
    /// `--flake-runs` of bisect; null passes none (its default).
    flake_runs: ?u32 = null,
    /// `--rerun-base`; null passes none (the tool picks one).
    rerun_base: ?u64 = null,
    /// `bisect flake` runs this many times, each with a work dir of its own.
    invocations: u32 = 1,
    expect: Expect,
};

const Expect = struct {
    exit: u8,
    verdict: ?[]const u8 = null,
    /// The candidate index of first_bad.
    first_bad: ?usize = null,
    /// The candidate index of last_good; -1 is good.
    last_good: ?isize = null,
    pr: ?u64 = null,
    max_probes: ?usize = null,
    exact_probes: ?usize = null,
    /// Candidate indexes, for an inconclusive verdict.
    candidates: ?[]const usize = null,
    /// A candidate probed twice that ended INFRA (and is in `infra`).
    infra_at: ?usize = null,
    /// A candidate whose first attempt was infra and whose second was not.
    retried_at: ?usize = null,
    failure_target: ?[]const u8 = null,
    no_buck2: bool = false,
    /// What stderr must say (a usage error's message).
    stderr_says: ?[]const u8 = null,
    /// bisect's stdout is a file opened read-only, so writing the verdict
    /// fails: a tool error, exit 5, never the flake code 1.
    tool_error: bool = false,
    /// The verdict of `bisect flake`.
    flake_verdict: ?[]const u8 = null,
    /// The measurement, per target: `flake_runs` of a bisect verdict,
    /// `measurement` of a `bisect flake` one.
    flake: ?[]const FlakeTarget = null,
};

fn culpritAt(comptime n: usize, comptime k: usize) [n][]const u8 {
    var s: [n][]const u8 = undefined;
    for (0..n) |i| s[i] = if (i < k) "pass" else "fail //t:a";
    return s;
}

const middle = culpritAt(9, 5);
const first = culpritAt(5, 0);
const last = culpritAt(5, 4);
const two = [_][]const u8{ "pass", "pass", "pass", "fail //t:a", "fail //t:a", "fail //t:a", "fail //t:a //t:b", "fail //t:a //t:b" };
// bad passes the recheck (no rerun flag: n is 0) and fails one run in
// every 5 consecutive n, so 1 in its 5 measured runs whatever the base.
const flake = [_][]const u8{ "pass", "pass", "pass", "flaky 5 3 //t:a" };
const flaky_a = [_][]const u8{ "pass", "flaky 5 3 //t:a" };
const steady = [_][]const u8{ "pass", "pass" };
// Run 4 is INFRA once (retried, counted); run 8, a failing one, stays
// INFRA (not counted, as a failure or as a run).
const flaky_infra = [_][]const u8{ "pass", "infra-run 4\ninfra-run-always 8\nflaky 5 3 //t:a" };
const retried = [_][]const u8{ "pass", "pass", "pass", "infra-once\npass", "pass", "fail //t:a", "fail //t:a", "fail //t:a", "fail //t:a" };
const boundary = [_][]const u8{ "pass", "pass", "pass", "pass", "pass", "infra-always\nfail //t:a", "fail //t:a", "fail //t:a", "fail //t:a" };
const single = [_][]const u8{"fail //t:a"};
// check.bxl refuses //t:a at bad: its rule runs no test action under the flag.
const no_rerun_a = [_][]const u8{ "pass", "no-rerun //t:a\npass" };
const check_infra = [_][]const u8{ "pass", "check-infra\npass" };

fn spec(name: []const u8) ?Spec {
    const table = .{
        .{ "culprit_middle", Spec{ .states = &middle, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 5, .last_good = 4, .pr = 105, .max_probes = 1 + 4, .failure_target = "//t:a" } } },
        .{ "culprit_first", Spec{ .states = &first, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 0, .last_good = -1, .pr = 100 } } },
        .{ "culprit_last", Spec{ .states = &last, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 4, .last_good = 3, .pr = 104 } } },
        .{ "two_culprits", Spec{ .states = &two, .targets = &.{ "root//t:a", "root//t:b" }, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 3, .last_good = 2, .pr = 103, .failure_target = "//t:a" } } },
        .{ "flake", Spec{ .states = &flake, .expect = .{ .exit = 1, .verdict = "flake", .exact_probes = 1, .flake = &.{.{ .target = "root//t:a", .runs = 5, .failures = 1, .attempts = 5, .excerpts = 1 }} } } },
        .{ "infra_retried", Spec{ .states = &retried, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 5, .last_good = 4, .pr = 105, .retried_at = 3 } } },
        .{ "infra_boundary", Spec{ .states = &boundary, .expect = .{ .exit = 3, .verdict = "inconclusive", .last_good = 4, .candidates = &.{ 5, 6 }, .infra_at = 5 } } },
        .{ "good_not_ancestor", Spec{ .states = &middle, .good = .stray, .expect = .{ .exit = 2, .no_buck2 = true, .stderr_says = "not an ancestor" } } },
        .{ "single_commit", Spec{ .states = &single, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 0, .last_good = -1, .pr = 100, .exact_probes = 1 } } },
        .{ "stdout_unwritable", Spec{ .states = &last, .expect = .{ .exit = 5, .tool_error = true } } },
        .{ "flake_rate", Spec{ .states = &flaky_a, .mode = .flake, .runs = 15, .rerun_base = 0, .targets = &.{ "root//t:a", "root//t:b" }, .expect = .{ .exit = 1, .flake_verdict = "flake", .flake = &.{
            .{ .target = "root//t:a", .runs = 15, .failures = 3, .attempts = 15, .failing_runs = &.{ 3, 8, 13 }, .excerpts = 1, .first_excerpt_runs = &.{ 3, 8, 13 } },
            .{ .target = "root//t:b", .runs = 15, .failures = 0, .attempts = 15, .failing_runs = &.{} },
        } } } },
        .{ "flake_never", Spec{ .states = &steady, .mode = .flake, .runs = 5, .expect = .{ .exit = 0, .flake_verdict = "never_failed", .flake = &.{.{ .target = "root//t:a", .runs = 5, .failures = 0, .attempts = 5, .failing_runs = &.{} }} } } },
        .{ "flake_infra", Spec{ .states = &flaky_infra, .mode = .flake, .runs = 10, .rerun_base = 0, .expect = .{ .exit = 1, .flake_verdict = "flake", .flake = &.{.{ .target = "root//t:a", .runs = 9, .failures = 1, .attempts = 12, .failing_runs = &.{3}, .infra_runs = &.{8}, .excerpts = 1 }} } } },
        .{ "flake_fresh_base", Spec{ .states = &flaky_a, .mode = .flake, .runs = 5, .invocations = 2, .expect = .{ .exit = 1, .flake_verdict = "flake", .flake = &.{.{ .target = "root//t:a", .runs = 5, .failures = 1, .attempts = 5, .excerpts = 1 }} } } },
        // A target without a cell: a usage error before buck2 runs, never a
        // measured 100% flake (the rules refuse a rerun value without one).
        .{ "flake_no_cell", Spec{ .states = &flaky_a, .mode = .flake, .runs = 5, .targets = &.{ "root//t:b", "//t:a" }, .expect = .{ .exit = 2, .no_buck2 = true, .stderr_says = "target //t:a has no cell" } } },
        // check.bxl refuses //t:a: never built, verdict not_measurable (not
        // never_failed) although //t:b never failed; exit 6.
        .{ "flake_not_measurable", Spec{ .states = &no_rerun_a, .mode = .flake, .runs = 3, .rerun_base = 0, .targets = &.{ "root//t:a", "root//t:b" }, .expect = .{ .exit = 6, .flake_verdict = "not_measurable", .flake = &.{
            .{ .target = "root//t:a", .runs = 0, .failures = 0, .attempts = 0, .failing_runs = &.{}, .check = "not_measurable" },
            .{ .target = "root//t:b", .runs = 3, .failures = 0, .attempts = 3, .failing_runs = &.{} },
        } } } },
        // check.bxl exits 2 twice: never built, infra run 0, inconclusive.
        .{ "flake_check_infra", Spec{ .states = &check_infra, .mode = .flake, .runs = 3, .rerun_base = 0, .expect = .{ .exit = 3, .flake_verdict = "inconclusive", .flake = &.{
            .{ .target = "root//t:a", .runs = 0, .failures = 0, .attempts = 0, .failing_runs = &.{}, .infra_runs = &.{0}, .check = "infra", .checks = 2 },
        } } } },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, row[0], name)) return row[1];
    }
    return null;
}

var failed_check = false;

fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (!ok) {
        std.io.getStdErr().writer().print("CHECK FAILED: " ++ fmt ++ "\n", args) catch {};
        failed_check = true;
    }
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("scenario: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(1);
}

const Ctx = struct {
    a: std.mem.Allocator,
    git: []const u8,
    repo: []const u8,
    env: *std.process.EnvMap,

    fn run(self: Ctx, cwd: []const u8, argv: []const []const u8) !std.ChildProcess.RunResult {
        return std.ChildProcess.run(.{ .allocator = self.a, .argv = argv, .cwd = cwd, .env_map = self.env, .max_output_bytes = 1 << 26 });
    }

    /// `git <args>` in the repository; its stdout, or the scenario dies.
    fn git_(self: Ctx, args: []const []const u8) []const u8 {
        var argv = std.ArrayList([]const u8).init(self.a);
        argv.append(self.git) catch die("out of memory", .{});
        argv.appendSlice(args) catch die("out of memory", .{});
        const r = self.run(self.repo, argv.items) catch |e| die("cannot run git: {s}", .{@errorName(e)});
        if (r.term != .Exited or r.term.Exited != 0) die("git {s} failed: {s}", .{ args[0], r.stderr });
        return std.mem.trim(u8, r.stdout, " \r\n");
    }

    fn write(self: Ctx, rel: []const u8, bytes: []const u8) void {
        var d = std.fs.openDirAbsolute(self.repo, .{}) catch |e| die("open repo: {s}", .{@errorName(e)});
        defer d.close();
        d.writeFile(rel, bytes) catch |e| die("write {s}: {s}", .{ rel, @errorName(e) });
    }
};

const Snapshot = struct { refs: []const u8, head: []const u8, status: []const u8 };

fn snapshot(c: Ctx) Snapshot {
    return .{
        .refs = c.git_(&.{ "for-each-ref", "--format=%(refname) %(objectname)" }),
        .head = c.git_(&.{ "rev-parse", "HEAD" }),
        .status = c.git_(&.{ "status", "--porcelain", "--ignored" }),
    };
}

/// Runs argv in `cwd` with its stdout a file opened read-only (this
/// process's fd 1, which the child inherits), so every write to it fails;
/// the file's bytes afterwards are the result's stdout.
fn runUnwritable(a: std.mem.Allocator, cwd: []const u8, env: *const std.process.EnvMap, argv: []const []const u8) !std.ChildProcess.RunResult {
    const path = try std.fs.path.join(a, &.{ cwd, "bisect_stdout" });
    (try std.fs.createFileAbsolute(path, .{})).close();
    const ro = try std.fs.openFileAbsolute(path, .{});
    try std.posix.dup2(ro.handle, std.posix.STDOUT_FILENO);
    ro.close();
    var child = std.ChildProcess.init(argv, a);
    child.cwd = cwd;
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const err = try child.stderr.?.reader().readAllAlloc(a, 1 << 26);
    const term = try child.wait();
    const out = try std.fs.cwd().readFileAlloc(a, path, 1 << 26);
    return .{ .term = term, .stdout = out, .stderr = err };
}

fn jget(v: std.json.Value, k: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(k);
}

fn jstr(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

/// A build line of fake_buck2's log that carried a rerun flag.
const RerunBuild = struct { label: []const u8, n: u64, value: []const u8, targets: []const u8 };

fn rerunBuilds(a: std.mem.Allocator, log: []const u8) ![]const RerunBuild {
    var out = std.ArrayList(RerunBuild).init(a);
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = w.next() orelse continue;
        _ = w.next() orelse continue;
        _ = w.next() orelse continue;
        const rerun = w.next() orelse continue;
        const targets = w.next() orelse "-";
        if (!std.mem.eql(u8, verb, "build") or std.mem.eql(u8, rerun, "-")) continue;
        const hash = std.mem.lastIndexOfScalar(u8, rerun, '#') orelse {
            check(false, "a rerun value without #: {s}", .{rerun});
            continue;
        };
        const n = std.fmt.parseInt(u64, rerun[hash + 1 ..], 10) catch {
            check(false, "a rerun value whose n is not a number: {s}", .{rerun});
            continue;
        };
        try out.append(.{ .label = rerun[0..hash], .n = n, .value = rerun, .targets = targets });
    }
    return out.items;
}

fn hasRerun(log: []const u8) bool {
    const got = rerunBuilds(std.heap.page_allocator, log) catch return true;
    return got.len > 0;
}

fn jint(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return if (x == .integer) x.integer else null;
}

fn jarr(v: ?std.json.Value) []const std.json.Value {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

fn intsEqual(got: []const std.json.Value, want: []const i64) bool {
    if (got.len != want.len) return false;
    for (got, want) |g, w| {
        if (g != .integer or g.integer != w) return false;
    }
    return true;
}

/// One invocation's measurement against `want`, and the rerun builds of its
/// log segment: each names one target, the one its flag names; each target
/// saw exactly K distinct n, base+1..base+K, in as many builds as its
/// attempts.
fn checkFlake(a: std.mem.Allocator, s: Spec, want: []const FlakeTarget, stdout: []const u8, seg: []const u8, inv: usize) !void {
    const parsed = std.json.parseFromSlice(std.json.Value, a, stdout, .{}) catch {
        check(false, "invocation {d}: stdout is not JSON", .{inv});
        return;
    };
    const v = parsed.value;
    const k: i64 = if (s.mode == .flake) s.runs else (s.flake_runs orelse 5);
    var m: std.json.Value = .null;
    if (s.mode == .flake) {
        check(std.mem.eql(u8, jstr(jget(v, "mode")) orelse "", "flake"), "invocation {d}: mode is not flake", .{inv});
        if (s.expect.flake_verdict) |fv| check(std.mem.eql(u8, jstr(jget(v, "verdict")) orelse "", fv), "invocation {d}: verdict {?s}, expected {s}", .{ inv, jstr(jget(v, "verdict")), fv });
        m = jget(v, "measurement") orelse .null;
    } else m = jget(v, "flake_runs") orelse .null;
    check(m == .object, "invocation {d}: no measurement in the verdict", .{inv});
    if (m != .object) return;
    check(jint(jget(m, "runs_requested")) == k, "invocation {d}: runs_requested {?d}, expected {d}", .{ inv, jint(jget(m, "runs_requested")), k });
    const base = jint(jget(m, "rerun_base")) orelse {
        check(false, "invocation {d}: no rerun_base", .{inv});
        return;
    };
    if (s.rerun_base) |b| check(base == @as(i64, @intCast(b)), "invocation {d}: rerun_base {d}, expected {d}", .{ inv, base, b });
    const ts = jarr(jget(m, "targets"));
    check(ts.len == want.len, "invocation {d}: {d} measured targets, expected {d}", .{ inv, ts.len, want.len });
    const builds = try rerunBuilds(a, seg);
    for (builds) |b| check(std.mem.eql(u8, b.targets, b.label), "a rerun build of {s} carries the flag of {s}: one target a build, the flag naming it", .{ b.targets, b.label });
    for (want, 0..) |wt, j| {
        if (j >= ts.len) break;
        const o = ts[j];
        check(std.mem.eql(u8, jstr(jget(o, "target")) orelse "", wt.target), "target {d} is {?s}, expected {s}", .{ j, jstr(jget(o, "target")), wt.target });
        check(jint(jget(o, "runs")) == wt.runs, "{s}: runs {?d}, expected {d}", .{ wt.target, jint(jget(o, "runs")), wt.runs });
        check(jint(jget(o, "failures")) == wt.failures, "{s}: failures {?d}, expected {d}", .{ wt.target, jint(jget(o, "failures")), wt.failures });
        check(jint(jget(o, "attempts")) == wt.attempts, "{s}: attempts {?d}, expected {d}", .{ wt.target, jint(jget(o, "attempts")), wt.attempts });
        const fr = jget(o, "failure_rate") orelse .null;
        const want_rate: f64 = if (wt.runs == 0) 0 else @as(f64, @floatFromInt(wt.failures)) / @as(f64, @floatFromInt(wt.runs));
        const got_rate: f64 = switch (fr) {
            .float => |f| f,
            .integer => |x| @floatFromInt(x),
            else => -1,
        };
        check(@abs(got_rate - want_rate) < 1e-9, "{s}: failure_rate {d}, expected {d}", .{ wt.target, got_rate, want_rate });
        const failing = jarr(jget(o, "failing_runs"));
        check(failing.len == @as(usize, @intCast(wt.failures)), "{s}: {d} failing runs listed, {d} failures", .{ wt.target, failing.len, wt.failures });
        if (wt.failing_runs) |fr_want| check(intsEqual(failing, fr_want), "{s}: failing_runs differ", .{wt.target});
        const infra = jarr(jget(o, "infra"));
        check(infra.len == wt.infra_runs.len, "{s}: {d} infra runs, expected {d}", .{ wt.target, infra.len, wt.infra_runs.len });
        for (infra, 0..) |x, q| {
            if (q < wt.infra_runs.len) check(jint(jget(x, "run")) == wt.infra_runs[q], "{s}: infra run {d} differs", .{ wt.target, q });
            check(std.mem.indexOf(u8, jstr(jget(x, "excerpt")) orelse "", "planted infrastructure failure") != null, "{s}: the infra excerpt lacks buck2's stderr", .{wt.target});
        }
        const ex = jarr(jget(o, "excerpts"));
        check(ex.len == wt.excerpts, "{s}: {d} excerpt groups, expected {d}", .{ wt.target, ex.len, wt.excerpts });
        if (ex.len > 0) {
            const line = try std.fmt.allocPrint(a, "2/2 test.planted flake of {s}...FAIL (PlantedFlake)", .{wt.target});
            check(std.mem.eql(u8, jstr(jget(ex[0], "first_failing_line")) orelse "", line), "{s}: first_failing_line {?s}", .{ wt.target, jstr(jget(ex[0], "first_failing_line")) });
            check(std.mem.indexOf(u8, jstr(jget(ex[0], "excerpt")) orelse "", line) != null, "{s}: the excerpt is not the failing run's stderr", .{wt.target});
            if (wt.first_excerpt_runs) |er| check(intsEqual(jarr(jget(ex[0], "runs")), er), "{s}: the first group's runs differ", .{wt.target});
        }
        // What fake_buck2 saw for this target.
        var count: i64 = 0;
        var seen = std.AutoHashMap(u64, void).init(a);
        for (builds) |b| {
            if (!std.mem.eql(u8, b.label, wt.target)) continue;
            count += 1;
            try seen.put(b.n, {});
            check(@as(i64, @intCast(b.n)) > base and @as(i64, @intCast(b.n)) <= base + k, "{s}: run n {d} outside base+1..base+K ({d}..{d})", .{ wt.target, b.n, base + 1, base + k });
        }
        check(count == wt.attempts, "{s}: fake_buck2 saw {d} rerun builds, expected {d}", .{ wt.target, count, wt.attempts });
        const want_distinct: u32 = if (wt.attempts > 0) @intCast(k) else 0;
        check(seen.count() == want_distinct, "{s}: fake_buck2 saw {d} distinct n, expected {d}: runs sharing an n would replay the cache", .{ wt.target, seen.count(), want_distinct });
        check(std.mem.eql(u8, jstr(jget(o, "check")) orelse "", wt.check), "{s}: check {?s}, expected {s}", .{ wt.target, jstr(jget(o, "check")), wt.check });
        const ce = jget(o, "check_excerpt") orelse .null;
        if (std.mem.eql(u8, wt.check, "measurable")) {
            check(ce == .null, "{s}: a check_excerpt for a measurable target", .{wt.target});
        } else check(ce == .string and ce.string.len > 0, "{s}: no check_excerpt", .{wt.target});
        // check.bxl ran for the target before its runs, with run 1's value.
        const first_value = try std.fmt.allocPrint(a, "{s}#{d}", .{ wt.target, base + 1 });
        var checks: i64 = 0;
        var before_runs = true;
        var segl = std.mem.tokenizeScalar(u8, seg, '\n');
        while (segl.next()) |ln| {
            var w = std.mem.tokenizeScalar(u8, ln, ' ');
            const verb = w.next() orelse continue;
            _ = w.next();
            _ = w.next();
            const rv = w.next() orelse "-";
            if (std.mem.eql(u8, verb, "bxl") and std.mem.eql(u8, rv, first_value)) {
                checks += 1;
            } else if (std.mem.eql(u8, verb, "build") and std.mem.startsWith(u8, rv, wt.target) and rv.len > wt.target.len and rv[wt.target.len] == '#' and checks == 0) before_runs = false;
        }
        check(checks == wt.checks, "{s}: fake_buck2 saw {d} check.bxl runs with {s}, expected {d}", .{ wt.target, checks, first_value, wt.checks });
        check(before_runs, "{s}: a run was built before its check", .{wt.target});
    }
}

/// No rerun value of one invocation recurs in another: a second measurement
/// must not replay the first's cache entries.
fn checkDisjoint(a: std.mem.Allocator, log: []const u8, marks: []const usize) void {
    const one = rerunBuilds(a, log[marks[0]..marks[1]]) catch return;
    const second = rerunBuilds(a, log[marks[1]..]) catch return;
    check(one.len > 0 and second.len > 0, "an invocation ran no rerun build", .{});
    for (one) |x| {
        for (second) |y| check(!std.mem.eql(u8, x.value, y.value), "{s} ran in two invocations: the second replays the first's cache", .{x.value});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var name: []const u8 = "";
    var bisect: []const u8 = "";
    var fake: []const u8 = "";
    var git_dist: []const u8 = "";
    var out: []const u8 = "";
    var i: usize = 1;
    while (i + 1 < argv.len) : (i += 2) {
        const k = argv[i];
        const v = argv[i + 1];
        if (std.mem.eql(u8, k, "--scenario")) name = v else if (std.mem.eql(u8, k, "--bisect")) bisect = v else if (std.mem.eql(u8, k, "--fake-buck2")) fake = v else if (std.mem.eql(u8, k, "--git-dist")) git_dist = v else if (std.mem.eql(u8, k, "--out")) out = v else die("unknown argument {s}", .{k});
    }
    if (i != argv.len or name.len == 0 or bisect.len == 0 or fake.len == 0 or git_dist.len == 0 or out.len == 0)
        die("usage: scenario --scenario <name> --bisect <exe> --fake-buck2 <exe> --git-dist <dir> --out <file>", .{});
    const s = spec(name) orelse die("no scenario {s}", .{name});

    // A directory of its own: buck2's per-action scratch directory when it
    // names one, else under the working directory.
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const scratch_base = if (std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH")) |p|
        (if (std.fs.path.isAbsolute(p)) p else try std.fs.path.join(a, &.{ cwd, p }))
    else |_|
        cwd;
    const root = try std.fs.path.join(a, &.{ scratch_base, try std.fmt.allocPrint(a, "bisect_{s}", .{name}) });
    std.fs.deleteTreeAbsolute(root) catch {};
    const home = try std.fs.path.join(a, &.{ root, "home" });
    const repo = try std.fs.path.join(a, &.{ root, "repo" });
    const work = try std.fs.path.join(a, &.{ root, "work" });
    try std.fs.cwd().makePath(home);
    try std.fs.cwd().makePath(repo);

    const git = try std.fs.path.join(a, &.{ try std.fs.cwd().realpathAlloc(a, git_dist), "bin", "git" });
    const bisect_abs = try std.fs.cwd().realpathAlloc(a, bisect);
    const fake_abs = try std.fs.cwd().realpathAlloc(a, fake);

    var env = try std.process.getEnvMap(a);
    for ([_][2][]const u8{
        .{ "HOME", home },                         .{ "LC_ALL", "C" },
        .{ "GIT_CONFIG_NOSYSTEM", "1" },           .{ "GIT_TERMINAL_PROMPT", "0" },
        .{ "GIT_AUTHOR_NAME", "Bisect Scenario" }, .{ "GIT_AUTHOR_EMAIL", "scenario@example.com" },
        .{ "GIT_COMMITTER_NAME", "Bisect Scenario" }, .{ "GIT_COMMITTER_EMAIL", "scenario@example.com" },
    }) |kv| try env.put(kv[0], kv[1]);

    const c = Ctx{ .a = a, .git = git, .repo = repo, .env = &env };
    _ = c.git_(&.{ "init", "-q", "-b", "main", "." });
    c.write("bisect_fixture.txt", "pass\n");
    _ = c.git_(&.{ "add", "." });
    _ = c.git_(&.{ "commit", "-q", "-m", "base" });
    const base = c.git_(&.{ "rev-parse", "HEAD" });

    const n = s.states.len;
    const merges = try a.alloc([]const u8, n);
    const sides = try a.alloc([]const u8, n);
    for (s.states, 0..) |state, k| {
        const branch = try std.fmt.allocPrint(a, "side{d}", .{k});
        _ = c.git_(&.{ "checkout", "-q", "-b", branch });
        c.write("bisect_fixture.txt", try std.fmt.allocPrint(a, "{s}\n", .{state}));
        c.write(try std.fmt.allocPrint(a, "change_{d}.txt", .{k}), "x\n");
        _ = c.git_(&.{ "add", "." });
        _ = c.git_(&.{ "commit", "-q", "-m", try std.fmt.allocPrint(a, "change {d}", .{k}) });
        sides[k] = c.git_(&.{ "rev-parse", "HEAD" });
        _ = c.git_(&.{ "checkout", "-q", "main" });
        _ = c.git_(&.{ "merge", "--no-ff", "-q", "-m", try std.fmt.allocPrint(a, "Merge pull request #{d} from example/side{d}", .{ 100 + k, k }), branch });
        merges[k] = c.git_(&.{ "rev-parse", "HEAD" });
    }
    var good = base;
    if (s.good == .stray) {
        _ = c.git_(&.{ "checkout", "-q", "-b", "stray", base });
        c.write("stray.txt", "x\n");
        _ = c.git_(&.{ "add", "." });
        _ = c.git_(&.{ "commit", "-q", "-m", "stray" });
        good = c.git_(&.{ "rev-parse", "HEAD" });
        _ = c.git_(&.{ "checkout", "-q", "main" });
    }
    const bad = merges[n - 1];
    const before = snapshot(c);

    // The run (`invocations` of them for `bisect flake`, each with a work
    // dir of its own; the checks below read the last, and the log segment
    // and verdict of each).
    const log_path = try std.fs.path.join(a, &.{ repo, ".git", "fake_buck2.log" });
    const stderr = std.io.getStdErr().writer();
    var marks = std.ArrayList(usize).init(a);
    var outs = std.ArrayList([]const u8).init(a);
    var r: std.ChildProcess.RunResult = undefined;
    var inv: u32 = 0;
    while (inv < s.invocations) : (inv += 1) {
        const wd = if (inv == 0) work else try std.fmt.allocPrint(a, "{s}{d}", .{ work, inv });
        var cmd = std.ArrayList([]const u8).init(a);
        try cmd.append(bisect_abs);
        switch (s.mode) {
            .bisect => try cmd.appendSlice(&.{ "--good", good, "--bad", bad }),
            .flake => try cmd.appendSlice(&.{ "flake", "--rev", bad, "--runs", try std.fmt.allocPrint(a, "{d}", .{s.runs}) }),
        }
        try cmd.appendSlice(&.{ "--work-dir", wd, "--repo", repo, "--buck2", fake_abs, "--git", git, "--timeout-s", "120" });
        if (s.flake_runs) |k| try cmd.appendSlice(&.{ "--flake-runs", try std.fmt.allocPrint(a, "{d}", .{k}) });
        if (s.rerun_base) |b| try cmd.appendSlice(&.{ "--rerun-base", try std.fmt.allocPrint(a, "{d}", .{b}) });
        try cmd.append("--");
        try cmd.appendSlice(s.targets);
        try marks.append((std.fs.cwd().readFileAlloc(a, log_path, 1 << 24) catch "").len);
        r = if (s.expect.tool_error) try runUnwritable(a, root, &env, cmd.items) else try c.run(root, cmd.items);
        try stderr.print("---- bisect stdout\n{s}---- bisect stderr\n{s}----\n", .{ r.stdout, r.stderr });
        try outs.append(r.stdout);
        const code_i: ?u8 = if (r.term == .Exited) r.term.Exited else null;
        check(code_i != null and code_i.? == s.expect.exit, "invocation {d}: exit {?d}, expected {d}", .{ inv, code_i, s.expect.exit });
    }
    const code: ?u8 = if (r.term == .Exited) r.term.Exited else null;
    const e = s.expect;

    // Nothing outside the probe worktrees changed.
    const after = snapshot(c);
    check(std.mem.eql(u8, before.refs, after.refs), "refs changed:\n{s}\n----\n{s}", .{ before.refs, after.refs });
    check(std.mem.eql(u8, before.head, after.head), "HEAD changed", .{});
    check(std.mem.eql(u8, before.status, after.status), "status changed:\n{s}\n----\n{s}", .{ before.status, after.status });
    const wl = c.git_(&.{ "worktree", "list", "--porcelain" });
    check(std.mem.count(u8, wl, "worktree ") == 1, "worktrees left:\n{s}", .{wl});
    for (0..s.invocations) |k| {
        const wd = if (k == 0) work else try std.fmt.allocPrint(a, "{s}{d}", .{ work, k });
        if (std.fs.openDirAbsolute(wd, .{ .iterate = true })) |d_| {
            var d = d_;
            defer d.close();
            var it = d.iterate();
            while (try it.next()) |ent| check(!std.mem.startsWith(u8, ent.name, "probe-"), "{s} left in the work dir", .{ent.name});
        } else |_| {}
    }

    // What fake_buck2 saw.
    const log = std.fs.cwd().readFileAlloc(a, log_path, 1 << 24) catch "";
    var builds: usize = 0;
    // check.bxl runs; each also has a kill after it.
    var bxls: usize = 0;
    // Builds without a rerun flag: the probes' attempts.
    var plain_builds: usize = 0;
    var kills: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    var build_cwds = std.ArrayList([]const u8).init(a);
    var kill_cwds = std.ArrayList([]const u8).init(a);
    while (lines.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = w.next() orelse continue;
        const commit = w.next() orelse continue;
        const where = w.next() orelse continue;
        const rerun = w.next() orelse "-";
        if (std.mem.eql(u8, verb, "build")) {
            builds += 1;
            if (std.mem.eql(u8, rerun, "-")) plain_builds += 1;
            try build_cwds.append(where);
            var merge = false;
            for (merges) |m| {
                if (std.mem.eql(u8, m, commit)) merge = true;
            }
            check(merge, "probed {s}, which is not a first-parent commit", .{commit});
            for (sides) |sd| check(!std.mem.eql(u8, sd, commit), "probed the side-branch commit {s}", .{commit});
        } else if (std.mem.eql(u8, verb, "bxl")) {
            bxls += 1;
            try build_cwds.append(where);
        } else if (std.mem.eql(u8, verb, "kill")) {
            kills += 1;
            try kill_cwds.append(where);
        }
    }
    check(builds + bxls == kills, "{d} builds and {d} check.bxl runs but {d} kills", .{ builds, bxls, kills });
    for (build_cwds.items, 0..) |b, k| check(k < kill_cwds.items.len and std.mem.eql(u8, b, kill_cwds.items[k]), "build or check {d} in {s} has no kill in the same worktree", .{ k, b });
    if (e.flake == null) check(bxls == 0, "check.bxl ran in a scenario with no measurement", .{});
    if (e.no_buck2) check(log.len == 0, "buck2 ran in a usage error:\n{s}", .{log});
    if (e.stderr_says) |want| check(std.mem.indexOf(u8, r.stderr, want) != null, "stderr does not say \"{s}\"", .{want});
    if (e.tool_error) {
        check(code == null or code.? != 1, "a tool error exited 1, the flake code", .{});
        check(std.mem.indexOf(u8, r.stderr, "bisect: tool error: NotOpenForWriting") != null, "stderr does not name the tool error", .{});
        check(builds >= 1, "the search never ran: the tool error was not in writing the verdict", .{});
        if (std.json.parseFromSlice(std.json.Value, a, r.stdout, .{})) |parsed| {
            check(!std.mem.eql(u8, jstr(jget(parsed.value, "verdict")) orelse "", "flake"), "stdout is a flake verdict", .{});
        } else |_| {}
    }

    // The verdict.
    if (e.verdict) |want| {
        const parsed = std.json.parseFromSlice(std.json.Value, a, r.stdout, .{}) catch die("stdout is not JSON", .{});
        const v = parsed.value;
        check(std.mem.eql(u8, jstr(jget(v, "verdict")) orelse "", want), "verdict {?s}, expected {s}", .{ jstr(jget(v, "verdict")), want });
        check(std.mem.eql(u8, jstr(jget(v, "good")) orelse "", good), "good is not the good commit", .{});
        check(std.mem.eql(u8, jstr(jget(v, "bad")) orelse "", bad), "bad is not the bad commit", .{});
        const fb = jget(v, "first_bad");
        if (e.first_bad) |k| {
            check(std.mem.eql(u8, jstr(jget(fb orelse .null, "commit")) orelse "", merges[k]), "first_bad is {?s}, expected c{d} {s}", .{ jstr(jget(fb orelse .null, "commit")), k, merges[k] });
            const subject = try std.fmt.allocPrint(a, "Merge pull request #{d} from example/side{d}", .{ 100 + k, k });
            check(std.mem.eql(u8, jstr(jget(fb orelse .null, "subject")) orelse "", subject), "first_bad subject", .{});
        } else check(fb != null and fb.? == .null, "first_bad is not null", .{});
        if (e.pr) |pr| {
            const got = jget(fb orelse .null, "pr");
            check(got != null and got.? == .integer and got.?.integer == @as(i64, @intCast(pr)), "pr, expected {d}", .{pr});
        }
        if (e.last_good) |k| {
            const want_lg = if (k < 0) good else merges[@intCast(k)];
            check(std.mem.eql(u8, jstr(jget(v, "last_good")) orelse "", want_lg), "last_good {?s}, expected {s}", .{ jstr(jget(v, "last_good")), want_lg });
        }
        const cands = jget(v, "candidates");
        if (e.candidates) |want_c| {
            const items = if (cands != null and cands.? == .array) cands.?.array.items else &[_]std.json.Value{};
            check(items.len == want_c.len, "{d} candidates, expected {d}", .{ items.len, want_c.len });
            for (want_c, 0..) |k, j| {
                if (j < items.len) check(std.mem.eql(u8, jstr(items[j]) orelse "", merges[k]), "candidate {d} is not c{d}", .{ j, k });
            }
        } else check(cands == null, "candidates present for a verdict that is not inconclusive", .{});

        const probes = if (jget(v, "probes")) |p| (if (p == .array) p.array.items else &[_]std.json.Value{}) else &[_]std.json.Value{};
        check(probes.len > 0 and std.mem.eql(u8, jstr(jget(probes[0], "role")) orelse "", "recheck"), "the first probe is not the recheck of bad", .{});
        if (probes.len > 0) check(std.mem.eql(u8, jstr(jget(probes[0], "commit")) orelse "", bad), "the recheck is not of bad", .{});
        if (e.max_probes) |m| check(probes.len <= m, "{d} probes, at most {d} expected", .{ probes.len, m });
        if (e.exact_probes) |m| check(probes.len == m, "{d} probes, expected {d}", .{ probes.len, m });
        // A commit is probed once (its retry is an attempt, not a probe).
        for (probes, 0..) |p, j| {
            for (probes[j + 1 ..]) |q| {
                check(!std.mem.eql(u8, jstr(jget(p, "commit")) orelse "", jstr(jget(q, "commit")) orelse "-"), "{?s} probed twice", .{jstr(jget(p, "commit"))});
            }
        }
        var attempts_total: i64 = 0;
        for (probes) |p| {
            const at = jget(p, "attempts") orelse .null;
            if (at == .integer) attempts_total += at.integer;
            const commit = jstr(jget(p, "commit")) orelse "";
            const outcome = jstr(jget(p, "outcome")) orelse "";
            if (e.retried_at) |k| {
                if (std.mem.eql(u8, commit, merges[k])) {
                    check(at == .integer and at.integer == 2, "the infra-once probe of c{d} has attempts {any}, expected 2", .{ k, at });
                    check(std.mem.eql(u8, outcome, "PASS"), "the infra-once probe of c{d} is {s}, expected PASS", .{ k, outcome });
                }
            }
            if (e.infra_at) |k| {
                if (std.mem.eql(u8, commit, merges[k])) {
                    check(at == .integer and at.integer == 2, "the infra-always probe of c{d} has attempts {any}, expected 2", .{ k, at });
                    check(std.mem.eql(u8, outcome, "INFRA"), "the infra-always probe of c{d} is {s}, expected INFRA", .{ k, outcome });
                }
            }
        }
        check(attempts_total == @as(i64, @intCast(plain_builds)), "the probes count {d} attempts, fake_buck2 saw {d} builds without a rerun flag", .{ attempts_total, plain_builds });
        if (e.infra_at) |k| {
            const infra = if (jget(v, "infra")) |x| (if (x == .array) x.array.items else &[_]std.json.Value{}) else &[_]std.json.Value{};
            check(infra.len == 1 and std.mem.eql(u8, jstr(jget(infra[0], "commit")) orelse "", merges[k]), "infra does not list c{d} alone", .{k});
            if (infra.len == 1) check(std.mem.indexOf(u8, jstr(jget(infra[0], "excerpt")) orelse "", "planted infrastructure failure") != null, "the infra excerpt lacks buck2's stderr", .{});
        }
        if (e.retried_at == null and e.infra_at == null) {
            for (probes) |p| {
                const at = jget(p, "attempts") orelse .null;
                check(at == .integer and at.integer == 1, "a probe was retried in a scenario with no infra", .{});
            }
        }
        if (e.failure_target) |ft| {
            const fs = if (jget(v, "failures")) |x| (if (x == .array) x.array.items else &[_]std.json.Value{}) else &[_]std.json.Value{};
            check(fs.len >= 1 and std.mem.eql(u8, jstr(jget(fs[0], "target")) orelse "", ft), "failures[0] is not {s}", .{ft});
            if (fs.len >= 1 and e.first_bad != null) {
                const want_ex = try std.fmt.allocPrint(a, "planted failure of {s} at {s}", .{ ft, merges[e.first_bad.?] });
                check(std.mem.indexOf(u8, jstr(jget(fs[0], "excerpt")) orelse "", want_ex) != null, "the excerpt is not the failing action's stderr at first_bad", .{});
            }
            if (s.targets.len > 1) check(fs.len == 1, "failures lists a target that did not fail at first_bad", .{});
        }
    }

    if (e.flake) |want| {
        for (outs.items, 0..) |o, k| {
            const seg_end = if (k + 1 < marks.items.len) marks.items[k + 1] else log.len;
            try checkFlake(a, s, want, o, log[marks.items[k]..seg_end], k);
        }
        if (s.invocations > 1) checkDisjoint(a, log, marks.items);
    } else check(!hasRerun(log), "a rerun build ran in a scenario with no measurement", .{});

    if (failed_check) std.process.exit(1);
    std.fs.deleteTreeAbsolute(root) catch {};
    try std.fs.cwd().writeFile(out, "passed\n");
}
