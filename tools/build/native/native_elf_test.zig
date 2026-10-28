//! Unit tests of native_elf.zig's `readShared` on real ELF bytes (run by
//! `:native_so_unit`). The checks' tests (native_so_test.zig) feed hand-made
//! `Shared` values; these build a small 64-bit little-endian shared object
//! byte by byte (`fixture`) and read it, so a dynamic tag, a needed or
//! defined version, or a symbol attribute the reader drops is red here even
//! when komira_crypto's green library carries none of it (it has no run
//! path). The object has every dynamic tag the reader keeps (NEEDED and
//! RUNPATH more than once, a non-glibc NEEDED before the last), an entry after
//! DT_NULL (which must not be read), version-needed and version-definition
//! sections, and a local, a hidden, a weak and versioned symbols.

const std = @import("std");
const elf = @import("native_elf.zig");
const checks = @import("native_checks.zig");

const t = std.testing;
const A = std.heap.page_allocator;

pub const Opts = struct { runpath: bool = true, rpath: bool = true, stray: bool = true };

const Buf = std.ArrayList(u8);

fn put(b: *Buf, comptime T: type, v: T) void {
    var x: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &x, v, .little);
    b.appendSlice(A, &x) catch unreachable;
}

/// Appends `s` and its NUL to the string table; returns its offset.
fn str(tab: *Buf, s: []const u8) u32 {
    const at: u32 = @intCast(tab.items.len);
    tab.appendSlice(A, s) catch unreachable;
    tab.append(A, 0) catch unreachable;
    return at;
}

fn dyn(b: *Buf, tag: u64, val: u64) void {
    put(b, u64, tag);
    put(b, u64, val);
}

fn sym(b: *Buf, name: u32, bind: u8, vis: u8, shndx: u16) void {
    put(b, u32, name);
    b.append(A, bind << 4 | 2) catch unreachable; // STT_FUNC
    b.append(A, vis) catch unreachable;
    put(b, u16, shndx);
    put(b, u64, 0);
    put(b, u64, 0);
}

