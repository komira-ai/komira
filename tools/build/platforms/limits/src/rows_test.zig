//! Rule 1 of the limits check: the rows of limits.tsv. Each test feeds one
//! malformed row next to a good one and requires exactly its finding.

const std = @import("std");
const limits = @import("limits.zig");
const t = @import("testkit.zig");

const good = "id\tretired_by\treason\na-limit\tnative-pr:4\tpkg/BUCK: x only\n";

test "a well-formed file: comments, blank lines, the header, both retired_by forms" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "# a comment\n\n" ++ good ++ "b-limit\tnever\tproduct: Linux only\nc-limit\tnative-pr:12b\tlater\n";
    const r = try t.rows(arena.allocator(), text);
    try std.testing.expectEqualStrings("", r.report);
    try std.testing.expectEqual(@as(usize, 3), r.limits);
}

test "a row of two columns, or four, is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try t.rows(a, good ++ "b-limit\tnever\n");
    try t.only(r, "limits.tsv line 3: want exactly three tab-separated columns");
    r = try t.rows(a, good ++ "b-limit\tnever\tproduct: x\textra\n");
    try t.only(r, "limits.tsv line 3: want exactly three tab-separated columns");
    // An empty reason is no reason.
    r = try t.rows(a, good ++ "b-limit\tnative-pr:2\t\n");
    try t.only(r, "limits.tsv line 3: want exactly three tab-separated columns");
}

test "an id that is not lowercase words joined by dashes is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "B-limit", "b--limit", "b-limit-", "-b", "b_limit" }) |id| {
        const text = try std.fmt.allocPrint(a, good ++ "{s}\tnever\tproduct: x\n", .{id});
        const want = try std.fmt.allocPrint(a, "limits.tsv line 3: id `{s}` is not lowercase words joined by dashes", .{id});
        try t.only(try t.rows(a, text), want);
    }
}

test "a second row for an id is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.rows(arena.allocator(), good ++ "a-limit\tnative-pr:5\tagain\n");
    try t.only(r, "limits.tsv line 3: id `a-limit` appears twice");
}

test "retired_by that is neither never nor native-pr:<n> is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "native-pr:", "native-pr:x", "native-pr:4bc", "native-pr:4B", "pr:4", "Never" }) |by| {
        const text = try std.fmt.allocPrint(a, good ++ "b-limit\t{s}\tproduct: x\n", .{by});
        const want = try std.fmt.allocPrint(a, "limits.tsv line 3 (b-limit): retired_by `{s}` is neither", .{by});
        try t.only(try t.rows(a, text), want);
    }
}

test "a limit never retired needs a product: reason" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.rows(arena.allocator(), good ++ "b-limit\tnever\tbecause\n");
    try t.only(r, "limits.tsv line 3 (b-limit): a limit that is never retired needs a reason starting `product:`");
}

test "a file with no row is refused: it cannot be told from an unchecked tree" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.rows(arena.allocator(), "# nothing\nid\tretired_by\treason\n");
    try t.only(r, "limits.tsv lists no limit");
}
