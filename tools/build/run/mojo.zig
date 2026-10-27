//! `gate mojo`: runs one gated Mojo test (G1-G12 of
//! docs/design/zig_gate_runner.md), optionally under a memory cap (M1-M6),
//! a test time limit (D1-D6) or a coverage run's limit (C1).
//!
//!   gate mojo --busybox B --runtime-lib DIR --label L --test ROOT/bin/NAME --marker M
//!             [--mem-cap-mib N] [--deadline-s L --runner-timeout-s T]
//!             [--limit-s N --limit-report coverage]
//!             [--env NAME=VALUE]... [--arg VALUE]...
//!
//! On exit 0 of the test: `PASS <label>\n` to the marker, nothing printed,
//! exit 0. Otherwise the banner (`GATED TEST FAILED: <label> (exit <rc>)`,
//! the last 200 lines of the test's output) and the test's own status. The
//! marker bytes and the banner lines are contracts (G9, G11): a package
//! action takes every marker as an input, release/ci/main_red matches the
//! banner, and the coverage runs remove two of its lines by exact text.

const std = @import("std");
const builtin = @import("builtin");
const sys = @import("sys.zig");
const util = @import("util.zig");
const supervise = @import("supervise.zig");

const reserved = [_][]const u8{
    "PATH",                       "LD_LIBRARY_PATH",       "LD_PRELOAD", "DYLD_LIBRARY_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "TMPDIR",     "TEST_TMPDIR",
    "HOME",                       "PWD",
};

/// The token a rule writes in an --arg for the action's directory.
pub const action_dir_token = "@KOMIRA_ACTION_DIR@";

pub const Args = struct {
    busybox: []const u8 = "",
    runtime_lib: []const u8 = "",
    label: []const u8 = "",
    test_bin: []const u8 = "",
    marker: []const u8 = "",
    cap_mib: ?u64 = null,
    deadline_s: ?[]const u8 = null,
    runner_timeout_s: ?[]const u8 = null,
    limit_s: ?u64 = null,
    limit_report: ?[]const u8 = null,
    env: std.ArrayList([]const u8) = undefined,
    args: std.ArrayList([]const u8) = undefined,
};

fn usage(comptime fmt: []const u8, a: anytype) u8 {
    util.err("gate_runner: " ++ fmt ++ "\n", a);
    return 2;
}

/// Parses argv after `mojo`; an exit status on a refusal.
pub fn parse(alloc: std.mem.Allocator, argv: []const []const u8, a: *Args) ?u8 {
    a.env = std.ArrayList([]const u8).empty;
    a.args = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    var have = [_]bool{false} ** 10;
    const names = [_][]const u8{ "--busybox", "--runtime-lib", "--label", "--test", "--marker", "--mem-cap-mib", "--deadline-s", "--runner-timeout-s", "--limit-s", "--limit-report" };
    while (i < argv.len) : (i += 2) {
        const flag = argv[i];
        if (std.mem.eql(u8, flag, "--env")) {
            if (i + 1 >= argv.len) return usage("--env needs NAME=VALUE", .{});
            const kv = argv[i + 1];
            if (a.args.items.len > 0) return usage("--env {s} after an --arg", .{kv});
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return usage("--env {s} is not NAME=VALUE", .{kv});
            const name = kv[0..eq];
            if (!validName(name)) return usage("--env {s} is not NAME=VALUE", .{kv});
            for (reserved) |r| {
                if (std.mem.eql(u8, name, r)) return usage("--env may not set {s}; the runner sets it", .{name});
            }
            a.env.append(alloc, kv) catch return 2;
            continue;
        }
        if (std.mem.eql(u8, flag, "--arg")) {
            if (i + 1 >= argv.len) return usage("--arg needs a value", .{});
            a.args.append(alloc, argv[i + 1]) catch return 2;
            continue;
        }
        const k = for (names, 0..) |n, j| {
            if (std.mem.eql(u8, flag, n)) break j;
        } else return usage("unknown argument {s}", .{flag});
        if (a.env.items.len > 0 or a.args.items.len > 0) return usage("{s} after an --env or --arg", .{flag});
        if (have[k]) return usage("{s} given twice", .{flag});
        have[k] = true;
        if (i + 1 >= argv.len) return usage("{s} needs a value", .{flag});
        const v = argv[i + 1];
        switch (k) {
            0 => a.busybox = v,
            1 => a.runtime_lib = v,
            2 => a.label = v,
            3 => a.test_bin = v,
            4 => a.marker = v,
            5 => a.cap_mib = util.positiveStrict(v) orelse {
                util.err("mem_cap: REFUSING: cap '{s}' is not a positive whole number of MiB\n", .{v});
                return 2;
            },
            6 => a.deadline_s = v,
            7 => a.runner_timeout_s = v,
            8 => a.limit_s = util.positiveStrict(v) orelse {
                util.err("cov_run: the limit '{s}' is not a positive whole number of seconds\n", .{v});
                return 2;
            },
            9 => a.limit_report = v,
            else => unreachable,
        }
    }
    for (have[0..5], 0..) |h, j| {
        if (!h) return usage("usage error: {s} is required", .{names[j]});
    }
    if ((a.deadline_s == null) != (a.runner_timeout_s == null)) {
        util.err("test_deadline: usage error: --deadline-s and --runner-timeout-s go together\n", .{});
        return 2;
    }
    if (a.deadline_s) |d| {
        for ([_][]const u8{ d, a.runner_timeout_s.? }) |n| {
            if (util.positiveStrict(n) == null) {
                util.err("test_deadline: REFUSING: '{s}' is not a positive whole number of seconds\n", .{n});
                return 2;
            }
        }
    }
    if ((a.limit_s == null) != (a.limit_report == null)) return usage("usage error: --limit-s and --limit-report go together", .{});
    if (a.limit_report) |r| {
        if (!std.mem.eql(u8, r, "coverage")) return usage("--limit-report {s}: the only report is coverage", .{r});
        if (a.deadline_s != null) return usage("usage error: --limit-s and --deadline-s are two limits", .{});
    }
    return null;
}

