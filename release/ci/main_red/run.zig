//! The run of the alert: reads one completed run and what it calls for from
//! the API, and writes the issue, the comment or the closes. The only part
//! that talks to the API, through the object it is given:
//!
//!   get(path)                  the JSON answer (`.null` when empty); error.NotFound on a 404
//!   text(path)                 the answer as text; error.NotFound on a 404
//!   write(method, path, body)  the JSON answer; error.AlreadyExists on a 422 `already_exists`
//!
//! Every function of it returns `anyerror!`.
const std = @import("std");
const logs = @import("logs.zig");
const range = @import("range.zig");
const issue = @import("issue.zig");

pub const Config = struct {
    /// owner/name
    repo: []const u8,
    /// The names of the workflows whose runs on main this alert reads: a run
    /// of any other workflow is ignored, and the last green is searched in
    /// the push runs of these.
    workflows: []const []const u8,
};

pub fn str(v: ?std.json.Value) []const u8 {
    const x = v orelse return "";
    return switch (x) {
        .string => |s| s,
        else => "",
    };
}

pub fn field(obj: std.json.Value, name: []const u8) ?std.json.Value {
    return switch (obj) {
        .object => |o| o.get(name),
        else => null,
    };
}

fn items(v: ?std.json.Value) []const std.json.Value {
    const x = v orelse return &.{};
    return switch (x) {
        .array => |arr| arr.items,
        else => &.{},
    };
}

fn int(v: ?std.json.Value, default: u64) u64 {
    const x = v orelse return default;
    return switch (x) {
        .integer => |i| if (i >= 0) @intCast(i) else default,
        else => default,
    };
}

/// One field of a JSON request body: a string, or a list of strings.
pub const Field = struct {
    key: []const u8,
    string: ?[]const u8 = null,
    list: ?[]const []const u8 = null,
};

pub fn jsonBody(a: std.mem.Allocator, fields: []const Field) ![]const u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var w: std.json.Stringify = .{ .writer = &buf.writer };
    try w.beginObject();
    for (fields) |f| {
        try w.objectField(f.key);
        if (f.list) |l| {
            try w.beginArray();
            for (l) |s| try w.write(s);
            try w.endArray();
        } else try w.write(f.string orelse "");
    }
    try w.endObject();
    return buf.written();
}

const RangeRead = struct { status: []const u8, commits: []const std.json.Value };

