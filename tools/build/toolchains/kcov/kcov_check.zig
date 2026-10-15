// Why Zig: build tools are Zig (tools/build/README.md). This replaces
// kcov_check.sh (a busybox shell script: sed, grep, od, dd, cmp, find, strings),
// so that the checks of kcov run no shell.
//! kcov_check: the checks of the kcov distribution, each mode one build action
//! of a validation target (defs.bzl, README.md "Checks").
//!
//! usage: kcov_check check <zig_dir> <report_dir> <kcov_dir> <kcov.tar.gz>
//!            <strip_prefix> <fixture_dir> <version> <zig_triple>
//!        kcov_check cases <zig_dir> <report_dir> <elf_rpath> <conda_payload>
//!            <fixture_dir> <zig_triple>
//!        kcov_check same - <report_dir> <dir_a> <dir_b>
//!        kcov_check identity - <report_dir> <kcov_dir> <sha256> <usage_line>
//!
//! Exit 1 on the first wrong result, naming it; otherwise writes
//! <report_dir>/validation.json, the validation result (and, for `check`, the
//! fixture's reports).
//!
//! The glibc floor and what the loader maps for bin/kcov, read from the ELF
//! files, are the validation :kcov_closure (../loader_closure).
//!
//! `check`, against the built kcov, with LD_LIBRARY_PATH set to a directory of
//! decoys (files named like each library kcov could want, none of them ELF), as
//! the test runner sets it to the Mojo toolchain's lib/:
//!   1. The distribution holds bin/kcov, lib/libgcc_s.so.1 and the licence
//!      files under share/licenses/, nothing else, and kcov's licence files are
//!      the source archive's.
//!   2. bin/kcov imports from libgcc_s.so.1 (version GCC_3.0).
//!   3. `kcov --version` prints `kcov <version>`.
//!   4. kcov run on fixtures/cov_fixture.c (zig cc -g -O0) reports each
//!      COV:hit line hit and each COV:miss line missed, and the report, with the
//!      source directory and the timestamp normalized, is
//!      fixtures/cov_fixture.cobertura.xml byte for byte.
//!   5. In that run the loader searched the DT_RPATH of bin/kcov and
//!      initialised its lib/libgcc_s.so.1 and glibc libraries from outside the
//!      distribution and the decoys, nothing else; and in the traced fixture it
//!      initialised the preload library kcov wrote (libkcov_sowrapper.so).
//!   6. kcov run as the coverage variant runs it, on fixtures/cov_fixture.c and
//!      fixtures/cov_part.c compiled with their directory mapped to a
//!      placeholder `/_..._` that exists nowhere: `--replace-src-path=^/_+:<root>`
//!      and `--configure=cobertura-full-paths=1`. Each COV line is reported as
//!      marked in its file, and the normalized report is
//!      fixtures/cov_fixture_relocated.cobertura.xml byte for byte.
//!   7. The HTML report writes the data files of the source archive's data/ byte
//!      for byte (the arrays kcov_build generated from them).
//! `cases` runs the functions behind 5, and elf_rpath and conda_payload, and the
//! mode `identity` (in its own process), on inputs whose answer is known, wrong
//! ones included. `same` compares two builds of the distribution: same files,
//! modes, bytes. `identity` requires that bin/kcov is what the package guard
//! refuses (tools/build/package/kcov_guard.bzl): its sha256 is <sha256> and it
//! holds <usage_line>, the two constants of identity.bzl.

const std = @import("std");
const diff = @import("unified_diff");
const A = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const scan = @import("kcov_check_scan.zig");
const normalize = scan.normalize;
const classLines = scan.classLines;
const lineHits = scan.lineHits;
const markerLines = scan.markerLines;
const inits = scan.inits;
const initsStray = scan.initsStray;
const hasString = scan.hasString;
const dynTagOff = scan.dynTagOff;
const zipMember = scan.zipMember;
const modeString = scan.modeString;

// ---- the checker ----------------------------------------------------------

const Result = struct { code: u32, out: []const u8, stdout: []const u8, stderr: []const u8 };

