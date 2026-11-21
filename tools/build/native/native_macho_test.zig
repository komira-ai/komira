//! Unit tests of native_macho.zig and of checks 1 to 7 on a Mach-O library
//! (run by `:native_so_unit`). `dylib` builds a small arm64 dynamic library
//! byte by byte (header, load commands, symbol and string tables), `object`
//! a relocatable object and `bsdArchive` a BSD-layout archive of them, the
//! layout a macOS archive has (`#1/<n>` long names, a `__.SYMDEF SORTED`
//! symbol table member). The reader is shown reading every field the checks
//! use, and refusing each malformed input with its reason; each check is
//! shown green on a library shaped as an owner's `.dylib` with a declared
//! owner, and red on the one defect it exists for.

const std = @import("std");
const elf = @import("native_elf.zig");
const macho = @import("native_macho.zig");
const checks = @import("native_checks.zig");

const t = std.testing;
const A = std.heap.page_allocator;
const Buf = std.ArrayList(u8);

fn put(b: *Buf, comptime T: type, v: T) void {
    var x: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &x, v, .little);
    b.appendSlice(A, &x) catch unreachable;
}

fn pad8(b: *Buf) void {
    while (b.items.len % 8 != 0) b.append(A, 0) catch unreachable;
}

const system = "/usr/lib/libSystem.B.dylib";
const owner_id = "@rpath/libkomira_o_native.1.dylib";
const own_id = "@rpath/libkomira_t_native.1.dylib";

pub const Load = struct { cmd: u32 = macho.LC_LOAD_DYLIB, name: []const u8 };

/// One nlist_64: its name (with Mach-O's `_`), n_type, n_desc and n_value.
pub const NSym = struct { name: []const u8, ty: u8, desc: u16 = 0, value: u64 = 0 };

pub const N_SECT_EXT: u8 = 0x0f;
const N_UNDF_EXT: u8 = 0x01;

/// The owner-shaped library: one export, memcpy from libSystem, a call into
/// the declared owner, a weak reference (komira_t_hook), and a local, a
/// private external and a debug entry the reader must not keep.
const default_syms = [_]NSym{
    .{ .name = "_komira_t_f", .ty = N_SECT_EXT },
    .{ .name = "_memcpy", .ty = N_UNDF_EXT, .desc = 0x0100 },
    .{ .name = "_komira_o_g", .ty = N_UNDF_EXT, .desc = 0x0200 },
    .{ .name = "_komira_t_hook", .ty = N_UNDF_EXT, .desc = 0x0100 | 0x40 },
    .{ .name = "_komira_t_local", .ty = 0x0e },
    .{ .name = "_komira_t_hidden", .ty = 0x1f },
    .{ .name = "t.c", .ty = 0x64 },
};

const default_loads = [_]Load{ .{ .name = system }, .{ .name = owner_id } };

pub const Opts = struct {
    filetype: u32 = macho.MH_DYLIB,
    cpu: u32 = 0x0100000c,
    /// MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL | MH_NO_REEXPORTED_DYLIBS.
    flags: u32 = 0x100085,
    ids: []const []const u8 = &.{own_id},
    loads: []const Load = &default_loads,
    rpaths: []const []const u8 = &.{"@loader_path"},
    /// LC_BUILD_VERSION's minos (11.0); null for no version command.
    minos: ?u32 = 0x000b0000,
    platform: u32 = macho.PLATFORM_MACOS,
    /// LC_VERSION_MIN_MACOSX in place of LC_BUILD_VERSION.
    version_min: bool = false,
    /// A second version command after the first.
    second_version: bool = false,
    syms: []const NSym = &default_syms,
    symtabs: usize = 1,
};

fn strCmd(c: *Buf, cmd: u32, head: usize, name: []const u8, fields: []const u32) void {
    const start = c.items.len;
    put(c, u32, cmd);
    const size_at = c.items.len;
    put(c, u32, 0);
    put(c, u32, @intCast(head));
    for (fields) |f| put(c, u32, f);
    c.appendSlice(A, name) catch unreachable;
    c.append(A, 0) catch unreachable;
    pad8(c);
    std.mem.writeInt(u32, c.items[size_at..][0..4], @intCast(c.items.len - start), .little);
}

