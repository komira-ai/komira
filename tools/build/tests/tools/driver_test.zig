//! The exit codes and messages of tests_act's checks over real files: each check
//! passes on a good input and fails (exit 1, saying what) on the defect it exists
//! to catch.
const std = @import("std");
const t = std.testing;

const Res = struct { code: u8, stderr: []const u8 };

const Work = struct {
    arena: std.heap.ArenaAllocator,
    dir: []const u8,

    fn init(name: []const u8) !Work {
        var arena = std.heap.ArenaAllocator.init(t.allocator);
        const a = arena.allocator();
        const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
        const dir = try std.fs.path.join(a, &.{ work, name });
        try std.fs.cwd().makePath(dir);
        return .{ .arena = arena, .dir = dir };
    }

    fn deinit(self: *Work) void {
        self.arena.deinit();
    }

    fn p(self: *Work, name: []const u8) []const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.dir, name }) catch @panic("oom");
    }

    fn put(self: *Work, name: []const u8, data: []const u8) void {
        const path = self.p(name);
        if (std.fs.path.dirname(path)) |d| std.fs.cwd().makePath(d) catch {};
        std.fs.cwd().writeFile(path, data) catch @panic("write");
    }

    fn run(self: *Work, args: []const []const u8) !Res {
        const a = self.arena.allocator();
        const tool = try std.process.getEnvVarOwned(a, "TESTS_ACT");
        var argv = std.ArrayList([]const u8).init(a);
        try argv.append(tool);
        try argv.appendSlice(args);
        const r = try std.process.Child.run(.{ .allocator = a, .argv = argv.items, .cwd = self.dir });
        return .{ .code = switch (r.term) {
            .Exited => |c| c,
            else => 255,
        }, .stderr = r.stderr };
    }
};

