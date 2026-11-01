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
        std.fs.cwd().writeFile(.{ .sub_path = path, .data = data }) catch @panic("write");
    }

    fn run(self: *Work, args: []const []const u8) !Res {
        const a = self.arena.allocator();
        const tool = try std.process.getEnvVarOwned(a, "TESTS_ACT");
        var argv = std.ArrayList([]const u8).empty;
        try argv.append(a, tool);
        try argv.appendSlice(a, args);
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

fn genDir(w: *Work, name: []const u8, rc: []const u8, stderr: []const u8) void {
    w.put(std.fmt.allocPrint(w.arena.allocator(), "{s}/rc", .{name}) catch @panic("oom"), rc);
    w.put(std.fmt.allocPrint(w.arena.allocator(), "{s}/stderr", .{name}) catch @panic("oom"), stderr);
    std.fs.cwd().makePath(w.p(std.fmt.allocPrint(w.arena.allocator(), "{s}/files", .{name}) catch @panic("oom"))) catch @panic("mkdir");
}

test "proto-check with golden files: the same tree passes, a changed one fails with the diff" {
    var w = try Work.init("pcheck");
    defer w.deinit();
    genDir(&w, "gen", "0\n", "");
    w.put("gen/files/a.mojo", "one\ntwo\n");
    w.put("golden/a.mojo", "one\ntwo\n");
    const ok = try w.run(&.{ "proto-check", "gen", "golden", "", "mark", "1", "forbidden", "two" });
    try t.expectEqual(@as(u8, 0), ok.code);
    w.put("golden/a.mojo", "one\n2\n");
    const bad = try w.run(&.{ "proto-check", "gen", "golden", "", "mark2", "0", "two" });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(std.mem.indexOf(u8, bad.stderr, "-2\n+two\n") != null or std.mem.indexOf(u8, bad.stderr, "-two\n+2\n") != null or std.mem.indexOf(u8, bad.stderr, "@@") != null);
    try t.expect(std.mem.indexOf(u8, bad.stderr, "the generated files differ from the golden files (above)") != null);
    w.put("golden/a.mojo", "one\ntwo\n");
    const absent = try w.run(&.{ "proto-check", "gen", "golden", "", "mark3", "1", "one" });
    try t.expectEqual(@as(u8, 1), absent.code);
    try t.expect(std.mem.indexOf(u8, absent.stderr, "which must be absent") != null);
}

/// `n` lines of Mojo-looking text, each ending in a newline.
fn lines(w: *Work, n: usize) []const u8 {
    var b = std.ArrayList(u8).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) b.appendSlice(w.arena.allocator(), "comptime X: Int = 1\n") catch @panic("oom");
    return b.items;
}

test "proto-check: a generated .mojo file of 1000 lines is refused, one of 999 is not, even when it equals its golden" {
    var w = try Work.init("pcheck_limit");
    defer w.deinit();
    genDir(&w, "gen", "0\n", "");
    w.put("gen/files/a.mojo", lines(&w, 999));
    w.put("golden/a.mojo", lines(&w, 999));
    const ok = try w.run(&.{ "proto-check", "gen", "golden", "", "mark", "0" });
    try t.expectEqual(@as(u8, 0), ok.code);
    w.put("gen/files/a.mojo", lines(&w, 1000));
    w.put("golden/a.mojo", lines(&w, 1000));
    const bad = try w.run(&.{ "proto-check", "gen", "golden", "", "mark2", "0" });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(std.mem.indexOf(u8, bad.stderr, "a.mojo (1000 lines) reaches 1000 lines") != null or std.mem.indexOf(u8, bad.stderr, "a.mojo (1000 lines)") != null);
    // A part in a directory is held to it too.
    w.put("gen/files/a.mojo", "x\n");
    w.put("golden/a.mojo", "x\n");
    w.put("gen/files/_parts/a_p01.mojo", lines(&w, 1200));
    w.put("golden/_parts/a_p01.mojo", lines(&w, 1200));
    const part = try w.run(&.{ "proto-check", "gen", "golden", "", "mark3", "0" });
    try t.expectEqual(@as(u8, 1), part.code);
    try t.expect(std.mem.indexOf(u8, part.stderr, "_parts/a_p01.mojo (1200 lines)") != null);
}

