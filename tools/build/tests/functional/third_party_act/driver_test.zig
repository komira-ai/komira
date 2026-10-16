//! The process behaviour of `third_party_act` (tools/build/third_party_srcs/
//! third_party_act.zig). Each case says the defect it would catch.
const std = @import("std");
const kit = @import("driver_kit");
const tt = @import("node_tartest");
const t = std.testing;
const has = kit.has;

fn newCtx(name: []const u8) !kit.Ctx {
    return kit.Ctx.init(name, "THIRD_PARTY_ACT");
}

fn sha(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

test "botocore-model: the model is copied, unchanged, once its sha256 is the pinned one" {
    var c = try newCtx("botocore_ok");
    defer c.deinit();
    const model = "{\"version\": \"2.0\", \"metadata\": {\"serviceId\": \"X\"}}\n";
    try c.write("in/service-2.json", model, 0o644);
    const want = sha(model);
    const r = try c.run(&.{ "botocore-model", "--src", "in/service-2.json", "--sha256", &want, "--out", "out/botocore/data/x/2020-01-01/service-2.json" }, &.{});
    if (r.code != 0) std.debug.print("[third_party_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings(model, try c.read("out/botocore/data/x/2020-01-01/service-2.json"));
}

test "botocore-model: other bytes are refused naming both digests, and nothing is written" {
    var c = try newCtx("botocore_bad");
    defer c.deinit();
    try c.write("in/service-2.json", "one byte more\n", 0o644);
    const pinned = sha("one byte more");
    const got = sha("one byte more\n");
    const r = try c.run(&.{ "botocore-model", "--src", "in/service-2.json", "--sha256", &pinned, "--out", "out.json" }, &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    const want = try std.fmt.allocPrint(c.alloc(), "botocore_model: in/service-2.json has sha256 {s}; models.bzl says {s}\n", .{ &got, &pinned });
    try t.expectEqualStrings(want, r.stderr);
    try t.expect(!c.exists("out.json"));
    // a missing model, missing flags, an unknown flag and an unknown subcommand
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "botocore-model", "--src", "nope.json", "--sha256", &pinned, "--out", "o.json" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "botocore-model", "--src", "x" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "botocore-model", "--bogus", "x" }, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"frobnicate"}, &.{})).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{}, &.{})).code);
}

// ---- drift --------------------------------------------------------------------

fn driftArgs() []const []const u8 {
    return &.{ "drift", "--generated", "generated.bzl", "--committed", "src/committed.bzl", "--regenerate", "./buck2 build //p:srcs_gen --out p/committed.bzl" };
}

test "drift: the same bytes pass and say so" {
    var c = try newCtx("drift_same");
    defer c.deinit();
    try c.write("generated.bzl", "A = 1\nB = 2\n", 0o644);
    try c.write("src/committed.bzl", "A = 1\nB = 2\n", 0o644);
    const r = try c.run(driftArgs(), &.{});
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("third_party_srcs: src/committed.bzl matches the archive\n", r.stdout);
}

test "drift: a difference is red, names the first lines (- committed, + generated) and how to regenerate" {
    var c = try newCtx("drift_diff");
    defer c.deinit();
    try c.write("src/committed.bzl", "keep1\nold_a\nkeep2\nold_b\nkeep3\n", 0o644);
    try c.write("generated.bzl", "keep1\nnew_a\nkeep2\nnew_b\nkeep3\n", 0o644);
    const r = try c.run(driftArgs(), &.{});
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expectEqualStrings("third_party_srcs: src/committed.bzl differs from what the archive gives (- committed, + generated):\n-old_a\n+new_a\n-old_b\n+new_b\nregenerate: ./buck2 build //p:srcs_gen --out p/committed.bzl\n", r.stdout);
    // only the first six changed lines are shown
    var many = std.ArrayList(u8).init(c.alloc());
    var other = std.ArrayList(u8).init(c.alloc());
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try many.writer().print("same{d}\nhave{d}\n", .{ i, i });
        try other.writer().print("same{d}\ngot{d}\n", .{ i, i });
    }
    try c.write("src/committed.bzl", many.items, 0o644);
    try c.write("generated.bzl", other.items, 0o644);
    const r2 = try c.run(driftArgs(), &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expectEqualStrings("third_party_srcs: src/committed.bzl differs from what the archive gives (- committed, + generated):\n-have0\n+got0\n-have1\n+got1\n-have2\n+got2\nregenerate: ./buck2 build //p:srcs_gen --out p/committed.bzl\n", r2.stdout);
    // a missing file is a failure of the tool's own
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "drift", "--generated", "nope", "--committed", "src/committed.bzl", "--regenerate", "x" }, &.{})).code);
}

// ---- srcs-gen -----------------------------------------------------------------

fn genArgs(c: *kit.Ctx, library: []const u8) ![]const []const u8 {
    return c.alloc().dupe([]const u8, &.{
        "srcs-gen", "--archive", "a.tar.gz", "--out", "srcs.bzl", "--gen", try c.env("FAKE_GEN"), "--library", library,
        "--gen-label", "//p:srcs_gen", "--drift-label", "//p:srcs_drift", "--committed-path", "p/srcs.bzl",
    });
}

test "srcs-gen: the archive is decompressed into the scratch directory and handed to the generator with its labels; the scratch goes" {
    var c = try newCtx("gen_ok");
    defer c.deinit();
    const tar = try tt.tar(c.alloc(), &.{ .{ .name = "lib-1.0/CMakeLists.txt", .data = "project(x)\n" }, .{ .name = "lib-1.0/a.c", .data = "int a;\n" } });
    try c.write("a.tar.gz", try tt.gzip(c.alloc(), tar), 0o644);
    const scratch = try c.path("scratch");
    const r = try c.run(try genArgs(&c, "aws-lc"), &.{.{ "BUCK_SCRATCH_PATH", scratch }});
    if (r.code != 0) std.debug.print("[third_party_act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 0), r.code);
    const want = try std.fmt.allocPrint(c.alloc(), "library=aws-lc\ntar_bytes={d}\ntar_name=lib-1.0/CMakeLists.txt\ngen_label=//p:srcs_gen\ndrift_label=//p:srcs_drift\ncommitted=p/srcs.bzl\ntar_path_is_absolute=yes\n", .{tar.len});
    try t.expectEqualStrings(want, try c.read("srcs.bzl"));
    try t.expect(!c.exists("scratch/komira"));
}

test "srcs-gen: the generator's status is the action's; an archive that is no gzip fails; usage errors exit 2" {
    var c = try newCtx("gen_bad");
    defer c.deinit();
    try c.write("a.tar.gz", try tt.gzip(c.alloc(), try tt.tar(c.alloc(), &.{.{ .name = "t/f", .data = "x" }})), 0o644);
    const r = try c.run(try genArgs(&c, "fail3"), &.{});
    try t.expectEqual(@as(u8, 3), r.code);
    try t.expect(!c.exists("srcs.bzl"));
    try c.write("a.tar.gz", "this is not gzip", 0o644);
    const r2 = try c.run(try genArgs(&c, "aws-lc"), &.{});
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(has(r2.stderr, "gzip: a.tar.gz: "));
    try t.expect(!c.exists("srcs.bzl"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "srcs-gen", "--archive", "a.tar.gz" }, &.{})).code);
}
