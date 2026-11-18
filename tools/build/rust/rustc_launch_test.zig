//! Unit tests of rustc_launch.zig: the command line, the scratch directory, the
//! arguments rustc is run with, and the checks on its output (what counts as a
//! path is held by tools/build/dir_match's tests). The process behaviour (the
//! environment, the exit statuses, the linker shim) is held by
//! tests//functional/rustc_launch, which runs the launcher over a stand-in
//! rustc, and by every Rust target of the repository, which compiles through it.
const std = @import("std");
const L = @import("rustc_launch.zig");
const t = std.testing;

test "parse: five positional arguments, then rustc's after --" {
    const p = try L.parse(&.{ "bb", "sys", "zig", "x86_64-linux-gnu.2.34", "out.rlib", "--", "--crate-name=a", "-o", "out.rlib", "lib.rs" });
    try t.expectEqualStrings("bb", p.busybox);
    try t.expectEqualStrings("sys", p.sysroot);
    try t.expectEqualStrings("zig", p.zig_dir);
    try t.expectEqualStrings("x86_64-linux-gnu.2.34", p.cc_target);
    try t.expectEqualStrings("out.rlib", p.output);
    try t.expectEqual(@as(usize, 4), p.rustc_args.len);
    try t.expectEqualStrings("lib.rs", p.rustc_args[3]);
}

test "parse: no rustc arguments is allowed; rustc's own -- is kept" {
    const p = try L.parse(&.{ "bb", "sys", "zig", "tgt", "out", "--" });
    try t.expectEqual(@as(usize, 0), p.rustc_args.len);
    const q = try L.parse(&.{ "bb", "sys", "zig", "tgt", "out", "--", "--", "x" });
    try t.expectEqual(@as(usize, 2), q.rustc_args.len);
    try t.expectEqualStrings("--", q.rustc_args[0]);
}

test "parse: refusals" {
    try t.expectError(error.Usage, L.parse(&.{}));
    try t.expectError(error.Usage, L.parse(&.{ "bb", "sys", "zig", "tgt" }));
    try t.expectError(error.MissingSeparator, L.parse(&.{ "bb", "sys", "zig", "tgt", "out" }));
    try t.expectError(error.MissingSeparator, L.parse(&.{ "bb", "sys", "zig", "tgt", "out", "x", "--" }));
}

test "scratchRoot: where buck2 names, else beside the inputs" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("/w/.komira_rustc", try L.scratchRoot(a, "/w", null));
    try t.expectEqualStrings("/w/.komira_rustc", try L.scratchRoot(a, "/w", ""));
    try t.expectEqualStrings("/s/x/komira", try L.scratchRoot(a, "/w", "/s/x"));
    try t.expectEqualStrings("/w/buck-out/s/komira", try L.scratchRoot(a, "/w", "buck-out/s"));
}

test "rustcArgv: the sysroot, the shim, no rust-lld, the remap, then the caller's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try L.rustcArgv(a, "/s/bin/rustc", "/s", "/t/cc/cc", "/w", &.{ "--crate-name=a", "lib.rs" });
    const want = [_][]const u8{
        "/s/bin/rustc",
        "--sysroot",
        "/s",
        "-C",
        "linker=/t/cc/cc",
        "-C",
        "linker-features=-lld",
        "--remap-path-prefix=/w=.",
        "--crate-name=a",
        "lib.rs",
    };
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "exitCodeOf: a child's status, 128 + N for a signal" {
    try t.expectEqual(@as(u8, 0), L.exitCodeOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 101), L.exitCodeOf(.{ .Exited = 101 }));
    try t.expectEqual(@as(u8, 139), L.exitCodeOf(.{ .Signal = 11 }));
    try t.expectEqual(@as(u8, 1), L.exitCodeOf(.{ .Unknown = 5 }));
}

test "unset_vars: the four a toolchain run must not inherit" {
    const want = [_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "RUSTFLAGS", "RUSTC_BOOTSTRAP" };
    try t.expectEqual(want.len, L.unset_vars.len);
    for (want, L.unset_vars) |w, g| try t.expectEqualStrings(w, g);
}

fn put(dir: std.fs.Dir, name: []const u8, data: []const u8) !void {
    const f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(data);
}

test "checkOutput: missing, empty, clean, near misses, and outputs holding the working directory" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const a = t.allocator;
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const at = struct {
        fn p(r: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(t.allocator, &.{ r, name });
        }
    }.p;
    const missing = try at(root, "missing");
    defer a.free(missing);
    try t.expectEqual(L.OutputCheck.missing_or_empty, try L.checkOutput(a, missing, "/work"));
    try put(tmp.dir, "empty", "");
    const empty = try at(root, "empty");
    defer a.free(empty);
    try t.expectEqual(L.OutputCheck.missing_or_empty, try L.checkOutput(a, empty, "/work"));
    const outputs = [_]struct { data: []const u8, want: L.OutputCheck }{
        .{ .data = "an rlib with ./src/lib.rs only", .want = .ok },
        // A longer name that starts with the working directory's bytes.
        .{ .data = "src/runtime/worker.rs", .want = .ok },
        .{ .data = ".../actions/workflows/ci.yml", .want = .ok },
        // The same name as a later component of another absolute path.
        .{ .data = "openapi_files(\"/home/someone/work/buck-out/v2/gen\")", .want = .ok },
        .{ .data = "debug info: /work/crate/src/lib.rs", .want = .has_cwd },
        .{ .data = "x\x00/work\x00", .want = .has_cwd },
        .{ .data = "-I/work/inc", .want = .has_cwd },
        .{ .data = "/home/someone/work /work", .want = .has_cwd },
    };
    for (outputs) |o| {
        try put(tmp.dir, "out", o.data);
        const out = try at(root, "out");
        defer a.free(out);
        t.expectEqual(o.want, try L.checkOutput(a, out, "/work")) catch |e| {
            std.debug.print("output: {s}\n", .{o.data});
            return e;
        };
    }
    // A directory is neither empty nor read.
    try tmp.dir.makeDir("adir");
    try put(tmp.dir, "adir/f", "/work");
    const adir = try at(root, "adir");
    defer a.free(adir);
    try t.expectEqual(L.OutputCheck.ok, try L.checkOutput(a, adir, "/work"));
}