fn validName(n: []const u8) bool {
    if (n.len == 0 or (n[0] >= '0' and n[0] <= '9')) return false;
    for (n) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

fn envName(kv: []const u8) []const u8 {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return kv;
    return kv[0..eq];
}

/// The test's environment (G7): the action's, with PATH, LD_LIBRARY_PATH
/// (and on macOS DYLD_LIBRARY_PATH), TMPDIR, TEST_TMPDIR, HOME and PWD set
/// by the runner, then each --env in order (a later one of a name wins).
pub fn buildEnv(alloc: std.mem.Allocator, inherited: []const []const u8, run: []const u8, lib: []const u8, cwd: []const u8, extra: []const []const u8) ![]const []const u8 {
    var fixed = std.ArrayList([]const u8).empty;
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "PATH={s}/bin", .{run}));
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "LD_LIBRARY_PATH={s}", .{lib}));
    if (sys.is_darwin) try fixed.append(alloc, try std.fmt.allocPrint(alloc, "DYLD_LIBRARY_PATH={s}", .{lib}));
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "TMPDIR={s}/tmp", .{run}));
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "TEST_TMPDIR={s}/tmp", .{run}));
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "HOME={s}/home", .{run}));
    try fixed.append(alloc, try std.fmt.allocPrint(alloc, "PWD={s}", .{cwd}));
    var all = std.ArrayList([]const u8).empty;
    outer: for (inherited) |kv| {
        const n = envName(kv);
        for (fixed.items) |f| if (std.mem.eql(u8, envName(f), n)) continue :outer;
        for (extra) |f| if (std.mem.eql(u8, envName(f), n)) continue :outer;
        try all.append(alloc, kv);
    }
    try all.appendSlice(alloc, fixed.items);
    for (extra, 0..) |kv, i| {
        // A later --env of the same name replaces this one.
        var later = false;
        for (extra[i + 1 ..]) |k2| {
            if (std.mem.eql(u8, envName(k2), envName(kv))) later = true;
        }
        if (!later) try all.append(alloc, kv);
    }
    return all.items;
}

/// The action's environment, as the test inherits it.
pub fn inheritedEnv(alloc: std.mem.Allocator) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    for (std.os.environ) |e| try out.append(alloc, std.mem.span(e));
    return out.items;
}

pub fn main(alloc: std.mem.Allocator, argv: []const []const u8) u8 {
    var a = Args{};
    if (parse(alloc, argv, &a)) |rc| return rc;
    return runParsed(alloc, &a) catch |e| {
        util.err("gate_runner: {s}\n", .{@errorName(e)});
        return 2;
    };
}

