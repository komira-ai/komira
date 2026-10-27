//! The process behaviour of `git_check` (third_party/git/git_check.zig) over a
//! stand-in for git and git-lfs (fake_git.zig) that is made to get one answer
//! wrong at a time. Each case says the defect it would catch.
const std = @import("std");
const kit = @import("driver_kit");
const t = std.testing;
const has = kit.has;

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "GIT_CHECK");
}

const files = [_][]const u8{
    "libexec/git-core/git-remote-http",
    "libexec/git-core/git-upload-pack",
    "libexec/git-core/git-receive-pack",
    "share/licenses/NOTICE",
    "share/licenses/git/COPYING",
    "share/licenses/git/LGPL-2.1",
    "share/licenses/curl/COPYING",
    "share/licenses/zlib/LICENSE",
};

/// A distribution of stand-ins in this case's directory, to be got wrong as
/// `mode` says, and the git-lfs beside it.
fn lay(c: *kit.Ctx, mode: []const u8) !void {
    try c.mkdir("dist/bin");
    try c.mkdir("lfs");
    try std.fs.cwd().copyFile(try c.env("FAKE_GIT"), std.fs.cwd(), try c.path("dist/bin/git"), .{});
    try std.fs.cwd().copyFile(try c.env("FAKE_GIT"), std.fs.cwd(), try c.path("lfs/git-lfs"), .{});
    for (files) |f| try c.write(try std.fmt.allocPrint(c.alloc(), "dist/{s}", .{f}), "x", 0o644);
    try c.write("dist/MODE", mode, 0o644);
}

fn args(c: *kit.Ctx, lfs_version: []const u8) ![]const []const u8 {
    return c.alloc().dupe([]const u8, &.{
        "--busybox", try c.env("BUSYBOX"), "--report", "report", "--git", "dist", "--lfs", "lfs/git-lfs", "--version", "2.56.0", "--lfs-version", lfs_version,
    });
}

fn runMode(c: *kit.Ctx, mode: []const u8) !kit.Result {
    try lay(c, mode);
    return c.run(try args(c, "3.8.0"), &.{.{ "BUCK_SCRATCH_PATH", try c.path("scratch") }});
}

test "a git that answers every check right: 8 checks, the report, the scratch directory gone" {
    var c = try newCtx("ok");
    defer c.deinit();
    const r = try runMode(&c, "ok");
    if (r.code != 0) std.debug.print("[git_check stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(has(r.stderr, "git_check GREEN: 8 checks\n"));
    try t.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"git_check: 8 checks passed\"}}\n", try c.read("report/validation.json"));
    try t.expect(!c.exists("scratch/git_check"));
}

test "each wrong answer is red, naming it (exit 1), and writes no report" {
    var c = try newCtx("red");
    defer c.deinit();
    const Case = struct { mode: []const u8, want: []const u8 };
    const cases = [_]Case{
        .{ .mode = "version", .want = "git_check RED: git --version printed 'git version 9.9.9', want 'git version 2.56.0'" },
        .{ .mode = "execpath", .want = "git_check RED: git --exec-path is '/tmp', not the distribution's libexec/git-core" },
        .{ .mode = "hash", .want = "git_check RED: hash-object of 'hello\\n' is 0000000000000000000000000000000000000000, want ce013625030ba8dba906f756967f9e9ca394464a" },
        .{ .mode = "tree", .want = "git_check RED: the empty tree is 1111111111111111111111111111111111111111, want 4b825dc642cb6eb9a060e54bf8d69288fbee4904" },
        .{ .mode = "commit", .want = "git_check RED: commit-tree gave 2222222222222222222222222222222222222222, want " },
        .{ .mode = "env", .want = "git_check RED: git commit-tree failed" },
        .{ .mode = "clone", .want = "git_check RED: git clone over file:// failed" },
        .{ .mode = "push", .want = "git_check RED: git push over file:// failed" },
        .{ .mode = "ls_ok", .want = "git_check RED: ls-remote to a closed port succeeded" },
        .{ .mode = "ls_text", .want = "git_check RED: ls-remote http:// printed 'fatal: unable to access 'http://127.0.0.1:1/r/': Failed to connect to 127.0.0.1:1 after <ms> ms: Connection refused', want " },
        .{ .mode = "https_text", .want = "git_check RED: ls-remote https:// printed 'fatal: unable to access 'https://127.0.0.1:1/r/': Protocol \"https\" is not allowed', want " },
        .{ .mode = "lfs_via_git", .want = "git_check RED: git lfs version printed 'git-lfs/3.8.0 (something else)', want 'git-lfs/3.8.0 (GitHub; linux amd64; go 1.25.0)'" },
        .{ .mode = "decoy", .want = "git_check RED: a git from PATH ran instead of the distribution's: git-upload-pack --stateless-rpc " },
    };
    for (cases) |cs| {
        c.dir = try std.fmt.allocPrint(c.alloc(), "{s}_{s}", .{ c.dir, cs.mode });
        try std.fs.cwd().makePath(c.dir);
        const r = try runMode(&c, cs.mode);
        if (r.code != 1 or !has(r.stderr, cs.want)) std.debug.print("[{s}] code {d}: {s}\n", .{ cs.mode, r.code, r.stderr });
        try t.expectEqual(@as(u8, 1), r.code);
        try t.expect(has(r.stderr, cs.want));
        try t.expect(!c.exists("report/validation.json"));
        c.dir = c.dir[0 .. c.dir.len - cs.mode.len - 1];
    }
}

