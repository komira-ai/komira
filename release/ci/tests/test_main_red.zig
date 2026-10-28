//! The cases of release/ci/main_red.zig (the main red alert, docs/ci.md, "The
//! main red alert"), run by the zig_test //release/ci/tests:test_main_red as a
//! build action: building the target is running them. The whole run against
//! a fake API is run_cases.zig, part of the same target.
//!
//! Each group pins one part, and names the defect it would catch:
//!
//! - log lines: the failing targets read from buck2's own failure output
//!   (fixtures/buck2_*.log, job logs of the farm build as the runner
//!   prints them), the key lines when no target line exists, timestamps,
//!   buck2 prefixes and colour codes stripped. A reader that keeps the
//!   timestamp, the configuration or a duplicate, reads `Waiting on` as a
//!   failure, or treats another tool's failure lines as buck2's is red.
//! - the range: which successful run is the last green (an ancestor of the
//!   red head), which one makes the red stale (a descendant), and the
//!   culprits (the first-parent commits of main after the last green,
//!   newest first, a pull request's number from the API or from the
//!   commit's subject).
//! - the issue: its title and the body contract an outside reader parses,
//!   line for line.
//! - the decision: open, comment or nothing on a red; close or keep on a
//!   green; nothing on a cancelled or skipped run, a manual run, another
//!   branch or a workflow that is not named.
//! - the command line and `gh`: the flags, and what a failed call means.
//! - terminal escapes: every `gh api` call passes --allow-escape-sequences
//!   (without it gh refuses a job log and the alert is silent), and no
//!   escape sequence of a log survives into the targets, the key lines or
//!   the issue body. A call without the flag, a stripper that knows only
//!   colours, or a body that takes a log's bytes as they are is red.
const std = @import("std");
const lib = @import("main_red_lib");
const t = std.testing;

const logs = lib.logs;
const range = lib.range;
const issue = lib.issue;

test {
    _ = @import("run_cases.zig");
}

const ACTION_LOG = @embedFile("fixtures/buck2_action_failed.log");
const GATED_LOG = @embedFile("fixtures/buck2_gated_test_failed.log");
const NO_TARGET_LOG = @embedFile("fixtures/buck2_no_target.log");

const HEAD = "a" ** 40;
const G1 = "1" ** 40;
const G2 = "2" ** 40;
const C1 = "c1" ++ "0" ** 38;
const C2 = "c2" ++ "0" ** 38;
const C3 = "c3" ++ "0" ** 38;
const RUN_URL = "https://github.com/komira-ai/komira/actions/runs/7";

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn json(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

// ---- log lines ---------------------------------------------------------------

test "an action failure from a real build log is named once, without its configuration" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try logs.failingTargets(arena.allocator(), ACTION_LOG, logs.MAX_TARGETS);
    try expectStrings(&.{"komira//tools/build/toolchains:busybox"}, got);
}

test "a gated test failure from a real log: the library and the test, in order, without duplicates" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try logs.failingTargets(arena.allocator(), GATED_LOG, logs.MAX_TARGETS);
    try expectStrings(&.{
        "komira//src/komira_proto_check:komira_proto_check",
        "komira//src/komira_proto_check:komira_proto_check:tests/test_held_numbers_are_unused.mojo",
    }, got);
}

test "a validation failure with and without backticks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log =
        "2026-10-05T22:38:08.9126771Z [2026-10-05T22:38:08.903+00:00] Validation for `komira//:docs " ++
        "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)` failed:\n" ++
        "Validation for komira//:public_boundary (cfg#1) failed:\n";
    const got = try logs.failingTargets(arena.allocator(), log, logs.MAX_TARGETS);
    try expectStrings(&.{ "komira//:docs", "komira//:public_boundary" }, got);
}

test "a line that only starts like a validation failure names nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = "Validation for komira//:docs passed\nValidation for  failed\nValidation for `` failed\nAction failed: \nGATED TEST FAILED:\n";
    const got = try logs.failingTargets(arena.allocator(), log, logs.MAX_TARGETS);
    try t.expectEqual(@as(usize, 0), got.len);
}

test "at most the limit of targets" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var log = std.ArrayList(u8).empty;
    for (0..9) |i| try log.print(arena.allocator(), "Action failed: //t:{d} (cfg)\n", .{i});
    const got = try logs.failingTargets(arena.allocator(), log.items, 3);
    try expectStrings(&.{ "//t:0", "//t:1", "//t:2" }, got);
}