const Ck = struct {
    a: A,
    mode: []const u8,
    t: []const u8,
    report: []const u8,
    zig: []const u8,
    /// What the last command printed: the script's `$T/log`.
    log: ?[]const u8 = null,
    n: usize = 0,

    fn red(self: *Ck, comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print("kcov_check {s} RED: " ++ fmt ++ "\n", .{self.mode} ++ args);
        if (self.log) |l| {
            std.debug.print("--- log:\n", .{});
            var lines = std.ArrayList([]const u8).init(self.a);
            var it = std.mem.splitScalar(u8, l, '\n');
            while (it.next()) |x| {
                if (it.peek() == null and x.len == 0) break;
                lines.append(x) catch {};
            }
            const from = if (lines.items.len > 40) lines.items.len - 40 else 0;
            for (lines.items[from..]) |x| std.debug.print("{s}\n", .{x});
        }
        std.process.exit(1);
    }

    fn pass(self: *Ck) void {
        self.n += 1;
    }

    fn join(self: *Ck, parts: []const []const u8) []u8 {
        return std.fs.path.join(self.a, parts) catch @panic("oom");
    }

    fn pf(self: *Ck, comptime fmt: []const u8, args: anytype) []u8 {
        return std.fmt.allocPrint(self.a, fmt, args) catch @panic("oom");
    }

    fn read(self: *Ck, path: []const u8) []u8 {
        return std.fs.cwd().readFileAlloc(self.a, path, 1 << 30) catch |e| self.red("cannot read {s}: {s}", .{ path, @errorName(e) });
    }

    fn write(self: *Ck, path: []const u8, data: []const u8) void {
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        const f = std.fs.cwd().createFile(path, .{}) catch |e| self.red("cannot create {s}: {s}", .{ path, @errorName(e) });
        defer f.close();
        f.writeAll(data) catch |e| self.red("cannot write {s}: {s}", .{ path, @errorName(e) });
    }

    fn exists(path: []const u8) bool {
        std.fs.cwd().access(path, .{}) catch return false;
        return true;
    }

    fn nonEmpty(path: []const u8) bool {
        const st = std.fs.cwd().statFile(path) catch return false;
        return st.size > 0;
    }

    fn copy(self: *Ck, from: []const u8, to: []const u8) void {
        if (std.fs.path.dirname(to)) |d| std.fs.cwd().makePath(d) catch {};
        std.fs.cwd().copyFile(from, std.fs.cwd(), to, .{}) catch |e| self.red("cannot copy {s}: {s}", .{ from, @errorName(e) });
    }

    /// Runs `argv` with `extra` environment variables (over the action's, with
    /// LC_ALL, the zig caches and HOME set), in `cwd` when given. The log is
    /// stdout then stderr.
    fn run(self: *Ck, argv: []const []const u8, extra: []const [2][]const u8, cwd: ?[]const u8) Result {
        var env = std.process.getEnvMap(self.a) catch @panic("oom");
        env.put("LC_ALL", "C") catch @panic("oom");
        env.put("ZIG_GLOBAL_CACHE_DIR", self.join(&.{ self.t, "zig-global" })) catch @panic("oom");
        env.put("ZIG_LOCAL_CACHE_DIR", self.join(&.{ self.t, "zig-local" })) catch @panic("oom");
        env.put("HOME", self.join(&.{ self.t, "home" })) catch @panic("oom");
        for (extra) |kv| env.put(kv[0], kv[1]) catch @panic("oom");
        const r = std.process.Child.run(.{ .allocator = self.a, .argv = argv, .env_map = &env, .cwd = cwd, .max_output_bytes = 1 << 27 }) catch |e|
            self.red("cannot run {s}: {s}", .{ argv[0], @errorName(e) });
        const code: u32 = switch (r.term) {
            .Exited => |c| c,
            .Signal => |s| 128 + s,
            else => 255,
        };
        const out = std.mem.concat(self.a, u8, &.{ r.stdout, r.stderr }) catch @panic("oom");
        return .{ .code = code, .out = out, .stdout = r.stdout, .stderr = r.stderr };
    }

    /// `run`, and the log is its output; red unless it exits 0.
    fn must(self: *Ck, argv: []const []const u8, extra: []const [2][]const u8, cwd: ?[]const u8, comptime fmt: []const u8, args: anytype) Result {
        const r = self.run(argv, extra, cwd);
        self.log = r.out;
        if (r.code != 0) self.red(fmt, args);
        return r;
    }

    fn green(self: *Ck) void {
        std.fs.cwd().deleteTree(self.t) catch {};
        const j = self.pf("{{\"version\": 1, \"data\": {{\"status\": \"success\", \"message\": \"kcov_check {s}: {d} checks passed\"}}}}\n", .{ self.mode, self.n });
        self.write(self.join(&.{ self.report, "validation.json" }), j);
        std.debug.print("kcov_check {s} GREEN: {d} checks\n", .{ self.mode, self.n });
    }

    /// The decoy directory `d`: a file named like each library in `names`,
    /// holding text, so the loader fails loudly if it ever maps one.
    fn decoys(self: *Ck, d: []const u8, names: []const []const u8) void {
        std.fs.cwd().makePath(d) catch {};
        for (names) |n| self.write(self.join(&.{ d, n }), "decoy\n");
    }

    /// The LD_DEBUG_OUTPUT file `<prefix>.*` that searched `exe`'s DT_RPATH
    /// (`RPATH from file`; a DT_RUNPATH reads `RUNPATH from file`), or null.
    fn rpathRecord(self: *Ck, exe: []const u8, prefix: []const u8) ?[]const u8 {
        const files = self.recordFiles(prefix);
        const needle = self.pf("(RPATH from file {s})", .{exe});
        for (files) |f| {
            if (std.mem.indexOf(u8, self.read(f), needle) != null) return f;
        }
        return null;
    }

    /// The files `<prefix>.*`, sorted.
    fn recordFiles(self: *Ck, prefix: []const u8) [][]const u8 {
        const dir = std.fs.path.dirname(prefix) orelse ".";
        const base = std.fs.path.basename(prefix);
        var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch return &.{};
        defer d.close();
        var out = std.ArrayList([]const u8).init(self.a);
        var it = d.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .file) continue;
            if (e.name.len > base.len and std.mem.startsWith(u8, e.name, base) and e.name[base.len] == '.')
                out.append(self.join(&.{ dir, e.name })) catch @panic("oom");
        }
        std.mem.sort([]const u8, out.items, {}, lessThan);
        return out.items;
    }

    /// Fails unless, in the Cobertura report `xml`, the class of the source
    /// file `<dir>/<file>` reports each line marked COV:hit hit and each
    /// COV:miss missed.
    fn markers(self: *Ck, xml_path: []const u8, xml: []const u8, dir: []const u8, file: []const u8) void {
        const class = classLines(self.a, xml, file) catch @panic("oom");
        if (class.len == 0) self.red("{s} is not in {s} (by its full path): {s}", .{ file, std.fs.path.basename(xml_path), xml });
        const src = self.read(self.join(&.{ dir, file }));
        for ([_][]const u8{ "hit", "miss" }) |kind| {
            const lines = markerLines(self.a, src, kind) catch @panic("oom");
            if (lines.len == 0) self.red("{s} has no COV:{s} line", .{ file, kind });
            for (lines) |l| {
                const zero = std.mem.eql(u8, kind, "miss");
                if (!(lineHits(self.a, class, l, zero) catch false)) {
                    var ls = std.ArrayList(u8).init(self.a);
                    var it = std.mem.splitScalar(u8, class, '\n');
                    while (it.next()) |x| {
                        if (std.mem.indexOf(u8, x, "<line ") != null) ls.writer().print("{s}\n", .{x}) catch {};
                    }
                    self.red("{s} line {d} (COV:{s}) is not reported as {s}: {s}", .{ file, l, kind, if (zero) "missed" else "hit", std.mem.trimRight(u8, ls.items, "\n") });
                }
            }
        }
    }

    /// Fails unless the text of `want_path` is `got` (a diff is the log).
    fn sameBytes(self: *Ck, want_path: []const u8, got: []const u8, comptime fmt: []const u8, args: anytype) void {
        const want = self.read(want_path);
        if (std.mem.eql(u8, want, got)) return;
        self.log = (diff.unifiedDiff(self.a, "want", "got", want, got) catch null) orelse "";
        self.red(fmt, args);
    }
};

// ---- check ----------------------------------------------------------------

