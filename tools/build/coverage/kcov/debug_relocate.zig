//! debug_relocate: overwrite a directory path inside a file with a
//! placeholder of the same length.
//!
//! usage: debug_relocate <file> <dir>...
//!
//! For each <dir> in order (absolute, no trailing '/', at least 8 bytes long),
//! every occurrence of its bytes in <file> that is followed by '/' or NUL
//! becomes '/' followed by '_' repeated to the same length, so
//! "/worker/build/0123456789abcdef/root" (35 bytes) becomes "/" and 34 '_'.
//! Occurrences are found left to right and do not overlap; the byte before
//! one is not looked at. The file never changes length, so no offset in it
//! moves.
//!
//! An occurrence followed by any other byte, or by the end of the file, is
//! refused: it is a longer name that only starts with <dir>
//! ("/root2"), and rewriting it would make a path that names nothing it named
//! before. The file is then left untouched.
//!
//! The placeholder is a path that does not exist on any machine this runs
//! on, which is the point: a tool that resolves the path with realpath before
//! rewriting it (kcov does) leaves it as written, and a regular expression
//! (`^/_+`) then finds it. See README.md.
//!
//! The file is rewritten through a temporary file in its directory, renamed
//! over it, with the original permission bits; the temporary file is removed
//! if a step fails. A symbolic link is refused (the rename would replace the
//! link, not the file it names). A file with no occurrence of any <dir> is not
//! written at all.
//!
//! An ELF file with a section whose flags hold SHF_COMPRESSED is refused,
//! and so is one whose section headers cannot be read (not little-endian, or
//! past the end of the file): a compressed section's bytes are not the
//! strings it holds, so a byte search could miss <dir> there and the counts
//! would claim a clean file. Any other file is searched as bytes.
//!
//! Prints one line per <dir>, `<count> <dir>`, before the file is written.
//!
//! Exit status: 0 done; 1 an occurrence followed by another byte, a
//! compressed or unreadable ELF file, a symbolic link, or an I/O error,
//! stdout included (the file is unchanged in every case); 2 bad usage.
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");

const usage =
    \\usage: debug_relocate <file> <dir>...
    \\  each <dir> absolute, without a trailing '/', at least 8 bytes long
    \\
;

