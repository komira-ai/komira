//! A library reached only through a DT_RUNPATH: the loader searches
//! LD_LIBRARY_PATH first, so a test runner's LD_LIBRARY_PATH (the Mojo
//! toolchain's lib/) would supply it. zig links an executable with a
//! DT_RUNPATH, which is why kcov's elf_rpath exists.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a program finding its library only through a DT_RUNPATH is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "runpath");
    try t.plant("bin/prog", .{ .interp = lc.DEFAULT_INTERP, .needed = &.{ "libown.so.1", "libc.so.6" }, .runpath = "$ORIGIN/../lib" });
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    try fx.expectRed(t, .{}, "bin/prog finds libown.so.1 at lib/libown.so.1 only through its DT_RUNPATH");
}

test "a DT_RUNPATH hides the object's DT_RPATH and the chain's, as in glibc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "runpath_hides");
    try t.plant("bin/prog", fx.program(&.{"libown.so.1"}));
    // Both tags: the loader ignores the DT_RPATH, and with it the program's.
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1", .needed = &.{"libdep.so.2"}, .rpath = "$ORIGIN", .runpath = "$ORIGIN" });
    try t.plant("lib/libdep.so.2", .{ .soname = "libdep.so.2" });
    try fx.expectRed(t, .{}, "lib/libown.so.1 finds libdep.so.2 at lib/libdep.so.2 only through its DT_RUNPATH");
}
