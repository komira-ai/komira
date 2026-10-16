//! Unit tests of cov_run.zig's parts: the arguments and their refusals, the names a
//! test binary holds, the gate's stderr, copies that follow links. The whole run
//! (kcov under the gate, the report normalized) is run by the coverage fixtures of
//! tests//negative/coverage and tests//functional/coverage (tests 41 to 47).
const std = @import("std");
const C = @import("cov_run.zig");
const t = std.testing;

fn base() [13][]const u8 {
    return .{ "bb", "gate", "tc", "//x:y [coverage]", "bin", "share", "buck-out/v2/art/src/imp", "o.xml", "o.passed", "src/imp/", "tests/test_a.mojo", "src/imp/tests/test_a.mojo", "imp" };
}

fn parseOf(a: std.mem.Allocator, extra: []const []const u8, diag: *[]const u8) !C.Args {
    var v = std.ArrayList([]const u8).init(a);
    const b = base();
    try v.appendSlice(&b);
    try v.appendSlice(extra);
    return C.parse(a, v.items, diag);
}

fn refused(a: std.mem.Allocator, argv: []const []const u8, want: []const u8) !void {
    var diag: []const u8 = "";
    try t.expectError(error.Usage, C.parse(a, argv, &diag));
    try t.expectEqualStrings(want, diag);
}

test "parse: the thirteen positional arguments, then --solib, --gen and the gate's own" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: []const u8 = "";
    const p = try parseOf(a, &.{ "--gen", "g/x.mojo", "--gen", "y.mojo", "--env", "A=1", "--env", "B=2" }, &diag);
    try t.expectEqualStrings("imp", p.import);
    try t.expect(p.solib == null);
    try t.expectEqual(@as(usize, 2), p.gen.len);
    try t.expectEqualStrings("y.mojo", p.gen[1]);
    try t.expectEqual(@as(usize, 4), p.rest.len);
    try t.expectEqualStrings("--env", p.rest[0]);
    const s = try parseOf(a, &.{ "--solib", "lib/libx.so", "--solib-src", "x/a.mojo", "--solib-src", "b.mojo", "--gen", "g" }, &diag);
    try t.expectEqualStrings("lib/libx.so", s.solib.?);
    try t.expectEqual(@as(usize, 2), s.solib_srcs.len);
    try t.expectEqual(@as(usize, 1), s.gen.len);
}

test "parse: refusals" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: []const u8 = "";
    try refused(a, &.{"bb"}, "usage error");
    var b = base();
    b[6] = "/abs/src/imp";
    try refused(a, &b, "<src_dir> /abs/src/imp must be a relative path from the action's directory");
    b = base();
    b[6] = "x/src/other";
    try refused(a, &b, "<src_dir> x/src/other does not end in src/imp");
    b = base();
    b[6] = "src/imp"; // no directory before src/
    try refused(a, &b, "<src_dir> src/imp does not end in src/imp");
    b = base();
    b[10] = "dir/";
    try refused(a, &b, "<test> dir/ must be a relative file path");
    b = base();
    b[11] = "";
    try refused(a, &b, "<test_repo>  must be a relative file path");
    b = base();
    b[9] = "src/imp";
    try refused(a, &b, "<src_repo> src/imp must be empty or relative with a trailing /");
    b = base();
    b[9] = "/src/";
    try refused(a, &b, "<src_repo> /src/ must be empty or relative with a trailing /");
    b = base();
    b[12] = "im-p";
    try refused(a, &b, "<import> im-p is not an import name");
    try t.expectError(error.Usage, parseOf(a, &.{"--solib"}, &diag));
    try t.expectEqualStrings("--solib needs a file", diag);
    try t.expectError(error.Usage, parseOf(a, &.{ "--solib", "/abs.so" }, &diag));
    try t.expectError(error.Usage, parseOf(a, &.{ "--solib", "a.so", "--solib-src", "buck-out/x.mojo" }, &diag));
    try t.expectError(error.Usage, parseOf(a, &.{ "--solib", "a.so", "--solib-src", "has space.mojo" }, &diag));
    try t.expectError(error.Usage, parseOf(a, &.{ "--solib", "a.so", "--solib-src", "a:b.mojo" }, &diag));
    try t.expectError(error.Usage, parseOf(a, &.{ "--gen", "a,b.mojo" }, &diag));
    try t.expectEqualStrings("--gen a,b.mojo must be a relative path without a space, , or :", diag);
    // With --solib, <test_repo> is a directory then <test>.
    b = base();
    b[11] = "src/imp/other.mojo";
    var v = std.ArrayList([]const u8).init(a);
    try v.appendSlice(&b);
    try v.appendSlice(&.{ "--solib", "a.so" });
    try t.expectError(error.Usage, C.parse(a, v.items, &diag));
    try t.expectEqualStrings("with --solib, <test_repo> src/imp/other.mojo must be a directory then <test> tests/test_a.mojo", diag);
}

