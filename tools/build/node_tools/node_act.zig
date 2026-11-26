// Why Zig: build tools are Zig (tools/build/README.md). node_act replaces the
// busybox scripts of tools/build/node/defs.bzl (the Node.js distribution, the
// npm package, the node test, the esbuild bundle), so those actions run no shell.
//! node_act: the actions of the node rules (tools/build/node/defs.bzl).
//!
//!   node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --libs <dir>
//!       Keeps bin/node, include/node and LICENSE of the archive's top
//!       directory, and runs that node, which must print v<version>.
//!   node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --foreign macho-arm64
//!       The same for an archive built for macOS arm64, which this platform
//!       cannot run: no --libs, and node is not run. bin/node must start with
//!       the Mach-O 64-bit arm64 header, and include/node/node_version.h must
//!       state <v>.
//!   node_act npm-package --tarball <tgz> --out <dir> --name <n> --version <v>
//!       --integrity <sha512-b64> --exe <path|-> --node <dir> --libs <dir> --js <program>
//!       Checks the tarball's sha512, unpacks its package/ directory, has the
//!       pinned node run <program> over its package.json, and with an
//!       executable named checks that it prints the version.
//!   node_act node-test --node <dir> --libs <dir> --out <file> --dir <dir>
//!       --script <path> --expect <pass|fail> --error <text> -- <args>...
//!   node_act binding-test --node <dir> --libs <dir> --out <file> --dir <dir>
//!       [--cover <path>]... -- <test file>...
//!       Runs `node --test` (TAP reporter) over the files in <dir>; passes only
//!       if the summary reports tests, all passed, none skipped. With --cover,
//!       node measures those files (paths in <dir>) into lcov, and the run
//!       passes only if every one was loaded and their lines and branches
//!       together are each at least 99% covered.
//!   node_act esbuild-bundle --esbuild <exe> --dir <dir> --entry <path>
//!       --out <file> --format <cjs|esm>
//!
//! The messages and exit statuses are those of the scripts they replace.

const std = @import("std");
const U = @import("act_util");
const X = U.extract;

const prog = "node_act";

fn usage(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print(prog ++ ": " ++ fmt ++ "\n", args);
    return 2;
}

// ---- dist -------------------------------------------------------------------

pub fn keepDist(rest: []const u8) bool {
    return std.mem.eql(u8, rest, "bin/node") or std.mem.eql(u8, rest, "LICENSE") or
        std.mem.eql(u8, rest, "include/node") or std.mem.startsWith(u8, rest, "include/node/");
}

/// Whether `dir` holds `path` as a regular file (links followed), and with
/// `exec` that it has an execute bit.
pub fn isFile(dir: std.fs.Dir, path: []const u8, exec: bool) bool {
    const st = dir.statFile(path) catch return false;
    if (st.kind != .file) return false;
    return !exec or st.mode & 0o111 != 0;
}

/// The environment of the node runs that are not tests: the library path only.
pub fn libsEnv(a: std.mem.Allocator, libs_abs: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ libs_abs, "lib" }));
    return env;
}

/// The first bytes of a Mach-O 64-bit arm64 executable: the magic `0xfeedfacf`
/// and the cputype `CPU_TYPE_ARM64` (`0x0100000c`), little-endian.
pub const macho_arm64_header = [8]u8{ 0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01 };

/// Why `head` (the first bytes of a file) is not a Mach-O 64-bit arm64
/// executable, or null when it is. An ELF file is named, as the likeliest
/// mistake: the linux archive given for a macOS dist.
pub fn machoArm64Refusal(head: []const u8) ?[]const u8 {
    if (head.len < macho_arm64_header.len) return "it is shorter than a Mach-O header";
    if (std.mem.startsWith(u8, head, "\x7fELF")) return "it is an ELF file";
    if (!std.mem.eql(u8, head[0..4], macho_arm64_header[0..4])) return "it does not start with the Mach-O 64-bit magic";
    if (!std.mem.eql(u8, head[4..8], macho_arm64_header[4..8])) return "its Mach-O cputype is not arm64";
    return null;
}

