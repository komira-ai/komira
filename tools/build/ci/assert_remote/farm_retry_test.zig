//! The cases of farm_retry.zig's `classify`, //tools/build/ci:farm_retry_unit:
//! which failed runs are the farm's (a cut connection to the farm, or a job
//! the farm failed to start, `input-unavailable`), run again, and which are
//! final. Each case is a log the tool must read right; the ones that
//! must be final are the ones a wrong reading would pass over.
//!
//! The logs in fixtures/ are recorded buck2 output, excerpts of failed runs on
//! the farm: build_cut.log (a build whose every failure was a cut, whole but
//! for its progress lines), build_cut_and_compile_error.log (a build with a
//! compile error and cuts: the first of each, the run's summary and its end),
//! test_failed.log (a test run with one failed test) and
//! build_cut_after_file_changes.log (a build whose every failure was a cut,
//! started after a step had written files the daemon saw change: its progress
//! and warning lines cut to two each, the action digests zeroed). A log buck2
//! printed in another run (a cut beside a test failure, a line quoting the
//! phrase) is a recorded one with lines added or changed, in the case.
//! test_cut.log is a test run whose every test failed because the connection
//! to the farm was cut before it ran: its progress lines cut to two, the
//! action digests zeroed. build_input_unavailable.log is a release build
//! whose one failure was a job the farm failed to start, an input unavailable
//! on its host: its progress lines cut to two, its build id and action
//! digests zeroed.
//!
//! The wait for the farm before a run again (farm_wait.zig) runs on a fake
//! clock and a fake farm, so a case of twenty minutes takes none: a farm that
//! answers at once, one back after three minutes, one that never answers (the
//! bound, the last sleep cut to it, a line a minute), a bound of 0 and a probe
//! slower than a minute. The farm config is read from the buckconfig
//! farm-connect writes, and each way it can name no farm is refused by name.
//! The real probe connects to loopback ports of the case's own (port 0), one
//! listening and one bound but not listening.
const std = @import("std");
const fr = @import("farm_retry.zig");
const fw = @import("farm_wait.zig");
const t = std.testing;

const build_cut = @embedFile("fixtures/build_cut.log");
const build_cut_after_file_changes = @embedFile("fixtures/build_cut_after_file_changes.log");
const test_cut = @embedFile("fixtures/test_cut.log");
const build_input_unavailable = @embedFile("fixtures/build_input_unavailable.log");

const build_mixed = @embedFile("fixtures/build_cut_and_compile_error.log");
const test_failed = @embedFile("fixtures/test_failed.log");
const build_unknown_target = @embedFile("fixtures/build_failed_unknown_target.log");

/// The first failed test of fixtures/test_cut.log and its output, as buck2 printed them.
const unrun_fail = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x97 Fail: komira//tools/build/third_party_srcs:aws_lc_mini_files_check (0.0s)";
const unrun_stdout = "[2026-11-25T02:24:32.807+00:00] ---- STDOUT ----\n";
const unrun_stderr = "[2026-11-25T02:24:32.807+00:00] ---- STDERR ----\n";
const unrun_execute = "[2026-11-25T02:24:32.807+00:00] Remote Execution Error on Execute with digest 0000000000000000000000000000000000000000000000000000000000000000:147 for ReSession GRPC-SESSION-ID\n";
const unrun_cut = "[2026-11-25T02:24:32.807+00:00] Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: \"h2 protocol error: error reading a body from connection\", source: hyper::Error(Body, Error { kind: Io(Custom { kind: BrokenPipe, error: \"stream closed because of a broken pipe\" }) }): error reading a body from connection: stream closed because of a broken pipe)\n";
/// The second failed test of fixtures/test_cut.log, the line after the first's output.
const unrun_next = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x97 Fail: komira//tests/scan_binding_links:test_scan_binding_links (0.0s)";
/// A line of the test's own.
const own = "[2026-11-25T02:24:32.807+00:00] the test's own line\n";

/// buck2's line for a job the farm failed to start, an input unavailable on its host.
const unavailable_error = "Error: (Error was returned on the stream by RE: the job failed to start: input-unavailable)";
/// The first failed block of fixtures/build_input_unavailable.log.
const unavailable_first = "[2026-11-27T05:17:43.695+00:00] Action failed: komira//src/atomic_alias:atomic_alias_conda (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (conda_pack atomic_alias_conda)";

const cut_error = "Error: (Error was returned on the stream by RE: RE channel error: code: 'Unknown error', message: \"h2 protocol error: error reading a body from connection\", source: None)";

/// One cut block, as buck2 prints it (the lines of fixtures/build_cut.log).
const cut_block =
    "[2026-11-21T16:48:35.653+00:00] Action failed: komira//src/a:a (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (mojo_build)\n" ++
    "[2026-11-21T16:48:35.653+00:00] Internal error (stage: remote_call_error): Remote Execution Error on Execute with digest 00:141 for ReSession GRPC-SESSION-ID\n" ++
    "[2026-11-21T16:48:35.653+00:00] " ++ cut_error ++ "\n" ++
    "[2026-11-21T16:48:35.653+00:00] Remote action digest: '00:141'\n" ++
    "[2026-11-21T16:48:35.653+00:00] Stdout: <empty>\n" ++
    "[2026-11-21T16:48:35.653+00:00] Stderr: <empty>\n\n";

