//! The process behaviour of `act` (tools/build/mojo/tools/act.zig) over real files and a
//! real child: copy keeps the mode, cat concatenates, run-check records stdout,
//! clears the library-path variables of both loaders, gives the child an empty
//! stdin, HOME and TMPDIR of its own and the busybox applets, and fails (exit 1)
//! on a non-zero exit, with the last 100 lines of stderr, and on a stdout that is
//! not the expected file; its scratch directory is gone afterwards.
const std = @import("std");
const t = std.testing;
const a = t.allocator;

const Ctx = struct {
    arena: std.heap.ArenaAllocator,
    act: []const u8,
    probe: []const u8,
    busybox: []const u8,
    dir: []const u8,

    fn init(name: []const u8) !Ctx {
        var arena = std.heap.ArenaAllocator.init(a);
        const al = arena.allocator();
        const work = try std.process.getEnvVarOwned(al, "KOMIRA_TEST_WORK");
        const dir = try std.fs.path.join(al, &.{ work, name });
        try std.fs.cwd().makePath(dir);
        const act = try std.process.getEnvVarOwned(al, "ACT");
        const probe = try std.process.getEnvVarOwned(al, "PROBE");
        const busybox = try std.process.getEnvVarOwned(al, "BUSYBOX");
        return .{ .arena = arena, .act = act, .probe = probe, .busybox = busybox, .dir = dir };
    }

    fn deinit(self: *Ctx) void {
        self.arena.deinit();
    }

    fn path(self: *Ctx, name: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.dir, name });
    }

    fn write(self: *Ctx, name: []const u8, data: []const u8, mode: std.fs.File.Mode) !void {
        const f = try std.fs.cwd().createFile(try self.path(name), .{ .mode = mode });
        defer f.close();
        try f.writeAll(data);
    }

    fn read(self: *Ctx, name: []const u8) ![]u8 {
        return std.fs.cwd().readFileAlloc(self.arena.allocator(), try self.path(name), 1 << 20);
    }

    const Result = struct { code: u8, stderr: []const u8 };

    fn run(self: *Ctx, argv_tail: []const []const u8, mode: []const u8) !Result {
        const al = self.arena.allocator();
        var env = try std.process.getEnvMap(al);
        try env.put("LD_LIBRARY_PATH", "/a");
        try env.put("LD_PRELOAD", "/b");
        try env.put("DYLD_LIBRARY_PATH", "/c");
        try env.put("DYLD_FALLBACK_LIBRARY_PATH", "/d");
        try env.put("DYLD_INSERT_LIBRARIES", "/e");
        try env.put("KEPT", "kept");
        try env.put("PROBE_MODE", mode);
        var argv = std.ArrayList([]const u8).init(al);
        try argv.append(self.act);
        try argv.appendSlice(argv_tail);
        const r = try std.process.Child.run(.{ .allocator = al, .argv = argv.items, .cwd = self.dir, .env_map = &env });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stderr = r.stderr };
    }
};

test "copy keeps the mode and the bytes" {
    var c = try Ctx.init("copy");
    defer c.deinit();
    try c.write("src", "published bytes\n", 0o755);
    const r = try c.run(&.{ "copy", "src", "dst" }, "ok");
    try t.expectEqual(@as(u8, 0), r.code);
    try t.expectEqualStrings("published bytes\n", try c.read("dst"));
    const st = try std.fs.cwd().statFile(try c.path("dst"));
    try t.expect(st.mode & 0o100 != 0);
    // A missing source and a directory are refused.
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "copy", "nope", "dst2" }, "ok")).code);
    try std.fs.cwd().makePath(try c.path("adir"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "copy", "adir", "dst3" }, "ok")).code);
}