/// A shared object `libkomira_t.so.1` with NEEDED libpthread.so.0, a stray
/// non-glibc libstray.so.1 (if `opts.stray`) and libc.so.6 last, two RUNPATH
/// entries and one RPATH (as `opts` asks), DT_SYMBOLIC, DT_FLAGS 0xa and
/// DT_FLAGS_1 0x1. More than one NEEDED and RUNPATH entry, so a reader
/// keeping only one of each is red.
pub fn fixture(opts: Opts) []const u8 {
    var s = Buf.empty;
    s.append(A, 0) catch unreachable;
    const n_soname = str(&s, "libkomira_t.so.1");
    const n_libc = str(&s, "libc.so.6");
    const n_pthread = str(&s, "libpthread.so.0");
    const n_stray = str(&s, "libstray.so.1");
    const n_runpath = str(&s, "$ORIGIN/lib");
    const n_runpath2 = str(&s, "/opt/runpath");
    const n_rpath = str(&s, "/opt/rpath");
    const n_after = str(&s, "libafter_null.so.1");
    const n_g214 = str(&s, "GLIBC_2.14");
    const n_g225 = str(&s, "GLIBC_2.2.5");
    const n_kv = str(&s, "KOMIRA_T_1");
    const n_f = str(&s, "komira_t_f");
    const n_memcpy = str(&s, "memcpy");
    const n_once = str(&s, "pthread_once");
    const n_gmon = str(&s, "__gmon_start__");
    const n_local = str(&s, "komira_t_local");
    const n_hidden = str(&s, "komira_t_hidden");

    var d = Buf.empty;
    dyn(&d, 1, n_pthread); // DT_NEEDED
    if (opts.stray) dyn(&d, 1, n_stray);
    dyn(&d, 1, n_libc);
    dyn(&d, 14, n_soname); // DT_SONAME
    if (opts.runpath) {
        dyn(&d, 29, n_runpath); // DT_RUNPATH
        dyn(&d, 29, n_runpath2);
    }
    if (opts.rpath) dyn(&d, 15, n_rpath); // DT_RPATH
    dyn(&d, 16, 0); // DT_SYMBOLIC
    dyn(&d, 30, 0xa); // DT_FLAGS
    dyn(&d, 0x6ffffffb, 0x1); // DT_FLAGS_1
    dyn(&d, 0, 0); // DT_NULL: nothing after it is read
    dyn(&d, 1, n_after);

    // Index: 0 null, 1 komira_t_f, 2 memcpy, 3 pthread_once, 4
    // __gmon_start__ (weak), 5 a local, 6 a hidden definition.
    var y = Buf.empty;
    for (0..24) |_| y.append(A, 0) catch unreachable;
    sym(&y, n_f, 1, 0, 7);
    sym(&y, n_memcpy, 1, 0, 0);
    sym(&y, n_once, 1, 0, 0);
    sym(&y, n_gmon, 2, 0, 0);
    sym(&y, n_local, 0, 0, 7);
    sym(&y, n_hidden, 1, 2, 7);

    // Version indexes: 2 GLIBC_2.14, 3 GLIBC_2.2.5 (needed), 1 the base and
    // 4 KOMIRA_T_1 (defined); komira_t_f's carries the hidden bit.
    var v = Buf.empty;
    for ([_]u16{ 0, 0x8004, 2, 3, 1, 0, 1 }) |x| put(&v, u16, x);

    var vn = Buf.empty; // one Verneed (libc.so.6), two Vernaux
    put(&vn, u16, 1);
    put(&vn, u16, 2);
    put(&vn, u32, n_libc);
    put(&vn, u32, 16);
    put(&vn, u32, 0);
    for ([_][2]u32{ .{ 2, n_g214 }, .{ 3, n_g225 } }, 0..) |a, i| {
        put(&vn, u32, 0); // vna_hash
        put(&vn, u16, 0); // vna_flags
        put(&vn, u16, @intCast(a[0]));
        put(&vn, u32, a[1]);
        put(&vn, u32, if (i == 0) 16 else 0);
    }

    var vd = Buf.empty; // two Verdef, each with one Verdaux
    for ([_][2]u32{ .{ 1, n_soname }, .{ 4, n_kv } }, 0..) |a, i| {
        put(&vd, u16, 1); // vd_version
        put(&vd, u16, if (i == 0) 1 else 0); // VER_FLG_BASE
        put(&vd, u16, @intCast(a[0]));
        put(&vd, u16, 1); // vd_cnt
        put(&vd, u32, 0); // vd_hash
        put(&vd, u32, 20); // vd_aux
        put(&vd, u32, if (i == 0) 28 else 0); // vd_next
        put(&vd, u32, a[1]); // vda_name
        put(&vd, u32, 0); // vda_next
    }

    // Sections: 1 .dynstr, 2 .dynamic, 3 .dynsym, 4 versym, 5 verneed,
    // 6 verdef, 7 a stand-in for .text (the definitions' section index).
    const Sec = struct { type: u32, body: []const u8, link: u32, info: u32 };
    const secs = [_]Sec{
        .{ .type = 3, .body = s.items, .link = 0, .info = 0 },
        .{ .type = 6, .body = d.items, .link = 1, .info = 0 },
        .{ .type = 11, .body = y.items, .link = 1, .info = 1 },
        .{ .type = 0x6fffffff, .body = v.items, .link = 3, .info = 0 },
        .{ .type = 0x6ffffffe, .body = vn.items, .link = 1, .info = 1 },
        .{ .type = 0x6ffffffd, .body = vd.items, .link = 1, .info = 2 },
        .{ .type = 1, .body = "\xc3", .link = 0, .info = 0 },
    };
    var f = Buf.empty;
    f.appendSlice(A, "\x7fELF\x02\x01\x01") catch unreachable;
    f.appendNTimes(A, 0, 9) catch unreachable;
    put(&f, u16, 3); // ET_DYN
    put(&f, u16, 62); // EM_X86_64
    put(&f, u32, 1);
    put(&f, u64, 0); // e_entry
    put(&f, u64, 0); // e_phoff
    const shoff_at = f.items.len;
    put(&f, u64, 0); // e_shoff, patched below
    put(&f, u32, 0);
    put(&f, u16, 64);
    put(&f, u16, 56);
    put(&f, u16, 0);
    put(&f, u16, 64);
    put(&f, u16, secs.len + 1);
    put(&f, u16, 1); // e_shstrndx: section names are not read
    var offs: [secs.len]u64 = undefined;
    for (secs, 0..) |sec, i| {
        while (f.items.len % 8 != 0) f.append(A, 0) catch unreachable;
        offs[i] = f.items.len;
        f.appendSlice(A, sec.body) catch unreachable;
    }
    while (f.items.len % 8 != 0) f.append(A, 0) catch unreachable;
    std.mem.writeInt(u64, f.items[shoff_at..][0..8], f.items.len, .little);
    f.appendNTimes(A, 0, 64) catch unreachable; // section 0
    for (secs, 0..) |sec, i| {
        put(&f, u32, 0);
        put(&f, u32, sec.type);
        put(&f, u64, 0);
        put(&f, u64, 0);
        put(&f, u64, offs[i]);
        put(&f, u64, sec.body.len);
        put(&f, u32, sec.link);
        put(&f, u32, sec.info);
        put(&f, u64, 8);
        put(&f, u64, if (sec.type == 11) 24 else 0);
    }
    return f.items;
}

