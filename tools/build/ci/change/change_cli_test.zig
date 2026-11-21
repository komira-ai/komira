//! The cases of the change tool's executable, //tools/build/ci:change_cli_cases: each runs the built
//! tool (`CHANGE`, an exec tool) as pr.yml's step runs it, with its flags, in a directory of the
//! case's own under KOMIRA_TEST_WORK, with `git` on its PATH being the stand-in (`STAND_IN_GIT`,
//! stand_in_git.zig) answering from the case's `answers` file and recording what it was asked. Each
//! checks the exit code, stderr by exact equality (git's own stderr passed through, then the
//! tool's `::error::` line), the files written into the output directory byte for byte, and the git
//! commands asked. The selection's every branch is in change_test.zig; these hold what only the
//! executable does: its flags, its exit codes, what it prints, where it writes and the git it runs.
//! What the cases catch:
//!  - a pull request and a merge group each exit 0 and write changed.txt and held.txt read
//!    against their base;
//!  - a refusal exits 1 with its `::error::` line, after git's stderr, and writes nothing;
//!  - an event other than the two exits 1 before any git;
//!  - wrong usage, and an output directory that cannot be opened, exit 2 with their line, before any git;
//!  - a git that cannot be started exits 1 with the git failure line.
const std = @import("std");
const t = std.testing;

const SHA = "0123456789abcdef0123456789abcdef01234567";
const USAGE = "usage: change --event <pull_request|merge_group> --group-base <sha or empty> --out <dir>\n";

const Outcome = struct { code: u8, stderr: []const u8, dir: []const u8 };

var case_no: usize = 0;

/// A directory of the case's own holding `bin/git` (the stand-in), `answers` and the output
/// directory `out`.
fn caseDir(ar: std.mem.Allocator, answers: []const u8, with_git: bool) ![]const u8 {
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/case{d}", .{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), case_no });
    try std.fs.cwd().makePath(try std.fs.path.join(ar, &.{ dir, "bin" }));
    try std.fs.cwd().makePath(try std.fs.path.join(ar, &.{ dir, "out" }));
    try std.fs.cwd().writeFile(.{ .sub_path = try std.fs.path.join(ar, &.{ dir, "answers" }), .data = answers });
    if (with_git) {
        const git = try std.fs.path.join(ar, &.{ dir, "bin", "git" });
        try std.fs.cwd().copyFile(try std.process.getEnvVarOwned(ar, "STAND_IN_GIT"), std.fs.cwd(), git, .{});
        var f = try std.fs.cwd().openFile(git, .{});
        try f.chmod(0o755);
        f.close();
    }
    return dir;
}

/// Runs the built tool with `args` in `dir`, with `dir/bin` alone on its PATH.
fn runTool(ar: std.mem.Allocator, dir: []const u8, args: []const []const u8) !Outcome {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(ar, try std.process.getEnvVarOwned(ar, "CHANGE"));
    try argv.appendSlice(ar, args);
    var env = std.process.EnvMap.init(ar);
    try env.put("PATH", try std.fs.path.join(ar, &.{ dir, "bin" }));
    const r = try std.process.Child.run(.{ .allocator = ar, .argv = argv.items, .cwd = dir, .env_map = &env });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    try t.expectEqualStrings("", r.stdout);
    return .{ .code = code, .stderr = r.stderr, .dir = dir };
}

fn read(ar: std.mem.Allocator, dir: []const u8, rel: []const u8) ![]const u8 {
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ dir, rel }), 1 << 20);
}

fn expectAbsent(ar: std.mem.Allocator, dir: []const u8, rel: []const u8) !void {
    try t.expectError(error.FileNotFound, std.fs.cwd().access(try std.fs.path.join(ar, &.{ dir, rel }), .{}));
}

fn outDir(ar: std.mem.Allocator, dir: []const u8) ![]const u8 {
    return std.fs.path.join(ar, &.{ dir, "out" });
}

test "a pull request exits 0 and writes its change read against HEAD^1" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar,
        "0\trev-parse --verify --quiet HEAD^2\t" ++ SHA ++ "\\n\n" ++
        "0\tdiff --no-renames --name-only HEAD^1...HEAD\tsrc/containers/BUCK\\ndocs/ci.md\\n\n" ++
        "0\tgrep -n  HEAD^1 HEAD -- *coverage_held\tHEAD^1:src/containers/coverage_held:1:line 99\\nHEAD:src/containers/coverage_held:1:line 100\\n\n", true);
    const o = try runTool(ar, dir, &.{ "--event", "pull_request", "--group-base", "", "--out", try outDir(ar, dir) });
    try t.expectEqualStrings(
        "stand-in git: rev-parse --verify --quiet HEAD^2\n" ++
            "stand-in git: diff --no-renames --name-only HEAD^1...HEAD\n" ++
            "stand-in git: grep -n  HEAD^1 HEAD -- *coverage_held\n",
        o.stderr,
    );
    try t.expectEqual(@as(u8, 0), o.code);
    try t.expectEqualStrings("src/containers/BUCK\ndocs/ci.md\n", try read(ar, dir, "out/changed.txt"));
    try t.expectEqualStrings("HEAD^1:src/containers/coverage_held:1:line 99\nHEAD:src/containers/coverage_held:1:line 100\n", try read(ar, dir, "out/held.txt"));
    try t.expectEqualStrings("rev-parse --verify --quiet HEAD^2\ndiff --no-renames --name-only HEAD^1...HEAD\ngrep -n  HEAD^1 HEAD -- *coverage_held\n", try read(ar, dir, "asked"));
}