const min_dir_len = 8;
const max_file = 1 << 34;

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("debug_relocate: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("debug_relocate: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const shf_compressed: u64 = 0x800;

fn le(comptime T: type, buf: []const u8, at: u64) T {
    const n = @divExact(@typeInfo(T).Int.bits, 8);
    return std.mem.readInt(T, buf[@intCast(at)..][0..n], .little);
}

/// Refuses (exit 1, nothing written) an ELF file holding a section whose
/// flags have SHF_COMPRESSED, or whose section headers cannot be read. A
/// file that does not start with the ELF magic is not looked at.
fn refuseCompressed(path: []const u8, buf: []const u8) void {
    if (buf.len < 4 or !std.mem.eql(u8, buf[0..4], "\x7fELF")) return;
    const unread = "{s}: an ELF file whose section headers cannot be read ({s}), so no section can be shown uncompressed; the file is left unchanged";
    if (buf.len < 52) fail(unread, .{ path, "shorter than an ELF header" });
    if (buf[5] != 1) fail(unread, .{ path, "not little-endian" });
    // (offset of e_shoff, e_shentsize, e_shnum), and of sh_flags and sh_size
    // in a section header, by class: ELF64 or ELF32.
    const wide = switch (buf[4]) {
        2 => true,
        1 => false,
        else => fail(unread, .{ path, "neither ELF32 nor ELF64" }),
    };
    if (wide and buf.len < 64) fail(unread, .{ path, "shorter than an ELF64 header" });
    const shoff: u64 = if (wide) le(u64, buf, 0x28) else le(u32, buf, 0x20);
    const entsize: u64 = le(u16, buf, if (wide) 0x3a else 0x2e);
    var shnum: u64 = le(u16, buf, if (wide) 0x3c else 0x30);
    if (shoff == 0) return; // no section header table, so no section
    const min_entsize: u64 = if (wide) 64 else 40;
    if (entsize < min_entsize) fail(unread, .{ path, "section headers shorter than the format's" });
    if (shoff > buf.len or buf.len - shoff < entsize) fail(unread, .{ path, "section headers past the end of the file" });
    // More than 0xff00 sections: e_shnum is 0 and section 0's sh_size holds the count.
    if (shnum == 0) shnum = if (wide) le(u64, buf, shoff + 0x20) else le(u32, buf, shoff + 0x14);
    if (shnum > (buf.len - shoff) / entsize) fail(unread, .{ path, "section headers past the end of the file" });
    var i: u64 = 0;
    while (i < shnum) : (i += 1) {
        const at = shoff + i * entsize + 8;
        const flags: u64 = if (wide) le(u64, buf, at) else le(u32, buf, at);
        if (flags & shf_compressed != 0) {
            fail("{s}: section {d} is compressed (SHF_COMPRESSED, flags 0x{x}): its bytes are not the strings it holds, so a directory in it cannot be found; the file is left unchanged", .{ path, i, flags });
        }
    }
}

/// Rewrites every occurrence of `dir` in `buf` followed by '/' or NUL, in
/// place, and returns how many there were. Refuses (exit 1) before writing
/// anything when one occurrence is followed by anything else.
fn relocate(path: []const u8, buf: []u8, dir: []const u8) usize {
    var count: usize = 0;
    var at: usize = 0;
    // First pass: find and check every occurrence; nothing is written yet.
    while (std.mem.indexOfPos(u8, buf, at, dir)) |i| {
        const next = i + dir.len;
        if (next >= buf.len) {
            fail("{s}: {s} at offset {d} ends the file; it is not followed by '/' or NUL, so the file is left unchanged", .{ path, dir, i });
        }
        const b = buf[next];
        if (b != '/' and b != 0) {
            fail("{s}: {s} at offset {d} is followed by byte 0x{x:0>2}, not '/' or NUL, so the file is left unchanged", .{ path, dir, i, b });
        }
        count += 1;
        at = next;
    }
    // Second pass: the same occurrences, rewritten.
    at = 0;
    while (std.mem.indexOfPos(u8, buf, at, dir)) |i| {
        buf[i] = '/';
        @memset(buf[i + 1 .. i + dir.len], '_');
        at = i + dir.len;
    }
    return count;
}

/// Replaces the file at `path` with `buf` through a temporary file in its
/// directory, renamed over it, with permission bits `mode` set exactly. It
/// returns its errors rather than exiting, so the deferred `deinit` removes
/// the temporary file when a step fails; `step` names the step.
fn replace(dir: std.fs.Dir, path: []const u8, buf: []const u8, mode: std.fs.File.Mode, step: *[]const u8) !void {
    step.* = "temporary file";
    var af = try dir.atomicFile(path, .{ .mode = mode });
    defer af.deinit();
    step.* = "write";
    try af.file.writeAll(buf);
    // The creation mode passed the umask; set the bits exactly.
    step.* = "chmod";
    try af.file.chmod(mode);
    step.* = "rename";
    try af.finish();
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});
    if (argv.len < 3) usageFail("expected a file and at least one directory", .{});
    const path = argv[1];
    const dirs = argv[2..];
    for (dirs) |d| {
        if (d.len < min_dir_len) usageFail("directory '{s}' is {d} bytes long, under {d}", .{ d, d.len, min_dir_len });
        if (d[0] != '/') usageFail("directory '{s}' is not absolute", .{d});
        if (d[d.len - 1] == '/') usageFail("directory '{s}' ends with '/'", .{d});
    }

    const cwd = std.fs.cwd();
    // A symbolic link is refused: the rename would replace the link with a
    // regular file and leave its target as it was.
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    if (cwd.readLink(path, &link_buf)) |_| {
        fail("{s} is a symbolic link; give the file it names", .{path});
    } else |err| switch (err) {
        error.NotLink => {},
        else => fail("{s}: {s}", .{ path, @errorName(err) }),
    }
    const st = cwd.statFile(path) catch |err| fail("{s}: {s}", .{ path, @errorName(err) });
    const buf = cwd.readFileAlloc(alloc, path, max_file) catch |err| fail("{s}: {s}", .{ path, @errorName(err) });
    const before = buf.len;
    refuseCompressed(path, buf);

    var counts = alloc.alloc(usize, dirs.len) catch fail("out of memory", .{});
    var total: usize = 0;
    for (dirs, 0..) |d, k| {
        counts[k] = relocate(path, buf, d);
        total += counts[k];
    }
    std.debug.assert(buf.len == before);

    // The counts go out before the file is replaced, so a failed write of
    // them (exit 1) leaves the file unchanged too.
    const out = std.io.getStdOut().writer();
    for (dirs, 0..) |d, k| {
        out.print("{d} {s}\n", .{ counts[k], d }) catch |err| fail("stdout: {s}; {s} is unchanged", .{ @errorName(err), path });
    }

    if (total > 0) {
        var step: []const u8 = "";
        replace(cwd, path, buf, st.mode & 0o7777, &step) catch |err| fail("{s}: {s}: {s}; the file is unchanged", .{ path, step, @errorName(err) });
    }
}