/// A Mach-O file as `opts` asks: header, load commands (the ids, loads,
/// run paths, version and symbol table commands, in that order), the
/// symbol table and the string table.
pub fn dylib(opts: Opts) []const u8 {
    var c = Buf.empty;
    var ncmds: u32 = 0;
    for (opts.ids) |id| {
        strCmd(&c, macho.LC_ID_DYLIB, 24, id, &.{ 2, 0x10000, 0x10000 });
        ncmds += 1;
    }
    for (opts.loads) |l| {
        strCmd(&c, l.cmd, 24, l.name, &.{ 2, 0x10000, 0x10000 });
        ncmds += 1;
    }
    for (opts.rpaths) |r| {
        strCmd(&c, macho.LC_RPATH, 12, r, &.{});
        ncmds += 1;
    }
    if (opts.minos) |v| {
        const n: usize = if (opts.second_version) 2 else 1;
        for (0..n) |_| {
            if (opts.version_min) {
                put(&c, u32, macho.LC_VERSION_MIN_MACOSX);
                put(&c, u32, 16);
                put(&c, u32, v);
                put(&c, u32, v);
            } else {
                put(&c, u32, macho.LC_BUILD_VERSION);
                put(&c, u32, 24);
                put(&c, u32, opts.platform);
                put(&c, u32, v);
                put(&c, u32, v);
                put(&c, u32, 0);
            }
            ncmds += 1;
        }
    }
    var symtab_at: [2]usize = undefined;
    for (0..opts.symtabs) |i| {
        put(&c, u32, macho.LC_SYMTAB);
        put(&c, u32, 24);
        symtab_at[i] = c.items.len;
        for (0..4) |_| put(&c, u32, 0);
        ncmds += 1;
    }

    var f = Buf.empty;
    put(&f, u32, macho.MH_MAGIC_64);
    put(&f, u32, opts.cpu);
    put(&f, u32, 0);
    put(&f, u32, opts.filetype);
    put(&f, u32, ncmds);
    put(&f, u32, @intCast(c.items.len));
    put(&f, u32, opts.flags);
    put(&f, u32, 0);
    const cmds_at = f.items.len;
    f.appendSlice(A, c.items) catch unreachable;

    var strs = Buf.empty;
    strs.appendSlice(A, " \x00") catch unreachable;
    pad8(&f);
    const symoff = f.items.len;
    for (opts.syms) |s| {
        put(&f, u32, @intCast(strs.items.len));
        strs.appendSlice(A, s.name) catch unreachable;
        strs.append(A, 0) catch unreachable;
        f.append(A, s.ty) catch unreachable;
        f.append(A, 1) catch unreachable;
        put(&f, u16, s.desc);
        put(&f, u64, s.value);
    }
    const stroff = f.items.len;
    f.appendSlice(A, strs.items) catch unreachable;
    for (0..opts.symtabs) |i| {
        const at = cmds_at + symtab_at[i];
        for ([_]usize{ symoff, opts.syms.len, stroff, strs.items.len }, 0..) |v, k|
            std.mem.writeInt(u32, f.items[at + 4 * k ..][0..4], @intCast(v), .little);
    }
    return f.items;
}

const object_syms = [_]NSym{
    .{ .name = "_komira_x_def", .ty = N_SECT_EXT },
    .{ .name = "_komira_x_call", .ty = N_UNDF_EXT },
    .{ .name = "_komira_x_local", .ty = 0x0e },
    .{ .name = "_komira_x_common", .ty = N_UNDF_EXT, .value = 16 },
    .{ .name = "_komira_x_hidden", .ty = 0x1f },
    .{ .name = "_komira_x_wdef", .ty = N_SECT_EXT, .desc = 0x80 },
};

/// A relocatable object: no install name, loads or run path.
pub fn object(syms: []const NSym) []const u8 {
    return dylib(.{ .filetype = macho.MH_OBJECT, .ids = &.{}, .loads = &.{}, .rpaths = &.{}, .flags = 0, .syms = syms });
}

pub const Member = struct { name: []const u8, body: []const u8 };

fn field(b: *Buf, text: []const u8, width: usize) void {
    b.appendSlice(A, text) catch unreachable;
    b.appendNTimes(A, ' ', width - text.len) catch unreachable;
}

/// A BSD-layout archive: each name over 16 bytes or holding a space is a
/// `#1/<n>` long name (its NUL-padded bytes lead the member); the first
/// member is the `__.SYMDEF SORTED` symbol table, as macOS's ar writes it.
pub fn bsdArchive(members: []const Member) []const u8 {
    var b = Buf.empty;
    b.appendSlice(A, "!<arch>\n") catch unreachable;
    var all = std.ArrayList(Member).empty;
    all.append(A, .{ .name = "__.SYMDEF SORTED", .body = "\x08\x00\x00\x00symbols!" }) catch unreachable;
    all.appendSlice(A, members) catch unreachable;
    for (all.items) |m| {
        const long = m.name.len > 16 or std.mem.indexOfScalar(u8, m.name, ' ') != null;
        var name_bytes = Buf.empty;
        if (long) {
            name_bytes.appendSlice(A, m.name) catch unreachable;
            name_bytes.append(A, 0) catch unreachable;
            pad8(&name_bytes);
        }
        const size = name_bytes.items.len + m.body.len;
        field(&b, if (long) std.fmt.allocPrint(A, "#1/{d}", .{name_bytes.items.len}) catch unreachable else m.name, 16);
        field(&b, "0", 12);
        field(&b, "0", 6);
        field(&b, "0", 6);
        field(&b, "644", 8);
        field(&b, std.fmt.allocPrint(A, "{d}", .{size}) catch unreachable, 10);
        b.appendSlice(A, "`\n") catch unreachable;
        b.appendSlice(A, name_bytes.items) catch unreachable;
        b.appendSlice(A, m.body) catch unreachable;
        if (size & 1 == 1) b.append(A, '\n') catch unreachable;
    }
    return b.items;
}

