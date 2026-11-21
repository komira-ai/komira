//! The cases of release/ci/buck2_failure.zig, release-macos.yml's report of a
//! failed buck2 step, run by the zig_test //release/ci/tests:test_buck2_failure
//! as a build action: building the program is running them. fixtures/ holds
//! the log of a real failed run (buck2_failure/analysis_failed.log: the
//! tail of the macOS build, Build ID zeroed) and a log of an action failure
//! (buck2_action_failed.log).
//!
//! What each case holds, and what it would catch:
//!
//! - analysis failure: the real log gives the exact message, output line and
//!   summary. A block that starts at the wrong line, keeps the blank line, or
//!   keeps the timestamps is wrong.
//! - action failure: the lines after `BUILD FAILED` of a log that also has
//!   `Action failed:` lines before it; the runner's `##[error]` line is not
//!   part of the block.
//! - BXL failure and `Command failed:`: both markers start a block; the
//!   `Command failed:` line itself is not in it.
//! - the last marker: with two failure lines, the block is after the last.
//! - no marker: the last 12 lines of the log, empty lines and runner lines
//!   left out.
//! - empty log: "wrote no buck2 output", one output line, a summary of one
//!   line; a log of blank and runner lines only is the same.
//! - the caps: 12 lines, 3000 bytes cut at a line, and a first line longer
//!   than the cap cut to it (at a character boundary).
//! - escaping: `%`, CR and LF of a message are escaped, a literal `%0A`
//!   comes out as `%250A`, and the output is one line ending in one newline.
//! - ANSI colour codes and buck2 timestamps are stripped from the block.
//! - the command line: the four flags give the arguments; each missing flag,
//!   an unknown flag, a repeated flag and a flag without a value is its own
//!   error.
const std = @import("std");
const lib = @import("buck2_failure_lib");
const t = std.testing;

const ANALYSIS_LOG = @embedFile("fixtures/buck2_failure/analysis_failed.log");
const ACTION_LOG = @embedFile("fixtures/buck2_action_failed.log");

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn blockOf(a: std.mem.Allocator, log: []const u8) ![]const []const u8 {
    return lib.failureBlock(a, log);
}

fn messageOf(a: std.mem.Allocator, log: []const u8) ![]u8 {
    return lib.message(a, "build the macOS set", try blockOf(a, log));
}

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "analysis failure: exact message, output line and summary" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const block = try blockOf(a, ANALYSIS_LOG);
    try expectStrings(&.{
        "Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`",
        "Caused by:",
        "komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto",
        "is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes",
    }, block);
    const msg = try lib.message(a, "build the macOS set", block);
    try t.expectEqualStrings(
        "step `build the macOS set` failed; buck2's output ends:\n" ++
            "Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`\n" ++
            "Caused by:\n" ++
            "komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto\n" ++
            "is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes",
        msg,
    );
    try t.expectEqualStrings(
        "message=step `build the macOS set` failed; buck2's output ends:%0A" ++
            "Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`%0A" ++
            "Caused by:%0A" ++
            "komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto%0A" ++
            "is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes\n",
        try lib.outputLine(a, msg),
    );
    try t.expectEqualStrings(
        "release-macos FAILED: step `build the macOS set`.\n" ++
            "\n" ++
            "    Error running analysis for `komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024)`\n" ++
            "    Caused by:\n" ++
            "    komira//release:mopm_darwin_libs (komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024) does not pass compatibility check (will be error in future) because its transitive dep toolchains//:mojo_proto\n" ++
            "    is incompatible with komira//tools/build/platforms:darwin-arm64#7fd7ccfd5d5f8024 (prelude//os/constraints:linux unsatisfied), check the target's compatibility attributes\n",
        try lib.summaryText(a, "build the macOS set", block),
    );
}

test "action failure: the lines after BUILD FAILED, without the runner's error line" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(), ACTION_LOG);
    try expectStrings(&.{
        "Failed to build 'komira//tools/build/toolchains:busybox (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)'",
    }, block);
}

test "BXL failure: the lines after BXL FAILED" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(),
        \\Build ID: 1
        \\BXL FAILED
        \\Error evaluating bxl script
        \\
        \\Caused by:
        \\    no such target
        \\
    );
    try expectStrings(&.{ "Error evaluating bxl script", "Caused by:", "no such target" }, block);
}

test "TEST FAILED starts a block" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(), "TEST FAILED\nTests failed: 1\n");
    try expectStrings(&.{"Tests failed: 1"}, block);
}

