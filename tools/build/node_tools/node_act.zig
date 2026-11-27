// Why Zig: build tools are Zig (tools/build/README.md). node_act replaces the
// busybox scripts of tools/build/node/defs.bzl (the Node.js distribution, the
// npm package, the node test, the esbuild bundle), so those actions run no
// shell, and runs the npm install test, which has no script to replace.
//! node_act: the actions of the node rules (tools/build/node/defs.bzl).
//!
//!   node_act dist --archive <tgz> --out <dir> --top <dir> --version <v> --libs <dir>
//!       Keeps bin/node, include/node and LICENSE of the archive's top
//!       directory, and runs that node, which must print v<version>.
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
//!   node_act install-test --node <dir> --libs <dir> --npm <dir> --out <file>
//!       --dir <dir> --install <tgz> [--tarball <tgz>]... -- <test file>...
//!       Copies <dir> into an empty project and the tarballs into its
//!       tarballs/, writes the project's package.json (a dependency on the
//!       package of --install, an override of every other tarball's package
//!       to that tarball, by absolute path), runs the npm CLI of <npm> (its bin/npm-cli.js) with
//!       the pinned node: `install --offline --ignore-scripts --engine-strict`.
//!       Passes only if npm exits 0, its package-lock.json names no package
//!       with an install script, and `node --test` over the test files, from
//!       the project, passes as binding-test requires.
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