/// The smallest relocatable ELF object the ELF reader takes: a header with
/// no sections.
fn elfObject() []const u8 {
    var f = Buf.empty;
    f.appendSlice(A, "\x7fELF\x02\x01\x01") catch unreachable;
    f.appendNTimes(A, 0, 9) catch unreachable;
    put(&f, u16, 1); // ET_REL
    f.appendNTimes(A, 0, 64 - 18) catch unreachable;
    return f.items;
}

fn render(so: elf.Shared) ![]const u8 {
    var b = Buf.empty;
    try elf.writeShared(b.writer(A), so);
    return b.items;
}

fn expectBad(why: []const u8, r: anytype) !void {
    try t.expectError(error.BadObject, r);
    try t.expectEqualStrings(why, elf.why);
}

/// One red line, exactly `want`.
fn expectOnly(red: checks.Red, want: []const u8) !void {
    if (red.lines.items.len != 1) {
        std.debug.print("want one finding `{s}`; findings:\n", .{want});
        for (red.lines.items) |l| std.debug.print("  {s}\n", .{l});
        return error.TestExpectedOneFinding;
    }
    try t.expectEqualStrings(want, red.lines.items[0]);
}

fn read(opts: Opts) !elf.Shared {
    return elf.readShared(A, dylib(opts));
}

// ---- the reader ---------------------------------------------------------------

test "reader: a dylib's install name, loads, run path, flags, version and symbols, through native_elf's entry" {
    const so = try read(.{});
    try t.expectEqual(elf.Format.macho, so.format);
    try t.expectEqualStrings(
        \\INSTALL_NAME @rpath/libkomira_t_native.1.dylib
        \\LOAD /usr/lib/libSystem.B.dylib
        \\LOAD @rpath/libkomira_o_native.1.dylib
        \\RPATH @loader_path
        \\FLAGS 0x100085
        \\MINOS 1 11.0
        \\DEF global default komira_t_f
        \\UND global default memcpy from /usr/lib/libSystem.B.dylib
        \\UND global default komira_o_g from @rpath/libkomira_o_native.1.dylib
        \\UND weak default komira_t_hook from /usr/lib/libSystem.B.dylib
        \\DEF global hidden komira_t_hidden
        \\
    , try render(so));
    const exp = try checks.exportsOf(A, so);
    try t.expectEqual(@as(usize, 1), exp.len);
    try t.expectEqualStrings("komira_t_f", exp[0]);
}

test "reader: every kind of load command is a loaded dylib, and its ordinal counts in load-command order" {
    const so = try read(.{
        .loads = &.{
            .{ .cmd = macho.LC_LOAD_WEAK_DYLIB, .name = "/w.dylib" },
            .{ .cmd = macho.LC_REEXPORT_DYLIB, .name = "/r.dylib" },
            .{ .cmd = macho.LC_LOAD_UPWARD_DYLIB, .name = "/u.dylib" },
            .{ .cmd = macho.LC_LAZY_LOAD_DYLIB, .name = "/l.dylib" },
            .{ .name = system },
        },
        .syms = &.{
            .{ .name = "_a", .ty = N_UNDF_EXT, .desc = 0x0300 },
            .{ .name = "_b", .ty = N_UNDF_EXT, .desc = 0x0500 },
            .{ .name = "_c", .ty = N_UNDF_EXT, .desc = 0x0000 },
            .{ .name = "_d", .ty = N_UNDF_EXT, .desc = 0xfe00 },
            .{ .name = "_e", .ty = N_UNDF_EXT, .desc = 0xff00 },
            .{ .name = "_f", .ty = 0x0d, .desc = 0x0100 }, // N_PBUD|N_EXT: undefined
            .{ .name = "_", .ty = N_SECT_EXT }, // a lone `_` is kept whole
            .{ .name = "no_underscore", .ty = N_SECT_EXT },
        },
    });
    try t.expectEqualStrings(
        \\INSTALL_NAME @rpath/libkomira_t_native.1.dylib
        \\LOAD /w.dylib (LC_LOAD_WEAK_DYLIB)
        \\LOAD /r.dylib (LC_REEXPORT_DYLIB)
        \\LOAD /u.dylib (LC_LOAD_UPWARD_DYLIB)
        \\LOAD /l.dylib (LC_LAZY_LOAD_DYLIB)
        \\LOAD /usr/lib/libSystem.B.dylib
        \\RPATH @loader_path
        \\FLAGS 0x100085
        \\MINOS 1 11.0
        \\UND global default a from /u.dylib
        \\UND global default b from /usr/lib/libSystem.B.dylib
        \\UND global default c from <this library>
        \\UND global default d from <flat lookup>
        \\UND global default e from <main executable>
        \\UND global default f from /w.dylib
        \\DEF global default _
        \\DEF global default no_underscore
        \\
    , try render(so));
}

