//! cov_zig: the `zig` of the coverage build's link directory.
//!
//! usage: <dir>/zig <zig arguments...>
//!
//! mojo_wrapper.sh runs every link of `mojo build` as
//! `<zig_dir>/zig cc -target <t> -Wl,--strip-debug ... <compiler arguments>`.
//! A coverage build (tools/build/mojo/README.md, "Coverage builds") passes a
//! directory holding this program as <zig_dir>, so the wrapper itself is the
//! one every build runs, byte for byte. <dir> is the directory argv[0] names
//! (the wrapper gives an absolute path); it holds:
//!
//!   zig              this program
//!   real/zig         the pinned zig distribution
//!   debug_relocate   README.md, "debug_relocate"
//!
//! A `cc` or `c++` that links (it names an output with `-o`, and none of
//! -c, -S, -E, -M, -MM, -fsyntax-only) is refused (exit 1, before real/zig
//! runs) when it has a release optimization level (-O1 to -O4, -Ofast, -Os,
//! -Oz): zig 0.12 then gives lld -O2 or -O3, which merges string tails in
//! .debug_str, and a string that is the tail of a relocated directory would
//! be rewritten with it. Otherwise it is changed in four ways:
//!
//!   - every `-Wl,--strip-debug` is dropped, so the line tables the compiler
//!     wrote reach the binary;
//!   - `-Wl,--build-id=none -Wl,--compress-debug-sections=none` is appended:
//!     no note that would differ with the bytes of an unrelated input, and
//!     no compressed debug section, whose bytes a search for the sandbox path
//!     cannot see (not `-Wl,-O1`: zig 0.12 ignores a linker optimization
//!     level and warns that it did);
//!   - after real/zig links successfully, `debug_relocate <output> <dir>...`
//!     overwrites the action's directories in the output (see below);
//!   - the link fails (exit 1) when debug_relocate refuses, or when the output
//!     has a debug section (.debug_info or .debug_line) and debug_relocate
//!     found the working directory, in either spelling, 0 times.
//!
//! What records a directory: the pinned Mojo writes no compilation directory
//! and names its sources by relative paths (`tests`, `buck-out/...`,
//! `oss/modular/...`), so its units hold no directory of the action. Zig's C
//! runtime objects (crt1, crti, crtn) record the working directory as
//! DW_AT_comp_dir; those are what the relocation rewrites in a Mojo binary,
//! and why a debug link that holds the working directory nowhere fails: the
//! runtime then recorded a directory this program did not pass (the binary
//! would differ by machine), or it lost its debug info.
//!
//! The directories, in order: the working directory (getcwd), then $PWD when
//! it is another absolute path to it (a path through a symbolic link, which
//! LLVM records when it names the same directory), then $BUCK_SCRATCH_PATH
//! when it is absolute and outside the working directory (zig's cache, where
//! it builds its C runtime objects, lives there). The zero count above sums
//! the two spellings of the working directory. A $PWD or $BUCK_SCRATCH_PATH
//! that is not absolute, is under 8 bytes, or is the working directory or
//! under it is not passed (without an error); a working directory under 8
//! bytes is debug_relocate's usage error, so the link fails.
//!
//! Anything else runs real/zig with the same arguments (exec).
//!
//! Exit status: real/zig's (128 + N when signal N killed it); 1 a refused or
//! unreadable output; 2 bad usage (argv[0] names no directory, real/zig
//! cannot be run).
//!
//! A static executable: it runs with no shell, no PATH and no network.

const std = @import("std");

const max_file = 1 << 34;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_zig: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cov_zig: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// The output of a `cc` that links, or null when the command does not link.
fn linkOutput(args: []const []const u8) ?[]const u8 {
    if (args.len < 1) return null;
    if (!std.mem.eql(u8, args[0], "cc") and !std.mem.eql(u8, args[0], "c++")) return null;
    const no_link = [_][]const u8{ "-c", "-S", "-E", "-M", "-MM", "-fsyntax-only" };
    var out: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        for (no_link) |n| {
            if (std.mem.eql(u8, a, n)) return null;
        }
        if (std.mem.eql(u8, a, "-o")) {
            if (i + 1 < args.len) out = args[i + 1];
            i += 1;
        } else if (a.len > 2 and std.mem.startsWith(u8, a, "-o")) {
            out = a[2..];
        }
    }
    return out;
}

fn le(comptime T: type, buf: []const u8, at: u64) T {
    const n = @divExact(@typeInfo(T).Int.bits, 8);
    return std.mem.readInt(T, buf[@intCast(at)..][0..n], .little);
}