fn cmdDist(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{ .{ .name = "archive" }, .{ .name = "out" }, .{ .name = "top" }, .{ .name = "version" }, .{ .name = "libs" } };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("dist: {s}: {s}", .{ @errorName(e), bad });
    const archive = f.need("archive") catch return usage("dist needs --archive", .{});
    const out = f.need("out") catch return usage("dist needs --out", .{});
    const top = f.need("top") catch return usage("dist needs --top", .{});
    const want = f.need("version") catch return usage("dist needs --version", .{});
    const libs = f.need("libs") catch return usage("dist needs --libs", .{});

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

// ---- install-test -------------------------------------------------------------

/// Whether the tar entry `name` is the package.json at the top of an npm
/// tarball: `<top>/package.json` for any one top directory (a leading `./`
/// aside), since npm drops the first component of every entry. The registry's
/// tarballs mostly call it `package`, but not all (`@types/node`'s is
/// `node v25.9`).
pub fn isTopManifest(name: []const u8) bool {
    var n = name;
    while (std.mem.startsWith(u8, n, "./")) n = n[2..];
    const slash = std.mem.indexOfScalar(u8, n, '/') orelse return false;
    return slash > 0 and std.mem.eql(u8, n[slash + 1 ..], "package.json");
}

/// The `name` a package.json states at its top level; `error.NoName` when it
/// states none (absent, not a string, or empty).
pub fn manifestName(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    if (parsed.value != .object) return error.NoName;
    const n = parsed.value.object.get("name") orelse return error.NoName;
    if (n != .string or n.string.len == 0) return error.NoName;
    return n.string;
}

/// The package name of the npm tarball `bytes` (gzip over tar): its top
/// package.json's `name`. `error.NoManifest` when it has no top package.json.
/// The stream is inflated into memory first, as extract.extractTgz does.
pub fn tarballName(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var in: std.Io.Reader = .fixed(bytes);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var tar_bytes = std.Io.Writer.Allocating.init(a);
    _ = dec.reader.streamRemaining(&tar_bytes.writer) catch |e| return if (e == error.ReadFailed) (dec.err orelse e) else e;
    var tar: std.Io.Reader = .fixed(tar_bytes.written());
    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(&tar, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        if (f.kind != .file or !isTopManifest(f.name)) continue;
        var text = std.Io.Writer.Allocating.init(a);
        try it.streamRemaining(f, &text.writer);
        return manifestName(a, text.written());
    }
    return error.NoManifest;
}

/// A package of a test project: its npm name and its tarball's path in the
/// project (`tarballs/<file>`).
pub const Tarball = struct { name: []const u8, file: []const u8 };

/// The package.json of the test project at `root` (absolute): private, an ES
/// module package, its one dependency `install` as a `file:` tarball, and
/// every package of `others` overridden to its tarball, so that npm resolves a
/// dependency of that name at any depth (a platform package the installed
/// package names among its optionalDependencies, a peer, or a dependency of a
/// peer) to the tarball. The paths are absolute: npm 11 reads an override's
/// relative `file:` path against the package that depends on it first, and
/// warns that the tarball is corrupted before it tries the project's.
pub fn projectManifest(a: std.mem.Allocator, root: []const u8, install: Tarball, others: []const Tarball) ![]u8 {
    var buf = std.Io.Writer.Allocating.init(a);
    var w: std.json.Stringify = .{ .writer = &buf.writer, .options = .{ .whitespace = .indent_2 } };
    try w.beginObject();
    try w.objectField("name");
    try w.write("komira-install-test");
    try w.objectField("version");
    try w.write("0.0.0");
    try w.objectField("private");
    try w.write(true);
    try w.objectField("type");
    try w.write("module");
    try w.objectField("dependencies");
    try w.beginObject();
    try w.objectField(install.name);
    try w.write(try std.fmt.allocPrint(a, "file:{s}/{s}", .{ root, install.file }));
    try w.endObject();
    try w.objectField("overrides");
    try w.beginObject();
    for (others) |o| {
        try w.objectField(o.name);
        try w.write(try std.fmt.allocPrint(a, "file:{s}/{s}", .{ root, o.file }));
    }
    try w.endObject();
    try w.endObject();
    try buf.writer.writeAll("\n");
    return buf.written();
}

/// Why two packages of a test project cannot both be in it, or null: the
/// same package name (npm would resolve it to one of them) or the same file
/// name (one would overwrite the other in tarballs/).
pub fn clash(a: std.mem.Allocator, have: []const Tarball, next: Tarball) !?[]const u8 {
    for (have) |h| {
        if (std.mem.eql(u8, h.name, next.name)) return try std.fmt.allocPrint(a, "{s} and {s} are both the package {s}", .{ h.file, next.file, next.name });
        if (std.mem.eql(u8, h.file, next.file)) return try std.fmt.allocPrint(a, "two tarballs are named {s}", .{next.file});
    }
    return null;
}

/// The arguments of the npm install of a test project: npm's CLI run by
/// `node_exe`, offline (nothing is fetched; every package is a tarball of the
/// project), with no install script run, the `engines` of every package held
/// to the running node, no audit, funding or update notice (each would ask a
/// registry), and its cache and both config files in `scratch`.
pub fn npmInstallArgv(a: std.mem.Allocator, node_exe: []const u8, npm_dir: []const u8, scratch: []const u8) ![]const []const u8 {
    var argv = std.ArrayList([]const u8).empty;
    try argv.append(a, node_exe);
    try argv.append(a, try std.fs.path.join(a, &.{ npm_dir, "bin", "npm-cli.js" }));
    try argv.appendSlice(a, &.{ "install", "--offline", "--ignore-scripts", "--engine-strict", "--no-audit", "--no-fund", "--no-update-notifier", "--loglevel=warn" });
    try argv.append(a, try std.fmt.allocPrint(a, "--cache={s}/npm-cache", .{scratch}));
    try argv.append(a, try std.fmt.allocPrint(a, "--userconfig={s}/npmrc", .{scratch}));
    try argv.append(a, try std.fmt.allocPrint(a, "--globalconfig={s}/npmrc-global", .{scratch}));
    return argv.toOwnedSlice(a);
}

/// The packages npm's package-lock.json `lock` marks `"hasInstallScript":
/// true` (a preinstall, install or postinstall script, or a binding.gyp, which
/// npm builds at install), by their path in it, sorted. `error.NotALock` when
/// `lock` has no `packages` object.
pub fn installScripts(a: std.mem.Allocator, lock: []const u8) ![]const []const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, lock, .{});
    if (parsed.value != .object) return error.NotALock;
    const pkgs = parsed.value.object.get("packages") orelse return error.NotALock;
    if (pkgs != .object) return error.NotALock;
    var out = std.ArrayList([]const u8).empty;
    var it = pkgs.object.iterator();
    while (it.next()) |kv| {
        const v = kv.value_ptr.*;
        if (v != .object) continue;
        const h = v.object.get("hasInstallScript") orelse continue;
        if (h == .bool and h.bool) try out.append(a, kv.key_ptr.*);
    }
    const items = try out.toOwnedSlice(a);
    std.mem.sort([]const u8, items, {}, U.lessBytes);
    return items;
}