test "waiting on a target is not a failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try logs.failingTargets(arena.allocator(), "Waiting on komira//a:b (cfg) -- mojo_build\nBUILD FAILED\n", logs.MAX_TARGETS);
    try t.expectEqual(@as(usize, 0), got.len);
}

test "the key lines of a log with targets are the target lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try logs.keyLogLines(arena.allocator(), ACTION_LOG, logs.MAX_LOG_LINES);
    try expectStrings(&.{
        "Action failed: komira//tools/build/toolchains:busybox " ++
            "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (download_file busybox)",
    }, got);
}

test "the key lines of a log without a target are buck2's BUILD FAILED and the runner's error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(usize, 0), (try logs.failingTargets(arena.allocator(), NO_TARGET_LOG, logs.MAX_TARGETS)).len);
    const got = try logs.keyLogLines(arena.allocator(), NO_TARGET_LOG, logs.MAX_LOG_LINES);
    try expectStrings(&.{ "BUILD FAILED", "##[error]Process completed with exit code 1." }, got);
}

test "another tool's failure lines are not key lines: only buck2's and the runner's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = "FAILED -- the channel's credential\nkci: FAILED (exit 4) stage prod\nsomething else failed\n";
    try t.expectEqual(@as(usize, 0), (try logs.keyLogLines(arena.allocator(), log, logs.MAX_LOG_LINES)).len);
}

test "strip removes the runner timestamp, buck2's timestamp and colour codes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("WARN x", try logs.stripLogLine(a, "2026-10-05T12:05:53.4100353Z [2026-10-05T12:05:53.408+00:00] \x1b[33m WARN\x1b[0m x"));
    try t.expectEqualStrings("Action failed: x", try logs.stripLogLine(a, "  Action failed: x  \r\n"));
    try t.expectEqualStrings("BUILD FAILED", try logs.stripLogLine(a, "2026-10-05T12:05:53Z BUILD FAILED"));
    // Not a timestamp: left alone.
    try t.expectEqualStrings("2026-10-05 Action failed: x", try logs.stripLogLine(a, "2026-10-05 Action failed: x"));
    try t.expectEqualStrings("[note] Action failed: x", try logs.stripLogLine(a, "[note] Action failed: x"));
}

test "failed jobs are named by job and step, the cancelled after the failed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const jobs = try json(a,
        \\[{"name":"build","conclusion":"success","steps":[]},
        \\ {"name":"prod","conclusion":"failure","steps":[
        \\   {"name":"the revision","conclusion":"success"},
        \\   {"name":"build //ci:all","conclusion":"failure"}]},
        \\ {"name":"validate","conclusion":"skipped","steps":[]},
        \\ {"name":"gamma","conclusion":"cancelled","steps":[]},
        \\ {"name":"slow","conclusion":"timed_out"}]
    );
    const failed = try logs.failedJobs(a, jobs.array.items);
    try t.expectEqual(@as(usize, 3), failed.len);
    try t.expectEqualStrings("job prod, step build //ci:all", try logs.jobLabel(a, failed[0]));
    try t.expectEqualStrings("job slow (timed_out)", try logs.jobLabel(a, failed[1]));
    try t.expectEqualStrings("job gamma (cancelled)", try logs.jobLabel(a, failed[2]));
}

// ---- the range -----------------------------------------------------------------

const Rel = struct {
    shas: []const []const u8,
    statuses: []const []const u8,

    pub fn relation(self: *Rel, sha: []const u8) ![]const u8 {
        for (self.shas, self.statuses) |s, st| if (std.mem.eql(u8, s, sha)) return st;
        return error.UnexpectedCompare;
    }
};

fn expectGreen(want: range.Green, got: range.Green) !void {
    switch (want) {
        .found => |w| try t.expectEqualStrings(w, got.found),
        .stale => |w| try t.expectEqualStrings(w, got.stale),
        .none => try t.expect(got == .none),
    }
}

test "the last green is the first ancestor success" {
    var rel = Rel{ .shas = &.{ G2, G1 }, .statuses = &.{ "diverged", "ahead" } };
    try expectGreen(.{ .found = G1 }, try range.lastGreen(HEAD, &.{ G2, G1 }, &rel));
}

