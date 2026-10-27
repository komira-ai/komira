//! The cases of debug_relocate (README.md#tests), `zig test` of this file
//! (which imports debug_relocate.zig) run as a build action by
//! `:debug_relocate_unit`; the executable `:debug_relocate_exe` is not built
//! unless every one passes.
//!
//! Each case runs the program as main does (`entry`: the command line, a
//! working directory, stdout, stderr) in a directory of its own, and reads
//! back the exit status, the counts, the messages and the file. The paths are
//! made up; the ELF files are written byte by byte.

const std = @import("std");
const R = @import("debug_relocate.zig");

const Args = []const []const u8;

// A made-up sandbox directory (35 bytes) and its placeholder: '/' and 34 '_'.
const D = "/worker/build/0123456789abcdef/root";
const P = "/__________________________________";
// A second directory (18 bytes) and its placeholder.
const D2 = "/var/scratch/act42";
const P2 = "/_________________";

comptime {
    std.debug.assert(D.len == 35 and P.len == 35);
    std.debug.assert(D2.len == 18 and P2.len == 18);
}

const Result = struct {
    status: u8,
    out: []const u8,
    err: []const u8,
};

/// A directory of its own, where the program runs.
const Case = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,

    fn init() Case {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            .tmp = std.testing.tmpDir(.{ .iterate = true }),
        };
    }

    fn deinit(self: *Case) void {
        self.tmp.cleanup();
        self.arena.deinit();
    }

    fn alloc(self: *Case) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn put(self: *Case, name: []const u8, bytes: []const u8) !void {
        var f = try self.tmp.dir.createFile(name, .{});
        defer f.close();
        try f.writeAll(bytes);
    }

    fn read(self: *Case, name: []const u8) ![]const u8 {
        return self.tmp.dir.readFileAlloc(self.alloc(), name, 1 << 20);
    }

    fn run(self: *Case, args: Args) !Result {
        const a = self.alloc();
        var out = std.ArrayList(u8).empty;
        var err = std.ArrayList(u8).empty;
        const status = R.entry(a, self.tmp.dir, args, out.writer(a), err.writer(a));
        return .{ .status = status, .out = out.items, .err = err.items };
    }

    /// The file `name` holds exactly `want`: the same length, byte for byte.
    fn same(self: *Case, what: []const u8, name: []const u8, want: []const u8) !void {
        const got = try self.read(name);
        if (got.len != want.len) {
            std.debug.print("{s}: length changed ({d} -> {d})\n", .{ what, want.len, got.len });
            return error.TestUnexpectedResult;
        }
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: bytes differ from the expected file\n", .{what});
            return error.TestUnexpectedResult;
        }
    }

    fn inode(self: *Case, name: []const u8) !std.fs.File.INode {
        return (try self.tmp.dir.statFile(name)).inode;
    }
};

fn expectStatus(what: []const u8, r: Result, want: u8) !void {
    if (r.status != want) {
        std.debug.print("{s}: exit {d}, want {d}; stdout:\n{s}\nstderr:\n{s}\n", .{ what, r.status, want, r.out, r.err });
        return error.TestUnexpectedResult;
    }
}

fn expectStdout(what: []const u8, r: Result, want: []const u8) !void {
    if (!std.mem.eql(u8, r.out, want)) {
        std.debug.print("{s}: stdout '{s}', want '{s}'\n", .{ what, r.out, want });
        return error.TestUnexpectedResult;
    }
}

fn has(what: []const u8, hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("{s}: does not say '{s}'; it says:\n{s}\n", .{ what, needle, hay });
        return error.TestUnexpectedResult;
    }
}

/// Exit 1 naming `msg` on stderr, nothing on stdout.
fn refused(what: []const u8, r: Result, msg: []const u8) !void {
    try expectStatus(what, r, 1);
    try has(what, r.err, msg);
    if (r.out.len != 0) {
        std.debug.print("{s}: counts were printed: '{s}'\n", .{ what, r.out });
        return error.TestUnexpectedResult;
    }
}

// The ELF fixtures: a header, then .shstrtab, then one section holding D and
// a NUL, then the section headers (null, .shstrtab, .debug_line).
const strtab = "\x00.shstrtab\x00.debug_line\x00";
const data = D ++ "\x00";

