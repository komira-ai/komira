//! The command line of release/ci/buck2_failure.zig, run as the built program (BUCK2_FAILURE, an
//! exec tool of the zig_test //release/ci:test_buck2_failure_cli) the way release-macos.yml's step
//! "what the build said" runs it: its exit status, its stderr and the files it writes, compared
//! whole. The real failed log (release/ci/tests/fixtures/buck2_failure/analysis_failed.log) is the
//! test's data, KOMIRA_TEST_WORK/analysis_failed.log; each case works in a directory of its own
//! under KOMIRA_TEST_WORK.
//!
//! What each case holds:
//! - the real failed log: exit 0; one `message=` line is appended after what $GITHUB_OUTPUT already
//!   held, and the summary is appended after the summary's earlier text (a program that truncated
//!   either file would drop another step's output);
//! - a log that does not exist: exit 0, the files are created, and both say the step wrote no buck2
//!   output (the step before it may have failed before buck2 wrote anything);
//! - a missing flag: exit 2, the reason and the usage on stderr, and no output file is created;
//! - an output file that cannot be opened: exit 2 and stderr names the file and the error.
const std = @import("std");
const t = std.testing;

const MESSAGE_LINE = "message=step `build the macOS set` failed; buck2's output ends:%0A" ++
    "Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`%0A" ++
    "Caused by:%0A" ++
    "komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto%0A" ++
    "is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes\n";

const SUMMARY = "release-macos FAILED: step `build the macOS set`.\n" ++
    "\n" ++
    "    Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`\n" ++
    "    Caused by:\n" ++
    "    komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto\n" ++
    "    is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes\n";

const USAGE =
    \\usage: buck2_failure --log <path> --step <name> --github-output <path>
    \\                     --summary-file <path>
    \\
;

const Outcome = struct { code: u8, stderr: []const u8 };

var case_no: usize = 0;

/// A new, empty directory of this case under KOMIRA_TEST_WORK.
fn caseDir(ar: std.mem.Allocator) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    case_no += 1;
    const dir = try std.fmt.allocPrint(ar, "{s}/cli{d}", .{ work, case_no });
    try std.fs.cwd().makePath(dir);
    return dir;
}

/// The path of the real failed log, the test's data.
fn analysisLog(ar: std.mem.Allocator) ![]const u8 {
    return std.fs.path.join(ar, &.{ try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK"), "analysis_failed.log" });
}

fn inDir(ar: std.mem.Allocator, dir: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(ar, &.{ dir, name });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

fn readFile(ar: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fs.cwd().readFileAlloc(ar, path, 1 << 20);
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Runs the built program with `args` and returns its exit status and stderr.
fn run(ar: std.mem.Allocator, args: []const []const u8) !Outcome {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(ar, try std.process.getEnvVarOwned(ar, "BUCK2_FAILURE"));
    try argv.appendSlice(ar, args);
    const r = try std.process.Child.run(.{ .allocator = ar, .argv = argv.items });
    const code: u8 = switch (r.term) {
        .Exited => |c| c,
        else => 255,
    };
    return .{ .code = code, .stderr = r.stderr };
}

test "the real failed log: exit 0, the message line and the summary appended to what the files held" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const log = try analysisLog(ar);
    const out = try inDir(ar, dir, "github_output");
    const summary = try inDir(ar, dir, "summary.md");
    try writeFile(out, "path=/x/assert_remote\n");
    try writeFile(summary, "release-macos FAILED on the commit.\n");
    const r = try run(ar, &.{ "--log", log, "--step", "build the macOS set", "--github-output", out, "--summary-file", summary });
    try t.expectEqualStrings("", r.stderr);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("path=/x/assert_remote\n" ++ MESSAGE_LINE, try readFile(ar, out));
    try t.expectEqualStrings("release-macos FAILED on the commit.\n" ++ SUMMARY, try readFile(ar, summary));
}

test "a log that does not exist: exit 0, both files created, no buck2 output" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const out = try inDir(ar, dir, "github_output");
    const summary = try inDir(ar, dir, "summary.md");
    const r = try run(ar, &.{ "--log", try inDir(ar, dir, "no-such.log"), "--step", "s", "--github-output", out, "--summary-file", summary });
    try t.expectEqualStrings("", r.stderr);
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("message=step `s` failed and wrote no buck2 output\n", try readFile(ar, out));
    try t.expectEqualStrings("release-macos FAILED: step `s`.\n", try readFile(ar, summary));
}

test "a missing flag: exit 2, the reason and the usage on stderr, no file written" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const log = try analysisLog(ar);
    const out = try inDir(ar, dir, "github_output");
    const summary = try inDir(ar, dir, "summary.md");
    const r = try run(ar, &.{ "--log", log, "--github-output", out, "--summary-file", summary });
    try t.expectEqual(@as(u8, 2), r.code);
    try t.expectEqualStrings("buck2_failure: --step is required\n" ++ USAGE, r.stderr);
    try t.expect(!exists(out));
    try t.expect(!exists(summary));
}

test "an output file that cannot be opened: exit 2, stderr names it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const dir = try caseDir(ar);
    const out = try inDir(ar, dir, "no-such-dir/github_output");
    const summary = try inDir(ar, dir, "summary.md");
    const r = try run(ar, &.{ "--log", try inDir(ar, dir, "no-such.log"), "--step", "s", "--github-output", out, "--summary-file", summary });
    try t.expectEqual(@as(u8, 2), r.code);
    try t.expectEqualStrings(try std.fmt.allocPrint(ar, "buck2_failure: cannot open {s}: FileNotFound\n", .{out}), r.stderr);
    try t.expect(!exists(summary));
}
