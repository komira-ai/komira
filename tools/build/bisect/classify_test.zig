//! The classifier's cases, over build reports the pinned buck2 wrote
//! (README.md, "Tests", says how each was captured).
const std = @import("std");
const classify = @import("classify.zig");
const t = std.testing;

const ACTION_FAILED = @embedFile("testdata/report_action_failed.json");
const ANALYSIS_FAILED = @embedFile("testdata/report_analysis_failed.json");
const SUCCESS = @embedFile("testdata/report_success.json");

const RED = "//tools/build/bisect/capture_tmp:red";

test "exit 3 and a failed action of a given target: fail, with the action's stderr as the excerpt" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try classify.classify(arena.allocator(), 3, .build, ACTION_FAILED, &.{RED});
    try t.expectEqual(classify.Outcome.fail, c.outcome);
    try t.expectEqual(@as(usize, 1), c.failures.len);
    try t.expectEqualStrings(RED, c.failures[0].target);
    try t.expect(std.mem.startsWith(u8, c.failures[0].excerpt, "1/1 red.test.planted red... FAIL (TestUnexpectedResult)"));
}

test "a given target with its cell names the same label" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try classify.classify(arena.allocator(), 3, .build, ACTION_FAILED, &.{"komira" ++ RED});
    try t.expectEqual(classify.Outcome.fail, c.outcome);
}

test "exit 3 and an analysis error of a given target: fail, with the error message as the excerpt" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try classify.classify(arena.allocator(), 3, .build, ANALYSIS_FAILED, &.{"//tools/build/bisect/capture_tmp/..."});
    try t.expectEqual(classify.Outcome.fail, c.outcome);
    try t.expectEqualStrings("//tools/build/bisect/capture_tmp:std", c.failures[0].target);
    try t.expect(std.mem.startsWith(u8, c.failures[0].excerpt, "Error running analysis for"));
}

test "exit 3 whose report names none of the given targets as failed: infra, never fail" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const c = try classify.classify(arena.allocator(), 3, .build, ACTION_FAILED, &.{"//other:x"});
    try t.expectEqual(classify.Outcome.infra, c.outcome);
    const s = try classify.classify(arena.allocator(), 3, .build, SUCCESS, &.{"//tools/build/bisect/capture_tmp:green"});
    try t.expectEqual(classify.Outcome.infra, s.outcome);
}

test "exit 3 with no report, or one that is not JSON: infra" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(classify.Outcome.infra, (try classify.classify(arena.allocator(), 3, .build, null, &.{RED})).outcome);
    try t.expectEqual(classify.Outcome.infra, (try classify.classify(arena.allocator(), 3, .build, ACTION_FAILED[0..100], &.{RED})).outcome);
    try t.expectEqual(classify.Outcome.infra, (try classify.classify(arena.allocator(), 3, .build, "[]", &.{RED})).outcome);
}

test "every exit other than 0 and 3 is infra, even beside a report naming the target as failed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    for ([_]u8{ 1, 2, 4, 5, 6, 11, 12, 32, 130, 141 }) |code| {
        const c = try classify.classify(arena.allocator(), code, .build, ACTION_FAILED, &.{RED});
        try t.expectEqual(classify.Outcome.infra, c.outcome);
    }
    try t.expectEqual(classify.Outcome.infra, (try classify.classify(arena.allocator(), null, .build, ACTION_FAILED, &.{RED})).outcome);
}

test "exit 0 is pass; exit 32 is fail only for the verb test" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(classify.Outcome.pass, (try classify.classify(arena.allocator(), 0, .build, SUCCESS, &.{"//tools/build/bisect/capture_tmp:green"})).outcome);
    try t.expectEqual(classify.Outcome.pass, (try classify.classify(arena.allocator(), 0, .build, null, &.{"//a:b"})).outcome);
    try t.expectEqual(classify.Outcome.fail, (try classify.classify(arena.allocator(), 32, .@"test", SUCCESS, &.{"//a:b"})).outcome);
}

test "target patterns" {
    try t.expect(classify.matches("//a:b", "root//a:b"));
    try t.expect(classify.matches("//a/...", "cell//a:b"));
    try t.expect(classify.matches("//a/...", "cell//a/c:b"));
    try t.expect(!classify.matches("//a/...", "cell//ab:c"));
    try t.expect(classify.matches("//a:", "cell//a:b"));
    try t.expect(!classify.matches("//a:", "cell//a/c:b"));
    try t.expect(classify.matches("//...", "cell//:docs"));
    try t.expect(!classify.matches("//a:b", "cell//a:bc"));
}

test "an excerpt is at most 20 lines and 2 KiB, cut at a character boundary" {
    const many = "x\n" ** 30;
    try t.expectEqual(@as(usize, 40), classify.excerpt(many).len);
    const long = "é" ** 2000;
    const e = classify.excerpt(long);
    try t.expect(e.len <= classify.MAX_EXCERPT_BYTES);
    try t.expect(std.unicode.utf8ValidateSlice(e));
    try t.expectEqualStrings("short", classify.excerpt("short"));
}
