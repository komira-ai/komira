//! Inputs of `cov_branch annotate` made by hand, for its unit tests
//! (cov_branch_annotate_test.zig) and its process tests
//! (cov_branch_exe_test.zig): an instrumented binary's ELF sections, the
//! listing `llvm-profdata show --all-functions` prints, bitcode bytes and the
//! module lld prints after `pgo-instr-use`.

const std = @import("std");

/// One function of a binary and of its profile: its profile name (whose MD5
/// starts the record), its hash and its number of counters.
pub const Fn = struct {
    name: []const u8,
    hash: u64,
    counters: u32 = 1,
};

/// A 72-byte `__llvm_prf_data` record of `f`.
pub fn record(f: Fn) [72]u8 {
    var r = [_]u8{0} ** 72;
    var md5: [16]u8 = undefined;
    std.crypto.hash.Md5.hash(f.name, &md5, .{});
    @memcpy(r[0..8], md5[0..8]);
    std.mem.writeInt(u64, r[8..16], f.hash, .little);
    std.mem.writeInt(u32, r[56..60], f.counters, .little);
    return r;
}

/// The `__llvm_prf_data` bytes of `fns`.
pub fn dataOf(alloc: std.mem.Allocator, fns: []const Fn) ![]const u8 {
    var v = std.ArrayList(u8).empty;
    for (fns) |f| try v.appendSlice(alloc, &record(f));
    return v.toOwnedSlice(alloc);
}

/// The `__llvm_prf_cnts` size `fns` need: 8 bytes per counter.
pub fn cntsSize(fns: []const Fn) u64 {
    var n: u64 = 0;
    for (fns) |f| n += f.counters;
    return n * 8;
}

/// A section of the ELF file: its name, its bytes, and the size its header
/// gives (the bytes' length unless set) and offset (where the bytes are
/// unless set).
pub const Section = struct {
    name: []const u8,
    bytes: []const u8 = "",
    size: ?u64 = null,
    offset: ?u64 = null,
};

/// Header fields to give other values than a well-formed file's.
pub const Odd = struct {
    ident: []const u8 = "\x7fELF\x02\x01\x01",
    shentsize: u16 = 64,
    shnum: ?u16 = null,
    shstrndx: ?u16 = null,
    shoff: ?u64 = null,
    /// Cut the file to this many bytes.
    cut: ?usize = null,
};

/// A 64-bit little-endian ELF file holding a null section, `sections` and
/// `.shstrtab` (the last, which the header names), the section headers at
/// the end.
pub fn elf(alloc: std.mem.Allocator, sections: []const Section, odd: Odd) ![]const u8 {
    var names = std.ArrayList(u8).empty;
    try names.append(alloc, 0);
    var name_at = std.ArrayList(u32).empty;
    for (sections) |s| {
        try name_at.append(alloc, @intCast(names.items.len));
        try names.appendSlice(alloc, s.name);
        try names.append(alloc, 0);
    }
    const strtab_name: u32 = @intCast(names.items.len);
    try names.appendSlice(alloc, ".shstrtab");
    try names.append(alloc, 0);

    var out = std.ArrayList(u8).empty;
    try out.appendNTimes(alloc, 0, 64);
    var offs = std.ArrayList(u64).empty;
    for (sections) |s| {
        try offs.append(alloc, out.items.len);
        try out.appendSlice(alloc, s.bytes);
    }
    const strtab_off = out.items.len;
    try out.appendSlice(alloc, names.items);
    while (out.items.len % 8 != 0) try out.append(alloc, 0);
    const shoff = out.items.len;
    const n: u16 = @intCast(sections.len + 2);

    var sh = [_]u8{0} ** 64;
    try out.appendSlice(alloc, &sh); // the null section
    for (sections, 0..) |s, i| {
        sh = [_]u8{0} ** 64;
        std.mem.writeInt(u32, sh[0..4], name_at.items[i], .little);
        std.mem.writeInt(u32, sh[4..8], 1, .little);
        std.mem.writeInt(u64, sh[24..32], s.offset orelse offs.items[i], .little);
        std.mem.writeInt(u64, sh[32..40], s.size orelse s.bytes.len, .little);
        try out.appendSlice(alloc, &sh);
    }
    sh = [_]u8{0} ** 64;
    std.mem.writeInt(u32, sh[0..4], strtab_name, .little);
    std.mem.writeInt(u32, sh[4..8], 3, .little);
    std.mem.writeInt(u64, sh[24..32], strtab_off, .little);
    std.mem.writeInt(u64, sh[32..40], names.items.len, .little);
    try out.appendSlice(alloc, &sh);

    const h = out.items[0..64];
    @memcpy(h[0..odd.ident.len], odd.ident);
    std.mem.writeInt(u64, h[40..48], odd.shoff orelse shoff, .little);
    std.mem.writeInt(u16, h[58..60], odd.shentsize, .little);
    std.mem.writeInt(u16, h[60..62], odd.shnum orelse n, .little);
    std.mem.writeInt(u16, h[62..64], odd.shstrndx orelse n - 1, .little);
    const bytes = try out.toOwnedSlice(alloc);
    return if (odd.cut) |c| bytes[0..@min(c, bytes.len)] else bytes;
}

