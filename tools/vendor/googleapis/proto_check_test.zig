//! Unit tests of proto_check.zig: reading the file names out of a descriptor set,
//! and the comparison of a tree with a closure. The check over real protoc is
//! proto_check_selftest (BUCK): a tree it accepts and one change per case it must
//! refuse.
const std = @import("std");
const P = @import("proto_check.zig");
const t = std.testing;

fn varint(out: *std.ArrayList(u8), v: usize) !void {
    var x = v;
    while (x >= 0x80) {
        try out.append(@intCast((x & 0x7f) | 0x80));
        x >>= 7;
    }
    try out.append(@intCast(x));
}

/// A FileDescriptorProto holding `name` (field 1) and a package (field 2).
fn file(a: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8) !void {
    var body = std.ArrayList(u8).init(a);
    try body.append(0x0a);
    try varint(&body, name.len);
    try body.appendSlice(name);
    try body.append(0x12);
    try varint(&body, 3);
    try body.appendSlice("pkg");
    try out.append(0x0a);
    try varint(out, body.items.len);
    try out.appendSlice(body.items);
}

test "setNames: the name of each file, in order; other fields are skipped" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var set = std.ArrayList(u8).init(a);
    try file(a, &set, "google/protobuf/timestamp.proto");
    try file(a, &set, "fix/dep.proto");
    // An unknown varint field (2: 7) and a fixed32 (3) between files.
    try set.appendSlice(&.{ 0x10, 0x07, 0x1d, 1, 2, 3, 4 });
    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    try file(a, &set, &long);
    const ns = try P.setNames(a, set.items);
    try t.expectEqual(@as(usize, 3), ns.len);
    try t.expectEqualStrings("google/protobuf/timestamp.proto", ns[0]);
    try t.expectEqualStrings("fix/dep.proto", ns[1]);
    try t.expectEqual(@as(usize, 200), ns[2].len);
    try t.expectEqual(@as(usize, 0), (try P.setNames(a, "")).len);
}

test "setNames: a truncated set is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var set = std.ArrayList(u8).init(a);
    try file(a, &set, "fix/dep.proto");
    try t.expectError(error.BadDescriptorSet, P.setNames(a, set.items[0 .. set.items.len - 2]));
    try t.expectError(error.BadDescriptorSet, P.setNames(a, &.{0x0b}));
}

test "mismatch: a closure file the tree lacks" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tree = [_][]const u8{ "a.proto", "b.proto" };
    try t.expect((try P.mismatch(a, &tree, &.{ "a.proto", "b.proto" })) == null);
    try t.expectEqualStrings("c.proto is in the import closure but not in the tree", (try P.mismatch(a, &tree, &.{ "a.proto", "c.proto" })).?);
}

test "listFiles: files and links, sorted, nested paths relative" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("z/y");
    try tmp.dir.writeFile("z/y/f.proto", "x");
    try tmp.dir.writeFile("a.proto", "x");
    try tmp.dir.makePath("empty");
    const fs = try P.listFiles(a, tmp.dir);
    try t.expectEqual(@as(usize, 2), fs.len);
    try t.expectEqualStrings("a.proto", fs[0]);
    try t.expectEqualStrings("z/y/f.proto", fs[1]);
}