test "a newer green descendant makes the red stale" {
    var rel = Rel{ .shas = &.{ G2, G1 }, .statuses = &.{ "behind", "ahead" } };
    try expectGreen(.{ .stale = G2 }, try range.lastGreen(HEAD, &.{ G2, G1 }, &rel));
}

test "the same commit green before is the last green, with no compare" {
    var rel = Rel{ .shas = &.{}, .statuses = &.{} };
    try expectGreen(.{ .found = HEAD }, try range.lastGreen(HEAD, &.{HEAD}, &rel));
    var same = Rel{ .shas = &.{G1}, .statuses = &.{"identical"} };
    try expectGreen(.{ .found = G1 }, try range.lastGreen(HEAD, &.{G1}, &same));
}

test "no success at all" {
    var rel = Rel{ .shas = &.{}, .statuses = &.{} };
    try expectGreen(.none, try range.lastGreen(HEAD, &.{}, &rel));
}

fn commit(a: std.mem.Allocator, sha: []const u8, parents: []const []const u8, subject: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    try out.print(a, "{{\"sha\":\"{s}\",\"parents\":[", .{sha});
    for (parents, 0..) |p, i| try out.print(a, "{s}{{\"sha\":\"{s}\"}}", .{ if (i > 0) "," else "", p });
    try out.print(a, "],\"commit\":{{\"message\":\"{s}\\n\\nbody\"}}}}", .{subject});
    return out.items;
}

fn commitList(a: std.mem.Allocator, texts: []const []const u8) ![]const std.json.Value {
    var out = std.ArrayList(std.json.Value).empty;
    for (texts) |x| try out.append(a, try json(a, x));
    return out.items;
}

/// The API's pull requests of a commit, from a table of JSON texts.
const Pulls = struct {
    a: std.mem.Allocator,
    shas: []const []const u8 = &.{},
    texts: []const []const u8 = &.{},

    pub fn of(self: Pulls, sha: []const u8) !std.json.Value {
        for (self.shas, self.texts) |s, x| if (std.mem.eql(u8, s, sha)) return json(self.a, x);
        return .null;
    }
};

test "culprits walk first parents, newest first" {
    // main: G1 <- C1 (merge of PR 11, second parent B1) <- C2 (squash, PR 12) <- C3 (merge of PR 13)
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b1 = "b1" ++ "0" ** 38;
    const commits = try commitList(a, &.{
        try commit(a, b1, &.{G1}, "a commit on the pull request's branch (#99)"),
        try commit(a, C1, &.{ G1, b1 }, "Merge pull request #11 from komira-ai/x"),
        try commit(a, C2, &.{C1}, "lib: a squashed change (#12)"),
        try commit(a, C3, &.{ C2, "f" ** 40 }, "Merge pull request #13 from komira-ai/y"),
    });
    try expectStrings(&.{ C3, C2, C1 }, try range.firstParentChain(a, commits, C3, G1));
    const got = try range.culprits(a, commits, C3, G1, Pulls{ .a = a });
    try t.expectEqualSlices(u64, &.{ 13, 12, 11 }, got);
}

test "culprits prefer the API's pull request and are listed once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const commits = try commitList(a, &.{
        try commit(a, C1, &.{G1}, "no number here"),
        try commit(a, C2, &.{C1}, "Merge pull request #12 from komira-ai/x"),
    });
    const pulls = Pulls{ .a = a, .shas = &.{C1}, .texts = &.{
        \\[{"number":12,"merged_at":"2026-10-06T00:00:00Z","base":{"ref":"main"}}]
    } };
    try t.expectEqualSlices(u64, &.{12}, try range.culprits(a, commits, C2, G1, pulls));
}

test "a pull request into another branch, or never merged, is not a culprit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const commits = try commitList(a, &.{try commit(a, C1, &.{G1}, "direct push")});
    const pulls = Pulls{ .a = a, .shas = &.{C1}, .texts = &.{
        \\[{"number":5,"merged_at":"x","base":{"ref":"other"}},{"number":6,"merged_at":null,"base":{"ref":"main"}}]
    } };
    try t.expectEqual(@as(usize, 0), (try range.culprits(a, commits, C1, G1, pulls)).len);
}