test "proto-check: the goldens of the parts in _parts are compared file for file" {
    var w = try Work.init("pcheck_parts");
    defer w.deinit();
    genDir(&w, "gen", "0\n", "");
    w.put("gen/files/a.mojo", "facade\n");
    w.put("gen/files/_parts/a_p01.mojo", "one\n");
    w.put("golden/a.mojo", "facade\n");
    w.put("golden/_parts/a_p01.mojo", "one\n");
    const ok = try w.run(&.{ "proto-check", "gen", "golden", "", "mark", "0" });
    try t.expectEqual(@as(u8, 0), ok.code);
    w.put("golden/_parts/a_p01.mojo", "uno\n");
    const changed = try w.run(&.{ "proto-check", "gen", "golden", "", "mark2", "0" });
    try t.expectEqual(@as(u8, 1), changed.code);
    w.put("golden/_parts/a_p01.mojo", "one\n");
    w.put("gen/files/_parts/a_p02.mojo", "two\n");
    const extra = try w.run(&.{ "proto-check", "gen", "golden", "", "mark3", "0" });
    try t.expectEqual(@as(u8, 1), extra.code);
    try t.expect(std.mem.indexOf(u8, extra.stderr, "Only in gen/files: _parts/a_p02.mojo") != null);
}

test "aws-cmp: parts goldens, no golden for parts, a file of 1000 lines, must-contain read across the parts" {
    var w = try Work.init("awscmp");
    defer w.deinit();
    w.put("gen/svc.mojo", "facade\n");
    w.put("gen/_layout_probe.mojo", "probe\n");
    w.put("gold/svc.mojo", "facade\n");
    w.put("gold/probe.mojo", "probe\n");
    // Not split: no parts directory and no parts golden.
    const whole = try w.run(&.{ "aws-cmp", "m1", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "-", "facade" });
    try t.expectEqual(@as(u8, 0), whole.code);
    // Split: the parts are compared with their goldens, and a needle in a part is found.
    w.put("gen/_parts/svc_p01.mojo", "part one\nvar needle: Int\n");
    w.put("gen/_parts/svc_p02.mojo", "part two\n");
    w.put("gold/parts/svc_p01.mojo", "part one\nvar needle: Int\n");
    w.put("gold/parts/svc_p02.mojo", "part two\n");
    const split = try w.run(&.{ "aws-cmp", "m2", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "gold/parts", "var needle: Int" });
    try t.expectEqual(@as(u8, 0), split.code);
    const missing = try w.run(&.{ "aws-cmp", "m3", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "gold/parts", "var absent: Int" });
    try t.expectEqual(@as(u8, 1), missing.code);
    try t.expect(std.mem.indexOf(u8, missing.stderr, "svc.mojo does not contain:") != null);
    // A split module with no golden for its parts is refused, and so is a golden for parts that were not made.
    const unnamed = try w.run(&.{ "aws-cmp", "m4", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "-" });
    try t.expectEqual(@as(u8, 1), unnamed.code);
    try t.expect(std.mem.indexOf(u8, unnamed.stderr, "the module was split into parts and no golden names them") != null);
    w.put("gold/parts/svc_p02.mojo", "part 2\n");
    const differs = try w.run(&.{ "aws-cmp", "m5", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "gold/parts" });
    try t.expectEqual(@as(u8, 1), differs.code);
    try t.expect(std.mem.indexOf(u8, differs.stderr, "the parts differ from their goldens") != null);
    // No generated file may reach the limit.
    w.put("gold/parts/svc_p02.mojo", "part two\n");
    w.put("gen/_parts/svc_p02.mojo", lines(&w, 1000));
    w.put("gold/parts/svc_p02.mojo", lines(&w, 1000));
    const long = try w.run(&.{ "aws-cmp", "m6", "gen", "svc", "gold/svc.mojo", "gold/probe.mojo", "gold/parts" });
    try t.expectEqual(@as(u8, 1), long.code);
    try t.expect(std.mem.indexOf(u8, long.stderr, "_parts/svc_p02.mojo (1000 lines)") != null);
    // Whole, with parts golden named but none made.
    w.put("g2/svc.mojo", "facade\n");
    const none = try w.run(&.{ "aws-cmp", "m7", "g2", "svc", "gold/svc.mojo", "-", "gold/parts" });
    try t.expectEqual(@as(u8, 1), none.code);
    try t.expect(std.mem.indexOf(u8, none.stderr, "the module was not split") != null);
}

