//! native_policy: what a shared library asks of the system that loads it,
//! read from its ELF bytes: its DT_NEEDED names, its DT_RUNPATH and DT_RPATH
//! entries, and the symbol versions it needs (the vernaux names of
//! DT_VERNEED: `GLIBC_2.34`, `GLIBCXX_3.4.30`, `CXXABI_1.3.13`).
//!
//! Read through the program headers (PT_DYNAMIC, and PT_LOAD to map an
//! address to a file offset), not the section headers, so a stripped library
//! reads the same. 64-bit little-endian only (x86-64 and AArch64, the release
//! platforms); anything else, and any offset or count outside the file, is
//! refused rather than read past.

const std = @import("std");
const diag = @import("diag.zig");
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

pub const Info = struct {
    /// e_machine: 62 x86-64, 183 AArch64.
    machine: u16 = 0,
    needed: []const []const u8 = &.{},
    runpath: []const []const u8 = &.{},
    versions: []const []const u8 = &.{},
};

pub fn isElf(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], "\x7fELF");
}

const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const DT_NULL = 0;
const DT_NEEDED = 1;
const DT_STRTAB = 5;
const DT_STRSZ = 10;
const DT_RPATH = 15;
const DT_RUNPATH = 29;
const DT_VERNEED = 0x6ffffffe;
const DT_VERNEEDNUM = 0x6fffffff;

const Load = struct { vaddr: u64, offset: u64, filesz: u64 };

const Reader = struct {
    alloc: Alloc,
    d: *Diag,
    name: []const u8,
    b: []const u8,

    fn bad(r: Reader, comptime what: []const u8) Refused {
        return refuse(r.d, r.alloc, "{s}: a malformed ELF file ({s})", .{ r.name, what });
    }

    fn int(r: Reader, comptime T: type, at: u64) Refused!T {
        const n = @sizeOf(T);
        if (at > r.b.len or r.b.len - at < n) return r.bad("an offset past the end of the file");
        return std.mem.readInt(T, r.b[@intCast(at)..][0..n], .little);
    }

    fn str(r: Reader, tab: u64, size: u64, at: u64) Refused![]const u8 {
        if (at >= size or tab > r.b.len or size > r.b.len - tab) return r.bad("a string outside the string table");
        const s = r.b[@intCast(tab + at)..@intCast(tab + size)];
        const end = std.mem.indexOfScalar(u8, s, 0) orelse return r.bad("a string without its NUL");
        return s[0..end];
    }
};

fn fileOffset(r: Reader, loads: []const Load, vaddr: u64) Refused!u64 {
    for (loads) |l| {
        if (vaddr >= l.vaddr and vaddr - l.vaddr < l.filesz) return l.offset +| (vaddr - l.vaddr);
    }
    return r.bad("an address no PT_LOAD segment maps");
}

/// What `data` (an ELF file named `name`) needs. An ELF file without a
/// PT_DYNAMIC segment needs nothing.
pub fn read(alloc: Alloc, d: *Diag, name: []const u8, data: []const u8) Refused!Info {
    const r = Reader{ .alloc = alloc, .d = d, .name = name, .b = data };
    if (!isElf(data)) return r.bad("no ELF magic");
    if (data.len < 64) return r.bad("a header shorter than 64 bytes");
    if (data[4] != 2 or data[5] != 1) return refuse(d, alloc, "{s}: not a 64-bit little-endian ELF file (class {d}, data {d}); the release platforms are x86-64 and AArch64", .{ name, data[4], data[5] });
    const machine = try r.int(u16, 0x12);
    const phoff = try r.int(u64, 0x20);
    const phentsize = try r.int(u16, 0x36);
    const phnum = try r.int(u16, 0x38);
    if (phentsize != 56) return r.bad("a program header entry that is not 56 bytes");

    var loads = std.ArrayList(Load).empty;
    var dyn: ?struct { offset: u64, size: u64 } = null;
    var i: u64 = 0;
    while (i < phnum) : (i += 1) {
        const at = phoff +| i *| 56;
        const kind = try r.int(u32, at);
        const offset = try r.int(u64, at +| 8);
        const vaddr = try r.int(u64, at +| 16);
        const filesz = try r.int(u64, at +| 32);
        if (kind == PT_LOAD) try loads.append(alloc, .{ .vaddr = vaddr, .offset = offset, .filesz = filesz });
        if (kind == PT_DYNAMIC) {
            if (dyn != null) return r.bad("two PT_DYNAMIC segments");
            dyn = .{ .offset = offset, .size = filesz };
        }
    }
    const dy = dyn orelse return .{ .machine = machine };

    var needed_at = std.ArrayList(u64).empty;
    var paths_at = std.ArrayList(u64).empty;
    var strtab: ?u64 = null;
    var strsz: ?u64 = null;
    var verneed: ?u64 = null;
    var verneednum: u64 = 0;
    var at = dy.offset;
    while (true) : (at +|= 16) {
        if (at +| 16 > dy.offset +| dy.size) return r.bad("a dynamic section without DT_NULL");
        const tag = try r.int(i64, at);
        const val = try r.int(u64, at +| 8);
        switch (tag) {
            DT_NULL => break,
            DT_NEEDED => try needed_at.append(alloc, val),
            DT_RPATH, DT_RUNPATH => try paths_at.append(alloc, val),
            DT_STRTAB => strtab = val,
            DT_STRSZ => strsz = val,
            DT_VERNEED => verneed = val,
            DT_VERNEEDNUM => verneednum = val,
            else => {},
        }
    }
    if (needed_at.items.len == 0 and paths_at.items.len == 0 and verneed == null) return .{ .machine = machine };
    const tab = try fileOffset(r, loads.items, strtab orelse return r.bad("no DT_STRTAB"));
    const size = strsz orelse return r.bad("no DT_STRSZ");

    var needed = std.ArrayList([]const u8).empty;
    for (needed_at.items) |v| try needed.append(alloc, try r.str(tab, size, v));
    var runpath = std.ArrayList([]const u8).empty;
    for (paths_at.items) |v| {
        var parts = std.mem.splitScalar(u8, try r.str(tab, size, v), ':');
        while (parts.next()) |p| try runpath.append(alloc, p);
    }
    var versions = std.ArrayList([]const u8).empty;
    if (verneed) |va| {
        var vn = try fileOffset(r, loads.items, va);
        var n: u64 = 0;
        while (n < verneednum) : (n += 1) {
            const cnt = try r.int(u16, vn +| 2);
            var aux = vn +| try r.int(u32, vn +| 8);
            var k: u64 = 0;
            while (k < cnt) : (k += 1) {
                try versions.append(alloc, try r.str(tab, size, try r.int(u32, aux +| 8)));
                const next_aux = try r.int(u32, aux +| 12);
                if (k + 1 < cnt and next_aux == 0) return r.bad("a version entry chain shorter than its count");
                aux +|= next_aux;
            }
            const next = try r.int(u32, vn +| 12);
            if (n + 1 < verneednum and next == 0) return r.bad("a DT_VERNEED chain shorter than DT_VERNEEDNUM");
            vn +|= next;
        }
    }
    return .{
        .machine = machine,
        .needed = try needed.toOwnedSlice(alloc),
        .runpath = try runpath.toOwnedSlice(alloc),
        .versions = try versions.toOwnedSlice(alloc),
    };
}