/// The number `<name>` is defined as in node_version.h (`#define NODE_MAJOR_VERSION 24`), or null.
fn defineNumber(text: []const u8, name: []const u8) ?u32 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var toks = std.mem.tokenizeAny(u8, line, " \t\r");
        const d = toks.next() orelse continue;
        if (!std.mem.eql(u8, d, "#define")) continue;
        const n = toks.next() orelse continue;
        if (!std.mem.eql(u8, n, name)) continue;
        const v = toks.next() orelse continue;
        return std.fmt.parseInt(u32, v, 10) catch continue;
    }
    return null;
}

/// The `<major>.<minor>.<patch>` node_version.h states. When a define is
/// absent or not a number, `error.NoDefine` and `missing` names it.
pub fn headerVersion(a: std.mem.Allocator, text: []const u8, missing: *[]const u8) error{ NoDefine, OutOfMemory }![]u8 {
    const names = [_][]const u8{ "NODE_MAJOR_VERSION", "NODE_MINOR_VERSION", "NODE_PATCH_VERSION" };
    var n: [3]u32 = undefined;
    for (names, 0..) |name, i| {
        n[i] = defineNumber(text, name) orelse {
            missing.* = name;
            return error.NoDefine;
        };
    }
    return std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ n[0], n[1], n[2] });
}

/// Why a dist built for macOS arm64 is not the pinned release, or null: its
/// `bin/node` (first bytes `head`) is no Mach-O arm64 executable, or its
/// node_version.h (`header`) states a version other than `want`. Nothing is run.
pub fn foreignRefusal(a: std.mem.Allocator, archive: []const u8, head: []const u8, header: []const u8, want: []const u8) !?[]const u8 {
    if (machoArm64Refusal(head)) |why| {
        return try std.fmt.allocPrint(a, "node_dist: the bin/node in {s} is not a Mach-O 64-bit arm64 executable: {s}\n", .{ archive, why });
    }
    var missing: []const u8 = "";
    const got = headerVersion(a, header, &missing) catch |e| switch (e) {
        error.NoDefine => return try std.fmt.allocPrint(a, "node_dist: include/node/node_version.h in {s} does not define {s} as a number\n", .{ archive, missing }),
        error.OutOfMemory => return e,
    };
    if (!std.mem.eql(u8, got, want)) {
        return try std.fmt.allocPrint(a, "node_dist: include/node/node_version.h in {s} states v{s}, the pin says v{s}\n", .{ archive, got, want });
    }
    return null;
}

