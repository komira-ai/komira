//! The release stamp, derived from git at the commit the run builds, before
//! any build runs: the three values a package build is given
//! (`-c komira.package_stamp`, `-c komira.package_commit`,
//! `-c komira.package_timestamp_ms`).
//!
//!   1. git rev-parse --is-shallow-repository   must print `false`
//!   2. git rev-parse --verify HEAD             must print the revision
//!   3. git status --porcelain --untracked-files=no   must print nothing
//!   4. git log -1 --first-parent --format=%H <revision> -- . :(exclude)docs
//!        :(exclude)*.md :(exclude).github      the stamp's commit S
//!   5. git rev-list --count --first-parent S   the build number N
//!   6. git log -1 --format=%ct S               S's commit time, seconds
//!
//! S is the newest first-parent commit at or below the revision that touches
//! anything but documentation, so a documentation-only commit never raises N;
//! the timestamp is S's commit time in milliseconds. The rule is
//! tools/build/package/release_version.sh's. A shallow clone is refused: the
//! first-parent count there is the clone's depth, not the history's.
const std = @import("std");
const util = @import("util.zig");

pub const Stamp = struct {
    source_commit: []const u8,
    build_number: u64,
    timestamp_ms: u64,
};

pub const Result = union(enum) {
    ok: Stamp,
    /// Why there is no stamp.
    refuse: []const u8,
};

const Line = union(enum) { ok: []const u8, refuse: []const u8 };

/// The one line `git <args>` printed, or why not.
fn line(a: std.mem.Allocator, git: anytype, args: []const []const u8) !Line {
    const r = try git.run(a, args);
    const cmd = try std.mem.join(a, " ", args);
    if (r.code != 0) {
        return .{ .refuse = try std.fmt.allocPrint(a, "`git {s}` failed ({d}): {s}", .{ cmd, r.code, std.mem.trim(u8, r.stderr, " \t\r\n") }) };
    }
    const one = util.oneLine(r.stdout) orelse {
        return .{ .refuse = try std.fmt.allocPrint(a, "`git {s}` printed more than one line", .{cmd}) };
    };
    return .{ .ok = one };
}

fn positive(text: []const u8) ?u64 {
    const n = std.fmt.parseInt(u64, text, 10) catch return null;
    if (n == 0) return null;
    return n;
}

/// `git` is any value with `run(self, a, args) anyerror!util.GitOut`.
pub fn derive(a: std.mem.Allocator, git: anytype, revision: []const u8) !Result {
    if (!util.isFullCommitId(revision)) {
        return .{ .refuse = try std.fmt.allocPrint(a, "--revision '{s}' is not a full commit id (40 lowercase hex)", .{revision}) };
    }
    const shallow = try line(a, git, &.{ "rev-parse", "--is-shallow-repository" });
    switch (shallow) {
        .refuse => |m| return .{ .refuse = m },
        .ok => |v| if (!std.mem.eql(u8, v, "false")) {
            return .{ .refuse = try std.fmt.allocPrint(a, "this is a shallow clone: the commit count would be the clone's depth, not the history's; check out with full history (fetch-depth: 0)", .{}) };
        },
    }
    const head = try line(a, git, &.{ "rev-parse", "--verify", "HEAD" });
    switch (head) {
        .refuse => |m| return .{ .refuse = m },
        .ok => |v| if (!std.mem.eql(u8, v, revision)) {
            return .{ .refuse = try std.fmt.allocPrint(a, "the checkout's HEAD '{s}' is not the revision {s}", .{ v, revision }) };
        },
    }
    const status = try git.run(a, &.{ "status", "--porcelain", "--untracked-files=no" });
    if (status.code != 0) {
        return .{ .refuse = try std.fmt.allocPrint(a, "`git status --porcelain --untracked-files=no` failed ({d}): {s}", .{ status.code, std.mem.trim(u8, status.stderr, " \t\r\n") }) };
    }
    if (status.stdout.len != 0) {
        return .{ .refuse = try std.fmt.allocPrint(a, "the checkout has modified tracked files: the bytes are not the revision's", .{}) };
    }
    const closure = try line(a, git, &.{ "log", "-1", "--first-parent", "--format=%H", revision, "--", ".", ":(exclude)docs", ":(exclude)*.md", ":(exclude).github" });
    const source = switch (closure) {
        .refuse => |m| return .{ .refuse = m },
        .ok => |v| v,
    };
    if (!util.isFullCommitId(source)) {
        return .{ .refuse = try std.fmt.allocPrint(a, "no commit at or below {s} touches anything but documentation (git printed '{s}')", .{ revision, source }) };
    }
    const count = try line(a, git, &.{ "rev-list", "--count", "--first-parent", source });
    const n_text = switch (count) {
        .refuse => |m| return .{ .refuse = m },
        .ok => |v| v,
    };
    const n = positive(n_text) orelse {
        return .{ .refuse = try std.fmt.allocPrint(a, "the commit count '{s}' of {s} is not a positive number", .{ n_text, source }) };
    };
    const time = try line(a, git, &.{ "log", "-1", "--format=%ct", source });
    const t_text = switch (time) {
        .refuse => |m| return .{ .refuse = m },
        .ok => |v| v,
    };
    const secs = positive(t_text) orelse {
        return .{ .refuse = try std.fmt.allocPrint(a, "the commit time '{s}' of {s} is not a positive number", .{ t_text, source }) };
    };
    return .{ .ok = .{ .source_commit = source, .build_number = n, .timestamp_ms = secs * 1000 } };
}