test "proto-check expecting an error: protoc must fail with the text and write nothing" {
    var w = try Work.init("pcheck_err");
    defer w.deinit();
    genDir(&w, "fail", "1\n", "x.proto: Import \"y\" was not found\n");
    const ok = try w.run(&.{ "proto-check", "fail", "", "was not found", "m1", "0" });
    try t.expectEqual(@as(u8, 0), ok.code);
    const other = try w.run(&.{ "proto-check", "fail", "", "different text", "m2", "0" });
    try t.expectEqual(@as(u8, 1), other.code);
    try t.expect(std.mem.indexOf(u8, other.stderr, "protoc-gen-mojo failed, but not with: different text") != null);
    genDir(&w, "wrote", "1\n", "boom\n");
    w.put("wrote/files/a.mojo", "partial");
    const wrote = try w.run(&.{ "proto-check", "wrote", "", "boom", "m3", "0" });
    try t.expectEqual(@as(u8, 1), wrote.code);
    try t.expect(std.mem.indexOf(u8, wrote.stderr, "failed but wrote files:\na.mojo") != null);
    genDir(&w, "okgen", "0\n", "");
    const succ = try w.run(&.{ "proto-check", "okgen", "", "boom", "m4", "0" });
    try t.expectEqual(@as(u8, 1), succ.code);
    try t.expect(std.mem.indexOf(u8, succ.stderr, "was expected to fail with: boom; it succeeded") != null);
}

test "rest-extract: the block between the markers; a marker missing or doubled is refused" {
    var w = try Work.init("rest");
    defer w.deinit();
    const b = "# ---- REST URL helpers (one copy per REST file) ----";
    const e = "# ---- end of REST URL helpers ----";
    w.put("good.mojo", "head\n" ++ b ++ "\nbody\n" ++ e ++ "\ntail\n");
    const ok = try w.run(&.{ "rest-extract", "good.mojo", "out.mojo" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings(b ++ "\nbody\n" ++ e ++ "\n", std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("out.mojo"), 1000) catch "");
    w.put("twice.mojo", b ++ "\n" ++ b ++ "\n" ++ e ++ "\n");
    const twice = try w.run(&.{ "rest-extract", "twice.mojo", "o2.mojo" });
    try t.expectEqual(@as(u8, 1), twice.code);
    try t.expect(std.mem.indexOf(u8, twice.stderr, "holds the marker '# ---- REST URL helpers (one copy per REST file) ----' 2 times, not once") != null);
}

test "cov-plant: the copy has the expression applied and must differ; an expression that changes nothing, or that sed would run but this does not, is refused" {
    var w = try Work.init("plant");
    defer w.deinit();
    w.put("src.zig", "const n = @N@;\nconst m = 2;\n");
    const ok = try w.run(&.{ "cov-plant", "s/@N@/4/", "src.zig", "out.zig" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings("const n = 4;\nconst m = 2;\n", std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("out.zig"), 1000) catch "");
    const none = try w.run(&.{ "cov-plant", "s/@NOPE@/4/", "src.zig", "out2.zig" });
    try t.expectEqual(@as(u8, 1), none.code);
    try t.expect(std.mem.indexOf(u8, none.stderr, "changes nothing") != null);
    try t.expect(!exists(w.p("out2.zig")));
    const unsupported = try w.run(&.{ "cov-plant", "s/@N*/4/", "src.zig", "out3.zig" });
    try t.expectEqual(@as(u8, 1), unsupported.code);
}

test "cov-report-check: golden reports must be byte for byte; a result JSON must hold each expected string" {
    var w = try Work.init("covreport");
    defer w.deinit();
    w.put("golden.xml", "<a/>\n");
    w.put("same.xml", "<a/>\n");
    w.put("other.xml", "<b/>\n");
    const ok = try w.run(&.{ "cov-report-check", "out1", "golden", "--golden", "golden.xml", "same.xml" });
    try t.expectEqual(@as(u8, 0), ok.code);
    try t.expectEqualStrings("ok same.xml = golden.xml (5 bytes)\n", std.fs.cwd().readFileAlloc(w.arena.allocator(), w.p("out1"), 1000) catch "");
    const bad = try w.run(&.{ "cov-report-check", "out2", "golden", "--golden", "golden.xml", "other.xml" });
    try t.expectEqual(@as(u8, 1), bad.code);
    try t.expect(std.mem.indexOf(u8, bad.stderr, "other.xml is not golden.xml byte for byte") != null);
    w.put("result.json", "{\"conclusion\":\"success\",\"held_line\":true}");
    const res = try w.run(&.{ "cov-report-check", "out3", "result", "--expect", "\"held_line\":true", "--json", "result.json" });
    try t.expectEqual(@as(u8, 0), res.code);
    const miss = try w.run(&.{ "cov-report-check", "out4", "result", "--expect", "\"held_line\":false", "--json", "result.json" });
    try t.expectEqual(@as(u8, 1), miss.code);
    try t.expect(std.mem.indexOf(u8, miss.stderr, "the gate's result JSON does not hold '\"held_line\":false'") != null);
}