test "reader: LC_VERSION_MIN_MACOSX is a macOS minimum, a patch version is kept, and no version command leaves none" {
    var so = try read(.{ .version_min = true, .minos = 0x000a0f02 });
    try t.expectEqual(@as(?u32, macho.PLATFORM_MACOS), so.platform);
    try t.expectEqualStrings("10.15.2", so.minos.?);
    so = try read(.{ .minos = null });
    try t.expectEqual(@as(?[]const u8, null), so.minos);
    try t.expectEqual(@as(?u32, null), so.platform);
    try t.expectEqualStrings(
        \\INSTALL_NAME @rpath/libkomira_t_native.1.dylib
        \\LOAD /usr/lib/libSystem.B.dylib
        \\LOAD @rpath/libkomira_o_native.1.dylib
        \\RPATH @loader_path
        \\FLAGS 0x100085
        \\DEF global default komira_t_f
        \\UND global default memcpy from /usr/lib/libSystem.B.dylib
        \\UND global default komira_o_g from @rpath/libkomira_o_native.1.dylib
        \\UND weak default komira_t_hook from /usr/lib/libSystem.B.dylib
        \\DEF global hidden komira_t_hidden
        \\
    , try render(so));
}

test "reader: an object's symbols, locals included for a program, external only in an archive" {
    const prog = try elf.readProgram(A, object(&object_syms));
    try t.expectEqual(@as(usize, 6), prog.len);
    try t.expectEqualStrings("komira_x_local", prog[2].name);
    try t.expectEqual(elf.Bind.local, prog[2].bind);
    try t.expect(prog[3].defined); // a common symbol is a definition
    try t.expectEqual(elf.Vis.hidden, prog[4].vis);
    try t.expectEqual(elf.Bind.weak, prog[5].bind); // a weak definition
    try t.expect(prog[5].defined);
    try t.expectEqual(@as(?[]const u8, null), prog[1].lib); // an object's ordinals mean nothing
    const ar = try elf.readArchive(A, bsdArchive(&.{
        .{ .name = "a.o", .body = object(&object_syms) },
        .{ .name = "a_long_member_name_over_sixteen.o", .body = object(&.{.{ .name = "_komira_y", .ty = N_SECT_EXT }}) },
    }));
    var names = std.ArrayList([]const u8).empty;
    for (ar) |s| try names.append(A, s.name);
    try t.expectEqualDeep(@as([]const []const u8, &.{ "komira_x_def", "komira_x_call", "komira_x_common", "komira_x_hidden", "komira_x_wdef", "komira_y" }), names.items);
    // A linked program and a dylib are programs too.
    _ = try elf.readProgram(A, dylib(.{ .filetype = macho.MH_EXECUTE, .ids = &.{} }));
    _ = try elf.readProgram(A, dylib(.{}));
}

test "reader: the export list of Mach-O archives, then checks 1 and 2 of the dylib built from them" {
    const ar = try elf.readArchive(A, bsdArchive(&.{.{ .name = "t.o", .body = object(&.{
        .{ .name = "_komira_t_f", .ty = N_SECT_EXT },
        .{ .name = "_komira_t_private", .ty = 0x1f },
    }) }}));
    var red = checks.Red.init(A);
    const e = try checks.exportList(A, &.{.{ .label = "//t:t", .syms = ar }}, &.{.{ .label = "//t:lib", .calls = &.{"komira_t_f"} }}, &red);
    try t.expect(red.green());
    const list_text = try checks.exportedSymbolsList(A, e.names);
    try t.expectEqualStrings("_komira_t_f\n", list_text);
    const so = try read(.{});
    _ = try checks.check1(A, so, e.names, try checks.symbolsListNames(A, list_text), &red);
    _ = try checks.check2(A, so, &.{.{ .label = "//t:t", .syms = ar }}, &.{.{ .label = "//t:lib", .calls = &.{"komira_t_f"} }}, &red);
    try t.expect(red.green());
}

