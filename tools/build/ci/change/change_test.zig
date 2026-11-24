//! The cases of the change tool (change.zig), //tools/build/ci:change_unit: the tool is built only when
//! they pass. Each runs the step's whole selection (`run`: the event, the base, the diff and the
//! coverage holds, the two files) in a scratch directory, with a fake git that answers each command
//! as the case says and records what it was asked, and checks the files it wrote, byte for byte, and
//! the commands. Nothing runs a real git.
//! What the cases catch:
//!  - a pull request's change is read against HEAD^1, and only when HEAD is a merge commit;
//!  - a merge group's change is read against its base_sha, and only when that is a full commit id
//!    and an ancestor of HEAD; a value that is not (empty, a revision expression, an option, short,
//!    upper case) runs no git;
//!  - a pull request given a group base, and any other event, are refused before any git;
//!  - a git command that fails or cannot run fails the step, and a refused or failed step writes no file;
//!  - no coverage hold on either side writes an empty held.txt, not a failure;
//!  - the options are each given once, with a value; each refusal has its own message.
const std = @import("std");
const c = @import("change.zig");
const t = std.testing;

const SHA = "0123456789abcdef0123456789abcdef01234567";
const SHA256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const CHANGED = "src/containers/BUCK\ndocs/ci.md\n";

/// One answer of the fake git: the command it expects (the arguments joined by one space), and
/// what it returns. `cannot_run` stands for a git that could not be started.
const Answer = struct { args: []const u8, code: ?u8 = 0, stdout: []const u8 = "", cannot_run: bool = false };

const Fake = struct {
    a: std.mem.Allocator,
    answers: []const Answer,
    asked: std.ArrayList([]const u8) = .empty,

    fn runFn(ctx: *anyopaque, args: []const []const u8) error{GitFailed}!c.Run {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const joined = std.mem.join(self.a, " ", args) catch return error.GitFailed;
        const n = self.asked.items.len;
        self.asked.append(self.a, joined) catch return error.GitFailed;
        // a command the case did not script: an exit no case scripts, and the commands differ below
        if (n >= self.answers.len or !std.mem.eql(u8, self.answers[n].args, joined)) return .{ .code = 99, .stdout = "" };
        const ans = self.answers[n];
        if (ans.cannot_run) return error.GitFailed;
        return .{ .code = ans.code, .stdout = ans.stdout };
    }

    fn git(self: *Fake) c.Git {
        return .{ .ctx = self, .runFn = runFn };
    }

    /// The fake was asked exactly the scripted commands, in order.
    fn expectAskedAll(self: *Fake) !void {
        try self.expectAsked(self.answers.len);
    }

    /// The fake was asked exactly the first `n` scripted commands.
    fn expectAsked(self: *Fake, n: usize) !void {
        if (self.asked.items.len != n) {
            std.debug.print("git was asked {d} commands, wanted {d}\n", .{ self.asked.items.len, n });
            for (self.asked.items) |q| std.debug.print("  asked: {s}\n", .{q});
            return error.WrongCommands;
        }
        for (self.answers[0..n], self.asked.items) |want, got| try t.expectEqualStrings(want.args, got);
    }
};

fn opts(event: []const u8, group_base: []const u8) c.Options {
    return .{ .event = event, .group_base = group_base, .out = "unused: the cases pass the directory" };
}

fn expectFile(dir: std.fs.Dir, a: std.mem.Allocator, name: []const u8, want: []const u8) !void {
    try t.expectEqualStrings(want, try dir.readFileAlloc(a, name, 1 << 20));
}

fn expectNoFiles(dir: std.fs.Dir) !void {
    try t.expectError(error.FileNotFound, dir.access("changed.txt", .{}));
    try t.expectError(error.FileNotFound, dir.access("held.txt", .{}));
}

/// Runs the step for `o` against `answers`, expects the error `want`, and
/// checks that a refused step wrote nothing and asked only the first `asked` commands.
fn expectRefused(o: c.Options, answers: []const Answer, want: anyerror, asked: usize) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var fake = Fake{ .a = arena.allocator(), .answers = answers };
    try t.expectError(want, c.run(arena.allocator(), fake.git(), o, tmp.dir));
    try fake.expectAsked(asked);
    try expectNoFiles(tmp.dir);
}