fn classify(a: std.mem.Allocator, log: []const u8) !fr.Verdict {
    return fr.classify(a, log);
}

fn edit(a: std.mem.Allocator, log: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try t.expect(std.mem.indexOf(u8, log, from) != null); // the recorded log has the text the case changes
    return std.mem.replaceOwned(u8, a, log, from, to);
}

/// `log` without each block whose first line holds `marker`: its lines up to
/// and with the empty line that ends it.
fn dropBlocks(a: std.mem.Allocator, log: []const u8, marker: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var dropping = false;
    var dropped: usize = 0;
    var it = std.mem.splitScalar(u8, log, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, marker) != null) {
            dropping = true;
            dropped += 1;
        }
        if (dropping) {
            if (l.len == 0) dropping = false;
            continue;
        }
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    try t.expect(dropped > 0);
    return out.toOwnedSlice(a);
}

fn expectFarm(log: []const u8, want: fr.Farm) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try classify(arena.allocator(), log);
    try t.expectEqualDeep(fr.Verdict{ .farm = want }, v);
}

fn expectCut(log: []const u8, blocks: usize) !void {
    try expectFarm(log, .{ .cut = blocks });
}

/// The log is final, for the reason `tag`, with `line` the line that says so.
fn expectFinal(log: []const u8, tag: std.meta.Tag(fr.Verdict), line: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try classify(arena.allocator(), log);
    try t.expectEqual(tag, std.meta.activeTag(v));
    const got = switch (v) {
        .failure, .test_status, .unexplained, .unmatched_target => |l| l,
        .farm, .no_failure => "",
    };
    try t.expectEqualStrings(line, got);
}

// ---- a cut, run again --------------------------------------------------------

test "a recorded build whose every failure is a cut is a cut, counting each block" {
    // two actions in flight, each printed once as it failed and once under BUILD ERRORS
    try expectCut(build_cut, 4);
}

