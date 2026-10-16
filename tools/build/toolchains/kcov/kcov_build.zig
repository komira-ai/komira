// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// kcov_build.sh (a busybox shell script: tar, ar, sed, od, find, cp), so that
// building kcov runs no shell.
//! kcov_build: builds kcov from its pinned source archive with the pinned zig,
//! as one build action of the `kcov_dist` rule (defs.bzl).
//!
//! usage: kcov_build <zig_dir> <conda_payload> <elf_rpath> <kcov.tar.gz>
//!            <strip_prefix> <version> <zig_triple> <shim_dir> <out_dir>
//!            <name>=<package.conda>...
//!
//! The conda packages are elfutils, zlib, bzip2, zstd and lzma (static
//! archives) and libgcc (libgcc_s.so.1). kcov is the Linux source list of
//! kcov's src/CMakeLists.txt with dummy-coveralls-writer.cc and
//! dummy-disassembler.cc (what its KCOV_STATIC_BUILD and no-libbfd branches
//! choose): no libcurl, no libbfd; shim/ defines the three curl functions
//! utils.cc calls.
//!
//! Every library is linked statically (libdw.a, libelf.a, libz.a, liblzma.a,
//! libbz2.a, libzstd.a, zig's libc++) except the unwinder: <out_dir>/bin/kcov
//! needs glibc and <out_dir>/lib/libgcc_s.so.1 only. <out_dir>/share/licenses
//! holds the licence files. README.md ("The unwinder") says why kcov links
//! libgcc_s.so.1 itself, as an input ahead of zig's own libraries, and finds it
//! through a DT_RPATH $ORIGIN/../lib, which elf_rpath makes of the DT_RUNPATH
//! zig 0.12 always writes.
//!
//! Exit status: 0; 2 on a missing input, a patch that does not apply, or a
//! usage error; the compiler's own status when a compile fails.

const std = @import("std");
const A = std.mem.Allocator;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("kcov_build: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or (c >= 10 and c <= 13);
}

// ---- patches --------------------------------------------------------------

pub const marker = "KOMIRA PATCH";

/// The lines of `text`, each with its newline (the last without one when the
/// text has none).
pub fn splitKeep(a: A, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    var i: usize = 0;
    while (i < text.len) {
        const e = if (std.mem.indexOfScalarPos(u8, text, i, '\n')) |n| n + 1 else text.len;
        try out.append(text[i..e]);
        i = e;
    }
    return out.toOwnedSlice();
}

fn body(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, line, "\n");
}

fn leadingBlank(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and isBlank(s[n])) n += 1;
    return n;
}

/// `line` is `[[:space:]]*<rest>` exactly (no more).
fn spaceThen(line: []const u8, rest: []const u8) bool {
    const b = body(line);
    const n = leadingBlank(b);
    return std.mem.eql(u8, b[n..], rest);
}

/// Matches `pattern` against `s` where '.' in the pattern is any one byte.
fn matchDots(pattern: []const u8, s: []const u8) bool {
    if (pattern.len != s.len) return false;
    for (pattern, s) |p, c| {
        if (p != '.' and p != c) return false;
    }
    return true;
}

/// Replaces the first `old` of `line` by `new`.
fn replaceFirst(a: A, line: []const u8, old: []const u8, new: []const u8) !?[]u8 {
    const at = std.mem.indexOf(u8, line, old) orelse return null;
    return try std.mem.concat(a, u8, &.{ line[0..at], new, line[at + old.len ..] });
}

pub const Patch = enum {
    /// engines/ptrace_linux.cc: no CPU pin (kcov pinned itself and the test to
    /// the CPU it started on, so every traced test ran on one CPU where the
    /// release gate gives it all of the worker's).
    no_cpu_pin,
    /// collector.cc: the exit status is not that of the last process to exit.
    not_other_exit,
    /// collector.cc: a signal death is reported as a shell does, 128 + signal.
    signal_exit,
    /// engines/ptrace.cc: only the test's exit ends the run.
    first_child,

    pub fn expected(self: Patch) usize {
        _ = self;
        return 1;
    }
};

