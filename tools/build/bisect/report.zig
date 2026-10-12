//! The verdict bisect prints on stdout: one JSON object (README.md, "The
//! verdict"), and the pull request number read from a merge subject.
const std = @import("std");
const Outcome = @import("search.zig").Outcome;
const Failure = @import("classify.zig").Failure;
const flake = @import("flake.zig");

pub const Verdict = enum { culprit, flake, inconclusive };
pub const Role = enum { recheck, search };

pub const Probe = struct {
    commit: []const u8,
    role: Role,
    outcome: Outcome,
    attempts: u32,
    /// null when buck2 was killed or died of a signal.
    buck2_exit: ?u8,
    failed_targets: []const []const u8,
    seconds: u64,
};

pub const Infra = struct {
    commit: []const u8,
    buck2_exit: ?u8,
    excerpt: []const u8,
};

pub const FirstBad = struct {
    commit: []const u8,
    subject: []const u8,
    pr: ?u64,
};

pub const Report = struct {
    verdict: Verdict,
    good: []const u8,
    bad: []const u8,
    targets: []const []const u8,
    /// Set for `culprit` only.
    first_bad: ?FirstBad = null,
    /// The newest commit known to pass before the first bad one (or the
    /// candidates); null for `flake`.
    last_good: ?[]const u8 = null,
    /// Set for `inconclusive` only: the commits one of which is the first
    /// bad one.
    candidates: ?[]const []const u8 = null,
    probes: []const Probe,
    failures: []const Failure,
    infra: []const Infra,
    /// Set for `flake` when bisect measured it (`--flake-runs`): each target
    /// built K times at bad (flake.zig).
    flake_runs: ?flake.Measurement = null,
};

/// N of a subject `Merge pull request #N ...`, the subject GitHub gives a
/// pull request's merge commit; null for any other subject.
pub fn prNumber(subject: []const u8) ?u64 {
    const prefix = "Merge pull request #";
    if (!std.mem.startsWith(u8, subject, prefix)) return null;
    const rest = subject[prefix.len..];
    var end: usize = 0;
    while (end < rest.len and std.ascii.isDigit(rest[end])) end += 1;
    if (end == 0) return null;
    if (end < rest.len and rest[end] != ' ') return null;
    return std.fmt.parseInt(u64, rest[0..end], 10) catch null;
}

pub fn outcomeName(o: Outcome) []const u8 {
    return switch (o) {
        .pass => "PASS",
        .fail => "FAIL",
        .infra => "INFRA",
    };
}

/// Writes `r` as one line of JSON, in the field order README.md shows.
pub fn write(r: Report, out: anytype) !void {
    var w = std.json.writeStream(out, .{});
    defer w.deinit();
    try w.beginObject();
    try w.objectField("verdict");
    try w.write(@tagName(r.verdict));
    try w.objectField("good");
    try w.write(r.good);
    try w.objectField("bad");
    try w.write(r.bad);
    try w.objectField("targets");
    try w.write(r.targets);
    try w.objectField("first_bad");
    if (r.first_bad) |f| {
        try w.beginObject();
        try w.objectField("commit");
        try w.write(f.commit);
        try w.objectField("subject");
        try w.write(f.subject);
        try w.objectField("pr");
        try w.write(f.pr);
        try w.endObject();
    } else try w.write(null);
    try w.objectField("last_good");
    try w.write(r.last_good);
    if (r.candidates) |c| {
        try w.objectField("candidates");
        try w.write(c);
    }
    try w.objectField("probes");
    try w.beginArray();
    for (r.probes) |p| {
        try w.beginObject();
        try w.objectField("commit");
        try w.write(p.commit);
        try w.objectField("role");
        try w.write(@tagName(p.role));
        try w.objectField("outcome");
        try w.write(outcomeName(p.outcome));
        try w.objectField("attempts");
        try w.write(p.attempts);
        try w.objectField("buck2_exit");
        try w.write(p.buck2_exit);
        try w.objectField("failed_targets");
        try w.write(p.failed_targets);
        try w.objectField("seconds");
        try w.write(p.seconds);
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("failures");
    try w.beginArray();
    for (r.failures) |f| {
        try w.beginObject();
        try w.objectField("target");
        try w.write(f.target);
        try w.objectField("excerpt");
        try w.write(f.excerpt);
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("infra");
    try w.beginArray();
    for (r.infra) |x| {
        try w.beginObject();
        try w.objectField("commit");
        try w.write(x.commit);
        try w.objectField("buck2_exit");
        try w.write(x.buck2_exit);
        try w.objectField("excerpt");
        try w.write(x.excerpt);
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("flake_runs");
    if (r.flake_runs) |m| try flake.write(m, &w) else try w.write(null);
    try w.endObject();
}