fn cmdInstall(a: std.mem.Allocator, args: []const []const u8) u8 {
    const spec = [_]U.Spec{
        .{ .name = "node" }, .{ .name = "libs" },    .{ .name = "npm" },     .{ .name = "out" },
        .{ .name = "dir" },  .{ .name = "install" }, .{ .name = "tarball" },
    };
    var bad: []const u8 = "";
    const f = U.parseFlags(a, args, &spec, &bad) catch |e| return usage("install-test: {s}: {s}", .{ @errorName(e), bad });
    const node = f.need("node") catch return usage("install-test needs --node", .{});
    const libs = f.need("libs") catch return usage("install-test needs --libs", .{});
    const npm = f.need("npm") catch return usage("install-test needs --npm", .{});
    const out = f.need("out") catch return usage("install-test needs --out", .{});
    const dir = f.need("dir") catch return usage("install-test needs --dir", .{});
    const install = f.need("install") catch return usage("install-test needs --install", .{});
    if (f.rest.len == 0) return usage("install-test: no test file", .{});
    const tarball_items = f.all(a, "tarball") catch return 2;

    const cwd = std.fs.cwd().realpathAlloc(a, ".") catch return usage("cannot resolve the working directory", .{});
    const scratch = U.scratchRoot(a, cwd, std.posix.getenv("BUCK_SCRATCH_PATH")) catch return 2;
    std.fs.cwd().makePath(std.fs.path.join(a, &.{ scratch, "home" }) catch return 2) catch return 2;
    std.fs.cwd().makePath(std.fs.path.join(a, &.{ scratch, "tmp" }) catch return 2) catch return 2;
    defer std.fs.cwd().deleteTree(scratch) catch {};

    const node_abs = U.abs(a, cwd, node) catch return 2;
    const libs_abs = U.abs(a, cwd, libs) catch return 2;
    const npm_abs = U.abs(a, cwd, npm) catch return 2;
    const project = std.fs.path.join(a, &.{ scratch, "project" }) catch return 2;

    // The project: the staged tests and fixtures, then the tarballs.
    var proj = std.fs.cwd().makeOpenPath(project, .{ .iterate = true }) catch |e| return usage("cannot create {s}: {s}", .{ project, @errorName(e) });
    defer proj.close();
    {
        var src = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e| return usage("cannot open {s}: {s}", .{ dir, @errorName(e) });
        defer src.close();
        U.copyTree(src, proj) catch |e| return usage("cannot copy {s} into {s}: {s}", .{ dir, project, @errorName(e) });
    }
    proj.makePath("tarballs") catch |e| return usage("cannot create {s}/tarballs: {s}", .{ project, @errorName(e) });
    var paths = std.ArrayList([]const u8).empty;
    paths.append(a, install) catch return 2;
    for (tarball_items) |it| paths.append(a, it.vals[0]) catch return 2;
    var packages = std.ArrayList(Tarball).empty;
    for (paths.items) |p| {
        const bytes = std.fs.cwd().readFileAlloc(a, p, 1 << 31) catch |e| return usage("cannot read {s}: {s}", .{ p, @errorName(e) });
        const name = tarballName(a, bytes) catch |e| {
            std.debug.print("install_test: {s} is not an npm tarball whose package.json names its package ({s})\n", .{ p, @errorName(e) });
            return 2;
        };
        const pkg = Tarball{ .name = name, .file = std.fmt.allocPrint(a, "tarballs/{s}", .{std.fs.path.basename(p)}) catch return 2 };
        if (clash(a, packages.items, pkg) catch return 2) |why| {
            std.debug.print("install_test: {s}\n", .{why});
            return 2;
        }
        U.writeAll(proj, pkg.file, bytes) catch |e| return usage("cannot write {s}/{s}: {s}", .{ project, pkg.file, @errorName(e) });
        packages.append(a, pkg) catch return 2;
    }
    const manifest = projectManifest(a, project, packages.items[0], packages.items[1..]) catch return 2;
    U.writeAll(proj, "package.json", manifest) catch |e| return usage("cannot write {s}/package.json: {s}", .{ project, @errorName(e) });
    // Empty config files, so that no npmrc of the worker is read.
    for ([_][]const u8{ "npmrc", "npmrc-global" }) |rc| {
        U.writeAll(std.fs.cwd(), std.fs.path.join(a, &.{ scratch, rc }) catch return 2, "") catch |e| return usage("cannot write {s}/{s}: {s}", .{ scratch, rc, @errorName(e) });
    }

    const env = testEnv(a, scratch, libs_abs) catch return 2;
    const node_exe = std.fmt.allocPrint(a, "{s}/bin/node", .{node_abs}) catch return 2;
    const npm_argv = npmInstallArgv(a, node_exe, npm_abs, scratch) catch return 2;
    const installed = U.runCapture(a, npm_argv, &env, project) catch |e| return usage("cannot run npm: {s}", .{@errorName(e)});
    if (installed.code != 0) {
        std.debug.print("{s}{s}install_test: npm install exited {d}\n", .{ installed.stdout, installed.stderr, installed.code });
        return installed.code;
    }
    const lock = proj.readFileAlloc(a, "package-lock.json", 1 << 30) catch |e| {
        std.debug.print("{s}{s}install_test: npm wrote no package-lock.json ({s})\n", .{ installed.stdout, installed.stderr, @errorName(e) });
        return 1;
    };
    const scripts = installScripts(a, lock) catch |e| {
        std.debug.print("install_test: cannot read npm's package-lock.json: {s}\n", .{@errorName(e)});
        return 1;
    };
    if (scripts.len > 0) {
        const named = U.spaced(a, scripts) catch return 2;
        std.debug.print("{s}{s}install_test: npm reports an install script in {s}, and npm install is the only step: a package runs nothing at install\n", .{ installed.stdout, installed.stderr, named });
        return 1;
    }

    // The tests, from the project, where a bare import resolves to node_modules.
    var argv = std.ArrayList([]const u8).empty;
    argv.appendSlice(a, &.{ node_exe, "--test", "--test-reporter=tap" }) catch return 2;
    const first_test = argv.items.len;
    for (f.rest) |t| argv.append(a, std.fs.path.join(a, &.{ project, t }) catch return 2) catch return 2;
    const r = U.runCapture(a, argv.items, &env, project) catch |e| return usage("cannot run node: {s}", .{@errorName(e)});
    if (r.code != 0) {
        std.debug.print("{s}{s}{s}install_test: node --test exited {d}\n", .{ installed.stdout, r.stdout, r.stderr, r.code });
        return r.code;
    }
    if (tapRefusal(r.stdout)) |why| {
        std.debug.print("{s}{s}install_test: node --test exited 0, but {s}\n", .{ r.stdout, r.stderr, why });
        return 1;
    }
    for (argv.items[first_test..]) |p| {
        if (fileIsTheTest(r.stdout, p)) {
            std.debug.print("{s}{s}install_test: node --test exited 0, but {s} registers no test of its own\n", .{ r.stdout, r.stderr, p });
            return 1;
        }
    }
    std.fs.File.stdout().writeAll(installed.stdout) catch {};
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
    if (argv.len < 2) std.process.exit(usage("usage: node_act (dist|npm-package|node-test|binding-test|install-test|esbuild-bundle) ...", .{}));
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
    else if (std.mem.eql(u8, sub, "install-test"))
        cmdInstall(a, plain)
    else if (std.mem.eql(u8, sub, "esbuild-bundle"))
        cmdBundle(a, plain)
    else
        usage("unknown subcommand {s}", .{sub});
    if (rc != 0) std.process.exit(rc);
}