test "reader refuses: a universal file, another CPU, the wrong file type, and bytes that are not Mach-O" {
    try expectBad("a universal (fat) Mach-O file: only thin arm64 is read", elf.readShared(A, "\xca\xfe\xba\xbe\x00\x00\x00\x02"));
    try expectBad("a universal (fat) Mach-O file: only thin arm64 is read", elf.readShared(A, "\xca\xfe\xba\xbf\x00\x00\x00\x02"));
    try expectBad("a Mach-O file for a CPU other than arm64", read(.{ .cpu = 0x01000007 }));
    try expectBad("a Mach-O file of the wrong type (filetype)", read(.{ .filetype = macho.MH_OBJECT }));
    try expectBad("a Mach-O file of the wrong type (filetype)", macho.readObject(A, dylib(.{})));
    try expectBad("not a 64-bit little-endian Mach-O file", elf.readShared(A, "\xcf\xfa\xed\xfe"));
    try expectBad("not a 64-bit little-endian Mach-O file", macho.readShared(A, "\x7fELF\x02\x01\x01\x00" ** 8));
    try expectBad("not a 64-bit little-endian Mach-O file", macho.readShared(A, "\xca"));
    try t.expect(!macho.isMachO("\xcf\xfa\xed"));
    try t.expect(!macho.isMachO("\x7fELF"));
}

test "reader refuses: load commands outside the file, of a bad size, or not filling sizeofcmds" {
    const good = dylib(.{});
    var b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[20..24], @intCast(good.len), .little);
    try expectBad("the load commands lie outside the file", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[36..40], 12, .little); // the first command's cmdsize
    try expectBad("a load command's size is not a multiple of 8", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[36..40], 0, .little);
    try expectBad("a load command's size is not a multiple of 8", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[36..40], 0x10000, .little);
    try expectBad("a load command lies outside the load commands", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[16..20], 1, .little); // ncmds 1 of several
    try expectBad("the load commands do not fill sizeofcmds", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[16..20], 0xffffffff, .little); // far more commands than sizeofcmds holds
    try expectBad("more load commands than sizeofcmds can hold", elf.readShared(A, b));
    // More commands than there are, though sizeofcmds could hold them: the
    // walk runs off the end of the load commands.
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[16..20], std.mem.readInt(u32, good[16..20], .little) + 1, .little);
    try expectBad("a header lies outside the file", elf.readShared(A, b));
}

test "reader refuses: no install name, two install names, two version commands, a string overlapping its command" {
    try expectBad("no LC_ID_DYLIB (not a dynamic library's install name)", read(.{ .ids = &.{} }));
    try expectBad("two LC_ID_DYLIB commands", read(.{ .ids = &.{ own_id, own_id } }));
    try expectBad("two minimum OS version commands", read(.{ .second_version = true }));
    var b = try A.dupe(u8, dylib(.{}));
    std.mem.writeInt(u32, b[40..44], 8, .little); // LC_ID_DYLIB's name offset
    try expectBad("a load command's string overlaps its fields", elf.readShared(A, b));
    b = try A.dupe(u8, dylib(.{}));
    std.mem.writeInt(u32, b[40..44], 0x1000, .little);
    try expectBad("a name lies outside its string table", elf.readShared(A, b));
    b = try A.dupe(u8, dylib(.{ .ids = &.{"@rpath/x"} }));
    @memset(b[56..72], 'x'); // the name, its NUL and its padding
    try expectBad("a name is not terminated in its string table", elf.readShared(A, b));
}

test "reader refuses: no symbol table, two of them, tables outside the file, an ordinal past the loads" {
    try expectBad("no LC_SYMTAB", read(.{ .symtabs = 0 }));
    try expectBad("two LC_SYMTAB commands", read(.{ .symtabs = 2 }));
    try expectBad("a symbol's library ordinal names no loaded dylib", read(.{ .syms = &.{.{ .name = "_x", .ty = N_UNDF_EXT, .desc = 0x0300 }} }));
    const good = dylib(.{});
    // The LC_SYMTAB command is the last one: symoff, nsyms, stroff, strsize.
    const sizeofcmds = std.mem.readInt(u32, good[20..24], .little);
    const st = 32 + sizeofcmds - 16;
    var b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[st + 8 ..][0..4], @intCast(good.len), .little); // stroff at the end
    std.mem.writeInt(u32, b[st + 12 ..][0..4], 1, .little);
    try expectBad("the string table lies outside the file", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[st + 4 ..][0..4], 0x100000, .little); // nsyms
    try expectBad("the symbol table lies outside the file", elf.readShared(A, b));
    b = try A.dupe(u8, good);
    std.mem.writeInt(u32, b[st ..][0..4], @intCast(good.len + 8), .little); // symoff
    try expectBad("the symbol table lies outside the file", elf.readShared(A, b));
}

