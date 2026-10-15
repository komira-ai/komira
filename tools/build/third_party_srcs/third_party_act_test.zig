//! Unit tests of third_party_act's pure parts. Its process behaviour (the copy,
//! the refusal, the exit statuses) is tests//functional/third_party_act; every
//! botocore_model of the repository runs through it too.
const std = @import("std");
const T = @import("third_party_act.zig");
const U = @import("act_util");
const t = std.testing;

test "modelRefusal: the pinned digest passes; any other bytes name both digests" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = "{\"metadata\": {}}\n";
    const want = U.sha256Hex(data);
    try t.expect((try T.modelRefusal(a, "m/service-2.json", data, &want)) == null);
    const other = U.sha256Hex("other");
    const text = (try T.modelRefusal(a, "m/service-2.json", data, &other)).?;
    const expected = try std.fmt.allocPrint(a, "botocore_model: m/service-2.json has sha256 {s}; models.bzl says {s}\n", .{ &want, &other });
    try t.expectEqualStrings(expected, text);
    // one byte more, one byte less, and the empty file are not the pinned bytes
    try t.expect((try T.modelRefusal(a, "m", "{\"metadata\": {}}\n ", &want)) != null);
    try t.expect((try T.modelRefusal(a, "m", data[0 .. data.len - 1], &want)) != null);
    try t.expect((try T.modelRefusal(a, "m", "", &want)) != null);
    // a digest in upper case is not the digest
    var upper: [64]u8 = undefined;
    _ = std.ascii.upperString(&upper, &want);
    try t.expect((try T.modelRefusal(a, "m", data, &upper)) != null);
}
