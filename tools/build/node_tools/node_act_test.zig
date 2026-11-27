//! Unit tests of node_act's pure parts.
//! Its process behaviour (the subcommands, their messages and exit
//! statuses, the environment node is run in) is tests//functional/node_act;
//! the node rules' targets run through it too.
const std = @import("std");
const A = @import("node_act.zig");
const tartest = @import("node_tartest");
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

// ---- install-test ---------------------------------------------------------------

test "isTopManifest: the package.json of the one top directory, whatever its name" {
    try t.expect(A.isTopManifest("package/package.json"));
    try t.expect(A.isTopManifest("node v25.9/package.json"));
    try t.expect(A.isTopManifest("./package/package.json"));
    try t.expect(!A.isTopManifest("package.json"));
    try t.expect(!A.isTopManifest("/package.json"));
    try t.expect(!A.isTopManifest("package/dist/package.json"));
    try t.expect(!A.isTopManifest("package/package.json5"));
    try t.expect(!A.isTopManifest("package/"));
}

test "manifestName: the top-level name, a string that is not empty" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("@komira-ai/komira", try A.manifestName(a, "{\"version\":\"0.0.0\",\"name\":\"@komira-ai/komira\"}"));
    try t.expectError(error.NoName, A.manifestName(a, "{\"version\":\"0.0.0\"}"));
    try t.expectError(error.NoName, A.manifestName(a, "{\"name\":7}"));
    try t.expectError(error.NoName, A.manifestName(a, "{\"name\":\"\"}"));
    try t.expectError(error.NoName, A.manifestName(a, "{\"dist\":{\"name\":\"nested\"}}"));
    try t.expectError(error.NoName, A.manifestName(a, "[\"name\"]"));
    try t.expect(std.meta.isError(A.manifestName(a, "{\"name\":")));
}

test "tarballName: the name in the top package.json of a tarball, any top directory" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try tartest.tgz(a, "apache-arrow", "21.2.0", &.{.{ .name = "package/Arrow.js", .data = "export {};\n" }});
    try t.expectEqualStrings("apache-arrow", try A.tarballName(a, plain));
    const types = try tartest.gzip(a, try tartest.tar(a, &.{
        .{ .name = "node v25.9/", .kind = '5', .mode = 0o755 },
        .{ .name = "node v25.9/README.md", .data = "types\n" },
        .{ .name = "node v25.9/package.json", .data = "{\"name\":\"@types/node\",\"version\":\"25.9.9\"}" },
    }));
    try t.expectEqualStrings("@types/node", try A.tarballName(a, types));
    // A package.json deeper down is not the package's.
    const nested = try tartest.gzip(a, try tartest.tar(a, &.{
        .{ .name = "package/", .kind = '5', .mode = 0o755 },
        .{ .name = "package/sub/package.json", .data = "{\"name\":\"inner\"}" },
    }));
    try t.expectError(error.NoManifest, A.tarballName(a, nested));
    const nameless = try tartest.gzip(a, try tartest.tar(a, &.{
        .{ .name = "package/package.json", .data = "{\"version\":\"1.0.0\"}" },
    }));
    try t.expectError(error.NoName, A.tarballName(a, nameless));
    try t.expect(std.meta.isError(A.tarballName(a, "not gzip")));
}