test "a merge group exits 0 and writes its change read against its base_sha" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar,
        "0\tmerge-base --is-ancestor " ++ SHA ++ " HEAD\t\n" ++
        "0\tdiff --no-renames --name-only " ++ SHA ++ "...HEAD\tdocs/ci.md\\n\n" ++
        "1\tgrep -n  " ++ SHA ++ " HEAD -- *coverage_held\t\n", true);
    const o = try runTool(ar, dir, &.{ "--out", try outDir(ar, dir), "--event", "merge_group", "--group-base", SHA });
    try t.expectEqual(@as(u8, 0), o.code);
    try t.expectEqualStrings("docs/ci.md\n", try read(ar, dir, "out/changed.txt"));
    // no hold on either side: an empty file, not a failure
    try t.expectEqualStrings("", try read(ar, dir, "out/held.txt"));
    try t.expectEqualStrings("merge-base --is-ancestor " ++ SHA ++ " HEAD\ndiff --no-renames --name-only " ++ SHA ++ "...HEAD\ngrep -n  " ++ SHA ++ " HEAD -- *coverage_held\n", try read(ar, dir, "asked"));
}

test "a refusal exits 1 with its line after git's stderr, and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, "1\tmerge-base --is-ancestor " ++ SHA ++ " HEAD\t\n", true);
    const o = try runTool(ar, dir, &.{ "--event", "merge_group", "--group-base", SHA, "--out", try outDir(ar, dir) });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expectEqualStrings("stand-in git: merge-base --is-ancestor " ++ SHA ++ " HEAD\n::error::the change base is the merge group's base_sha, and it is not an ancestor of HEAD\n", o.stderr);
    try expectAbsent(ar, dir, "out/changed.txt");
    try expectAbsent(ar, dir, "out/held.txt");
}

test "an event other than a pull request or a merge group exits 1 before any git" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, "", true);
    const o = try runTool(ar, dir, &.{ "--event", "push", "--group-base", "", "--out", try outDir(ar, dir) });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expectEqualStrings("::error::the check runs on a pull request or a merge group, not on this event\n", o.stderr);
    try expectAbsent(ar, dir, "asked");
    try expectAbsent(ar, dir, "out/changed.txt");
}

test "wrong usage exits 2 with the usage line, before any git" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const cases = [_][]const []const u8{
        &.{}, // nothing
        &.{ "--event", "pull_request", "--group-base", "" }, // no --out
        &.{ "--event", "pull_request", "--group-base", "", "--out" }, // --out with no value
        &.{ "--event", "pull_request", "--base", "", "--out", "out" }, // an unknown option
    };
    for (cases) |args| {
        const dir = try caseDir(ar, "", true);
        const o = try runTool(ar, dir, args);
        try t.expectEqual(@as(u8, 2), o.code);
        try t.expectEqualStrings(USAGE, o.stderr);
        try expectAbsent(ar, dir, "asked");
    }
}

test "an output directory that cannot be opened exits 2 with its line, before any git" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, "", true);
    const missing = try std.fs.path.join(ar, &.{ dir, "no-such-dir" });
    const o = try runTool(ar, dir, &.{ "--event", "pull_request", "--group-base", "", "--out", missing });
    try t.expectEqual(@as(u8, 2), o.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "::error::the output directory {s} cannot be opened\n", .{missing}), o.stderr);
    try expectAbsent(ar, dir, "asked");
}

test "a git that cannot be started exits 1 with the git failure line, and writes nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar, "", false); // no git on the PATH
    const o = try runTool(ar, dir, &.{ "--event", "pull_request", "--group-base", "", "--out", try outDir(ar, dir) });
    try t.expectEqual(@as(u8, 1), o.code);
    try t.expectEqualStrings("::error::a git command of the change failed\n", o.stderr);
    try expectAbsent(ar, dir, "out/changed.txt");
    try expectAbsent(ar, dir, "out/held.txt");
}
