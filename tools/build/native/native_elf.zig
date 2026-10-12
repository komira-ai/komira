//! The ELF reading of `native_so` (native_so.zig): the symbols of every
//! member of a static archive, and a shared object's dynamic section and
//! dynamic symbol table with each symbol's version.
//!
//! Only 64-bit little-endian ELF is read. Anything else (another class, a
//! thin archive, a member that is not a relocatable object, a header or a
//! name pointing outside its file) is an error naming the file, never a
//! skipped member: a reader that skips what it cannot read cannot fail a
//! check.

const std = @import("std");

pub const Alloc = std.mem.Allocator;

pub const Error = error{BadElf};

/// Why the last `Error.BadElf` was returned (the caller prints it).
pub var why: []const u8 = "";

fn bad(msg: []const u8) Error {
    why = msg;
    return Error.BadElf;
}

pub const Bind = enum { local, global, weak, unique, other };
pub const Vis = enum { default, internal, hidden, protected };

pub const Sym = struct {
    name: []const u8,
    /// Defined in this object (any section, or common); false when undefined.
    defined: bool,
    bind: Bind,
    vis: Vis,
    /// The version an undefined dynamic symbol needs (`GLIBC_2.14`), or the
    /// version a defined one has; null for none.
    version: ?[]const u8 = null,

    /// A name another object of the process can see: defined, not local,
    /// default or protected visibility.
    pub fn exported(s: Sym) bool {
        return s.defined and s.bind != .local and (s.vis == .default or s.vis == .protected);
    }
};

/// One version a shared object needs from one of its NEEDED files.
pub const Need = struct { file: []const u8, version: []const u8 };

pub const Shared = struct {
    soname: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
    runpath: []const []const u8 = &.{},
    rpath: []const []const u8 = &.{},
    /// DT_FLAGS, when the dynamic section has one.
    flags: ?u64 = null,
    /// DT_FLAGS_1, when the dynamic section has one.
    flags_1: ?u64 = null,
    /// A DT_SYMBOLIC entry.
    symbolic_tag: bool = false,
    syms: []const Sym = &.{},
    verneed: []const Need = &.{},
};

pub const DF_SYMBOLIC: u64 = 0x2;
pub const DF_BIND_NOW: u64 = 0x8;

const SHT_SYMTAB: u32 = 2;
const SHT_DYNAMIC: u32 = 6;
const SHT_DYNSYM: u32 = 11;
const SHT_GNU_VERDEF: u32 = 0x6ffffffd;
const SHT_GNU_VERNEED: u32 = 0x6ffffffe;
const SHT_GNU_VERSYM: u32 = 0x6fffffff;
const SHN_UNDEF: u16 = 0;

const DT_NULL: u64 = 0;
const DT_NEEDED: u64 = 1;
const DT_SONAME: u64 = 14;
const DT_RPATH: u64 = 15;
const DT_SYMBOLIC: u64 = 16;
const DT_RUNPATH: u64 = 29;
const DT_FLAGS: u64 = 30;
const DT_FLAGS_1: u64 = 0x6ffffffb;

const ET_REL: u16 = 1;
const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;