test "archive: a BSD archive refuses a bad long name, and an archive mixing ELF and Mach-O members" {
    try expectBad("an archive mixing ELF and Mach-O members", elf.readArchive(A, bsdArchive(&.{
        .{ .name = "a.o", .body = object(&object_syms) },
        .{ .name = "b.o", .body = "\x7fELF" },
    })));
    var b = try A.dupe(u8, bsdArchive(&.{.{ .name = "a.o", .body = object(&object_syms) }}));
    @memcpy(b[8..13], "#1/zz"); // the symbol table member's long name length
    try expectBad("a BSD member name length is not a number", elf.readArchive(A, b));
    b = try A.dupe(u8, bsdArchive(&.{.{ .name = "a.o", .body = object(&object_syms) }}));
    @memcpy(b[8..13], "#1/99");
    try expectBad("a BSD member name lies outside its member", elf.readArchive(A, b));
    try expectBad("an archive with no members", elf.readArchive(A, bsdArchive(&.{})));
    // The other order: an ELF member first, then a Mach-O one.
    try expectBad("an archive mixing ELF and Mach-O members", elf.readArchive(A, bsdArchive(&.{
        .{ .name = "e.o", .body = elfObject() },
        .{ .name = "a.o", .body = object(&object_syms) },
    })));
}

// ---- checks 1 to 7 on a Mach-O library ----------------------------------------

const owners = [_][]const u8{owner_id};

/// memcpy from libSystem alone: a library that loads only the system.
const memcpy_only = [_]NSym{.{ .name = "_memcpy", .ty = N_UNDF_EXT, .desc = 0x0100 }};
const weak = [_][]const u8{"komira_t_hook"};

test "checks 1 to 7: green on the owner-shaped dylib, with the Mach-O titles' messages" {
    const so = try read(.{});
    var red = checks.Red.init(A);
    try t.expectEqualStrings(
        "1 exports, all komira_, exactly the generated list and the exported symbols list",
        try checks.check1(A, so, &.{"komira_t_f"}, &.{"komira_t_f"}, &red),
    );
    const owner = try checks.ownerOf(A, owner_id, try read(.{ .ids = &.{owner_id}, .loads = &.{.{ .name = system }}, .rpaths = &.{}, .syms = &.{.{ .name = "_komira_o_g", .ty = N_SECT_EXT }} }));
    try t.expectEqualStrings(
        "1 strong undefined komira_ symbols, each exported by a declared NEEDED owner: @rpath/libkomira_o_native.1.dylib 1; 1 weak undefined komira_ symbols, all listed",
        try checks.check3(A, so, &weak, &.{owner}, &red),
    );
    try t.expectEqualStrings(
        "install name @rpath/libkomira_t_native.1.dylib; loads /usr/lib/libSystem.B.dylib @rpath/libkomira_o_native.1.dylib; LC_RPATH @loader_path",
        try checks.check4(A, so, own_id, &owners, &red),
    );
    try t.expectEqualStrings("minimum macOS version 11.0, at or below the floor 11.0", try checks.check5(A, so, "11.0", &red));
    try t.expectEqualStrings("header flags 0x100085: two-level namespace, no exported weak definition", try checks.check6(A, so, &red));
    try t.expectEqualStrings(
        "2 strong undefined symbols, all system or komira_; weak undefined exactly the 1 recorded",
        try checks.check7(A, so, &weak, &red),
    );
    try t.expect(red.green());
}

test "check 1: the exported symbols list is named as such when it differs from the list" {
    var red = checks.Red.init(A);
    _ = try checks.check1(A, try read(.{}), &.{"komira_t_f"}, &.{ "komira_t_f", "komira_t_g" }, &red);
    try expectOnly(red, "exported symbols list names not in the list (1): komira_t_g");
    red = checks.Red.init(A);
    _ = try checks.check1(A, try read(.{}), &.{"komira_t_f"}, &.{}, &red);
    try expectOnly(red, "listed names not in the exported symbols list (1): komira_t_f");
}

test "exported symbols list: written with the `_`, read back without it; a line without one is kept whole" {
    try t.expectEqualStrings("_komira_a\n_komira_b\n", try checks.exportedSymbolsList(A, &.{ "komira_a", "komira_b" }));
    try t.expectEqualDeep(
        @as([]const []const u8, &.{ "_", "komira_a", "komira_b", "nounderscore" }),
        @as([]const []const u8, try checks.symbolsListNames(A, "_komira_b\n\n  _komira_a \r\nnounderscore\n_\n_komira_a\n")),
    );
}

test "check 4: a dylib loaded by a re-export, weak, upward or lazy load command, even a system one or an owner" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{
        .{ .cmd = macho.LC_REEXPORT_DYLIB, .name = system },
        .{ .cmd = macho.LC_LOAD_WEAK_DYLIB, .name = owner_id },
        .{ .cmd = macho.LC_LOAD_UPWARD_DYLIB, .name = "/usr/lib/libc++.1.dylib" },
        .{ .cmd = macho.LC_LAZY_LOAD_DYLIB, .name = system },
    } }), own_id, &owners, &red);
    try expectOnly(red, "dylibs loaded by a command other than LC_LOAD_DYLIB (4): /usr/lib/libSystem.B.dylib (LC_REEXPORT_DYLIB) @rpath/libkomira_o_native.1.dylib (LC_LOAD_WEAK_DYLIB) /usr/lib/libc++.1.dylib (LC_LOAD_UPWARD_DYLIB) /usr/lib/libSystem.B.dylib (LC_LAZY_LOAD_DYLIB)");
}

