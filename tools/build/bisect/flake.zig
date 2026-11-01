//! The flake measurement (README.md, "Flake mode"): each given target built
//! K times at one commit, one target at a time, in one worktree. Run i of a
//! target passes `-c komira.rerun=<target>#<base+i>`, which gives that
//! target's test actions, and no other action, a key no earlier run had: a
//! failing run is a real failure, never a cache hit replaying another run.
//! An INFRA run is tried again once with the same n; if it stays INFRA it is
//! not counted, as a failure or as a run.
//!
//! Before its runs, a target is checked with CHECK_BXL: a target whose rule
//! runs no test action under the flag (or that names nothing) would replay
//! the cache in every run, so it is `not_measurable`, never `never_failed`.
const std = @import("std");
const classify = @import("classify.zig");
const prober = @import("probe.zig");
const Outcome = @import("search.zig").Outcome;

/// The buckconfig key a run names its target and number in.
pub const RERUN_KEY = "komira.rerun";

/// The BXL script that checks a rerun value (tools/build/rerun/README.md):
/// it fails unless the label names a target whose rule passes KOMIRA_RERUN
/// to its test actions.
pub const CHECK_BXL = "komira//tools/build/rerun/check.bxl:check";

pub const Verdict = enum {
    /// Some target failed in at least one counted run.
    flake,
    /// Every target was counted in every run and never failed.
    never_failed,
    /// No target failed, but some run stayed INFRA, so "never failed in K
    /// runs" was not shown.
    inconclusive,
    /// No target failed, and some target has no test action the rerun flag
    /// runs again (CHECK_BXL refused it): its runs would all be cache hits.
    not_measurable,
};

/// What CHECK_BXL said of a target.
pub const Check = enum {
    /// It exited 0: the target's test actions run again under the flag.
    measurable,
    /// It exited 3, buck2's user error: the label names no target, or one
    /// whose rule runs no test action under the flag. Not built.
    not_measurable,
    /// It exited otherwise (or was killed) twice. Not built; the target is
    /// listed with one infra run, run 0.
    infra,
};

/// The Check of a CHECK_BXL run that exited `exit` (null: killed).
pub fn checkOutcome(exit: ?u8) Check {
    const e = exit orelse return .infra;
    return switch (e) {
        0 => .measurable,
        3 => .not_measurable,
        else => .infra,
    };
}

/// The failing runs that share a first failing line.
pub const Excerpt = struct {
    first_failing_line: []const u8,
    runs: []const u64,
    /// The excerpt of the first of `runs`.
    excerpt: []const u8,
};

pub const InfraRun = struct { run: u64, buck2_exit: ?u8, excerpt: []const u8 };

pub const Target = struct {
    target: []const u8,
    check: Check = .measurable,
    /// The end of CHECK_BXL's stderr when it did not exit 0.
    check_excerpt: []const u8 = "",
    /// Counted runs: those that ended PASS or FAIL.
    runs: u32,
    failures: u32,
    /// Builds run, retries included.
    attempts: u32,
    failing_runs: []const u64,
    excerpts: []const Excerpt,
    infra: []const InfraRun,
};

pub const Measurement = struct {
    rev: []const u8,
    runs_requested: u32,
    rerun_base: u64,
    targets: []const Target,
};

/// The `-c` value of run `n` of `target`: `komira.rerun=<target>#<n>`.
pub fn rerunValue(a: std.mem.Allocator, target: []const u8, n: u64) ![]const u8 {
    return std.fmt.allocPrint(a, RERUN_KEY ++ "={s}#{d}", .{ target, n });
}

/// Whether `target` names one target, which a rerun can name; a pattern
/// (`//p/...`, `//p:`) cannot.
pub fn isLabel(target: []const u8) bool {
    if (std.mem.endsWith(u8, target, "...") or std.mem.endsWith(u8, target, ":")) return false;
    return std.mem.indexOfScalar(u8, target, ':') != null;
}

/// Whether `target` names its cell (`komira//p:n`). A rerun value must: the
/// rules refuse `//p:n`, so every run would fail analysis.
pub fn hasCell(target: []const u8) bool {
    const i = std.mem.indexOf(u8, target, "//") orelse return false;
    return i > 0;
}

/// The first of `targets` that is a label without a cell.
pub fn firstWithoutCell(targets: []const []const u8) ?[]const u8 {
    for (targets) |t| if (isLabel(t) and !hasCell(t)) return t;
    return null;
}

/// Whether `line` (trimmed) marks a failure: it holds `FAIL` (so `FAILED`,
/// `BUILD FAILED`) or `Action failed` as written, or `panic` or `error:` in
/// any case, and does not end `OK`. A runner prints a passing test's name
/// with `OK` after it, and a name may hold any of the words.
pub fn marksFailure(line: []const u8) bool {
    if (std.mem.endsWith(u8, line, "OK")) return false;
    if (std.mem.indexOf(u8, line, "FAIL") != null) return true;
    if (std.mem.indexOf(u8, line, "Action failed") != null) return true;
    if (std.ascii.indexOfIgnoreCase(line, "panic") != null) return true;
    return std.ascii.indexOfIgnoreCase(line, "error:") != null;
}