/// An instrumented binary of `fns`: its data and counter sections.
pub fn binary(alloc: std.mem.Allocator, fns: []const Fn) ![]const u8 {
    return elf(alloc, &.{
        .{ .name = ".text", .bytes = "\x90\x90\x90\x90" },
        .{ .name = "__llvm_prf_cnts", .size = cntsSize(fns) },
        .{ .name = "__llvm_prf_data", .bytes = try dataOf(alloc, fns) },
    }, .{});
}

/// What `llvm-profdata show --all-functions` prints for `fns`.
pub fn show(alloc: std.mem.Allocator, fns: []const Fn) ![]const u8 {
    var v = std.ArrayList(u8).empty;
    const w = v.writer(alloc);
    try w.writeAll("Counters:\n");
    for (fns) |f| {
        try w.print("  {s}:\n    Hash: 0x{x:0>16}\n    Counters: {d}\n    Function count: 0\n", .{ f.name, f.hash, f.counters });
    }
    try w.print("Instrumentation level: IR  entry_first = 0\nFunctions shown: {d}\nTotal functions: {d}\nMaximum function count: 1\nMaximum internal block count: 0\n", .{ fns.len, fns.len });
    return v.toOwnedSlice(alloc);
}

/// Bitcode as far as the annotation reads it: the magic, then `body`.
pub fn bitcode(alloc: std.mem.Allocator, body: []const u8) ![]const u8 {
    return std.mem.concat(alloc, u8, &.{ "BC\xc0\xde\x35\x14\x00\x00", body });
}

pub const HEADER = "; *** IR Dump After PGOInstrumentationUse on [module] ***";

/// A line LLVM prints, before the dump, for a function of the bitcode the
/// profile does not hold.
pub fn missing(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "lld: warning: ld-temp.o: no profile data available for function {s} Hash = 1234 up to 0 count discarded\n", .{name});
}

/// The dump lld prints for `fns`, each defined with an entry count.
pub fn dump(alloc: std.mem.Allocator, fns: []const Fn) ![]const u8 {
    var v = std.ArrayList(u8).empty;
    const w = v.writer(alloc);
    try w.print("{s}\n; ModuleID = 'ld-temp.o'\nsource_filename = \"ld-temp.o\"\n\n", .{HEADER});
    for (fns, 0..) |f, i| {
        try w.print("define void @\"{s}\"() !prof !{d} {{\n  br i1 true, label %a, label %b, !prof !{d}\na:\n  ret void\nb:\n  ret void\n}}\n\n", .{ f.name, 10 + i, 100 + i });
    }
    try w.writeAll("define internal void @unrun() {\n  ret void\n}\n\n!10 = !{!\"function_entry_count\", i64 1}\n");
    return v.toOwnedSlice(alloc);
}

pub const MAIN = Fn{ .name = "main", .hash = 0x1234_5678_9abc_def0, .counters = 3 };
pub const HELPER = Fn{ .name = "test_one::helper(::Int)", .hash = 0x0102_0304_0506_0708, .counters = 2 };
pub const SMALL = Fn{ .name = "ld-temp.o;small", .hash = 0x42, .counters = 1 };
pub const FNS = [_]Fn{ MAIN, HELPER, SMALL };
