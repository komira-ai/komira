//! An absolute run path entry: the loader searches that directory wherever
//! the prefix is installed, so whatever it finds there is outside the prefix.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "an absolute DT_RPATH entry outside the prefix is red, even after the entry that finds the library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "/opt/elsewhere/lib:$ORIGIN/../lib", "$ORIGIN/../lib:/opt/elsewhere/lib" }, 0..) |rp, i| {
        const t = try fx.Tree.init(a, try std.fmt.allocPrint(a, "rpath_absolute_{d}", .{i}));
        try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{"libown.so.1"}, .rpath = rp });
        try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
        try fx.expectRed(t, .{}, "bin/prog: its DT_RPATH has the absolute run path entry '/opt/elsewhere/lib'");
    }
}

test "an absolute DT_RUNPATH entry of a library is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "runpath_absolute");
    try t.plant("bin/prog", fx.program(&.{"libown.so.1"}));
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .runpath = "/usr/lib64" });
    try fx.expectRed(t, .{}, "lib/libown.so.1: its DT_RUNPATH has the absolute run path entry '/usr/lib64'");
}