/// The text of a source file after `patch`.
pub fn applyPatch(a: A, patch: Patch, text: []const u8) ![]u8 {
    const ls = try splitKeep(a, text);
    var out = std.ArrayList(u8).init(a);
    var in_range = false;
    var skip_next_subst = false;
    for (ls) |line| {
        var cur: []const u8 = line;
        switch (patch) {
            .no_cpu_pin => {
                const b = body(line);
                const n = leadingBlank(b);
                const stmt = "panic_if(sched_setaffinity(pid, CPU_ALLOC_SIZE(max_cpu), set) < 0, \"Can.t set CPU affinity. Coincident won.t work\");";
                if (matchDots(stmt, b[n..])) {
                    cur = try std.fmt.allocPrint(a, "{s}(void) pid; /* {s}: no CPU pin */{s}", .{ b[0..n], marker, line[b.len..] });
                }
            },
            .not_other_exit => {
                if (skip_next_subst) {
                    skip_next_subst = false;
                    if (try replaceFirst(a, line, "m_exitCode = ev.data;", "/* " ++ marker ++ ": not the status of another process */")) |r| cur = r;
                } else if (spaceThen(line, "case ev_exit:")) skip_next_subst = true;
            },
            .signal_exit => {
                if (!in_range and spaceThen(line, "case ev_signal_exit:")) {
                    in_range = true;
                    if (try replaceFirst(a, line, "m_exitCode = ev.data;", "m_exitCode = 128 + ev.data; /* " ++ marker ++ ": as a shell reports it */")) |r| cur = r;
                } else if (in_range) {
                    if (try replaceFirst(a, line, "m_exitCode = ev.data;", "m_exitCode = 128 + ev.data; /* " ++ marker ++ ": as a shell reports it */")) |r| cur = r;
                    if (spaceThen(line, "case ev_exit_first_process:")) in_range = false;
                }
            },
            .first_child => {
                const b = body(line);
                const n = leadingBlank(b);
                if (std.mem.eql(u8, b[n..], "if (!childrenLeft())"))
                    cur = try std.fmt.allocPrint(a, "{s}if (who == m_firstChild) /* {s}: the test, not another process */{s}", .{ b[0..n], marker, line[b.len..] });
            },
        }
        try out.appendSlice(cur);
    }
    return out.toOwnedSlice();
}

fn countMarked(text: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.indexOf(u8, l, marker) != null) n += 1;
    }
    return n;
}

// ---- generated sources ----------------------------------------------------

/// The text `bin-to-c-source.py` of kcov writes for the (file, name) pairs:
/// each file as a byte array, sixteen `0xhh,` to a line, and a GeneratedData.
pub fn bin2c(a: A, files: []const [2][]const u8, data: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.writeAll("#include <stdint.h>\n#include <stdlib.h>\n#include <generated-data-base.hh>\nusing namespace kcov;\n");
    for (files, data) |f, d| {
        const name = f[1];
        if (d.len == 0) fail("bin2c: {s} is missing or empty", .{f[0]});
        try w.print("const uint8_t {s}_data_raw[] = {{\n", .{name});
        var i: usize = 0;
        while (i < d.len) : (i += 16) {
            for (d[i..@min(i + 16, d.len)]) |b| try w.print("0x{x:0>2},", .{b});
            try w.writeByte('\n');
        }
        try w.print("}};\nGeneratedData {s}_data({s}_data_raw, sizeof({s}_data_raw));\n", .{ name, name, name });
    }
    return out.toOwnedSlice();
}

// ---- ar -------------------------------------------------------------------

pub const Member = struct { name: []const u8, data: []const u8 };