test "the subject's number is read only from the merge and squash forms" {
    try t.expectEqual(@as(?u64, 42), range.subjectPr("Merge pull request #42 from a/b"));
    try t.expectEqual(@as(?u64, 43), range.subjectPr("x: y (#43)"));
    try t.expectEqual(@as(?u64, null), range.subjectPr("refs #44 somewhere in the middle"));
    try t.expectEqual(@as(?u64, null), range.subjectPr("Merge pull request #45x from a/b"));
    try t.expectEqual(@as(?u64, null), range.subjectPr("x (#46) and more"));
    try t.expectEqual(@as(?u64, null), range.subjectPr("x (#)"));
    try t.expectEqual(@as(?u64, null), range.subjectPr("Merge pull request #99999999999999999999999 from a/b"));
}

// ---- the issue -------------------------------------------------------------------

test "the title is the first failing target" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("main red: //a:b", try issue.issueTitle(arena.allocator(), &.{ "//a:b", "//c:d" }));
}

test "the body contract, line for line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const body = try issue.issueBody(arena.allocator(), RUN_URL, HEAD, G1, &.{ 13, 12 }, &.{ "//a:b", "//c:d" }, &.{ "Action failed: //a:b (cfg)", "BUILD FAILED" });
    try t.expectEqualStrings(
        "Run: " ++ RUN_URL ++ "\nHead: " ++ HEAD ++ "\nLast green: " ++ G1 ++ "\nCulprits: #13, #12\n" ++
            "Failing: //a:b\nFailing: //c:d\nLog: Action failed: //a:b (cfg)\nLog: BUILD FAILED\n",
        body,
    );
}

test "the body's unknowns" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const body = try issue.issueBody(arena.allocator(), RUN_URL, HEAD, null, &.{}, &.{"job x"}, &.{});
    try t.expectEqualStrings("Run: " ++ RUN_URL ++ "\nHead: " ++ HEAD ++ "\nLast green: none\nCulprits: unknown\nFailing: job x\n", body);
}

test "body values are one line and bounded" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try issue.issueBody(a, RUN_URL, HEAD, G1, &.{}, &.{"//a:b\nFailing: forged"}, &.{"x" ** 1000});
    var keys = std.ArrayList([]const u8).empty;
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, body, "\n"), '\n');
    var log_len: usize = 0;
    while (lines.next()) |l| {
        const colon = std.mem.indexOfScalar(u8, l, ':').?;
        try keys.append(a, l[0..colon]);
        if (std.mem.startsWith(u8, l, "Log: ")) log_len = l.len;
    }
    try expectStrings(&.{ "Run", "Head", "Last green", "Culprits", "Failing", "Log" }, keys.items);
    try t.expectEqual(@as(usize, "Log: ".len + issue.MAX_VALUE), log_len);
    try t.expect(std.mem.indexOf(u8, body, "Failing: //a:b Failing: forged\n") != null);
}

test "a bounded value never cuts a multi-byte character" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    // 299 bytes of ASCII, then a 3-byte character crossing the limit.
    const text = "y" ** 299 ++ "\u{20ac}\u{20ac}";
    const v = try issue.value(arena.allocator(), text);
    try t.expectEqual(@as(usize, 299), v.len);
    try t.expect(std.unicode.utf8ValidateSlice(v));
}

test "heads are read back from bodies and comments" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const own = try issue.issueBody(a, RUN_URL, HEAD, null, &.{}, &.{"x"}, &.{});
    const got = try issue.headsIn(a, &.{ own, "Head: " ++ G2 ++ "\n", "Head: short", "Head: " ++ HEAD });
    try expectStrings(&.{ HEAD, G2 }, got);
}

test "a head mid-line is not read: only a line that IS `Head: <sha>`" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const body = try issue.issueBody(a, RUN_URL, HEAD, null, &.{}, &.{"//a:b Head: " ++ G1}, &.{"x Head: " ++ G2});
    try expectStrings(&.{HEAD}, try issue.headsIn(a, &.{body}));
    try expectStrings(&.{G2}, try issue.headsIn(a, &.{ "Log: Head: " ++ G1, "  Head: " ++ G2 }));
}

test "the fixed comment" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("Fixed: main is green at " ++ G1 ++ " (run " ++ RUN_URL ++ ")", try issue.fixedComment(arena.allocator(), G1, RUN_URL));
}

