//! change: writes the change of the pull request's check (.github/workflows/pr.yml, step `the
//! change`): the files it touches and the coverage holds of both sides, which the BXL selector
//! (tools/build/ci/affected.bxl) reads.
//!
//!     change --event <pull_request|merge_group> --group-base <sha or empty> --out <dir>
//!
//! Run in the checkout of the commit the check builds. The change base is:
//!   * a pull request (`pull_request`): HEAD^1, the first parent of the merge commit GitHub made,
//!     which is the main the pull request is merged into. HEAD must be a merge commit (it has a
//!     HEAD^2); `--group-base` must be empty.
//!   * a merge group of the merge queue (`merge_group`): `--group-base`, the event's
//!     `merge_group.base_sha`, the commit the group's head was built on. It must be a full commit
//!     id and an ancestor of HEAD. The head is a squash commit on top of it, so HEAD^1 would be wrong.
//! Any other event is refused. Then it writes, into <dir>:
//!   * changed.txt: `git diff --no-renames --name-only <base>...HEAD` (renames as a delete and an add);
//!   * held.txt: `git grep -n '' <base> HEAD -- '*coverage_held'` (`rev:path:line:text`; empty when
//!     neither side holds any).
//! Both files are written only when every git command succeeded.
//!
//! Exit 0: written. Exit 1: refused (the reason is on stderr as a `::error::` line). Exit 2: usage.
const std = @import("std");

pub const Event = enum { pull_request, merge_group };

/// What one git command returned: its exit code (null when it did not exit) and its stdout.
pub const Run = struct { code: ?u8, stdout: []const u8 };

/// Runs `git <args>` in the checkout. The tool's own runs git; the cases run a fake.
pub const Git = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, args: []const []const u8) error{GitFailed}!Run,

    pub fn run(self: Git, args: []const []const u8) error{GitFailed}!Run {
        return self.runFn(self.ctx, args);
    }
};

pub const Refusal = error{
    /// The event is neither a pull request nor a merge group.
    UnknownEvent,
    /// A pull request's HEAD has no second parent.
    NotAMergeCommit,
    /// A pull request was given a group base.
    GroupBaseOnPullRequest,
    /// A merge group was given no base, or one that is not a full commit id.
    NoGroupBase,
    /// The merge group's base is not an ancestor of HEAD.
    GroupBaseNotAncestor,
    /// A git command could not run or failed.
    GitFailed,
};

pub const Usage = error{ UnknownArgument, MissingValue, MissingArgument, RepeatedArgument };

pub const Options = struct { event: []const u8, group_base: []const u8, out: []const u8 };

/// The options of `args` (without the program name). Each of --event, --group-base and --out is
/// given once, with a value (--group-base's may be empty).
pub fn parseArgs(args: []const []const u8) Usage!Options {
    var event: ?[]const u8 = null;
    var group_base: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        const slot = if (std.mem.eql(u8, args[i], "--event"))
            &event
        else if (std.mem.eql(u8, args[i], "--group-base"))
            &group_base
        else if (std.mem.eql(u8, args[i], "--out"))
            &out
        else
            return error.UnknownArgument;
        if (i + 1 >= args.len) return error.MissingValue;
        if (slot.* != null) return error.RepeatedArgument;
        slot.* = args[i + 1];
    }
    return .{
        .event = event orelse return error.MissingArgument,
        .group_base = group_base orelse return error.MissingArgument,
        .out = out orelse return error.MissingArgument,
    };
}

pub fn parseEvent(name: []const u8) Refusal!Event {
    return std.meta.stringToEnum(Event, name) orelse return error.UnknownEvent;
}