test "Command failed: starts a block and is not part of it" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(),
        \\[2026-11-21T04:57:12.747+00:00] Build ID: 1
        \\Command failed: Unknown target `bad` from package `komira//release`.
        \\Did you mean one of the 1 targets in komira//release:BUCK?
        \\
    );
    try expectStrings(&.{"Did you mean one of the 1 targets in komira//release:BUCK?"}, block);
}

test "a marker must be the whole line: BUILD FAILED inside a line is not one" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(), "one\nthe BUILD FAILED here\ntwo\n");
    try expectStrings(&.{ "one", "the BUILD FAILED here", "two" }, block);
}

test "two markers: the block is after the last one" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(),
        \\BUILD FAILED
        \\first failure
        \\Command failed: second
        \\second failure
        \\
    );
    try expectStrings(&.{"second failure"}, block);
}

test "no marker: the last 12 lines, blank and runner lines left out" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var log = std.ArrayList(u8).empty;
    var i: usize = 1;
    while (i <= 15) : (i += 1) {
        try log.appendSlice(a, try std.fmt.allocPrint(a, "line {d}\n\n##[group]g{d}\n", .{ i, i }));
    }
    const block = try blockOf(a, log.items);
    try t.expectEqual(@as(usize, 12), block.len);
    try t.expectEqualStrings("line 4", block[0]);
    try t.expectEqualStrings("line 15", block[11]);
}

test "runner ##[ lines after the marker are skipped" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(),
        \\BUILD FAILED
        \\Failed to build 'x'
        \\2026-10-05T12:06:22.3565986Z ##[error]Process completed with exit code 2.
        \\##[endgroup]
        \\
    );
    try expectStrings(&.{"Failed to build 'x'"}, block);
}

test "empty log: no buck2 output, one output line, a one-line summary" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const block = try blockOf(a, "");
    try t.expectEqual(@as(usize, 0), block.len);
    const msg = try lib.message(a, "build the macOS set", block);
    try t.expectEqualStrings("step `build the macOS set` failed and wrote no buck2 output", msg);
    try t.expectEqualStrings(
        "message=step `build the macOS set` failed and wrote no buck2 output\n",
        try lib.outputLine(a, msg),
    );
    try t.expectEqualStrings(
        "release-macos FAILED: step `build the macOS set`.\n",
        try lib.summaryText(a, "build the macOS set", block),
    );
}

test "a log of blank and runner lines only is no buck2 output" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const msg = try messageOf(a, "\n  \n##[error]Process completed with exit code 1.\n\n");
    try t.expectEqualStrings("step `build the macOS set` failed and wrote no buck2 output", msg);
}

test "a marker with nothing after it: no buck2 output" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(), "earlier line\nBUILD FAILED\n");
    try t.expectEqual(@as(usize, 0), block.len);
}

test "after a marker: at most 12 lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var log = std.ArrayList(u8).empty;
    try log.appendSlice(a, "BUILD FAILED\n");
    var i: usize = 1;
    while (i <= 20) : (i += 1) try log.appendSlice(a, try std.fmt.allocPrint(a, "l{d}\n", .{i}));
    const block = try blockOf(a, log.items);
    try t.expectEqual(@as(usize, 12), block.len);
    try t.expectEqualStrings("l1", block[0]);
    try t.expectEqualStrings("l12", block[11]);
}

test "the 3000-byte cap cuts at a line boundary" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const l1 = "a" ** 1000;
    const l2 = "b" ** 1000;
    const l3 = "c" ** 998;
    const l4 = "d" ** 10;
    // 1000 + 1 + 1000 + 1 + 998 = 3000 bytes: fits; the next line does not.
    const log = "BUILD FAILED\n" ++ l1 ++ "\n" ++ l2 ++ "\n" ++ l3 ++ "\n" ++ l4 ++ "\n";
    const block = try blockOf(a, log);
    try expectStrings(&.{ l1, l2, l3 }, block);
    const log2 = "BUILD FAILED\n" ++ l1 ++ "\n" ++ l2 ++ "\n" ++ l3 ++ "x\n" ++ l4 ++ "\n";
    try expectStrings(&.{ l1, l2 }, try blockOf(a, log2));
}

test "a first line longer than the cap is cut to it" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const block = try blockOf(a, "BUILD FAILED\n" ++ ("x" ** 5000) ++ "\nnext\n");
    try expectStrings(&.{"x" ** 3000}, block);
}

