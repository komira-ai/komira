//! Rules 2 and 3 of the limits check: every platform restriction carries a
//! marker, every marker names a row and every row has a marker; and which
//! files of a tree are read.

const std = @import("std");
const limits = @import("limits.zig");
const t = @import("testkit.zig");

const tsv = "id\tretired_by\treason\na-limit\tnative-pr:4\tpkg/BUCK: x only\n";
const declared = "t(\n    target_compatible_with = X,  # komira-limit:a-limit\n)\n";

test "a declared limit with its row passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", declared }});
    try t.clean(r);
    try std.testing.expectEqual(@as(usize, 1), r.limits);
}

test "a restriction with no marker is an undeclared limit, named by its line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", declared ++ "t(\n    target_compatible_with = Y,\n)\n" }});
    try t.only(r, "undeclared limit (a `target_compatible_with` with no `komira-limit:<id>` marker): pkg/BUCK:5");
}

test "a marker with no row is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", declared ++ "# komira-limit:other-limit\n" }});
    try t.only(r, "marker `komira-limit:other-limit` at pkg/BUCK:4 has no row in limits.tsv");
}

test "every marker of a line is read, each to its longest id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `a-limit-` is the id a-limit, then a dash; `x-limit` follows on the same line.
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", "# komira-limit:a-limit- and komira-limit:x-limit\n" }});
    try t.only(r, "marker `komira-limit:x-limit` at pkg/BUCK:1 has no row");
}

test "a row with no marker is refused: its limit is gone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", "t(\n)\n" }});
    try t.only(r, "row `a-limit` (limits.tsv line 2) has no marker in the tree: its limit is gone, delete the row");
}

test "a marker that is not an id names nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // `komira-limit:-x` matches no id, so it neither marks a-limit nor is a marker of its own.
    const r = try t.tree(arena.allocator(), tsv, &.{.{ "pkg/BUCK", "# komira-limit:-x\n" }});
    try t.only(r, "row `a-limit` (limits.tsv line 2) has no marker");
}

test "collect reads every file but the excluded, Markdown and binary data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const files = [_][2][]const u8{
        .{ "pkg/BUCK", declared },
        .{ "docs/limits.md", "a `target_compatible_with` in prose\n" },
        .{ "pkg/blob.bin", "\x00target_compatible_with\n" },
        .{ "tools/limits.tsv", tsv },
        .{ "tools/check/fixture.bzl", "target_compatible_with = Z\n" },
        .{ "tools/checker", "target_compatible_with = Z\n" },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |d| try tmp.dir.makePath(d);
        try tmp.dir.writeFile(.{ .sub_path = f[0], .data = f[1] });
    }
    const got = try limits.collect(a, tmp.dir, &.{ "tools/limits.tsv", "tools/check/" });
    // Sorted by path; `tools/checker` is not under the excluded directory.
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("pkg/BUCK", got[0].path);
    try std.testing.expectEqualStrings("tools/checker", got[1].path);
    var out = std.ArrayList(u8).empty;
    const r = try limits.checkTree(a, "tools/limits.tsv", tsv, got, &out);
    try std.testing.expectEqual(@as(usize, 1), r.findings);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "tools/checker:1") != null);
}
