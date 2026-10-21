//! The whole run of the alert against a fake API (part of
//! //release/ci/tests:test_main_red, see test_main_red.zig): what is read,
//! what is written, in what order. A path the fake has no answer for is a 404,
//! so a read the alert should not make (another workflow's runs, another
//! attempt's jobs, a compare it does not need) fails the case.
const std = @import("std");
const lib = @import("main_red_lib");
const t = std.testing;

const ACTION_LOG = @embedFile("fixtures/buck2_action_failed.log");
const NO_TARGET_LOG = @embedFile("fixtures/buck2_no_target.log");

const HEAD = "a" ** 40;
const G1 = "1" ** 40;
const G2 = "2" ** 40;
const RUN_URL = "https://github.com/komira-ai/komira/actions/runs/7";
const R = "repos/o/r";
const BOT = "github-actions[bot]";
const ISSUES = R ++ "/issues?labels=main-red&state=open&per_page=100";
const RELEASE_RUNS = R ++ "/actions/workflows/5/runs?branch=main&event=push&status=success&per_page=30";
const WORKFLOWS = R ++ "/actions/workflows?per_page=100";

const Entry = struct {
    path: []const u8,
    answers: []const []const u8,
    /// One answer per read, in order; else the first answer, every time.
    sequence: bool,
    next: usize = 0,
};

const Write = struct { method: []const u8, path: []const u8, body: []const u8 };

const Fake = struct {
    a: std.mem.Allocator,
    workflows: []const []const u8 = &.{"release"},
    entries: std.ArrayList(Entry) = .empty,
    writes: std.ArrayList(Write) = .empty,
    sink: std.Io.Writer.Allocating,
    /// A POST of the label answers `already_exists`: another run made it first.
    label_raced: bool = false,

    fn init(a: std.mem.Allocator) Fake {
        return .{ .a = a, .sink = std.Io.Writer.Allocating.init(a) };
    }

    /// `path` answers `answer`, every time; a later put of a path replaces it.
    fn put(self: *Fake, path: []const u8, reply: []const u8) !void {
        try self.entries.append(self.a, .{ .path = path, .answers = try self.a.dupe([]const u8, &.{reply}), .sequence = false });
    }

    fn putSeq(self: *Fake, path: []const u8, answers: []const []const u8) !void {
        try self.entries.append(self.a, .{ .path = path, .answers = answers, .sequence = true });
    }

    fn putf(self: *Fake, comptime path_fmt: []const u8, path_args: anytype, reply: []const u8) !void {
        try self.put(try std.fmt.allocPrint(self.a, path_fmt, path_args), reply);
    }

    /// `path` has no answer from now on: the fake's 404.
    fn remove(self: *Fake, path: []const u8) void {
        var i: usize = 0;
        while (i < self.entries.items.len) {
            if (std.mem.eql(u8, self.entries.items[i].path, path)) {
                _ = self.entries.orderedRemove(i);
            } else i += 1;
        }
    }

    fn answer(self: *Fake, path: []const u8) ![]const u8 {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const e = &self.entries.items[i];
            if (!std.mem.eql(u8, e.path, path)) continue;
            if (!e.sequence) return e.answers[0];
            if (e.next >= e.answers.len) return error.AnswersExhausted;
            e.next += 1;
            return e.answers[e.next - 1];
        }
        return error.NotFound;
    }

    pub fn get(self: *Fake, path: []const u8) anyerror!std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.a, try self.answer(path), .{});
    }

    pub fn text(self: *Fake, path: []const u8) anyerror![]const u8 {
        return self.answer(path);
    }

    pub fn write(self: *Fake, method: []const u8, path: []const u8, body: []const u8) anyerror!std.json.Value {
        if (self.label_raced and std.mem.endsWith(u8, path, "/labels")) return error.AlreadyExists;
        try self.writes.append(self.a, .{ .method = method, .path = path, .body = body });
        const reply: []const u8 = if (std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, path, "/issues")) "{\"number\": 21}" else "{}";
        return std.json.parseFromSliceLeaky(std.json.Value, self.a, reply, .{});
    }

    fn run(self: *Fake, run_id: u64) !void {
        const alert = lib.run.Alert(Fake){
            .a = self.a,
            .api = self,
            .cfg = .{ .repo = "o/r", .workflows = self.workflows },
            .out = &self.sink.writer,
        };
        try alert.run(run_id);
    }

    fn expectWrite(self: *Fake, i: usize, method: []const u8, path: []const u8, body: []const u8) !void {
        try t.expect(i < self.writes.items.len);
        const w = self.writes.items[i];
        try t.expectEqualStrings(method, w.method);
        try t.expectEqualStrings(path, w.path);
        try t.expectEqualStrings(body, w.body);
    }

    fn expectNoWrites(self: *Fake) !void {
        try t.expectEqual(@as(usize, 0), self.writes.items.len);
    }
};

