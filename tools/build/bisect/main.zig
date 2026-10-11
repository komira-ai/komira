//! bisect: the first commit between a good and a bad one at which the given
//! Buck2 targets stop building (README.md).
//!
//! 1. Check the inputs (usage error, exit 2, before any buck2 call).
//! 2. Build the targets at bad again: if they pass, the verdict is `flake`.
//! 3. List the first-parent commits after good up to bad.
//! 4. Binary-search them (search.zig), one probe per commit (probe.zig),
//!    an infra outcome retried once and never counted as a failure.
//! 5. Print the verdict as JSON (report.zig).
const std = @import("std");
const classify = @import("classify.zig");
const search = @import("search.zig");
const report = @import("report.zig");
const prober = @import("probe.zig");
const Git = @import("git.zig").Git;

pub const EXIT_CULPRIT = 0;
pub const EXIT_FLAKE = 1;
pub const EXIT_USAGE = 2;
pub const EXIT_INCONCLUSIVE = 3;
pub const EXIT_GIT = 4;

const USAGE =
    \\usage: bisect --good <rev> --bad <rev> --work-dir <dir> [--repo <dir>]
    \\              [--verb build|test] [--buck2 <path>] [--git <path>]
    \\              [--copy <relpath>]... [--submodules] [--buck2-arg <arg>]...
    \\              [--timeout-s <n>] -- <target>...
    \\
;

pub const Args = struct {
    good: []const u8 = "",
    bad: []const u8 = "",
    work_dir: []const u8 = "",
    repo: []const u8 = ".",
    verb: classify.Verb = .build,
    buck2: []const u8 = "buck2",
    git: []const u8 = "git",
    copies: []const []const u8 = &.{},
    submodules: bool = false,
    buck2_args: []const []const u8 = &.{},
    timeout_s: u32 = 3600,
    targets: []const []const u8 = &.{},
};

pub const ArgError = error{ MissingValue, UnknownArgument, BadVerb, BadTimeout, MissingGood, MissingBad, MissingWorkDir, NoTargets, BadCopy };

pub fn parseArgs(a: std.mem.Allocator, argv: []const []const u8) !Args {
    var r = Args{};
    var copies = std.ArrayList([]const u8).init(a);
    var bargs = std.ArrayList([]const u8).init(a);
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            r.targets = argv[i + 1 ..];
            break;
        }
        if (std.mem.eql(u8, arg, "--submodules")) {
            r.submodules = true;
            continue;
        }
        const names = [_][]const u8{ "--good", "--bad", "--work-dir", "--repo", "--verb", "--buck2", "--git", "--copy", "--buck2-arg", "--timeout-s" };
        var which: ?usize = null;
        for (names, 0..) |n, k| {
            if (std.mem.eql(u8, arg, n)) which = k;
        }
        const k = which orelse return error.UnknownArgument;
        if (i + 1 >= argv.len) return error.MissingValue;
        i += 1;
        const v = argv[i];
        switch (k) {
            0 => r.good = v,
            1 => r.bad = v,
            2 => r.work_dir = v,
            3 => r.repo = v,
            4 => r.verb = std.meta.stringToEnum(classify.Verb, v) orelse return error.BadVerb,
            5 => r.buck2 = v,
            6 => r.git = v,
            7 => {
                if (v.len == 0 or std.fs.path.isAbsolute(v) or std.mem.indexOf(u8, v, "..") != null) return error.BadCopy;
                try copies.append(v);
            },
            8 => try bargs.append(v),
            9 => r.timeout_s = std.fmt.parseInt(u32, v, 10) catch return error.BadTimeout,
            else => unreachable,
        }
    }
    if (r.good.len == 0) return error.MissingGood;
    if (r.bad.len == 0) return error.MissingBad;
    if (r.work_dir.len == 0) return error.MissingWorkDir;
    if (r.targets.len == 0) return error.NoTargets;
    if (r.timeout_s == 0) return error.BadTimeout;
    r.copies = try copies.toOwnedSlice();
    r.buck2_args = try bargs.toOwnedSlice();
    return r;
}

