//! The release workflow's guard: whether this run may build a release, and
//! of what. It decides from the facts of the run (flags) and two answers of
//! git, and builds nothing.
//!
//!   1. what the run is is known: an event and a ref, and a full commit id;
//!   2. the ref is not `main` in another case (GitHub compares refs and
//!      concurrency groups ignoring case, so such a ref would join main's
//!      group);
//!   3. the run is a push to main, a nightly (schedule) run of main, or a manual
//!      run, and nothing else;
//!   4. the checkout's HEAD is the commit the run started on: what is built
//!      is that commit's bytes;
//!   5. a push to main or a nightly run builds a commit on main's history
//!      (refs/remotes/origin/main); a manual run (break-glass) needs a
//!      reason of 1 to 200 bytes on one line, and says so in its first
//!      summary line;
//!   6. a commit without the artifacts file has nothing to release: a push
//!      skips it (a warning and a summary line, no failure), a manual run
//!      asked for a release and is refused.
//!
//! The release is always the commit the run started on. There is no
//! revision input: the guard is built from the checkout, so the checkout
//! must be the commit it guards.
const std = @import("std");
const util = @import("util.zig");

pub const MAIN_REF = "refs/heads/main";
/// A FULL refname: `origin/main` would resolve a tag of that name first.
pub const MAIN_TRACKING_REF = "refs/remotes/origin/main";
pub const REASON_MAX_BYTES = 200;

pub const Input = struct {
    /// GITHUB_EVENT_NAME: `push`, `schedule` or `workflow_dispatch`.
    event: []const u8,
    /// GITHUB_REF.
    ref: []const u8,
    /// GITHUB_SHA: the commit the run started on.
    sha: []const u8,
    /// A manual run's reason.
    reason: []const u8 = "",
    /// The login that started the run (the banner names it).
    actor: []const u8 = "",
    /// The artifacts file's path, as the messages name it.
    artifacts: []const u8,
    /// Whether the artifacts file is in the checkout.
    artifacts_exist: bool,
};

pub const Outcome = union(enum) {
    /// Build the release. A break-glass (manual) run carries its banner, the
    /// first line of its summary.
    release: ?[]const u8,
    /// Nothing to release: the message, as a warning and a summary line.
    skip: []const u8,
    /// Do nothing and fail: why.
    refuse: []const u8,
};

fn refuse(a: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .refuse = try std.fmt.allocPrint(a, fmt, args) };
}

fn eqlIgnoreCase(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(x, y);
}

/// `git` is any value with `run(self, a, args) anyerror!util.GitOut`.
pub fn decide(a: std.mem.Allocator, in: Input, git: anytype) !Outcome {
    if (in.event.len == 0 or in.ref.len == 0) {
        return refuse(a, "--event and --ref must both be set: what this run is cannot be told, so nothing is built", .{});
    }
    if (!util.isFullCommitId(in.sha)) {
        return refuse(a, "--sha '{s}' is not a full commit id (40 lowercase hex), so nothing is built", .{in.sha});
    }
    if (!std.mem.eql(u8, in.ref, MAIN_REF) and eqlIgnoreCase(in.ref, MAIN_REF)) {
        return refuse(a, "this run is on {s}, main in another case: GitHub compares refs and concurrency groups ignoring case, so such a ref would pass for main there; it is refused, so nothing is built", .{in.ref});
    }
    // a schedule runs on the default branch's latest commit: a run of main, as a push is
    const push_to_main = (std.mem.eql(u8, in.event, "push") or std.mem.eql(u8, in.event, "schedule")) and std.mem.eql(u8, in.ref, MAIN_REF);
    const manual = std.mem.eql(u8, in.event, "workflow_dispatch");
    if (!push_to_main and !manual) {
        return refuse(a, "a release is built by a push to main, a nightly run of main or a manual run; this run is a {s} of {s}, so nothing is built", .{ in.event, in.ref });
    }

    const head = try git.run(a, &.{ "rev-parse", "--verify", "HEAD" });
    if (head.code != 0) {
        return refuse(a, "`git rev-parse --verify HEAD` failed ({d}): {s}", .{ head.code, std.mem.trim(u8, head.stderr, " \t\r\n") });
    }
    const head_id = util.oneLine(head.stdout) orelse "";
    if (!std.mem.eql(u8, head_id, in.sha)) {
        return refuse(a, "the checkout's HEAD '{s}' is not {s}, the commit this run started on: what would be built is not that commit, so nothing is built", .{ head_id, in.sha });
    }

    var banner: ?[]const u8 = null;
    if (push_to_main) {
        const anc = try git.run(a, &.{ "merge-base", "--is-ancestor", in.sha, MAIN_TRACKING_REF });
        switch (anc.code) {
            0 => {},
            1 => return refuse(a, "the commit {s} is not on main's history ({s}): a run of main releases a merged commit only, so nothing is built", .{ in.sha, MAIN_TRACKING_REF }),
            else => return refuse(a, "whether {s} is on {s}'s history cannot be told ({s}), so nothing is built", .{ in.sha, MAIN_TRACKING_REF, std.mem.trim(u8, anc.stderr, " \t\r\n") }),
        }
    } else {
        // trimmed: a reason of spaces says nothing. One line: the banner is a
        // line of the job summary, and a second line there is a forged one.
        const reason = std.mem.trim(u8, in.reason, " \t\r\n");
        if (reason.len == 0 or reason.len > REASON_MAX_BYTES or std.mem.indexOfScalar(u8, reason, '\n') != null) {
            return refuse(a, "BREAK-GLASS on {s} (a {s}, not a push to main) needs --reason <why>, 1 to {d} bytes on one line once leading and trailing whitespace is trimmed; it has {d} bytes{s}, so nothing is built", .{
                in.ref,
                in.event,
                REASON_MAX_BYTES,
                reason.len,
                if (std.mem.indexOfScalar(u8, reason, '\n') != null) " and more than one line" else "",
            });
        }
        banner = try std.fmt.allocPrint(a, "BREAK-GLASS: {s} {s} by {s}: {s}", .{ in.ref, in.sha[0..8], in.actor, reason });
    }

    if (!in.artifacts_exist) {
        const msg = try std.fmt.allocPrint(a, "nothing to release: {s} has no {s}", .{ in.sha, in.artifacts });
        if (manual) return refuse(a, "{s}: a manual run asked for a release", .{msg});
        return .{ .skip = msg };
    }
    return .{ .release = banner };
}