test "gen-check: exact entries, absent strings, identical files, present strings" {
    var w = try Work.init("gen");
    defer w.deinit();
    w.put("gen/a.mojo", "alpha beta");
    w.put("gen/sub/b.mojo", "gamma");
    w.put("want_a", "alpha beta");
    const ok = try w.run(&.{ "gen-check", "gen", "mark", "a.mojo sub", "1", "1", "forbidden", "a.mojo", "want_a", "gamma" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings("ok\n", std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("mark"), 100) catch "");
    const extra = try w.run(&.{ "gen-check", "gen", "m2", "a.mojo", "0", "0", "gamma" });
    try t.expectEqual(@as(u8, 1), extra.code);
    try t.expect(std.mem.indexOf(u8, extra.stderr, "the generated directory holds: a.mojo sub ") != null);
    const absent = try w.run(&.{ "gen-check", "gen", "m3", "a.mojo sub", "1", "0", "gamma", "alpha" });
    try t.expectEqual(@as(u8, 1), absent.code);
    try t.expect(std.mem.indexOf(u8, absent.stderr, "gen/sub/b.mojo") != null);
    try t.expect(std.mem.indexOf(u8, absent.stderr, "which must be absent") != null);
    w.put("want_other", "alpha");
    const ident = try w.run(&.{ "gen-check", "gen", "m4", "a.mojo sub", "0", "1", "a.mojo", "want_other", "gamma" });
    try t.expectEqual(@as(u8, 1), ident.code);
    try t.expect(std.mem.indexOf(u8, ident.stderr, "the generated a.mojo is not byte for byte want_other") != null);
    const missing = try w.run(&.{ "gen-check", "gen", "m5", "a.mojo sub", "0", "0", "delta" });
    try t.expectEqual(@as(u8, 1), missing.code);
    try t.expect(std.mem.indexOf(u8, missing.stderr, "no generated file holds `delta`") != null);
    try t.expect(!exists(w.p("m5")));
}

fn exists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

test "tests-check: markers must be .passed files recording PASS, and be exactly the expected tests" {
    var w = try Work.init("tests");
    defer w.deinit();
    w.put("m/test_a.passed", "PASS test_a\n");
    w.put("m/test_b.passed", "PASS test_b\n");
    w.put("m/test_c.passed", "FAIL test_c\n");
    w.put("m/stray.txt", "PASS\n");
    const ok = try w.run(&.{ "tests-check", "mark", "test_a test_b", "m/test_b.passed", "m/test_a.passed" });
    try t.expectEqual(@as(u8, 0), ok.code);
    const fail = try w.run(&.{ "tests-check", "m2", "test_a test_c", "m/test_a.passed", "m/test_c.passed" });
    try t.expectEqual(@as(u8, 1), fail.code);
    try t.expect(std.mem.indexOf(u8, fail.stderr, "the welded test test_c did not pass: FAIL test_c") != null);
    const other = try w.run(&.{ "tests-check", "m3", "test_a", "m/stray.txt" });
    try t.expectEqual(@as(u8, 1), other.code);
    try t.expect(std.mem.indexOf(u8, other.stderr, "`stray.txt` is not a test pass marker") != null);
    const set = try w.run(&.{ "tests-check", "m4", "test_a test_b", "m/test_a.passed" });
    try t.expectEqual(@as(u8, 1), set.code);
    try t.expect(std.mem.indexOf(u8, set.stderr, "the library's welded tests that passed: test_a ") != null);
}

test "same-bytes: equal non-empty files pass with their sha256; different or empty ones fail" {
    var w = try Work.init("same");
    defer w.deinit();
    w.put("a", "package bytes");
    w.put("b", "package bytes");
    w.put("c", "other bytes");
    w.put("empty", "");
    const ok = try w.run(&.{ "same-bytes", "a", "b", "report" });
    try t.expectEqual(@as(u8, 0), ok.code);
    const rep = try std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("report"), 200);
    try t.expect(std.mem.startsWith(u8, rep, "same bytes: "));
    try t.expectEqual(@as(usize, "same bytes: ".len + 64 + 1), rep.len);
    const diff = try w.run(&.{ "same-bytes", "a", "c", "r2" });
    try t.expectEqual(@as(u8, 1), diff.code);
    try t.expect(std.mem.indexOf(u8, diff.stderr, "differs: the .mojoc records where it was built") != null);
    const empty = try w.run(&.{ "same-bytes", "empty", "empty", "r3" });
    try t.expectEqual(@as(u8, 1), empty.code);
    try t.expect(std.mem.indexOf(u8, empty.stderr, "wrote an empty package") != null);
}

test "test-command: the command's failure is the failure; success records ok <label>" {
    var w = try Work.init("cmd");
    defer w.deinit();
    const tool = try std.process.getEnvVarOwned(w.arena.allocator(), "TESTS_ACT");
    // The command is tests_act itself: `same-bytes` over equal files passes, over different ones fails.
    w.put("x", "1");
    w.put("y", "1");
    w.put("z", "2");
    const ok = try w.run(&.{ "test-command", "//t:x", "rep", "--", tool, "same-bytes", "x", "y", "inner" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings("ok //t:x\n", std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("rep"), 100) catch "");
    const bad = try w.run(&.{ "test-command", "//t:z", "rep2", "--", tool, "same-bytes", "x", "z", "inner2" });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(std.mem.indexOf(u8, bad.stderr, "the test command of //t:z exited 1") != null);
    try t.expect(!exists(w.p("rep2")));
}

test "delete-member: the copy lacks the member and keeps the rest; the source is untouched" {
    var w = try Work.init("del");
    defer w.deinit();
    w.put("src/bin/mojo", "m");
    w.put("src/lib/libx.so", "x");
    const ok = try w.run(&.{ "delete-member", "src", "dst", "lib/libx.so" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expect(exists(w.p("dst/bin/mojo")));
    try t.expect(!exists(w.p("dst/lib/libx.so")));
    try t.expect(exists(w.p("src/lib/libx.so")));
    const none = try w.run(&.{ "delete-member", "src", "dst2", "lib/nosuch" });
    try t.expectEqual(@as(u8, 1), none.code);
}