test "buck2's own warning lines beside the cut are not errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const warn = "[2026-11-21T15:40:33.203+00:00] \x1b[2m2026-11-21T15:40:33.120769Z\x1b[0m \x1b[33m WARN\x1b[0m \x1b[2mremote_execution::client\x1b[0m\x1b[2m:\x1b[0m Transient error (attempt 1/5), retrying in 120ms\n";
    try expectCut(try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", warn ++ "[2026-11-21T16:48:35.702+00:00] Cache hits"), 4);
}

test "CRLF line ends read the same" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectCut(try std.mem.replaceOwned(u8, arena.allocator(), build_cut, "\n", "\r\n"), 4);
}

test "a recorded cut build that starts with buck2's changed-file lines is a cut" {
    // thirteen actions in flight, each printed once as it failed and once under BUILD ERRORS
    try expectCut(build_cut_after_file_changes, 26);
}

/// The changed-file lines buck2 printed before the run of fixtures/build_cut_after_file_changes.log.
const file_changes =
    "[2026-11-25T00:07:53.435+00:00] File changed: komira//src/anomaly/mopm.toml\n" ++
    "[2026-11-25T00:07:53.435+00:00] 415 additional file change events\n";

test "buck2's changed-file lines beside the cut are not errors" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectCut(try edit(arena.allocator(), build_cut, "[2026-11-21T16:23:14.887+00:00] RE Session", file_changes ++ "[2026-11-21T16:23:14.887+00:00] RE Session"), 4);
}

test "a recorded test run whose every test failed for a cut before it ran is a cut, counting each test" {
    try expectCut(test_cut, 56);
}

test "the list of failed tests that buck2 cuts short is one of its lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectCut(try edit(a, test_cut, "  ...and 46 more not shown...\n", ""), 56);
    inline for ([_][]const u8{ "  ...and more not shown...", "  ...and 46 more not shown", "  ...and 46 more not shown... and an error" }) |line| {
        try expectFinal(try edit(a, test_cut, "  ...and 46 more not shown...", line), .unexplained, line);
    }
}

test "a test run whose only failure is a cut build of a test is a cut" {
    const log = "[2026-11-21T16:00:00.000+00:00] Build ID: 00000000-0000-0000-0000-000000000000\n" ++ cut_block ++
        "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: komira//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDERR ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "Tests finished: \x1b[38;5;10mPass 1\x1b[39m. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n" ++
        "1 BUILDS FAILED\n";
    try expectCut(log, 1);
}

test "a failed test whose head, before its output, has buck2's cut line is a cut" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x97 Fail: komira//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] " ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDERR ----\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++
        "Tests finished: Pass 0. Fail 1. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 0\n" ++
        "1 TESTS FAILED\n" ++
        "  \xe2\x9c\x97 komira//src/b:test_b (cfg)\n";
    try expectCut(log, 1);
}

// ---- a real failure, final ---------------------------------------------------

const compile_error = "[2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))";

test "a recorded build with a compile error beside cuts is final, naming the compile error" {
    try expectFinal(build_mixed, .failure, compile_error);
}

test "a recorded test failure is final" {
    try expectFinal(test_failed, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: komira//src/komira_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a test failure beside a cut is final: the cut does not excuse it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_failed, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail:", cut_block ++ "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail:");
    try expectFinal(log, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: komira//src/komira_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a failed test whose own output prints buck2's cut line is final: the line is the test's, after its output marker" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_failed, "[2026-10-25T13:04:11.131+00:00] The library's package", "[2026-10-25T13:04:11.131+00:00] " ++ cut_error ++ "\n[2026-10-25T13:04:11.131+00:00] The library's package");
    try expectFinal(log, .failure, "[2026-10-25T13:04:11.131+00:00] \xe2\x9c\x97 Fail: komira//src/komira_proto_codec:test_float32_json_binades (9:00.5s)");
}

test "a cut test with any output of its own is final: the test ran" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = unrun_fail ++ "\n" ++ unrun_stdout;
    // stdout that is not empty
    try expectFinal(try edit(a, test_cut, head, head ++ own), .failure, unrun_fail);
    // a line before the two lines of buck2's, between them, after them
    try expectFinal(try edit(a, test_cut, head ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_stderr, head ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_stderr ++ own), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ own ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ own ++ unrun_next), .failure, unrun_fail);
}

test "a failed test whose stderr has only one of buck2's two cut-run lines, or both out of order, is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const first = unrun_execute ++ unrun_cut ++ unrun_next;
    try expectFinal(try edit(a, test_cut, first, unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, first, unrun_execute ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, first, unrun_cut ++ unrun_execute ++ unrun_next), .failure, unrun_fail);
}

test "a failed test whose output is only buck2's stderr of a cut run is a cut, with or without its stdout" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the first test's stdout section dropped: its head goes straight to STDERR
    try expectCut(try edit(a, test_cut, unrun_fail ++ "\n" ++ unrun_stdout ++ "[2026-11-25T02:24:32.807+00:00]\n", unrun_fail ++ "\n"), 56);
    // the log ends right after the first test's output, with no counts after it
    const end = std.mem.indexOf(u8, test_cut, unrun_next).?;
    try expectCut(test_cut[0..end], 1);
}

test "a cut test with a line of its own without buck2's prefix is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const head = unrun_fail ++ "\n" ++ unrun_stdout;
    try expectFinal(try edit(a, test_cut, head, head ++ "the test's own line\n"), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_cut ++ unrun_next, unrun_cut ++ "the test's own line\n" ++ unrun_next), .failure, unrun_fail);
}

test "a cut test whose two lines are not back to back, or come twice, is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ "[2026-11-25T02:24:32.807+00:00]\n" ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ unrun_cut ++ unrun_next), .failure, unrun_fail);
    try expectFinal(try edit(a, test_cut, unrun_execute ++ unrun_cut ++ unrun_next, unrun_execute ++ unrun_cut ++ unrun_stdout ++ unrun_next), .failure, unrun_fail);
}

test "a passing test whose output is buck2's cut-run lines is judged as before: its cut line is outside the block" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const pass = "[2026-11-25T02:24:32.807+00:00] \xe2\x9c\x93 Pass: komira//tools/build/third_party_srcs:aws_lc_mini_files_check (0.0s)";
    const log = try edit(arena.allocator(), test_cut, unrun_fail ++ "\n", pass ++ "\n");
    try expectFinal(log, .unexplained, unrun_cut[0 .. unrun_cut.len - 1]);
}

test "a compile error whose output quotes the phrase is final: an action's output is not buck2's line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the compile error alone: the recorded run without its cut blocks
    const alone = try dropBlocks(a, build_mixed, "Action failed: komira//tools/build/proto-codegen");
    try t.expect(std.mem.indexOf(u8, alone, "RE channel error") == null);
    try expectFinal(alone, .failure, compile_error);
    try expectFinal(try edit(a, alone, "1 error generated.\n", cut_error ++ "\n1 error generated.\n"), .failure, compile_error);
}

test "an action that failed on its own and quotes the cut line after Stderr is final" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)\n" ++
        "[2026-11-21T16:00:00.000+00:00] Remote command returned non-zero exit code 1\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stderr:\n" ++
        "[2026-11-21T15:59:59.000+00:00] " ++ cut_error ++ "\n\n" ++
        "BUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)");
}

test "a cut line without buck2's prefix in a block's head does not make it a cut" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)\n" ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n\nBUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)");
}

test "a block whose head has an error other than the channel's is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_cut, "RE channel error: code: 'Unknown error'", "RE upload error: code: 'Unknown error'");
    try expectFinal(log, .failure, "[2026-11-21T16:48:35.653+00:00] Action failed: komira//src/bench_q6_phases:komira_bench_q6_phases_main (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (mojo_build)");
}

test "an error outside every block is final, though every block is a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const other = "[2026-11-21T15:40:34.803+00:00] Error: (Failed to make BatchReadBlobs request: code: 'The operation was cancelled', message: \"operation was canceled\")";
    const log = try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", other ++ "\n[2026-11-21T16:48:35.702+00:00] Cache hits");
    try expectFinal(log, .unexplained, other);
}

test "a compile error after buck2's changed-file lines is final: the lines excuse no failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try expectFinal(try edit(arena.allocator(), build_mixed, compile_error, file_changes ++ compile_error), .failure, compile_error);
}

