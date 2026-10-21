//! The GitHub API through `gh api` (GH_TOKEN in the environment). Each call
//! is tried three times; a 404 is error.NotFound and a 422 `already_exists`
//! error.AlreadyExists, neither retried. With `dry_run`, a write is printed,
//! not sent.
const std = @import("std");

pub const ATTEMPTS = 3;

pub const Failure = enum { not_found, already_exists, other };

/// What a failed `gh api` call means: its stderr names the HTTP status, and a
/// 422's `already_exists` is in the answer (stdout) or stderr.
pub fn classify(stdout: []const u8, stderr: []const u8) Failure {
    if (std.mem.indexOf(u8, stderr, "HTTP 404") != null) return .not_found;
    if (std.mem.indexOf(u8, stderr, "HTTP 422") != null and
        (std.mem.indexOf(u8, stdout, "already_exists") != null or std.mem.indexOf(u8, stderr, "already_exists") != null))
        return .already_exists;
    return .other;
}

pub const GhApi = struct {
    a: std.mem.Allocator,
    /// The `gh` executable (a flag, so a test can stand in for it).
    gh: []const u8 = "gh",
    dry_run: bool = false,
    out: *std.Io.Writer,
    /// The wait after the first failed attempt; it doubles after each.
    backoff_ms: u64 = 1000,
    /// The stderr of the last failed attempt, for the message.
    last_err: []const u8 = "",

    const Run = struct { ok: bool, stdout: []const u8, stderr: []const u8 };

    fn once(self: *GhApi, args: []const []const u8, stdin: ?[]const u8) !Run {
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(self.a, self.gh);
        try argv.append(self.a, "api");
        try argv.appendSlice(self.a, args);
        var child = std.process.Child.init(argv.items, self.a);
        child.stdin_behavior = if (stdin != null) .Pipe else .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        if (stdin) |s| {
            child.stdin.?.writeAll(s) catch {};
            child.stdin.?.close();
            child.stdin = null;
        }
        var out = std.ArrayList(u8).empty;
        var err = std.ArrayList(u8).empty;
        try child.collectOutput(self.a, &out, &err, 1 << 28);
        const term = try child.wait();
        const ok = switch (term) {
            .Exited => |c| c == 0,
            else => false,
        };
        return .{ .ok = ok, .stdout = out.items, .stderr = err.items };
    }

    fn call(self: *GhApi, args: []const []const u8, stdin: ?[]const u8) ![]const u8 {
        var attempt: u6 = 0;
        while (attempt < ATTEMPTS) : (attempt += 1) {
            const r = try self.once(args, stdin);
            if (r.ok) return r.stdout;
            self.last_err = std.mem.trim(u8, r.stderr, " \t\r\n");
            switch (classify(r.stdout, r.stderr)) {
                .not_found => return error.NotFound,
                .already_exists => return error.AlreadyExists,
                .other => {},
            }
            if (attempt + 1 < ATTEMPTS) std.Thread.sleep((self.backoff_ms << attempt) * std.time.ns_per_ms);
        }
        return error.GhFailed;
    }

    fn parse(self: *GhApi, body: []const u8) !std.json.Value {
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) return .null;
        return (try std.json.parseFromSlice(std.json.Value, self.a, body, .{})).value;
    }

    pub fn get(self: *GhApi, path: []const u8) anyerror!std.json.Value {
        return self.parse(try self.call(&.{path}, null));
    }

    pub fn text(self: *GhApi, path: []const u8) anyerror![]const u8 {
        return self.call(&.{path}, null);
    }

    pub fn write(self: *GhApi, method: []const u8, path: []const u8, body: []const u8) anyerror!std.json.Value {
        if (self.dry_run) {
            try self.out.print("main_red: DRY RUN {s} {s} {s}\n", .{ method, path, body });
            return self.parse("{\"number\": 0}");
        }
        return self.parse(try self.call(&.{ "--method", method, path, "--input", "-" }, body));
    }
};
