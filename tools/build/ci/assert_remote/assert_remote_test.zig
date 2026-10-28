//! Each test is a defect assert_remote would let through if it were wrong.
//! The logs in fixtures/ are recorded buck2 output (a build, a bxl run, each
//! once with actions run on the farm and once fully cached, and a failed
//! build). A log buck2 never printed here (an action run locally, a changed
//! summary) is a recorded one with the one line changed, in the test.
const std = @import("std");
const ar = @import("assert_remote.zig");
const t = std.testing;

const build_remote = @embedFile("fixtures/build_remote.log");
const build_cached = @embedFile("fixtures/build_cached.log");
const bxl_remote = @embedFile("fixtures/bxl_remote.log");
const bxl_cached = @embedFile("fixtures/bxl_cached.log");
const build_unknown_target = @embedFile("fixtures/build_failed_unknown_target.log");
const test_none_ran = @embedFile("fixtures/test_none_ran.log");
const test_cached_remote = @embedFile("fixtures/test_cached_remote.log");

fn edit(a: std.mem.Allocator, log: []const u8, from: []const u8, to: []const u8) ![]u8 {
    try t.expect(std.mem.indexOf(u8, log, from) != null); // the recorded log has the line the case changes
    return std.mem.replaceOwned(u8, a, log, from, to);
}

fn drop(a: std.mem.Allocator, log: []const u8, prefix_of_line: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var it = std.mem.splitScalar(u8, log, '\n');
    var dropped: usize = 0;
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, prefix_of_line) != null) {
            dropped += 1;
            continue;
        }
        try out.appendSlice(a, l);
        try out.append(a, '\n');
    }
    try t.expect(dropped == 1);
    return out.toOwnedSlice(a);
}

test "a build whose actions all ran remotely passes" {
    try t.expectEqual(ar.Verdict.ok, ar.verdict(build_remote));
}

test "a bxl run whose actions all ran remotely passes: bxl prints the same summary" {
    try t.expect(std.mem.indexOf(u8, bxl_remote, "Commands: 5 (cached: 3, remote: 2, local: 0)") != null);
    try t.expectEqual(ar.Verdict.ok, ar.verdict(bxl_remote));
}

test "a fully cached build prints no summary and passes on its zero-byte network line" {
    try t.expect(std.mem.indexOf(u8, build_cached, "Commands:") == null);
    try t.expectEqual(ar.Verdict.ok, ar.verdict(build_cached));
}

test "a fully cached bxl run prints no summary and passes on its zero-byte network line" {
    try t.expect(std.mem.indexOf(u8, bxl_cached, "Commands:") == null);
    try t.expectEqual(ar.Verdict.ok, ar.verdict(bxl_cached));
}

test "a test run with nothing to execute passes: no action, no summary" {
    try t.expectEqual(ar.Verdict.ok, ar.verdict(test_none_ran));
}

test "a test run whose results all came from the farm's cache passes: no build action, no summary, bytes moved" {
    try t.expect(std.mem.indexOf(u8, test_cached_remote, "Commands:") == null);
    try t.expect(std.mem.indexOf(u8, test_cached_remote, "Cache hits:") == null);
    try t.expect(std.mem.indexOf(u8, test_cached_remote, "Network: up 0B") == null);
    try t.expectEqual(ar.Verdict.ok, ar.verdict(test_cached_remote));
}

test "a test run with a cache-hits line but no summary fails: a build action ran and its summary is missing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_cached_remote, "Network: up 11KiB", "Cache hits: 100%\nNetwork: up 11KiB");
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict(log));
}

test "a test run whose summary counts a local action fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), test_cached_remote, "Network: up 11KiB", "Cache hits: 0%\nCommands: 2 (cached: 0, remote: 0, local: 2)\nNetwork: up 11KiB");
    try t.expectEqual(ar.Verdict{ .local_execution = 2 }, ar.verdict(log));
}

test "a build with no summary and bytes moved fails even without a cache-hits line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const log = try drop(a, try drop(a, build_remote, "Commands:"), "Cache hits:");
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict(log));
}

test "local: 3 fails and names the count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_remote, "local: 0)", "local: 3)");
    try t.expectEqual(ar.Verdict{ .local_execution = 3 }, ar.verdict(log));
}

test "local: 10 fails: the count is read whole, not as a prefix 1 or as a leading 0 test" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_remote, "local: 0)", "local: 10)");
    try t.expectEqual(ar.Verdict{ .local_execution = 10 }, ar.verdict(log));
}

test "a bxl run with a local action fails like a build" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), bxl_remote, "local: 0)", "local: 1)");
    try t.expectEqual(ar.Verdict{ .local_execution = 1 }, ar.verdict(log));
}

test "two summaries: one local action anywhere fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = try edit(a, build_remote, "local: 0)", "local: 2)");
    const both = try std.mem.concat(a, u8, &.{ build_remote, bad });
    try t.expectEqual(ar.Verdict{ .local_execution = 2 }, ar.verdict(both));
}

test "no summary line while bytes moved fails: output of another shape is not a pass" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try drop(arena.allocator(), build_remote, "Commands:");
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict(log));
}

test "a renamed summary line fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_remote, "Commands:", "Actions:");
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict(log));
}

test "a summary with no local field fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_remote, ", local: 0)", ")");
    try t.expectEqual(ar.Verdict.unreadable_summary, ar.verdict(log));
}

test "an empty log fails" {
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict(""));
}

test "a failed run fails even with a good summary above it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), build_remote, "BUILD SUCCEEDED", "BUILD FAILED");
    try t.expectEqual(ar.Verdict.run_failed, ar.verdict(log));
}

test "a failed run with no action fails: the zero-byte network line does not excuse it" {
    try t.expectEqual(ar.Verdict.run_failed, ar.verdict(build_unknown_target));
}

test "a failed bxl run fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const log = try edit(arena.allocator(), bxl_cached, "BXL SUCCEEDED", "BXL FAILED");
    try t.expectEqual(ar.Verdict.run_failed, ar.verdict(log));
}

test "CRLF line ends read the same" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const crlf = try std.mem.replaceOwned(u8, a, build_remote, "\n", "\r\n");
    try t.expectEqual(ar.Verdict.ok, ar.verdict(crlf));
    const bad = try edit(a, crlf, "local: 0)", "local: 4)");
    try t.expectEqual(ar.Verdict{ .local_execution = 4 }, ar.verdict(bad));
}

test "a network line with traffic is not the zero line" {
    try t.expectEqual(ar.Verdict.missing_summary, ar.verdict("Network: up 0B  down 12KiB\nBUILD SUCCEEDED\n"));
    try t.expectEqual(ar.Verdict.ok, ar.verdict("Network: up 0B  down 0B  session X\nBUILD SUCCEEDED\n"));
}

test "the log cap holds the 530 MB log a large affected set printed" {
    try t.expect(ar.max_log_bytes >= 600 * 1000 * 1000);
}