const Bytes = struct {
    b: std.ArrayList(u8),
    a: std.mem.Allocator,

    fn le(self: *Bytes, comptime T: type, v: u64) void {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        var x: [n]u8 = undefined;
        std.mem.writeInt(T, &x, @intCast(v), .little);
        self.b.appendSlice(self.a, &x) catch @panic("out of memory");
    }

    fn raw(self: *Bytes, s: []const u8) void {
        self.b.appendSlice(self.a, s) catch @panic("out of memory");
    }

    fn zeros(self: *Bytes, n: usize) void {
        self.b.appendNTimes(self.a, 0, n) catch @panic("out of memory");
    }

    /// One ELF64 section header.
    fn shdr64(self: *Bytes, name: u64, typ: u64, flags: u64, off: u64, size: u64) void {
        self.le(u32, name);
        self.le(u32, typ);
        self.le(u64, flags);
        self.le(u64, 0);
        self.le(u64, off);
        self.le(u64, size);
        self.le(u32, 0);
        self.le(u32, 0);
        self.le(u64, 1);
        self.le(u64, 0);
    }

    /// One ELF32 section header (32-bit sh_flags).
    fn shdr32(self: *Bytes, name: u64, typ: u64, flags: u64, off: u64, size: u64) void {
        self.le(u32, name);
        self.le(u32, typ);
        self.le(u32, flags);
        self.le(u32, 0);
        self.le(u32, off);
        self.le(u32, size);
        self.le(u32, 0);
        self.le(u32, 0);
        self.le(u32, 1);
        self.le(u32, 0);
    }
};

/// An ELF64 file whose .debug_line has `flags`; `shoff` defaults to where
/// the headers really are. With `many`, e_shnum is 0 and section 0's sh_size
/// holds the count (3).
fn elf64(a: std.mem.Allocator, flags: u64, shoff: ?u64, many: bool) []const u8 {
    var w = Bytes{ .b = std.ArrayList(u8).empty, .a = a };
    const real = 64 + strtab.len + data.len;
    w.raw("\x7fELF");
    w.le(u8, 2);
    w.le(u8, 1);
    w.le(u8, 1);
    w.zeros(9);
    w.le(u16, 1);
    w.le(u16, 62);
    w.le(u32, 1);
    w.le(u64, 0);
    w.le(u64, 0);
    w.le(u64, shoff orelse real);
    w.le(u32, 0);
    w.le(u16, 64);
    w.le(u16, 0);
    w.le(u16, 0);
    w.le(u16, 64);
    w.le(u16, if (many) 0 else 3);
    w.le(u16, 1);
    w.raw(strtab);
    w.raw(data);
    if (many) w.shdr64(0, 0, 0, 0, 3) else w.zeros(64);
    w.shdr64(1, 3, 0, 64, strtab.len);
    w.shdr64(11, 1, flags, 64 + strtab.len, data.len);
    return w.b.items;
}

/// The same as an ELF32 file: 52-byte header, 40-byte section headers.
fn elf32(a: std.mem.Allocator, flags: u64, many: bool) []const u8 {
    var w = Bytes{ .b = std.ArrayList(u8).empty, .a = a };
    w.raw("\x7fELF");
    w.le(u8, 1);
    w.le(u8, 1);
    w.le(u8, 1);
    w.zeros(9);
    w.le(u16, 1);
    w.le(u16, 3);
    w.le(u32, 1);
    w.le(u32, 0);
    w.le(u32, 0);
    w.le(u32, 52 + strtab.len + data.len);
    w.le(u32, 0);
    w.le(u16, 52);
    w.le(u16, 0);
    w.le(u16, 0);
    w.le(u16, 40);
    w.le(u16, if (many) 0 else 3);
    w.le(u16, 1);
    w.raw(strtab);
    w.raw(data);
    if (many) w.shdr32(0, 0, 0, 0, 3) else w.zeros(40);
    w.shdr32(1, 3, 0, 52, strtab.len);
    w.shdr32(11, 1, flags, 52 + strtab.len, data.len);
    return w.b.items;
}

