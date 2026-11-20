//! The ELF reader on synthetic libraries: DT_NEEDED, DT_RUNPATH and DT_RPATH
//! entries and DT_VERNEED symbol versions read back as written; a library
//! with no dynamic segment needs nothing; and a file that is not a 64-bit
//! little-endian ELF, or whose offsets leave the file, is refused by name.

const std = @import("std");
const diag = @import("diag.zig");
const elf = @import("elf.zig");
const fixture = @import("testing.zig");
const t = std.testing;

fn expectStrings(want: []const []const u8, got: []const []const u8) !void {
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "needed names, run path entries and symbol versions read back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const lib = try fixture.goodLibrary(a);
    try t.expect(elf.isElf(lib));
    const info = try elf.read(a, &d, "libkomira.so", lib);
    try expectStrings(&.{ "libkomira_fs_native.so.1", "libKGENCompilerRTShared.so", "libstdc++.so.6", "libc.so.6" }, info.needed);
    try expectStrings(&.{ "$ORIGIN/lib", "$ORIGIN" }, info.runpath);
    try expectStrings(&.{ "GLIBC_2.2.5", "GLIBC_2.34", "GLIBCXX_3.4.29", "CXXABI_1.3.13", "CXXABI_TM_1" }, info.versions);

    const old = try fixture.elf(a, .{ .rpath = "/opt/lib" });
    try expectStrings(&.{"/opt/lib"}, (try elf.read(a, &d, "old.so", old)).runpath);
    try t.expect(!elf.isElf("#!/bin/sh\n"));
}

test "addresses are mapped through the PT_LOAD that holds them, not read as offsets" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    // The string table and DT_VERNEED in the second of two PT_LOADs, mapped
    // 0x1000 above their file offsets, as a real library's data segment is.
    const lib = try fixture.elf(a, .{
        .needed = &.{ "libc.so.6", "libm.so.6" },
        .runpath = "$ORIGIN",
        .verneed = &.{.{ .file = "libc.so.6", .versions = &.{"GLIBC_2.34"} }},
        .bias = 0x1000,
        .machine = 183,
    });
    const info = try elf.read(a, &d, "lib.so", lib);
    try t.expectEqual(@as(u16, 183), info.machine);
    try expectStrings(&.{ "libc.so.6", "libm.so.6" }, info.needed);
    try expectStrings(&.{"$ORIGIN"}, info.runpath);
    try expectStrings(&.{"GLIBC_2.34"}, info.versions);
}

test "an ELF file without a dynamic segment needs nothing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    var lib = try fixture.elf(a, .{ .needed = &.{"libc.so.6"} });
    std.mem.writeInt(u16, lib[0x38..][0..2], 1, .little); // the PT_LOAD only
    const info = try elf.read(a, &d, "static", lib);
    try t.expectEqual(@as(usize, 0), info.needed.len);
    try t.expectEqual(@as(u16, 62), info.machine);
}

fn refusal(a: std.mem.Allocator, data: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, elf.read(a, &d, "lib.so", data));
    return d.msg;
}

test "a file that is not a 64-bit little-endian ELF, or reads outside itself, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try fixture.goodLibrary(a);

    try t.expectEqualStrings("lib.so: a malformed ELF file (a header shorter than 64 bytes)", try refusal(a, good[0..40]));

    var class32 = try a.dupe(u8, good);
    class32[4] = 1;
    try t.expectEqualStrings("lib.so: not a 64-bit little-endian ELF file (class 1, data 1); the release platforms are x86-64 and AArch64", try refusal(a, class32));

    var phent = try a.dupe(u8, good);
    std.mem.writeInt(u16, phent[0x36..][0..2], 32, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (a program header entry that is not 56 bytes)", try refusal(a, phent));

    var phoff = try a.dupe(u8, good);
    std.mem.writeInt(u64, phoff[0x20..][0..8], std.math.maxInt(u64) - 8, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (an offset past the end of the file)", try refusal(a, phoff));

    // The string table's size shrunk below the needed names' offsets.
    const small = try fixture.elf(a, .{ .needed = &.{"libc.so.6"} });
    const strsz_val = std.mem.indexOf(u8, small, &[_]u8{ 10, 0, 0, 0, 0, 0, 0, 0 }).? + 8;
    var cut = try a.dupe(u8, small);
    std.mem.writeInt(u64, cut[strsz_val..][0..8], 1, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (a string outside the string table)", try refusal(a, cut));

    // The dynamic section cut before its DT_NULL.
    const dyn_ph = 64 + 56;
    var nonull = try a.dupe(u8, small);
    std.mem.writeInt(u64, nonull[dyn_ph + 32 ..][0..8], 16, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (a dynamic section without DT_NULL)", try refusal(a, nonull));

    // DT_VERNEEDNUM larger than the chain.
    const versioned = try fixture.elf(a, .{ .verneed = &.{.{ .file = "libc.so.6", .versions = &.{"GLIBC_2.34"} }} });
    const num_val = std.mem.indexOf(u8, versioned, &[_]u8{ 0xff, 0xff, 0xff, 0x6f, 0, 0, 0, 0 }).? + 8;
    var long = try a.dupe(u8, versioned);
    std.mem.writeInt(u64, long[num_val..][0..8], 2, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (a DT_VERNEED chain shorter than DT_VERNEEDNUM)", try refusal(a, long));

    // The string table at an address no PT_LOAD maps.
    const strtab_val = std.mem.indexOf(u8, small, &[_]u8{ 5, 0, 0, 0, 0, 0, 0, 0 }).? + 8;
    var unmapped = try a.dupe(u8, small);
    std.mem.writeInt(u64, unmapped[strtab_val..][0..8], 1 << 40, .little);
    try t.expectEqualStrings("lib.so: a malformed ELF file (an address no PT_LOAD segment maps)", try refusal(a, unmapped));
}