test "projectManifest: one file: dependency, every other tarball an override, by absolute path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try A.projectManifest(
        a,
        "/s/project",
        .{ .name = "@komira-ai/komira", .file = "tarballs/komira-ai-komira-0.0.0.tgz" },
        &.{
            .{ .name = "@komira-ai/komira-linux-x64-gnu", .file = "tarballs/komira-ai-komira-linux-x64-gnu-0.0.0.tgz" },
            .{ .name = "apache-arrow", .file = "tarballs/npm-apache-arrow-21.2.0.tgz" },
        },
    );
    try t.expect(std.mem.endsWith(u8, text, "}\n"));
    const v = (try std.json.parseFromSlice(std.json.Value, a, text, .{})).value;
    try t.expectEqual(@as(usize, 6), v.object.count());
    try t.expectEqualStrings("komira-install-test", v.object.get("name").?.string);
    try t.expectEqualStrings("0.0.0", v.object.get("version").?.string);
    try t.expect(v.object.get("private").?.bool);
    try t.expectEqualStrings("module", v.object.get("type").?.string);
    const deps = v.object.get("dependencies").?.object;
    try t.expectEqual(@as(usize, 1), deps.count());
    try t.expectEqualStrings("file:/s/project/tarballs/komira-ai-komira-0.0.0.tgz", deps.get("@komira-ai/komira").?.string);
    const over = v.object.get("overrides").?.object;
    try t.expectEqual(@as(usize, 2), over.count());
    try t.expectEqualStrings("file:/s/project/tarballs/komira-ai-komira-linux-x64-gnu-0.0.0.tgz", over.get("@komira-ai/komira-linux-x64-gnu").?.string);
    try t.expectEqualStrings("file:/s/project/tarballs/npm-apache-arrow-21.2.0.tgz", over.get("apache-arrow").?.string);
    // With no other tarball, overrides is an empty object.
    const alone = (try std.json.parseFromSlice(std.json.Value, a, try A.projectManifest(a, "/p", .{ .name = "p", .file = "tarballs/p.tgz" }, &.{}), .{})).value;
    try t.expectEqual(@as(usize, 0), alone.object.get("overrides").?.object.count());
}

test "clash: a package name or a file name given twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const have = [_]A.Tarball{.{ .name = "tslib", .file = "tarballs/tslib-2.8.1.tgz" }};
    try t.expect(try A.clash(a, &have, .{ .name = "flatbuffers", .file = "tarballs/flatbuffers.tgz" }) == null);
    try t.expect(try A.clash(a, &.{}, .{ .name = "tslib", .file = "tarballs/tslib-2.8.1.tgz" }) == null);
    try t.expectEqualStrings(
        "tarballs/tslib-2.8.1.tgz and tarballs/other.tgz are both the package tslib",
        (try A.clash(a, &have, .{ .name = "tslib", .file = "tarballs/other.tgz" })).?,
    );
    try t.expectEqualStrings(
        "two tarballs are named tarballs/tslib-2.8.1.tgz",
        (try A.clash(a, &have, .{ .name = "other", .file = "tarballs/tslib-2.8.1.tgz" })).?,
    );
}

test "npmInstallArgv: offline, no install script, engines enforced, nothing of the worker's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try A.npmInstallArgv(a, "/n/bin/node", "/npm", "/s");
    const want = [_][]const u8{
        "/n/bin/node",
        "/npm/bin/npm-cli.js",
        "install",
        "--offline",
        "--ignore-scripts",
        "--engine-strict",
        "--no-audit",
        "--no-fund",
        "--no-update-notifier",
        "--loglevel=warn",
        "--cache=/s/npm-cache",
        "--userconfig=/s/npmrc",
        "--globalconfig=/s/npmrc-global",
    };
    try t.expectEqual(want.len, argv.len);
    for (want, argv) |w, g| try t.expectEqualStrings(w, g);
}

test "installScripts: the packages npm marks hasInstallScript, sorted, and nothing else" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const lock =
        \\{"name":"t","lockfileVersion":3,"packages":{
        \\  "":{"name":"t","hasInstallScript":true},
        \\  "node_modules/zz":{"version":"1.0.0","hasInstallScript":true},
        \\  "node_modules/@komira-ai/komira":{"version":"0.0.0","hasInstallScript":true},
        \\  "node_modules/tslib":{"version":"2.8.1"},
        \\  "node_modules/off":{"version":"1.0.0","hasInstallScript":false},
        \\  "node_modules/odd":{"version":"1.0.0","hasInstallScript":"yes"}
        \\}}
    ;
    const got = try A.installScripts(a, lock);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("", got[0]);
    try t.expectEqualStrings("node_modules/@komira-ai/komira", got[1]);
    try t.expectEqualStrings("node_modules/zz", got[2]);
    try t.expectEqual(@as(usize, 0), (try A.installScripts(a, "{\"packages\":{\"node_modules/a\":{\"version\":\"1.0.0\"}}}")).len);
    try t.expectError(error.NotALock, A.installScripts(a, "{\"lockfileVersion\":3}"));
    try t.expectError(error.NotALock, A.installScripts(a, "{\"packages\":[]}"));
    try t.expectError(error.NotALock, A.installScripts(a, "[]"));
    try t.expect(std.meta.isError(A.installScripts(a, "{\"packages\":")));
}
