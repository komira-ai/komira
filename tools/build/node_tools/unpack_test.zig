const std = @import("std");
const unpack = @import("unpack.zig");
const tartest = @import("tartest.zig");

fn mode(dir: std.fs.Dir, path: []const u8) !u32 {
    const st = try dir.statFile(path);
    return @intCast(st.mode & 0o777);
}

test "stripFirst: the first component goes, whatever it is" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("package/lib/a.js", &buf));
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("fx-scoped-3.0.0/lib/a.js", &buf));
    try std.testing.expectEqualStrings("lib/a.js", try unpack.stripFirst("./package//lib/./a.js", &buf));
    try std.testing.expectEqualStrings("", try unpack.stripFirst("package/", &buf));
    try std.testing.expectEqualStrings("", try unpack.stripFirst("package", &buf));
}

test "stripFirst: a path that leaves the package is refused" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/../../etc/passwd", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("../package/a", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("package/a/..", &buf));
    try std.testing.expectError(error.PathEscapes, unpack.stripFirst("/etc/passwd", &buf));
}

test "unpackTgz: files at their stripped paths with npm's modes, links not extracted" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{
        .{ .name = "package/bin/run.js", .mode = 0o755, .data = "#!/usr/bin/env node\n" },
        .{ .name = "package/lib/a.js", .mode = 0o600, .data = "exports.a = 1;\n" },
        .{ .name = "package/lib/b.js", .mode = 0o664, .data = "" },
        .{ .name = "package/evil", .kind = '2', .link = "/etc/passwd" },
        .{ .name = "package/empty/", .kind = '5', .mode = 0o700 },
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const st = try unpack.unpackTgz(tmp.dir, z);
    try std.testing.expectEqual(@as(usize, 4), st.files);
    try std.testing.expectEqual(@as(usize, 1), st.links);
    try std.testing.expectEqual(@as(u32, 0o755), try mode(tmp.dir, "bin/run.js"));
    try std.testing.expectEqual(@as(u32, 0o644), try mode(tmp.dir, "lib/a.js"));
    try std.testing.expectEqual(@as(u32, 0o644), try mode(tmp.dir, "lib/b.js"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("evil"));
    const text = try tmp.dir.readFileAlloc(a, "lib/a.js", 100);
    defer a.free(text);
    try std.testing.expectEqualStrings("exports.a = 1;\n", text);
    var d = try tmp.dir.openDir("empty", .{});
    d.close();
}

test "unpackTgz: an entry that escapes the package fails the unpack and writes nothing outside" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{
        .{ .name = "package/../escaped.txt", .data = "x" },
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var sub = try tmp.dir.makeOpenPath("pkg", .{});
    defer sub.close();
    try std.testing.expectError(error.PathEscapes, unpack.unpackTgz(sub, z));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile("escaped.txt"));
}

test "unpackTgz: a stream that is not gzip, and a truncated one, are errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, "not a gzip stream at all")));
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const z = try tartest.tgz(arena.allocator(), "p", "1.0.0", &.{.{ .name = "package/a", .data = "0123456789" }});
    try std.testing.expect(std.meta.isError(unpack.unpackTgz(tmp.dir, z[0 .. z.len - 20])));
}
