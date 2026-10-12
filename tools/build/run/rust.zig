//! `gate rust`: runs one rust_test (a libtest harness) in a build action
//! (R1-R8 of docs/design/zig_gate_runner.md).
//!
//!   gate rust --busybox B --label L --test BIN --marker M --timeout-s N
//!
//! 1. `--list --format terse` names every test; none is a refusal (EMPTY
//!    GATE).
//! 2. Every test runs in one harness invocation; the harness's summary must
//!    count every listed test as passed, with none ignored.
//! A harness killed by SIGKILL (137) or by the timeout's SIGALRM (142) is NO
//! VERDICT, before any other verdict. The harness sees exactly PATH (busybox
//! applets), TMPDIR and HOME, runs from an empty directory with stdin
//! /dev/null, in a session of its own whose group is killed after each run.
//! On success: `PASS <label>: <n> passed\n` to the marker and to stdout.

const std = @import("std");
const sys = @import("sys.zig");
const util = @import("util.zig");
const supervise = @import("supervise.zig");

fn usageError() u8 {
    util.err("rust test_runner: usage error\n", .{});
    return 2;
}

const Args = struct {
    busybox: []const u8,
    label: []const u8,
    test_bin: []const u8,
    marker: []const u8,
    timeout: []const u8,
    timeout_s: u64,
};

fn parse(argv: []const []const u8) union(enum) { ok: Args, rc: u8 } {
    if (argv.len != 10) return .{ .rc = usageError() };
    const names = [_][]const u8{ "--busybox", "--label", "--test", "--marker", "--timeout-s" };
    var vals = [_]?[]const u8{null} ** 5;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        const k = for (names, 0..) |n, j| {
            if (std.mem.eql(u8, argv[i], n)) break j;
        } else return .{ .rc = usageError() };
        if (vals[k] != null) return .{ .rc = usageError() };
        vals[k] = argv[i + 1];
    }
    const t = vals[4].?;
    var ok = t.len > 0;
    for (t) |c| {
        if (c < '0' or c > '9') ok = false;
    }
    const n: u64 = if (ok) std.fmt.parseInt(u64, t, 10) catch 0 else 0;
    if (n == 0) {
        util.err("rust test_runner: timeout must be a positive number of seconds, not '{s}'\n", .{t});
        return .{ .rc = 2 };
    }
    return .{ .ok = .{ .busybox = vals[0].?, .label = vals[1].?, .test_bin = vals[2].?, .marker = vals[3].?, .timeout = t, .timeout_s = n } };
}

pub fn main(alloc: std.mem.Allocator, argv: []const []const u8) u8 {
    const a = switch (parse(argv)) {
        .ok => |v| v,
        .rc => |rc| return rc,
    };
    return run(alloc, a) catch |e| {
        util.err("rust test_runner: {s}\n", .{@errorName(e)});
        return 2;
    };
}

fn banner(comptime fmt: []const u8, a: anytype) void {
    util.err("{s}\n" ++ fmt ++ "\n", .{util.rule} ++ a);
}

const Run = struct {
    status: u8,
    signal: u8,
};

fn harness(alloc: std.mem.Allocator, bin: []const u8, run_dir: []const u8, extra: []const []const u8, out_fd: sys.fd_t, err_fd: sys.fd_t, timeout_s: u64) !Run {
    var argv = std.ArrayList([]const u8).init(alloc);
    try argv.append(bin);
    try argv.appendSlice(extra);
    const env = [_][]const u8{
        try std.fmt.allocPrint(alloc, "PATH={s}/bin", .{run_dir}),
        try std.fmt.allocPrint(alloc, "TMPDIR={s}/tmp", .{run_dir}),
        try std.fmt.allocPrint(alloc, "HOME={s}/home", .{run_dir}),
    };
    const o = try supervise.run(alloc, .{
        .path = (try alloc.dupeZ(u8, bin)).ptr,
        .argv = (try util.zList(alloc, argv.items)).ptr,
        .envp = (try util.zList(alloc, &env)).ptr,
        .cwd = (try std.fmt.allocPrintZ(alloc, "{s}/cwd", .{run_dir})).ptr,
        .stdout_fd = out_fd,
        .stderr_fd = err_fd,
        .limit = .{ .alarm_ms = timeout_s * 1000 },
    });
    if (o.timer_failed) return error.TimerFailed;
    return .{ .status = o.status, .signal = o.signal };
}

/// R7: a kill is not a verdict. Returns the exit status, or null.
fn noVerdict(rc: u8, what: []const u8, a: Args) ?u8 {
    if (rc == 137) {
        banner("NO VERDICT: {s} of {s} was killed by SIGKILL (exit 137).", .{ what, a.label });
        util.err("  A memory limit's kill is not the test's failure; retry on a larger machine.\n", .{});
        return 137;
    }
    if (rc == 142) {
        banner("NO VERDICT: {s} of {s} timed out after {s}s (exit 142).", .{ what, a.label, a.timeout });
        util.err("  A hang is not the test's failure; find what it waits on, or raise `test_timeout_s`.\n", .{});
        return 142;
    }
    return null;
}