fn cmdDist(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "archive" }, .{ .name = "out" }, .{ .name = "top" }, .{ .name = "version" }, .{ .name = "libs" }, .{ .name = "foreign" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("dist: {s}: {s}", .{ @errorName(e), bad });
    const archive = f.need("archive") catch return usage("dist needs --archive", .{});
    const out = f.need("out") catch return usage("dist needs --out", .{});
    const top = f.need("top") catch return usage("dist needs --top", .{});
    const want = f.need("version") catch return usage("dist needs --version", .{});
    const foreign = f.one("foreign");
    if (foreign) |fmt| {
        if (!std.mem.eql(u8, fmt, "macho-arm64")) return usage("dist: --foreign is macho-arm64, not {s}", .{fmt});
        if (f.one("libs") != null) return usage("dist: --foreign takes no --libs", .{});
    }
    const libs = if (foreign != null) "" else f.need("libs") catch return usage("dist needs --libs", .{});

    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const bytes = std.fs.cwd().readFileAlloc(a, archive, 1 << 30) catch |e| return usage("cannot read {s}: {s}", .{ archive, @errorName(e) });
    var dest = std.fs.cwd().makeOpenPath(out, .{ .iterate = true }) catch |e| return usage("cannot create {s}: {s}", .{ out, @errorName(e) });
    defer dest.close();
    X.extractTgz(a, dest, bytes, top, keepDist) catch |e| {
        std.debug.print("node_dist: cannot unpack {s}: {s}\n", .{ archive, @errorName(e) });
        return 2;
    };
    if (!isFile(dest, "bin/node", true) or !isFile(dest, "include/node/node_api.h", false)) {
        std.debug.print("node_dist: {s} holds no {s}/bin/node or {s}/include/node/node_api.h\n", .{ archive, top, top });
        return 2;
    }
    if (!isFile(dest, "LICENSE", false)) {
        std.debug.print("node_dist: {s} holds no {s}/LICENSE\n", .{ archive, top });
        return 2;
    }
    if (foreign != null) {
        // Not run: its format is this platform's no more than its libraries are.
        var head: [macho_arm64_header.len]u8 = undefined;
        const got = dest.readFile("bin/node", &head) catch |e| return usage("cannot read {s}/bin/node: {s}", .{ out, @errorName(e) });
        const header = dest.readFileAlloc(a, "include/node/node_version.h", 1 << 20) catch |e| switch (e) {
            error.FileNotFound => "",
            else => return usage("cannot read {s}/include/node/node_version.h: {s}", .{ out, @errorName(e) }),
        };
        const refusal = foreignRefusal(a, archive, got, header, want) catch return 2;
        if (refusal) |why| {
            std.debug.print("{s}", .{why});
            return 2;
        }
        return 0;
    }
    const libs_abs = U.abs(a, cwd, libs) catch return 2;
    const env = libsEnv(a, libs_abs) catch return 2;
    const node = std.fmt.allocPrint(a, "{s}/bin/node", .{out}) catch return 2;
    const r = U.runCapture(a, &.{ node, "--version" }, &env, null) catch {
        std.debug.print("node_dist: {s} does not run\n", .{node});
        return 2;
    };
    if (r.stderr.len > 0) std.debug.print("{s}", .{r.stderr});
    if (r.code != 0) {
        std.debug.print("node_dist: {s} does not run\n", .{node});
        return 2;
    }
    const got = U.trimNewlines(r.stdout);
    const pin = std.fmt.allocPrint(a, "v{s}", .{want}) catch return 2;
    if (!std.mem.eql(u8, got, pin)) {
        std.debug.print("node_dist: the node in {s} is {s}, the pin says v{s}\n", .{ archive, got, want });
        return 2;
    }
    return 0;
}

// ---- npm-package ------------------------------------------------------------

pub const sri_prefix = "sha512-";

/// `error.NotSha512` unless `sri` is `sha512-` and at least one more character.
pub fn sriShape(sri: []const u8) error{NotSha512}!void {
    if (!std.mem.startsWith(u8, sri, sri_prefix) or sri.len == sri_prefix.len) return error.NotSha512;
}

/// The bytes of the base64 after `sha512-`, as lower-case hex; the empty
/// string when it does not decode.
pub fn sriHex(a: std.mem.Allocator, sri: []const u8) ![]u8 {
    const b64 = sri[sri_prefix.len..];
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(b64) catch return a.dupe(u8, "");
    const buf = try a.alloc(u8, n);
    dec.decode(buf, b64) catch return a.dupe(u8, "");
    const hex = try a.alloc(u8, n * 2);
    _ = std.fmt.bufPrint(hex, "{x}", .{buf}) catch unreachable;
    return hex;
}

