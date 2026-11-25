//! Unit tests of node_act's pure parts.
//! Its process behaviour (the four subcommands, their messages and exit
//! statuses, the environment node is run in) is tests//functional/node_act;
//! the node rules' targets run through it too.
const std = @import("std");
const A = @import("node_act.zig");
const t = std.testing;

test "keepDist and isFile" {
    try t.expect(A.keepDist("bin/node"));
    try t.expect(A.keepDist("LICENSE"));
    try t.expect(A.keepDist("include/node"));
    try t.expect(A.keepDist("include/node/v8.h"));
    try t.expect(!A.keepDist("bin/node2"));
    try t.expect(!A.keepDist("include/node2/x"));
    try t.expect(!A.keepDist("include"));
    try t.expect(!A.keepDist("lib/node_modules/npm"));
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("d");
    {
        const f = try tmp.dir.createFile("x", .{});
        defer f.close();
        try f.chmod(0o755);
        const g = try tmp.dir.createFile("y", .{});
        defer g.close();
        try g.chmod(0o644);
    }
    try tmp.dir.symLink("x", "lx", .{});
    try t.expect(A.isFile(tmp.dir, "x", true));
    try t.expect(!A.isFile(tmp.dir, "y", true));
    try t.expect(A.isFile(tmp.dir, "y", false));
    try t.expect(!A.isFile(tmp.dir, "d", false));
    try t.expect(!A.isFile(tmp.dir, "missing", false));
    try t.expect(A.isFile(tmp.dir, "lx", true));
}

test "sri: the shape, and the digest the base64 holds as hex" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try A.sriShape("sha512-AAAA");
    try t.expectError(error.NotSha512, A.sriShape("sha512-"));
    try t.expectError(error.NotSha512, A.sriShape("sha256-AAAA"));
    try t.expectError(error.NotSha512, A.sriShape("xsha512-AAAA"));
    try t.expectError(error.NotSha512, A.sriShape(""));
    var digest: [64]u8 = undefined;
    std.crypto.hash.sha2.Sha512.hash("abc", &digest, .{});
    const b64 = try a.alloc(u8, std.base64.standard.Encoder.calcSize(64));
    _ = std.base64.standard.Encoder.encode(b64, &digest);
    const sri = try std.fmt.allocPrint(a, "sha512-{s}", .{b64});
    const hex = try A.sriHex(a, sri);
    try t.expectEqualStrings(&std.fmt.bytesToHex(digest, .lower), hex);
    try t.expectEqualStrings("0" ** 128, try A.sriHex(a, "sha512-" ++ "A" ** 86 ++ "=="));
    try t.expectEqualStrings("", try A.sriHex(a, "sha512-!!!!"));
}

test "environments: the tests' fixed five, and the library path alone" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env = try A.testEnv(a, "/s", "/libs");
    try t.expectEqual(@as(u32, 5), env.count());
    try t.expectEqualStrings("C", env.get("LC_ALL").?);
    try t.expectEqualStrings("UTC0", env.get("TZ").?);
    try t.expectEqualStrings("/s/home", env.get("HOME").?);
    try t.expectEqualStrings("/s/tmp", env.get("TMPDIR").?);
    try t.expectEqualStrings("/libs/lib", env.get("LD_LIBRARY_PATH").?);
    const e2 = try A.libsEnv(a, "/libs");
    try t.expectEqual(@as(u32, 1), e2.count());
    try t.expectEqualStrings("/libs/lib", e2.get("LD_LIBRARY_PATH").?);
}

const tap_ok = "TAP version 13\n1..1\n# tests 3\n# suites 0\n# pass 3\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n# duration_ms 41.2\n";