/// A file size limit of 512 bytes with SIGXFSZ ignored, so a write past it
/// fails with EFBIG part way (FileTooBig); `restore` puts both back.
const SizeLimit = struct {
    old: std.posix.rlimit,
    old_act: std.posix.Sigaction,

    fn set() !SizeLimit {
        const posix = std.posix;
        const ign = posix.Sigaction{ .handler = .{ .handler = posix.SIG.IGN }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
        var l: SizeLimit = undefined;
        posix.sigaction(posix.SIG.XFSZ, &ign, &l.old_act);
        l.old = try posix.getrlimit(.FSIZE);
        posix.setrlimit(.FSIZE, .{ .cur = 512, .max = l.old.max }) catch |e| {
            posix.sigaction(posix.SIG.XFSZ, &l.old_act, null);
            return e;
        };
        return l;
    }

    fn restore(self: *const SizeLimit) void {
        std.posix.setrlimit(.FSIZE, self.old) catch {};
        std.posix.sigaction(std.posix.SIG.XFSZ, &self.old_act, null);
    }
};

/// D and a NUL, doubled 11 times: 73728 bytes (72 KiB), over the limit.
fn big(a: std.mem.Allocator) []const u8 {
    var b: []const u8 = data;
    for (0..11) |_| b = std.mem.concat(a, u8, &.{ b, b }) catch @panic("out of memory");
    return b;
}

// 1. An occurrence followed by NUL is rewritten (a DW_AT_comp_dir string).
test "followed by NUL: rewritten, same length, '1 <dir>' printed" {
    var c = Case.init();
    defer c.deinit();
    try c.put("f", "A" ++ D ++ "\x00B");
    const r = try c.run(&.{ "f", D });
    try expectStatus("followed by NUL", r, 0);
    try expectStdout("followed by NUL", r, "1 " ++ D ++ "\n");
    try c.same("followed by NUL", "f", "A" ++ P ++ "\x00B");
}

// 2. An occurrence followed by '/' is rewritten (a file path under it).
test "followed by '/': a path under the directory is rewritten" {
    var c = Case.init();
    defer c.deinit();
    try c.put("f", "x" ++ D ++ "/buck-out/a.mojo\x00");
    const r = try c.run(&.{ "f", D });
    try expectStatus("followed by '/'", r, 0);
    try expectStdout("followed by '/'", r, "1 " ++ D ++ "\n");
    try c.same("followed by '/'", "f", "x" ++ P ++ "/buck-out/a.mojo\x00");
}

// 3. An occurrence followed by another byte ('x': the longer name /rootx) is
// refused with exit 1 and its offset, and the file keeps every byte, the
// rewritable occurrence before it included.
test "followed by 'x': exit 1 naming offset 39, the file untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = D ++ "/ok\x00" ++ D ++ "x\x00";
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try refused("followed by 'x'", r, "at offset 39 is followed by byte 0x78");
    try c.same("followed by 'x' (must be untouched)", "f", f);
}

// 4. An occurrence that ends the file is refused the same way.
test "at the end of the file: exit 1 naming offset 2, the file untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = "A\x00" ++ D;
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try refused("at the end of the file", r, "at offset 2 ends the file");
    try c.same("at the end of the file (must be untouched)", "f", f);
}

// 5. Several occurrences of several directories, each counted (D three
// times, D2 twice, so a count printed against the wrong directory shows); the
// permission bits are kept through the rename, other-write included, which a
// umask of 022 (set here) clears from a file created with them.
test "two directories: each occurrence counted and rewritten, mode 757 kept" {
    var c = Case.init();
    defer c.deinit();
    try c.put("f", D ++ "\x00" ++ D2 ++ "/f\x00" ++ D ++ "/g\x00" ++ D2 ++ "\x00" ++ D ++ "/h\x00");
    {
        var f = try c.tmp.dir.openFile("f", .{});
        defer f.close();
        try f.chmod(0o757);
    }
    const linux = std.os.linux;
    const old_mask = linux.syscall1(.umask, 0o022);
    defer _ = linux.syscall1(.umask, old_mask);
    const r = try c.run(&.{ "f", D, D2 });
    try expectStatus("two directories", r, 0);
    try expectStdout("two directories", r, "3 " ++ D ++ "\n2 " ++ D2 ++ "\n");
    try c.same("two directories", "f", P ++ "\x00" ++ P2 ++ "/f\x00" ++ P ++ "/g\x00" ++ P2 ++ "\x00" ++ P ++ "/h\x00");
    const mode = (try c.tmp.dir.statFile("f")).mode & 0o7777;
    if (mode != 0o757) {
        std.debug.print("two directories: mode {o}, want 757\n", .{mode});
        return error.TestUnexpectedResult;
    }
}