fn extractSome(ck: *Ck, archive: []const u8, dest: std.fs.Dir, wanted: []const []const u8) void {
    const f = std.fs.cwd().openFile(archive, .{}) catch |e| ck.red("cannot open {s}: {s}", .{ archive, @errorName(e) });
    defer f.close();
    var br = std.io.bufferedReader(f.reader());
    var gz = std.compress.gzip.decompressor(br.reader());
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(gz.reader(), .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (it.next() catch |e| ck.red("cannot read {s}: {s}", .{ archive, @errorName(e) })) |ent| {
        const name = std.mem.trimRight(u8, ent.name, "/");
        var take = false;
        for (wanted) |w| {
            if (std.mem.eql(u8, name, w) or (name.len > w.len and std.mem.startsWith(u8, name, w) and name[w.len] == '/')) take = true;
        }
        if (!take or ent.kind != .file) continue;
        if (std.fs.path.dirname(name)) |d| dest.makePath(d) catch {};
        const out = dest.createFile(name, .{}) catch |e| ck.red("cannot create {s}: {s}", .{ name, @errorName(e) });
        defer out.close();
        ent.writeAll(out) catch |e| ck.red("cannot extract {s}: {s}", .{ name, @errorName(e) });
    }
}

fn listNonDirs(ck: *Ck, dir: []const u8) [][]const u8 {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e| ck.red("cannot open {s}: {s}", .{ dir, @errorName(e) });
    defer d.close();
    var out = std.ArrayList([]const u8).init(ck.a);
    var w = d.walk(ck.a) catch @panic("oom");
    while (w.next() catch |e| ck.red("cannot walk {s}: {s}", .{ dir, @errorName(e) })) |e| {
        if (e.kind == .directory) continue;
        out.append(ck.pf("./{s}", .{e.path})) catch @panic("oom");
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

fn realpath(ck: *Ck, p: []const u8) []u8 {
    return std.fs.cwd().realpathAlloc(ck.a, p) catch |e| ck.red("cannot resolve {s}: {s}", .{ p, @errorName(e) });
}

fn checkMode(ck: *Ck, args: []const []const u8) void {
    const kdir = absolute(ck, args[0]);
    const archive = absolute(ck, args[1]);
    const prefix = args[2];
    const fix = absolute(ck, args[3]);
    const version = args[4];
    const triple = args[5];
    const kcov = ck.join(&.{ kdir, "bin/kcov" });
    const own = ck.pf("{s}/bin/../lib/libgcc_s.so.1", .{kdir});
    const decoy = ck.join(&.{ ck.t, "decoy" });
    ck.decoys(decoy, &.{ "libz.so.1", "libdw.so.1", "libelf.so.1", "liblzma.so.5", "libbz2.so.1.0", "libzstd.so.1", "libcurl.so.4", "libstdc++.so.6", "libgcc_s.so.1" });
    const src_root = ck.join(&.{ ck.t, "src" });
    std.fs.cwd().makePath(src_root) catch {};
    {
        var dd = std.fs.cwd().openDir(src_root, .{}) catch @panic("scratch");
        defer dd.close();
        extractSome(ck, archive, dd, &.{ ck.pf("{s}/data", .{prefix}), ck.pf("{s}/COPYING", .{prefix}), ck.pf("{s}/COPYING.externals", .{prefix}) });
    }
    const up = ck.join(&.{ src_root, prefix });
    const ld_decoy = [_][2][]const u8{.{ "LD_LIBRARY_PATH", decoy }};

    // 1. The files of the distribution. A file in lib/ is searched before
    // LD_LIBRARY_PATH and before the system (DT_RPATH), whatever its name.
    const files = listNonDirs(ck, kdir);
    const want_files = [_][]const u8{ "./bin/kcov", "./lib/libgcc_s.so.1", "./share/licenses/NOTICE", "./share/licenses/kcov/COPYING", "./share/licenses/kcov/COPYING.externals" };
    var same_files = files.len == want_files.len;
    if (same_files) {
        for (files, want_files) |x, y| {
            if (!std.mem.eql(u8, x, y)) same_files = false;
        }
    }
    if (!same_files) {
        var got = std.ArrayList(u8).init(ck.a);
        for (files) |x| got.writer().print("{s} ", .{x}) catch {};
        var wantl = std.ArrayList(u8).init(ck.a);
        for (want_files) |x| wantl.writer().print("{s} ", .{x}) catch {};
        ck.red("the distribution holds {s}, want {s}", .{ got.items, wantl.items });
    }
    for ([_][]const u8{ "COPYING", "COPYING.externals" }) |f| {
        const a1 = std.fs.cwd().readFileAlloc(ck.a, ck.join(&.{ up, f }), 1 << 28) catch "";
        const b1 = std.fs.cwd().readFileAlloc(ck.a, ck.join(&.{ kdir, "share/licenses/kcov", f }), 1 << 28) catch "\x00other";
        if (!std.mem.eql(u8, a1, b1)) ck.red("share/licenses/kcov/{s} is not the source archive's {s}", .{ f, f });
    }
    ck.pass();

    // 2. The unwinder. glibc's pthread_cancel unwinds kcov's threads with
    // libgcc_s.so.1; kcov's C++ frames must name the same unwinder. This sees
    // one GCC_3.0 import, not where every _Unwind_* comes from: the run of
    // check 4 ends in pthread_cancel, and a second unwinder crashes it.
    if (!hasString(ck.read(kcov), 7, "GCC_3.0"))
        ck.red("bin/kcov imports no GCC_3.0 symbol from libgcc_s.so.1: its _Unwind_* are another unwinder's (README.md, The unwinder)", .{});
    ck.pass();

    // 3. version
    {
        const r = ck.run(&.{ kcov, "--version" }, &ld_decoy, null);
        ck.log = r.stderr;
        if (r.code != 0) ck.red("kcov --version failed", .{});
        const v = std.mem.trimRight(u8, r.stdout, "\n");
        const want = ck.pf("kcov {s}", .{version});
        if (!std.mem.eql(u8, v, want)) ck.red("kcov --version printed '{s}', want '{s}'", .{ v, want });
    }
    ck.pass();

    // 4. A coverage run, with kcov's defaults and --cobertura-only. The
    // fixture is copied to a real directory: kcov reports the realpath of a
    // source file and drops one it cannot open.
    const src0 = ck.join(&.{ ck.t, "fixture" });
    ck.copy(ck.join(&.{ fix, "cov_fixture.c" }), ck.join(&.{ src0, "cov_fixture.c" }));
    const src = realpath(ck, src0);
    const cov_fixture = ck.join(&.{ ck.t, "cov_fixture" });
    _ = ck.must(&.{ ck.zig, "cc", "-target", triple, "-g", "-O0", "-fno-sanitize=undefined", "cov_fixture.c", "-o", cov_fixture }, &.{}, src, "zig cc of the fixture failed", .{});
    const lddebug = ck.join(&.{ ck.t, "lddebug" });
    const kout = ck.join(&.{ ck.t, "kout" });
    const include = ck.pf("--include-path={s}", .{src});
    {
        const r = ck.must(&.{ kcov, "--cobertura-only", include, kout, cov_fixture }, &.{ .{ "LD_DEBUG", "libs" }, .{ "LD_DEBUG_OUTPUT", lddebug }, .{ "LD_LIBRARY_PATH", decoy } }, null, "kcov run failed", .{});
        if (!hasLine(r.out, "cov_fixture 2")) ck.red("the fixture's output is missing under kcov", .{});
    }
    // With --cobertura-only, kcov v42 writes <out>/cov.xml only (its writer
    // names it for an editor plugin), not <out>/<binary>/cobertura.xml.
    const xml_path = ck.join(&.{ kout, "cov.xml" });
    if (!Ck.nonEmpty(xml_path)) ck.red("kcov wrote no cov.xml", .{});
    const xml = ck.read(xml_path);
    ck.write(ck.join(&.{ ck.report, "cov.xml" }), xml);
    ck.markers(xml_path, xml, src, "cov_fixture.c");
    const norm = normalize(ck.a, xml, src, "@SRC@") catch @panic("oom");
    ck.write(ck.join(&.{ ck.report, "cov.normalized.xml" }), norm);
    ck.sameBytes(ck.join(&.{ fix, "cov_fixture.cobertura.xml" }), norm, "the fixture's report is not fixtures/cov_fixture.cobertura.xml (normalized: @SRC@, timestamp 0)", .{});
    ck.pass();

    // 5. The loader's records of that run (the traced fixture inherits
    // LD_DEBUG and writes a file of its own). kcov's is the one that searched
    // the DT_RPATH of bin/kcov.
    const rec = ck.rpathRecord(kcov, lddebug) orelse ck.red("no loader record searched a DT_RPATH of bin/kcov", .{});
    const init_list = inits(ck.a, ck.read(rec)) catch @panic("oom");
    var found_own = false;
    for (init_list) |p| {
        if (std.mem.eql(u8, p, own)) found_own = true;
    }
    if (!found_own) ck.red("kcov did not initialise lib/libgcc_s.so.1 of its own directory: {s}", .{joinLines(ck, init_list)});
    if (initsStray(ck.a, init_list, kdir, decoy, &.{"libgcc_s.so.1"}) catch @panic("oom")) |stray|
        ck.red("kcov loaded {s}, which is neither glibc from the system nor its own lib/libgcc_s.so.1: {s}", .{ stray, joinLines(ck, init_list) });
    // The fixture's: kcov preloads the library it embeds (libkcov_sowrapper.so,
    // written to its output directory) to hear of shared libraries the program
    // loads. A loader that cannot map it ignores it with a warning, and the
    // run above still passes.
    var found = false;
    for (ck.recordFiles(lddebug)) |f| {
        if (std.mem.eql(u8, f, rec)) continue;
        var lines = std.mem.splitScalar(u8, ck.read(f), '\n');
        while (lines.next()) |l| {
            if (std.mem.indexOf(u8, l, "calling init: ") != null and std.mem.endsWith(u8, l, "/libkcov_sowrapper.so")) found = true;
        }
    }
    if (!found) ck.red("the fixture did not initialise the preload library libkcov_sowrapper.so", .{});
    ck.pass();

    // 6. The coverage variant's run (tools/build/coverage). Its binaries'
    // DWARF names their sources under a placeholder `/_..._` that never
    // exists, which kcov maps back to a source root (realpath first, then the
    // regex), and it writes full paths. The build directory is deleted before
    // the run, so only the mapping finds the sources.
    const b0 = ck.join(&.{ ck.t, "reloc_build" });
    const root0 = ck.join(&.{ ck.t, "srcroot" });
    for ([_][]const u8{ "cov_fixture.c", "cov_part.c" }) |f| {
        ck.copy(ck.join(&.{ fix, f }), ck.join(&.{ b0, f }));
        ck.copy(ck.join(&.{ fix, f }), ck.join(&.{ root0, f }));
    }
    const bdir = realpath(ck, b0);
    const root = realpath(ck, root0);
    const ph = "/________________";
    const cov_reloc = ck.join(&.{ ck.t, "cov_reloc" });
    _ = ck.must(&.{ ck.zig, "cc", "-target", triple, "-g", "-O0", "-fno-sanitize=undefined", ck.pf("-fdebug-prefix-map={s}={s}", .{ bdir, ph }), "cov_fixture.c", "cov_part.c", "-o", cov_reloc }, &.{}, bdir, "zig cc of the relocated fixture failed", .{});
    std.fs.cwd().deleteTree(bdir) catch {};
    const reloc_bin = ck.read(cov_reloc);
    if (std.mem.indexOf(u8, reloc_bin, ph) == null) ck.red("the relocated fixture's DWARF does not name the placeholder {s}", .{ph});
    if (std.mem.indexOf(u8, reloc_bin, bdir) != null) ck.red("the relocated fixture still names its build directory {s}", .{bdir});
    const rout = ck.join(&.{ ck.t, "rout" });
    {
        const r = ck.must(&.{ kcov, "--cobertura-only", "--configure=cobertura-full-paths=1", ck.pf("--include-path={s}", .{root}), ck.pf("--replace-src-path=^/_+:{s}", .{root}), rout, cov_reloc }, &ld_decoy, null, "kcov run of the relocated fixture failed", .{});
        if (!hasLine(r.out, "cov_fixture 2")) ck.red("the relocated fixture's output is missing under kcov", .{});
    }
    const rxml_path = ck.join(&.{ rout, "cov.xml" });
    if (!Ck.nonEmpty(rxml_path)) ck.red("kcov wrote no cov.xml for the relocated fixture", .{});
    const rxml = ck.read(rxml_path);
    ck.write(ck.join(&.{ ck.report, "cov_relocated.xml" }), rxml);
    if (std.mem.indexOf(u8, rxml, ph) != null) ck.red("the relocated report still names the placeholder", .{});
    ck.markers(rxml_path, rxml, root, "cov_fixture.c");
    ck.markers(rxml_path, rxml, root, "cov_part.c");
    const rnorm = normalize(ck.a, rxml, root, "@ROOT@") catch @panic("oom");
    ck.write(ck.join(&.{ ck.report, "cov_relocated.normalized.xml" }), rnorm);
    ck.sameBytes(ck.join(&.{ fix, "cov_fixture_relocated.cobertura.xml" }), rnorm, "the relocated fixture's report is not fixtures/cov_fixture_relocated.cobertura.xml (normalized: @ROOT@, timestamp 0)", .{});
    ck.pass();

    // 7. The HTML report (kcov's default output) and the arrays behind it. The
    // arrays of the bash and Python helpers and of kcov_system_lib are not
    // checked: the variant runs none of those engines.
    const data = ck.join(&.{ up, "data" });
    const hout = ck.join(&.{ ck.t, "hout" });
    _ = ck.must(&.{ kcov, include, hout, cov_fixture }, &ld_decoy, null, "kcov run with the HTML report failed", .{});
    if (!Ck.nonEmpty(ck.join(&.{ hout, "index.html" }))) ck.red("the HTML report has no index.html", .{});
    const pairs = [_][2][]const u8{
        .{ "amber.png", "amber.png" },                                     .{ "glass.png", "glass.png" },
        .{ "bcov.css", "bcov.css" },                                       .{ "tablesorter-theme.css", "tablesorter-theme.css" },
        .{ "js/handlebars.js", "js/handlebars.js" },                       .{ "js/kcov.js", "js/kcov.js" },
        .{ "js/jquery.min.js", "js/jquery.min.js" },                       .{ "js/tablesorter.min.js", "js/jquery.tablesorter.min.js" },
        .{ "js/jquery.tablesorter.widgets.min.js", "js/jquery.tablesorter.widgets.min.js" },
    };
    for (pairs) |pr| {
        const got = std.fs.cwd().readFileAlloc(ck.a, ck.join(&.{ hout, "data", pr[0] }), 1 << 28) catch "\x00missing";
        const want = ck.read(ck.join(&.{ data, pr[1] }));
        if (!std.mem.eql(u8, got, want)) ck.red("the HTML report's data/{s} is not the archive's data/{s}", .{ pr[0], pr[1] });
    }
    ck.pass();
    ck.green();
}

fn joinLines(ck: *Ck, xs: []const []const u8) []u8 {
    return std.mem.join(ck.a, "\n", xs) catch @panic("oom");
}

fn hasLine(text: []const u8, line: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.eql(u8, l, line)) return true;
    }
    return false;
}

fn absolute(ck: *Ck, p: []const u8) []u8 {
    if (std.fs.path.isAbsolute(p)) return ck.a.dupe(u8, p) catch @panic("oom");
    return realpath(ck, p);
}

// ---- cases ----------------------------------------------------------------

/// `zig cc -target <triple> -O1 <extra...>`.
fn zc(ck: *Ck, triple: []const u8, extra: []const []const u8) []const []const u8 {
    var v = std.ArrayList([]const u8).init(ck.a);
    v.appendSlice(&.{ ck.zig, "cc", "-target", triple, "-O1" }) catch @panic("oom");
    v.appendSlice(extra) catch @panic("oom");
    return v.items;
}

fn countDiffs(x: []const u8, y: []const u8) usize {
    var n: usize = 0;
    const m = @min(x.len, y.len);
    for (x[0..m], y[0..m]) |p, q| {
        if (p != q) n += 1;
    }
    return n + (@max(x.len, y.len) - m);
}

fn casesMode(ck: *Ck, args: []const []const u8) void {
    const elf_rpath = absolute(ck, args[0]);
    const payload = absolute(ck, args[1]);
    const fix = absolute(ck, args[2]);
    const triple = args[3];
    const r_dir = ck.join(&.{ ck.t, "rpath" });
    const decoy = ck.join(&.{ ck.t, "decoy" });
    ck.decoys(decoy, &.{"libkcovprobe.so.1"});
    std.fs.cwd().makePath(ck.join(&.{ r_dir, "bin" })) catch {};
    std.fs.cwd().makePath(ck.join(&.{ r_dir, "lib" })) catch {};
    const lib = ck.join(&.{ r_dir, "lib/libkcovprobe.so.1" });
    const probe = ck.join(&.{ r_dir, "bin/probe" });
    const plain = ck.join(&.{ r_dir, "bin/plain" });
    const rpath_lib = ck.join(&.{ fix, "rpath_lib.c" });
    const rpath_main = ck.join(&.{ fix, "rpath_main.c" });

    // The decoy and the run path. libkcovprobe.so.1 and a program linked
    // against it as kcov links libgcc_s.so.1: a positional input, with
    // --disable-new-dtags and $ORIGIN/../lib.
    _ = ck.must(zc(ck, triple, &.{ "-shared", "-fPIC", rpath_lib, "-Wl,-soname,libkcovprobe.so.1", "-o", lib }), &.{}, null, "zig cc of rpath_lib.c failed", .{});
    _ = ck.must(zc(ck, triple, &.{ rpath_main, lib, "-Wl,--disable-new-dtags", "-Wl,-rpath,$ORIGIN/../lib", "-o", probe }), &.{}, null, "zig cc of rpath_main.c failed", .{});
    _ = ck.must(zc(ck, triple, &.{ rpath_main, lib, "-o", plain }), &.{}, null, "zig cc of rpath_main.c without a run path failed", .{});
    {
        const r = ck.run(&.{probe}, &.{}, null);
        if (r.code != 0 or !std.mem.eql(u8, std.mem.trimRight(u8, r.stdout, "\n"), "kcov_probe 42")) ck.red("the probe does not find its library through its run path", .{});
    }
    ck.pass();
    // As zig links it, the run path is a DT_RUNPATH: LD_LIBRARY_PATH comes
    // first, and the decoy wins.
    {
        const r = ck.run(&.{probe}, &.{ .{ "LD_DEBUG", "libs" }, .{ "LD_DEBUG_OUTPUT", ck.join(&.{ ck.t, "runpath" }) }, .{ "LD_LIBRARY_PATH", decoy } }, null);
        ck.log = r.out;
        if (r.code == 0) ck.red("the probe ran with a decoy on LD_LIBRARY_PATH and a DT_RUNPATH: zig wrote a DT_RPATH (drop elf_rpath, README.md)", .{});
    }
    // With nothing on LD_LIBRARY_PATH holding the library, the loader reaches
    // the DT_RUNPATH and records that search, which rpath_record must not take
    // for a DT_RPATH one. (The decoy run above fails before the loader searches
    // the run path, so its record cannot show this.)
    const empty = ck.join(&.{ ck.t, "empty" });
    std.fs.cwd().makePath(empty) catch {};
    const runpath_found = ck.join(&.{ ck.t, "runpath_found" });
    _ = ck.must(&.{probe}, &.{ .{ "LD_DEBUG", "libs" }, .{ "LD_DEBUG_OUTPUT", runpath_found }, .{ "LD_LIBRARY_PATH", empty } }, null, "the unconverted probe failed with an empty LD_LIBRARY_PATH", .{});
    {
        const needle = ck.pf("(RUNPATH from file {s})", .{probe});
        var any = false;
        for (ck.recordFiles(runpath_found)) |f| {
            if (std.mem.indexOf(u8, ck.read(f), needle) != null) any = true;
        }
        if (!any) ck.red("the loader's record of the unconverted probe names no DT_RUNPATH search, so this case shows nothing", .{});
        if (ck.rpathRecord(probe, runpath_found) != null) ck.red("rpath_record took a DT_RUNPATH search for a DT_RPATH one", .{});
    }
    ck.pass();
    // elf_rpath makes it a DT_RPATH: the loader's own lib/ comes first.
    const probe_runpath = ck.join(&.{ ck.t, "probe.runpath" });
    ck.copy(probe, probe_runpath);
    _ = ck.must(&.{ elf_rpath, probe }, &.{}, null, "elf_rpath refused a file with one DT_RUNPATH", .{});
    const rp_prefix = ck.join(&.{ ck.t, "rpathrec" });
    {
        const r = ck.run(&.{probe}, &.{ .{ "LD_DEBUG", "libs" }, .{ "LD_DEBUG_OUTPUT", rp_prefix }, .{ "LD_LIBRARY_PATH", decoy } }, null);
        ck.log = r.stderr;
        if (r.code != 0) ck.red("after elf_rpath the probe fails with a decoy on LD_LIBRARY_PATH", .{});
        const out = std.mem.trimRight(u8, r.stdout, "\n");
        if (!std.mem.eql(u8, out, "kcov_probe 42")) ck.red("after elf_rpath the probe printed '{s}'", .{out});
    }
    if (ck.rpathRecord(probe, rp_prefix) == null) ck.red("rpath_record found no DT_RPATH search of the converted probe", .{});
    if (countDiffs(ck.read(probe_runpath), ck.read(probe)) != 1) ck.red("elf_rpath changed more than the one tag byte", .{});
    ck.pass();
    // inits_stray (check 5) is silent on the converted probe, which loads its
    // own library and glibc from the system...
    {
        const rec = ck.rpathRecord(probe, rp_prefix).?;
        const il = inits(ck.a, ck.read(rec)) catch @panic("oom");
        const want = ck.pf("{s}/bin/../lib/libkcovprobe.so.1", .{r_dir});
        var has_own = false;
        for (il) |p| {
            if (std.mem.eql(u8, p, want)) has_own = true;
        }
        if (!has_own) ck.red("the probe's record initialised no lib/libkcovprobe.so.1 of its own: {s}", .{joinLines(ck, il)});
        if (initsStray(ck.a, il, r_dir, decoy, &.{"libkcovprobe.so.1"}) catch @panic("oom")) |stray|
            ck.red("inits_stray says '{s}' of the converted probe: {s}", .{ stray, joinLines(ck, il) });
    }
    ck.pass();
    // ...and names a library with a glibc name that the loader took from the
    // program's own lib/ (searched before the system): a probe linked like the
    // first one, with a libm.so.6 of its own.
    const m_dir = ck.join(&.{ ck.t, "glibc_named" });
    std.fs.cwd().makePath(ck.join(&.{ m_dir, "bin" })) catch {};
    std.fs.cwd().makePath(ck.join(&.{ m_dir, "lib" })) catch {};
    const m_probe_lib = ck.join(&.{ m_dir, "lib/libkcovprobe.so.1" });
    const m_libm = ck.join(&.{ m_dir, "lib/libm.so.6" });
    const m_probe = ck.join(&.{ m_dir, "bin/probe" });
    ck.copy(lib, m_probe_lib);
    _ = ck.must(zc(ck, triple, &.{ "-shared", "-fPIC", "-Dkcov_probe=kcov_glibc_named", rpath_lib, "-Wl,-soname,libm.so.6", "-o", m_libm }), &.{}, null, "zig cc of rpath_lib.c as libm.so.6 failed", .{});
    _ = ck.must(zc(ck, triple, &.{ rpath_main, m_probe_lib, m_libm, "-Wl,--disable-new-dtags", "-Wl,-rpath,$ORIGIN/../lib", "-o", m_probe }), &.{}, null, "zig cc of rpath_main.c with a libm.so.6 failed", .{});
    _ = ck.must(&.{ elf_rpath, m_probe }, &.{}, null, "elf_rpath refused the probe with a libm.so.6", .{});
    const named = ck.join(&.{ ck.t, "named" });
    _ = ck.must(&.{m_probe}, &.{ .{ "LD_DEBUG", "libs" }, .{ "LD_DEBUG_OUTPUT", named }, .{ "LD_LIBRARY_PATH", decoy } }, null, "the probe with a libm.so.6 of its own failed", .{});
    {
        const rec = ck.rpathRecord(m_probe, named) orelse ck.red("rpath_record found no DT_RPATH search of the probe with a libm.so.6", .{});
        const il = inits(ck.a, ck.read(rec)) catch @panic("oom");
        const stray = (initsStray(ck.a, il, m_dir, decoy, &.{"libkcovprobe.so.1"}) catch @panic("oom")) orelse "";
        const want = ck.pf("{s}/bin/../lib/libm.so.6", .{m_dir});
        if (!std.mem.eql(u8, stray, want)) ck.red("inits_stray says '{s}' of a probe initialising libm.so.6 from its own lib/, want that libm.so.6: {s}", .{ stray, joinLines(ck, il) });
    }
    ck.pass();
    // elf_rpath refuses, leaving the file as it was, unless the file is an
    // x86_64 executable or shared object with one PT_DYNAMIC header, exactly
    // one DT_RUNPATH and no DT_RPATH. The last five subjects are the
    // unconverted probe, which it converts, with one edit each: e_machine
    // aarch64, e_type ET_REL, the first program header retyped PT_DYNAMIC, and
    // its DT_DEBUG entry retagged DT_RPATH (a file with both run paths) or
    // DT_RUNPATH (a file with two).
    const orig = ck.read(probe_runpath);
    const phoff = std.mem.readInt(u32, orig[32..36], .little);
    if (std.mem.readInt(u32, orig[phoff..][0..4], .little) == 2) ck.red("the probe's first program header is PT_DYNAMIC already", .{});
    const debug = dynTagOff(orig, 21) orelse ck.red("the probe has no DT_DEBUG entry to retag", .{});
    if (dynTagOff(orig, 29) == null) ck.red("dyn_tag_off finds no DT_RUNPATH in the unconverted probe", .{});
    if (dynTagOff(orig, 15) != null) ck.red("dyn_tag_off finds a DT_RPATH in the unconverted probe", .{});
    const Defect = struct { name: []const u8, at: usize, bytes: []const u8 };
    const defects = [_]Defect{
        .{ .name = "machine", .at = 18, .bytes = &.{ 0xb7, 0x00 } },
        .{ .name = "type", .at = 16, .bytes = &.{ 0x01, 0x00 } },
        .{ .name = "dynamic", .at = phoff, .bytes = &.{ 0x02, 0x00, 0x00, 0x00 } },
        .{ .name = "both_paths", .at = debug, .bytes = &.{0x0f} },
        .{ .name = "two_runpaths", .at = debug, .bytes = &.{0x1d} },
    };
    var subjects = std.ArrayList([]const u8).init(ck.a);
    subjects.appendSlice(&.{ probe, plain, ck.join(&.{ decoy, "libkcovprobe.so.1" }) }) catch @panic("oom");
    for (defects) |d| {
        const edited = ck.a.dupe(u8, orig) catch @panic("oom");
        @memcpy(edited[d.at .. d.at + d.bytes.len], d.bytes);
        if (countDiffs(orig, edited) < 1) ck.red("the {s} edit changed nothing", .{d.name});
        const p = ck.join(&.{ ck.t, d.name });
        ck.write(p, edited);
        subjects.append(p) catch @panic("oom");
    }
    for (subjects.items) |subject| {
        const before = ck.read(subject);
        const r = ck.run(&.{ elf_rpath, subject }, &.{}, null);
        ck.log = r.out;
        if (r.code != 2) ck.red("elf_rpath exited {d} on {s}, want 2", .{ r.code, std.fs.path.basename(subject) });
        if (!std.mem.eql(u8, before, ck.read(subject))) ck.red("elf_rpath changed {s}, which it refused", .{std.fs.path.basename(subject)});
        ck.pass();
    }

    // conda_payload: the zstd payload of the pkg-*.tar.zst member, with a
    // 32-bit or a zip64 size; a refusal (exit 2, no output) otherwise. The
    // payload is one zstd frame of one raw block, `kcov\n`.
    const frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x05, 0x29, 0x00, 0x00, 0x6b, 0x63, 0x6f, 0x76, 0x0a };
    const cdir = ck.join(&.{ ck.t, "conda" });
    std.fs.cwd().makePath(cdir) catch {};
    const zip = struct {
        fn m(c: *Ck, name: []const u8, method: u16, z64: bool, data: []const u8) []u8 {
            return zipMember(c.a, name, method, z64, data) catch @panic("oom");
        }
    }.m;
    ck.write(ck.join(&.{ cdir, "plain.conda" }), std.mem.concat(ck.a, u8, &.{ zip(ck, "info-x.tar.zst", 0, false, &.{0}), zip(ck, "pkg-x.tar.zst", 0, false, &frame) }) catch @panic("oom"));
    ck.write(ck.join(&.{ cdir, "zip64.conda" }), zip(ck, "pkg-x.tar.zst", 0, true, &frame));
    ck.write(ck.join(&.{ cdir, "nopkg.conda" }), zip(ck, "info-x.tar.zst", 0, false, &frame));
    ck.write(ck.join(&.{ cdir, "deflate.conda" }), zip(ck, "pkg-x.tar.zst", 8, false, &frame));
    for ([_][]const u8{ "plain", "zip64" }) |p| {
        const conda = ck.join(&.{ cdir, ck.pf("{s}.conda", .{p}) });
        const tar = ck.join(&.{ cdir, ck.pf("{s}.tar", .{p}) });
        _ = ck.must(&.{ payload, conda, tar }, &.{}, null, "conda_payload refused {s}.conda", .{p});
        const got = std.mem.trimRight(u8, ck.read(tar), "\n");
        if (!std.mem.eql(u8, got, "kcov")) ck.red("conda_payload wrote '{s}' for {s}.conda, want 'kcov'", .{ got, p });
        ck.pass();
    }
    for ([_][]const u8{ "nopkg", "deflate" }) |p| {
        const conda = ck.join(&.{ cdir, ck.pf("{s}.conda", .{p}) });
        const tar = ck.join(&.{ cdir, ck.pf("{s}.tar", .{p}) });
        const r = ck.run(&.{ payload, conda, tar }, &.{}, null);
        ck.log = r.out;
        if (r.code != 2) ck.red("conda_payload exited {d} on {s}.conda, want 2", .{ r.code, p });
        if (Ck.exists(tar)) ck.red("conda_payload wrote an output for {s}.conda, which it refused", .{p});
        ck.pass();
    }

    // identity, in its own process, on a fixture standing for bin/kcov (its
    // sha256 written here, not computed): accepted with its sha256 and a line
    // it holds; refused, naming the constant and the sha256 to update it to,
    // with a sha256 one digit off; refused with a line it does not hold.
    const idir = ck.join(&.{ ck.t, "identity" });
    std.fs.cwd().makePath(ck.join(&.{ idir, "kcov/bin" })) catch {};
    const id_sha = "3350799a0c9ff68ad6e690405c7a42bba0fe583311a46c7aea97c4a855abced2";
    const id_line = "Usage: kcov_identity case [OPTIONS]";
    ck.write(ck.join(&.{ idir, "kcov/bin/kcov" }), ck.pf("kcov_check cases: this file stands for bin/kcov\x00{s}\x00tail\n", .{id_line}));
    const Case = struct { name: []const u8, sha: []const u8, line: []const u8, want: []const u8 };
    const bad_sha = ck.pf("4{s}", .{id_sha[1..]});
    const id_cases = [_]Case{
        .{ .name = "ok", .sha = id_sha, .line = id_line, .want = "" },
        .{ .name = "sha", .sha = bad_sha, .line = id_line, .want = ck.pf("Update KCOV_BIN_SHA256 to {s}", .{id_sha}) },
        .{ .name = "line", .sha = id_sha, .line = ck.pf("{s} out-dir", .{id_line}), .want = "does not hold KCOV_USAGE_LINE" },
    };
    var self_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const self_exe = std.fs.selfExePath(&self_buf) catch |e| ck.red("cannot find myself: {s}", .{@errorName(e)});
    for (id_cases) |c| {
        const report = ck.join(&.{ idir, "report" });
        const scratch = ck.join(&.{ idir, "scratch" });
        std.fs.cwd().deleteTree(report) catch {};
        std.fs.cwd().deleteTree(scratch) catch {};
        const r = ck.run(&.{ self_exe, "identity", "-", report, ck.join(&.{ idir, "kcov" }), c.sha, c.line }, &.{.{ "BUCK_SCRATCH_PATH", scratch }}, null);
        if (c.want.len == 0) {
            if (r.code != 0) ck.red("identity_{s}: exited {d}, want 0: {s}", .{ c.name, r.code, r.stderr });
            const v = ck.read(ck.join(&.{ report, "validation.json" }));
            if (std.mem.indexOf(u8, v, "2 checks passed") == null) ck.red("identity_{s}: the result is not 2 checks: {s}", .{ c.name, v });
        } else {
            if (r.code != 1) ck.red("identity_{s}: exited {d}, want 1: {s}", .{ c.name, r.code, r.stderr });
            if (std.mem.indexOf(u8, r.stderr, c.want) == null) ck.red("identity_{s}: the refusal does not say '{s}': {s}", .{ c.name, c.want, r.stderr });
            if (Ck.exists(ck.join(&.{ report, "validation.json" }))) ck.red("identity_{s}: refused, but wrote a result", .{c.name});
        }
        ck.pass();
    }
    ck.green();
}