test "check 4 and 5 on a hand-made Mach-O Shared: no install name, no platform, no load kinds recorded" {
    var red = checks.Red.init(A);
    const so = elf.Shared{ .format = .macho, .needed = &.{system}, .minos = "11.0" };
    _ = try checks.check4(A, so, own_id, &.{}, &red);
    try expectOnly(red, "install name is , not @rpath/libkomira_t_native.1.dylib");
    red = checks.Red.init(A);
    _ = try checks.check5(A, so, "11.0", &red);
    try expectOnly(red, "built for platform 0, not macOS (1)");
    try t.expectEqualStrings("LOAD /usr/lib/libSystem.B.dylib\nFLAGS 0x0\nMINOS 0 11.0\n", try render(so));
}

test "check 4: the install name differs" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .ids = &.{"@rpath/other.dylib"} }), own_id, &owners, &red);
    try expectOnly(red, "install name is @rpath/other.dylib, not @rpath/libkomira_t_native.1.dylib");
}

test "check 4: a loaded dylib neither the system's nor a declared owner" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{ .{ .name = system }, .{ .name = owner_id }, .{ .name = "/opt/homebrew/lib/libz.1.dylib" } } }), own_id, &owners, &red);
    try expectOnly(red, "loaded dylibs that are neither the system's nor a declared owner (1): /opt/homebrew/lib/libz.1.dylib");
}

test "check 4: libc++ is a system dylib; a declared owner not loaded is red" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{ .{ .name = system }, .{ .name = "/usr/lib/libc++.1.dylib" } }, .rpaths = &.{}, .syms = &.{} }), own_id, &.{}, &red);
    try t.expect(red.green());
    _ = try checks.check4(A, try read(.{ .loads = &.{.{ .name = system }}, .syms = &memcpy_only }), own_id, &owners, &red);
    try expectOnly(red, "declared owners not loaded (1): @rpath/libkomira_o_native.1.dylib");
}

test "check 4: undefined symbols outside komira_ without libSystem loaded; none needs it" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{.{ .name = owner_id }}, .syms = &.{
        .{ .name = "_memcpy", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_komira_o_g", .ty = N_UNDF_EXT, .desc = 0x0100 },
    } }), own_id, &owners, &red);
    try expectOnly(red, "libSystem is not loaded, but the library has undefined symbols outside komira_ (not linked against the system?)");
    red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{}, .rpaths = &.{}, .syms = &.{.{ .name = "_komira_t_f", .ty = N_SECT_EXT }} }), own_id, &.{}, &red);
    try t.expect(red.green());
}

test "check 4: the run path: absent with an owner, present without one, another entry, @loader_path twice" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .rpaths = &.{} }), own_id, &owners, &red);
    try expectOnly(red, "no LC_RPATH, but a komira owner is loaded: dyld would not find @rpath/libkomira_o_native.1.dylib beside this library (want LC_RPATH @loader_path)");
    red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .loads = &.{.{ .name = system }}, .syms = &memcpy_only }), own_id, &.{}, &red);
    try expectOnly(red, "LC_RPATH entries (no komira owner is loaded, so none is wanted) (1): @loader_path");
    red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .rpaths = &.{ "@loader_path", "/opt/komira/lib" } }), own_id, &owners, &red);
    try expectOnly(red, "LC_RPATH entries other than @loader_path (1): /opt/komira/lib");
    red = checks.Red.init(A);
    _ = try checks.check4(A, try read(.{ .rpaths = &.{ "@loader_path", "@loader_path" } }), own_id, &owners, &red);
    try expectOnly(red, "LC_RPATH lists @loader_path 2 times");
}

test "check 5: a minimum macOS version above the floor, none recorded, another platform, a bad floor" {
    var red = checks.Red.init(A);
    _ = try checks.check5(A, try read(.{ .minos = 0x000d0000 }), "11.0", &red);
    try expectOnly(red, "minimum macOS version 13.0 is above the floor 11.0");
    red = checks.Red.init(A);
    _ = try checks.check5(A, try read(.{ .minos = 0x000a0f02, .version_min = true }), "11.0", &red);
    try t.expect(red.green());
    _ = try checks.check5(A, try read(.{ .minos = null }), "11.0", &red);
    try expectOnly(red, "no LC_BUILD_VERSION: the library records no minimum macOS version");
    red = checks.Red.init(A);
    _ = try checks.check5(A, try read(.{ .platform = 2 }), "11.0", &red);
    try expectOnly(red, "built for platform 2, not macOS (1)");
    red = checks.Red.init(A);
    _ = try checks.check5(A, try read(.{}), "macos-11.0", &red);
    try expectOnly(red, "the floor macos-11.0 is not a dotted version");
}

