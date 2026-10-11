//! Planted ELF fixtures for the tests of loader_closure.zig: a prefix
//! directory under the test run's own TMPDIR, and minimal ELF64
//! little-endian files written into it with exactly the PT_INTERP,
//! DT_NEEDED, DT_RPATH, DT_RUNPATH and DT_SONAME a test names. Nothing here
//! is linked or run; the loader never sees these files.

const std = @import("std");
const lc = @import("loader_closure.zig");
const posix = if (@hasDecl(std, "posix")) std.posix else std.os;

/// What one planted ELF file holds. `interp` set makes it a program.
pub const Spec = struct {
    interp: ?[]const u8 = null,
    needed: []const []const u8 = &.{},
    rpath: ?[]const u8 = null,
    runpath: ?[]const u8 = null,
    soname: ?[]const u8 = null,
    /// Bytes appended to the string table, as a version name would be.
    extra: []const u8 = "",
};

/// The program a test plants most: needs `needed`, finds them through the
/// DT_RPATH `$ORIGIN/../lib`.
pub fn program(needed: []const []const u8) Spec {
    return .{ .interp = lc.DEFAULT_INTERP, .needed = needed, .rpath = "$ORIGIN/../lib" };
}

// The virtual address of file offset 0: unlike the offset, so a parser that
// reads DT_STRTAB as a file offset reads the wrong bytes.
const BASE: u64 = 0x400000;

fn put(comptime T: type, b: []u8, at: usize, v: T) void {
    std.mem.writeInt(T, b[at..][0..@sizeOf(T)], v, .little);
}

/// The bytes of an ELF64 little-endian x86_64 file: the ELF header, a
/// PT_LOAD covering the file, PT_INTERP when `interp` is set, PT_DYNAMIC;
/// then the interpreter path, the string table and the dynamic section.
pub fn elf(a: std.mem.Allocator, s: Spec) ![]u8 {
    var strtab = std.ArrayList(u8).init(a);
    try strtab.append(0);
    var dyn = std.ArrayList([2]u64).init(a);
    const str = struct {
        fn add(t: *std.ArrayList(u8), v: []const u8) !u64 {
            const pos = t.items.len;
            try t.appendSlice(v);
            try t.append(0);
            return pos;
        }
    };
    for (s.needed) |n| try dyn.append(.{ 1, try str.add(&strtab, n) });
    if (s.soname) |v| try dyn.append(.{ 14, try str.add(&strtab, v) });
    if (s.rpath) |v| try dyn.append(.{ 15, try str.add(&strtab, v) });
    if (s.runpath) |v| try dyn.append(.{ 29, try str.add(&strtab, v) });
    if (s.extra.len != 0) _ = try str.add(&strtab, s.extra);

    const nph: usize = if (s.interp != null) 3 else 2;
    const interp_at: usize = 64 + nph * 56;
    const interp_len: usize = if (s.interp) |i| i.len + 1 else 0;
    const str_at = interp_at + interp_len;
    const dyn_at = std.mem.alignForward(usize, str_at + strtab.items.len, 8);
    // DT_STRTAB, DT_STRSZ, DT_NULL after the planted entries.
    const dyn_len = (dyn.items.len + 3) * 16;
    const total = dyn_at + dyn_len;
    const b = try a.alloc(u8, total);
    @memset(b, 0);

    @memcpy(b[0..4], "\x7fELF");
    b[4] = 2; // ELFCLASS64
    b[5] = 1; // ELFDATA2LSB
    b[6] = 1; // EV_CURRENT
    put(u16, b, 16, if (s.interp != null) 2 else 3); // ET_EXEC or ET_DYN
    put(u16, b, 18, 62); // EM_X86_64
    put(u32, b, 20, 1);
    put(u64, b, 32, 64); // e_phoff
    put(u16, b, 52, 64); // e_ehsize
    put(u16, b, 54, 56); // e_phentsize
    put(u16, b, 56, @intCast(nph));

    var ph: usize = 64;
    const phdr = struct {
        fn w(bytes: []u8, o: usize, ty: u32, off: u64, size: u64) void {
            put(u32, bytes, o, ty);
            put(u64, bytes, o + 8, off);
            put(u64, bytes, o + 16, BASE + off);
            put(u64, bytes, o + 24, BASE + off);
            put(u64, bytes, o + 32, size);
            put(u64, bytes, o + 40, size);
            put(u64, bytes, o + 48, 8);
        }
    };
    phdr.w(b, ph, 1, 0, total); // PT_LOAD
    ph += 56;
    if (s.interp) |i| {
        phdr.w(b, ph, 3, interp_at, interp_len); // PT_INTERP
        ph += 56;
        @memcpy(b[interp_at..][0..i.len], i);
    }
    phdr.w(b, ph, 2, dyn_at, dyn_len); // PT_DYNAMIC
    @memcpy(b[str_at..][0..strtab.items.len], strtab.items);
    var at = dyn_at;
    try dyn.append(.{ 5, BASE + str_at }); // DT_STRTAB
    try dyn.append(.{ 10, strtab.items.len }); // DT_STRSZ
    for (dyn.items) |e| {
        put(u64, b, at, e[0]);
        put(u64, b, at + 8, e[1]);
        at += 16;
    }
    return b; // DT_NULL: the zeroed last entry
}