test "a pull request's change is read against HEAD^1 of its merge commit" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const held = "HEAD^1:src/containers/coverage_held:1:line 99\nHEAD:src/containers/coverage_held:1:line 100\n";
    var fake = Fake{ .a = a, .answers = &.{
        .{ .args = "rev-parse --verify --quiet HEAD^2", .stdout = SHA ++ "\n" },
        .{ .args = "diff --no-renames --name-only HEAD^1...HEAD", .stdout = CHANGED },
        .{ .args = "grep -n  HEAD^1 HEAD -- *coverage_held", .stdout = held },
    } };
    try c.run(a, fake.git(), opts("pull_request", ""), tmp.dir);
    try fake.expectAskedAll();
    try expectFile(tmp.dir, a, "changed.txt", CHANGED);
    try expectFile(tmp.dir, a, "held.txt", held);
}

test "a merge group's change is read against its base_sha, a SHA-1 or a SHA-256 commit id" {
    for ([_][]const u8{ SHA, SHA256 }) |sha| {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        const held = try std.fmt.allocPrint(a, "{s}:src/containers/coverage_held:1:line 99\nHEAD:src/containers/coverage_held:1:line 99\n", .{sha});
        const answers = [_]Answer{
            .{ .args = try std.fmt.allocPrint(a, "merge-base --is-ancestor {s} HEAD", .{sha}) },
            .{ .args = try std.fmt.allocPrint(a, "diff --no-renames --name-only {s}...HEAD", .{sha}), .stdout = CHANGED },
            .{ .args = try std.fmt.allocPrint(a, "grep -n  {s} HEAD -- *coverage_held", .{sha}), .stdout = held },
        };
        var fake = Fake{ .a = a, .answers = &answers };
        try c.run(a, fake.git(), opts("merge_group", sha), tmp.dir);
        try fake.expectAskedAll();
        try expectFile(tmp.dir, a, "changed.txt", CHANGED);
        try expectFile(tmp.dir, a, "held.txt", held);
    }
}

test "a pull request whose HEAD is not a merge commit is refused, and nothing is written" {
    try expectRefused(opts("pull_request", ""), &.{.{ .args = "rev-parse --verify --quiet HEAD^2", .code = 1 }}, error.NotAMergeCommit, 1);
    // a rev-parse killed by a signal (no exit code) is no merge commit either
    try expectRefused(opts("pull_request", ""), &.{.{ .args = "rev-parse --verify --quiet HEAD^2", .code = null }}, error.NotAMergeCommit, 1);
}

test "a merge group whose base_sha is not an ancestor of HEAD is refused, and nothing is written" {
    try expectRefused(opts("merge_group", SHA), &.{.{ .args = "merge-base --is-ancestor " ++ SHA ++ " HEAD", .code = 1 }}, error.GroupBaseNotAncestor, 1);
}

test "a merge group base that is not a full commit id is refused before any git" {
    const bad = [_][]const u8{
        "", // the event had no base_sha
        "HEAD^1", // a revision expression, not a commit id
        "--output=/x", // an option
        SHA[0..39], // short
        "0123456789ABCDEF0123456789ABCDEF01234567", // upper case
        SHA ++ "0", // 41 digits
        "g123456789abcdef0123456789abcdef01234567", // not hex
    };
    for (bad) |b| try expectRefused(opts("merge_group", b), &.{}, error.NoGroupBase, 0);
}

test "a pull request given a merge group base is refused before any git" {
    try expectRefused(opts("pull_request", SHA), &.{}, error.GroupBaseOnPullRequest, 0);
}

test "an event other than a pull request or a merge group is refused before any git" {
    for ([_][]const u8{ "push", "pull_request_target", "workflow_dispatch", "", "Pull_Request" }) |e|
        try expectRefused(opts(e, ""), &.{}, error.UnknownEvent, 0);
}

