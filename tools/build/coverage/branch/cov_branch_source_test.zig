//! Unit test of `placeFile` (cov_branch_source.zig): a `--gen` that names a
//! directory, the `_parts` of a split generated module, leaves out every file
//! under it and no sibling that only starts with its name.

const std = @import("std");
const s = @import("cov_branch_source.zig");
const t = std.testing;

test "placeFile: a --gen directory excludes the files under it, not a sibling named like it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "_partsx.mojo", .data = "x = 1\n" });
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const src = try std.fmt.allocPrint(a, "{s}/", .{dir});
    var gens = [_][]const u8{"_parts"};
    var none = [_][]const u8{};
    const o = s.Opts{
        .prefix = "p/",
        .src = src,
        .hash_tail = null,
        .repo = "r/",
        .gens = &gens,
        .excludes = &none,
        .exclude_files = &none,
        .stdlib = "std/",
    };
    try t.expect(s.placeFile(a, &o, "p/_parts/x_p01.mojo").where == .excluded);
    try t.expect(s.placeFile(a, &o, "p/_parts/deeper/y.mojo").where == .excluded);
    try t.expect(s.placeFile(a, &o, "p/_parts").where == .excluded);
    try t.expect(s.placeFile(a, &o, "p/_partsx.mojo").where == .measured);
}