fn render(so: elf.Shared) ![]const u8 {
    var b = Buf.empty;
    try elf.writeShared(b.writer(A), so);
    return b.items;
}

test "reader: every dynamic tag, version and symbol of a built shared object" {
    const so = try elf.readShared(A, fixture(.{}));
    try t.expectEqualStrings(
        \\SONAME libkomira_t.so.1
        \\NEEDED libpthread.so.0
        \\NEEDED libstray.so.1
        \\NEEDED libc.so.6
        \\RUNPATH $ORIGIN/lib
        \\RUNPATH /opt/runpath
        \\RPATH /opt/rpath
        \\SYMBOLIC
        \\FLAGS 0xa
        \\FLAGS_1 0x1
        \\VERNEED libc.so.6 GLIBC_2.14
        \\VERNEED libc.so.6 GLIBC_2.2.5
        \\DEF global default komira_t_f@KOMIRA_T_1
        \\UND global default memcpy@GLIBC_2.14
        \\UND global default pthread_once@GLIBC_2.2.5
        \\UND weak default __gmon_start__
        \\DEF global hidden komira_t_hidden
        \\
    , try render(so));
    const exp = try checks.exportsOf(A, so);
    try t.expectEqual(@as(usize, 1), exp.len);
    try t.expectEqualStrings("komira_t_f", exp[0]);
}

test "reader + check 4: a RUNPATH and an RPATH read from the object are red; none is green" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try elf.readShared(A, fixture(.{ .runpath = false, .rpath = false, .stray = false })), "libkomira_t.so.1", &.{}, &red);
    try t.expect(red.green());
    red = checks.Red.init(A);
    _ = try checks.check4(A, try elf.readShared(A, fixture(.{ .rpath = false, .stray = false })), "libkomira_t.so.1", &.{}, &red);
    try t.expectEqual(@as(usize, 1), red.lines.items.len);
    try t.expectEqualStrings("RUNPATH entries (no komira owner is NEEDED, so none is wanted) (2): $ORIGIN/lib /opt/runpath", red.lines.items[0]);
    red = checks.Red.init(A);
    _ = try checks.check4(A, try elf.readShared(A, fixture(.{ .runpath = false, .stray = false })), "libkomira_t.so.1", &.{}, &red);
    try t.expectEqual(@as(usize, 1), red.lines.items.len);
    try t.expectEqualStrings("RPATH entries (1): /opt/rpath", red.lines.items[0]);
}

test "reader + check 4: a stray non-glibc NEEDED read from the object is red when it is not the last entry" {
    var red = checks.Red.init(A);
    _ = try checks.check4(A, try elf.readShared(A, fixture(.{ .runpath = false, .rpath = false })), "libkomira_t.so.1", &.{}, &red);
    try t.expectEqual(@as(usize, 1), red.lines.items.len);
    try t.expectEqualStrings("NEEDED entries that are neither glibc nor a declared owner (1): libstray.so.1", red.lines.items[0]);
}