// ---- the decisions -----------------------------------------------------------------

fn runOf(a: std.mem.Allocator, name: []const u8, conclusion: []const u8, event: []const u8, branch: []const u8) !std.json.Value {
    const text = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"conclusion\":\"{s}\",\"event\":\"{s}\",\"head_branch\":\"{s}\"}}", .{ name, conclusion, event, branch });
    return json(a, text);
}

test "classify: red, green or ignore" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names: []const []const u8 = &.{"release"};
    try t.expectEqual(issue.Kind.red, issue.classify(try runOf(a, "release", "failure", "push", "main"), names));
    try t.expectEqual(issue.Kind.red, issue.classify(try runOf(a, "release", "timed_out", "push", "main"), names));
    try t.expectEqual(issue.Kind.red, issue.classify(try runOf(a, "release", "startup_failure", "push", "main"), names));
    try t.expectEqual(issue.Kind.green, issue.classify(try runOf(a, "release", "success", "push", "main"), names));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "release", "cancelled", "push", "main"), names));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "release", "skipped", "push", "main"), names));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "release", "failure", "workflow_dispatch", "main"), names));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "release", "success", "workflow_dispatch", "main"), names));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "release", "failure", "push", "other"), names));
}

test "classify reads only the named workflows, whatever their number" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one: []const []const u8 = &.{"old"};
    const two: []const []const u8 = &.{ "old", "new" };
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "new", "failure", "push", "main"), one));
    try t.expectEqual(issue.Kind.red, issue.classify(try runOf(a, "new", "failure", "push", "main"), two));
    try t.expectEqual(issue.Kind.green, issue.classify(try runOf(a, "old", "success", "push", "main"), two));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "coverage", "failure", "push", "main"), two));
    try t.expectEqual(issue.Kind.ignore, issue.classify(try runOf(a, "olde", "failure", "push", "main"), two));
}

test "a red opens when none is open, else comments on the oldest" {
    try t.expectEqual(issue.RedAction.open, issue.decideRed(&.{}));
    try t.expectEqual(@as(u64, 4), issue.decideRed(&.{ 9, 4 }).comment);
}

const Contains = struct {
    heads: []const []const u8,
    answers: []const ?bool,

    pub fn of(self: Contains, head: []const u8) !?bool {
        for (self.heads, self.answers) |h, ans| if (std.mem.eql(u8, h, head)) return ans;
        return error.UnexpectedHead;
    }
};

test "a green closes only an issue whose every head it contains" {
    const c = Contains{ .heads = &.{ G1, G2 }, .answers = &.{ true, false } };
    try t.expect(!try issue.keepsOpen(&.{G1}, c));
    try t.expect(try issue.keepsOpen(&.{ G1, G2 }, c));
    try t.expect(!try issue.keepsOpen(&.{}, c));
}

test "a green skips a head it cannot place" {
    // null: the compare API does not know the head (404) or it is not on
    // main's line (diverged); it neither blocks nor counts.
    try t.expect(!try issue.keepsOpen(&.{ G1, G2 }, Contains{ .heads = &.{ G1, G2 }, .answers = &.{ true, null } }));
    try t.expect(try issue.keepsOpen(&.{ G1, G2 }, Contains{ .heads = &.{ G1, G2 }, .answers = &.{ false, null } }));
}

test "after a race every issue but the oldest is a duplicate" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const d = try issue.duplicates(arena.allocator(), &.{ 8, 3, 5 });
    try t.expectEqual(@as(?u64, 3), d.oldest);
    try t.expectEqualSlices(u64, &.{ 5, 8 }, d.others);
    const one = try issue.duplicates(arena.allocator(), &.{3});
    try t.expectEqual(@as(?u64, 3), one.oldest);
    try t.expectEqual(@as(usize, 0), one.others.len);
    try t.expectEqual(@as(?u64, null), (try issue.duplicates(arena.allocator(), &.{})).oldest);
}

// ---- the command line and gh ----------------------------------------------------------

