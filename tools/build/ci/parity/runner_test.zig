//! The harness's own checks, each the defect it would let through: the
//! grammar (format.zig), the timing normalization, the divergences, the
//! comparison of every stream and of the calls. Welded: the runner and the
//! replay are built only when these pass (BUCK).
const std = @import("std");
const format = @import("format.zig");
const runner = @import("runner.zig");
const t = std.testing;

fn parseEntries(a: std.mem.Allocator, text: []const u8) ![]format.Entry {
    var diag = format.Diag{};
    return format.parseTranscript(a, text, .{}, &diag);
}

test "a quoted word reads back every byte quote wrote" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, k| b.* = @intCast(k);
    const samples = [_][]const u8{ "", "plain", "a \"q\" \\ b", "tab\there\r\n", "\xc3\xa9 \xef\xbf\xbd", "\xff\xc3", &all };
    for (samples) |s| {
        var buf = std.ArrayList(u8).init(a);
        try format.quote(&buf, s);
        var diag = format.Diag{};
        const w = try format.parseLine(a, buf.items, 1, &diag);
        try t.expectEqual(@as(usize, 1), w.len);
        try t.expect(w[0].quoted);
        try t.expectEqualSlices(u8, s, w[0].bytes);
    }
}

test "quote keeps valid UTF-8 readable and escapes a broken sequence" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var buf = std.ArrayList(u8).init(arena.allocator());
    try format.quote(&buf, "\xc3\xa9\xc3\x1b");
    try t.expectEqualStrings("\"\xc3\xa9\\xc3\\x1b\"", buf.items);
}

test "a malformed word is refused, never read as something else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diag = format.Diag{};
    for ([_][]const u8{ "\"open", "\"a\\q\"", "\"a\\x1\"", "\"a\"b", "\"ends\\" }) |bad| {
        try t.expectError(error.Syntax, format.parseLine(arena.allocator(), bad, 1, &diag));
    }
}

test "a body concatenates quoted words and repeats" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag = format.Diag{};
    const w = try format.parseLine(a, "\"ab\" *3 \"x\" \"\\n\"", 1, &diag);
    try t.expectEqualStrings("abxxx\n", try format.body(a, w, .{}, 1, &diag));
    const f = try format.parseLine(a, "@stdout", 1, &diag);
    try t.expectError(error.Syntax, format.body(a, f, .{}, 1, &diag));
}

test "a transcript: entries, bodies, exit or signal, and its rendering reads back" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text =
        \\# a comment
        \\call buck2 "cquery" "rdeps(//..., set(//a:))"
        \\exit 0
        \\stdout "//a:a\n"
        \\stdout "//b:b\n"
        \\call git "cat-file" "-e" "base:a b/BUCK"
        \\signal 9
        \\stderr *2 "e"
    ;
    const e = try parseEntries(a, text);
    try t.expectEqual(@as(usize, 2), e.len);
    try t.expectEqualStrings("buck2", e[0].argv[0]);
    try t.expectEqualStrings("rdeps(//..., set(//a:))", e[0].argv[2]);
    try t.expectEqualStrings("//a:a\n//b:b\n", e[0].stdout);
    try t.expectEqual(format.End{ .exit = 0 }, e[0].end);
    try t.expectEqual(format.End{ .signal = 9 }, e[1].end);
    try t.expectEqualStrings("ee", e[1].stderr);
    const back = try parseEntries(a, try format.renderTranscript(a, e));
    try t.expectEqual(e.len, back.len);
    for (e, back) |x, y| {
        try t.expect(format.sameCall(x.argv, y.argv));
        try t.expectEqualStrings(x.stdout, y.stdout);
        try t.expectEqualStrings(x.stderr, y.stderr);
        try t.expectEqual(x.end, y.end);
    }
}

test "a transcript entry with no end, or a program path, is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.Syntax, parseEntries(arena.allocator(), "call buck2 \"x\"\nstdout \"y\""));
    try t.expectError(error.Syntax, parseEntries(arena.allocator(), "call ./buck2 \"x\"\nexit 0"));
    try t.expectError(error.Syntax, parseEntries(arena.allocator(), "exit 0"));
}

