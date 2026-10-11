//! ELF files the check cannot read are red, never skipped and never a crash.
const std = @import("std");
const lc = @import("loader_closure.zig");
const fx = @import("fixture.zig");

test "a truncated ELF file is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try fx.Tree.init(a, "truncated");
    try t.plant("bin/prog", fx.program(&.{"libc.so.6"}));
    const whole = try fx.elf(a, .{ .soname = "libown.so.1", .needed = &.{"libc.so.6"} });
    try t.file("lib/libown.so.1", whole[0..100]);
    try fx.expectRed(t, .{}, "lib/libown.so.1: a truncated or malformed ELF file");
}

test "an ELF32 file is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const t = try fx.Tree.init(a, "elf32");
    try t.plant("bin/prog", fx.program(&.{"libc.so.6"}));
    const b = try fx.elf(a, .{ .soname = "libown.so.1" });
    b[4] = 1; // ELFCLASS32
    try t.file("lib/libown.so.1", b);
    try fx.expectRed(t, .{}, "lib/libown.so.1: an ELF file that is not ELF64 little-endian");
}

test "a dynamic section whose string table is outside every PT_LOAD is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = try fx.elf(a, .{ .soname = "libown.so.1" });
    // The PT_LOAD's p_vaddr (the second header field of the first header)
    // moved away: DT_STRTAB then maps to no file offset.
    std.mem.writeInt(u64, b[64 + 16 ..][0..8], 0x900000, .little);
    try std.testing.expectError(error.BadDynamic, lc.parse(a, b));
}
