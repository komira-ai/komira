//! A DT_NEEDED that is not in the prefix: the loader would take it from
//! LD_LIBRARY_PATH or the worker, so a library of the build machine leaks in.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a needed library the prefix does not hold is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try fx.Tree.init(a, "missing_control");
    try ok.plant("bin/prog", fx.program(&.{ "libown.so.1", "libc.so.6" }));
    try ok.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    _ = try fx.expectGreen(ok, .{});

    const t = try fx.Tree.init(a, "missing");
    try t.plant("bin/prog", fx.program(&.{ "libown.so.1", "libgone.so.1", "libc.so.6" }));
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    try fx.expectRed(t, .{}, "bin/prog needs libgone.so.1, which is not in the prefix");
}

test "a library of the prefix needing one it does not hold is red: the closure is transitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "missing_transitive");
    try t.plant("bin/prog", fx.program(&.{"libown.so.1"}));
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .needed = &.{ "libc.so.6", "libgone.so.1" } });
    try fx.expectRed(t, .{}, "lib/libown.so.1 needs libgone.so.1, which is not in the prefix");
}