test "tapCount reads a summary line by its whole key, last one winning" {
    try t.expectEqual(@as(?u64, 3), A.tapCount(tap_ok, "tests"));
    try t.expectEqual(@as(?u64, 3), A.tapCount(tap_ok, "pass"));
    try t.expectEqual(@as(?u64, 0), A.tapCount(tap_ok, "fail"));
    // "test" is not "tests", and a line that is not a summary line is not read.
    try t.expectEqual(@as(?u64, null), A.tapCount(tap_ok, "test"));
    try t.expectEqual(@as(?u64, null), A.tapCount("ok 1 - # tests 9\n", "tests"));
    try t.expectEqual(@as(?u64, 2), A.tapCount("# tests 1\n# tests 2\n", "tests"));
    try t.expectEqual(@as(?u64, null), A.tapCount("# tests many\n", "tests"));
    try t.expectEqual(@as(?u64, null), A.tapCount("# tests\n", "tests"));
}

test "tapRefusal: a run counts only if tests ran, all passed and none was skipped" {
    try t.expect(A.tapRefusal(tap_ok) == null);
    try t.expectEqualStrings("it ran no test", A.tapRefusal("# tests 0\n# pass 0\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n").?);
    try t.expect(A.tapRefusal("1..0\n") != null);
    try t.expect(A.tapRefusal("") != null);
    try t.expectEqualStrings("a test failed or was cancelled", A.tapRefusal("# tests 3\n# pass 3\n# fail 1\n# cancelled 0\n# skipped 0\n# todo 0\n").?);
    try t.expectEqualStrings("a test failed or was cancelled", A.tapRefusal("# tests 3\n# pass 3\n# fail 0\n# cancelled 1\n# skipped 0\n# todo 0\n").?);
    try t.expectEqualStrings("a test was skipped or left todo", A.tapRefusal("# tests 3\n# pass 3\n# fail 0\n# cancelled 0\n# skipped 1\n# todo 0\n").?);
    try t.expectEqualStrings("a test was skipped or left todo", A.tapRefusal("# tests 3\n# pass 3\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 2\n").?);
    try t.expectEqualStrings("not every test passed", A.tapRefusal("# tests 3\n# pass 2\n# fail 0\n# cancelled 0\n# skipped 0\n# todo 0\n").?);
    // A summary missing a line is refused, not read as zero.
    try t.expect(A.tapRefusal("# tests 3\n# pass 3\n# fail 0\n# cancelled 0\n# todo 0\n") != null);
}

test "fileIsTheTest: a file that registered no test is named as the one test" {
    const bare = "TAP version 13\n# Subtest: /w/a.test.mjs\nok 1 - /w/a.test.mjs\n1..1\n# tests 1\n# pass 1\n";
    try t.expect(A.fileIsTheTest(bare, "/w/a.test.mjs"));
    try t.expect(!A.fileIsTheTest(bare, "/w/b.test.mjs"));
    try t.expect(!A.fileIsTheTest(bare, "/w/a.test.mj"));
    try t.expect(!A.fileIsTheTest("# Subtest: /w/a.test.mjs.\n", "/w/a.test.mjs"));
    // A test whose name merely holds the path, or a file with tests of its own.
    try t.expect(!A.fileIsTheTest("# Subtest: reads /w/a.test.mjs\nok 1 - reads /w/a.test.mjs\n", "/w/a.test.mjs"));
    try t.expect(!A.fileIsTheTest(tap_ok, "/w/a.test.mjs"));
}

// node's lcov reporter, as it writes two files (DA, FN and BRDA lines elided).
const lcov_two = "TN:\nSF:src/a.ts\nFNF:2\nFNH:2\nBRF:5\nBRH:5\nLH:11\nLF:11\nend_of_record\nSF:/w/src/b.ts\nBRF:3\nBRH:2\nLH:1\nLF:1\nend_of_record\n";

