//! Unit tests of test_weld.zig: how the .mojo files are classified into packages,
//! sources and test files, the ledger's rows and refusals, and each finding. The
//! whole lint, over the real tree and its ledger, is the pull request check's
//! `buck2 bxl tools/build/lint/test_weld.bxl:check -- --lint //:test_weld`.
const std = @import("std");
const W = @import("test_weld.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

const mojo = [_][]const u8{
    "src/a/__init__.mojo",
    "src/a/x.mojo",
    "src/a/tests/test_x.mojo",
    "src/a/tests/helper.mojo",
    "src/a/tests/sub/test_deep.mojo",
    "src/b/b.mojo",
    "src/c/tests/test_c.mojo",
    "src/loose.mojo",
    "src/tests/e2e/foo/foo.mojo",
    "src/tests/e2e/foo/tests/test_foo.mojo",
    "src/tests/e2e/top.mojo",
    "src/tests/e2e/bar/tests/test_bar.mojo",
};

test "classify: sources, test files, welded or not; the tests/ tree holds packages by kind" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const welded = [_][]const u8{ "src/a/tests/test_x.mojo", "src/tests/e2e/foo/tests/test_foo.mojo" };
    const cs = try W.classify(a, "src", &mojo, &welded);
    // helper.mojo is neither a source nor a test; loose.mojo and tests/e2e/top.mojo are in no package.
    var src_a: usize = 0;
    var tests_a: usize = 0;
    var found_foo = false;
    for (cs) |c| {
        if (std.mem.eql(u8, c.pkg, "a") and c.is_src) src_a += 1;
        if (std.mem.eql(u8, c.pkg, "a") and !c.is_src) tests_a += 1;
        if (std.mem.eql(u8, c.pkg, "tests/e2e/foo")) {
            if (c.is_src) found_foo = true;
        }
        try t.expect(!std.mem.eql(u8, c.pkg, "tests"));
        try t.expect(!std.mem.eql(u8, c.pkg, "tests/e2e"));
    }
    try t.expectEqual(@as(usize, 2), src_a);
    try t.expectEqual(@as(usize, 2), tests_a);
    try t.expect(found_foo);
    const ps = try W.packages(a, cs);
    const names = [_][]const u8{ "a", "b", "c", "tests/e2e/bar", "tests/e2e/foo" };
    try t.expectEqual(names.len, ps.len);
    for (names, ps) |n, p| try t.expectEqualStrings(n, p.name);
    try t.expectEqual(@as(usize, 2), ps[0].src);
    try t.expectEqual(@as(usize, 1), ps[0].welded);
    try t.expectEqual(@as(usize, 0), ps[2].src);
    try t.expectEqual(@as(usize, 1), ps[4].src);
    try t.expectEqual(@as(usize, 1), ps[4].welded);
}

test "parseLedger: rows, comments, and the two refusals" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var report = std.ArrayList(u8).init(a);
    const text = "# c\n\nsrc/a\tno test yet\nsrc/b\n\t\nsrc/c\t \nsrc/a\tsecond\n  # indented comment\nsrc/d\treason with\ttab\nsrc/e\tok\n";
    const rows = try W.parseLedger(a, "ledger.tsv", text, &report);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("src/a", rows[0].path);
    try t.expectEqual(@as(usize, 3), rows[0].line);
    try t.expectEqualStrings("src/e", rows[1].path);
    try t.expectEqualStrings(
        "ledger.tsv:4: a row is <path><TAB><reason>, with a reason\n" ++
            "ledger.tsv:6: a row is <path><TAB><reason>, with a reason\n" ++
            "ledger.tsv:7: src/a has a row already, on line 3\n" ++
            "ledger.tsv:9: a row is <path><TAB><reason>, with a reason\n",
        report.items,
    );
}

fn run(a: std.mem.Allocator, welded: []const []const u8, ledger: []const u8) ![][]const u8 {
    const cs = try W.classify(a, "src", &mojo, welded);
    const ps = try W.packages(a, cs);
    var report = std.ArrayList(u8).init(a);
    const rows = try W.parseLedger(a, "ledger.tsv", ledger, &report);
    return W.findings(a, "src", "komira//", "ledger.tsv", cs, ps, rows);
}