/// `text` as the string of a JSON body, newlines escaped.
fn esc(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, text, "\n", "\\n");
}

fn runJson(a: std.mem.Allocator, id: u64, name: []const u8, conclusion: []const u8, sha: []const u8, attempt: u32) ![]const u8 {
    return std.fmt.allocPrint(a,
        \\{{"id":{d},"name":"{s}","conclusion":"{s}","event":"push","head_branch":"main","head_sha":"{s}","html_url":"https://github.com/komira-ai/komira/actions/runs/{d}","run_attempt":{d}}}
    , .{ id, name, conclusion, sha, id, attempt });
}

const EXPECTED_BODY =
    "Run: " ++ RUN_URL ++ "\nHead: " ++ HEAD ++ "\nLast green: " ++ G1 ++ "\nCulprits: #13\n" ++
    "Failing: komira//tools/build/toolchains:busybox\n" ++
    "Log: Action failed: komira//tools/build/toolchains:busybox " ++
    "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (download_file busybox)\n";

const BUILD_JOBS =
    \\{"jobs":[{"id":70,"name":"build","conclusion":"failure","steps":[{"name":"build //ci:all","conclusion":"failure"}]}]}
;

/// A red run 7 of the workflow `release` (id 5): its jobs, the log, the last
/// green G1 one merge behind it, and the open issues.
fn redWorld(f: *Fake, open_issues: []const u8, label: bool) !void {
    try f.put(R ++ "/actions/runs/7", try runJson(f.a, 7, "release", "failure", HEAD, 1));
    try f.put(R ++ "/actions/runs/7/attempts/1/jobs?per_page=100", BUILD_JOBS);
    try f.put(R ++ "/actions/jobs/70/logs", ACTION_LOG);
    try f.put(WORKFLOWS,
        \\{"workflows":[{"id":5,"name":"release"},{"id":6,"name":"coverage"}]}
    );
    try f.put(RELEASE_RUNS, "{\"workflow_runs\":[{\"head_sha\":\"" ++ G1 ++ "\",\"created_at\":\"2026-10-05T00:00:00Z\"}]}");
    try f.put(R ++ "/compare/" ++ G1 ++ "..." ++ HEAD ++ "?per_page=100&page=1",
        "{\"status\":\"ahead\",\"total_commits\":1,\"commits\":[{\"sha\":\"" ++ HEAD ++ "\",\"parents\":[{\"sha\":\"" ++ G1 ++
            "\"}],\"commit\":{\"message\":\"Merge pull request #13 from x/y\"}}]}");
    try f.put(R ++ "/commits/" ++ HEAD ++ "/pulls", "[]");
    try f.put(ISSUES, open_issues);
    if (label) try f.put(R ++ "/labels/main-red", "{\"name\":\"main-red\"}");
}

fn expectedIssueBody(a: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"title\":\"main red: komira//tools/build/toolchains:busybox\",\"body\":\"{s}\",\"labels\":[\"main-red\"]}}", .{try esc(a, EXPECTED_BODY)});
}

fn expectedComment(a: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"body\":\"{s}\"}}", .{try esc(a, body)});
}

test "a red with no open issue creates the label and the issue" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", false);
    try f.run(7);
    try t.expectEqual(@as(usize, 2), f.writes.items.len);
    try f.expectWrite(0, "POST", R ++ "/labels", "{\"name\":\"main-red\",\"color\":\"b60205\",\"description\":\"main's build failed (docs/ci.md, main_red.yml)\"}");
    try f.expectWrite(1, "POST", R ++ "/issues", try expectedIssueBody(a));
    try t.expect(std.mem.indexOf(u8, f.sink.written(), "main_red: opened #21\n") != null);
}

test "a red with an open issue comments on the oldest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[{\"number\":9,\"body\":\"x\"},{\"number\":4,\"body\":\"Head: " ++ G1 ++ "\"}]", true);
    try f.run(7);
    try t.expectEqual(@as(usize, 1), f.writes.items.len);
    try f.expectWrite(0, "POST", R ++ "/issues/4/comments", try expectedComment(a, EXPECTED_BODY));
}

