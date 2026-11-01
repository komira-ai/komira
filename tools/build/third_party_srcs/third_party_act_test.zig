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
    var b = std.ArrayList(u8).empty;
    for (ops) |op| try b.writer(a).print("{c}{s}\n", .{ op.sign, op.line });
    return b.toOwnedSlice(a);
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

const sample_bzl =
    \\# Generated by x; do not edit.
    \\
    \\# A comment with "quotes" in it.
    \\ASM = [
    \\    "src/a.S",
    \\    "src/b.S",
    \\]
    \\
    \\EXPORTED_HEADERS = {
    \\    "lib/x.h": "include/x.h",
    \\}
    \\EXPORTED_INCLUDES = [
    \\    "include",
    \\]
    \\EMPTY = [
    \\]
    \\PROBE_GLOBAL_FLAGS = "-Wall"
    \\FILES = [
    \\    "include/x.h",
    \\    "src/a.S",
    \\    "src/b.S",
    \\]
    \\
;

fn allFiles() []const []const u8 {
    return &.{ "include/x.h", "src/a.S", "src/b.S", "src/unlisted.c" };
}

test "parseTables: lists and dict values, by name, in file order; one-line values and comments are not tables" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tables = try T.parseTables(a, sample_bzl);
    try t.expectEqual(@as(usize, 5), tables.len);
    try t.expectEqualStrings("ASM", tables[0].name);
    try t.expectEqual(@as(usize, 2), tables[0].values.len);
    try t.expectEqualStrings("src/b.S", tables[0].values[1]);
    try t.expectEqualStrings("EXPORTED_HEADERS", tables[1].name);
    try t.expectEqual(@as(usize, 1), tables[1].values.len);
    try t.expectEqualStrings("include/x.h", tables[1].values[0]);
    try t.expectEqual(@as(usize, 0), tables[3].values.len);
    try t.expectEqualStrings("FILES", tables[4].name);
    try t.expectError(error.UnclosedTable, T.parseTables(a, "X = [\n    \"a\",\n"));
}

test "archiveFiles: the regular files below the top directory, top dropped; directories and links are not files" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tartest.tar(a, &.{
        .{ .name = "top/", .kind = '5', .mode = 0o755 },
        .{ .name = "top/include/", .kind = '5', .mode = 0o755 },
        .{ .name = "top/include/x.h", .data = "H" },
        .{ .name = "top/src/a.S", .data = "A" },
        .{ .name = "top/src/link", .kind = '2', .link = "a.S" },
    });
    const names = try T.archiveFiles(a, tar);
    try t.expectEqual(@as(usize, 2), names.len);
    try t.expectEqualStrings("include/x.h", names[0]);
    try t.expectEqualStrings("src/a.S", names[1]);
}

fn problemsOf(a: std.mem.Allocator, text: []const u8, require: []const []const u8) ![]const []const u8 {
    return T.filesProblems(a, text, allFiles(), require);
}

test "filesProblems: a file list that names only archive files, all in FILES, has none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(usize, 0), (try problemsOf(a, sample_bzl, &.{ "ASM", "FILES" })).len);
}

test "filesProblems: a listed file the archive lacks, a list entry outside FILES, a bad include dir" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing = try std.mem.replaceOwned(u8, a, sample_bzl, "\"src/b.S\",\n]\n\nEXPORTED", "\"src/gone.S\",\n]\n\nEXPORTED");
    const p1 = try problemsOf(a, missing, &.{});
    try t.expectEqual(@as(usize, 1), p1.len);
    try t.expectEqualStrings("ASM: src/gone.S is not in the archive", p1[0]);
    // present in the archive, absent from FILES
    const outside = try std.mem.replaceOwned(u8, a, sample_bzl, "\"src/b.S\",\n]\n\nEXPORTED", "\"src/unlisted.c\",\n]\n\nEXPORTED");
    const p2 = try problemsOf(a, outside, &.{});
    try t.expectEqual(@as(usize, 1), p2.len);
    try t.expectEqualStrings("ASM: src/unlisted.c is not in FILES", p2[0]);
    // an include directory with no file under it
    const dir = try std.mem.replaceOwned(u8, a, sample_bzl, "\"include\",\n]", "\"nowhere\",\n]");
    const p3 = try problemsOf(a, dir, &.{});
    try t.expectEqual(@as(usize, 1), p3.len);
    try t.expectEqualStrings("EXPORTED_INCLUDES: nowhere holds no file of the archive", p3[0]);
    // a name that is only a prefix of a directory is not that directory
    const prefix = try std.mem.replaceOwned(u8, a, sample_bzl, "\"include\",\n]", "\"inc\",\n]");
    try t.expectEqual(@as(usize, 1), (try problemsOf(a, prefix, &.{})).len);
}

test "filesProblems: FILES must be sorted without duplicates, and must exist; a required list must be there and not empty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unsorted = try std.mem.replaceOwned(u8, a, sample_bzl, "    \"include/x.h\",\n    \"src/a.S\",\n    \"src/b.S\",\n]\n", "    \"include/x.h\",\n    \"src/b.S\",\n    \"src/a.S\",\n]\n");
    const p1 = try problemsOf(a, unsorted, &.{});
    try t.expect(p1.len >= 1);
    try t.expectEqualStrings("FILES: src/a.S follows src/b.S; the list is sorted with no duplicate", p1[p1.len - 1]);
    const dup = try std.mem.replaceOwned(u8, a, sample_bzl, "    \"include/x.h\",\n    \"src/a.S\",\n    \"src/b.S\",\n]\n", "    \"include/x.h\",\n    \"src/a.S\",\n    \"src/a.S\",\n]\n");
    try t.expect((try problemsOf(a, dup, &.{})).len >= 1);
    const nofiles = "ASM = [\n    \"src/a.S\",\n]\n";
    const p2 = try problemsOf(a, nofiles, &.{});
    try t.expectEqualStrings("there is no FILES list", p2[0]);
    const p3 = try problemsOf(a, sample_bzl, &.{ "EMPTY", "ABSENT" });
    try t.expectEqual(@as(usize, 2), p3.len);
    try t.expectEqualStrings("EMPTY is required and is empty", p3[0]);
    try t.expectEqualStrings("ABSENT is required and is not in the file", p3[1]);
}
