//! Unit tests of act.zig's pure parts. Its process behaviour (copy, cat and
//! run-check over real files and a real child) is tests//functional/act.
const std = @import("std");
const A = @import("act.zig");
const t = std.testing;

test "lastLines: tail -n" {
    try t.expectEqualStrings("b\nc\n", A.lastLines("a\nb\nc\n", 2));
    try t.expectEqualStrings("c\n", A.lastLines("a\nb\nc\n", 1));
    try t.expectEqualStrings("b\nc", A.lastLines("a\nb\nc", 2));
    try t.expectEqualStrings("a\nb\nc\n", A.lastLines("a\nb\nc\n", 3));
    try t.expectEqualStrings("a\nb\nc\n", A.lastLines("a\nb\nc\n", 100));
    try t.expectEqualStrings("", A.lastLines("", 5));
    try t.expectEqualStrings("", A.lastLines("a\n", 0));
    try t.expectEqualStrings("x", A.lastLines("x", 1));
}

test "lastLines: a long stderr keeps exactly the last 100 lines" {
    var buf = std.ArrayList(u8).init(t.allocator);
    defer buf.deinit();
    var i: usize = 0;
    while (i < 250) : (i += 1) try buf.writer().print("line {d}\n", .{i});
    const tail = A.lastLines(buf.items, 100);
    var lines: usize = 0;
    for (tail) |c| {
        if (c == '\n') lines += 1;
    }
    try t.expectEqual(@as(usize, 100), lines);
    try t.expect(std.mem.startsWith(u8, tail, "line 150\n"));
    try t.expect(std.mem.endsWith(u8, tail, "line 249\n"));
}

test "exitCodeOf: a child's status, 128 + N for a signal" {
    try t.expectEqual(@as(u8, 0), A.exitCodeOf(.{ .Exited = 0 }));
    try t.expectEqual(@as(u8, 3), A.exitCodeOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 134), A.exitCodeOf(.{ .Signal = 6 }));
    try t.expectEqual(@as(u8, 1), A.exitCodeOf(.{ .Unknown = 1 }));
}

test "cleanEnv: the library path variables are gone, three are set, the rest is kept" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var base = std.process.EnvMap.init(a);
    for (A.cleared) |v| try base.put(v, "/x");
    try base.put("PATH", "/usr/bin");
    try base.put("KEEP", "yes");
    const env = try A.cleanEnv(a, base, "/t/bin", "/t/tmp", "/t/home");
    for (A.cleared) |v| try t.expect(env.get(v) == null);
    try t.expectEqualStrings("/t/bin", env.get("PATH").?);
    try t.expectEqualStrings("/t/tmp", env.get("TMPDIR").?);
    try t.expectEqualStrings("/t/home", env.get("HOME").?);
    try t.expectEqualStrings("yes", env.get("KEEP").?);
    // The base is not changed.
    try t.expectEqualStrings("/usr/bin", base.get("PATH").?);
    try t.expect(base.get("LD_PRELOAD") != null);
}

test "cleared: both loaders' variables" {
    var ld = false;
    var dyld = false;
    for (A.cleared) |v| {
        if (std.mem.eql(u8, v, "LD_LIBRARY_PATH")) ld = true;
        if (std.mem.eql(u8, v, "DYLD_LIBRARY_PATH")) dyld = true;
    }
    try t.expect(ld and dyld);
}
