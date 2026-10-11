//! The flake measurement (README.md, "Flake mode"): each given target built
//! K times at one commit, one target at a time, in one worktree. Run i of a
//! target passes `-c komira.rerun=<target>#<base+i>`, which gives that
//! target's test actions, and no other action, a key no earlier run had: a
//! failing run is a real failure, never a cache hit replaying another run.
//! An INFRA run is tried again once with the same n; if it stays INFRA it is
//! not counted, as a failure or as a run.
const std = @import("std");
const classify = @import("classify.zig");
const prober = @import("probe.zig");
const Outcome = @import("search.zig").Outcome;

/// The buckconfig key a run names its target and number in.
pub const RERUN_KEY = "komira.rerun";

pub const Verdict = enum {
    /// Some target failed in at least one counted run.
    flake,
    /// Every target was counted in every run and never failed.
    never_failed,
    /// No target failed, but some run stayed INFRA, so "never failed in K
    /// runs" was not shown.
    inconclusive,
};

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

/// The line failing runs are grouped by: the first line of the excerpt that
/// says assert, expect, panic, fail or error (any case), trimmed; else its
/// first non-blank line. A test's first lines often name the run (a seed, a
/// time, a path); its assertion line names the defect.
pub fn firstFailingLine(excerpt: []const u8) []const u8 {
    const words = [_][]const u8{ "assert", "expect", "panic", "fail", "error" };
    var first: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, excerpt, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (first == null) first = line;
        for (words) |w| {
            if (std.ascii.indexOfIgnoreCase(line, w) != null) return line;
        }
    }
    return first orelse "";
}

pub const Failed = struct { run: u64, excerpt: []const u8 };

/// The failing runs grouped by first failing line, in the order each line
/// first appeared.
pub fn dedup(a: std.mem.Allocator, failed: []const Failed) ![]const Excerpt {
    var keys = std.ArrayList([]const u8).init(a);
    var runs = std.ArrayList(std.ArrayList(u64)).init(a);
    var texts = std.ArrayList([]const u8).init(a);
    for (failed) |f| {
        const k = firstFailingLine(f.excerpt);
        var at: ?usize = null;
        for (keys.items, 0..) |x, j| {
            if (std.mem.eql(u8, x, k)) at = j;
        }
        if (at) |j| {
            try runs.items[j].append(f.run);
        } else {
            try keys.append(k);
            try texts.append(f.excerpt);
            var l = std.ArrayList(u64).init(a);
            try l.append(f.run);
            try runs.append(l);
        }
    }
    const out = try a.alloc(Excerpt, keys.items.len);
    for (out, 0..) |*e, j| e.* = .{ .first_failing_line = keys.items[j], .runs = runs.items[j].items, .excerpt = texts.items[j] };
    return out;
}

pub fn verdict(m: Measurement) Verdict {
    var short = false;
    for (m.targets) |t| {
        if (t.failures > 0) return .flake;
        if (t.runs < m.runs_requested) short = true;
    }
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
    var failed = std.ArrayList(Failed).init(a);
    var failing = std.ArrayList(u64).init(a);
    var infra = std.ArrayList(InfraRun).init(a);
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
                try failing.append(n);
                const text = if (at.classified.failures.len > 0) at.classified.failures[0].excerpt else at.tail;
                try failed.append(.{ .run = n, .excerpt = text });
            },
            .infra => try infra.append(.{ .run = n, .buck2_exit = at.exit, .excerpt = at.tail }),
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
    const err = std.io.getStdErr().writer();
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
pub fn writeVerdict(m: Measurement, out: anytype) !void {
    var w = std.json.writeStream(out, .{});
    defer w.deinit();
    try w.beginObject();
    try w.objectField("mode");
    try w.write("flake");
    try w.objectField("verdict");
    try w.write(@tagName(verdict(m)));
    try w.objectField("measurement");
    try write(m, &w);
    try w.endObject();
}