/// The line failing runs are grouped by: the first line of the excerpt that
/// marks a failure (marksFailure), trimmed; else its first non-blank line
/// that does not end `OK`; else "". A test's first lines often name the run
/// (a seed, a time, a path) or a test that passed; the failing line names
/// the defect.
pub fn firstFailingLine(excerpt: []const u8) []const u8 {
    var first: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, excerpt, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (marksFailure(line)) return line;
        if (first == null and !std.mem.endsWith(u8, line, "OK")) first = line;
    }
    return first orelse "";
}

pub const Failed = struct { run: u64, excerpt: []const u8 };

/// The failing runs grouped by first failing line, in the order each line
/// first appeared.
pub fn dedup(a: std.mem.Allocator, failed: []const Failed) ![]const Excerpt {
    var keys = std.ArrayList([]const u8).empty;
    var runs = std.ArrayList(std.ArrayList(u64)).empty;
    var texts = std.ArrayList([]const u8).empty;
    for (failed) |f| {
        const k = firstFailingLine(f.excerpt);
        var at: ?usize = null;
        for (keys.items, 0..) |x, j| {
            if (std.mem.eql(u8, x, k)) at = j;
        }
        if (at) |j| {
            try runs.items[j].append(a, f.run);
        } else {
            try keys.append(a, k);
            try texts.append(a, f.excerpt);
            var l = std.ArrayList(u64).empty;
            try l.append(a, f.run);
            try runs.append(a, l);
        }
    }
    const out = try a.alloc(Excerpt, keys.items.len);
    for (out, 0..) |*e, j| e.* = .{ .first_failing_line = keys.items[j], .runs = runs.items[j].items, .excerpt = texts.items[j] };
    return out;
}

/// flake, else not_measurable, else inconclusive, else never_failed.
pub fn verdict(m: Measurement) Verdict {
    var short = false;
    var unmeasurable = false;
    for (m.targets) |t| {
        if (t.failures > 0) return .flake;
        if (t.check == .not_measurable) {
            unmeasurable = true;
        } else if (t.runs < m.runs_requested) short = true;
    }
    if (unmeasurable) return .not_measurable;
    return if (short) .inconclusive else .never_failed;
}

/// failures / runs; 0 when no run was counted.
pub fn rate(t: Target) f64 {
    if (t.runs == 0) return 0;
    return @as(f64, @floatFromInt(t.failures)) / @as(f64, @floatFromInt(t.runs));
}

/// One target K times in the prepared worktree `wt`. `err` takes progress.
fn measureTarget(cfg: prober.Config, wt: []const u8, rev: []const u8, idx: usize, target: []const u8, runs: u32, base: u64, err: anytype) !Target {
    const a = cfg.a;
    // CHECK_BXL first, with run 1's value; INFRA is tried again once.
    const first_value = try rerunValue(a, target, base + 1);
    var ck: prober.Exec = undefined;
    var verdict_of_check: Check = .infra;
    var check_tries: u32 = 0;
    while (check_tries < 2) {
        check_tries += 1;
        const tag = try std.fmt.allocPrint(a, "{s}-check-t{d}-{d}", .{ rev[0..@min(12, rev.len)], idx, check_tries });
        ck = try prober.bxl(cfg, wt, CHECK_BXL, &.{ "-c", first_value }, tag);
        verdict_of_check = checkOutcome(ck.exit);
        err.print("bisect: check {s} (attempt {d}): {s}\n", .{ target, check_tries, @tagName(verdict_of_check) }) catch {};
        if (verdict_of_check != .infra) break;
    }
    if (verdict_of_check != .measurable) {
        const tail = prober.tail(ck.stderr, 20);
        var infra_runs: []const InfraRun = &.{};
        if (verdict_of_check == .infra) {
            const one = try a.alloc(InfraRun, 1);
            one[0] = .{ .run = 0, .buck2_exit = ck.exit, .excerpt = tail };
            infra_runs = one;
        }
        return .{ .target = target, .check = verdict_of_check, .check_excerpt = tail, .runs = 0, .failures = 0, .attempts = 0, .failing_runs = &.{}, .excerpts = &.{}, .infra = infra_runs };
    }

    var failed = std.ArrayList(Failed).empty;
    var failing = std.ArrayList(u64).empty;
    var infra = std.ArrayList(InfraRun).empty;
    var counted: u32 = 0;
    var attempts: u32 = 0;
    var i: u64 = 1;
    while (i <= runs) : (i += 1) {
        const n = base + i;
        const extra = [_][]const u8{ "-c", try rerunValue(a, target, n) };
        var at: prober.Attempt = undefined;
        var tries: u32 = 0;
        while (tries < 2) {
            tries += 1;
            const tag = try std.fmt.allocPrint(a, "{s}-flake-t{d}-r{d}-{d}", .{ rev[0..@min(12, rev.len)], idx, n, tries });
            at = try prober.build(cfg, wt, &.{target}, &extra, tag);
            err.print("bisect: flake {s} run {d} (attempt {d}): {s}\n", .{ target, n, tries, @tagName(at.classified.outcome) }) catch {};
            if (at.classified.outcome != .infra) break;
        }
        attempts += tries;
        switch (at.classified.outcome) {
            .pass => counted += 1,
            .fail => {
                counted += 1;
                try failing.append(a, n);
                const text = if (at.classified.failures.len > 0) at.classified.failures[0].excerpt else at.tail;
                try failed.append(a, .{ .run = n, .excerpt = text });
            },
            .infra => try infra.append(a, .{ .run = n, .buck2_exit = at.exit, .excerpt = at.tail }),
        }
    }
    return .{
        .target = target,
        .runs = counted,
        .failures = @intCast(failing.items.len),
        .attempts = attempts,
        .failing_runs = failing.items,
        .excerpts = try dedup(a, failed.items),
        .infra = infra.items,
    };
}

