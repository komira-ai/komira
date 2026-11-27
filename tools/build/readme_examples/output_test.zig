//! The exact output compare (output.zig): equal bytes pass, and any other
//! output is refused naming the expected file's first differing line, word
//! for word.

const std = @import("std");
const output = @import("output.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const D = "src/p/examples/a.expected_output.txt";

fn firstLine(a: std.mem.Allocator, want: []const u8, got: []const u8) ![]const u8 {
    const why = (try output.compare(a, D, want, got)) orelse return error.TestExpectedRefusal;
    return why[0..std.mem.indexOfScalar(u8, why, '\n').?];
}

test "output equal to the file byte for byte passes, empty output included" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(?[]const u8, null), try output.compare(a, D, "a\nb\n", "a\nb\n"));
    try t.expectEqual(@as(?[]const u8, null), try output.compare(a, D, "", ""));
}

test "a changed line is named by its line in the file, with both lines" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(D ++ ":2: expected \"7.5\", printed \"7.0\"", try firstLine(a, "id\n7.5\n", "id\n7.0\n"));
    try t.expectEqualStrings(D ++ ":1: expected \"a\", printed \"\"", try firstLine(a, "a\n", "\n"));
}

test "a line too many, a line too few, and a missing or extra final line feed are each refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(D ++ ":2: expected \"\", printed \"b\"", try firstLine(a, "a\n", "a\nb\n"));
    try t.expectEqualStrings(D ++ ":2: expected \"b\", printed \"\"", try firstLine(a, "a\nb\n", "a\n"));
    // No final line feed: the last line differs only by what follows it.
    try t.expectEqualStrings(D ++ ":2: expected \"\", printed missing", try firstLine(a, "a\n", "a"));
    try t.expectEqualStrings(D ++ ":2: expected missing, printed \"\"", try firstLine(a, "a", "a\n"));
    // Nothing printed against an expected line.
    try t.expectEqualStrings(D ++ ":1: expected \"a\", printed \"\"", try firstLine(a, "a\n", ""));
}

test "the refusal holds both texts whole after its first line" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const why = (try output.compare(a, D, "a\nb\n", "a\nc\n")).?;
    try t.expectEqualStrings(D ++ ":2: expected \"b\", printed \"c\"\n--- " ++ D ++ " expected ---\na\nb\n--- printed ---\na\nc\n--- end ---\n", why);
}

test "firstDifference: none for equal texts; else the line and each side's line, null past its end" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(?output.Difference, null), try output.firstDifference(a, "x\n", "x\n"));
    const d = (try output.firstDifference(a, "x", "x\ny")).?;
    try t.expectEqual(@as(usize, 2), d.line);
    try t.expectEqual(@as(?[]const u8, null), d.got);
    try t.expectEqualStrings("y", d.want.?);
}
