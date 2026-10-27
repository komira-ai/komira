//! Rule 4 of the limits check: no row outlives the PR that retires it.

const std = @import("std");
const t = @import("testkit.zig");

const tsv = "id\tretired_by\treason\na-limit\tnative-pr:4\tpkg/BUCK: x only\nb-limit\tnever\tproduct: Linux only\n";

test "no subject names the retiring PR: no finding" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.clean(try t.merged(arena.allocator(), tsv, "build: one thing\nbuild: another\n"));
    try t.clean(try t.merged(arena.allocator(), tsv, ""));
}

test "a subject naming the retiring PR refuses the row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = "limit `a-limit` is retired by native-pr:4, whose PR has merged";
    try t.only(try t.merged(a, tsv, "build: a thing [native-pr:4]\n"), want);
    // At the very end of the subjects, with no newline.
    try t.only(try t.merged(a, tsv, "x\nbuild: native-pr:4"), want);
    // After a different PR on the same line.
    try t.only(try t.merged(a, tsv, "build: [native-pr:44] [native-pr:4]\n"), want);
}

test "a subject naming a different PR (44, 4b) is not PR 4" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try t.clean(try t.merged(arena.allocator(), tsv, "build: a thing [native-pr:44]\nbuild: [native-pr:4b]\n"));
}

test "a row retired by a lettered PR is refused by that PR only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lettered = "c-limit\tnative-pr:8b\tlater\n";
    try t.clean(try t.merged(a, lettered, "build: [native-pr:8a] [native-pr:8]\n"));
    try t.only(try t.merged(a, lettered, "build: [native-pr:8b]\n"), "limit `c-limit` is retired by native-pr:8b");
}

test "never is never refused, whatever the subjects" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const never = "b-limit\tnever\tproduct: Linux only\n";
    try t.clean(try t.merged(arena.allocator(), never, "never\nnative-pr:never\n"));
}