/// Every target of `cfg` measured `runs` times at `rev`, in one worktree
/// made for the measurement and removed after. A worktree that cannot be
/// readied (twice) leaves every run uncounted, with the reason as each
/// target's infra excerpt. Errors as `probe.attempt`'s.
pub fn measure(cfg: prober.Config, rev: []const u8, runs: u32, base: u64, why: *[]const u8) !Measurement {
    const a = cfg.a;
    const err = std.fs.File.stderr().deprecatedWriter();
    var ready: ?[]const u8 = null;
    var reason: prober.Attempt = undefined;
    var tries: u32 = 0;
    while (tries < 2 and ready == null) {
        tries += 1;
        const wt = try prober.add(cfg, rev, why);
        if (prober.prepare(cfg, wt, why)) |infra| {
            if (infra) |x| {
                reason = x;
                try prober.remove(cfg, wt, why);
            } else ready = wt;
        } else |e| {
            prober.remove(cfg, wt, why) catch {};
            return e;
        }
    }
    const targets = try a.alloc(Target, cfg.targets.len);
    if (ready) |wt| {
        for (cfg.targets, 0..) |t, idx| {
            targets[idx] = measureTarget(cfg, wt, rev, idx, t, runs, base, err) catch |e| {
                prober.remove(cfg, wt, why) catch {};
                return e;
            };
        }
        try prober.remove(cfg, wt, why);
    } else {
        for (cfg.targets, 0..) |t, idx| {
            const one = try a.alloc(InfraRun, 1);
            one[0] = .{ .run = 0, .buck2_exit = reason.exit, .excerpt = reason.tail };
            targets[idx] = .{ .target = t, .runs = 0, .failures = 0, .attempts = 0, .failing_runs = &.{}, .excerpts = &.{}, .infra = one };
        }
    }
    return .{ .rev = rev, .runs_requested = runs, .rerun_base = base, .targets = targets };
}

/// Writes `m` as a JSON object into the open stream `w`.
pub fn write(m: Measurement, w: anytype) !void {
    try w.beginObject();
    try w.objectField("rev");
    try w.write(m.rev);
    try w.objectField("runs_requested");
    try w.write(m.runs_requested);
    try w.objectField("rerun_base");
    try w.write(m.rerun_base);
    try w.objectField("targets");
    try w.beginArray();
    for (m.targets) |t| {
        try w.beginObject();
        try w.objectField("target");
        try w.write(t.target);
        try w.objectField("check");
        try w.write(@tagName(t.check));
        try w.objectField("check_excerpt");
        if (t.check == .measurable) try w.write(null) else try w.write(t.check_excerpt);
        try w.objectField("runs");
        try w.write(t.runs);
        try w.objectField("failures");
        try w.write(t.failures);
        try w.objectField("failure_rate");
        try w.write(rate(t));
        try w.objectField("attempts");
        try w.write(t.attempts);
        try w.objectField("failing_runs");
        try w.write(t.failing_runs);
        try w.objectField("excerpts");
        try w.beginArray();
        for (t.excerpts) |e| {
            try w.beginObject();
            try w.objectField("first_failing_line");
            try w.write(e.first_failing_line);
            try w.objectField("runs");
            try w.write(e.runs);
            try w.objectField("excerpt");
            try w.write(e.excerpt);
            try w.endObject();
        }
        try w.endArray();
        try w.objectField("infra");
        try w.beginArray();
        for (t.infra) |x| {
            try w.beginObject();
            try w.objectField("run");
            try w.write(x.run);
            try w.objectField("buck2_exit");
            try w.write(x.buck2_exit);
            try w.objectField("excerpt");
            try w.write(x.excerpt);
            try w.endObject();
        }
        try w.endArray();
        try w.endObject();
    }
    try w.endArray();
    try w.endObject();
}

/// The `bisect flake` verdict: `{"mode":"flake","verdict":...}` and the
/// measurement's fields, as one line.
pub fn writeVerdict(m: Measurement, out: *std.Io.Writer) !void {
    var w: std.json.Stringify = .{ .writer = out };
    try w.beginObject();
    try w.objectField("mode");
    try w.write("flake");
    try w.objectField("verdict");
    try w.write(@tagName(verdict(m)));
    try w.objectField("measurement");
    try write(m, &w);
    try w.endObject();
}