test "a line only shaped like buck2's changed-file lines is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const at = "[2026-11-21T16:23:14.887+00:00] RE Session";
    inline for ([_][]const u8{
        "[2026-11-25T00:07:53.435+00:00] File changed: ",
        "[2026-11-25T00:07:53.435+00:00] File changed: komira//src/a/mopm.toml Error: boom",
        "[2026-11-25T00:07:53.435+00:00] additional file change events",
        "[2026-11-25T00:07:53.435+00:00] 415 additional file change events, and an error",
        "[2026-11-25T00:07:53.435+00:00] x415 additional file change events",
        "File changed: komira//src/anomaly/mopm.toml",
    }) |line| {
        try expectFinal(try edit(arena.allocator(), build_cut, at, line ++ "\n" ++ at), .unexplained, line);
    }
}

test "a bare cut line outside every block is not a block: the log is final" {
    try expectFinal("[2026-11-21T16:00:00.000+00:00] " ++ cut_error ++ "\nBUILD FAILED\n", .unexplained, "[2026-11-21T16:00:00.000+00:00] " ++ cut_error);
}

test "an error of buck2's own log at ERROR level is not a warning: final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "[2026-11-21T15:40:33.203+00:00] 2026-11-21T15:40:33.120769Z ERROR buck2_server: the daemon lost its state";
    try expectFinal(try edit(arena.allocator(), build_cut, "[2026-11-21T16:48:35.702+00:00] Cache hits", line ++ "\n[2026-11-21T16:48:35.702+00:00] Cache hits"), .unexplained, line);
}

test "an error after a passing test's output is judged outside the block: final, though the test may have printed it" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: komira//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00] checking the error path\n" ++
        "[2026-11-21T16:00:01.000+00:00] Error: the analysis of komira//src/c:c failed\n" ++ cut_block ++
        "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n";
    try expectFinal(log, .unexplained, "[2026-11-21T16:00:01.000+00:00] Error: the analysis of komira//src/c:c failed");
}

test "a passing test's other output stays in its block beside a cut" {
    const log = "[2026-11-21T16:00:01.000+00:00] \xe2\x9c\x93 Pass: komira//src/b:test_b (0.4s)\n" ++
        "[2026-11-21T16:00:01.000+00:00] ---- STDOUT ----\n" ++
        "[2026-11-21T16:00:01.000+00:00] FAIL is what this test checks the parser rejects\n" ++
        "[2026-11-21T16:00:01.000+00:00]\n" ++ cut_block ++
        "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1\n";
    try expectCut(log, 1);
}

test "a line of buck2's between an action's Stdout and Stderr ends the block" {
    const line = "[2026-11-21T16:00:00.000+00:00] Error: the daemon went away";
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (mojo_build)\n" ++
        "[2026-11-21T16:00:00.000+00:00] " ++ cut_error ++ "\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout:\nsome output\n" ++ line ++ "\nBUILD FAILED\n";
    try expectFinal(log, .unexplained, line);
}

test "an error after BUILD FAILED is final: an analysis error is not a cut" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\nError running analysis for `komira//src/c:c`\n");
    try expectFinal(log, .unexplained, "Error running analysis for `komira//src/c:c`");
}

test "a recorded analysis failure with no block is final" {
    try expectFinal(build_unknown_target, .unexplained, "Unknown target `nonexistent` from package `komira//tools/build/ci/parity`.");
}

test "a target buck2 failed to build with no failed action of its own is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "Failed to build 'komira//src/other:other (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be)'";
    try expectFinal(try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\n" ++ line ++ "\n"), .unmatched_target, line);
}

test "a target named by a prefix of a cut block's target is not matched by it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const line = "Failed to build 'komira//src/bench_q6_phases:komira_bench_q6'";
    try expectFinal(try edit(arena.allocator(), build_cut, "BUILD FAILED\n", "BUILD FAILED\n" ++ line ++ "\n"), .unmatched_target, line);
}

test "a fatal test is final, even beside cuts" {
    const fatal = "[2026-11-21T16:00:02.000+00:00] \xe2\x9a\xa0 Fatal: komira//src/b:test_b";
    try expectFinal(cut_block ++ fatal ++ "\n", .test_status, fatal);
}

test "a timed-out, fatal or infrastructure-failed count on the test line is final" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const counts = "Tests finished: Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectCut(cut_block ++ counts ++ "\n", 1);
    for ([_][]const u8{ "Timeout 0", "Fatal 0", "Infra Failure 0" }) |zero| {
        const one = try std.mem.replaceOwned(u8, a, zero, "0", "2");
        const line = try std.mem.replaceOwned(u8, a, counts, zero, one);
        try expectFinal(try std.mem.concat(a, u8, &.{ cut_block, line, "\n" }), .test_status, line);
    }
    // a line without one of the counts cannot show it is zero
    const short = "Tests finished: Pass 1. Fail 0. Timeout 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectFinal(cut_block ++ short ++ "\n", .test_status, short);
    const listing = "Tests finished: Listing failed 1. Pass 1. Fail 0. Timeout 0. Fatal 0. Skip 0. Omit 0. Infra Failure 0. Build failure 1";
    try expectFinal(cut_block ++ listing ++ "\n", .test_status, listing);
}

