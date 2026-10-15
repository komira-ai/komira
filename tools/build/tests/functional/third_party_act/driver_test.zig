//! The process behaviour of `third_party_act` (tools/build/third_party_srcs/
//! third_party_act.zig). Each case says the defect it would catch.
const std = @import("std");
const kit = @import("driver_kit");
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