test "pkgRepo, dirPart, parseLimit" {
    try t.expectEqualStrings("", C.pkgRepo("test_a.mojo", "test_a.mojo").?);
    try t.expectEqualStrings("src/imp/", C.pkgRepo("src/imp/tests/test_a.mojo", "tests/test_a.mojo").?);
    try t.expect(C.pkgRepo("src/imp/x.mojo", "tests/test_a.mojo") == null);
    try t.expect(C.pkgRepo("xtests/test_a.mojo", "tests/test_a.mojo") == null);
    try t.expectEqualStrings("tests/", C.dirPart("tests/test_a.mojo"));
    try t.expectEqualStrings("", C.dirPart("test_a.mojo"));
    try t.expectEqualStrings("450", C.parseLimit("450\n").?);
    try t.expect(C.parseLimit("") == null);
    try t.expect(C.parseLimit("0\n") == null);
    try t.expect(C.parseLimit("045") == null);
    try t.expect(C.parseLimit("4x5") == null);
}

test "strings: runs of printable bytes, one byte long included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ss = try C.strings(arena.allocator(), "ab\x00c\x01\x02de f\tg\xffh");
    try t.expectEqual(@as(usize, 4), ss.len);
    try t.expectEqualStrings("ab", ss[0]);
    try t.expectEqualStrings("c", ss[1]);
    try t.expectEqualStrings("de f\tg", ss[2]);
    try t.expectEqualStrings("h", ss[3]);
}

test "buckNames: the maximal runs of path characters that hold buck-out/" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ns = try C.buckNames(a, &.{ "see /w/buck-out/v2/art/x.mojo: here", "no path", "a=b buck-out/v2 c", "buck-out/ buck-out/y" });
    try t.expectEqual(@as(usize, 4), ns.len);
    try t.expectEqualStrings("/w/buck-out/v2/art/x.mojo", ns[0]);
    try t.expectEqualStrings("buck-out/v2", ns[1]);
    try t.expectEqualStrings("buck-out/", ns[2]);
    try t.expectEqualStrings("buck-out/y", ns[3]);
}

test "elsewhere: a [src] of the library named inside an artifact, cut after the last src/<import>" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const names = [_][]const u8{
        "buck-out/v2/art/komira/src/imp/__imp__/abc/src/imp/mod.mojo",
        "buck-out/v2/art/komira/src/imp/__imp__/abc/src/imp",
        "buck-out/v2/art/komira/src/imp/__imp__/abc/src/impx/mod.mojo",
        "buck-out/v2/art/komira/src/imp/mod.mojo",
        "buck-out/v2/art/komira/__imp__/src/other/a.mojo",
        "/x/__a__/y/src/imp/z/src/imp/",
    };
    const got = try C.elsewhere(a, &names, "imp");
    // The first two of the names give one directory; the sort puts `/` before `b`.
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("/x/__a__/y/src/imp/z/src/imp", got[0]);
    try t.expectEqualStrings("buck-out/v2/art/komira/src/imp/__imp__/abc/src/imp", got[1]);
}

test "elsewhere: the artifact component must be __x__ and the library after it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqual(@as(usize, 0), (try C.elsewhere(a, &.{"buck-out/src/imp/x"}, "imp")).len);
    try t.expectEqual(@as(usize, 0), (try C.elsewhere(a, &.{"buck-out/__/src/imp/x"}, "imp")).len);
    try t.expectEqual(@as(usize, 0), (try C.elsewhere(a, &.{"buck-out/src/imp/__a__/x"}, "imp")).len);
    // The artifact's directory is followed by a directory of its own (the hash) before src/.
    try t.expectEqual(@as(usize, 0), (try C.elsewhere(a, &.{"buck-out/__a__/src/imp"}, "imp")).len);
    try t.expectEqual(@as(usize, 1), (try C.elsewhere(a, &.{"buck-out/__a__/h/src/imp"}, "imp")).len);
}

