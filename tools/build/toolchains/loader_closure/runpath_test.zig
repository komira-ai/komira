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

// libmid has both tags; libleaf, which libmid loads, has neither, and needs
// libdep.so.1, which only libmid's DT_RPATH directory private/ holds. glibc
// walks libleaf's loader chain for DT_RPATH and skips libmid, whose
// DT_RUNPATH hides its DT_RPATH; the program's lib/ lacks libdep.so.1. The
// green twin below differs only in libmid having no DT_RUNPATH.
fn chain(t: fx.Tree, mid_runpath: ?[]const u8) !void {
    try t.plant("bin/prog", fx.program(&.{"libmid.so.1"}));
    try t.plant("lib/libmid.so.1", .{ .soname = "libmid.so.1", .needed = &.{"libleaf.so.1"}, .rpath = "$ORIGIN/../private", .runpath = mid_runpath });
    try t.plant("lib/libleaf.so.1", .{ .soname = "libleaf.so.1", .needed = &.{"libdep.so.1"} });
    try t.plant("private/libdep.so.1", .{ .soname = "libdep.so.1" });
}

test "an object up the chain with both tags lends no DT_RPATH to what it loads" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "runpath_chain");
    try chain(t, "$ORIGIN");
    try fx.expectRedAll(t, .{}, &.{
        "lib/libmid.so.1 finds libleaf.so.1 at lib/libleaf.so.1 only through its DT_RUNPATH",
        "lib/libleaf.so.1 needs libdep.so.1, which is not in the prefix",
    });
}

test "the same chain with no DT_RUNPATH lends its DT_RPATH: green" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "runpath_chain_twin");
    try chain(t, null);
    const r = try fx.expectGreen(t, .{});
    try fx.expectMaps(r, "libdep.so.1 <- lib/libleaf.so.1: private/libdep.so.1 (through DT_RPATH $ORIGIN/../private of lib/libmid.so.1)");
}