fn cmdNpm(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "tarball" }, .{ .name = "out" },  .{ .name = "name" },    .{ .name = "version" }, .{ .name = "integrity" },
        .{ .name = "exe" },     .{ .name = "node" }, .{ .name = "libs" },    .{ .name = "js" },
    };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("npm-package: {s}: {s}", .{ @errorName(e), bad });
    const tgz = f.need("tarball") catch return usage("npm-package needs --tarball", .{});
    const out = f.need("out") catch return usage("npm-package needs --out", .{});
    const name = f.need("name") catch return usage("npm-package needs --name", .{});
    const version = f.need("version") catch return usage("npm-package needs --version", .{});
    const sri = f.need("integrity") catch return usage("npm-package needs --integrity", .{});
    const exe = f.need("exe") catch return usage("npm-package needs --exe", .{});
    const node = f.need("node") catch return usage("npm-package needs --node", .{});
    const libs = f.need("libs") catch return usage("npm-package needs --libs", .{});
    const js = f.need("js") catch return usage("npm-package needs --js", .{});

    sriShape(sri) catch {
        std.debug.print("npm_package: {s}: integrity {s} is not sha512-<base64>\n", .{ name, sri });
        return 2;
    };
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const bytes = std.fs.cwd().readFileAlloc(a, tgz, 1 << 30) catch |e| return usage("cannot read {s}: {s}", .{ tgz, @errorName(e) });
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash(bytes, &digest, .{});
    const got = std.fmt.allocPrint(a, "{x}", .{&digest}) catch return 2;
    const want = sriHex(a, sri) catch return 2;
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("npm_package: {s}: the sha512 of {s} is {s}; the pinned integrity {s} is {s}\n", .{ name, tgz, got, sri, want });
        return 2;
    }
    var dest = std.fs.cwd().makeOpenPath(out, .{ .iterate = true }) catch |e| return usage("cannot create {s}: {s}", .{ out, @errorName(e) });
    defer dest.close();
    X.extractTgz(a, dest, bytes, "package", X.keepAll) catch |e| {
        std.debug.print("npm_package: {s}: cannot unpack {s}: {s}\n", .{ name, tgz, @errorName(e) });
        return 2;
    };
    if (!isFile(dest, "package.json", false)) {
        std.debug.print("npm_package: {s}: {s} holds no package/package.json\n", .{ name, tgz });
        return 2;
    }
    // The pinned node reads package.json as npm does (JSON.parse).
    const node_abs = U.abs(a, cwd, node) catch return 2;
    const libs_abs = U.abs(a, cwd, libs) catch return 2;
    const env = libsEnv(a, libs_abs) catch return 2;
    const node_exe = std.fmt.allocPrint(a, "{s}/bin/node", .{node_abs}) catch return 2;
    const manifest = std.fmt.allocPrint(a, "{s}/package.json", .{out}) catch return 2;
    const where = std.fmt.allocPrint(a, "npm_package: {s}: package.json of {s}", .{ name, tgz }) catch return 2;
    const r = U.runCapture(a, &.{ node_exe, "-e", js, manifest, where, name, version }, &env, null) catch |e| return usage("cannot run {s}: {s}", .{ node_exe, @errorName(e) });
    std.debug.print("{s}", .{r.stderr});
    if (r.stdout.len > 0) std.fs.File.stdout().writeAll(r.stdout) catch {};
    if (r.code != 0) return r.code;

    if (!std.mem.eql(u8, exe, "-")) {
        const exe_path = std.fmt.allocPrint(a, "{s}/{s}", .{ out, exe }) catch return 2;
        var empty = std.process.EnvMap.init(a);
        defer empty.deinit();
        const v = U.runCapture(a, &.{ exe_path, "--version" }, &empty, null) catch {
            std.debug.print("npm_package: {s}: {s} does not run\n", .{ name, exe });
            return 2;
        };
        if (v.stderr.len > 0) std.debug.print("{s}", .{v.stderr});
        if (v.code != 0) {
            std.debug.print("npm_package: {s}: {s} does not run\n", .{ name, exe });
            return 2;
        }
        const printed = U.trimNewlines(v.stdout);
        if (!std.mem.eql(u8, printed, version)) {
            std.debug.print("npm_package: {s}: {s} --version prints {s}, the pin says {s}\n", .{ name, exe, printed, version });
            return 2;
        }
    }
    return 0;
}

// ---- node-test --------------------------------------------------------------

/// The environment of a node test: fixed, nothing inherited.
pub fn testEnv(a: std.mem.Allocator, scratch: []const u8, libs_abs: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    try env.put("LC_ALL", "C");
    try env.put("TZ", "UTC0");
    try env.put("HOME", try std.fs.path.join(a, &.{ scratch, "home" }));
    try env.put("TMPDIR", try std.fs.path.join(a, &.{ scratch, "tmp" }));
    try env.put("LD_LIBRARY_PATH", try std.fs.path.join(a, &.{ libs_abs, "lib" }));
    return env;
}