/// The nearest directory at or above `dir` holding a `.buckconfig` or
/// `.buckroot`, which buck2 would take as (part of) a project; null when
/// there is none.
fn enclosingProject(a: std.mem.Allocator, dir: []const u8) !?[]const u8 {
    var d: ?[]const u8 = dir;
    while (d) |cur| : (d = std.fs.path.dirname(cur)) {
        for ([_][]const u8{ ".buckconfig", ".buckroot" }) |marker| {
            const p = try std.fs.path.join(a, &.{ cur, marker });
            if (std.fs.accessAbsolute(p, .{})) |_| return cur else |_| {}
        }
    }
    return null;
}

fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("bisect: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

const State = struct {
    a: std.mem.Allocator,
    cfg: prober.Config,
    probes: std.ArrayList(report.Probe),
    infra: std.ArrayList(report.Infra),
    /// The failures of each commit that failed, by commit.
    failures: std.StringHashMap([]const classify.Failure),
    candidates: []const []const u8 = &.{},
    role: report.Role = .recheck,

    /// Builds `commit`, retrying an infra outcome once.
    fn probeCommit(self: *State, commit: []const u8) !search.Outcome {
        const err = std.io.getStdErr().writer();
        var why: []const u8 = "";
        var attempts: u32 = 0;
        var at: prober.Attempt = undefined;
        while (attempts < 2) {
            attempts += 1;
            err.print("bisect: {s} {s} (attempt {d})...\n", .{ @tagName(self.role), commit, attempts }) catch {};
            at = prober.attempt(self.cfg, commit, attempts, &why) catch |e| switch (e) {
                error.Git => fail(EXIT_GIT, "{s}", .{why}),
                error.NotOwnProject => fail(EXIT_USAGE, "{s}", .{why}),
                else => fail(EXIT_GIT, "probe of {s} failed: {s}", .{ commit, @errorName(e) }),
            };
            err.print("bisect: {s} {s}: {s}\n", .{ @tagName(self.role), commit, report.outcomeName(at.classified.outcome) }) catch {};
            if (at.classified.outcome != .infra) break;
        }
        var names = std.ArrayList([]const u8).init(self.a);
        for (at.classified.failures) |f| try names.append(f.target);
        try self.probes.append(.{
            .commit = commit,
            .role = self.role,
            .outcome = at.classified.outcome,
            .attempts = attempts,
            .buck2_exit = at.exit,
            .failed_targets = try names.toOwnedSlice(),
            .seconds = at.seconds,
        });
        switch (at.classified.outcome) {
            .infra => try self.infra.append(.{ .commit = commit, .buck2_exit = at.exit, .excerpt = at.tail }),
            .fail => try self.failures.put(commit, at.classified.failures),
            .pass => {},
        }
        return at.classified.outcome;
    }

    /// search.zig's callback: candidate `i`.
    pub fn probe(self: *State, i: usize) !search.Outcome {
        return self.probeCommit(self.candidates[i]);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = parseArgs(a, argv[1..]) catch |e| {
        std.io.getStdErr().writer().print("bisect: {s}\n{s}", .{ @errorName(e), USAGE }) catch {};
        std.process.exit(EXIT_USAGE);
    };

    // The environment of git and buck2: this process's, without BUCK*
    // variables, which an outer buck2 (`buck2 run`) sets for itself.
    var env = try std.process.getEnvMap(a);
    var drop = std.ArrayList([]const u8).init(a);
    var it = env.iterator();
    while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, "BUCK")) try drop.append(try a.dupe(u8, e.key_ptr.*));
    for (drop.items) |k| env.remove(k);

    const repo = std.fs.cwd().realpathAlloc(a, args.repo) catch |e|
        fail(EXIT_USAGE, "--repo {s}: {s}", .{ args.repo, @errorName(e) });
    var git = Git{ .a = a, .git = args.git, .repo = repo, .env = &env };
    const top = git.output(&.{ "rev-parse", "--show-toplevel" }) catch fail(EXIT_USAGE, "--repo {s} is not a git working tree: {s}", .{ repo, git.last_err });
    const root = std.mem.trim(u8, top, " \r\n");

    // 1. The inputs.
    const good = (try git.commit(args.good)) orelse fail(EXIT_USAGE, "--good {s} names no commit", .{args.good});
    const bad = (try git.commit(args.bad)) orelse fail(EXIT_USAGE, "--bad {s} names no commit", .{args.bad});
    if (std.mem.eql(u8, good, bad)) fail(EXIT_USAGE, "--good and --bad are the same commit {s}", .{good});
    const ancestor = git.isAncestor(good, bad) catch fail(EXIT_GIT, "{s}", .{git.last_err});
    if (!ancestor) fail(EXIT_USAGE, "--good {s} is not an ancestor of --bad {s}", .{ good, bad });
    for (args.copies) |rel| {
        const p = try std.fs.path.join(a, &.{ root, rel });
        std.fs.accessAbsolute(p, .{}) catch fail(EXIT_USAGE, "--copy {s}: no such file in {s}", .{ rel, root });
    }
    std.fs.cwd().makePath(args.work_dir) catch |e| fail(EXIT_USAGE, "--work-dir {s}: {s}", .{ args.work_dir, @errorName(e) });
    const work_dir = try std.fs.cwd().realpathAlloc(a, args.work_dir);
    {
        var d = try std.fs.openDirAbsolute(work_dir, .{ .iterate = true });
        defer d.close();
        var di = d.iterate();
        if (try di.next()) |_| fail(EXIT_USAGE, "--work-dir {s} is not empty", .{work_dir});
    }
    if (try enclosingProject(a, work_dir)) |p|
        fail(EXIT_USAGE, "--work-dir {s} lies inside the buck2 project at {s}: a probe worktree there would not be its own project", .{ work_dir, p });

    var st = State{
        .a = a,
        .cfg = .{
            .a = a,
            .git = &git,
            .repo = root,
            .work_dir = work_dir,
            .buck2 = args.buck2,
            .verb = args.verb,
            .buck2_args = args.buck2_args,
            .targets = args.targets,
            .copies = args.copies,
            .submodules = args.submodules,
            .timeout_s = args.timeout_s,
            .env = &env,
        },
        .probes = std.ArrayList(report.Probe).init(a),
        .infra = std.ArrayList(report.Infra).init(a),
        .failures = std.StringHashMap([]const classify.Failure).init(a),
    };

    // 3. The candidates (listed before the recheck so a git failure costs no build).
    const cands = git.firstParents(good, bad) catch fail(EXIT_GIT, "{s}", .{git.last_err});
    if (cands.len == 0 or !std.mem.eql(u8, cands[cands.len - 1], bad))
        fail(EXIT_GIT, "git rev-list --first-parent {s}..{s} does not end at {s}", .{ good, bad, bad });
    st.candidates = cands;

    var r = report.Report{
        .verdict = .inconclusive,
        .good = good,
        .bad = bad,
        .targets = args.targets,
        .probes = &.{},
        .failures = &.{},
        .infra = &.{},
    };

    // 2. Bad again.
    st.role = .recheck;
    const again = try st.probeCommit(bad);
    var code: u8 = EXIT_INCONCLUSIVE;
    switch (again) {
        .pass => {
            r.verdict = .flake;
            code = EXIT_FLAKE;
        },
        .infra => {
            r.verdict = .inconclusive;
            r.last_good = good;
            r.candidates = cands;
            code = EXIT_INCONCLUSIVE;
        },
        .fail => {
            // 4. The search.
            st.role = .search;
            const untestable = try a.alloc(bool, cands.len);
            switch (try search.search(cands.len, &st, untestable)) {
                .culprit => |i| {
                    const c = cands[i];
                    const subj = git.subject(c) catch fail(EXIT_GIT, "{s}", .{git.last_err});
                    r.verdict = .culprit;
                    r.first_bad = .{ .commit = c, .subject = subj, .pr = report.prNumber(subj) };
                    r.last_good = if (i == 0) good else cands[i - 1];
                    r.failures = st.failures.get(c) orelse &.{};
                    code = EXIT_CULPRIT;
                },
                .inconclusive => |span| {
                    r.verdict = .inconclusive;
                    r.last_good = if (span.first == 0) good else cands[span.first - 1];
                    r.candidates = cands[span.first .. span.last + 1];
                    r.failures = st.failures.get(cands[span.last]) orelse &.{};
                    code = EXIT_INCONCLUSIVE;
                },
            }
        },
    }
    if (r.verdict == .inconclusive and r.failures.len == 0) r.failures = st.failures.get(bad) orelse &.{};
    r.probes = st.probes.items;
    r.infra = st.infra.items;

    // 5. The verdict.
    const out = std.io.getStdOut().writer();
    try report.write(r, out);
    try out.writeAll("\n");
    std.process.exit(code);
}