// 6. A directory under 8 bytes (7: one under the floor), a relative one, one
// ending in '/', and no directory at all are bad usage: exit 2, the file
// untouched.
test "usage: a 7-byte, a relative, a trailing-'/' directory and none exit 2" {
    var c = Case.init();
    defer c.deinit();
    const f = "/a/b/c/";
    try c.put("f", f);
    const cases = [_]Args{ &.{ "f", "/a/b/cd" }, &.{ "f", "a/b/c/d/e/f" }, &.{ "f", D ++ "/" }, &.{"f"} };
    for (cases) |args| {
        const r = try c.run(args);
        const what = if (args.len > 1) args[1] else "(none)";
        try expectStatus(what, r, 2);
        try has(what, r.err, "\nusage: debug_relocate");
        try c.same(what, "f", f);
    }
}

// 7. A directory of exactly 8 bytes is accepted: the floor is 8, not 9.
test "8-byte directory: accepted and rewritten" {
    var c = Case.init();
    defer c.deinit();
    try c.put("f", "/a/b/c/d/e\x00");
    const r = try c.run(&.{ "f", "/a/b/c/d" });
    try expectStatus("8-byte directory", r, 0);
    try expectStdout("8-byte directory", r, "1 /a/b/c/d\n");
    try c.same("8-byte directory", "f", "/_______/e\x00");
}

// 8. A file with no occurrence: 0 rewrites, exit 0, the bytes unchanged, and
// the file not written at all: the same inode (a rename would give a new one).
test "no occurrence: '0 <dir>', exit 0, the same bytes and inode" {
    var c = Case.init();
    defer c.deinit();
    const f = "no sandbox path here\x00/worker/build/\x00";
    try c.put("f", f);
    const ino = try c.inode("f");
    const r = try c.run(&.{ "f", D });
    try expectStatus("no occurrence", r, 0);
    try expectStdout("no occurrence", r, "0 " ++ D ++ "\n");
    try c.same("no occurrence", "f", f);
    try std.testing.expectEqual(ino, try c.inode("f"));
}

// 9. The second directory refused after the first had rewritable occurrences:
// exit 1 naming the second's offset, nothing printed, the file untouched.
test "second directory refused: exit 1 naming its offset, nothing printed, untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = D ++ "/ok\x00" ++ D2 ++ "x\x00";
    try c.put("f", f);
    const r = try c.run(&.{ "f", D, D2 });
    try refused("second directory refused", r, D2 ++ " at offset 39 is followed by byte 0x78");
    try c.same("second directory refused (must be untouched)", "f", f);
}

// 10. A symbolic link is refused: replacing it through a rename would turn the
// link into a regular file and leave its target as it was.
test "symbolic link: exit 1, the link still a link, its target untouched" {
    var c = Case.init();
    defer c.deinit();
    try c.put("target", data);
    try c.tmp.dir.symLink("target", "link", .{});
    const r = try c.run(&.{ "link", D });
    try expectStatus("symbolic link", r, 1);
    try has("symbolic link", r.err, "is a symbolic link");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = c.tmp.dir.readLink("link", &buf) catch |e| {
        std.debug.print("symbolic link: the link was replaced ({s})\n", .{@errorName(e)});
        return error.TestUnexpectedResult;
    };
    try c.same("symbolic link's target (must be untouched)", "target", data);
}

// The next cases make a write fail with EFBIG: a file size limit with
// SIGXFSZ ignored. The probe checks the limit stops a plain write first.
test "probe: the size limit stops a plain write of the 72 KiB file" {
    var c = Case.init();
    defer c.deinit();
    const b = big(c.alloc());
    try std.testing.expectEqual(@as(usize, 73728), b.len);
    const lim = try SizeLimit.set();
    defer lim.restore();
    var f = try c.tmp.dir.createFile("probe", .{});
    defer f.close();
    if (f.writeAll(b)) {
        std.debug.print("probe: the size limit did not stop the write\n", .{});
        return error.TestUnexpectedResult;
    } else |e| if (e != error.FileTooBig) return e;
    try std.testing.expect((try f.getEndPos()) < b.len);
}