fn run(alloc: std.mem.Allocator, a: Args) !u8 {
    const here = try util.actionDir(alloc);
    const bb = try util.abs(alloc, here, a.busybox);
    const bin = try util.abs(alloc, here, a.test_bin);
    const dir = try util.makeTempDir(alloc, here, ".komira_rust_test.");
    defer util.removeTree(dir);
    try util.mkdirs(alloc, dir, &.{ "bin", "tmp", "home", "cwd" });
    const bin_dir = try std.fmt.allocPrint(alloc, "{s}/bin", .{dir});
    const irc = try supervise.runPlain(alloc, &.{ bb, "--install", "-s", bin_dir });
    if (irc != 0) {
        util.err("rust test_runner: {s} --install -s {s} exited {d}\n", .{ bb, bin_dir, irc });
        return irc;
    }

    // 1. The listed tests.
    const list_raw = try std.fmt.allocPrint(alloc, "{s}/list_raw", .{dir});
    const list_err = try std.fmt.allocPrint(alloc, "{s}/list_err", .{dir});
    const fo = try util.createLog(list_raw);
    const fe = try util.createLog(list_err);
    const r1 = try harness(alloc, bin, dir, &.{ "--list", "--format", "terse" }, fo, fe, a.timeout_s);
    std.posix.close(fo);
    std.posix.close(fe);
    if (r1.signal != 0) return 128 +| r1.signal;
    if (noVerdict(r1.status, "listing the tests", a)) |rc| return rc;
    if (r1.status != 0) {
        banner("GATED TEST FAILED: {s}: listing its tests exited {d}.", .{ a.label, r1.status });
        util.writeTail(2, list_err, 50);
        return r1.status;
    }
    const listing = try util.readFileAlloc(alloc, list_raw);
    var listed: usize = 0;
    var it = util.lines(listing);
    while (it.next()) |line| {
        if (std.mem.endsWith(u8, line, ": test")) listed += 1;
    }
    if (listed == 0) {
        banner("EMPTY GATE: {s} lists 0 tests. A gate that runs nothing passes for any code; give it a #[test], or drop it from `tests`.", .{a.label});
        return 1;
    }

    // 2. Every test, in one run.
    const log = try std.fmt.allocPrint(alloc, "{s}/log", .{dir});
    const fl = try util.createLog(log);
    const r2 = try harness(alloc, bin, dir, &.{}, fl, fl, a.timeout_s);
    std.posix.close(fl);
    if (r2.signal != 0) return 128 +| r2.signal;
    if (noVerdict(r2.status, "the tests", a)) |rc| return rc;
    if (r2.status != 0) {
        banner("GATED TEST FAILED: {s} (exit {d})", .{ a.label, r2.status });
        util.writeTail(2, log, 100);
        return r2.status;
    }
    const text = try util.readFileAlloc(alloc, log);
    const counts = summary(text) orelse {
        banner("GATED TEST FAILED: {s}: the harness exited 0 without a `test result: ok.` line.", .{a.label});
        util.writeTail(2, log, 50);
        return 1;
    };
    if (!std.mem.eql(u8, counts.ignored, "0")) {
        banner("REFUSED: {s}: {s} #[ignore]d test(s) did not run. An ignored test is a mute; remove its #[ignore] and make it pass, or delete it.", .{ a.label, counts.ignored });
        var lit = util.lines(text);
        while (lit.next()) |line| {
            if (std.mem.indexOf(u8, line, " ... ignored") != null) util.err("{s}\n", .{line});
        }
        return 1;
    }
    const listed_s = try std.fmt.allocPrint(alloc, "{d}", .{listed});
    if (!std.mem.eql(u8, counts.passed, listed_s)) {
        banner("REFUSED: {s}: {s} tests listed, so {s} must pass; the harness reports {s}.", .{ a.label, listed_s, listed_s, counts.passed });
        util.writeTail(2, log, 50);
        return 1;
    }
    const line = try std.fmt.allocPrint(alloc, "PASS {s}: {s} passed\n", .{ a.label, counts.passed });
    const f = std.fs.cwd().createFile(a.marker, .{}) catch |e| {
        util.err("rust test_runner: cannot write the marker {s}: {s}\n", .{ a.marker, @errorName(e) });
        return 2;
    };
    defer f.close();
    f.writeAll(line) catch return 2;
    util.out("{s}", .{line});
    return 0;
}

const Counts = struct { passed: []const u8, ignored: []const u8 };

/// The first `^test result: ok\.` line, read as
/// `test result: ok. <N> passed; <M> failed; <K> ignored;...`; null when
/// there is none, it does not read so, or N is empty (sed's `[0-9]*`).
pub fn summary(text: []const u8) ?Counts {
    var it = util.lines(text);
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, "test result: ok.")) continue;
        return parseSummary(line);
    }
    return null;
}

fn digits(s: []const u8, i: *usize) []const u8 {
    const b = i.*;
    while (i.* < s.len and s[i.*] >= '0' and s[i.*] <= '9') i.* += 1;
    return s[b..i.*];
}

fn literal(s: []const u8, i: *usize, l: []const u8) bool {
    if (!std.mem.startsWith(u8, s[i.*..], l)) return false;
    i.* += l.len;
    return true;
}

fn parseSummary(line: []const u8) ?Counts {
    var i: usize = 0;
    if (!literal(line, &i, "test result: ok. ")) return null;
    const passed = digits(line, &i);
    if (!literal(line, &i, " passed; ")) return null;
    _ = digits(line, &i);
    if (!literal(line, &i, " failed; ")) return null;
    const ignored = digits(line, &i);
    if (!literal(line, &i, " ignored;")) return null;
    if (passed.len == 0) return null;
    return .{ .passed = passed, .ignored = ignored };
}