test "a failed run with no failure block is final" {
    try expectFinal("", .no_failure, "");
    try expectFinal("[2026-11-21T16:00:00.000+00:00] Build ID: 00000000-0000-0000-0000-000000000000\nBUILD FAILED\n", .no_failure, "");
    // a buck2 that exited non-zero after it said the build succeeded
    try expectFinal(@embedFile("fixtures/build_remote.log"), .no_failure, "");
}

// ---- a job the farm failed to start, run again --------------------------------

test "a recorded build whose every failure is a job the farm failed to start (input-unavailable) is the farm's, counting each block" {
    // one action, printed once as it failed and once under BUILD ERRORS
    try expectFarm(build_input_unavailable, .{ .input_unavailable = 2 });
}

test "input-unavailable blocks beside cut blocks are the farm's, each counted by its cause" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const at = "[2026-11-27T05:17:43.708+00:00] Cache hits";
    try expectFarm(try edit(arena.allocator(), build_input_unavailable, at, cut_block ++ at), .{ .cut = 1, .input_unavailable = 2 });
}

test "a job the farm failed to start for another reason is final: only input-unavailable is run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "input-not-allowed", "rootfs-unsupported-here", "invalid-mount" }) |code| {
        try expectFinal(try edit(a, build_input_unavailable, "failed to start: input-unavailable)", try std.mem.concat(a, u8, &.{ "failed to start: ", code, ")" })), .failure, unavailable_first);
    }
}

test "the input-unavailable line counts only word for word" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // more after it, its closing parenthesis gone, another stream's error before it
    try expectFinal(try edit(a, build_input_unavailable, unavailable_error, unavailable_error ++ " and more"), .failure, unavailable_first);
    try expectFinal(try edit(a, build_input_unavailable, unavailable_error, unavailable_error[0 .. unavailable_error.len - 1]), .failure, unavailable_first);
    try expectFinal(try edit(a, build_input_unavailable, "by RE: the job failed", "by CAS: the job failed"), .failure, unavailable_first);
}

test "the input-unavailable line without buck2's prefix in a block's head does not make it the farm's" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)\n" ++ unavailable_error ++ "\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n\nBUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)");
}

test "an action that failed on its own and quotes the input-unavailable line after Stderr is final" {
    const log = "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)\n" ++
        "[2026-11-21T16:00:00.000+00:00] Remote command returned non-zero exit code 1\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stdout: <empty>\n" ++
        "[2026-11-21T16:00:00.000+00:00] Stderr:\n" ++
        "[2026-11-21T15:59:59.000+00:00] " ++ unavailable_error ++ "\n\n" ++
        "BUILD FAILED\n";
    try expectFinal(log, .failure, "[2026-11-21T16:00:00.000+00:00] Action failed: komira//src/a:a (cfg) (zig_test)");
}

test "a failed test the farm never started (input-unavailable after buck2's Execute line) is the farm's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const end = std.mem.indexOf(u8, test_cut, unrun_next).?;
    const unavailable = "[2026-11-25T02:24:32.807+00:00] " ++ unavailable_error ++ "\n";
    try expectFarm(try edit(a, test_cut[0..end], unrun_cut, unavailable), .{ .input_unavailable = 1 });
    // with a line of the test's own after it, the test ran: final
    try expectFinal(try edit(a, test_cut[0..end], unrun_cut, unavailable ++ own), .failure, unrun_fail);
}

