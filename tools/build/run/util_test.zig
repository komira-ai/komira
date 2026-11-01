//! The tail every banner prints (util.zig): it must print what busybox
//! `tail -n N` printed in the shell runners, byte for byte, including a final
//! line with no newline. Each case is compared against the busybox of the
//! test action's PATH, run on the same file.

const std = @import("std");
const posix = std.posix;
const sys = @import("sys.zig");
const util = @import("util.zig");
const kit = @import("testkit.zig");
const proctab = @import("proctab.zig");

fn busyboxTail(alloc: std.mem.Allocator, bb: []const u8, n: usize, path: []const u8, out_path: []const u8) ![]u8 {
    const pid = try posix.fork();
    if (pid == 0) {
        const fd = posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644) catch posix.exit(99);
        posix.dup2(fd, 1) catch posix.exit(99);
        var nbuf: [32]u8 = undefined;
        const ns = std.fmt.bufPrintZ(&nbuf, "{d}", .{n}) catch posix.exit(99);
        const argv = [_:null]?[*:0]const u8{ (alloc.dupeZ(u8, bb) catch posix.exit(99)).ptr, "tail", "-n", ns.ptr, (alloc.dupeZ(u8, path) catch posix.exit(99)).ptr };
        const envp = [_:null]?[*:0]const u8{};
        _ = posix.execveZ(argv[0].?, &argv, &envp) catch {};
        posix.exit(99);
    }
    const st = sys.waitpid(pid, false);
    try std.testing.expectEqual(@as(?u8, 0), st);
    return kit.readFile(alloc, out_path);
}

fn ourTail(alloc: std.mem.Allocator, n: usize, path: []const u8, out_path: []const u8) ![]u8 {
    const fd = try posix.open(out_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    util.writeTail(fd, path, n);
    posix.close(fd);
    return kit.readFile(alloc, out_path);
}

test "tail: 0, 1, 200, 201 and 10,000 lines, with and without a final newline, match busybox tail -n" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bb = try kit.busybox(a);
    const dir = try kit.tempDir(a);
    // Lines long enough that 10,000 of them cross the 64 KiB read block.
    for ([_]usize{ 0, 1, 2, 199, 200, 201, 10_000 }) |lines| {
        for ([_]bool{ true, false }) |final_nl| {
            var text = std.ArrayList(u8).empty;
            var k: usize = 1;
            while (k <= lines) : (k += 1) {
                try text.writer(a).print("line {d} of the test's output, padded to be long\n", .{k});
            }
            if (!final_nl and text.items.len > 0) text.items.len -= 1;
            // An empty line in the middle counts as a line.
            const path = try std.fmt.allocPrint(a, "{s}/log_{d}_{}", .{ dir, lines, final_nl });
            try kit.writeFile(path, text.items);
            for ([_]usize{ 0, 1, 50, 60, 100, 200 }) |n| {
                const want = try busyboxTail(a, bb, n, path, try std.fmt.allocPrint(a, "{s}.bb", .{path}));
                const got = try ourTail(a, n, path, try std.fmt.allocPrint(a, "{s}.ours", .{path}));
                if (!std.mem.eql(u8, want, got)) {
                    std.debug.print("tail -n {d} of {d} lines (final newline {}): busybox {d} bytes, ours {d}\n", .{ n, lines, final_nl, want.len, got.len });
                    return error.TestExpectedEqual;
                }
            }
        }
    }
}

test "tail: blank lines and a lone newline match busybox" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bb = try kit.busybox(a);
    const dir = try kit.tempDir(a);
    for ([_][]const u8{ "\n", "\n\n\n", "a\n\nb", "a\n\n\nb\n", "x" }) |body| {
        const path = try std.fmt.allocPrint(a, "{s}/b{d}", .{ dir, body.len });
        try kit.writeFile(path, body);
        for ([_]usize{ 1, 2, 3 }) |n| {
            const want = try busyboxTail(a, bb, n, path, try std.fmt.allocPrint(a, "{s}.bb", .{path}));
            const got = try ourTail(a, n, path, try std.fmt.allocPrint(a, "{s}.ours", .{path}));
            try std.testing.expectEqualStrings(want, got);
        }
    }
}

test "tailStart agrees with writeTail" {
    try std.testing.expectEqual(@as(usize, 4), util.tailStart("a\nb\nc\n", 1));
    try std.testing.expectEqual(@as(usize, 4), util.tailStart("a\nb\nc", 1));
    try std.testing.expectEqual(@as(usize, 0), util.tailStart("a\nb\nc", 9));
    try std.testing.expectEqual(@as(usize, 5), util.tailStart("a\nb\nc", 0));
}

test "positiveStrict refuses empty, non-digits and a leading zero" {
    try std.testing.expectEqual(@as(?u64, 30), util.positiveStrict("30"));
    for ([_][]const u8{ "", "0", "007", "1a", "-1", " 1" }) |s| {
        try std.testing.expectEqual(@as(?u64, null), util.positiveStrict(s));
    }
}

test "the process table: status and stat parsing" {
    const st = "Name:\tcat\nState:\tS (sleeping)\nTgid:\t42\nPid:\t42\nPPid:\t7\nTracerPid:\t0\nVmRSS:\t    1234 kB\n";
    const p = proctab.parseStatus(st).?;
    try std.testing.expectEqual(@as(i32, 42), p.pid);
    try std.testing.expectEqual(@as(i32, 7), p.ppid);
    try std.testing.expectEqual(@as(u8, 'S'), p.state);
    try std.testing.expectEqual(@as(u64, 1234), p.rss_kib);
    const s = proctab.parseStat("99 (a b) c)) Z 1 77 77 0").?;
    try std.testing.expectEqual(@as(i32, 99), s.pid);
    try std.testing.expectEqualStrings("a b) c)", s.comm);
    try std.testing.expectEqual(@as(u8, 'Z'), s.state);
    try std.testing.expectEqual(@as(i32, 77), s.pgrp);
}

test "the process table: the tree of a root, and a zombie root is gone" {
    var procs = [_]proctab.Proc{
        .{ .pid = 1, .ppid = 0, .state = 'S', .rss_kib = 5 },
        .{ .pid = 10, .ppid = 1, .state = 'S', .rss_kib = 100 },
        .{ .pid = 11, .ppid = 10, .state = 'R', .rss_kib = 200 },
        .{ .pid = 12, .ppid = 11, .state = 'S', .rss_kib = 300 },
        .{ .pid = 13, .ppid = 1, .state = 'S', .rss_kib = 400 },
        .{ .pid = 14, .ppid = 1, .state = 'Z', .rss_kib = 0 },
    };
    const t = proctab.Table{ .procs = &procs };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const tree = t.tree(arena.allocator(), 10).?;
    try std.testing.expectEqual(@as(usize, 3), tree.len);
    try std.testing.expectEqual(@as(u64, 600), t.rss(tree));
    try std.testing.expectEqual(@as(?[]i32, null), t.tree(arena.allocator(), 14));
    try std.testing.expectEqual(@as(?[]i32, null), t.tree(arena.allocator(), 99));
}

test "the real process table shows this process" {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const t = proctab.read(arena.allocator()).?;
    try std.testing.expect(t.has(sys.getpid()));
    const seen = proctab.selfSeen();
    try std.testing.expectEqual(@as(i64, sys.getpid()), seen[0]);
    try std.testing.expectEqual(@as(i64, sys.getpid()), seen[1]);
}
