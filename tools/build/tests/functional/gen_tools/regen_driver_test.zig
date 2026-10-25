//! The process behaviour of `regen` (tools/build/gen/regen.zig), over a stand-in
//! buck2 (fake_buck2.zig) that answers from files and records its calls: which
//! buck2 commands regen runs, what it leaves in the committed directory, that a
//! second run changes nothing, and each way it refuses.
const std = @import("std");
const kit = @import("driver_kit");
const t = std.testing;
const has = kit.has;

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "REGEN");
}

/// A cell at `cell/`, a generator output at `out/` (three files) and the answers
/// buck2 gives for the library komira//src/svc:svc (`<name>_fresh` and `<name>_gen`).
fn rig(c: *kit.Ctx) !void {
    try c.write("out/__init__.mojo", "# @generated\n", 0o644);
    try c.write("out/svc.mojo", "struct A:\n    pass\n", 0o644);
    try c.write("out/_layout_probe.mojo", "probe\n", 0o644);
    try c.mkdir("cell/src/svc");
    try c.write("fake/uquery.json",
        \\{"komira//src/svc:svc_fresh":{"buck.type":"gen_fresh","committed_dir":"generated/svc","gen":"komira//src/svc:svc_gen"}}
    , 0o644);
    try c.write("fake/build.txt", try std.fmt.allocPrint(c.alloc(), "komira//src/svc:svc_gen {s}\n", .{try c.path("out")}), 0o644);
    try c.write("fake/cell_root", try std.fmt.allocPrint(c.alloc(), "{s}\n", .{try c.path("cell")}), 0o644);
}

fn runRegen(c: *kit.Ctx, targets: []const []const u8) !kit.Result {
    var args = std.ArrayList([]const u8).empty;
    try args.appendSlice(c.alloc(), &.{ "--buck2", try c.env("FAKE_BUCK2") });
    try args.appendSlice(c.alloc(), targets);
    return c.run(args.items, &.{});
}

const svc = "komira//src/svc:svc";

