//! A library with a glibc name inside the prefix: the loader maps it before
//! the system's (a DT_RPATH comes first), so a check that accepts glibc by
//! name wherever it is found would pass a foreign libm.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a glibc name found inside the prefix is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "glibc_named");
    try t.plant("bin/prog", fx.program(&.{ "libown.so.1", "libm.so.6", "libc.so.6" }));
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    try t.plant("lib/libm.so.6", .{ .soname = "libm.so.6" });
    try fx.expectRed(t, .{}, "bin/prog loads libm.so.6 from the prefix (lib/libm.so.6");
}