test "the verdict says why, for the job log" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .farm = .{ .cut = 4 } }, &w);
    try t.expectEqualStrings("every failure (4 block(s)) is a cut connection to the farm (buck2's `RE channel error`)", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .farm = .{ .input_unavailable = 2 } }, &w);
    try t.expectEqualStrings("every failure (2 block(s)) is a job the farm failed to start (the farm's `input-unavailable`)", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .farm = .{ .cut = 1, .input_unavailable = 2 } }, &w);
    try t.expectEqualStrings("every failure (3 block(s)) is the farm's: 1 a cut connection (buck2's `RE channel error`), 2 a job it failed to start (the farm's `input-unavailable`)", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .failure = "X" }, &w);
    try t.expectEqualStrings("a failure that is not a cut connection: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .test_status = "X" }, &w);
    try t.expectEqualStrings("a test result a cut connection does not explain: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .unexplained = "X" }, &w);
    try t.expectEqualStrings("an error outside the failed actions and tests: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.{ .unmatched_target = "X" }, &w);
    try t.expectEqualStrings("a target failed with no failed action of its own: X", w.buffered());
    w = std.Io.Writer.fixed(&buf);
    try fr.describe(.no_failure, &w);
    try t.expectEqualStrings("no failed action or test in the log", w.buffered());
}

// ---- what runs again, and where its first log goes ----------------------------

test "only build, test and bxl run again" {
    try t.expect(fr.retriable("build"));
    try t.expect(fr.retriable("test"));
    try t.expect(fr.retriable("bxl"));
    for ([_][]const u8{ "run", "install", "uquery", "Build", "" }) |s| try t.expect(!fr.retriable(s));
}

test "a log run again is kept beside the log, as <name>.<ordinal>.log" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/r/buck2-farm.first.log", try fr.keptLogPath(a, "/r/buck2-farm.log", "first"));
    try t.expectEqualStrings("/r/buck2-farm.second.log", try fr.keptLogPath(a, "/r/buck2-farm.log", "second"));
    try t.expectEqualStrings("/r/out.first", try fr.keptLogPath(a, "/r/out", "first"));
}

test "a step runs at most three times, and its runs are named first, second, third" {
    try t.expectEqual(@as(usize, 3), fr.max_runs);
    try t.expectEqualStrings("first", fr.ordinal(1));
    try t.expectEqualStrings("second", fr.ordinal(2));
    try t.expectEqualStrings("third", fr.ordinal(3));
    try t.expectEqualStrings("next", fr.ordinal(4));
}

test "a wrong command line prints the usage and exits 2, running nothing" {
    var buf: [512]u8 = undefined;
    const cases = [_][]const [:0]const u8{
        &.{},
        &.{ "--log", "l.log", "--summary", "s.md", "--farm-config", "f" }, // no command
        &.{ "--log", "l.log", "--summary", "s.md", "--farm-config", "f", "--", "./buck2" }, // no subcommand
        &.{ "--summary", "s.md", "--farm-config", "f", "--", "./buck2", "build" }, // no log
        &.{ "--log", "l.log", "--farm-config", "f", "--", "./buck2", "build" }, // no summary
        &.{ "--log", "l.log", "--summary", "s.md", "--", "./buck2", "build" }, // no farm config
        &.{ "--log", "", "--summary", "s.md", "--farm-config", "f", "--", "./buck2", "build" }, // an empty log path
        &.{ "--log", "l.log", "--summary", "", "--farm-config", "f", "--", "./buck2", "build" }, // an empty summary (unset on the runner)
        &.{ "--log", "l.log", "--summary", "s.md", "--farm-config", "", "--", "./buck2", "build" }, // an empty farm config
        &.{ "--log", "l.log", "--other", "x", "--", "./buck2", "build" },
        &.{ "--log", "l.log", "--summary" },
    };
    for (cases) |args| {
        var w = std.Io.Writer.fixed(&buf);
        try t.expectEqual(@as(u8, 2), try fr.main(t.allocator, args, 1 << 20, &w));
        try t.expectEqualStrings(fr.usage, w.buffered());
    }
}

// ---- the wait for the farm before a run again (farm_wait.zig) -----------------

/// The machine buckconfig farm-connect writes with its default inputs.
const farm_config =
    \\[komira_ci]
    \\  farm_wait_seconds = 1200
    \\[buck2_re_client]
    \\  engine_address = grpc://re.example.com:8980
    \\  action_cache_address = grpc://re.example.com:8980
    \\  cas_address = grpc://re.example.com:8980
    \\  instance_name = main
    \\  tls = false
    \\[komira_re]
    \\  linux_x86_64_properties = OSFamily=Linux,pool=linux
    \\
;

test "the farm config farm-connect writes gives the farm's host, port and longest wait" {
    const f = try fw.parseConfig(farm_config);
    try t.expectEqualStrings("re.example.com", f.host);
    try t.expectEqual(@as(u16, 8980), f.port);
    try t.expectEqual(@as(u32, 1200), f.wait_seconds);
}

test "an engine address is read as farm-connect reads FARM_ADDRESS: scheme, path and brackets dropped" {
    const cases = [_]struct { address: []const u8, host: []const u8, port: u16 }{
        .{ .address = "grpcs://re.example.com:443", .host = "re.example.com", .port = 443 },
        .{ .address = "re.example.com:8980", .host = "re.example.com", .port = 8980 },
        .{ .address = "grpc://re.example.com:8980/instance", .host = "re.example.com", .port = 8980 },
        .{ .address = "grpc://[::1]:8980", .host = "::1", .port = 8980 },
        .{ .address = "grpc://192.0.2.7:65535", .host = "192.0.2.7", .port = 65535 },
    };
    var buf: [256]u8 = undefined;
    for (cases) |c| {
        const text = try std.fmt.bufPrint(&buf, "[buck2_re_client]\nengine_address={s}\n[komira_ci]\nfarm_wait_seconds = 0\r\n", .{c.address});
        const f = try fw.parseConfig(text);
        try t.expectEqualStrings(c.host, f.host);
        try t.expectEqual(c.port, f.port);
        try t.expectEqual(@as(u32, 0), f.wait_seconds);
    }
}

test "a farm config with no farm, or no longest wait, is refused by name" {
    const wait = "[komira_ci]\n  farm_wait_seconds = 60\n";
    try t.expectError(error.NoEngineAddress, fw.parseConfig(wait));
    // the key in another section is not buck2's address
    try t.expectError(error.NoEngineAddress, fw.parseConfig(wait ++ "[komira_re]\n  engine_address = grpc://re.example.com:8980\n"));
    for ([_][]const u8{ "grpc://re.example.com", "re.example.com:", "re.example.com:80a", "grpc://:8980", "re.example.com:0", "re.example.com:70000", "[]:8980" }) |bad| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{s}[buck2_re_client]\n  engine_address = {s}\n", .{ wait, bad });
        try t.expectError(error.BadEngineAddress, fw.parseConfig(text));
    }
    const address = "[buck2_re_client]\n  engine_address = grpc://re.example.com:8980\n";
    try t.expectError(error.NoWaitSeconds, fw.parseConfig(address));
    try t.expectError(error.NoWaitSeconds, fw.parseConfig(address ++ "[komira_re]\n  farm_wait_seconds = 60\n"));
    for ([_][]const u8{ "", "20m", "-1", "1.5", "99999999999" }) |bad| {
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "{s}[komira_ci]\n  farm_wait_seconds = {s}\n", .{ address, bad });
        try t.expectError(error.BadWaitSeconds, fw.parseConfig(text));
    }
}

