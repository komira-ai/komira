//! expect-failure's judgement: a run fails as expected only when it exits
//! non-zero with the text in its output; every other end is refused, saying
//! why and showing the end of the output.

const std = @import("std");
const ef = @import("expect_failure.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const WANT = "examples/a.mojo:9:";

test "a non-zero exit whose output holds the text failed as expected" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect((try ef.judge(a, .{ .exited = 1 }, "At src/p/examples/a.mojo:9:5: AssertionError\n", WANT)) == null);
    try t.expect((try ef.judge(a, .{ .exited = 134 }, "x\nexamples/a.mojo:9:\n", WANT)) == null);
}

test "a run that passed is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("the run passed (exit 0); it must fail with `examples/a.mojo:9:` in its output. Its output ends:\nPASS\n", (try ef.judge(a, .{ .exited = 0 }, "PASS\n", WANT)).?);
    // Even when its output holds the text.
    try t.expect((try ef.judge(a, .{ .exited = 0 }, WANT, WANT)) != null);
}

test "a failure without the text is refused, showing the end of the output" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("the run failed (exit 1) but its output does not hold `examples/a.mojo:9:`. Its output ends:\nAt src/p/examples/a.mojo:10:5: AssertionError\n", (try ef.judge(a, .{ .exited = 1 }, "At src/p/examples/a.mojo:10:5: AssertionError\n", WANT)).?);
}

test "a run killed by a signal or stopped is refused, whatever it printed" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("the run was killed by signal 9; it must exit non-zero with `examples/a.mojo:9:` in its output. Its output ends:\nexamples/a.mojo:9:\n", (try ef.judge(a, .{ .signal = 9 }, "examples/a.mojo:9:\n", WANT)).?);
    try t.expectEqualStrings("the run stopped without exiting; it must exit non-zero with `examples/a.mojo:9:` in its output", (try ef.judge(a, .other, WANT, WANT)).?);
}

test "tail keeps the last lines, a final line feed ending the last" {
    try t.expectEqualStrings("c\nd\n", ef.tail("a\nb\nc\nd\n", 2));
    try t.expectEqualStrings("c\nd", ef.tail("a\nb\nc\nd", 2));
    try t.expectEqualStrings("a\nb\n", ef.tail("a\nb\n", 5));
    try t.expectEqualStrings("", ef.tail("", 3));
}

test "a child's end is its exit status, its signal, or neither" {
    try t.expectEqual(ef.End{ .exited = 3 }, ef.endOf(.{ .Exited = 3 }));
    try t.expectEqual(ef.End{ .signal = 9 }, ef.endOf(.{ .Signal = 9 }));
    try t.expectEqual(@as(ef.End, .other), ef.endOf(.{ .Stopped = 19 }));
    try t.expectEqual(@as(ef.End, .other), ef.endOf(.{ .Unknown = 0 }));
}