fn cmdTest(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "node" }, .{ .name = "libs" },   .{ .name = "out" },    .{ .name = "dir" },
        .{ .name = "script" }, .{ .name = "expect" }, .{ .name = "error" },
    };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("node-test: {s}: {s}", .{ @errorName(e), bad });
    const node = f.need("node") catch return usage("node-test needs --node", .{});
    const libs = f.need("libs") catch return usage("node-test needs --libs", .{});
    const out = f.need("out") catch return usage("node-test needs --out", .{});
    const dir = f.need("dir") catch return usage("node-test needs --dir", .{});
    const script = f.need("script") catch return usage("node-test needs --script", .{});
    const expect = f.need("expect") catch return usage("node-test needs --expect", .{});
    const err_text = f.need("error") catch return usage("node-test needs --error", .{});
    const want_fail = std.mem.eql(u8, expect, "fail");
    if (!want_fail and !std.mem.eql(u8, expect, "pass")) return usage("node-test: --expect is pass or fail", .{});

    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    const home = std.fs.path.join(a, &.{ scratch, "home" }) catch return 2;
    const tmp = std.fs.path.join(a, &.{ scratch, "tmp" }) catch return 2;
    std.fs.cwd().makePath(home) catch return 2;
    std.fs.cwd().makePath(tmp) catch return 2;
    defer std.fs.cwd().deleteTree(scratch) catch {};

    const node_abs = U.abs(a, cwd, node) catch return 2;
    const libs_abs = U.abs(a, cwd, libs) catch return 2;
    const dir_abs = U.abs(a, cwd, dir) catch return 2;
    const script_path = std.fs.path.join(a, &.{ dir_abs, script }) catch return 2;
    const env = testEnv(a, scratch, libs_abs) catch return 2;
    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, std.fmt.allocPrint(a, "{s}/bin/node", .{node_abs}) catch return 2) catch return 2;
    argv.append(a, script_path) catch return 2;
    argv.appendSlice(a, f.rest) catch return 2;

    if (!want_fail) {
        var child = std.process.Child.init(argv.items, a);
        child.env_map = &env;
        const term = child.spawnAndWait() catch |e| return usage("cannot run node: {s}", .{@errorName(e)});
        const code = U.exitCodeOf(term);
        if (code != 0) return code;
    } else {
        const r = U.runCapture(a, argv.items, &env, null) catch |e| return usage("cannot run node: {s}", .{@errorName(e)});
        if (r.stdout.len > 0) std.fs.File.stdout().writeAll(r.stdout) catch {};
        if (r.code == 0) {
            std.debug.print("node_test: {s} exited 0; it was expected to fail with: {s}\n", .{ script_path, err_text });
            return 1;
        }
        if (!U.contains(r.stderr, err_text)) {
            std.debug.print("{s}node_test: {s} failed, but its stderr does not hold: {s}\n", .{ r.stderr, script_path, err_text });
            return 1;
        }
    }
    U.writeAll(std.fs.cwd(), out, "") catch |e| return usage("cannot write {s}: {s}", .{ out, @errorName(e) });
    return 0;
}

// ---- binding-test -------------------------------------------------------------

/// The number of a TAP summary line `# <key> <n>` (the last such line), or null.
pub fn tapCount(out: []const u8, key: []const u8) ?u64 {
    var found: ?u64 = null;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "# ")) continue;
        const rest = line[2..];
        if (!std.mem.startsWith(u8, rest, key)) continue;
        if (rest.len <= key.len or rest[key.len] != ' ') continue;
        found = std.fmt.parseInt(u64, std.mem.trim(u8, rest[key.len + 1 ..], " \r"), 10) catch continue;
    }
    return found;
}

/// Why a `node --test` run that exited 0 still does not count, or null. A run
/// of zero tests (a file that registers none), a test skipped or left todo
/// pass node's exit status and prove nothing.
pub fn tapRefusal(out: []const u8) ?[]const u8 {
    const tests = tapCount(out, "tests") orelse return "its TAP summary has no \"# tests\" line";
    if (tests == 0) return "it ran no test";
    if ((tapCount(out, "fail") orelse 1) != 0 or (tapCount(out, "cancelled") orelse 1) != 0) return "a test failed or was cancelled";
    if ((tapCount(out, "skipped") orelse 1) != 0 or (tapCount(out, "todo") orelse 1) != 0) return "a test was skipped or left todo";
    if ((tapCount(out, "pass") orelse 0) != tests) return "not every test passed";
    return null;
}