test "each refused farm config says what is missing" {
    try t.expectEqualStrings("it has no engine_address under [buck2_re_client]", fw.describeConfigError(error.NoEngineAddress));
    try t.expectEqualStrings("its engine_address is not <host>:<port>", fw.describeConfigError(error.BadEngineAddress));
    try t.expectEqualStrings("it has no farm_wait_seconds under [komira_ci]", fw.describeConfigError(error.NoWaitSeconds));
    try t.expectEqualStrings("its farm_wait_seconds is not a whole number of seconds", fw.describeConfigError(error.BadWaitSeconds));
}

/// A clock that moves only when the wait sleeps or a probe takes its time.
const FakeClock = struct {
    now_s: u64 = 0,
    sleeps: usize = 0,
    /// Set by a sleep of 0 s or of more than `probe_seconds`, which no wait asks for.
    odd_sleep: bool = false,
    pub fn now(c: *FakeClock) u64 {
        return c.now_s;
    }
    pub fn sleep(c: *FakeClock, s: u64) void {
        if (s == 0 or s > fw.probe_seconds) c.odd_sleep = true;
        c.now_s += s;
        c.sleeps += 1;
    }
};

/// A farm that answers once the clock reaches `answers_from` (never when
/// null); a probe it does not answer takes `cost` seconds, as a connection
/// left unanswered for its 5 s does.
const FakeFarm = struct {
    clock: *FakeClock,
    answers_from: ?u64,
    cost: u64 = fw.probe_seconds,
    probes: usize = 0,
    pub fn answers(f: *FakeFarm) bool {
        f.probes += 1;
        if (f.answers_from) |from| if (f.clock.now_s >= from) return true;
        f.clock.now_s += f.cost;
        return false;
    }
};

test "a farm that answers the first probe: no wait, no sleep, nothing in the job log" {
    var clock: FakeClock = .{};
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = 0 };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(fw.Waited{ .answered = 0 }, try fw.waitForFarm(&clock, &farm, 1200, &w));
    try t.expectEqual(@as(usize, 1), farm.probes);
    try t.expectEqual(@as(usize, 0), clock.sleeps);
    try t.expectEqualStrings("", w.buffered());
}

test "a farm back after three minutes: answered with the time waited, a line for each whole minute" {
    var clock: FakeClock = .{};
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = 185 };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // probes start at 0, 10, 20, ...: each unanswered one takes 5 s, then 5 s of sleep
    try t.expectEqual(fw.Waited{ .answered = 190 }, try fw.waitForFarm(&clock, &farm, 1200, &w));
    try t.expectEqual(@as(usize, 20), farm.probes);
    try t.expect(!clock.odd_sleep);
    try t.expectEqualStrings(
        "buck2-farm: the farm has not answered for 1 min 5 s; waiting up to 20 min 0 s\n" ++
            "buck2-farm: the farm has not answered for 2 min 5 s; waiting up to 20 min 0 s\n" ++
            "buck2-farm: the farm has not answered for 3 min 5 s; waiting up to 20 min 0 s\n",
        w.buffered(),
    );
}

test "a farm that never answers: the wait gives up once the bound has passed, its last sleep cut to the bound" {
    var clock: FakeClock = .{};
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = null };
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    // the probe that starts at the bound (1200 s) is the last; it takes its 5 s
    try t.expectEqual(fw.Waited{ .gave_up = 1205 }, try fw.waitForFarm(&clock, &farm, 1200, &w));
    try t.expectEqual(@as(usize, 121), farm.probes);
    try t.expectEqual(@as(usize, 120), clock.sleeps);
    try t.expect(!clock.odd_sleep);
    const out = w.buffered();
    try t.expectEqual(@as(usize, 19), std.mem.count(u8, out, "\n"));
    try t.expect(std.mem.startsWith(u8, out, "buck2-farm: the farm has not answered for 1 min 5 s; waiting up to 20 min 0 s\n"));
    try t.expect(std.mem.endsWith(u8, out, "buck2-farm: the farm has not answered for 19 min 5 s; waiting up to 20 min 0 s\n"));
}

test "the bound does not fall between two probes: a sleep never passes it" {
    var clock: FakeClock = .{};
    // a refused connection takes no time
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = null, .cost = 0 };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(fw.Waited{ .gave_up = 7 }, try fw.waitForFarm(&clock, &farm, 7, &w));
    // probes at 0, 5 and 7: the second sleep is 2 s, the rest of the bound
    try t.expectEqual(@as(usize, 3), farm.probes);
    try t.expectEqual(@as(usize, 2), clock.sleeps);
    try t.expect(!clock.odd_sleep);
}

