//! Unit tests of rustc_launch.zig: the command line, the scratch directory, the
//! arguments rustc is run with, and the checks on its output. The process
//! behaviour (the environment, the exit statuses, the linker shim) is held by
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

test "fileContains: a match anywhere, across reads, and not a near miss" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // The needle (9 bytes) straddles the first read of a 20-byte buffer.
    try put(tmp.dir, "f", "aaaaaaaaaaaaaaa/work/dir/bbbbbbbbbbbbbbbbbb");
    var small: [20]u8 = undefined;
    const f = try tmp.dir.openFile("f", .{});
    defer f.close();
    try t.expect(try L.fileContains(f, "/work/dir", &small));
    try f.seekTo(0);
    try t.expect(!try L.fileContains(f, "/work/dix", &small));
    try f.seekTo(0);
    try t.expect(try L.fileContains(f, "aaaa", &small));
    try f.seekTo(0);
    try t.expect(try L.fileContains(f, "bbbbbbbbbbbbbbbbbb", &small));
    try f.seekTo(0);
    try t.expect(!try L.fileContains(f, "bbbbbbbbbbbbbbbbbbb", &small));
}

test "checkOutput: missing, empty, clean, and one holding the working directory" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [64]u8 = undefined;
    const root = try tmp.dir.realpathAlloc(t.allocator, ".");
    defer t.allocator.free(root);
    const at = struct {
        fn p(r: []const u8, name: []const u8) ![]u8 {
            return std.fs.path.join(t.allocator, &.{ r, name });
        }
    }.p;
    const missing = try at(root, "missing");
    defer t.allocator.free(missing);
    try t.expectEqual(L.OutputCheck.missing_or_empty, try L.checkOutput(missing, "/work", &buf));
    try put(tmp.dir, "empty", "");
    const empty = try at(root, "empty");
    defer t.allocator.free(empty);
    try t.expectEqual(L.OutputCheck.missing_or_empty, try L.checkOutput(empty, "/work", &buf));
    try put(tmp.dir, "clean", "an rlib with ./src/lib.rs only");
    const clean = try at(root, "clean");
    defer t.allocator.free(clean);
    try t.expectEqual(L.OutputCheck.ok, try L.checkOutput(clean, "/work", &buf));
    try put(tmp.dir, "dirty", "debug info: /work/crate/src/lib.rs");
    const dirty = try at(root, "dirty");
    defer t.allocator.free(dirty);
    try t.expectEqual(L.OutputCheck.has_cwd, try L.checkOutput(dirty, "/work", &buf));
    // A directory is neither empty nor read.
    try tmp.dir.makeDir("adir");
    try put(tmp.dir, "adir/f", "/work");
    const adir = try at(root, "adir");
    defer t.allocator.free(adir);
    try t.expectEqual(L.OutputCheck.ok, try L.checkOutput(adir, "/work", &buf));
}