test "every flag, the workflow flag repeated" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const r = try lib.args.parseArgs(arena.allocator(), &.{
        "--repo", "komira-ai/komira", "--run-id", "42", "--workflow", "old", "--workflow", "new", "--dry-run", "--gh", "/x/gh",
    });
    try t.expectEqualStrings("komira-ai/komira", r.repo);
    try t.expectEqual(@as(u64, 42), r.run_id);
    try expectStrings(&.{ "old", "new" }, r.workflows);
    try t.expect(r.dry_run);
    try t.expectEqualStrings("/x/gh", r.gh);
    const plain = try lib.args.parseArgs(arena.allocator(), &.{ "--repo", "o/r", "--run-id", "1", "--workflow", "w" });
    try t.expect(!plain.dry_run);
    try t.expectEqualStrings("gh", plain.gh);
}

test "each refusal is a usage error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const P = lib.args.parseArgs;
    try t.expectError(error.NoWorkflow, P(a, &.{ "--repo", "o/r", "--run-id", "1" }));
    try t.expectError(error.EmptyWorkflow, P(a, &.{ "--repo", "o/r", "--run-id", "1", "--workflow", " " }));
    try t.expectError(error.MissingRepo, P(a, &.{ "--run-id", "1", "--workflow", "w" }));
    try t.expectError(error.BadRepo, P(a, &.{ "--repo", "o", "--run-id", "1", "--workflow", "w" }));
    try t.expectError(error.BadRepo, P(a, &.{ "--repo", "o/r/x", "--run-id", "1", "--workflow", "w" }));
    try t.expectError(error.BadRepo, P(a, &.{ "--repo", "o/r;x", "--run-id", "1", "--workflow", "w" }));
    try t.expectError(error.MissingRunId, P(a, &.{ "--repo", "o/r", "--workflow", "w" }));
    try t.expectError(error.BadRunId, P(a, &.{ "--repo", "o/r", "--run-id", "x", "--workflow", "w" }));
    try t.expectError(error.MissingValue, P(a, &.{ "--repo", "o/r", "--run-id" }));
    try t.expectError(error.UnknownArgument, P(a, &.{ "--repo", "o/r", "--run-id", "1", "--workflow", "w", "--kci" }));
}

test "gh: a 404 is not found, a 422 already_exists is already exists, anything else is retried" {
    try t.expectEqual(lib.gh.Failure.not_found, lib.gh.classify("", "gh: Not Found (HTTP 404)\n"));
    try t.expectEqual(lib.gh.Failure.already_exists, lib.gh.classify(
        "{\"errors\":[{\"code\":\"already_exists\"}]}",
        "gh: Validation Failed (HTTP 422)\n",
    ));
    try t.expectEqual(lib.gh.Failure.already_exists, lib.gh.classify("", "HTTP 422 already_exists"));
    try t.expectEqual(lib.gh.Failure.other, lib.gh.classify("", "gh: Validation Failed (HTTP 422)\n"));
    try t.expectEqual(lib.gh.Failure.other, lib.gh.classify("already_exists", "HTTP 500"));
    try t.expectEqual(lib.gh.Failure.other, lib.gh.classify("", "HTTP 403"));
}

test "gh: a command that keeps failing is an error after its attempts; one that succeeds empty is null" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = std.Io.Writer.Allocating.init(a);
    var failing = lib.gh.GhApi{ .a = a, .gh = "false", .out = &sink.writer, .backoff_ms = 0 };
    try t.expectError(error.GhFailed, failing.get("repos/o/r"));
    var empty = lib.gh.GhApi{ .a = a, .gh = "true", .out = &sink.writer, .backoff_ms = 0 };
    try t.expect((try empty.get("repos/o/r")) == .null);
    try t.expectEqualStrings("", try empty.text("repos/o/r"));
}

test "gh: a dry run prints the write and sends nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = std.Io.Writer.Allocating.init(a);
    // `false` would fail any real call.
    var api = lib.gh.GhApi{ .a = a, .gh = "false", .dry_run = true, .out = &sink.writer, .backoff_ms = 0 };
    const answer = try api.write("POST", "repos/o/r/issues", "{\"title\":\"x\"}");
    try t.expectEqual(@as(i64, 0), answer.object.get("number").?.integer);
    try t.expectEqualStrings("main_red: DRY RUN POST repos/o/r/issues {\"title\":\"x\"}\n", sink.written());
}

// ---- terminal escape sequences -----------------------------------------------