/// Whether the TAP output reports `path` as a test of its own
/// (`# Subtest: <path>`). node does that for a file that registers no test:
/// the file itself is the one test, and it passes by exiting 0.
pub fn fileIsTheTest(out: []const u8, path: []const u8) bool {
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "# Subtest: ") and std.mem.eql(u8, std.mem.trimRight(u8, line["# Subtest: ".len..], "\r"), path)) return true;
    }
    return false;
}

/// The line and branch percentage, at least, that the covered sources of a
/// binding test must each reach over the run as a whole (rule T1).
pub const cover_floor: u64 = 99;

/// One `SF:` record of an lcov tracefile: its lines found and hit (`LF`,
/// `LH`) and its branches found and hit (`BRF`, `BRH`).
pub const FileCover = struct {
    path: []const u8,
    lf: u64 = 0,
    lh: u64 = 0,
    brf: u64 = 0,
    brh: u64 = 0,
};

/// The records of an lcov tracefile, in order. A path under `dir` (absolute)
/// is made relative to it. A count that is not a number is an error.
pub fn parseLcov(a: std.mem.Allocator, text: []const u8, dir: []const u8) ![]FileCover {
    var files = std.ArrayList(FileCover).empty;
    var cur: ?FileCover = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "SF:")) {
            var p = line[3..];
            if (dir.len > 0 and p.len > dir.len + 1 and std.mem.startsWith(u8, p, dir) and p[dir.len] == '/') p = p[dir.len + 1 ..];
            cur = .{ .path = p };
        } else if (std.mem.eql(u8, line, "end_of_record")) {
            if (cur) |c| try files.append(a, c);
            cur = null;
        } else if (cur) |*c| {
            const keys = [_][]const u8{ "LF:", "LH:", "BRF:", "BRH:" };
            const fields = [_]*u64{ &c.lf, &c.lh, &c.brf, &c.brh };
            for (keys, fields) |k, field| {
                if (std.mem.startsWith(u8, line, k)) field.* = try std.fmt.parseInt(u64, line[k.len..], 10);
            }
        }
    }
    return files.toOwnedSlice(a);
}

/// `hit` of `found` as a percentage with two decimals, rounded down; 0 of 0 is 100.
fn percent(a: std.mem.Allocator, hit: u64, found: u64) ![]const u8 {
    const bp = if (found == 0) 10000 else hit * 10000 / found;
    return std.fmt.allocPrint(a, "{d}.{d:0>2}%", .{ bp / 100, bp % 100 });
}

/// Why the covered sources `covers` fail their floor in the lcov records
/// `files`, or null: a source no test loaded (no record), or line or branch
/// coverage of all of them together under `cover_floor` percent.
pub fn coverRefusal(a: std.mem.Allocator, files: []const FileCover, covers: []const []const u8) !?[]const u8 {
    var total = FileCover{ .path = "" };
    for (covers) |want| {
        const rec = for (files) |f| {
            if (std.mem.eql(u8, f.path, want)) break f;
        } else return try std.fmt.allocPrint(a, "{s} is to be covered, and no test loaded it", .{want});
        total.lf += rec.lf;
        total.lh += rec.lh;
        total.brf += rec.brf;
        total.brh += rec.brh;
    }
    if (total.lh * 100 < cover_floor * total.lf) {
        return try std.fmt.allocPrint(a, "the line coverage of the covered sources is {s} ({d} of {d} lines), under {d}%", .{ try percent(a, total.lh, total.lf), total.lh, total.lf, cover_floor });
    }
    if (total.brh * 100 < cover_floor * total.brf) {
        return try std.fmt.allocPrint(a, "the branch coverage of the covered sources is {s} ({d} of {d} branches), under {d}%", .{ try percent(a, total.brh, total.brf), total.brh, total.brf, cover_floor });
    }
    return null;
}

