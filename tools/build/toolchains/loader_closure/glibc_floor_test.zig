//! The glibc floor: a GLIBC_2.<m> string above the floor anywhere in an ELF
//! file of the prefix (a version need, or a library embedded as bytes).
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a version above the floor is red, at and below it green" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try fx.Tree.init(a, "floor_ok");
    try ok.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libc.so.6"}, .extra = "GLIBC_2.2.5\x00GLIBC_2.34\x00GLIBC_PRIVATE" });
    _ = try fx.expectGreen(ok, .{ .glibc_floor = 34 });

    const t = try fx.Tree.init(a, "floor_over");
    try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libc.so.6"}, .extra = "GLIBC_2.34" });
    // In a library, one twice: each named once, in order.
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .extra = "GLIBC_2.38\x00GLIBC_2.36\x00GLIBC_2.38" });
    try fx.expectRed(t, .{ .glibc_floor = 34 }, "lib/libown.so.1 needs GLIBC_2.36 GLIBC_2.38, above the floor GLIBC_2.34");
}

test "a prefix naming no glibc version is red: the floor check would see nothing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "floor_none");
    try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libc.so.6"} });
    _ = try fx.expectGreen(t, .{});
    try fx.expectRed(t, .{ .glibc_floor = 34 }, "no ELF file of the prefix names a GLIBC_2. symbol version");
}