pub fn Alert(comptime Api: type) type {
    return struct {
        const Self = @This();

        a: std.mem.Allocator,
        api: *Api,
        cfg: Config,
        out: *std.Io.Writer,

        fn path(self: Self, comptime fmt: []const u8, args: anytype) ![]const u8 {
            return std.fmt.allocPrint(self.a, fmt, args);
        }

        fn compare(self: Self, base: []const u8, head: []const u8, per_page: usize, page: usize) !std.json.Value {
            return self.api.get(try self.path("repos/{s}/compare/{s}...{s}?per_page={d}&page={d}", .{ self.cfg.repo, base, head, per_page, page }));
        }

        /// The compare API's commits of base...head, every page, and its status.
        fn rangeCommits(self: Self, base: []const u8, head: []const u8) !RangeRead {
            const first = try self.compare(base, head, 100, 1);
            var commits = std.ArrayList(std.json.Value).empty;
            try commits.appendSlice(self.a, items(field(first, "commits")));
            const total = int(field(first, "total_commits"), commits.items.len);
            var page: usize = 2;
            while (commits.items.len < total and page <= 20) : (page += 1) {
                const more = items(field(try self.compare(base, head, 100, page), "commits"));
                if (more.len == 0) break;
                try commits.appendSlice(self.a, more);
            }
            return .{ .status = str(field(first, "status")), .commits = commits.items };
        }

        fn openIssues(self: Self) ![]const std.json.Value {
            const listed = try self.api.get(try self.path("repos/{s}/issues?labels={s}&state=open&per_page=100", .{ self.cfg.repo, issue.LABEL }));
            var out = std.ArrayList(std.json.Value).empty;
            for (items(listed)) |i| {
                if (field(i, "pull_request") == null) try out.append(self.a, i);
            }
            return out.items;
        }

        fn numbersOf(self: Self, issues: []const std.json.Value) ![]const u64 {
            var out = std.ArrayList(u64).empty;
            for (issues) |i| try out.append(self.a, int(field(i, "number"), 0));
            return out.items;
        }

        /// The head shas of the successful push runs of main of the watched
        /// workflows, newest first.
        fn successRuns(self: Self) ![]const []const u8 {
            const flows = try self.api.get(try self.path("repos/{s}/actions/workflows?per_page=100", .{self.cfg.repo}));
            const Row = struct { sha: []const u8, at: []const u8 };
            var rows = std.ArrayList(Row).empty;
            for (items(field(flows, "workflows"))) |w| {
                if (!issue.watches(self.cfg.workflows, str(field(w, "name")))) continue;
                const id = int(field(w, "id"), 0);
                const runs = try self.api.get(try self.path(
                    "repos/{s}/actions/workflows/{d}/runs?branch={s}&event=push&status=success&per_page=30",
                    .{ self.cfg.repo, id, issue.MAIN },
                ));
                for (items(field(runs, "workflow_runs"))) |r| {
                    try rows.append(self.a, .{ .sha = str(field(r, "head_sha")), .at = str(field(r, "created_at")) });
                }
            }
            // Newest first across the workflows; a stable sort keeps the
            // API's own order for equal times.
            std.sort.insertion(Row, rows.items, {}, struct {
                fn newer(_: void, x: Row, y: Row) bool {
                    return std.mem.order(u8, x.at, y.at) == .gt;
                }
            }.newer);
            var out = std.ArrayList([]const u8).empty;
            for (rows.items) |r| try out.append(self.a, r.sha);
            return out.items;
        }

        const Relations = struct {
            outer: *const Self,
            head: []const u8,
            statuses: std.StringHashMap([]const u8),
            ranges: std.StringHashMap([]const std.json.Value),

            // A candidate's compare is also the range when it is the last
            // green: read it once, with every page.
            pub fn relation(self: *Relations, sha: []const u8) ![]const u8 {
                if (self.statuses.get(sha)) |s| return s;
                const r = try self.outer.rangeCommits(sha, self.head);
                try self.statuses.put(sha, r.status);
                try self.ranges.put(sha, r.commits);
                return r.status;
            }
        };

        const Pulls = struct {
            outer: *const Self,

            pub fn of(self: Pulls, sha: []const u8) !std.json.Value {
                return self.outer.api.get(try self.outer.path("repos/{s}/commits/{s}/pulls", .{ self.outer.cfg.repo, sha })) catch |e| {
                    if (e == error.NotFound) return .null;
                    return e;
                };
            }
        };

        fn comment(self: Self, number: u64, body: []const u8) !void {
            _ = try self.api.write("POST", try self.path("repos/{s}/issues/{d}/comments", .{ self.cfg.repo, number }), try jsonBody(self.a, &.{.{ .key = "body", .string = body }}));
        }

        fn close(self: Self, number: u64, reason: []const u8) !void {
            _ = try self.api.write("PATCH", try self.path("repos/{s}/issues/{d}", .{ self.cfg.repo, number }), try jsonBody(self.a, &.{
                .{ .key = "state", .string = "closed" },
                .{ .key = "state_reason", .string = reason },
            }));
        }

        fn ensureLabel(self: Self) !void {
            _ = self.api.get(try self.path("repos/{s}/labels/{s}", .{ self.cfg.repo, issue.LABEL })) catch |e| {
                if (e != error.NotFound) return e;
                _ = self.api.write("POST", try self.path("repos/{s}/labels", .{self.cfg.repo}), try jsonBody(self.a, &.{
                    .{ .key = "name", .string = issue.LABEL },
                    .{ .key = "color", .string = issue.LABEL_COLOR },
                    .{ .key = "description", .string = issue.LABEL_DESCRIPTION },
                })) catch |e2| {
                    if (e2 != error.AlreadyExists) return e2;
                };
            };
        }

        fn onRed(self: Self, the_run: std.json.Value) !void {
            const head = str(field(the_run, "head_sha"));
            var rel = Relations{
                .outer = &self,
                .head = head,
                .statuses = std.StringHashMap([]const u8).init(self.a),
                .ranges = std.StringHashMap([]const std.json.Value).init(self.a),
            };
            const verdict = try range.lastGreen(head, try self.successRuns(), &rel);
            var green: ?[]const u8 = null;
            var prs: []const u64 = &.{};
            switch (verdict) {
                .stale => |g| {
                    try self.out.print("main_red: {s} is red, but main is green at {s}, which contains it: nothing to do\n", .{ head, g });
                    return;
                },
                .found => |g| {
                    green = g;
                    if (!std.mem.eql(u8, g, head)) {
                        const commits = rel.ranges.get(g) orelse &[_]std.json.Value{};
                        prs = try range.culprits(self.a, commits, head, g, Pulls{ .outer = &self });
                    }
                },
                .none => {},
            }

            const attempt = int(field(the_run, "run_attempt"), 1);
            const jobs_answer = try self.api.get(try self.path("repos/{s}/actions/runs/{d}/attempts/{d}/jobs?per_page=100", .{ self.cfg.repo, int(field(the_run, "id"), 0), attempt }));
            const failed = try logs.failedJobs(self.a, items(field(jobs_answer, "jobs")));
            var failing = std.ArrayList([]const u8).empty;
            var log_lines: []const []const u8 = &.{};
            for (failed) |job| {
                const log = self.api.text(try self.path("repos/{s}/actions/jobs/{d}/logs", .{ self.cfg.repo, int(field(job, "id"), 0) })) catch |e| blk: {
                    if (e == error.NotFound) break :blk "";
                    return e;
                };
                for (try logs.failingTargets(self.a, log, logs.MAX_TARGETS)) |t| {
                    var seen = false;
                    for (failing.items) |x| {
                        if (std.mem.eql(u8, x, t)) seen = true;
                    }
                    if (!seen and failing.items.len < logs.MAX_TARGETS) try failing.append(self.a, t);
                }
                if (log_lines.len == 0) log_lines = try logs.keyLogLines(self.a, log, logs.MAX_LOG_LINES);
            }
            if (failing.items.len == 0) {
                for (failed) |job| {
                    if (failing.items.len < logs.MAX_TARGETS) try failing.append(self.a, try logs.jobLabel(self.a, job));
                }
            }
            if (failing.items.len == 0) {
                const name = if (str(field(the_run, "name")).len > 0) str(field(the_run, "name")) else "workflow";
                try failing.append(self.a, try self.path("workflow {s} (no job failed: a job could not start)", .{name}));
            }

            const body = try issue.issueBody(self.a, str(field(the_run, "html_url")), head, green, prs, failing.items, log_lines);
            const open_numbers = try self.numbersOf(try self.openIssues());
            switch (issue.decideRed(open_numbers)) {
                .comment => |n| {
                    try self.comment(n, body);
                    try self.out.print("main_red: commented on #{d}\n", .{n});
                    return;
                },
                .open => {},
            }
            try self.ensureLabel();
            const created = try self.api.write("POST", try self.path("repos/{s}/issues", .{self.cfg.repo}), try jsonBody(self.a, &.{
                .{ .key = "title", .string = try issue.issueTitle(self.a, failing.items) },
                .{ .key = "body", .string = body },
                .{ .key = "labels", .list = &.{issue.LABEL} },
            }));
            const created_number = int(field(created, "number"), 0);
            try self.out.print("main_red: opened #{d}\n", .{created_number});
            const dup = try issue.duplicates(self.a, try self.numbersOf(try self.openIssues()));
            for (dup.others) |n| {
                if (n != created_number) continue;
                const oldest = dup.oldest.?;
                try self.comment(oldest, body);
                try self.comment(created_number, try self.path("Duplicate of #{d}", .{oldest}));
                try self.close(created_number, "not_planned");
                try self.out.print("main_red: #{d} raced #{d}; closed as its duplicate\n", .{ created_number, oldest });
            }
        }

        const Contains = struct {
            outer: *const Self,
            sha: []const u8,

            /// Whether the green commit contains `head`: null for a head the
            /// compare API does not know (404) or places off main's line.
            pub fn of(self: Contains, head: []const u8) !?bool {
                if (std.mem.eql(u8, head, self.sha)) return true;
                const status = blk: {
                    const answer = self.outer.compare(head, self.sha, 1, 1) catch |e| {
                        if (e == error.NotFound) break :blk "unknown";
                        return e;
                    };
                    break :blk str(field(answer, "status"));
                };
                if (std.mem.eql(u8, status, "ahead") or std.mem.eql(u8, status, "identical")) return true;
                if (std.mem.eql(u8, status, "behind")) return false;
                try self.outer.out.print("main_red: recorded head {s} is {s} against {s}; skipped\n", .{ head, status, self.sha });
                return null;
            }
        };

        fn onGreen(self: Self, the_run: std.json.Value) !void {
            const sha = str(field(the_run, "head_sha"));
            const url = str(field(the_run, "html_url"));
            const Rec = struct { number: u64, heads: []const []const u8 };
            var recs = std.ArrayList(Rec).empty;
            for (try self.openIssues()) |i| {
                const number = int(field(i, "number"), 0);
                const comments = try self.api.get(try self.path("repos/{s}/issues/{d}/comments?per_page=100", .{ self.cfg.repo, number }));
                // The body, and the workflow's own comments: no one else's.
                var texts = std.ArrayList([]const u8).empty;
                try texts.append(self.a, str(field(i, "body")));
                for (items(comments)) |c| {
                    const user = field(c, "user") orelse continue;
                    if (std.mem.eql(u8, str(field(user, "login")), issue.WORKFLOW_LOGIN)) try texts.append(self.a, str(field(c, "body")));
                }
                try recs.append(self.a, .{ .number = number, .heads = try issue.headsIn(self.a, texts.items) });
            }
            std.sort.insertion(Rec, recs.items, {}, struct {
                fn lower(_: void, x: Rec, y: Rec) bool {
                    return x.number < y.number;
                }
            }.lower);
            const contains = Contains{ .outer = &self, .sha = sha };
            for (recs.items) |r| {
                if (try issue.keepsOpen(r.heads, contains)) {
                    try self.out.print("main_red: #{d} records a head {s} does not contain; left open\n", .{ r.number, sha });
                } else {
                    try self.comment(r.number, try issue.fixedComment(self.a, sha, url));
                    try self.close(r.number, "completed");
                    try self.out.print("main_red: closed #{d}\n", .{r.number});
                }
            }
        }

        /// Reads run `run_id` and writes what it calls for (docs/ci.md).
        pub fn run(self: Self, run_id: u64) !void {
            const the_run = try self.api.get(try self.path("repos/{s}/actions/runs/{d}", .{ self.cfg.repo, run_id }));
            const kind = issue.classify(the_run, self.cfg.workflows);
            try self.out.print("main_red: run {d} ({s}, {s}, {s}, {s}) at {s}: {s}\n", .{
                run_id,
                str(field(the_run, "name")),
                str(field(the_run, "event")),
                str(field(the_run, "head_branch")),
                str(field(the_run, "conclusion")),
                str(field(the_run, "head_sha")),
                @tagName(kind),
            });
            switch (kind) {
                .red => try self.onRed(the_run),
                .green => try self.onGreen(the_run),
                .ignore => {},
            }
        }
    };
}