/// One line per covered source: its path, lines hit of found and branches
/// hit of found, for the log of a run that measured them.
pub fn coverTable(a: std.mem.Allocator, files: []const FileCover, covers: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (covers) |want| {
        for (files) |f| {
            if (!std.mem.eql(u8, f.path, want)) continue;
            try out.appendSlice(a, try std.fmt.allocPrint(a, "binding_test: covered {s}: lines {d}/{d} ({s}), branches {d}/{d} ({s})\n", .{ f.path, f.lh, f.lf, try percent(a, f.lh, f.lf), f.brh, f.brf, try percent(a, f.brh, f.brf) }));
        }
    }
    return out.toOwnedSlice(a);
}

fn cmdBinding(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "node" }, .{ .name = "libs" }, .{ .name = "out" }, .{ .name = "dir" }, .{ .name = "cover" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("binding-test: {s}: {s}", .{ @errorName(e), bad });
    const node = f.need("node") catch return usage("binding-test needs --node", .{});
    const libs = f.need("libs") catch return usage("binding-test needs --libs", .{});
    const out = f.need("out") catch return usage("binding-test needs --out", .{});
    const dir = f.need("dir") catch return usage("binding-test needs --dir", .{});
    if (f.rest.len == 0) return usage("binding-test: no test file", .{});
    const cover_items = f.all(a, "cover") catch return 2;
    const covers = a.alloc([]const u8, cover_items.len) catch return 2;
    for (cover_items, 0..) |it, i| covers[i] = it.vals[0];

    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    std.fs.cwd().makePath(std.fs.path.join(a, &.{ scratch, "home" }) catch return 2) catch return 2;
    std.fs.cwd().makePath(std.fs.path.join(a, &.{ scratch, "tmp" }) catch return 2) catch return 2;
    defer std.fs.cwd().deleteTree(scratch) catch {};

    const node_abs = U.abs(a, cwd, node) catch return 2;
    const libs_abs = U.abs(a, cwd, libs) catch return 2;
    const dir_abs = U.abs(a, cwd, dir) catch return 2;
    const env = testEnv(a, scratch, libs_abs) catch return 2;
    var argv = std.ArrayList([]const u8).empty;
    argv.append(a, std.fmt.allocPrint(a, "{s}/bin/node", .{node_abs}) catch return 2) catch return 2;
    argv.append(a, "--test") catch return 2;
    argv.append(a, "--test-reporter=tap") catch return 2;
    // With covered sources, node also writes an lcov tracefile of exactly
    // those files (the TAP report stays on stdout, where it is read).
    const lcov = std.fs.path.join(a, &.{ scratch, "lcov.info" }) catch return 2;
    if (covers.len > 0) {
        argv.append(a, "--test-reporter-destination=stdout") catch return 2;
        argv.append(a, "--test-reporter=lcov") catch return 2;
        argv.append(a, std.fmt.allocPrint(a, "--test-reporter-destination={s}", .{lcov}) catch return 2) catch return 2;
        argv.append(a, "--experimental-test-coverage") catch return 2;
        for (covers) |c| argv.append(a, std.fmt.allocPrint(a, "--test-coverage-include={s}", .{c}) catch return 2) catch return 2;
    }
    const first_test = argv.items.len;
    for (f.rest) |t| argv.append(a, std.fs.path.join(a, &.{ dir_abs, t }) catch return 2) catch return 2;

    const r = U.runCapture(a, argv.items, &env, dir_abs) catch |e| return usage("cannot run node: {s}", .{@errorName(e)});
    if (r.code != 0) {
        std.debug.print("{s}{s}binding_test: node --test exited {d}\n", .{ r.stdout, r.stderr, r.code });
        return r.code;
    }
    if (tapRefusal(r.stdout)) |why| {
        std.debug.print("{s}{s}binding_test: node --test exited 0, but {s}\n", .{ r.stdout, r.stderr, why });
        return 1;
    }
    for (argv.items[first_test..]) |p| {
        if (fileIsTheTest(r.stdout, p)) {
            std.debug.print("{s}{s}binding_test: node --test exited 0, but {s} registers no test of its own\n", .{ r.stdout, r.stderr, p });
            return 1;
        }
    }
    if (covers.len > 0) {
        const text = std.fs.cwd().readFileAlloc(a, lcov, 1 << 30) catch |e| {
            std.debug.print("{s}{s}binding_test: node wrote no coverage ({s}: {s})\n", .{ r.stdout, r.stderr, lcov, @errorName(e) });
            return 1;
        };
        const files = parseLcov(a, text, dir_abs) catch |e| {
            std.debug.print("{s}{s}binding_test: cannot read node's coverage: {s}\n", .{ r.stdout, r.stderr, @errorName(e) });
            return 1;
        };
        const table = coverTable(a, files, covers) catch return 2;
        if (coverRefusal(a, files, covers) catch return 2) |why| {
            std.debug.print("{s}{s}{s}binding_test: node --test passed, but {s}\n", .{ r.stdout, r.stderr, table, why });
            return 1;
        }
        std.fs.File.stdout().writeAll(table) catch {};
    }
    std.fs.File.stdout().writeAll(r.stdout) catch {};
    U.writeAll(std.fs.cwd(), out, "") catch |e| return usage("cannot write {s}: {s}", .{ out, @errorName(e) });
    return 0;
}