test "a cut line does not end inside a UTF-8 character" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    // 2999 ASCII bytes then a 2-byte character: the cap falls inside it.
    const block = try blockOf(a, "BUILD FAILED\n" ++ ("x" ** 2999) ++ "\xc3\xa9" ++ "yyy\n");
    try expectStrings(&.{"x" ** 2999}, block);
}

test "escaping: percent, CR and LF; a literal %0A becomes %250A" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a%25b%0Dc%0Ad%250Ae", try lib.escapeData(a, "a%b\rc\nd%0Ae"));
    try t.expectEqualStrings("", try lib.escapeData(a, ""));
    try t.expectEqualStrings("plain text", try lib.escapeData(a, "plain text"));
    try t.expectEqualStrings("message=100%25 sure%0Aok\n", try lib.outputLine(a, "100% sure\nok"));
}

test "a message with %0A in a log line is escaped once, on one output line" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const msg = try lib.message(a, "s", try blockOf(a, "BUILD FAILED\nsaw %0A in a name\n"));
    const line = try lib.outputLine(a, msg);
    try t.expectEqualStrings("message=step `s` failed; buck2's output ends:%0Asaw %250A in a name\n", line);
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, line, "\n"));
}

test "ANSI colour codes and buck2 timestamps are stripped" {
    var ar = arena();
    defer ar.deinit();
    const block = try blockOf(ar.allocator(),
        "BUILD FAILED\n" ++
            "[2026-11-21T04:57:13.069+00:00] \x1b[31mError\x1b[0m: \x1b[1;33mbad\x1b[0m\n" ++
            "2026-10-05T12:06:22.3565986Z \x1b[2mdim\x1b[0m\r\n",
    );
    try expectStrings(&.{ "Error: bad", "dim" }, block);
}

test "arguments: the four flags in any order" {
    const args = try lib.parseArgs(&.{ "--summary-file", "s", "--step", "build", "--log", "l", "--github-output", "o" });
    try t.expectEqualStrings("l", args.log);
    try t.expectEqualStrings("build", args.step);
    try t.expectEqualStrings("o", args.github_output);
    try t.expectEqualStrings("s", args.summary_file);
}

test "arguments: each missing flag is its own error" {
    try t.expectError(error.MissingLog, lib.parseArgs(&.{ "--step", "b", "--github-output", "o", "--summary-file", "s" }));
    try t.expectError(error.MissingStep, lib.parseArgs(&.{ "--log", "l", "--github-output", "o", "--summary-file", "s" }));
    try t.expectError(error.MissingGithubOutput, lib.parseArgs(&.{ "--log", "l", "--step", "b", "--summary-file", "s" }));
    try t.expectError(error.MissingSummaryFile, lib.parseArgs(&.{ "--log", "l", "--step", "b", "--github-output", "o" }));
    try t.expectError(error.MissingLog, lib.parseArgs(&.{}));
}

test "arguments: an unknown flag, a repeated flag and a flag without a value" {
    try t.expectError(error.UnknownArgument, lib.parseArgs(&.{ "--log", "l", "--step", "b", "--github-output", "o", "--summary-file", "s", "--extra", "x" }));
    try t.expectError(error.UnknownArgument, lib.parseArgs(&.{"positional"}));
    try t.expectError(error.DuplicateArgument, lib.parseArgs(&.{ "--log", "l", "--log", "m", "--step", "b", "--github-output", "o", "--summary-file", "s" }));
    try t.expectError(error.MissingValue, lib.parseArgs(&.{ "--log", "l", "--step", "b", "--github-output", "o", "--summary-file" }));
}

test "arguments: every error has a reason for the usage message" {
    try t.expectEqualStrings("--log is required", lib.argErrorText(error.MissingLog));
    try t.expectEqualStrings("--step is required", lib.argErrorText(error.MissingStep));
    try t.expectEqualStrings("--github-output is required", lib.argErrorText(error.MissingGithubOutput));
    try t.expectEqualStrings("--summary-file is required", lib.argErrorText(error.MissingSummaryFile));
    try t.expectEqualStrings("unknown argument", lib.argErrorText(error.UnknownArgument));
    try t.expectEqualStrings("a flag has no value", lib.argErrorText(error.MissingValue));
    try t.expectEqualStrings("a flag is given twice", lib.argErrorText(error.DuplicateArgument));
}