test "a git command that fails or cannot run fails the step, and nothing is written" {
    const rev = Answer{ .args = "rev-parse --verify --quiet HEAD^2" };
    const diff = "diff --no-renames --name-only HEAD^1...HEAD";
    const grep = "grep -n  HEAD^1 HEAD -- *coverage_held";
    const anc = "merge-base --is-ancestor " ++ SHA ++ " HEAD";
    // the ancestor check: an error exit, a signal, git not started
    try expectRefused(opts("merge_group", SHA), &.{.{ .args = anc, .code = 128 }}, error.GitFailed, 1);
    try expectRefused(opts("merge_group", SHA), &.{.{ .args = anc, .code = null }}, error.GitFailed, 1);
    try expectRefused(opts("merge_group", SHA), &.{.{ .args = anc, .cannot_run = true }}, error.GitFailed, 1);
    try expectRefused(opts("pull_request", ""), &.{.{ .args = rev.args, .cannot_run = true }}, error.GitFailed, 1);
    // the diff
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .code = 128, .stdout = CHANGED } }, error.GitFailed, 2);
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .code = null } }, error.GitFailed, 2);
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .cannot_run = true } }, error.GitFailed, 2);
    // the coverage holds, after a diff that succeeded: still nothing written
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .stdout = CHANGED }, .{ .args = grep, .code = 2 } }, error.GitFailed, 3);
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .stdout = CHANGED }, .{ .args = grep, .code = null } }, error.GitFailed, 3);
    try expectRefused(opts("pull_request", ""), &.{ rev, .{ .args = diff, .stdout = CHANGED }, .{ .args = grep, .cannot_run = true } }, error.GitFailed, 3);
}

test "no coverage hold on either side writes an empty held.txt beside the change" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var fake = Fake{ .a = a, .answers = &.{
        .{ .args = "rev-parse --verify --quiet HEAD^2" },
        .{ .args = "diff --no-renames --name-only HEAD^1...HEAD", .stdout = CHANGED },
        .{ .args = "grep -n  HEAD^1 HEAD -- *coverage_held", .code = 1 },
    } };
    try c.run(a, fake.git(), opts("pull_request", ""), tmp.dir);
    try fake.expectAskedAll();
    try expectFile(tmp.dir, a, "changed.txt", CHANGED);
    try expectFile(tmp.dir, a, "held.txt", "");
}

test "the options are each given once, with a value, in any order" {
    const o = try c.parseArgs(&.{ "--out", "/scratch/x", "--group-base", "", "--event", "merge_group" });
    try t.expectEqualStrings("merge_group", o.event);
    try t.expectEqualStrings("", o.group_base);
    try t.expectEqualStrings("/scratch/x", o.out);
    try t.expectError(error.MissingArgument, c.parseArgs(&.{ "--event", "pull_request", "--group-base", "" }));
    try t.expectError(error.MissingArgument, c.parseArgs(&.{}));
    try t.expectError(error.MissingValue, c.parseArgs(&.{ "--event", "pull_request", "--group-base", "", "--out" }));
    try t.expectError(error.RepeatedArgument, c.parseArgs(&.{ "--event", "pull_request", "--event", "merge_group", "--group-base", "", "--out", "d" }));
    try t.expectError(error.UnknownArgument, c.parseArgs(&.{ "--base", "HEAD^1", "--event", "pull_request", "--group-base", "", "--out", "d" }));
    try t.expectError(error.UnknownArgument, c.parseArgs(&.{"pull_request"}));
}

test "each refusal has its own message, and an error that is not a refusal has none" {
    try t.expectEqualStrings("::error::the check runs on a pull request or a merge group, not on this event", c.describe(error.UnknownEvent).?);
    try t.expectEqualStrings("::error::the change base is the merge commit's first parent, and HEAD is not a merge commit", c.describe(error.NotAMergeCommit).?);
    try t.expectEqualStrings("::error::a pull request has no merge group base, and one was given", c.describe(error.GroupBaseOnPullRequest).?);
    try t.expectEqualStrings("::error::the change base is the merge group's base_sha, and it is not a full commit id", c.describe(error.NoGroupBase).?);
    try t.expectEqualStrings("::error::the change base is the merge group's base_sha, and it is not an ancestor of HEAD", c.describe(error.GroupBaseNotAncestor).?);
    try t.expectEqualStrings("::error::a git command of the change failed", c.describe(error.GitFailed).?);
    try t.expect(c.describe(error.OutOfMemory) == null);
}
