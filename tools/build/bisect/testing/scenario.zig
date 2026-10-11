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

const Spec = struct {
    /// Fixture of each candidate, oldest first; the last is bad.
    states: []const []const u8,
    targets: []const []const u8 = &.{"//t:a"},
    good: Good = .base,
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
    /// bisect's stdout is a file opened read-only, so writing the verdict
    /// fails: a tool error, exit 5, never the flake code 1.
    tool_error: bool = false,
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
const flake = [_][]const u8{ "pass", "pass", "pass", "pass" };
const retried = [_][]const u8{ "pass", "pass", "pass", "infra-once\npass", "pass", "fail //t:a", "fail //t:a", "fail //t:a", "fail //t:a" };
const boundary = [_][]const u8{ "pass", "pass", "pass", "pass", "pass", "infra-always\nfail //t:a", "fail //t:a", "fail //t:a", "fail //t:a" };
const single = [_][]const u8{"fail //t:a"};

fn spec(name: []const u8) ?Spec {
    const table = .{
        .{ "culprit_middle", Spec{ .states = &middle, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 5, .last_good = 4, .pr = 105, .max_probes = 1 + 4, .failure_target = "//t:a" } } },
        .{ "culprit_first", Spec{ .states = &first, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 0, .last_good = -1, .pr = 100 } } },
        .{ "culprit_last", Spec{ .states = &last, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 4, .last_good = 3, .pr = 104 } } },
        .{ "two_culprits", Spec{ .states = &two, .targets = &.{ "//t:a", "//t:b" }, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 3, .last_good = 2, .pr = 103, .failure_target = "//t:a" } } },
        .{ "flake", Spec{ .states = &flake, .expect = .{ .exit = 1, .verdict = "flake", .exact_probes = 1 } } },
        .{ "infra_retried", Spec{ .states = &retried, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 5, .last_good = 4, .pr = 105, .retried_at = 3 } } },
        .{ "infra_boundary", Spec{ .states = &boundary, .expect = .{ .exit = 3, .verdict = "inconclusive", .last_good = 4, .candidates = &.{ 5, 6 }, .infra_at = 5 } } },
        .{ "good_not_ancestor", Spec{ .states = &middle, .good = .stray, .expect = .{ .exit = 2, .no_buck2 = true } } },
        .{ "single_commit", Spec{ .states = &single, .expect = .{ .exit = 0, .verdict = "culprit", .first_bad = 0, .last_good = -1, .pr = 100, .exact_probes = 1 } } },
        .{ "stdout_unwritable", Spec{ .states = &last, .expect = .{ .exit = 5, .tool_error = true } } },
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

    // The run.
    var cmd = std.ArrayList([]const u8).init(a);
    try cmd.appendSlice(&.{ bisect_abs, "--good", good, "--bad", bad, "--work-dir", work, "--repo", repo, "--buck2", fake_abs, "--git", git, "--timeout-s", "120", "--" });
    try cmd.appendSlice(s.targets);
    const r = if (s.expect.tool_error) try runUnwritable(a, root, &env, cmd.items) else try c.run(root, cmd.items);
    const stderr = std.io.getStdErr().writer();
    try stderr.print("---- bisect stdout\n{s}---- bisect stderr\n{s}----\n", .{ r.stdout, r.stderr });
    const code: ?u8 = if (r.term == .Exited) r.term.Exited else null;
    const e = s.expect;
    check(code != null and code.? == e.exit, "exit {?d}, expected {d}", .{ code, e.exit });

    // Nothing outside the probe worktrees changed.
    const after = snapshot(c);
    check(std.mem.eql(u8, before.refs, after.refs), "refs changed:\n{s}\n----\n{s}", .{ before.refs, after.refs });
    check(std.mem.eql(u8, before.head, after.head), "HEAD changed", .{});
    check(std.mem.eql(u8, before.status, after.status), "status changed:\n{s}\n----\n{s}", .{ before.status, after.status });
    const wl = c.git_(&.{ "worktree", "list", "--porcelain" });
    check(std.mem.count(u8, wl, "worktree ") == 1, "worktrees left:\n{s}", .{wl});
    if (std.fs.openDirAbsolute(work, .{ .iterate = true })) |d_| {
        var d = d_;
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |ent| check(!std.mem.startsWith(u8, ent.name, "probe-"), "{s} left in the work dir", .{ent.name});
    } else |_| {}

    // What fake_buck2 saw.
    const log_path = try std.fs.path.join(a, &.{ repo, ".git", "fake_buck2.log" });
    const log = std.fs.cwd().readFileAlloc(a, log_path, 1 << 24) catch "";
    var builds: usize = 0;
    var kills: usize = 0;
    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    var build_cwds = std.ArrayList([]const u8).init(a);
    var kill_cwds = std.ArrayList([]const u8).init(a);
    while (lines.next()) |line| {
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = w.next() orelse continue;
        const commit = w.next() orelse continue;
        const where = w.next() orelse continue;
        if (std.mem.eql(u8, verb, "build")) {
            builds += 1;
            try build_cwds.append(where);
            var merge = false;
            for (merges) |m| {
                if (std.mem.eql(u8, m, commit)) merge = true;
            }
            check(merge, "probed {s}, which is not a first-parent commit", .{commit});
            for (sides) |sd| check(!std.mem.eql(u8, sd, commit), "probed the side-branch commit {s}", .{commit});
        } else if (std.mem.eql(u8, verb, "kill")) {
            kills += 1;
            try kill_cwds.append(where);
        }
    }
    check(builds == kills, "{d} builds but {d} kills", .{ builds, kills });
    for (build_cwds.items, 0..) |b, k| check(k < kill_cwds.items.len and std.mem.eql(u8, b, kill_cwds.items[k]), "build {d} in {s} has no kill in the same worktree", .{ k, b });
    if (e.no_buck2) {
        check(log.len == 0, "buck2 ran in a usage error:\n{s}", .{log});
        check(std.mem.indexOf(u8, r.stderr, "not an ancestor") != null, "the refusal does not say good is not an ancestor", .{});
    }
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
        check(attempts_total == @as(i64, @intCast(builds)), "the probes count {d} attempts, fake_buck2 saw {d} builds", .{ attempts_total, builds });
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

    if (failed_check) std.process.exit(1);
    std.fs.deleteTreeAbsolute(root) catch {};
    try std.fs.cwd().writeFile(out, "passed\n");
}