test "parseLcov: one record per SF, its counts, a path under the directory made relative" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try A.parseLcov(a, lcov_two, "/w");
    try t.expectEqual(@as(usize, 2), files.len);
    try t.expectEqualStrings("src/a.ts", files[0].path);
    try t.expectEqual(A.FileCover{ .path = files[0].path, .lf = 11, .lh = 11, .brf = 5, .brh = 5 }, files[0]);
    try t.expectEqualStrings("src/b.ts", files[1].path);
    try t.expectEqual(A.FileCover{ .path = files[1].path, .lf = 1, .lh = 1, .brf = 3, .brh = 2 }, files[1]);
    // A path outside the directory, or one that only starts with its name, stays as written.
    const other = try A.parseLcov(a, "SF:/wx/c.ts\nend_of_record\nSF:/v/d.ts\nend_of_record\n", "/w");
    try t.expectEqualStrings("/wx/c.ts", other[0].path);
    try t.expectEqualStrings("/v/d.ts", other[1].path);
    // CR LF endings, and a record that never ends, which is not a record.
    const crlf = try A.parseLcov(a, "SF:e.ts\r\nLF:4\r\nLH:3\r\nend_of_record\r\nSF:f.ts\nLF:1\n", "");
    try t.expectEqual(@as(usize, 1), crlf.len);
    try t.expectEqual(A.FileCover{ .path = crlf[0].path, .lf = 4, .lh = 3 }, crlf[0]);
    // A count that is not a number is an error, not a zero.
    try t.expectError(error.InvalidCharacter, A.parseLcov(a, "SF:g.ts\nLF:x\nend_of_record\n", ""));
}

test "coverRefusal: every covered source loaded, lines and branches together at least 99%" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try A.parseLcov(a, lcov_two, "/w");
    // a.ts alone is fully covered.
    try t.expect(try A.coverRefusal(a, files, &.{"src/a.ts"}) == null);
    // With b.ts, 7 of 8 branches is 87.50%.
    try t.expectEqualStrings(
        "the branch coverage of the covered sources is 87.50% (7 of 8 branches), under 99%",
        (try A.coverRefusal(a, files, &.{ "src/a.ts", "src/b.ts" })).?,
    );
    // A covered source no test loaded has no record.
    try t.expectEqualStrings(
        "src/c.ts is to be covered, and no test loaded it",
        (try A.coverRefusal(a, files, &.{ "src/a.ts", "src/c.ts" })).?,
    );
    // Lines are checked before branches, and the percentage is rounded down.
    const low = [_]A.FileCover{.{ .path = "x.ts", .lf = 3, .lh = 2, .brf = 1, .brh = 0 }};
    try t.expectEqualStrings(
        "the line coverage of the covered sources is 66.66% (2 of 3 lines), under 99%",
        (try A.coverRefusal(a, &low, &.{"x.ts"})).?,
    );
    // The boundary: 99 of 100 passes, 98 of 100 and 989 of 1000 do not.
    try t.expect(try A.coverRefusal(a, &.{.{ .path = "x.ts", .lf = 100, .lh = 99, .brf = 100, .brh = 99 }}, &.{"x.ts"}) == null);
    try t.expect(try A.coverRefusal(a, &.{.{ .path = "x.ts", .lf = 100, .lh = 98 }}, &.{"x.ts"}) != null);
    try t.expectEqualStrings(
        "the branch coverage of the covered sources is 98.90% (989 of 1000 branches), under 99%",
        (try A.coverRefusal(a, &.{.{ .path = "x.ts", .brf = 1000, .brh = 989 }}, &.{"x.ts"})).?,
    );
    // A source with no line and no branch (types only) passes.
    try t.expect(try A.coverRefusal(a, &.{.{ .path = "types.ts" }}, &.{"types.ts"}) == null);
}

test "coverTable: one line per covered source, in the order given" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try A.parseLcov(a, lcov_two, "/w");
    try t.expectEqualStrings(
        "binding_test: covered src/b.ts: lines 1/1 (100.00%), branches 2/3 (66.66%)\n" ++
            "binding_test: covered src/a.ts: lines 11/11 (100.00%), branches 5/5 (100.00%)\n",
        try A.coverTable(a, files, &.{ "src/b.ts", "src/a.ts", "src/none.ts" }),
    );
}
