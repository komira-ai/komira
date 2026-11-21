//! The Mach-O reading of `native_so` (native_so.zig): a dynamic library's
//! load commands and symbol table, and the symbols of a relocatable object
//! (an archive member, or a README program compiled to an object). It fills
//! the same `Shared` and `Sym` values native_elf.zig does, so the export
//! list and checks 1 to 3 read a `.dylib` as they read a `.so`; checks 4 to 7
//! hold the Mach-O fields (`Shared.format == .macho`) to their Mach-O rules
//! (native_checks.zig).
//!
//! Only thin 64-bit arm64 Mach-O is read: macos-arm64 is the one Mac
//! release platform. A universal (fat) file, another CPU, a load command or
//! a name pointing outside its file is an error naming what is wrong, never a
//! skipped part, as in native_elf.zig.
//!
//! The mapping onto `Sym`: a C name loses the one leading `_` Mach-O
//! prepends (`_komira_x` is `komira_x`, the name the callers and the export
//! list use); an external symbol (`N_EXT`) is global, or weak when it is a
//! weak definition or a weak reference; a private external one (`N_PEXT`)
//! is hidden; a non-external one is local; debug entries (`N_STAB`) are
//! not symbols. An undefined symbol of a two-level-namespace library carries
//! the install name of the library its ordinal names (`Sym.lib`): Mach-O's
//! counterpart of an ELF symbol's GLIBC_ version, which says where it binds.

const std = @import("std");
const elf = @import("native_elf.zig");

const Alloc = std.mem.Allocator;
const Sym = elf.Sym;
const Shared = elf.Shared;
const bad = elf.bad;

pub const MH_MAGIC_64: u32 = 0xfeedfacf;
const FAT_MAGIC: u32 = 0xcafebabe;
const FAT_MAGIC_64: u32 = 0xcafebabf;
const CPU_TYPE_ARM64: u32 = 0x0100000c;

pub const MH_OBJECT: u32 = 1;
pub const MH_EXECUTE: u32 = 2;
pub const MH_DYLIB: u32 = 6;

/// Header flags checks 6 reads.
pub const MH_TWOLEVEL: u32 = 0x80;
pub const MH_FORCE_FLAT: u32 = 0x100;

pub const LC_SYMTAB: u32 = 0x2;
pub const LC_LOAD_DYLIB: u32 = 0xc;
pub const LC_ID_DYLIB: u32 = 0xd;
pub const LC_LAZY_LOAD_DYLIB: u32 = 0x20;
pub const LC_VERSION_MIN_MACOSX: u32 = 0x24;
pub const LC_BUILD_VERSION: u32 = 0x32;
pub const LC_LOAD_WEAK_DYLIB: u32 = 0x80000018;
pub const LC_RPATH: u32 = 0x8000001c;
pub const LC_REEXPORT_DYLIB: u32 = 0x8000001f;
pub const LC_LOAD_UPWARD_DYLIB: u32 = 0x80000023;

/// LC_BUILD_VERSION's platform for macOS.
pub const PLATFORM_MACOS: u32 = 1;

const N_STAB: u8 = 0xe0;
const N_PEXT: u8 = 0x10;
const N_TYPE: u8 = 0x0e;
const N_EXT: u8 = 0x01;
const N_UNDF: u8 = 0x0;
const N_PBUD: u8 = 0xc;
const N_WEAK_REF: u16 = 0x40;
const N_WEAK_DEF: u16 = 0x80;

const SELF_LIBRARY_ORDINAL: u8 = 0;
const DYNAMIC_LOOKUP_ORDINAL: u8 = 0xfe;
const EXECUTABLE_ORDINAL: u8 = 0xff;

/// The name of a load command that loads a dylib, for check 4's messages.
pub fn loadName(cmd: u32) []const u8 {
    return switch (cmd) {
        LC_LOAD_DYLIB => "LC_LOAD_DYLIB",
        LC_LOAD_WEAK_DYLIB => "LC_LOAD_WEAK_DYLIB",
        LC_REEXPORT_DYLIB => "LC_REEXPORT_DYLIB",
        LC_LOAD_UPWARD_DYLIB => "LC_LOAD_UPWARD_DYLIB",
        else => "LC_LAZY_LOAD_DYLIB",
    };
}

/// What `Sym.lib` holds for the ordinals that name no LC_LOAD_DYLIB.
pub const lib_self = "<this library>";
pub const lib_flat = "<flat lookup>";
pub const lib_executable = "<main executable>";

/// Whether `b` starts as a Mach-O file of any kind this reader knows of
/// (thin 64-bit, or universal): native_elf.zig hands such bytes here.
pub fn isMachO(b: []const u8) bool {
    if (b.len < 4) return false;
    const le = std.mem.readInt(u32, b[0..4], .little);
    const be = std.mem.readInt(u32, b[0..4], .big);
    return le == MH_MAGIC_64 or be == FAT_MAGIC or be == FAT_MAGIC_64;
}