fn rd(comptime T: type, b: []const u8, at: usize) Error!T {
    if (at > b.len or b.len - at < @sizeOf(T)) return bad("a header lies outside the file");
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn cstr(tab: []const u8, at: u64) Error![]const u8 {
    if (at >= tab.len) return bad("a name lies outside its string table");
    const s = tab[@intCast(at)..];
    const end = std.mem.indexOfScalar(u8, s, 0) orelse return bad("a name is not terminated in its string table");
    return s[0..end];
}

const Section = struct { type: u32, offset: usize, size: usize, link: u32, info: u32 };

const Elf = struct {
    b: []const u8,
    sections: []Section,

    fn open(alloc: Alloc, b: []const u8, want: []const u16) !Elf {
        if (b.len < 64 or !std.mem.eql(u8, b[0..4], "\x7fELF")) return bad("not an ELF file");
        if (b[4] != 2 or b[5] != 1) return bad("not 64-bit little-endian ELF");
        const e_type = try rd(u16, b, 16);
        if (std.mem.indexOfScalar(u16, want, e_type) == null) return bad("an ELF file of the wrong type (e_type)");
        const shoff: usize = @intCast(try rd(u64, b, 40));
        const shentsize = try rd(u16, b, 58);
        const shnum = try rd(u16, b, 60);
        if (shnum > 0 and shentsize != 64) return bad("section headers are not 64 bytes");
        const secs = try alloc.alloc(Section, shnum);
        for (secs, 0..) |*s, i| {
            const h = shoff + i * 64;
            s.* = .{
                .type = try rd(u32, b, h + 4),
                .offset = @intCast(try rd(u64, b, h + 24)),
                .size = @intCast(try rd(u64, b, h + 32)),
                .link = try rd(u32, b, h + 40),
                .info = try rd(u32, b, h + 44),
            };
        }
        return .{ .b = b, .sections = secs };
    }

    fn data(e: Elf, s: Section) Error![]const u8 {
        if (s.offset > e.b.len or e.b.len - s.offset < s.size) return bad("a section lies outside the file");
        return e.b[s.offset .. s.offset + s.size];
    }

    fn find(e: Elf, t: u32) ?Section {
        for (e.sections) |s| if (s.type == t) return s;
        return null;
    }

    fn strtab(e: Elf, s: Section) Error![]const u8 {
        if (s.link >= e.sections.len) return bad("a section links no string table");
        return e.data(e.sections[s.link]);
    }
};

fn bindOf(info: u8) Bind {
    return switch (info >> 4) {
        0 => .local,
        1 => .global,
        2 => .weak,
        10 => .unique,
        else => .other,
    };
}

fn visOf(other: u8) Vis {
    return switch (other & 3) {
        0 => .default,
        1 => .internal,
        2 => .hidden,
        else => .protected,
    };
}

/// The symbols of one symbol table section (index 0 skipped).
fn readSyms(alloc: Alloc, e: Elf, s: Section, skip_local: bool) ![]Sym {
    const raw = try e.data(s);
    const names = try e.strtab(s);
    if (raw.len % 24 != 0) return bad("a symbol table's size is not a multiple of 24");
    var out = std.ArrayList(Sym).init(alloc);
    var k: usize = 24;
    while (k < raw.len) : (k += 24) {
        const info = raw[k + 4];
        const bind = bindOf(info);
        if (skip_local and bind == .local) continue;
        const shndx = try rd(u16, raw, k + 6);
        try out.append(.{
            .name = try cstr(names, try rd(u32, raw, k)),
            .defined = shndx != SHN_UNDEF,
            .bind = bind,
            .vis = visOf(raw[k + 5]),
        });
    }
    return out.toOwnedSlice();
}

/// Every non-local symbol of every member of a static archive (`!<arch>`).
pub fn readArchive(alloc: Alloc, b: []const u8) ![]Sym {
    if (b.len >= 8 and std.mem.eql(u8, b[0..8], "!<thin>\n")) return bad("a thin archive (its members are not in it)");
    if (b.len < 8 or !std.mem.eql(u8, b[0..8], "!<arch>\n")) return bad("not an ar archive");
    var out = std.ArrayList(Sym).init(alloc);
    var at: usize = 8;
    var members: usize = 0;
    while (at < b.len) {
        if (b.len - at < 60) return bad("a member header lies outside the archive");
        const h = b[at .. at + 60];
        if (h[58] != '`' or h[59] != '\n') return bad("a member header has no terminator");
        const size_txt = std.mem.trimRight(u8, h[48..58], " ");
        const size = std.fmt.parseInt(usize, size_txt, 10) catch return bad("a member size is not a number");
        const start = at + 60;
        if (start > b.len or b.len - start < size) return bad("a member lies outside the archive");
        const name = std.mem.trimRight(u8, h[0..16], " ");
        const special = std.mem.eql(u8, name, "/") or std.mem.eql(u8, name, "/SYM64/") or std.mem.eql(u8, name, "//");
        if (!special) {
            const e = try Elf.open(alloc, b[start .. start + size], &.{ET_REL});
            if (e.find(SHT_SYMTAB)) |s| try out.appendSlice(try readSyms(alloc, e, s, true));
            members += 1;
        }
        at = start + size + (size & 1);
    }
    if (members == 0) return bad("an archive with no members");
    return out.toOwnedSlice();
}

/// Every symbol of an object's or a linked program's static symbol table
/// (.symtab), locals included. A README program compiled to an object
/// (`mojo build --emit object`) has each C function it reaches as an
/// undefined symbol there. A file without a .symtab (a stripped program;
/// the programs `mojo build` links are) is an error, never an empty list:
/// a check that reads nothing cannot fail.
pub fn readProgram(alloc: Alloc, b: []const u8) ![]Sym {
    const e = try Elf.open(alloc, b, &.{ ET_REL, ET_EXEC, ET_DYN });
    const s = e.find(SHT_SYMTAB) orelse return bad("no .symtab (a stripped program): its symbols cannot be read");
    return readSyms(alloc, e, s, false);
}

/// A shared object's (or a dynamically linked program's) dynamic section,
/// its .dynsym (local symbols left out), and the versions it needs.
pub fn readShared(alloc: Alloc, b: []const u8) !Shared {
    const e = try Elf.open(alloc, b, &.{ ET_DYN, ET_EXEC });
    var out = Shared{};
    const dyn = e.find(SHT_DYNAMIC) orelse return bad("no dynamic section");
    const draw = try e.data(dyn);
    const dstr = try e.strtab(dyn);
    var needed = std.ArrayList([]const u8).init(alloc);
    var runpath = std.ArrayList([]const u8).init(alloc);
    var rpath = std.ArrayList([]const u8).init(alloc);
    var k: usize = 0;
    while (k + 16 <= draw.len) : (k += 16) {
        const tag = try rd(u64, draw, k);
        const val = try rd(u64, draw, k + 8);
        switch (tag) {
            DT_NULL => break,
            DT_NEEDED => try needed.append(try cstr(dstr, val)),
            DT_SONAME => out.soname = try cstr(dstr, val),
            DT_RUNPATH => try runpath.append(try cstr(dstr, val)),
            DT_RPATH => try rpath.append(try cstr(dstr, val)),
            DT_SYMBOLIC => out.symbolic_tag = true,
            DT_FLAGS => out.flags = val,
            DT_FLAGS_1 => out.flags_1 = val,
            else => {},
        }
    }
    out.needed = try needed.toOwnedSlice();
    out.runpath = try runpath.toOwnedSlice();
    out.rpath = try rpath.toOwnedSlice();

    const ds = e.find(SHT_DYNSYM) orelse return bad("no dynamic symbol table");
    const dstrtab = try e.strtab(ds);
    // Version index -> name: needed versions (vna_other), defined ones (vd_ndx).
    var names = std.AutoHashMap(u16, []const u8).init(alloc);
    var verneed = std.ArrayList(Need).init(alloc);
    if (e.find(SHT_GNU_VERNEED)) |vn| {
        const v = try e.data(vn);
        const vs = try e.strtab(vn);
        var off: usize = 0;
        var n: u32 = 0;
        while (n < vn.info) : (n += 1) {
            const file = try cstr(vs, try rd(u32, v, off + 4));
            const cnt = try rd(u16, v, off + 2);
            var aux = off + try rd(u32, v, off + 8);
            var j: u16 = 0;
            while (j < cnt) : (j += 1) {
                const other = try rd(u16, v, aux + 6);
                const ver = try cstr(vs, try rd(u32, v, aux + 8));
                try names.put(other & 0x7fff, ver);
                try verneed.append(.{ .file = file, .version = ver });
                const next = try rd(u32, v, aux + 12);
                if (next == 0) break;
                aux += next;
            }
            const next = try rd(u32, v, off + 12);
            if (next == 0) break;
            off += next;
        }
    }
    if (e.find(SHT_GNU_VERDEF)) |vd| {
        const v = try e.data(vd);
        const vs = try e.strtab(vd);
        var off: usize = 0;
        var n: u32 = 0;
        while (n < vd.info) : (n += 1) {
            const ndx = try rd(u16, v, off + 4);
            const aux = off + try rd(u32, v, off + 12);
            try names.put(ndx & 0x7fff, try cstr(vs, try rd(u32, v, aux)));
            const next = try rd(u32, v, off + 16);
            if (next == 0) break;
            off += next;
        }
    }
    const versym: ?[]const u8 = if (e.find(SHT_GNU_VERSYM)) |s| try e.data(s) else null;

    const raw = try e.data(ds);
    if (raw.len % 24 != 0) return bad("the dynamic symbol table's size is not a multiple of 24");
    var syms = std.ArrayList(Sym).init(alloc);
    var i: usize = 1;
    while (i * 24 < raw.len) : (i += 1) {
        const at = i * 24;
        const bind = bindOf(raw[at + 4]);
        if (bind == .local) continue;
        var s = Sym{
            .name = try cstr(dstrtab, try rd(u32, raw, at)),
            .defined = (try rd(u16, raw, at + 6)) != SHN_UNDEF,
            .bind = bind,
            .vis = visOf(raw[at + 5]),
        };
        if (versym) |vsym| {
            const idx = (try rd(u16, vsym, i * 2)) & 0x7fff;
            // 0 local, 1 the object's base (unversioned): no version name.
            if (idx >= 2) s.version = names.get(idx) orelse return bad("a symbol's version index names no version");
        }
        try syms.append(s);
    }
    out.syms = try syms.toOwnedSlice();
    out.verneed = try verneed.toOwnedSlice();
    return out;
}

/// `readShared`'s result, one line per entry: the dynamic section (SONAME,
/// NEEDED, RUNPATH, RPATH, SYMBOLIC, FLAGS, FLAGS_1), every needed version
/// (`VERNEED <file> <version>`), then every non-local dynamic symbol as
/// `DEF|UND <bind> <visibility> <name>[@<version>]`.
pub fn writeShared(w: anytype, s: Shared) !void {
    if (s.soname) |n| try w.print("SONAME {s}\n", .{n});
    for (s.needed) |n| try w.print("NEEDED {s}\n", .{n});
    for (s.runpath) |n| try w.print("RUNPATH {s}\n", .{n});
    for (s.rpath) |n| try w.print("RPATH {s}\n", .{n});
    if (s.symbolic_tag) try w.writeAll("SYMBOLIC\n");
    if (s.flags) |f| try w.print("FLAGS 0x{x}\n", .{f});
    if (s.flags_1) |f| try w.print("FLAGS_1 0x{x}\n", .{f});
    for (s.verneed) |n| try w.print("VERNEED {s} {s}\n", .{ n.file, n.version });
    for (s.syms) |y| {
        try w.print("{s} {s} {s} {s}", .{ if (y.defined) "DEF" else "UND", @tagName(y.bind), @tagName(y.vis), y.name });
        if (y.version) |v| try w.print("@{s}", .{v});
        try w.writeAll("\n");
    }
}
