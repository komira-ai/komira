//! Unit tests of util.zig: the helpers every action tool shares.
const std = @import("std");
const U = @import("util.zig");
const t = std.testing;

test "exitCodeOf: a child's status, 128 + N for a signal" {
    try t.expectEqual(@as(u8, 0), U.exitCodeOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 3), U.exitCodeOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 137), U.exitCodeOf(.{ .Signal = 9 }));
    try t.expectEqual(@as(u8, 1), U.exitCodeOf(.{ .Unknown = 1 }));
}

test "scratchRoot: buck2's directory, else beside the inputs" {
    const a = t.allocator;
    const s1 = try U.scratchRoot(a, "/w", null);
    defer a.free(s1);
    try t.expectEqualStrings("/w/.komira_action", s1);
    const s2 = try U.scratchRoot(a, "/w", "/s");
    defer a.free(s2);
    try t.expectEqualStrings("/s/komira", s2);
    const s3 = try U.scratchRoot(a, "/w", "rel/s");
    defer a.free(s3);
    try t.expectEqualStrings("/w/rel/s/komira", s3);
    const s4 = try U.scratchRoot(a, "/w", "");
    defer a.free(s4);
    try t.expectEqualStrings("/w/.komira_action", s4);
}

test "sha256Hex: the digest of known bytes" {
    try t.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", &U.sha256Hex(""));
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &U.sha256Hex("abc"));
}

test "trimNewlines and contains" {
    try t.expectEqualStrings("a\nb", U.trimNewlines("a\nb\n\n"));
    try t.expectEqualStrings("", U.trimNewlines("\n"));
    try t.expect(U.contains("xx\x00needle\x00yy", "needle"));
    try t.expect(!U.contains("need\nle", "needle"));
}

test "listFiles: sorted bytewise, links followed only on request" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.makePath("d/sub");
    try tmp.dir.makePath("other");
    try U.writeAll(tmp.dir, "d/b", "1");
    try U.writeAll(tmp.dir, "d/a.b", "2");
    try U.writeAll(tmp.dir, "d/sub/z", "4");
    try U.writeAll(tmp.dir, "other/f", "5");
    try tmp.dir.symLink("../other/f", "d/link_file", .{});
    try tmp.dir.symLink("../other", "d/link_dir", .{});
    try tmp.dir.symLink("nowhere", "d/dangling", .{});
    var d = try tmp.dir.openDir("d", .{ .iterate = true });
    defer d.close();

    const plain = try U.listFiles(a, d, false);
    try t.expectEqual(@as(usize, 3), plain.len);
    try t.expectEqualStrings("a.b", plain[0]);
    try t.expectEqualStrings("b", plain[1]);
    try t.expectEqualStrings("sub/z", plain[2]);

    const followed = try U.listFiles(a, d, true);
    try t.expectEqual(@as(usize, 5), followed.len);
    try t.expectEqualStrings("a.b", followed[0]);
    try t.expectEqualStrings("b", followed[1]);
    try t.expectEqualStrings("link_dir/f", followed[2]);
    try t.expectEqualStrings("link_file", followed[3]);
    try t.expectEqualStrings("sub/z", followed[4]);
}

test "listNames: hidden entries too, sorted, each followed by a space" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try U.writeAll(tmp.dir, "b", "");
    try U.writeAll(tmp.dir, ".h", "");
    try U.writeAll(tmp.dir, "a", "");
    const names = try U.listNames(a, tmp.dir);
    try t.expectEqualStrings(".h a b ", try U.spaced(a, names));
}

test "copyTree keeps modes and links and merges into existing directories" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/sub");
    try tmp.dir.makePath("dst/sub");
    try U.writeAll(tmp.dir, "src/x", "x");
    try U.writeAll(tmp.dir, "src/sub/y", "y");
    try U.writeAll(tmp.dir, "dst/sub/keep", "k");
    {
        const f = try tmp.dir.openFile("src/x", .{});
        defer f.close();
        try f.chmod(0o755);
    }
    try tmp.dir.symLink("x", "src/ln", .{});
    var s = try tmp.dir.openDir("src", .{ .iterate = true });
    defer s.close();
    var d = try tmp.dir.openDir("dst", .{ .iterate = true });
    defer d.close();
    try U.copyTree(s, d);
    const st = try tmp.dir.statFile("dst/x");
    try t.expect(st.mode & 0o111 != 0);
    _ = try tmp.dir.statFile("dst/sub/y");
    _ = try tmp.dir.statFile("dst/sub/keep");
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("x", try tmp.dir.readLink("dst/ln", &buf));
}

test "setModes: directories and files, links untouched" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("o/bin");
    try U.writeAll(tmp.dir, "o/bin/p", "");
    try U.writeAll(tmp.dir, "o/f", "");
    var o = try tmp.dir.openDir("o", .{ .iterate = true });
    defer o.close();
    try U.setModes(o, 0o755, 0o644);
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), (try tmp.dir.statFile("o/f")).mode & 0o777);
    try t.expectEqual(@as(std.fs.File.Mode, 0o644), (try tmp.dir.statFile("o/bin/p")).mode & 0o777);
    try t.expectEqual(@as(std.fs.File.Mode, 0o755), (try tmp.dir.statFile("o/bin")).mode & 0o777);
}

test "parseFlags: values by arity, repeated flags in order, the rest after --, refusals name the argument" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = [_]U.Spec{ .{ .name = "out" }, .{ .name = "pair", .arity = 2 }, .{ .name = "empty" } };
    var bad: []const u8 = "";
    const f = try U.parseFlags(a, &.{ "--out", "o", "--pair", "a", "b", "--pair", "c", "d", "--empty", "", "--", "x", "--out" }, &spec, &bad);
    try t.expectEqualStrings("o", try f.need("out"));
    try t.expectEqualStrings("", f.one("empty").?);
    const pairs = try f.all(a, "pair");
    try t.expectEqual(@as(usize, 2), pairs.len);
    try t.expectEqualStrings("a", pairs[0].vals[0]);
    try t.expectEqualStrings("d", pairs[1].vals[1]);
    try t.expectEqual(@as(usize, 2), f.rest.len);
    try t.expectEqualStrings("x", f.rest[0]);
    try t.expectError(error.MissingFlag, f.need("nope"));
    try t.expect(f.one("nope") == null);

    try t.expectError(error.UnknownFlag, U.parseFlags(a, &.{ "--out", "o", "--bogus" }, &spec, &bad));
    try t.expectEqualStrings("--bogus", bad);
    try t.expectError(error.UnknownFlag, U.parseFlags(a, &.{"out"}, &spec, &bad));
    // A flag that lacks a value: `--pair a` has one of two.
    try t.expectError(error.MissingValue, U.parseFlags(a, &.{ "--pair", "a" }, &spec, &bad));
    try t.expectEqualStrings("--pair", bad);
    try t.expectError(error.MissingValue, U.parseFlags(a, &.{"--out"}, &spec, &bad));
}