test "a call is answered by the next entry with its exact argv" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const e = try parseEntries(arena.allocator(), "call git \"a\"\nexit 0\ncall buck2 \"a\"\nexit 1\ncall git \"a\"\nexit 2");
    const git_a = [_][]const u8{ "/x/.parity/bin/git", "a" };
    try t.expectEqual(@as(?usize, 0), format.answerIndex(e, &git_a, 0));
    try t.expectEqual(@as(?usize, 2), format.answerIndex(e, &git_a, 1));
    try t.expectEqual(@as(?usize, null), format.answerIndex(e, &git_a, 2));
    const git_b = [_][]const u8{ "git", "a " };
    try t.expectEqual(@as(?usize, null), format.answerIndex(e, &git_b, 0));
    const buck_more = [_][]const u8{ "buck2", "a", "b" };
    try t.expectEqual(@as(?usize, null), format.answerIndex(e, &buck_more, 0));
}

test "case.txt: argv, inputs, tree, exit, divergences" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag = format.Diag{};
    const c = try format.parseCase(a,
        \\arg "--files"
        \\arg "{changed_files}"
        \\input changed_files "src/a/a.mojo\n"
        \\file "src/a/BUCK"
        \\exit 10
        \\alt stderr "not found" "No such file"
    , .{}, &diag);
    try t.expectEqual(@as(usize, 2), c.args.len);
    try t.expectEqual(@as(u8, 10), c.exit);
    try t.expectEqualStrings("", c.files[0].bytes);
    try t.expectEqualStrings("--files .parity/in/changed_files", try std.mem.join(a, " ", &.{ c.args[0], try runner.bindArg(a, c.args[1], c.inputs) }));
    try t.expectError(error.Syntax, format.parseCase(a, "arg \"x\"", .{}, &diag));
    try t.expectError(error.Syntax, format.parseCase(a, "exit 0\nfile \"../out\"", .{}, &diag));
    try t.expectError(error.Syntax, format.parseCase(a, "exit 0\nfile \".parity/transcript\"", .{}, &diag));
    try t.expectError(error.Syntax, format.parseCase(a, "exit 0\nfile \"buck2\"", .{}, &diag));
}

test "the timing of affected's summary and of --json is normalized, nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "affected: AFFECTED: 2 target(s) from 1 file(s), 1 seed(s), 12.034s", "affected: AFFECTED: 2 target(s) from 1 file(s), 1 seed(s), #.###s" },
        .{ "affected: WIDENED: 0 target(s) from 1 file(s), 0 seed(s), 0.007s -- 'a, 1.000s' matches", "affected: WIDENED: 0 target(s) from 1 file(s), 0 seed(s), #.###s -- 'a, 1.000s' matches" },
        .{ "affected: coverage: 3 target(s) no unit builds or depends on, 0.100s", "affected: coverage: 3 target(s) no unit builds or depends on, #.###s" },
        .{ "affected: WARN no target owns: a, 1.000s", "affected: WARN no target owns: a, 1.000s" },
        .{ "affected: cannot tell: x, 1.000s", "affected: cannot tell: x, 1.000s" },
        .{ "derive_checks: 1 targets, 0.100s", "derive_checks: 1 targets, 0.100s" },
        .{ "{\"verdict\":\"EMPTY\",\"milliseconds\":1234,\"targets\":[]}", "{\"verdict\":\"EMPTY\",\"milliseconds\":#,\"targets\":[]}" },
    };
    for (cases) |c| try t.expectEqualStrings(c[1], try runner.normalize(a, c[0]));
    try t.expectEqualStrings("x\n, 1.234s\n", try runner.normalize(a, "x\n, 1.234s\n"));
}

const golden_ok = runner.Golden{ .exit = 10, .stdout = "//a:a\n", .stderr = "affected: WIDENED: 1 target(s) from 1 file(s), 0 seed(s), #.###s -- why\n", .alts = &.{} };

fn actualOk(calls: []const format.Call) runner.Actual {
    return .{ .term = .{ .exited = 10 }, .stdout = "//a:a\n", .stderr = "affected: WIDENED: 1 target(s) from 1 file(s), 0 seed(s), 0.250s -- why\n", .calls = calls };
}

const call_q = [_][]const u8{ "buck2", "cquery", "//..." };
const call_t = [_][]const u8{ "buck2", "targets", "//..." };