fn runParsed(alloc: std.mem.Allocator, a: *Args) !u8 {
    if (a.cap_mib != null and !supervise.plat.has_proc) {
        util.err("mem_cap: REFUSING: no /proc here to read resident memory from; {s} would run uncapped\n", .{a.label});
        return 2;
    }
    const here = try util.actionDir(alloc);
    const bb = try util.abs(alloc, here, a.busybox);
    const lib = try util.abs(alloc, here, a.runtime_lib);
    const bin = try util.abs(alloc, here, a.test_bin);
    const cut = std.mem.lastIndexOf(u8, bin, "/bin/") orelse {
        util.err("gate_runner: {s} is not <root>/bin/<name>\n", .{bin});
        return 2;
    };
    const root = bin[0..cut];

    var expanded = std.ArrayList([]const u8).empty;
    try expanded.append(alloc, bin);
    for (a.args.items) |v| try expanded.append(alloc, try util.replaceAll(alloc, v, action_dir_token, here));

    const run = try util.makeTempDir(alloc, here, ".komira_test.");
    defer util.removeTree(run);
    try util.mkdirs(alloc, run, &.{ "bin", "tmp", "home", "share" });
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/bin", .{run});
    const irc = try supervise.runPlain(alloc, &.{ bb, "--install", "-s", bin_dir });
    if (irc != 0) {
        util.err("gate_runner: {s} --install -s {s} exited {d}\n", .{ bb, bin_dir, irc });
        return irc;
    }

    const share = try std.fmt.allocPrint(alloc, "{s}/share", .{root});
    const cwd = if (isDir(share)) share else try std.fmt.allocPrint(alloc, "{s}/share", .{run});
    const env = try buildEnv(alloc, try inheritedEnv(alloc), run, lib, cwd, a.env.items);
    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{run});
    const log_fd = try util.createLog(log);

    var limit: supervise.Limit = .none;
    if (a.deadline_s) |d| limit = .{ .deadline_ms = util.positiveStrict(d).? * 1000 };
    if (a.limit_s) |l| limit = .{ .group_ms = l * 1000 };
    const outcome = try supervise.run(alloc, .{
        .path = (try alloc.dupeZ(u8, bin)).ptr,
        .argv = (try util.zList(alloc, expanded.items)).ptr,
        .envp = (try util.zList(alloc, env)).ptr,
        .cwd = (try alloc.dupeZ(u8, cwd)).ptr,
        .stdout_fd = log_fd,
        .stderr_fd = log_fd,
        .cap_kib = if (a.cap_mib) |c| c * 1024 else null,
        .limit = limit,
    });
    std.posix.close(log_fd);

    if (outcome.signal != 0) return 128 +| outcome.signal;
    if (outcome.timer_failed) {
        const what = a.deadline_s orelse "the coverage run's";
        util.err("test_deadline: the timer of {s} failed, so the test ran without its limit of {s} s\n", .{ a.label, what });
        return 2;
    }
    if (outcome.unreadable) {
        util.err("mem_cap: cannot read the process tree of {s} from /proc; killed it rather than run it uncapped\n", .{a.label});
        return 2;
    }
    if (a.limit_s != null and outcome.limit_hit) return coverageExpired(alloc, a, outcome, log);

    const rc = outcome.status;
    if (rc == 0) {
        const f = std.fs.cwd().createFile(a.marker, .{}) catch |e| {
            util.err("gate_runner: cannot write the marker {s}: {s}\n", .{ a.marker, @errorName(e) });
            return 2;
        };
        defer f.close();
        const line = try std.fmt.allocPrint(alloc, "PASS {s}\n", .{a.label});
        f.writeAll(line) catch return 2;
    } else {
        banner(a.label, rc, log);
    }
    if (outcome.capped_kib) |k| {
        util.err("MEMORY CAP: killed {s} at {d} MiB resident, over its cap of {d} MiB\n", .{ a.label, k / 1024, a.cap_mib.? });
    }
    if (a.deadline_s != null and outcome.limit_hit) {
        util.err("TEST TIME LIMIT: killed {s} after {s} s, under the test runner's timeout of {s} s (komira.test_timeout_s)\n", .{ a.label, a.deadline_s.?, a.runner_timeout_s.? });
    }
    return rc;
}

/// G10: the banner of a red test, to stderr.
pub fn banner(label: []const u8, rc: u8, log: []const u8) void {
    util.err("{s}\nGATED TEST FAILED: {s} (exit {d})\nThe library's package is not produced until this test passes.\n" ++
        "------------------------------------------------------------------ output\n", .{ util.rule, label, rc });
    util.writeTail(2, log, 200);
    util.err("{s}\n", .{util.rule});
}

fn red(label: []const u8, comptime fmt: []const u8, a: anytype) u8 {
    util.err("{s}\nCOVERAGE RUN FAILED: {s}\n" ++ fmt ++ "\n{s}\n", .{ util.rule, label } ++ a ++ .{util.rule});
    return 1;
}

/// C1: a coverage run past its limit, its whole group killed.
fn coverageExpired(alloc: std.mem.Allocator, a: *Args, o: supervise.Outcome, log: []const u8) u8 {
    const me = sys.getpid();
    if (o.blind) |seen| {
        return red(a.label, "cov_run: /proc is not readable as this run's own: /proc/{d}/stat and /proc/self/stat must both start with this process's pid {d}, and start with '{d}' and '{d}'. So whether the time limit's kill reached every process of the run cannot be checked.", .{ me, me, seen[0], seen[1] });
    }
    if (o.survivors.len > 0) {
        var list = std.ArrayList(u8).empty;
        for (o.survivors) |m| list.writer(alloc).print("{d} {c} {s};", .{ m.pid, m.state, m.comm }) catch {};
        return red(a.label, "After the time limit ({d} s), processes of the coverage run survived the kill of its process group {d} (pid state comm: {s}). The limit must kill the whole group, kcov, the test and every child it left; they are killed now.", .{ a.limit_s.?, o.pid, list.items });
    }
    util.err("------------------------------------------------------------------ output (last 200 lines)\n", .{});
    util.writeTail(2, log, 200);
    return red(a.label, "The test left processes running or did not finish within {d} s under kcov, and every process of the run was killed: kcov waits for every process the test started, where the release gate waits for the test alone. A test must wait for (or kill) every child it starts.", .{a.limit_s.?});
}

/// `[ -d p ]`: a directory, symbolic links followed.
fn isDir(p: []const u8) bool {
    const st = std.posix.fstatat(std.posix.AT.FDCWD, p, 0) catch return false;
    return std.posix.S.ISDIR(st.mode);
}