/// A job log as a terminal-aware tool writes it: colours (SGR with several
/// parameters), a private-mode CSI (`?25l` hides the cursor), a cursor move
/// and an erase, and a window-title OSC ended by BEL, each in front of the
/// text a reader matches on.
const ESCAPE_LOG =
    "2026-10-05T12:06:22.3345183Z [2026-10-05T12:06:22.334+00:00] \x1b[31mAction failed:\x1b[0m komira//src/a:a (komira//p:linux#03cc) (compile)\n" ++
    "2026-10-05T12:06:23.0000000Z \x1b[?25l\x1b[2K\x1b[1GGATED TEST FAILED: komira//src/b:b:tests/t.mojo\x1b[?25h\n" ++
    "2026-10-05T12:06:24.0000000Z \x1b]0;buck2 title\x07\x1b[1;38;5;196mValidation for `komira//v:v` failed\x1b[m\n" ++
    "2026-10-05T12:06:25.0000000Z BUILD FAILED \x1b(B\x1b[0m\x01end\n";

test "a log with terminal escapes still names its failing targets, and none keeps an ESC byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectStrings(&.{ "komira//src/a:a", "komira//src/b:b:tests/t.mojo", "komira//v:v" }, try logs.failingTargets(a, ESCAPE_LOG, logs.MAX_TARGETS));
    const keys = try logs.keyLogLines(a, ESCAPE_LOG, 5);
    try t.expectEqual(@as(usize, 3), keys.len);
    for (keys) |k| try t.expect(std.mem.indexOfScalar(u8, k, 0x1b) == null);
    try t.expectEqualStrings("BUILD FAILED end", try logs.stripLogLine(a, "2026-10-05T12:06:25.0000000Z BUILD FAILED \x1b(B\x1b[0m\x01end"));
    // A lone ESC at the end and an unterminated OSC drop out too.
    try t.expectEqualStrings("x", try logs.stripLogLine(a, "x\x1b"));
    try t.expectEqualStrings("x", try logs.stripLogLine(a, "x\x1b]0;never ended"));
}

test "no text from a log puts an ESC byte in the issue body, whatever it is" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Straight from the log, through the issue.
    const failing = try logs.failingTargets(a, ESCAPE_LOG, logs.MAX_TARGETS);
    const keys = try logs.keyLogLines(a, ESCAPE_LOG, 5);
    const body = try issue.issueBody(a, RUN_URL, HEAD, null, &.{}, failing, keys);
    try t.expect(std.mem.indexOfScalar(u8, body, 0x1b) == null);
    try t.expect(std.mem.indexOf(u8, body, "Failing: komira//src/a:a\n") != null);
    // And a value given with escapes, as a last line of defence.
    const v = try issue.value(a, "\x1b[31ma\x1b[0m \x01 b");
    try t.expect(std.mem.indexOfScalar(u8, v, 0x1b) == null);
    try t.expectEqualStrings("[31ma[0m b", v);
    const title = try issue.issueTitle(a, &.{"\x1bx"});
    try t.expect(std.mem.indexOfScalar(u8, title, 0x1b) == null);
}

test "gh: every call is `gh api --allow-escape-sequences` and then its arguments" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The three shapes of call: a read, a log read, a write from stdin.
    const calls = [_][]const []const u8{
        &.{"repos/o/r/actions/runs/7"},
        &.{"repos/o/r/actions/jobs/70/logs"},
        &.{ "--method", "POST", "repos/o/r/issues", "--input", "-" },
    };
    for (calls) |args| {
        const argv = try lib.gh.buildArgv(a, "gh", args);
        try t.expectEqual(args.len + 3, argv.len);
        try t.expectEqualStrings("gh", argv[0]);
        try t.expectEqualStrings("api", argv[1]);
        try t.expectEqualStrings("--allow-escape-sequences", argv[2]);
        try expectStrings(args, argv[3..]);
    }
}

test "gh: a failed call remembers which call it was, for the message" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var sink = std.Io.Writer.Allocating.init(a);
    var api = lib.gh.GhApi{ .a = a, .gh = "false", .out = &sink.writer, .backoff_ms = 0 };
    try t.expectError(error.GhFailed, api.text("repos/o/r/actions/jobs/70/logs"));
    try t.expectEqualStrings("repos/o/r/actions/jobs/70/logs", api.last_call);
}