/// The members of a GNU or BSD `ar` archive (not its symbol table).
pub fn arMembers(a: A, d: []const u8) ![]Member {
    if (!std.mem.startsWith(u8, d, "!<arch>\n")) return error.NotAr;
    var out = std.ArrayList(Member).init(a);
    var long: []const u8 = "";
    var at: usize = 8;
    while (at + 60 <= d.len) {
        const h = d[at .. at + 60];
        if (!std.mem.eql(u8, h[58..60], "`\n")) return error.BadAr;
        const raw_name = std.mem.trimRight(u8, h[0..16], " ");
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, h[48..58], " "), 10) catch return error.BadAr;
        at += 60;
        if (at + size > d.len) return error.BadAr;
        var data = d[at .. at + size];
        at += size + (size & 1);
        if (std.mem.eql(u8, raw_name, "/") or std.mem.eql(u8, raw_name, "/SYM64/")) continue;
        if (std.mem.eql(u8, raw_name, "//")) {
            long = data;
            continue;
        }
        var name: []const u8 = raw_name;
        if (raw_name.len > 1 and raw_name[0] == '/' and raw_name[1] >= '0' and raw_name[1] <= '9') {
            const off = std.fmt.parseInt(usize, raw_name[1..], 10) catch return error.BadAr;
            if (off >= long.len) return error.BadAr;
            const end = std.mem.indexOfScalarPos(u8, long, off, '/') orelse long.len;
            name = long[off..end];
        } else if (std.mem.startsWith(u8, raw_name, "#1/")) {
            const n = std.fmt.parseInt(usize, raw_name[3..], 10) catch return error.BadAr;
            if (n > data.len) return error.BadAr;
            name = std.mem.trimRight(u8, data[0..n], "\x00");
            data = data[n..];
        } else if (raw_name.len > 0 and raw_name[raw_name.len - 1] == '/') {
            name = raw_name[0 .. raw_name.len - 1];
        }
        try out.append(.{ .name = name, .data = data });
    }
    if (at != d.len) return error.BadAr;
    return out.toOwnedSlice();
}

// ---- files ----------------------------------------------------------------

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

fn readFile(a: A, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| fail("cannot read {s}: {s}", .{ path, @errorName(e) });
}

fn nonEmpty(path: []const u8) bool {
    const st = std.fs.cwd().statFile(path) catch return false;
    return st.size > 0;
}

