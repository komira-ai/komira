//! Unit tests of so_exports.zig: which declarations count as C exports, and
//! the report of a check. The whole tool is run by
//! tests//negative/shared_lib and the mojo_shared_lib targets.
const std = @import("std");
const E = @import("so_exports.zig");
const t = std.testing;

fn names(a: std.mem.Allocator, src: []const u8) ![]const []const u8 {
    return E.exportedNames(a, src);
}

fn expectNames(src: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try names(arena.allocator(), src);
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "a bare @export with abi(\"C\") is an export; sorted" {
    try expectNames(
        \\@export
        \\def zeta(a: Int32) abi("C") -> Int32:
        \\    return a
        \\
        \\@export
        \\def alpha() abi("C") -> Int32:
        \\    return 1
    , &.{ "alpha", "zeta" });
}

test "fn, other decorators between, and a multi-line signature" {
    try expectNames(
        \\@export
        \\@always_inline
        \\fn multi(
        \\    a: Int32,
        \\    b: UnsafePointer[UInt8, MutAnyOrigin],
        \\) abi("C") -> Int32:
        \\    return a
    , &.{"multi"});
}

test "an @export without abi(\"C\") is not a C export" {
    try expectNames(
        \\@export
        \\def mojo_abi(a: Int32) -> Int32:
        \\    return a
        \\@export
        \\def other_abi(a: Int32) abi("Mojo") -> Int32:
        \\    return a
    , &.{});
}

test "abi(\"C\") without @export is not an export" {
    try expectNames(
        \\def callback(a: Int32) abi("C") -> Int32:
        \\    return a
    , &.{});
}

test "comments, docstrings and strings do not declare exports" {
    try expectNames(
        \\# @export
        \\# def commented() abi("C") -> Int32:
        \\def f() -> Int32:
        \\    """
        \\    @export
        \\    def in_doc() abi("C") -> Int32:
        \\    """
        \\    var s = "@export"
        \\    return 1
        \\@export
        \\def real() abi("C") -> Int32:  # trailing abi("C")
        \\    return 2
    , &.{"real"});
}

test "an @export applies to the next def only" {
    try expectNames(
        \\@export
        \\def first() abi("C") -> Int32:
        \\    return 1
        \\def second() abi("C") -> Int32:
        \\    return 2
    , &.{"first"});
}

test "an abi(\"C\") in the body is not the signature's" {
    try expectNames(
        \\@export
        \\def body_only() -> Int32:
        \\    var x = 0  # abi("C")
        \\    return x
    , &.{});
}

test "an @export with arguments is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.ExportWithArguments, names(arena.allocator(),
        \\@export("alias")
        \\def f() abi("C") -> Int32:
        \\    return 1
    ));
}

test "differences: equal sets pass; both directions are named" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exported: []const []const u8 = &.{ "a", "b" };
    try t.expect((try E.differences(a, "//x:y", "f.mojo", exported, &.{ "a", "b" }, &.{})) == null);
    const r = (try E.differences(a, "//x:y", "f.mojo", exported, &.{ "a", "ghost" }, &.{})).?;
    try t.expect(std.mem.indexOf(u8, r, "listed in `exports`, but f.mojo has no @export abi(\"C\") function of that name: ghost") != null);
    try t.expect(std.mem.indexOf(u8, r, "not in `exports` (or `unlisted_exports`): b") != null);
}

test "differences: unlisted exports leave the list, and must be exported" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exported: []const []const u8 = &.{ "a", "hidden" };
    try t.expect((try E.differences(a, "l", "f", exported, &.{"a"}, &.{"hidden"})) == null);
    try t.expect((try E.differences(a, "l", "f", exported, &.{"a"}, &.{"nope"})) != null);
    try t.expect((try E.differences(a, "l", "f", exported, &.{ "a", "hidden" }, &.{"hidden"})) != null);
}

test "differences: an unlisted name with no such function is named under unlisted_exports" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exported: []const []const u8 = &.{ "a", "hidden" };
    const r = (try E.differences(a, "l", "f.mojo", exported, &.{"a"}, &.{ "hidden", "nope" })).?;
    try t.expect(std.mem.indexOf(u8, r, "in `unlisted_exports`, but f.mojo has no @export abi(\"C\") function of that name: nope") != null);
    try t.expect(std.mem.indexOf(u8, r, "hidden\n") == null);
}