fn twoEntries(a: std.mem.Allocator) ![]format.Entry {
    return parseEntries(a, "call buck2 \"cquery\" \"//...\"\nexit 0\ncall buck2 \"targets\" \"//...\"\nexit 0\nstdout \"//a:a\\n\"");
}

test "a run that matches every golden and makes every recorded call passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calls = [_]format.Call{ .{ .recorded = true, .argv = &call_t }, .{ .recorded = true, .argv = &call_q } };
    const f = try runner.check(a, golden_ok, try twoEntries(a), actualOk(&calls));
    try t.expectEqual(@as(usize, 0), f.len);
}

fn failuresOf(a: std.mem.Allocator, golden: runner.Golden, actual: runner.Actual) ![]const []const u8 {
    return runner.check(a, golden, try twoEntries(a), actual);
}

test "each stream and the exit code is compared: one byte off fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calls = [_]format.Call{ .{ .recorded = true, .argv = &call_q }, .{ .recorded = true, .argv = &call_t } };
    var x = actualOk(&calls);
    x.stdout = "//a:b\n";
    try t.expectEqual(@as(usize, 1), (try failuresOf(a, golden_ok, x)).len);
    x = actualOk(&calls);
    x.stderr = "affected: WIDENED: 1 target(s) from 1 file(s), 0 seed(s), 0.250s -- whY\n";
    const f = try failuresOf(a, golden_ok, x);
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expect(std.mem.startsWith(u8, f[0], "stderr differs"));
    x = actualOk(&calls);
    x.term = .{ .exited = 0 };
    try t.expectEqual(@as(usize, 1), (try failuresOf(a, golden_ok, x)).len);
    x = actualOk(&calls);
    x.term = .{ .signaled = 9 };
    try t.expectEqual(@as(usize, 1), (try failuresOf(a, golden_ok, x)).len);
}

test "an extra, a missing, a repeated or an unrecorded call fails" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const missing = [_]format.Call{.{ .recorded = true, .argv = &call_q }};
    const f1 = try failuresOf(a, golden_ok, actualOk(&missing));
    try t.expectEqual(@as(usize, 1), f1.len);
    try t.expect(std.mem.startsWith(u8, f1[0], "a recorded call the subject never made"));
    const repeated = [_]format.Call{ .{ .recorded = true, .argv = &call_q }, .{ .recorded = true, .argv = &call_t }, .{ .recorded = true, .argv = &call_q } };
    try t.expectEqual(@as(usize, 1), (try failuresOf(a, golden_ok, actualOk(&repeated))).len);
    const unrecorded = [_]format.Call{ .{ .recorded = true, .argv = &call_q }, .{ .recorded = true, .argv = &call_t }, .{ .recorded = false, .argv = &call_q } };
    const f3 = try failuresOf(a, golden_ok, actualOk(&unrecorded));
    try t.expectEqual(@as(usize, 1), f3.len);
    try t.expect(std.mem.startsWith(u8, f3[0], "unrecorded call"));
}

test "a declared divergence is the only text allowed to differ" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const calls = [_]format.Call{ .{ .recorded = true, .argv = &call_q }, .{ .recorded = true, .argv = &call_t } };
    var g = golden_ok;
    g.stderr = "affected: see affected.mojo\n";
    g.alts = &.{.{ .stream = .stderr, .golden = "affected.mojo", .other = "affected.zig" }};
    var x = actualOk(&calls);
    x.stderr = "affected: see affected.zig\n";
    try t.expectEqual(@as(usize, 0), (try failuresOf(a, g, x)).len);
    x.stderr = "affected: see affected.zig!\n";
    try t.expectEqual(@as(usize, 1), (try failuresOf(a, g, x)).len);
    x.stdout = "//a:a\naffected.zig\n";
    try t.expectEqual(@as(usize, 2), (try failuresOf(a, g, x)).len);
}

test "the BUCK files of the tree are the listed ones, CR dropped" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const e = try parseEntries(a, "call git \"ls-files\" \"--\"\nexit 0\nstdout \"BUCK\\nsrc/a/BUCK\\r\\n\\n\"\ncall git \"diff\"\nexit 0\nstdout \"x/BUCK\\n\"");
    const p = try runner.listedBuckFiles(a, e);
    try t.expectEqual(@as(usize, 2), p.len);
    try t.expectEqualStrings("BUCK", p[0]);
    try t.expectEqualStrings("src/a/BUCK", p[1]);
}