test "regen of a library builds its generation target once and fills the committed directory with the output" {
    var c = try newCtx("fills");
    defer c.deinit();
    try rig(&c);
    const r = try runRegen(&c, &.{svc});
    if (r.code != 0) std.debug.print("[regen stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("# @generated\n", try c.read("cell/src/svc/generated/svc/__init__.mojo"));
    try t.expectEqualStrings("struct A:\n    pass\n", try c.read("cell/src/svc/generated/svc/svc.mojo"));
    try t.expectEqualStrings("probe\n", try c.read("cell/src/svc/generated/svc/_layout_probe.mojo"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try c.mode("cell/src/svc/generated/svc/svc.mojo"));
    try t.expect(has(r.stderr, "komira//src/svc:svc_fresh: src/svc/generated/svc/: wrote 3, removed 0, unchanged 0\n"));
    // The commands: the query for the library's fresh target, one build of the
    // generation target with the paths printed, and the cell's root.
    try t.expectEqualStrings(
        "uquery --json -a committed_dir -a gen kind('^gen_fresh$', komira//src/svc:svc_fresh)\n" ++
            "build --show-full-output komira//src/svc:svc_gen\n" ++
            "audit cell --paths-only komira\n",
        try c.read("calls.log"),
    );
}

test "a second regen changes nothing: no file is written, none removed, and the files are the same files" {
    var c = try newCtx("idempotent");
    defer c.deinit();
    try rig(&c);
    try t.expectEqual(@as(u8, 0), (try runRegen(&c, &.{svc})).code);
    const before = try std.fs.cwd().statFile(try c.path("cell/src/svc/generated/svc/svc.mojo"));
    const r = try runRegen(&c, &.{svc});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(has(r.stderr, "wrote 0, removed 0, unchanged 3\n"));
    const after = try std.fs.cwd().statFile(try c.path("cell/src/svc/generated/svc/svc.mojo"));
    try t.expectEqual(before.inode, after.inode);
    try t.expectEqual(before.mtime, after.mtime);
}

test "regen repairs a hand edit, restores a deleted file and removes a file the generator no longer writes" {
    var c = try newCtx("repairs");
    defer c.deinit();
    try rig(&c);
    try t.expectEqual(@as(u8, 0), (try runRegen(&c, &.{svc})).code);
    try c.write("cell/src/svc/generated/svc/svc.mojo", "hand edited\n", 0o644);
    try std.fs.cwd().deleteFile(try c.path("cell/src/svc/generated/svc/_layout_probe.mojo"));
    try c.write("cell/src/svc/generated/svc/old_module.mojo", "old\n", 0o644);
    try c.write("cell/src/svc/generated/svc/nested/deep.mojo", "old\n", 0o644);
    const r = try runRegen(&c, &.{svc});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expect(has(r.stderr, "wrote 2, removed 2, unchanged 1\n"));
    try t.expectEqualStrings("struct A:\n    pass\n", try c.read("cell/src/svc/generated/svc/svc.mojo"));
    try t.expectEqualStrings("probe\n", try c.read("cell/src/svc/generated/svc/_layout_probe.mojo"));
    try t.expect(!c.exists("cell/src/svc/generated/svc/old_module.mojo"));
    try t.expect(!c.exists("cell/src/svc/generated/svc/nested"));
}

test "`all` queries every generated library of the cell komira; a package is queried as itself" {
    var c = try newCtx("patterns");
    defer c.deinit();
    try rig(&c);
    try t.expectEqual(@as(u8, 0), (try runRegen(&c, &.{"all"})).code);
    try t.expect(has(try c.read("calls.log"), "kind('^gen_fresh$', komira//...)\n"));
    try std.fs.cwd().deleteFile(try c.path("calls.log"));
    try t.expectEqual(@as(u8, 0), (try runRegen(&c, &.{"komira//src/svc:"})).code);
    try t.expect(has(try c.read("calls.log"), "kind('^gen_fresh$', komira//src/svc:)\n"));
}

test "a target that has no fresh target (a library still in the ledger, or not generated) is refused, and nothing is built" {
    var c = try newCtx("no_match");
    defer c.deinit();
    try rig(&c);
    try c.write("fake/uquery.json", "{}", 0o644);
    const r = try runRegen(&c, &.{"komira//src/other:other"});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(has(r.stderr, "komira//src/other:other names no generated library with committed sources"));
    try t.expect(has(r.stderr, "tools/build/gen/transition.bzl"));
    try t.expect(!has(try c.read("calls.log"), "build"));
    try t.expect(!c.exists("cell/src/svc/generated"));
}

test "a failed build leaves the committed directory as it was and exits 1" {
    var c = try newCtx("build_fails");
    defer c.deinit();
    try rig(&c);
    try c.write("cell/src/svc/generated/svc/svc.mojo", "committed\n", 0o644);
    try c.write("fake/build_fails", "", 0o644);
    const r = try runRegen(&c, &.{svc});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("committed\n", try c.read("cell/src/svc/generated/svc/svc.mojo"));
}

test "a failed query exits 1 and builds nothing" {
    var c = try newCtx("query_fails");
    defer c.deinit();
    try rig(&c);
    try c.write("fake/uquery_fails", "", 0o644);
    const r = try runRegen(&c, &.{svc});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(!has(try c.read("calls.log"), "build"));
}

test "usage errors exit 2: no target, an argument that is not a label, an unknown flag" {
    var c = try newCtx("usage");
    defer c.deinit();
    try rig(&c);
    const r1 = try runRegen(&c, &.{});
    try t.expectEqual(@as(u8, 2), r1.code);
    try t.expect(has(r1.stderr, "usage: regen"));
    const r2 = try runRegen(&c, &.{"komira_aws_sqs"});
    try t.expectEqual(@as(u8, 2), r2.code);
    try t.expect(has(r2.stderr, "is not a target label"));
    const r3 = try c.run(&.{ "--bogus", svc }, &.{});
    try t.expectEqual(@as(u8, 2), r3.code);
    try t.expect(!c.exists("calls.log"));
}