test "check 6: a flat namespace (a -flat_namespace link), and an exported weak definition" {
    var red = checks.Red.init(A);
    _ = try checks.check6(A, try read(.{ .flags = 0x100005 }), &red);
    try expectOnly(red, "header flags 0x100005 lack MH_TWOLEVEL (0x80): linked with a flat namespace");
    red = checks.Red.init(A);
    _ = try checks.check6(A, try read(.{ .flags = 0x100185 }), &red);
    try expectOnly(red, "header flags 0x100185 carry MH_FORCE_FLAT (0x100): linked -flat_namespace");
    red = checks.Red.init(A);
    _ = try checks.check6(A, try read(.{ .syms = &.{
        .{ .name = "_komira_t_f", .ty = N_SECT_EXT, .desc = 0x80 },
        .{ .name = "_komira_t_inline", .ty = 0x1f, .desc = 0x80 }, // hidden weak: not exported, green
    } }), &red);
    try expectOnly(red, "exported weak definitions (dyld may bind them to another image's copy) (1): komira_t_f");
}

test "check 7: a symbol left to flat lookup (a -undefined dynamic_lookup link), or bound outside the system" {
    var red = checks.Red.init(A);
    _ = try checks.check7(A, try read(.{ .syms = &.{
        .{ .name = "__Znwm", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_strlen", .ty = N_UNDF_EXT, .desc = 0x0200 },
        .{ .name = "_komira_t_hook", .ty = N_UNDF_EXT, .desc = 0x0140 },
    } }), &weak, &red);
    try t.expectEqual(@as(usize, 2), red.lines.items.len);
    try t.expectEqualStrings("undefined symbols bound to no loaded dylib (1): _Znwm from <flat lookup>", red.lines.items[0]);
    try t.expectEqualStrings("strong undefined symbols neither bound to a system dylib nor komira_ (2): _Znwm from <flat lookup> strlen from @rpath/libkomira_o_native.1.dylib", red.lines.items[1]);
}

test "check 7: a komira_ symbol, strong or weak, left to flat lookup, the main executable or the library itself" {
    var red = checks.Red.init(A);
    _ = try checks.check7(A, try read(.{ .syms = &.{
        .{ .name = "_komira_o_g", .ty = N_UNDF_EXT, .desc = 0xfe00 },
        .{ .name = "_komira_o_h", .ty = N_UNDF_EXT, .desc = 0xff00 },
        .{ .name = "_komira_o_i", .ty = N_UNDF_EXT, .desc = 0x0000 },
        .{ .name = "_komira_t_hook", .ty = N_UNDF_EXT, .desc = 0xfe40 },
    } }), &weak, &red);
    try expectOnly(red, "undefined symbols bound to no loaded dylib (4): komira_o_g from <flat lookup> komira_o_h from <main executable> komira_o_i from <this library> komira_t_hook from <flat lookup>");
}

test "check 7: an object's undefined symbol carries no library, and is red" {
    var so = try read(.{});
    var syms = std.ArrayList(elf.Sym).empty;
    try syms.appendSlice(A, so.syms);
    try syms.append(A, .{ .name = "memmove", .defined = false, .bind = .global, .vis = .default });
    so.syms = syms.items;
    var red = checks.Red.init(A);
    _ = try checks.check7(A, so, &weak, &red);
    try expectOnly(red, "strong undefined symbols neither bound to a system dylib nor komira_ (1): memmove from <no library>");
}

test "check 7: the weak undefined symbols differ from the recorded list, both ways" {
    var red = checks.Red.init(A);
    _ = try checks.check7(A, try read(.{}), &.{}, &red);
    try expectOnly(red, "weak undefined symbols not on the recorded weak list (1): komira_t_hook");
    red = checks.Red.init(A);
    _ = try checks.check7(A, try read(.{}), &.{ "komira_t_hook", "komira_t_gone" }, &red);
    try expectOnly(red, "recorded weak names the library no longer references (update the list) (1): komira_t_gone");
}

test "README check: a Mach-O README object references an export" {
    const prog = try elf.readProgram(A, object(&.{.{ .name = "_komira_t_f", .ty = N_UNDF_EXT }}));
    var red = checks.Red.init(A);
    const msg = try checks.checkReadme(A, &.{"komira_t_f"}, &.{.{ .name = "readme_0.o", .syms = prog }}, &red);
    try t.expect(red.green());
    try t.expectEqualStrings("1 of 1 README programs reference an export: komira_t_f in readme_0.o", msg);
}
