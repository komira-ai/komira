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

test "fileHoldsDir: the directory as a path, across reads; not a near miss" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // The needle (9 bytes) straddles the first read of a 20-byte buffer.
    try put(tmp.dir, "f", "aaaaaaaaaaaaaaa/work/dir/bbbbbbbbbbbbbbbbbb");
    var small: [20]u8 = undefined;
    const f = try tmp.dir.openFile("f", .{});
    defer f.close();
    try t.expect(try L.fileHoldsDir(f, "/work/dir", &small));
    try f.seekTo(0);
    try t.expect(!try L.fileHoldsDir(f, "/work/dix", &small));
    try f.seekTo(0);
    // The last bytes of the file, then one byte more than the file holds.
    try t.expect(try L.fileHoldsDir(f, "bbbbbbbbbbbbbbbbbb", &small));
    try f.seekTo(0);
    try t.expect(!try L.fileHoldsDir(f, "bbbbbbbbbbbbbbbbbbb", &small));
    try f.seekTo(0);
    // `aaaa` is followed by `a` at every match but the last, whose next
    // byte is `/`; a directory that ends in `/` counts wherever it is.
    try t.expect(try L.fileHoldsDir(f, "aaaa", &small));
    try f.seekTo(0);
    try t.expect(try L.fileHoldsDir(f, "/work/", &small));
}

test "fileHoldsDir: a longer name that starts with the directory's bytes does not count" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var small: [8]u8 = undefined;
    const cases = [_]struct { data: []const u8, held: bool }{
        .{ .data = "src/runtime/worker.rs", .held = false },
        .{ .data = "/workspace /work.d /work_1 /work-a /work+b /work~ /work@c /work9", .held = false },
        .{ .data = "/work\xc3\xa9", .held = false },
        .{ .data = "/wor", .held = false },
        .{ .data = "/work", .held = true },
        .{ .data = "x\x00/work\x00", .held = true },
        .{ .data = "-I/work/inc", .held = true },
        .{ .data = "PWD=\"/work\"", .held = true },
        .{ .data = "/work:/usr/lib", .held = true },
        .{ .data = "runtime/worker.rs then /work/x", .held = true },
    };
    for (cases) |c| {
        try put(tmp.dir, "f", c.data);
        const f = try tmp.dir.openFile("f", .{});
        defer f.close();
        t.expectEqual(c.held, try L.fileHoldsDir(f, "/work", &small)) catch |e| {
            std.debug.print("data: {s}\n", .{c.data});
            return e;
        };
    }
}

test "fileHoldsDir: a match that ends a read is decided by the next read's first byte" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // An 8-byte buffer: the first read is `xxx/work`, the match's next byte
    // is the first of the second read.
    var small: [8]u8 = undefined;
    try put(tmp.dir, "e", "xxx/worker");
    const e = try tmp.dir.openFile("e", .{});
    defer e.close();
    try t.expect(!try L.fileHoldsDir(e, "/work", &small));
    try put(tmp.dir, "s", "xxx/work/x");
    const s = try tmp.dir.openFile("s", .{});
    defer s.close();
    try t.expect(try L.fileHoldsDir(s, "/work", &small));
    // The match ends the read and the file: it counts.
    try put(tmp.dir, "z", "xxx/work");
    const z = try tmp.dir.openFile("z", .{});
    defer z.close();
    try t.expect(try L.fileHoldsDir(z, "/work", &small));
}

test "continuesName: name bytes and the bytes that end a name" {
    for ("az09AZ._-+~@\x80\xff") |c| try t.expect(L.continuesName(c));
    for ("/\x00\"' =:;,\n\t") |c| try t.expect(!L.continuesName(c));
}

test "checkOutput: missing, empty, clean, a near miss, and one holding the working directory" {
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
    // A source path whose name starts with the working directory's bytes.
    try put(tmp.dir, "near", "src/runtime/worker.rs");
    const near = try at(root, "near");
    defer t.allocator.free(near);
    try t.expectEqual(L.OutputCheck.ok, try L.checkOutput(near, "/work", &buf));
    // A directory is neither empty nor read.
    try tmp.dir.makeDir("adir");
    try put(tmp.dir, "adir/f", "/work");
    const adir = try at(root, "adir");
    defer t.allocator.free(adir);
    try t.expectEqual(L.OutputCheck.ok, try L.checkOutput(adir, "/work", &buf));
}