/// Whether `s` is a full commit id: 40 (SHA-1) or 64 (SHA-256) lowercase hex digits.
fn isCommitId(s: []const u8) bool {
    if (s.len != 40 and s.len != 64) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// The change base of `event` (see the header). Runs at most one git command.
pub fn base(git: Git, event: Event, group_base: []const u8) Refusal![]const u8 {
    switch (event) {
        .pull_request => {
            if (group_base.len != 0) return error.GroupBaseOnPullRequest;
            const r = try git.run(&.{ "rev-parse", "--verify", "--quiet", "HEAD^2" });
            if (r.code == null or r.code.? != 0) return error.NotAMergeCommit;
            return "HEAD^1";
        },
        .merge_group => {
            if (!isCommitId(group_base)) return error.NoGroupBase;
            const r = try git.run(&.{ "merge-base", "--is-ancestor", group_base, "HEAD" });
            const code = r.code orelse return error.GitFailed;
            if (code == 1) return error.GroupBaseNotAncestor;
            if (code != 0) return error.GitFailed;
            return group_base;
        },
    }
}

pub const Change = struct { changed: []const u8, held: []const u8 };

/// The files the change touches and the coverage holds of `from` and of HEAD.
pub fn change(a: std.mem.Allocator, git: Git, from: []const u8) (Refusal || std.mem.Allocator.Error)!Change {
    const range = try std.fmt.allocPrint(a, "{s}...HEAD", .{from});
    const diff = try git.run(&.{ "diff", "--no-renames", "--name-only", range });
    if (diff.code == null or diff.code.? != 0) return error.GitFailed;
    const held = try git.run(&.{ "grep", "-n", "", from, "HEAD", "--", "*coverage_held" });
    const code = held.code orelse return error.GitFailed;
    // git grep exits 1 when nothing matched: no hold on either side
    if (code == 1) return .{ .changed = diff.stdout, .held = "" };
    if (code != 0) return error.GitFailed;
    return .{ .changed = diff.stdout, .held = held.stdout };
}

/// The whole step: the base of `opts`' event, the change against it, and changed.txt and held.txt
/// written into `out` (nothing written when anything before fails).
pub fn run(a: std.mem.Allocator, git: Git, opts: Options, out: std.fs.Dir) !void {
    const event = try parseEvent(opts.event);
    const from = try base(git, event, opts.group_base);
    const c = try change(a, git, from);
    try out.writeFile(.{ .sub_path = "changed.txt", .data = c.changed });
    try out.writeFile(.{ .sub_path = "held.txt", .data = c.held });
}

/// The `::error::` line of a refusal; null for an error that is not one.
pub fn describe(e: anyerror) ?[]const u8 {
    return switch (e) {
        error.UnknownEvent => "::error::the check runs on a pull request or a merge group, not on this event",
        error.NotAMergeCommit => "::error::the change base is the merge commit's first parent, and HEAD is not a merge commit",
        error.GroupBaseOnPullRequest => "::error::a pull request has no merge group base, and one was given",
        error.NoGroupBase => "::error::the change base is the merge group's base_sha, and it is not a full commit id",
        error.GroupBaseNotAncestor => "::error::the change base is the merge group's base_sha, and it is not an ancestor of HEAD",
        error.GitFailed => "::error::a git command of the change failed",
        else => null,
    };
}

const Real = struct {
    a: std.mem.Allocator,

    fn runFn(ctx: *anyopaque, args: []const []const u8) error{GitFailed}!Run {
        const self: *Real = @ptrCast(@alignCast(ctx));
        var argv = std.ArrayList([]const u8).empty;
        argv.append(self.a, "git") catch return error.GitFailed;
        argv.appendSlice(self.a, args) catch return error.GitFailed;
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = argv.items, .max_output_bytes = 1 << 28 }) catch return error.GitFailed;
        std.fs.File.stderr().writeAll(r.stderr) catch {};
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => null,
        }, .stdout = r.stdout };
    }
};

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [512]u8 = undefined;
    var err = std.fs.File.stderr().writer(&buf);
    const raw = try std.process.argsAlloc(a);
    const args = try a.alloc([]const u8, raw.len -| 1);
    for (args, 0..) |*o, i| o.* = raw[i + 1];
    const opts = parseArgs(args) catch {
        try err.interface.writeAll("usage: change --event <pull_request|merge_group> --group-base <sha or empty> --out <dir>\n");
        try err.interface.flush();
        return 2;
    };
    var out = try std.fs.cwd().openDir(opts.out, .{});
    defer out.close();
    var real = Real{ .a = a };
    run(a, .{ .ctx = &real, .runFn = Real.runFn }, opts, out) catch |e| {
        const line = describe(e) orelse return e;
        try err.interface.print("{s}\n", .{line});
        try err.interface.flush();
        return 1;
    };
    return 0;
}