test "the distribution's files: a missing or empty file, and a shared library" {
    var c = try newCtx("files");
    defer c.deinit();
    try lay(&c, "ok");
    for (files) |f| {
        const p = try std.fmt.allocPrint(c.alloc(), "dist/{s}", .{f});
        try c.write(p, "", 0o644);
        const r = try c.run(try args(&c, "3.8.0"), &.{});
        try t.expectEqual(@as(u8, 1), r.code);
        const want = try std.fmt.allocPrint(c.alloc(), "git_check RED: the distribution has no {s}", .{f});
        if (!has(r.stderr, want)) std.debug.print("[{s}] {s}\n", .{ f, r.stderr });
        try t.expect(has(r.stderr, want));
        try c.write(p, "x", 0o644);
    }
    try std.fs.cwd().deleteFile(try c.path("dist/share/licenses/zlib/LICENSE"));
    try t.expect(has((try c.run(try args(&c, "3.8.0"), &.{})).stderr, "the distribution has no share/licenses/zlib/LICENSE"));
    try c.write("dist/share/licenses/zlib/LICENSE", "x", 0o644);
    try c.write("dist/lib/libz.so.1", "z", 0o644);
    const so = try c.run(try args(&c, "3.8.0"), &.{});
    try t.expectEqual(@as(u8, 1), so.code);
    try t.expect(has(so.stderr, "git_check RED: the distribution holds shared libraries: "));
    try t.expect(has(so.stderr, "/dist/lib/libz.so.1"));
}

test "git-lfs: a version line that is not the pinned one is red; usage errors exit 2" {
    var c = try newCtx("lfs");
    defer c.deinit();
    try lay(&c, "ok");
    const r = try c.run(try args(&c, "3.9.0"), &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.stderr, "git_check RED: git-lfs version printed 'git-lfs/3.8.0 (GitHub; linux amd64; go 1.25.0)', want 'git-lfs/3.9.0 ...'"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "--git", "dist" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"--bogus"}, &.{})).code);
}

test "run under a decoy's name the program records itself and exits 97" {
    var c = try newCtx("decoy");
    defer c.deinit();
    try c.mkdir("t/decoy");
    try std.fs.cwd().symLink(c.tool, try c.path("t/decoy/git-upload-pack"), .{});
    const r = try c.runTool(try c.path("t/decoy/git-upload-pack"), &.{ "--stateless-rpc", "x" }, &.{});
    try t.expectEqual(@as(u8, 97), r.code);
    try t.expectEqualStrings("git-upload-pack --stateless-rpc x\n", try c.read("t/decoy_ran"));
    // (Run by name through PATH, it records in the first PATH entry that holds it:
    // the `decoy` case above has the stand-in git do that, and decoyDir is unit-tested.)
}
