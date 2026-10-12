//! The control: a prefix laid out as the toolchain distributions are is
//! green, and the check maps what the loader would. Every other scenario
//! plants one defect into a tree like this one.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a program, its own libraries through its DT_RPATH, glibc from the system" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "green");
    try t.plant("bin/prog", fx.program(&.{ "libown.so.1", "libc.so.6" }));
    // No run path of its own: found through the program's DT_RPATH (the
    // loader walks the chain of the objects that loaded it).
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .needed = &.{ "libdep.so.2", "libm.so.6" }, .extra = "GLIBC_2.2.5" });
    try t.plant("lib/libdep.so.2", .{ .soname = "libdep.so.2", .needed = &.{"libc.so.6"}, .rpath = "${ORIGIN}/.", .extra = "GLIBC_2.34" });
    // A link to a file of the prefix, and files that are not ELF.
    try t.symlink("libdep.so.2", "lib/libdep.so");
    try t.file("share/licenses/NOTICE", "not an ELF file\n");
    try t.file("runtime/libx.a", "!<arch>\n");
    const r = try fx.expectGreen(t, .{ .glibc_floor = 34, .roots = &.{"bin/prog"} });
    try std.testing.expectEqual(@as(usize, 1), r.programs);
    try std.testing.expectEqual(@as(usize, 2), r.mapped);
    try fx.expectMaps(r, "bin/prog: libdep.so.2 <- lib/libown.so.1: lib/libdep.so.2 (through DT_RPATH $ORIGIN/../lib of bin/prog)");
    try fx.expectMaps(r, "bin/prog: libm.so.6 <- lib/libown.so.1: the system's");
}

test "a name a mapped object already has is that object, whatever its run path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "green_loaded");
    try t.plant("bin/prog", fx.program(&.{ "libown.so.1", "libdep.so.2" }));
    // Its DT_RUNPATH would lose to LD_LIBRARY_PATH, but libdep.so.2 is mapped
    // (by the program, breadth first) before libown.so.1's needs are read.
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .needed = &.{"libdep.so.2"}, .runpath = "$ORIGIN" });
    try t.plant("lib/libdep.so.2", .{ .soname = "libdep.so.2" });
    _ = try fx.expectGreen(t, .{});
}
