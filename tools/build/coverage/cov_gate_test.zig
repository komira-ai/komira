//! Unit tests of cov_gate.zig's parts. The whole gate, over a real covcheck, is
//! run by the fixtures of tests//negative/coverage (coverage_gate_tests.sh,
//! test 46): a library below the target, with no test, with an unmeasured file,
//! a full one, a held one, a test-only package.
const std = @import("std");
const G = @import("cov_gate.zig");
const t = std.testing;

test "validPackage: a repository directory, or (root)" {
    try t.expect(G.validPackage("src/komira_json"));
    try t.expect(G.validPackage("(root)"));
    try t.expect(G.validPackage("a"));
    try t.expect(!G.validPackage(""));
    try t.expect(!G.validPackage("/src/a"));
    try t.expect(!G.validPackage("src/a/"));
    try t.expect(!G.validPackage("src//a"));
}

test "validTarget: digits" {
    try t.expect(G.validTarget("0"));
    try t.expect(G.validTarget("9900"));
    try t.expect(!G.validTarget(""));
    try t.expect(!G.validTarget("99.0"));
    try t.expect(!G.validTarget("-1"));
    try t.expect(!G.validTarget("99%"));
}

test "parseTail: reports, then branch records after --branch-lcov; --info-package first" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: []const u8 = "";
    const r = try G.parseTail(a, "src/x", &.{ "r1.xml", "r2.xml", "--branch-lcov", "b1.info", "b2.info" }, &diag);
    try t.expect(r.info == null);
    try t.expectEqual(@as(usize, 4), r.inputs.len);
    try t.expectEqualStrings("--cobertura", r.inputs[0].flag);
    try t.expectEqualStrings("r2.xml", r.inputs[1].path);
    try t.expectEqualStrings("--branch-lcov", r.inputs[2].flag);
    try t.expectEqualStrings("b2.info", r.inputs[3].path);
    const i = try G.parseTail(a, "src/x", &.{ "--info-package", "src/x", "r.xml" }, &diag);
    try t.expectEqualStrings("src/x", i.info.?);
    try t.expectEqual(@as(usize, 1), i.inputs.len);
    const none = try G.parseTail(a, "src/x", &.{}, &diag);
    try t.expectEqual(@as(usize, 0), none.inputs.len);
    // A second --branch-lcov is a branch record file's name.
    const twice = try G.parseTail(a, "p", &.{ "--branch-lcov", "--branch-lcov" }, &diag);
    try t.expectEqual(@as(usize, 1), twice.inputs.len);
    try t.expectEqualStrings("--branch-lcov", twice.inputs[0].path);
    try t.expectEqualStrings("--branch-lcov", twice.inputs[0].flag);
}

test "parseTail: --info-package must name the package" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: []const u8 = "";
    try t.expectError(error.Usage, G.parseTail(a, "src/x", &.{ "--info-package", "src/y" }, &diag));
    try t.expectEqualStrings("--info-package must name the package src/x", diag);
    try t.expectError(error.Usage, G.parseTail(a, "src/x", &.{"--info-package"}, &diag));
}

test "repoFiles: regular files under the root, at their paths, sorted bytewise" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/p/tests");
    for ([_][]const u8{ "src/p/BUCK", "src/p/a.mojo", "src/p/B.mojo", "src/p/tests/test_a.mojo", "z" }) |f| {
        const h = try tmp.dir.createFile(f, .{});
        h.close();
    }
    try tmp.dir.symLink("z", "link", .{});
    const files = try G.repoFiles(a, tmp.dir);
    const want = [_][]const u8{ "src/p/B.mojo", "src/p/BUCK", "src/p/a.mojo", "src/p/tests/test_a.mojo", "z" };
    try t.expectEqual(want.len, files.len);
    for (want, files) |w, g| try t.expectEqualStrings(w, g);
}

test "nulSeparated, testSources, inputArg, libraryName" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualSlices(u8, "a\x00bc\x00", try G.nulSeparated(a, &.{ "a", "bc" }));
    try t.expectEqualSlices(u8, "", try G.nulSeparated(a, &.{}));
    const ts = try G.testSources(a, "src/p/tests/t1.mojo\nsrc/p/t2.mojo\nunterminated");
    try t.expectEqual(@as(usize, 2), ts.len);
    try t.expectEqualStrings("src/p/t2.mojo", ts[1]);
    try t.expectEqual(@as(usize, 0), (try G.testSources(a, "")).len);
    try t.expectEqualStrings("/w/r.xml", try G.inputArg(a, "/w/r.xml"));
    try t.expectEqualStrings("=/w/a=b.xml", try G.inputArg(a, "/w/a=b.xml"));
    try t.expectEqualStrings("covlow", G.libraryName("tests//negative/coverage:covlow [coverage gate]"));
    try t.expectEqualStrings("lib", G.libraryName("komira//src/a:lib"));
    try t.expectEqualStrings("plain", G.libraryName("plain"));
}

test "exitCodeOf" {
    try t.expectEqual(@as(u8, 3), G.exitCodeOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 137), G.exitCodeOf(.{ .Signal = 9 }));
}