test "holdsCode, firstCodeName, namesStage" {
    try t.expect(C.holdsCode(&.{ "x", "imp::foo::Bar" }, "imp"));
    try t.expect(C.holdsCode(&.{"call imp::f"}, "imp"));
    try t.expect(!C.holdsCode(&.{"ximp::f"}, "imp"));
    try t.expect(!C.holdsCode(&.{ "imp:", "imp :: x", "imp" }, "imp"));
    try t.expectEqualStrings("imp::foo::Bar", C.firstCodeName(&.{ "a", "see imp::foo::Bar(x" }, "imp").?);
    try t.expectEqualStrings("imp::f", C.firstCodeName(&.{"ximp::f"}, "imp").?);
    try t.expect(C.firstCodeName(&.{"nothing"}, "imp") == null);
    try t.expect(C.namesStage(&.{ "a", "imp" }, "imp"));
    try t.expect(C.namesStage(&.{"imp/mod.mojo"}, "imp"));
    try t.expect(!C.namesStage(&.{ "imp2", "ximp", "imp ", "/imp/x" }, "imp"));
}

test "filterGateErr: the release gate's header pair goes; a header followed by another line stays" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "before\nGATED TEST FAILED: L (exit 3)\nThe library's package is not produced until this test passes.\nafter\n";
    try t.expectEqualStrings("before\nafter\n", try C.filterGateErr(a, text, "L", 3));
    const other = "GATED TEST FAILED: L (exit 3)\nsomething else\nThe library's package is not produced until this test passes.\n";
    try t.expectEqualStrings("GATED TEST FAILED: L (exit 3)\nsomething else\nThe library's package is not produced until this test passes.\n", try C.filterGateErr(a, other, "L", 3));
    // Another label or exit status is not the header.
    try t.expectEqualStrings(text, try C.filterGateErr(a, text, "M", 3));
    try t.expectEqualStrings("", try C.filterGateErr(a, "", "L", 1));
}

test "failureWhy: ptrace or personality refused, kcov's own failure, or the test's" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Can't set me as ptraced: Operation not permitted\n", "x\nCan't set personality: EPERM\n", "Can't get personality: x\n", "Can't attach to 123: x\n" }) |e| {
        try t.expect(std.mem.startsWith(u8, try C.failureWhy(a, e, 1), "kcov could not trace the test"));
    }
    try t.expect(std.mem.startsWith(u8, try C.failureWhy(a, "kcov: error: no such file\n", 1), "kcov itself failed"));
    try t.expect(std.mem.startsWith(u8, try C.failureWhy(a, "Usage: kcov [OPTIONS]\n", 1), "kcov itself failed"));
    // A line that merely contains the text (the test's own output) is not kcov's.
    try t.expect(std.mem.startsWith(u8, try C.failureWhy(a, "the test said kcov: error: x\n", 7), "The test failed under kcov (exit 7)"));
    try t.expect(std.mem.startsWith(u8, try C.failureWhy(a, "Can't attach to x\n", 2), "The test failed under kcov (exit 2)"));
}

test "copyTreeDeref follows links, as cp -RL" {
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/dir");
    try tmp.dir.makePath("elsewhere");
    {
        const f = try tmp.dir.createFile("elsewhere/real.txt", .{});
        defer f.close();
        try f.writeAll("real");
        const g = try tmp.dir.createFile("src/dir/plain.txt", .{ .mode = 0o755 });
        defer g.close();
        try g.writeAll("plain");
    }
    try tmp.dir.symLink("../../elsewhere/real.txt", "src/dir/link.txt", .{});
    try tmp.dir.symLink("../elsewhere", "src/dirlink", .{});
    try tmp.dir.symLink("nowhere", "src/dangling", .{});
    try tmp.dir.makePath("dst");
    var s = try tmp.dir.openDir("src", .{ .iterate = true });
    defer s.close();
    var d = try tmp.dir.openDir("dst", .{ .iterate = true });
    defer d.close();
    try C.copyTreeDeref(s, d);
    var buf: [16]u8 = undefined;
    try t.expectEqualStrings("real", try d.readFile("dir/link.txt", &buf));
    try t.expectEqualStrings("real", try d.readFile("dirlink/real.txt", &buf));
    try t.expectEqualStrings("plain", try d.readFile("dir/plain.txt", &buf));
    try t.expect((try d.statFile("dir/plain.txt")).mode & 0o100 != 0);
    // A copy, not a link.
    try t.expectError(error.NotLink, d.readLink("dir/link.txt", &buf));
    try t.expectError(error.FileNotFound, d.statFile("dangling"));
}

test "exitCodeOf" {
    try t.expectEqual(@as(u8, 3), C.exitCodeOf(.{ .Exited = 3 }));
    try t.expectEqual(@as(u8, 139), C.exitCodeOf(.{ .Signal = 11 }));
}