fn contained(name: []const u8) bool {
    if (name.len == 0 or name[0] == '/') return false;
    var it = std.mem.splitScalar(u8, name, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

/// Extracts the tar read from `reader` into `dest`: directories, files (with
/// their executable bit) and symbolic links.
fn extractTar(dest: std.fs.Dir, reader: anytype) !void {
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        const name = std.mem.trimRight(u8, f.name, "/");
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        if (!contained(name)) return error.PathEscapes;
        switch (f.kind) {
            .directory => try dest.makePath(name),
            .file => {
                if (std.fs.path.dirname(name)) |d| try dest.makePath(d);
                const mode: std.fs.File.Mode = if (f.mode & 0o111 != 0) 0o755 else 0o644;
                const file = try dest.createFile(name, .{ .mode = mode });
                defer file.close();
                try f.writeAll(file);
                try file.chmod(mode);
            },
            .sym_link => {
                if (std.fs.path.dirname(name)) |d| try dest.makePath(d);
                dest.deleteFile(name) catch {};
                try dest.symLink(f.link_name, name, .{});
            },
        }
    }
}

fn absolute(a: A, p: []const u8) []u8 {
    if (std.fs.path.isAbsolute(p)) return a.dupe(u8, p) catch @panic("oom");
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch @panic("oom");
    return std.fs.path.join(a, &.{ cwd, p }) catch @panic("oom");
}

// ---- the build ------------------------------------------------------------

const Build = struct {
    a: A,
    zig: []const u8,
    env: std.process.EnvMap,

    fn run(self: *Build, argv: []const []const u8) void {
        var child = std.process.Child.init(argv, self.a);
        child.env_map = &self.env;
        const term = child.spawnAndWait() catch |e| fail("cannot run {s}: {s}", .{ argv[0], @errorName(e) });
        switch (term) {
            .Exited => |c| if (c != 0) {
                std.debug.print("kcov_build: {s} exited {d}\n", .{ argv[0], c });
                std.process.exit(if (c == 2) 1 else @intCast(c));
            },
            else => {
                std.debug.print("kcov_build: {s} did not exit\n", .{argv[0]});
                std.process.exit(1);
            },
        }
    }

    /// `zig <kind> <flags...> <rest...>`.
    fn zigRun(self: *Build, kind: []const u8, flags: []const []const u8, rest: []const []const u8) void {
        var argv = std.ArrayList([]const u8).init(self.a);
        argv.append(self.zig) catch @panic("oom");
        argv.append(kind) catch @panic("oom");
        argv.appendSlice(flags) catch @panic("oom");
        argv.appendSlice(rest) catch @panic("oom");
        self.run(argv.items);
    }
};

fn join(a: A, parts: []const []const u8) []u8 {
    return std.fs.path.join(a, parts) catch @panic("oom");
}

fn pf(a: A, comptime f: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(a, f, args) catch @panic("oom");
}

const licences_notice =
    \\This directory is kcov, built from the source archive of its tag with the
    \\changes komira's kcov_build makes (each changed line says KOMIRA PATCH:
    \\no CPU pin; the exit status is the traced program's). kcov is
    \\GPL-2.0 (kcov/COPYING); the files of its data/ that bin/kcov embeds are
    \\listed with their licences in kcov/COPYING.externals.
    \\
    \\bin/kcov also holds, linked statically (licences as their conda-forge
    \\packages declare them):
    \\  elfutils libdw and libelf    LGPL-3.0-only
    \\  zlib                         Zlib
    \\  bzip2                        bzip2-1.0.6
    \\  zstd                         BSD-3-Clause
    \\  liblzma (xz)                 0BSD
    \\  zig's libc++ and libc++abi   Apache-2.0 WITH LLVM-exception
    \\
    \\lib/libgcc_s.so.1 is GCC's runtime library from the conda-forge libgcc
    \\package: GPL-3.0-or-later WITH GCC-exception-3.1.
    \\
;

const srcs_list = [_][]const u8{
    "capabilities.cc",                 "collector.cc",                    "configuration.cc",             "engine-factory.cc",
    "engines/bash-engine.cc",          "engines/system-mode-engine.cc",   "engines/system-mode-file-format.cc", "engines/python-engine.cc",
    "filter.cc",                       "gcov.cc",                         "main.cc",                      "merge-file-parser.cc",
    "output-handler.cc",               "parsers/dummy-disassembler.cc",   "parser-manager.cc",            "reporter.cc",
    "source-file-cache.cc",            "utils.cc",                        "writers/cobertura-writer.cc",  "writers/codecov-writer.cc",
    "writers/json-writer.cc",          "writers/dummy-coveralls-writer.cc", "writers/html-writer.cc",     "writers/sonarqube-xml-writer.cc",
    "writers/writer-base.cc",          "engines/clang-coverage-engine.cc", "engines/ptrace.cc",           "engines/ptrace_linux.cc",
    "engines/kernel-engine.cc",        "parsers/elf.cc",                  "parsers/elf-parser.cc",        "parsers/dwarf.cc",
    "solib-handler.cc",                "system-mode/file-data.cc",
};

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 10) fail("usage: kcov_build <zig_dir> <conda_payload> <elf_rpath> <kcov.tar.gz> <strip_prefix> <version> <zig_triple> <shim_dir> <out_dir> <name>=<package.conda>...", .{});
    const zig = join(a, &.{ absolute(a, argv[1]), "zig" });
    const payload = absolute(a, argv[2]);
    const elf_rpath = absolute(a, argv[3]);
    const archive = absolute(a, argv[4]);
    const prefix = argv[5];
    const version = argv[6];
    const triple = argv[7];
    const shim = absolute(a, argv[8]);
    const out = absolute(a, argv[9]);
    const cwd = std.fs.cwd();

    // Private scratch (as in tools/build/mojo/toolchain.bzl).
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".kcov_build");
    const t = if (std.process.hasEnvVarConstant("BUCK_SCRATCH_PATH")) join(a, &.{ absolute(a, scratch_base), "kcov_build" }) else absolute(a, scratch_base);
    try cwd.deleteTree(t);
    try cwd.makePath(join(a, &.{ t, "home" }));
    var env = try std.process.getEnvMap(a);
    try env.put("LC_ALL", "C");
    try env.put("ZIG_GLOBAL_CACHE_DIR", join(a, &.{ t, "zig-global" }));
    try env.put("ZIG_LOCAL_CACHE_DIR", join(a, &.{ t, "zig-local" }));
    try env.put("HOME", join(a, &.{ t, "home" }));
    var b = Build{ .a = a, .zig = zig, .env = env };

    // The conda packages: <name>=<package.conda>, unpacked into $T/conda/<name>.
    const conda = join(a, &.{ t, "conda" });
    for (argv[10..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse fail("bad package argument '{s}'", .{spec});
        const d = join(a, &.{ conda, spec[0..eq] });
        try cwd.makePath(d);
        const tar = pf(a, "{s}.tar", .{d});
        b.run(&.{ payload, absolute(a, spec[eq + 1 ..]), tar });
        {
            const f = try cwd.openFile(tar, .{});
            defer f.close();
            var br = std.io.bufferedReader(f.reader());
            var dd = try cwd.openDir(d, .{});
            defer dd.close();
            try extractTar(dd, br.reader());
        }
        try cwd.deleteFile(tar);
    }
    inline for (.{
        "elfutils/include/elfutils/libdw.h", "elfutils/lib/libdw.a",  "elfutils/lib/libelf.a", "zlib/include/zlib.h",
        "zlib/lib/libz.a",                   "bzip2/lib/libbz2.a",    "zstd/lib/libzstd.a",    "lzma/lib/liblzma.a",
        "libgcc/lib/libgcc_s.so.1",
    }) |need| {
        if (!nonEmpty(join(a, &.{ conda, need }))) fail("{s} is missing from the pinned packages", .{need});
    }

    // libelf.a and libz.a both define crc32, the same function (CRC-32,
    // polynomial 0xedb88320, inverted before and after), and a static link
    // pulls both members. libelf's objects are linked without its crc32.o, so
    // its callers take zlib's.
    const libelf_dir = join(a, &.{ t, "libelf" });
    try cwd.makePath(libelf_dir);
    const members = arMembers(a, readFile(a, join(a, &.{ conda, "elfutils/lib/libelf.a" }))) catch fail("libelf.a is not an ar archive", .{});
    var names = std.StringHashMap(void).init(a);
    for (members) |m| {
        if (names.contains(m.name)) fail("libelf.a has two members of one name", .{});
        try names.put(m.name, {});
    }
    if (!names.contains("crc32.o")) fail("libelf.a has no crc32.o; drop the workaround", .{});
    var libelf_objs = std.ArrayList([]const u8).init(a);
    for (members) |m| {
        if (std.mem.eql(u8, m.name, "crc32.o")) continue;
        const p = join(a, &.{ libelf_dir, m.name });
        try writeFile(p, m.data);
        if (std.mem.endsWith(u8, m.name, ".o")) try libelf_objs.append(p);
    }
    std.mem.sort([]const u8, libelf_objs.items, {}, lessThan);

    const src_root = join(a, &.{ t, "src" });
    try cwd.makePath(src_root);
    {
        const f = try cwd.openFile(archive, .{});
        defer f.close();
        var br = std.io.bufferedReader(f.reader());
        var gz = std.compress.gzip.decompressor(br.reader());
        var dd = try cwd.openDir(src_root, .{});
        defer dd.close();
        try extractTar(dd, gz.reader());
    }
    const top = join(a, &.{ src_root, prefix });
    const s = join(a, &.{ top, "src" });
    const data = join(a, &.{ top, "data" });
    if (!nonEmpty(join(a, &.{ s, "CMakeLists.txt" }))) fail("{s}/src is not in the archive", .{prefix});
    const g = join(a, &.{ t, "gen" });
    try cwd.makePath(g);

    // The patches (README.md, "Patches"): each must add exactly one line
    // holding KOMIRA PATCH; an expression that matches nothing (a new kcov)
    // fails here.
    const patches = [_]struct { file: []const u8, p: Patch }{
        .{ .file = "engines/ptrace_linux.cc", .p = .no_cpu_pin },
        .{ .file = "collector.cc", .p = .not_other_exit },
        .{ .file = "collector.cc", .p = .signal_exit },
        .{ .file = "engines/ptrace.cc", .p = .first_child },
    };
    for (patches) |pt| {
        const path = join(a, &.{ s, pt.file });
        const before = readFile(a, path);
        const after = try applyPatch(a, pt.p, before);
        const delta = countMarked(after) -% countMarked(before);
        if (delta != pt.p.expected()) fail("the patch of {s} marked {d} line(s), expected {d}", .{ pt.file, @as(isize, @bitCast(delta)), pt.p.expected() });
        try writeFile(path, after);
    }

    const defs = [_][]const u8{ "-D_GLIBCXX_USE_NANOSLEEP", "-DKCOV_LIBRARY_PREFIX=/tmp", "-DKCOV_HAS_LIBBFD=0", "-DKCOV_LIBFD_DISASM_STYLED=0", "-DPACKAGE", "-DPACKAGE_VERSION" };
    const incs = [_][]const u8{
        pf(a, "-I{s}/include", .{s}),
        pf(a, "-I{s}", .{shim}),
        pf(a, "-I{s}/elfutils/include", .{conda}),
        pf(a, "-I{s}/zlib/include", .{conda}),
    };
    const cflags = try std.mem.concat(a, []const u8, &.{ &.{ "-target", triple, "-O2", "-g0", "-fPIC" }, &defs, &incs });
    const cxxflags = try std.mem.concat(a, []const u8, &.{ &.{ "-target", triple, "-std=c++17", "-O2", "-g0", "-fPIC" }, &defs, &incs });
    const zlib_a = join(a, &.{ conda, "zlib/lib/libz.a" });
    var static_libs = std.ArrayList([]const u8).init(a);
    try static_libs.append(join(a, &.{ conda, "elfutils/lib/libdw.a" }));
    try static_libs.appendSlice(libelf_objs.items);
    try static_libs.appendSlice(&.{ zlib_a, join(a, &.{ conda, "lzma/lib/liblzma.a" }), join(a, &.{ conda, "bzip2/lib/libbz2.a" }), join(a, &.{ conda, "zstd/lib/libzstd.a" }) });

    // The C objects (zig c++ would pass -std=c++17 to a .c source).
    try writeFile(join(a, &.{ g, "version.c" }), pf(a, "const char *kcov_version = \"{s}\";\n", .{version}));
    b.zigRun("cc", cflags, &.{ "-c", join(a, &.{ g, "version.c" }), "-o", join(a, &.{ g, "version.o" }) });
    b.zigRun("cc", cflags, &.{ "-c", join(a, &.{ s, "solib-parser/phdr_data.c" }), "-o", join(a, &.{ g, "phdr_data.o" }) });
    const curl_o = join(a, &.{ g, "curl_shim.o" });
    b.zigRun("cc", cflags, &.{ "-c", join(a, &.{ shim, "curl_shim.c" }), "-o", curl_o });

    // The libraries kcov embeds and writes out at run time. Each is stripped
    // (-s), as bin/kcov is: zig builds its C runtime objects and libc++ with
    // debug information, whose compilation directory is the worker's absolute
    // path, and those bytes would make every build of kcov differ.
    const sowrapper = join(a, &.{ g, "libkcov_sowrapper.so" });
    const redirector = join(a, &.{ g, "bash_execve_redirector.so" });
    const cloexec = join(a, &.{ g, "bash_tracefd_cloexec.so" });
    const syslib = join(a, &.{ g, "kcov_system_lib.so" });
    b.zigRun("cc", cflags, &.{ "-shared", "-s", join(a, &.{ s, "solib-parser/phdr_data.c" }), join(a, &.{ s, "solib-parser/lib.c" }), "-ldl", "-o", sowrapper });
    b.zigRun("cc", cflags, &.{ "-shared", "-s", join(a, &.{ s, "engines/bash-execve-redirector.c" }), "-ldl", "-o", redirector });
    b.zigRun("cc", cflags, &.{ "-shared", "-s", join(a, &.{ s, "engines/bash-tracefd-cloexec.c" }), "-ldl", "-o", cloexec });
    b.zigRun("c++", cxxflags, &.{ "-shared", "-s", join(a, &.{ s, "engines/system-mode-binary-lib.cc" }), join(a, &.{ s, "utils.cc" }), join(a, &.{ s, "system-mode/registration.cc" }), curl_o, zlib_a, "-ldl", "-o", syslib });

    const Gen = struct { out: []const u8, pairs: []const [2][]const u8 };
    const gens = [_]Gen{
        .{ .out = "library.cc", .pairs = &.{.{ sowrapper, "__library" }} },
        .{ .out = "bash-redirector-library.cc", .pairs = &.{.{ redirector, "bash_redirector_library" }} },
        .{ .out = "bash-cloexec-library.cc", .pairs = &.{.{ cloexec, "bash_cloexec_library" }} },
        .{ .out = "kcov-system-library.cc", .pairs = &.{.{ syslib, "kcov_system_library" }} },
        .{ .out = "python-helper.cc", .pairs = &.{.{ join(a, &.{ s, "engines/python-helper.py" }), "python_helper" }} },
        .{ .out = "bash-helper.cc", .pairs = &.{
            .{ join(a, &.{ s, "engines/bash-helper.sh" }), "bash_helper" },
            .{ join(a, &.{ s, "engines/bash-helper-debug-trap.sh" }), "bash_helper_debug_trap" },
        } },
        .{ .out = "html-data-files.cc", .pairs = &.{
            .{ join(a, &.{ data, "bcov.css" }), "css_text" },
            .{ join(a, &.{ data, "amber.png" }), "icon_amber" },
            .{ join(a, &.{ data, "glass.png" }), "icon_glass" },
            .{ join(a, &.{ data, "source-file.html" }), "source_file_text" },
            .{ join(a, &.{ data, "index.html" }), "index_text" },
            .{ join(a, &.{ data, "js/handlebars.js" }), "handlebars_text" },
            .{ join(a, &.{ data, "js/kcov.js" }), "kcov_text" },
            .{ join(a, &.{ data, "js/jquery.min.js" }), "jquery_text" },
            .{ join(a, &.{ data, "js/jquery.tablesorter.min.js" }), "tablesorter_text" },
            .{ join(a, &.{ data, "js/jquery.tablesorter.widgets.min.js" }), "tablesorter_widgets_text" },
            .{ join(a, &.{ data, "tablesorter-theme.css" }), "tablesorter_theme_text" },
        } },
    };
    for (gens) |gen| {
        var datas = std.ArrayList([]const u8).init(a);
        for (gen.pairs) |p| try datas.append(readFile(a, p[0]));
        try writeFile(join(a, &.{ g, gen.out }), try bin2c(a, gen.pairs, datas.items));
    }

    // kcov_SRCS of src/CMakeLists.txt for Linux, without libbfd and libcurl.
    var link = std.ArrayList([]const u8).init(a);
    for (srcs_list) |f| try link.append(join(a, &.{ s, f }));
    for ([_][]const u8{ "library.cc", "bash-redirector-library.cc", "bash-cloexec-library.cc", "python-helper.cc", "bash-helper.cc", "kcov-system-library.cc", "html-data-files.cc" }) |f| try link.append(join(a, &.{ g, f }));
    try link.appendSlice(&.{ join(a, &.{ g, "version.o" }), join(a, &.{ g, "phdr_data.o" }), curl_o });
    try link.appendSlice(static_libs.items);
    try link.append(join(a, &.{ conda, "libgcc/lib/libgcc_s.so.1" }));
    const bin_dir = join(a, &.{ out, "bin" });
    const lib_dir = join(a, &.{ out, "lib" });
    try cwd.makePath(bin_dir);
    try cwd.makePath(lib_dir);
    const kcov = join(a, &.{ bin_dir, "kcov" });
    try link.appendSlice(&.{ "-lpthread", "-ldl", "-lm", "-s", "-Wl,--disable-new-dtags", "-Wl,-rpath,$ORIGIN/../lib", "-o", kcov });
    b.zigRun("c++", cxxflags, link.items);
    b.run(&.{ elf_rpath, kcov });
    {
        const st = cwd.statFile(kcov) catch fail("bin/kcov was not written", .{});
        if (st.mode & 0o111 == 0) fail("bin/kcov is not executable", .{});
    }
    // cp -L
    try cwd.copyFile(join(a, &.{ conda, "libgcc/lib/libgcc_s.so.1" }), cwd, join(a, &.{ lib_dir, "libgcc_s.so.1" }), .{});

    // The licences (README.md, "Licences"): kcov's own files, and what else
    // bin/kcov and lib/ hold.
    const lic = join(a, &.{ out, "share/licenses/kcov" });
    try cwd.makePath(lic);
    for ([_][]const u8{ "COPYING", "COPYING.externals" }) |f| try cwd.copyFile(join(a, &.{ top, f }), cwd, join(a, &.{ lic, f }), .{});
    try writeFile(join(a, &.{ out, "share/licenses/NOTICE" }), licences_notice);
    try cwd.deleteTree(t);
}