fn has(fs: []const []const u8, want: []const u8) bool {
    for (fs) |f| {
        if (std.mem.eql(u8, f, want)) return true;
    }
    return false;
}

test "findings: a test file nothing welds, and a package with sources and no welded test" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const fs = try run(a, &.{"src/a/tests/test_x.mojo"}, "");
    try t.expect(has(fs, "komira//src/a/tests/sub/test_deep.mojo: a test file no target welds (test_srcs or a mojo_test), so it never runs; weld it, delete it, or give it a row in ledger.tsv"));
    try t.expect(has(fs, "komira//src/c/tests/test_c.mojo: a test file no target welds (test_srcs or a mojo_test), so it never runs; weld it, delete it, or give it a row in ledger.tsv"));
    try t.expect(has(fs, "komira//src/b: 1 .mojo source(s) and no welded test; weld one in test_srcs, or give the package a row in ledger.tsv"));
    try t.expect(has(fs, "komira//src/tests/e2e/foo: 1 .mojo source(s) and no welded test; weld one in test_srcs, or give the package a row in ledger.tsv"));
    // a welds a test: no finding for the package; c has no source: none either.
    for (fs) |f| {
        try t.expect(!std.mem.startsWith(u8, f, "komira//src/a: "));
        try t.expect(!std.mem.startsWith(u8, f, "komira//src/c: "));
    }
    // Sorted.
    for (fs[1..], 0..) |f, i| try t.expect(!std.mem.lessThan(u8, f, fs[i]));
}

test "findings: a ledger row excuses what it names" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const welded = [_][]const u8{ "src/a/tests/test_x.mojo", "src/tests/e2e/foo/tests/test_foo.mojo", "src/tests/e2e/bar/tests/test_bar.mojo" };
    const fs = try run(a, &welded, "src/b\tsoon\nsrc/a/tests/sub/test_deep.mojo\tfixture\nsrc/c/tests/test_c.mojo\twhy\n");
    try t.expectEqual(@as(usize, 0), fs.len);
}

test "findings: a stale row is deleted: welded test, welding package, nothing, outside root" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const welded = [_][]const u8{ "src/a/tests/test_x.mojo", "src/a/tests/sub/test_deep.mojo", "src/tests/e2e/foo/tests/test_foo.mojo" };
    const ledger = "src/a/tests/test_x.mojo\tx\nsrc/a\ty\nsrc/ghost\tz\nlib/other\tw\nsrc/a/tests/sub/test_deep.mojo\tdeep\nsrc/b\tok\nsrc/c/tests/test_c.mojo\tok\n";
    const fs = try run(a, &welded, ledger);
    try t.expect(has(fs, "ledger.tsv:1: src/a/tests/test_x.mojo: the test is welded now; delete the row (the ledger only shrinks)"));
    try t.expect(has(fs, "ledger.tsv:2: src/a: the package welds 2 test(s) now; delete the row (the ledger only shrinks)"));
    try t.expect(has(fs, "ledger.tsv:3: src/ghost: names neither a test file nor a package with a .mojo source; delete the row"));
    try t.expect(has(fs, "ledger.tsv:4: lib/other: not under src/"));
    try t.expect(has(fs, "ledger.tsv:5: src/a/tests/sub/test_deep.mojo: the test is welded now; delete the row (the ledger only shrinks)"));
    // src/c has tests and no source: a row for the package itself names nothing to excuse.
    const fs2 = try run(a, &.{}, "src/c\tx\n");
    try t.expect(has(fs2, "ledger.tsv:1: src/c: names neither a test file nor a package with a .mojo source; delete the row"));
}

test "lineList and the sorted-unique inputs" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const ls = try W.lineList(a, "b\n\na\nb\n");
    try t.expectEqual(@as(usize, 3), ls.len);
    try t.expectEqualStrings("b", ls[0]);
}