// ---- same -----------------------------------------------------------------

/// `<mode> <sha256 or -> <path>` per entry of `dir`, sorted by path.
pub fn listing(a: A, dir: []const u8) ![]u8 {
    var d = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer d.close();
    const Ent = struct { path: []const u8, kind: std.fs.File.Kind };
    var entries = std.ArrayList(Ent).init(a);
    try entries.append(.{ .path = ".", .kind = .directory });
    var w = try d.walk(a);
    while (try w.next()) |e| try entries.append(.{ .path = try std.fmt.allocPrint(a, "./{s}", .{e.path}), .kind = e.kind });
    std.mem.sort(Ent, entries.items, {}, struct {
        fn f(_: void, x: Ent, y: Ent) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.f);
    var out = std.ArrayList(u8).init(a);
    for (entries.items) |e| {
        const rel = if (std.mem.eql(u8, e.path, ".")) "." else e.path[2..];
        if (e.kind == .sym_link) {
            try out.writer().print("lrwxrwxrwx - {s}\n", .{e.path});
            continue;
        }
        const st = try d.statFile(rel);
        const ms = modeString(e.kind, st.mode);
        if (e.kind == .file) {
            const data = try d.readFileAlloc(a, rel, 1 << 30);
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
            try out.writer().print("{s} {s} {s}\n", .{ ms, std.fmt.fmtSliceHexLower(&h), e.path });
        } else try out.writer().print("{s} - {s}\n", .{ ms, e.path });
    }
    return out.toOwnedSlice();
}

fn sameMode(ck: *Ck, args: []const []const u8) void {
    const a_list = listing(ck.a, absolute(ck, args[0])) catch |e| ck.red("cannot list {s}: {s}", .{ args[0], @errorName(e) });
    const b_list = listing(ck.a, absolute(ck, args[1])) catch |e| ck.red("cannot list {s}: {s}", .{ args[1], @errorName(e) });
    if (a_list.len == 0) ck.red("the first build is empty", .{});
    if (!std.mem.eql(u8, a_list, b_list)) {
        ck.log = (diff.unifiedDiff(ck.a, "a", "b", a_list, b_list) catch null) orelse "";
        ck.red("two builds of the distribution differ (README.md, Reproducible)", .{});
    }
    ck.pass();
    ck.green();
}

// ---- identity -------------------------------------------------------------

fn identityMode(ck: *Ck, args: []const []const u8) void {
    const kcov = ck.join(&.{ absolute(ck, args[0]), "bin/kcov" });
    const want = args[1];
    const line = args[2];
    const data = std.fs.cwd().readFileAlloc(ck.a, kcov, 1 << 30) catch ck.red("{s} is not a file", .{kcov});
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &h, .{});
    const got = ck.pf("{s}", .{std.fmt.fmtSliceHexLower(&h)});
    if (!std.mem.eql(u8, got, want))
        ck.red("bin/kcov's sha256 is {s}, but KCOV_BIN_SHA256 in tools/build/toolchains/kcov/identity.bzl is {s}: kcov's bytes changed (a pin, kcov_build or zig). Update KCOV_BIN_SHA256 to {s}: the package guard refuses a file by it (tools/build/package/README.md, \"kcov is never packed\")", .{ got, want, got });
    ck.pass();
    if (std.mem.indexOf(u8, data, line) == null)
        ck.red("bin/kcov does not hold KCOV_USAGE_LINE of tools/build/toolchains/kcov/identity.bzl, '{s}': kcov's help text changed, so the package guard would find no kcov by it. Update KCOV_USAGE_LINE to a line of kcov's usage text that bin/kcov holds", .{line});
    ck.pass();
    ck.green();
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 4) {
        std.debug.print("usage: kcov_check check|cases|same|identity <zig_dir|-> <report_dir> ...\n", .{});
        std.process.exit(2);
    }
    const mode = argv[1];
    const scratch_base = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch try a.dupe(u8, ".kcov_check");
    const t0 = if (std.process.hasEnvVarConstant("BUCK_SCRATCH_PATH")) try std.fs.path.join(a, &.{ scratch_base, try std.fmt.allocPrint(a, "kcov_{s}", .{mode}) }) else try std.fmt.allocPrint(a, "{s}_{s}", .{ scratch_base, mode });
    try std.fs.cwd().makePath(t0);
    const t = try std.fs.cwd().realpathAlloc(a, t0);
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ t, "home" }));
    const report0 = argv[3];
    try std.fs.cwd().makePath(report0);
    var ck = Ck{
        .a = a,
        .mode = mode,
        .t = t,
        .report = try std.fs.cwd().realpathAlloc(a, report0),
        .zig = if (std.mem.eql(u8, argv[2], "-")) "" else try std.fs.path.join(a, &.{ try std.fs.cwd().realpathAlloc(a, argv[2]), "zig" }),
    };
    const rest = argv[4..];
    if (std.mem.eql(u8, mode, "check")) {
        if (rest.len != 6) ck.red("usage: check needs 6 arguments after the report dir", .{});
        checkMode(&ck, rest);
    } else if (std.mem.eql(u8, mode, "cases")) {
        if (rest.len != 4) ck.red("usage: cases needs 4 arguments after the report dir", .{});
        casesMode(&ck, rest);
    } else if (std.mem.eql(u8, mode, "same")) {
        if (rest.len != 2) ck.red("usage: same needs 2 arguments after the report dir", .{});
        sameMode(&ck, rest);
    } else if (std.mem.eql(u8, mode, "identity")) {
        if (rest.len != 3) ck.red("usage: identity needs 3 arguments after the report dir", .{});
        identityMode(&ck, rest);
    } else ck.red("unknown mode '{s}'", .{mode});
}