fn rd(comptime T: type, b: []const u8, at: usize) elf.Error!T {
    if (at > b.len or b.len - at < @sizeOf(T)) return bad("a header lies outside the file");
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn cstr(tab: []const u8, at: usize) elf.Error![]const u8 {
    if (at >= tab.len) return bad("a name lies outside its string table");
    const s = tab[at..];
    const end = std.mem.indexOfScalar(u8, s, 0) orelse return bad("a name is not terminated in its string table");
    return s[0..end];
}

/// One load command: its kind and its bytes (cmdsize of them).
const Cmd = struct { cmd: u32, body: []const u8 };

const MachO = struct {
    b: []const u8,
    filetype: u32,
    flags: u32,
    cmds: []Cmd,

    fn open(alloc: Alloc, b: []const u8, want: []const u32) !MachO {
        if (b.len >= 4) {
            const be = std.mem.readInt(u32, b[0..4], .big);
            if (be == FAT_MAGIC or be == FAT_MAGIC_64) return bad("a universal (fat) Mach-O file: only thin arm64 is read");
        }
        if (b.len < 32 or std.mem.readInt(u32, b[0..4], .little) != MH_MAGIC_64) return bad("not a 64-bit little-endian Mach-O file");
        if (try rd(u32, b, 4) != CPU_TYPE_ARM64) return bad("a Mach-O file for a CPU other than arm64");
        const filetype = try rd(u32, b, 12);
        if (std.mem.indexOfScalar(u32, want, filetype) == null) return bad("a Mach-O file of the wrong type (filetype)");
        const ncmds = try rd(u32, b, 16);
        const sizeofcmds = try rd(u32, b, 20);
        if (b.len - 32 < sizeofcmds) return bad("the load commands lie outside the file");
        if (ncmds > sizeofcmds / 8) return bad("more load commands than sizeofcmds can hold");
        const area = b[32 .. 32 + @as(usize, sizeofcmds)];
        const cmds = try alloc.alloc(Cmd, ncmds);
        var at: usize = 0;
        for (cmds) |*c| {
            const cmd = try rd(u32, area, at);
            const size = try rd(u32, area, at + 4);
            if (size < 8 or size % 8 != 0) return bad("a load command's size is not a multiple of 8");
            if (area.len - at < size) return bad("a load command lies outside the load commands");
            c.* = .{ .cmd = cmd, .body = area[at .. at + size] };
            at += size;
        }
        if (at != area.len) return bad("the load commands do not fill sizeofcmds");
        return .{ .b = b, .filetype = filetype, .flags = try rd(u32, b, 24), .cmds = cmds };
    }

    /// The string a command holds at the offset (an `lc_str`) at `field`.
    fn lcStr(c: Cmd, field: usize) elf.Error![]const u8 {
        const off = try rd(u32, c.body, field);
        if (off < field + 4) return bad("a load command's string overlaps its fields");
        return cstr(c.body, off);
    }

    fn symtab(m: MachO) elf.Error!?Cmd {
        var found: ?Cmd = null;
        for (m.cmds) |c| {
            if (c.cmd != LC_SYMTAB) continue;
            if (found != null) return bad("two LC_SYMTAB commands");
            found = c;
        }
        return found;
    }
};

fn isLoad(cmd: u32) bool {
    return cmd == LC_LOAD_DYLIB or cmd == LC_LOAD_WEAK_DYLIB or cmd == LC_REEXPORT_DYLIB or
        cmd == LC_LOAD_UPWARD_DYLIB or cmd == LC_LAZY_LOAD_DYLIB;
}

/// `X.Y` (or `X.Y.Z` when Z is set) of a Mach-O version, xxxx.yy.zz in nibbles.
pub fn versionText(alloc: Alloc, v: u32) ![]const u8 {
    const z = v & 0xff;
    if (z != 0) return std.fmt.allocPrint(alloc, "{d}.{d}.{d}", .{ v >> 16, (v >> 8) & 0xff, z });
    return std.fmt.allocPrint(alloc, "{d}.{d}", .{ v >> 16, (v >> 8) & 0xff });
}

/// The library a two-level ordinal names: 1 is the first loaded dylib.
fn libOf(libs: []const []const u8, ord: u8) elf.Error![]const u8 {
    return switch (ord) {
        SELF_LIBRARY_ORDINAL => lib_self,
        DYNAMIC_LOOKUP_ORDINAL => lib_flat,
        EXECUTABLE_ORDINAL => lib_executable,
        else => if (ord <= libs.len) libs[ord - 1] else bad("a symbol's library ordinal names no loaded dylib"),
    };
}

/// The symbols of the LC_SYMTAB of `m`. `libs` (the library's loaded
/// dylibs, in load-command order) names each undefined symbol's library by
/// its two-level ordinal; null for an object, whose ordinals mean nothing.
fn readSyms(alloc: Alloc, m: MachO, skip_local: bool, libs: ?[]const []const u8) ![]Sym {
    const c = (try m.symtab()) orelse return bad("no LC_SYMTAB");
    const symoff: usize = try rd(u32, c.body, 8);
    const nsyms: usize = try rd(u32, c.body, 12);
    const stroff: usize = try rd(u32, c.body, 16);
    const strsize: usize = try rd(u32, c.body, 20);
    if (stroff > m.b.len or m.b.len - stroff < strsize) return bad("the string table lies outside the file");
    const names = m.b[stroff .. stroff + strsize];
    if (symoff > m.b.len or (m.b.len - symoff) / 16 < nsyms) return bad("the symbol table lies outside the file");
    var out = std.ArrayList(Sym).empty;
    for (0..nsyms) |i| {
        const at = symoff + i * 16;
        const strx = try rd(u32, m.b, at);
        const ty = m.b[at + 4];
        const desc = try rd(u16, m.b, at + 6);
        const value = try rd(u64, m.b, at + 8);
        if (ty & N_STAB != 0) continue;
        const ext = ty & N_EXT != 0;
        if (skip_local and !ext) continue;
        const kind = ty & N_TYPE;
        // An undefined entry with a value is a common symbol: a definition.
        const defined = !((kind == N_UNDF and value == 0) or kind == N_PBUD);
        const weak = if (defined) desc & N_WEAK_DEF != 0 else desc & N_WEAK_REF != 0;
        var name = try cstr(names, strx);
        if (name.len > 1 and name[0] == '_') name = name[1..];
        var s = Sym{
            .name = name,
            .defined = defined,
            .bind = if (!ext) .local else if (weak) .weak else .global,
            .vis = if (ext and ty & N_PEXT != 0) .hidden else .default,
        };
        if (libs) |ls| {
            if (!defined) s.lib = try libOf(ls, @intCast(desc >> 8));
        }
        try out.append(alloc, s);
    }
    return out.toOwnedSlice(alloc);
}

/// The external symbols of a relocatable object (an archive member).
pub fn readObject(alloc: Alloc, b: []const u8) ![]Sym {
    return readSyms(alloc, try MachO.open(alloc, b, &.{MH_OBJECT}), true, null);
}

/// Every symbol of an object's or a program's symbol table, locals
/// included (native_elf.zig, `readProgram`). A file without one is an
/// error, never an empty list.
pub fn readProgram(alloc: Alloc, b: []const u8) ![]Sym {
    return readSyms(alloc, try MachO.open(alloc, b, &.{ MH_OBJECT, MH_EXECUTE, MH_DYLIB }), false, null);
}

/// A dynamic library's install name (`Shared.soname`), loaded dylibs
/// (`needed`, every kind of load command, in order, each command's kind in
/// `load_cmds`), LC_RPATH entries
/// (`runpath`), header flags, platform and minimum OS version, and its
/// non-local symbols, each undefined one with the library it binds to.
pub fn readShared(alloc: Alloc, b: []const u8) !Shared {
    const m = try MachO.open(alloc, b, &.{MH_DYLIB});
    var out = Shared{ .format = .macho, .mh_flags = m.flags };
    var needed = std.ArrayList([]const u8).empty;
    var kinds = std.ArrayList(u32).empty;
    var runpath = std.ArrayList([]const u8).empty;
    for (m.cmds) |c| {
        if (isLoad(c.cmd)) {
            try needed.append(alloc, try MachO.lcStr(c, 8));
            try kinds.append(alloc, c.cmd);
        } else switch (c.cmd) {
            LC_ID_DYLIB => {
                if (out.soname != null) return bad("two LC_ID_DYLIB commands");
                out.soname = try MachO.lcStr(c, 8);
            },
            LC_RPATH => try runpath.append(alloc, try MachO.lcStr(c, 8)),
            LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX => {
                if (out.minos != null) return bad("two minimum OS version commands");
                const v = try rd(u32, c.body, if (c.cmd == LC_BUILD_VERSION) 12 else 8);
                out.platform = if (c.cmd == LC_BUILD_VERSION) try rd(u32, c.body, 8) else PLATFORM_MACOS;
                out.minos = try versionText(alloc, v);
            },
            else => {},
        }
    }
    if (out.soname == null) return bad("no LC_ID_DYLIB (not a dynamic library's install name)");
    out.needed = try needed.toOwnedSlice(alloc);
    out.load_cmds = try kinds.toOwnedSlice(alloc);
    out.runpath = try runpath.toOwnedSlice(alloc);
    out.syms = try readSyms(alloc, m, true, out.needed);
    return out;
}