test "a pull request is not an open issue: the issues API lists both" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[{\"number\":2,\"pull_request\":{\"url\":\"u\"}}]", true);
    try f.run(7);
    try f.expectWrite(0, "POST", R ++ "/issues", try expectedIssueBody(a));
}

test "a raced second issue is closed as the duplicate of the oldest" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    // Empty when this run looks; after it creates #21, another run's #3 is there too.
    try f.putSeq(ISSUES, &.{ "[]", "[{\"number\":21},{\"number\":3}]" });
    try f.run(7);
    try t.expectEqual(@as(usize, 4), f.writes.items.len);
    try f.expectWrite(0, "POST", R ++ "/issues", try expectedIssueBody(a));
    try f.expectWrite(1, "POST", R ++ "/issues/3/comments", try expectedComment(a, EXPECTED_BODY));
    try f.expectWrite(2, "POST", R ++ "/issues/21/comments", "{\"body\":\"Duplicate of #3\"}");
    try f.expectWrite(3, "PATCH", R ++ "/issues/21", "{\"state\":\"closed\",\"state_reason\":\"not_planned\"}");
}

test "a created issue that is the oldest is not closed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.putSeq(ISSUES, &.{ "[]", "[{\"number\":21},{\"number\":30}]" });
    try f.run(7);
    try t.expectEqual(@as(usize, 1), f.writes.items.len);
}

test "a red already fixed by a newer green writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.put(RELEASE_RUNS, "{\"workflow_runs\":[{\"head_sha\":\"" ++ G2 ++ "\"}]}");
    try f.put(R ++ "/compare/" ++ G2 ++ "..." ++ HEAD ++ "?per_page=100&page=1", "{\"status\":\"behind\",\"total_commits\":0,\"commits\":[]}");
    try f.run(7);
    try f.expectNoWrites();
}

test "a red with no last green says culprits unknown" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.put(RELEASE_RUNS, "{\"workflow_runs\":[]}");
    try f.run(7);
    const want =
        "Run: " ++ RUN_URL ++ "\nHead: " ++ HEAD ++ "\nLast green: none\nCulprits: unknown\n" ++
        "Failing: komira//tools/build/toolchains:busybox\n" ++
        "Log: Action failed: komira//tools/build/toolchains:busybox " ++
        "(komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (download_file busybox)\n";
    try f.expectWrite(0, "POST", R ++ "/issues", try std.fmt.allocPrint(a, "{{\"title\":\"main red: komira//tools/build/toolchains:busybox\",\"body\":\"{s}\",\"labels\":[\"main-red\"]}}", .{try esc(a, want)}));
}

test "a range longer than one page is read to its end" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    // Page 1 holds the base's side of the range only; the head and the merge
    // that names the pull request are on page 2.
    try f.put(R ++ "/compare/" ++ G1 ++ "..." ++ HEAD ++ "?per_page=100&page=1",
        "{\"status\":\"ahead\",\"total_commits\":2,\"commits\":[{\"sha\":\"" ++ "c1" ++ "0" ** 38 ++ "\",\"parents\":[{\"sha\":\"" ++ G1 ++
            "\"}],\"commit\":{\"message\":\"x (#12)\"}}]}");
    try f.put(R ++ "/compare/" ++ G1 ++ "..." ++ HEAD ++ "?per_page=100&page=2",
        "{\"status\":\"ahead\",\"total_commits\":2,\"commits\":[{\"sha\":\"" ++ HEAD ++ "\",\"parents\":[{\"sha\":\"" ++ "c1" ++ "0" ** 38 ++
            "\"}],\"commit\":{\"message\":\"Merge pull request #13 from x/y\"}}]}");
    try f.run(7);
    try t.expect(std.mem.indexOf(u8, f.writes.items[0].body, "Culprits: #13, #12\\n") != null);
}

fn greenWorld(f: *Fake, issue_body: []const u8, comments: []const u8, compares: []const [2][]const u8) !void {
    try f.put(R ++ "/actions/runs/8", try runJson(f.a, 8, "release", "success", G2, 1));
    try f.put(ISSUES, try std.fmt.allocPrint(f.a, "[{{\"number\":4,\"body\":\"{s}\"}}]", .{issue_body}));
    try f.put(R ++ "/issues/4/comments?per_page=100", comments);
    for (compares) |c| {
        try f.putf(R ++ "/compare/{s}..." ++ G2 ++ "?per_page=1&page=1", .{c[0]}, try std.fmt.allocPrint(f.a, "{{\"status\":\"{s}\"}}", .{c[1]}));
    }
}

