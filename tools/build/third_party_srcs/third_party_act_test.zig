//! Unit tests of third_party_act's pure parts. Its process behaviour (the copy,
//! the refusal, the exit statuses) is tests//functional/third_party_act; every
//! botocore_model of the repository runs through it too.
const std = @import("std");
const T = @import("third_party_act.zig");
const U = @import("act_util");
const tartest = @import("node_tartest");
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

fn strs(a: std.mem.Allocator, ops: []const T.Op) ![]u8 {
    var b = std.ArrayList(u8).init(a);
    for (ops) |op| try b.writer().print("{c}{s}\n", .{ op.sign, op.line });
    return b.toOwnedSlice();
}

fn diffText(a: std.mem.Allocator, have: []const u8, got: []const u8) ![]u8 {
    return strs(a, try T.diffOps(a, try T.lines(a, have), try T.lines(a, got)));
}

test "lines: as diff sees them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(usize, 2), (try T.lines(a, "a\nb\n")).len);
    try t.expectEqual(@as(usize, 2), (try T.lines(a, "a\nb")).len);
    try t.expectEqual(@as(usize, 0), (try T.lines(a, "")).len);
    try t.expectEqual(@as(usize, 1), (try T.lines(a, "\n")).len);
    try t.expectEqualStrings("", (try T.lines(a, "\n"))[0]);
    try t.expectEqual(@as(usize, 3), (try T.lines(a, "a\n\nb\n")).len);
}

test "diffOps: what changed, removed lines before added ones within a run, in file order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("", try diffText(a, "a\nb\nc\n", "a\nb\nc\n"));
    try t.expectEqualStrings("-b\n+B\n", try diffText(a, "a\nb\nc\n", "a\nB\nc\n"));
    try t.expectEqualStrings("+x\n", try diffText(a, "a\nb\n", "a\nx\nb\n"));
    try t.expectEqualStrings("-b\n", try diffText(a, "a\nb\nc\n", "a\nc\n"));
    try t.expectEqualStrings("-a\n-b\n+x\n+y\n+z\n", try diffText(a, "a\nb\nc\n", "x\ny\nz\nc\n"));
    // two separate runs, each removed-then-added
    try t.expectEqualStrings("-b\n+B\n-d\n+D\n", try diffText(a, "a\nb\nc\nd\ne\n", "a\nB\nc\nD\ne\n"));
    // from nothing, and to nothing
    try t.expectEqualStrings("+a\n+b\n", try diffText(a, "", "a\nb\n"));
    try t.expectEqualStrings("-a\n-b\n", try diffText(a, "a\nb\n", ""));
    // a moved block is a removal and an addition
    try t.expectEqualStrings("+c\n-c\n", try diffText(a, "a\nb\nc\n", "c\na\nb\n"));
}

test "diffOps: a middle too large to match line by line is all removed, then all added" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const n: usize = 4100;
    const have = try a.alloc([]const u8, n + 2);
    const got = try a.alloc([]const u8, n + 2);
    have[0] = "top";
    got[0] = "top";
    have[n + 1] = "end";
    got[n + 1] = "end";
    for (1..n + 1) |i| {
        have[i] = try std.fmt.allocPrint(a, "h{d}", .{i});
        got[i] = try std.fmt.allocPrint(a, "g{d}", .{i});
    }
    const ops = try T.diffOps(a, have, got);
    try t.expectEqual(2 * n, ops.len);
    try t.expectEqual(@as(u8, '-'), ops[0].sign);
    try t.expectEqual(@as(u8, '+'), ops[n].sign);
}

test "shown: only changed lines of text, not the ones that begin with - or +, the first N" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = [_]T.Op{
        .{ .sign = '-', .line = "old" },
        .{ .sign = '-', .line = "" },
        .{ .sign = '-', .line = "-dash" },
        .{ .sign = '+', .line = "+plus" },
        .{ .sign = '+', .line = "new" },
        .{ .sign = '+', .line = "x" },
    };
    const rows = try T.shown(a, &ops, 6);
    try t.expectEqual(@as(usize, 3), rows.len);
    try t.expectEqualStrings("-old", rows[0]);
    try t.expectEqualStrings("+new", rows[1]);
    try t.expectEqualStrings("+x", rows[2]);
    const two = try T.shown(a, &ops, 2);
    try t.expectEqual(@as(usize, 2), two.len);
}

test "gunzip: the file back, byte for byte" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const payload = try tartest.tar(a, &.{.{ .name = "top/a.txt", .data = "alpha\n" }});
    try U.writeAll(tmp.dir, "a.tar.gz", try tartest.gzip(a, payload));
    try T.gunzip(tmp.dir, "a.tar.gz", "a.tar");
    try t.expectEqualSlices(u8, payload, try tmp.dir.readFileAlloc(a, "a.tar", 1 << 20));
    try U.writeAll(tmp.dir, "bad.gz", "not gzip at all");
    try t.expectError(error.BadGzipHeader, T.gunzip(tmp.dir, "bad.gz", "bad.tar"));
}