/// Whether the ELF64 little-endian file in `buf` has a section named
/// .debug_info or .debug_line. Refuses (exit 1) any other file, or one whose
/// section headers or names lie outside it.
fn hasDebugSection(path: []const u8, buf: []const u8) bool {
    const bad = "{s}: the link output is not an ELF64 little-endian file whose section headers can be read ({s})";
    if (buf.len < 64 or !std.mem.eql(u8, buf[0..4], "\x7fELF")) fail(bad, .{ path, "no ELF header" });
    if (buf[4] != 2 or buf[5] != 1) fail(bad, .{ path, "not ELF64 little-endian" });
    const shoff = le(u64, buf, 0x28);
    if (shoff == 0) return false;
    const entsize: u64 = le(u16, buf, 0x3a);
    var shnum: u64 = le(u16, buf, 0x3c);
    var strndx: u64 = le(u16, buf, 0x3e);
    if (entsize < 64) fail(bad, .{ path, "section headers shorter than 64 bytes" });
    if (shoff > buf.len or buf.len - shoff < entsize) fail(bad, .{ path, "section headers past the end" });
    // Past 0xff00 sections the count and the name table's index are in
    // section 0 (sh_size, sh_link).
    if (shnum == 0) shnum = le(u64, buf, shoff + 0x20);
    if (strndx == 0xffff) strndx = le(u32, buf, shoff + 0x28);
    if (shnum > (buf.len - shoff) / entsize) fail(bad, .{ path, "section headers past the end" });
    if (strndx >= shnum) fail(bad, .{ path, "no section name table" });
    const names_hdr = shoff + strndx * entsize;
    const names_off = le(u64, buf, names_hdr + 0x18);
    const names_size = le(u64, buf, names_hdr + 0x20);
    if (names_off > buf.len or buf.len - names_off < names_size) fail(bad, .{ path, "section names past the end" });
    const names = buf[@intCast(names_off)..][0..@intCast(names_size)];
    var i: u64 = 0;
    while (i < shnum) : (i += 1) {
        const at: u64 = le(u32, buf, shoff + i * entsize);
        if (at >= names.len) fail(bad, .{ path, "a section name past its table" });
        const end = std.mem.indexOfScalarPos(u8, names, @intCast(at), 0) orelse fail(bad, .{ path, "a section name with no NUL" });
        const name = names[@intCast(at)..end];
        if (std.mem.eql(u8, name, ".debug_info") or std.mem.eql(u8, name, ".debug_line")) return true;
    }
    return false;
}

/// Whether `a` is a `zig cc` optimization level that zig 0.12 takes for a
/// release mode (main.zig): -O1 to -O4, -Ofast, -Os, -Oz. -O0 and -Og are
/// Debug, and a bare -O is passed to clang without changing the mode.
fn isReleaseLevel(a: []const u8) bool {
    for ([_][]const u8{ "-O1", "-O2", "-O3", "-O4", "-Ofast", "-Os", "-Oz" }) |l| {
        if (std.mem.eql(u8, a, l)) return true;
    }
    return false;
}

/// Exits like a child that ended with `term`, when it did not succeed.
fn passOn(term: std.ChildProcess.Term) void {
    switch (term) {
        .Exited => |c| if (c != 0) std.process.exit(c),
        .Signal => |s| std.process.exit(@intCast(128 + (s & 0x7f))),
        else => std.process.exit(1),
    }
}