test "cat concatenates in order and refuses a missing input" {
    var c = try Ctx.init("cat");
    defer c.deinit();
    try c.write("a", "one\n", 0o644);
    try c.write("b", "two\n", 0o644);
    try c.write("e", "", 0o644);
    try t.expectEqual(@as(u8, 0), (try c.run(&.{ "cat", "out", "a", "e", "b" }, "ok")).code);
    try t.expectEqualStrings("one\ntwo\n", try c.read("out"));
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "cat", "out2", "a", "missing" }, "ok")).code);
}

test "run-check records stdout; the child sees no library path, its own HOME and TMPDIR, and an empty stdin" {
    var c = try Ctx.init("rc_ok");
    defer c.deinit();
    const r = try c.run(&.{ "run-check", c.busybox, c.probe, "stdout.txt" }, "stdin");
    try t.expectEqual(@as(u8, 0), r.code);
    const want =
        \\LD_LIBRARY_PATH=(unset)
        \\LD_PRELOAD=(unset)
        \\DYLD_LIBRARY_PATH=(unset)
        \\DYLD_FALLBACK_LIBRARY_PATH=(unset)
        \\DYLD_INSERT_LIBRARIES=(unset)
        \\KEPT=kept
        \\stdin 0 bytes
        \\home-set=yes
        \\tmp-set=yes
        \\
    ;
    try t.expectEqualStrings(want, try c.read("stdout.txt"));
    // The scratch directory is removed.
    var d = try std.fs.cwd().openDir(c.dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |e| {
        try t.expect(!std.mem.startsWith(u8, e.name, ".komira_run."));
    }
}

test "run-check with an expected file: equal passes, different fails with both sides shown" {
    var c = try Ctx.init("rc_expected");
    defer c.deinit();
    _ = try c.run(&.{ "run-check", c.busybox, c.probe, "first.txt" }, "ok");
    const first = try c.read("first.txt");
    try c.write("expected_same", first, 0o644);
    try t.expectEqual(@as(u8, 0), (try c.run(&.{ "run-check", c.busybox, c.probe, "o1.txt", "expected_same" }, "ok")).code);
    try c.write("expected_diff", "something else\n", 0o644);
    const r = try c.run(&.{ "run-check", c.busybox, c.probe, "o2.txt", "expected_diff" }, "ok");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(std.mem.indexOf(u8, r.stderr, "differs from expected_diff") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "--- expected\nsomething else\n--- actual\nLD_LIBRARY_PATH=(unset)") != null);
}

test "run-check of a binary that fails: exit 1, its exit status, the last 100 lines of stderr; stdout is still recorded" {
    var c = try Ctx.init("rc_fail");
    defer c.deinit();
    const r = try c.run(&.{ "run-check", c.busybox, c.probe, "out.txt" }, "stderr:250");
    try t.expectEqual(@as(u8, 1), r.code);
    try t.expect(std.mem.indexOf(u8, r.stderr, "run_check: ") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, " exited 3\n") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "err line 249\n") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "err line 150\n") != null);
    try t.expect(std.mem.indexOf(u8, r.stderr, "err line 149\n") == null);
    try t.expect((try c.read("out.txt")).len > 0);
    const r2 = try c.run(&.{ "run-check", c.busybox, c.probe, "out2.txt" }, "exit:7");
    try t.expectEqual(@as(u8, 1), r2.code);
    try t.expect(std.mem.indexOf(u8, r2.stderr, " exited 7\n") != null);
}

test "run-check usage and a binary that cannot start" {
    var c = try Ctx.init("rc_usage");
    defer c.deinit();
    try t.expectEqual(@as(u8, 2), (try c.run(&.{ "run-check", c.busybox }, "ok")).code);
    try t.expectEqual(@as(u8, 2), (try c.run(&.{"frobnicate"}, "ok")).code);
    const r = try c.run(&.{ "run-check", c.busybox, "no_such_binary", "o.txt" }, "ok");
    if (r.code != 1) std.debug.print("[act stderr] {s}\n", .{r.stderr});
    try t.expectEqual(@as(u8, 1), r.code);
}