// 11. A write that fails part way leaves the file untouched and no temporary
// file behind (exit 1).
test "failed write: exit 1, the file untouched, no temporary file left" {
    var c = Case.init();
    defer c.deinit();
    const b = big(c.alloc());
    try c.tmp.dir.makeDir("leak");
    try c.put("leak/f", b);
    const r = blk: {
        const lim = try SizeLimit.set();
        defer lim.restore();
        break :blk try c.run(&.{ "leak/f", D });
    };
    try expectStatus("failed write", r, 1);
    try has("failed write", r.err, "write: FileTooBig; the file is unchanged");
    try c.same("failed write (must be untouched)", "leak/f", b);
    var dir = try c.tmp.dir.openDir("leak", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (!std.mem.eql(u8, e.name, "f")) {
            std.debug.print("failed write: the directory holds '{s}', want only 'f' (a temporary file was left)\n", .{e.name});
            return error.TestUnexpectedResult;
        }
    }
}

const FullStdout = std.io.GenericWriter(void, error{FileTooBig}, fullWrite);
fn fullWrite(_: void, _: []const u8) error{FileTooBig}!usize {
    return error.FileTooBig;
}

// 12. Exit 1 means the file is unchanged: a failed write of the counts (the
// shell's stdout over the size limit; here a stdout whose every write fails
// with FileTooBig) leaves it as it was.
test "failed stdout: exit 1 and the file unchanged" {
    var c = Case.init();
    defer c.deinit();
    try c.put("f", data);
    var err = std.ArrayList(u8).empty;
    const st = R.entry(c.alloc(), c.tmp.dir, &.{ "f", D }, FullStdout{ .context = {} }, err.writer(c.alloc()));
    if (st != 1) {
        std.debug.print("failed stdout: exit {d}, want 1; stderr:\n{s}\n", .{ st, err.items });
        return error.TestUnexpectedResult;
    }
    try has("failed stdout", err.items, "stdout: FileTooBig; f is unchanged");
    try c.same("failed stdout (must be untouched)", "f", data);
}

// 13. An ELF file with a section whose flags hold SHF_COMPRESSED (0x800) is
// refused (exit 1) and left untouched, although D followed by NUL is in it:
// a compressed section's bytes are not the strings they hold, so a byte search
// can miss the directory there, and a count would claim a clean file.
test "compressed section: exit 1 naming section 2, nothing printed, untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = elf64(c.alloc(), 0x800, null, false);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try refused("compressed section", r, "section 2 is compressed (SHF_COMPRESSED");
    try c.same("compressed section (must be untouched)", "f", f);
}

// 14. The same ELF file with that flag clear (0x2, SHF_ALLOC, beside it) is
// relocated as any file is: the refusal is the flag's, not the format's.
// 15. Relocating is idempotent: the relocated file again, with the same
// directory, is 0 rewrites, exit 0, the same bytes and the same inode (not
// written). The placeholder never holds the directory it replaced.
test "uncompressed ELF relocated; again: idempotent, the same bytes and inode" {
    var c = Case.init();
    defer c.deinit();
    const f = elf64(c.alloc(), 0x2, null, false);
    try std.testing.expectEqual(@as(usize, 64 + 23 + D.len + 1 + 3 * 64), f.len);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try expectStatus("uncompressed ELF", r, 0);
    try expectStdout("uncompressed ELF", r, "1 " ++ D ++ "\n");
    const got = try c.read("f");
    try has("uncompressed ELF: the file", got, P);
    if (std.mem.indexOf(u8, got, D) != null) {
        std.debug.print("uncompressed ELF: the directory is still in the file\n", .{});
        return error.TestUnexpectedResult;
    }

    const ino = try c.inode("f");
    const r2 = try c.run(&.{ "f", D });
    try expectStatus("idempotent", r2, 0);
    try expectStdout("idempotent", r2, "0 " ++ D ++ "\n");
    try c.same("idempotent", "f", got);
    try std.testing.expectEqual(ino, try c.inode("f"));
}

