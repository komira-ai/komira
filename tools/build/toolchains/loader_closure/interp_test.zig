//! The interpreter and the programs: every program's PT_INTERP is the
//! system's loader, each --root is a program, and a prefix with no program
//! (a check that reads nothing) is red.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a program with another interpreter is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "interp");
    try t.plant("bin/prog", .{ .interp = "/opt/x/lib/ld-linux-x86-64.so.2", .needed = &.{"libc.so.6"} });
    try fx.expectRed(t, .{}, "bin/prog has the interpreter /opt/x/lib/ld-linux-x86-64.so.2, not /lib64/ld-linux-x86-64.so.2");
}

test "a root that is missing, or a library, is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "interp_roots");
    try t.plant("bin/prog", fx.program(&.{"libc.so.6"}));
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    _ = try fx.expectGreen(t, .{ .roots = &.{"bin/prog"} });
    try fx.expectRed(t, .{ .roots = &.{ "bin/prog", "bin/gone" } }, "bin/gone is not a regular ELF file of the prefix");
    try fx.expectRed(t, .{ .roots = &.{"lib/libown.so.1"} }, "lib/libown.so.1 has no PT_INTERP");
}

test "a prefix with no program is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const t = try fx.Tree.init(arena.allocator(), "interp_none");
    try t.plant("lib/libown.so.1", .{ .soname = "libown.so.1" });
    try fx.expectRed(t, .{}, "the prefix holds no dynamically linked program");
}