const CLOSED_COMMENT = "{\"body\":\"Fixed: main is green at " ++ G2 ++ " (run https://github.com/komira-ai/komira/actions/runs/8)\"}";
const CLOSED_PATCH = "{\"state\":\"closed\",\"state_reason\":\"completed\"}";

fn bot(comptime head: []const u8) []const u8 {
    return "[{\"user\":{\"login\":\"" ++ BOT ++ "\"},\"body\":\"Head: " ++ head ++ "\\n\"}]";
}

test "a green closes with the fixed comment" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try greenWorld(&f, "Run: x\\nHead: " ++ HEAD ++ "\\n", bot(G1), &.{ .{ HEAD, "ahead" }, .{ G1, "ahead" } });
    try f.run(8);
    try t.expectEqual(@as(usize, 2), f.writes.items.len);
    try f.expectWrite(0, "POST", R ++ "/issues/4/comments", CLOSED_COMMENT);
    try f.expectWrite(1, "PATCH", R ++ "/issues/4", CLOSED_PATCH);
}

test "a green that does not contain a recorded head keeps the issue open" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try greenWorld(&f, "Head: " ++ HEAD ++ "\\n", "[]", &.{.{ HEAD, "behind" }});
    try f.run(8);
    try f.expectNoWrites();
    try t.expect(std.mem.indexOf(u8, f.sink.written(), "main_red: #4 records a head") != null);
}

test "a green ignores heads in comments by anyone but the workflow" {
    // A public comment can say anything: a head main does not contain
    // (`behind`) or one no API knows must not keep the issue open.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    const comments = "[{\"user\":{\"login\":\"someone\"},\"body\":\"Head: " ++ G1 ++ "\\n\"}," ++
        "{\"user\":{\"login\":\"github-actions\"},\"body\":\"Head: " ++ "0f" ** 20 ++ "\\n\"}]";
    try greenWorld(&f, "Head: " ++ HEAD ++ "\\n", comments, &.{ .{ HEAD, "ahead" }, .{ G1, "behind" } });
    try f.run(8);
    try t.expectEqual(@as(usize, 2), f.writes.items.len);
    try f.expectWrite(1, "PATCH", R ++ "/issues/4", CLOSED_PATCH);
}

test "a green skips a recorded head the API does not know" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    // No compare answer for the unknown head: the fake's 404.
    try greenWorld(&f, "Head: " ++ HEAD ++ "\\n", bot("0f" ** 20), &.{.{ HEAD, "ahead" }});
    try f.run(8);
    try t.expectEqual(@as(usize, 2), f.writes.items.len);
    try t.expect(std.mem.indexOf(u8, f.sink.written(), "is unknown against") != null);
}

test "a green skips a recorded head off main's line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try greenWorld(&f, "Head: " ++ HEAD ++ "\\n", bot(G1), &.{ .{ HEAD, "ahead" }, .{ G1, "diverged" } });
    try f.run(8);
    try t.expectEqual(@as(usize, 2), f.writes.items.len);
    try t.expect(std.mem.indexOf(u8, f.sink.written(), "is diverged against") != null);
}

test "a green keeps the issue for a workflow-recorded head it does not contain" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try greenWorld(&f, "Head: " ++ HEAD ++ "\\n", bot(G1), &.{ .{ HEAD, "ahead" }, .{ G1, "behind" } });
    try f.run(8);
    try f.expectNoWrites();
}

test "a rerun reads its own attempt's jobs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.put(R ++ "/actions/runs/7", try runJson(a, 7, "release", "failure", HEAD, 2));
    // Attempt 1 failed elsewhere; attempt 2 is the run that just ended.
    try f.put(R ++ "/actions/runs/7/attempts/1/jobs?per_page=100",
        \\{"jobs":[{"id":69,"name":"gamma","conclusion":"failure","steps":[{"name":"publish","conclusion":"failure"}]}]}
    );
    try f.put(R ++ "/actions/runs/7/attempts/2/jobs?per_page=100", BUILD_JOBS);
    try f.put(R ++ "/actions/jobs/69/logs", "Action failed: //wrong:attempt (cfg)\n");
    try f.run(7);
    try f.expectWrite(0, "POST", R ++ "/issues", try expectedIssueBody(a));
}