// 16. An ELF file whose section headers lie past its end cannot be shown free
// of compressed sections: refused (exit 1), untouched.
test "section headers past the end: exit 1, untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = elf64(c.alloc(), 0x2, 4096, false);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try expectStatus("section headers past the end", r, 1);
    try has("section headers past the end", r.err, "section headers");
    try c.same("section headers past the end (must be untouched)", "f", f);
}

// 17. More than 0xff00 sections: e_shnum is 0 and section 0's sh_size holds
// the count (3). The compressed section is found through that count.
test "compressed section, e_shnum 0: refused through section 0's count; 0x2 relocated" {
    var c = Case.init();
    defer c.deinit();
    const f = elf64(c.alloc(), 0x800, null, true);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try expectStatus("compressed section, e_shnum 0", r, 1);
    try has("compressed section, e_shnum 0", r.err, "section 2 is compressed (SHF_COMPRESSED");
    try c.same("compressed section, e_shnum 0 (must be untouched)", "f", f);
    try c.put("f", elf64(c.alloc(), 0x2, null, true));
    try expectStatus("uncompressed, e_shnum 0", try c.run(&.{ "f", D }), 0);
}

// 18. An ELF32 file (40-byte section headers, 32-bit sh_flags) with a
// compressed section: refused the same way, untouched.
test "compressed section, ELF32: refused, untouched; 0x2 relocated" {
    var c = Case.init();
    defer c.deinit();
    const f = elf32(c.alloc(), 0x800, false);
    try std.testing.expectEqual(@as(usize, 52 + 23 + D.len + 1 + 3 * 40), f.len);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try expectStatus("compressed section, ELF32", r, 1);
    try has("compressed section, ELF32", r.err, "section 2 is compressed (SHF_COMPRESSED");
    try c.same("compressed section, ELF32 (must be untouched)", "f", f);
    try c.put("f", elf32(c.alloc(), 0x2, false));
    const r2 = try c.run(&.{ "f", D });
    try expectStatus("uncompressed, ELF32", r2, 0);
    try expectStdout("uncompressed, ELF32", r2, "1 " ++ D ++ "\n");
}

// 19. An ELF32 file with e_shnum 0: section 0's 32-bit sh_size (offset 0x14
// of its header) holds the count (3), and the compressed section is found
// through it, as case 17 for ELF64.
test "compressed section, ELF32, e_shnum 0: refused through section 0's count; 0x2 relocated" {
    var c = Case.init();
    defer c.deinit();
    const f = elf32(c.alloc(), 0x800, true);
    try std.testing.expectEqual(@as(usize, 52 + 23 + D.len + 1 + 3 * 40), f.len);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try expectStatus("compressed section, ELF32, e_shnum 0", r, 1);
    try has("compressed section, ELF32, e_shnum 0", r.err, "section 2 is compressed (SHF_COMPRESSED");
    try c.same("compressed section, ELF32, e_shnum 0 (must be untouched)", "f", f);
    try c.put("f", elf32(c.alloc(), 0x2, true));
    const r2 = try c.run(&.{ "f", D });
    try expectStatus("uncompressed, ELF32, e_shnum 0", r2, 0);
    try expectStdout("uncompressed, ELF32, e_shnum 0", r2, "1 " ++ D ++ "\n");
}

// 20. e_shnum 0 and section 0's sh_size claiming 4 section headers where the
// file holds 3: the table starts inside the file, so only the count check
// finds it runs past the end. Refused (exit 1), untouched.
test "e_shnum 0, a count past the end: exit 1, untouched" {
    var c = Case.init();
    defer c.deinit();
    const f = try c.alloc().dupe(u8, elf64(c.alloc(), 0x2, null, true));
    const shoff = 64 + strtab.len + data.len;
    try std.testing.expectEqual(@as(usize, shoff + 3 * 64), f.len);
    std.mem.writeInt(u64, f[shoff + 0x20 ..][0..8], 4, .little);
    try c.put("f", f);
    const r = try c.run(&.{ "f", D });
    try refused("e_shnum 0, a count past the end", r, "section headers past the end of the file");
    try c.same("e_shnum 0, a count past the end (must be untouched)", "f", f);
}