// ---- esbuild-bundle -----------------------------------------------------------

fn cmdBundle(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "esbuild" }, .{ .name = "dir" }, .{ .name = "entry" }, .{ .name = "out" }, .{ .name = "format" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("esbuild-bundle: {s}: {s}", .{ @errorName(e), bad });
    const esbuild = f.need("esbuild") catch return usage("esbuild-bundle needs --esbuild", .{});
    const dir = f.need("dir") catch return usage("esbuild-bundle needs --dir", .{});
    const entry = f.need("entry") catch return usage("esbuild-bundle needs --entry", .{});
    const out = f.need("out") catch return usage("esbuild-bundle needs --out", .{});
    const format = f.need("format") catch return usage("esbuild-bundle needs --format", .{});
    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const exe = U.abs(a, cwd, esbuild) catch return 2;
    const dir_abs = U.abs(a, cwd, dir) catch return 2;
    const out_abs = U.abs(a, cwd, out) catch return 2;
    const fmt_arg = std.fmt.allocPrint(a, "--format={s}", .{format}) catch return 2;
    const out_arg = std.fmt.allocPrint(a, "--outfile={s}", .{out_abs}) catch return 2;
    // esbuild runs from the staged directory, so the bundle's path comments
    // are paths in it, with an empty environment.
    var empty = std.process.EnvMap.init(a);
    defer empty.deinit();
    var child = std.process.Child.init(&.{ exe, entry, "--bundle", "--platform=node", fmt_arg, out_arg, "--log-level=warning" }, a);
    child.env_map = &empty;
    child.cwd = dir_abs;
    const term = child.spawnAndWait() catch |e| return usage("cannot run {s}: {s}", .{ exe, @errorName(e) });
    return U.exitCodeOf(term);
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = std.process.argsAlloc(a) catch std.process.exit(2);
    if (argv.len < 2) std.process.exit(usage("usage: node_act (dist|npm-package|node-test|binding-test|esbuild-bundle) ...", .{}));
    const plain = a.alloc([]const u8, argv.len - 2) catch std.process.exit(2);
    for (argv[2..], 0..) |s, i| plain[i] = s;
    const sub = argv[1];
    const rc: u8 = if (std.mem.eql(u8, sub, "dist"))
        cmdDist(a, plain)
    else if (std.mem.eql(u8, sub, "npm-package"))
        cmdNpm(a, plain)
    else if (std.mem.eql(u8, sub, "node-test"))
        cmdTest(a, plain)
    else if (std.mem.eql(u8, sub, "binding-test"))
        cmdBinding(a, plain)
    else if (std.mem.eql(u8, sub, "esbuild-bundle"))
        cmdBundle(a, plain)
    else
        usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