test "a bound of 0: one probe, no sleep" {
    var clock: FakeClock = .{};
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = null, .cost = 0 };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(fw.Waited{ .gave_up = 0 }, try fw.waitForFarm(&clock, &farm, 0, &w));
    try t.expectEqual(@as(usize, 1), farm.probes);
    try t.expectEqual(@as(usize, 0), clock.sleeps);
}

test "a probe that takes past a minute gets one line with the time, not one per minute missed" {
    var clock: FakeClock = .{};
    var farm: FakeFarm = .{ .clock = &clock, .answers_from = null, .cost = 130 };
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try t.expectEqual(fw.Waited{ .gave_up = 265 }, try fw.waitForFarm(&clock, &farm, 200, &w));
    try t.expectEqualStrings("buck2-farm: the farm has not answered for 2 min 10 s; waiting up to 3 min 20 s\n", w.buffered());
}

test "a wait is given in minutes and seconds" {
    var buf: [64]u8 = undefined;
    for ([_]struct { s: u64, want: []const u8 }{
        .{ .s = 0, .want = "0 min 0 s" },
        .{ .s = 59, .want = "0 min 59 s" },
        .{ .s = 60, .want = "1 min 0 s" },
        .{ .s = 3725, .want = "62 min 5 s" },
    }) |c| {
        var w = std.Io.Writer.fixed(&buf);
        try fw.writeDuration(&w, c.s);
        try t.expectEqualStrings(c.want, w.buffered());
    }
}

test "the job summary line names the wait: at once, for how long, or past the longest wait" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "buck2-farm: the first run of `build` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 4 failed block(s)); the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log",
        try fr.summaryLine(a, "build", 1, .{ .cut = 4 }, .{ .answered = 0 }, "buck2-farm.first.log"),
    );
    try t.expectEqualStrings(
        "buck2-farm: the second run of `test` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 1 failed block(s)); farm unreachable for 3 min 10 s; ran again (run 3 of at most 3); the second run's log is buck2-farm.second.log",
        try fr.summaryLine(a, "test", 2, .{ .cut = 1 }, .{ .answered = 190 }, "buck2-farm.second.log"),
    );
    try t.expectEqualStrings(
        "buck2-farm: the first run of `bxl` was cut by a lost connection to the farm (buck2's `RE channel error` in each of 2 failed block(s)); farm unreachable for 20 min 5 s, the longest wait; not run again",
        try fr.summaryLine(a, "bxl", 1, .{ .cut = 2 }, .{ .gave_up = 1205 }, "unused"),
    );
}

test "the job summary line names the farm's cause: input-unavailable alone, or beside cuts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "buck2-farm: the first run of `build` had jobs the farm failed to start (the farm's `input-unavailable` in each of 2 failed block(s)); the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log",
        try fr.summaryLine(a, "build", 1, .{ .input_unavailable = 2 }, .{ .answered = 0 }, "buck2-farm.first.log"),
    );
    try t.expectEqualStrings(
        "buck2-farm: the second run of `test` was cut by a lost connection to the farm and had jobs the farm failed to start (buck2's `RE channel error` in 3 and the farm's `input-unavailable` in 1 failed block(s)); farm unreachable for 20 min 5 s, the longest wait; not run again",
        try fr.summaryLine(a, "test", 2, .{ .cut = 3, .input_unavailable = 1 }, .{ .gave_up = 1205 }, "unused"),
    );
}

test "the real probe: a listening loopback port answers, a bound one that does not listen does not" {
    const listen_at = try std.net.Address.parseIp("127.0.0.1", 0);
    var server = try listen_at.listen(.{});
    defer server.deinit();
    try t.expect((fw.TcpProber{ .a = t.allocator, .host = "127.0.0.1", .port = server.listen_address.getPort() }).answers());

    // a port bound and not listening refuses every connection, and no other socket can take it
    const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(fd);
    var addr = try std.net.Address.parseIp("127.0.0.1", 0);
    try std.posix.bind(fd, &addr.any, addr.getOsSockLen());
    var len = addr.getOsSockLen();
    try std.posix.getsockname(fd, &addr.any, &len);
    try t.expect(!(fw.TcpProber{ .a = t.allocator, .host = "127.0.0.1", .port = addr.getPort() }).answers());
}

test "the real clock reads at least the seconds slept" {
    var clock = try fw.RealClock.init();
    clock.slept = 42; // as after 42 s of sleep
    try t.expect(clock.now() >= 42);
}

test "the job summary line of a run the watchdog ended names the silence, the bound and the wait" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "buck2-farm: the first run of `build` hung on a dead connection to the farm (nothing heard for 5 min 1 s, past the watchdog's bound of 5 min 0 s), so buck2 and its daemon were ended; the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log",
        try fr.deadSummaryLine(a, "build", 1, 301_400, 300_000, .{ .answered = 0 }, "buck2-farm.first.log"),
    );
    try t.expectEqualStrings(
        "buck2-farm: the second run of `test` hung on a dead connection to the farm (nothing heard for 220 min 0 s, past the watchdog's bound of 5 min 0 s), so buck2 and its daemon were ended; farm unreachable for 20 min 5 s, the longest wait; not run again",
        try fr.deadSummaryLine(a, "test", 2, 13_200_000, 300_000, .{ .gave_up = 1205 }, "unused"),
    );
}