test "a label another run just created is not an error" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", false);
    f.label_raced = true;
    try f.run(7);
    try t.expectEqual(@as(usize, 1), f.writes.items.len);
    try f.expectWrite(0, "POST", R ++ "/issues", try expectedIssueBody(a));
}

test "a cancelled run writes nothing and reads nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try f.put(R ++ "/actions/runs/9", try runJson(a, 9, "release", "cancelled", HEAD, 1));
    try f.run(9);
    try f.expectNoWrites();
}

test "a run of a workflow that is not named writes nothing and reads nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try f.put(R ++ "/actions/runs/9", try runJson(a, 9, "coverage", "failure", HEAD, 1));
    try f.run(9);
    try f.expectNoWrites();
}

test "a red with no failed job names the workflow" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.put(R ++ "/actions/runs/7/attempts/1/jobs?per_page=100",
        \\{"jobs":[{"id":71,"name":"build","conclusion":"success","steps":[]},{"id":72,"name":"prod","conclusion":"skipped","steps":[]}]}
    );
    try f.run(7);
    try t.expect(std.mem.indexOf(u8, f.writes.items[0].body, "\"title\":\"main red: workflow release (no job failed: a job could not start)\"") != null);
}

test "a red whose log names no target names the failed job and step, and the key lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    try f.put(R ++ "/actions/jobs/70/logs", NO_TARGET_LOG);
    try f.run(7);
    const body = f.writes.items[0].body;
    try t.expect(std.mem.indexOf(u8, body, "\"title\":\"main red: job build, step build //ci:all\"") != null);
    try t.expect(std.mem.indexOf(u8, body, "Failing: job build, step build //ci:all\\nLog: BUILD FAILED\\nLog: ##[error]Process completed with exit code 1.\\n") != null);
}

test "a job whose log is gone (404) still names its job and step" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try redWorld(&f, "[]", true);
    f.remove(R ++ "/actions/jobs/70/logs");
    try f.run(7);
    try t.expect(std.mem.indexOf(u8, f.writes.items[0].body, "\"title\":\"main red: job build, step build //ci:all\"") != null);
}

/// Two workflows named: `old` (id 5) and `new` (id 6); a third, `coverage`
/// (id 7), is not and has no runs the fake answers.
fn twoWorkflows(f: *Fake, old_at: []const u8, new_at: []const u8) !void {
    f.workflows = &.{ "old", "new" };
    try redWorld(f, "[]", true);
    try f.put(R ++ "/actions/runs/7", try runJson(f.a, 7, "new", "failure", HEAD, 1));
    try f.put(WORKFLOWS,
        \\{"workflows":[{"id":5,"name":"old"},{"id":6,"name":"new"},{"id":7,"name":"coverage"}]}
    );
    try f.put(RELEASE_RUNS, try std.fmt.allocPrint(f.a, "{{\"workflow_runs\":[{{\"head_sha\":\"{s}\",\"created_at\":\"{s}\"}}]}}", .{ G1, old_at }));
    try f.put(R ++ "/actions/workflows/6/runs?branch=main&event=push&status=success&per_page=30", try std.fmt.allocPrint(f.a, "{{\"workflow_runs\":[{{\"head_sha\":\"{s}\",\"created_at\":\"{s}\"}}]}}", .{ G2, new_at }));
}

test "the last green is the newest success across the named workflows (the old one's)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try twoWorkflows(&f, "2026-10-06T00:00:00Z", "2026-10-05T00:00:00Z");
    try f.run(7);
    // G1 is the last green and an ancestor: G2's compare was never asked for.
    try f.expectWrite(0, "POST", R ++ "/issues", try expectedIssueBody(a));
}

test "the last green is the newest success across the named workflows (the new one's)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var f = Fake.init(a);
    try twoWorkflows(&f, "2026-10-05T00:00:00Z", "2026-10-06T00:00:00Z");
    try f.put(R ++ "/compare/" ++ G2 ++ "..." ++ HEAD ++ "?per_page=100&page=1",
        "{\"status\":\"ahead\",\"total_commits\":1,\"commits\":[{\"sha\":\"" ++ HEAD ++ "\",\"parents\":[{\"sha\":\"" ++ G2 ++
            "\"}],\"commit\":{\"message\":\"Merge pull request #14 from x/y\"}}]}");
    try f.run(7);
    try t.expect(std.mem.indexOf(u8, f.writes.items[0].body, "Last green: " ++ G2 ++ "\\nCulprits: #14\\n") != null);
}
