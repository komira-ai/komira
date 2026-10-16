//! Unit tests of extract.zig: the entries below one top directory, kept by a
//! predicate, with tar's modes and links.
const std = @import("std");
const X = @import("extract.zig");
const tartest = @import("node_tartest");
const t = std.testing;

/// What the node rules keep of a Node.js archive.
fn keepDist(rest: []const u8) bool {
    return std.mem.eql(u8, rest, "bin/node") or std.mem.eql(u8, rest, "LICENSE") or
        std.mem.eql(u8, rest, "include/node") or std.mem.startsWith(u8, rest, "include/node/");
}

test "below: the path under the top directory; another top is not below it; .. is refused" {
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("bin/node", (try X.below("node-v1/bin/node", "node-v1", &buf)).?);
    try t.expectEqualStrings("bin/node", (try X.below("./node-v1//bin/./node", "node-v1", &buf)).?);
    try t.expectEqualStrings("", (try X.below("node-v1/", "node-v1", &buf)).?);
    try t.expectEqualStrings("", (try X.below("node-v1", "node-v1", &buf)).?);
    try t.expect((try X.below("other/bin/node", "node-v1", &buf)) == null);
    try t.expect((try X.below("node-v10/bin/node", "node-v1", &buf)) == null);
    try t.expect((try X.below("bin/node", "node-v1", &buf)) == null);
    try t.expectError(error.PathEscapes, X.below("node-v1/../x", "node-v1", &buf));
    try t.expectError(error.PathEscapes, X.below("node-v1/a/..", "node-v1", &buf));
}

fn modeOf(dir: std.fs.Dir, path: []const u8) !std.fs.File.Mode {
    return (try dir.statFile(path)).mode & 0o777;
}

test "extractTgz: only the kept entries under the top, with tar's modes, links kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tartest.tar(a, &.{
        .{ .name = "node-x/", .kind = '5', .mode = 0o755 },
        .{ .name = "node-x/bin/node", .mode = 0o775, .data = "NODE" },
        .{ .name = "node-x/bin/npm", .kind = '2', .link = "../lib/npm" },
        .{ .name = "node-x/LICENSE", .mode = 0o600, .data = "L" },
        .{ .name = "node-x/include/node/node_api.h", .mode = 0o644, .data = "H" },
        .{ .name = "node-x/include/node/sub/", .kind = '5', .mode = 0o755 },
        .{ .name = "node-x/include/node/sub/link.h", .kind = '2', .link = "../node_api.h" },
        .{ .name = "node-x/include/other.h", .data = "O" },
        .{ .name = "node-x/lib/npm", .data = "NPM" },
        .{ .name = "elsewhere/bin/node", .mode = 0o755, .data = "X" },
    });
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try X.extractTgz(tmp.dir, try tartest.gzip(a, tar), "node-x", keepDist);
    try t.expectEqualStrings("NODE", try tmp.dir.readFileAlloc(a, "bin/node", 100));
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try modeOf(tmp.dir, "bin/node"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try modeOf(tmp.dir, "LICENSE"));
    try t.expectEqualStrings("H", try tmp.dir.readFileAlloc(a, "include/node/node_api.h", 100));
    var link: [64]u8 = undefined;
    try t.expectEqualStrings("../node_api.h", try tmp.dir.readLink("include/node/sub/link.h", &link));
    // not kept: the npm link, the other include, the library, another top
    try t.expectError(error.FileNotFound, tmp.dir.statFile("lib/npm"));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("include/other.h"));
    try t.expectError(error.FileNotFound, tmp.dir.readLink("bin/npm", &link));
    try t.expectError(error.FileNotFound, tmp.dir.statFile("elsewhere"));
}

test "extractTgz: keepAll takes the whole package; an escaping path is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const ok = try tartest.tgz(a, "p", "1.0.0", &.{
        .{ .name = "package/bin/run", .mode = 0o755, .data = "R" },
        .{ .name = "package/lib/a.js", .mode = 0o400, .data = "A" },
    });
    try X.extractTgz(tmp.dir, ok, "package", X.keepAll);
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), try modeOf(tmp.dir, "bin/run"));
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), try modeOf(tmp.dir, "lib/a.js"));
    _ = try tmp.dir.statFile("package.json");
    const bad = try tartest.tgz(a, "p", "1.0.0", &.{.{ .name = "package/../../etc/x", .data = "no" }});
    try t.expectError(error.PathEscapes, X.extractTgz(tmp.dir, bad, "package", X.keepAll));
}


test "headerMtime: octal, space or NUL padded, base-256, and unreadable fields" {
    var h = [_]u8{0} ** 512;
    @memcpy(h[136..148], "00000000017\x00");
    try t.expectEqual(@as(?u64, 15), X.headerMtime(&h));
    @memcpy(h[136..148], "      17    ");
    try t.expectEqual(@as(?u64, 15), X.headerMtime(&h));
    @memcpy(h[136..148], "11111111111\x00");
    try t.expectEqual(@as(?u64, 0o11111111111), X.headerMtime(&h));
    h[136] = 0x80;
    @memset(h[137..148], 0);
    h[147] = 5;
    try t.expectEqual(@as(?u64, 5), X.headerMtime(&h));
    @memcpy(h[136..148], "00000000089\x00");
    try t.expectEqual(@as(?u64, null), X.headerMtime(&h));
    @memset(h[136..148], 0);
    try t.expectEqual(@as(?u64, null), X.headerMtime(&h));
}

test "extractTgz: each file gets its header's modification time, so what a program writes about it is the same at every run" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const gz = try tartest.tgz(a, "p", "1.0.0", &.{
        .{ .name = "package/a.js", .data = "A", .mtime = 499162500 },
        .{ .name = "package/dir/b.js", .data = "B", .mtime = 1700000000 },
        .{ .name = "package/c.js", .data = "C", .mtime = 0 },
    });
    try X.extractTgz(tmp.dir, gz, "package", X.keepAll);
    const sec = std.time.ns_per_s;
    try t.expectEqual(@as(i128, 499162500) * sec, (try tmp.dir.statFile("a.js")).mtime);
    try t.expectEqual(@as(i128, 1700000000) * sec, (try tmp.dir.statFile("dir/b.js")).mtime);
    try t.expectEqual(@as(i128, 0), (try tmp.dir.statFile("c.js")).mtime);
}