/// `d` without trailing '/' when it can be given to debug_relocate as one
/// more directory (absolute, at least 8 bytes, not `cwd` and not under it),
/// else null.
fn extraDir(d: []const u8, cwd: []const u8) ?[]const u8 {
    const t = std.mem.trimRight(u8, d, "/");
    if (t.len < 8 or t[0] != '/') return null;
    if (std.mem.eql(u8, t, cwd)) return null;
    if (t.len > cwd.len and std.mem.startsWith(u8, t, cwd) and t[cwd.len] == '/') return null;
    return t;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});
    const dir = std.fs.path.dirname(argv[0]) orelse usageFail("argv[0] '{s}' names no directory; run this program by its path", .{argv[0]});
    const real = std.fs.path.join(alloc, &.{ dir, "real", "zig" }) catch fail("out of memory", .{});
    const relocate = std.fs.path.join(alloc, &.{ dir, "debug_relocate" }) catch fail("out of memory", .{});
    const args = argv[1..];

    const out = linkOutput(args) orelse {
        var same = std.ArrayList([]const u8).init(alloc);
        same.append(real) catch fail("out of memory", .{});
        same.appendSlice(args) catch fail("out of memory", .{});
        const err = std.process.execv(alloc, same.items);
        usageFail("cannot run {s}: {s}", .{ real, @errorName(err) });
    };

    var link = std.ArrayList([]const u8).init(alloc);
    link.append(real) catch fail("out of memory", .{});
    for (args) |a| {
        // At these levels zig 0.12 is in a release mode and gives lld -O2 or
        // -O3, which merges string tails in .debug_str: a string that is the
        // tail of the working directory would be overwritten with it.
        if (isReleaseLevel(a)) {
            fail("a link with the optimization level {s} is refused: zig would have lld merge string tails, and debug_relocate cannot see a string that is the tail of a directory it rewrites", .{a});
        }
        if (std.mem.eql(u8, a, "-Wl,--strip-debug")) continue;
        link.append(a) catch fail("out of memory", .{});
    }
    link.appendSlice(&.{ "-Wl,--build-id=none", "-Wl,--compress-debug-sections=none" }) catch fail("out of memory", .{});
    var child = std.ChildProcess.init(link.items, alloc);
    const term = child.spawnAndWait() catch |err| usageFail("cannot run {s}: {s}", .{ real, @errorName(err) });
    passOn(term);

    const cwd = std.process.getCwdAlloc(alloc) catch |err| fail("getcwd: {s}", .{@errorName(err)});
    var rel_argv = std.ArrayList([]const u8).init(alloc);
    rel_argv.appendSlice(&.{ relocate, out, cwd }) catch fail("out of memory", .{});
    // The spellings of the working directory: getcwd, and $PWD when it is
    // another path to it.
    var wd_dirs = std.ArrayList([]const u8).init(alloc);
    wd_dirs.append(cwd) catch fail("out of memory", .{});
    for ([_][]const u8{ "PWD", "BUCK_SCRATCH_PATH" }) |name| {
        const v = std.process.getEnvVarOwned(alloc, name) catch continue;
        if (extraDir(v, cwd)) |d| {
            var seen = false;
            for (rel_argv.items[2..]) |e| seen = seen or std.mem.eql(u8, e, d);
            if (!seen) rel_argv.append(d) catch fail("out of memory", .{});
            if (!seen and std.mem.eql(u8, name, "PWD")) wd_dirs.append(d) catch fail("out of memory", .{});
        }
    }

    const bytes = std.fs.cwd().readFileAlloc(alloc, out, max_file) catch |err| fail("{s}: {s}", .{ out, @errorName(err) });
    const debug = hasDebugSection(out, bytes);
    alloc.free(bytes);

    const r = std.ChildProcess.run(.{ .allocator = alloc, .argv = rel_argv.items, .max_output_bytes = 1 << 16 }) catch |err| fail("cannot run {s}: {s}", .{ relocate, @errorName(err) });
    switch (r.term) {
        .Exited => |c| if (c != 0) fail("debug_relocate refused {s} (exit {d}), so the link fails:\n{s}", .{ out, c, r.stderr }),
        else => fail("debug_relocate did not exit ({s}), so the link fails:\n{s}", .{ @tagName(r.term), r.stderr }),
    }
    // It prints `<count> <dir>` per directory, in the order given.
    var count: u64 = 0;
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, r.stdout, "\n"), '\n');
    for (rel_argv.items[2..]) |d| {
        const line = lines.next() orelse fail("debug_relocate printed no count of {s}", .{d});
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse fail("debug_relocate printed '{s}', not '<count> <dir>'", .{line});
        if (!std.mem.eql(u8, line[sp + 1 ..], d)) fail("debug_relocate printed '{s}', not the count of {s}", .{ line, d });
        const n = std.fmt.parseUnsigned(u64, line[0..sp], 10) catch fail("debug_relocate printed '{s}', not '<count> <dir>'", .{line});
        for (wd_dirs.items) |w| {
            if (std.mem.eql(u8, w, d)) count += n;
        }
    }
    if (debug and count == 0) {
        fail("{s} has debug sections but holds the working directory ({s}, or $PWD) nowhere. Only zig's C runtime records a compilation directory (the pinned Mojo writes relative paths and none), so either the runtime's DWARF names a directory debug_relocate was not given (the binary would differ by machine) or the runtime has no debug info; the link fails", .{ out, cwd });
    }
}