/// A prefix directory of its own under this run's TMPDIR.
pub const Tree = struct {
    a: std.mem.Allocator,
    dir: []const u8,

    pub fn init(a: std.mem.Allocator, name: []const u8) !Tree {
        const tmp = posix.getenv("TMPDIR") orelse "/tmp";
        const d = try std.fmt.allocPrint(a, "{s}/loader_closure_{s}_{d}", .{ tmp, name, std.os.linux.getpid() });
        try std.fs.cwd().makePath(d);
        return .{ .a = a, .dir = d };
    }

    /// The bytes `data` at `rel` in the prefix.
    pub fn file(t: Tree, rel: []const u8, data: []const u8) !void {
        const p = try std.fs.path.join(t.a, &.{ t.dir, rel });
        try std.fs.cwd().makePath(std.fs.path.dirname(p).?);
        try std.fs.cwd().writeFile(p, data);
    }

    /// A planted ELF file at `rel`.
    pub fn plant(t: Tree, rel: []const u8, s: Spec) !void {
        try t.file(rel, try elf(t.a, s));
    }

    pub fn symlink(t: Tree, target: []const u8, rel: []const u8) !void {
        const p = try std.fs.path.join(t.a, &.{ t.dir, rel });
        try std.fs.cwd().makePath(std.fs.path.dirname(p).?);
        try std.fs.cwd().symLink(target, p, .{});
    }

    pub fn check(t: Tree, opts: lc.Options) !lc.Report {
        return lc.check(t.a, t.dir, opts);
    }
};

fn show(r: lc.Report) void {
    for (r.findings.items) |f| std.debug.print("  finding: {s}\n", .{f});
    for (r.lines.items) |l| std.debug.print("  maps: {s}\n", .{l});
}

/// Fails unless the check of `t` is green.
pub fn expectGreen(t: Tree, opts: lc.Options) !lc.Report {
    const r = try t.check(opts);
    if (r.findings.items.len != 0) {
        std.debug.print("want green, got red:\n", .{});
        show(r);
        return error.TestExpectedGreen;
    }
    return r;
}

/// Fails unless the check of `t` is red with exactly one finding, which
/// contains `want`.
pub fn expectRed(t: Tree, opts: lc.Options, want: []const u8) !void {
    const r = try t.check(opts);
    if (r.findings.items.len != 1 or std.mem.indexOf(u8, r.findings.items[0], want) == null) {
        std.debug.print("want one finding containing '{s}', got {d}:\n", .{ want, r.findings.items.len });
        show(r);
        return error.TestExpectedRed;
    }
}

/// Fails unless the check maps `rel` for some program (a line naming it).
pub fn expectMaps(r: lc.Report, want: []const u8) !void {
    for (r.lines.items) |l| if (std.mem.indexOf(u8, l, want) != null) return;
    std.debug.print("no mapped line contains '{s}':\n", .{want});
    show(r);
    return error.TestExpectedMapping;
}
