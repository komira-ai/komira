//! Unit tests of tests_act.zig's helpers. The subcommands' exit codes and messages
//! are driver_test.zig; the rules that use them are the tests cell's own targets.
const std = @import("std");
const T = @import("tests_act.zig");
const t = std.testing;

test "listingWords: the entries, hidden ones too, sorted, each followed by a blank" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "b.mojo", .data = "x" });
    try tmp.dir.writeFile(.{ .sub_path = ".hidden", .data = "x" });
    try tmp.dir.makePath("a_dir/inner");
    try tmp.dir.writeFile(.{ .sub_path = "a_dir/inner/f", .data = "x" });
    try t.expectEqualStrings(".hidden a_dir b.mojo ", try T.listingWords(a, tmp.dir));
}

test "grepFiles: files under the directory, nested, that hold the string, sorted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("d/e");
    try tmp.dir.writeFile(.{ .sub_path = "d/e/z.txt", .data = "has needle here" });
    try tmp.dir.writeFile(.{ .sub_path = "d/a.txt", .data = "needle" });
    try tmp.dir.writeFile(.{ .sub_path = "d/none.txt", .data = "nothing" });
    const hits = try T.grepFiles(a, tmp.dir, "gen", "needle");
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqualStrings("gen/d/a.txt", hits[0]);
    try t.expectEqualStrings("gen/d/e/z.txt", hits[1]);
    try t.expectEqual(@as(usize, 0), (try T.grepFiles(a, tmp.dir, "gen", "absent")).len);
}

test "hasPassLine: a line that starts with PASS and a blank" {
    try t.expect(T.hasPassLine("PASS test_x\n"));
    try t.expect(T.hasPassLine("note\nPASS ok"));
    try t.expect(!T.hasPassLine("FAIL test_x\n"));
    try t.expect(!T.hasPassLine("a PASS b\n"));
    try t.expect(!T.hasPassLine("PASSED\n"));
}

test "copyTree: directories, files with the executable bit, links kept" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/bin");
    try tmp.dir.makePath("dst");
    {
        const f = try tmp.dir.createFile("src/bin/tool", .{ .mode = 0o755 });
        defer f.close();
        try f.writeAll("elf");
    }
    try tmp.dir.writeFile(.{ .sub_path = "src/data", .data = "d" });
    try tmp.dir.symLink("tool", "src/bin/alias", .{});
    var s = try tmp.dir.openDir("src", .{ .iterate = true });
    defer s.close();
    var d = try tmp.dir.openDir("dst", .{});
    defer d.close();
    try T.copyTree(a, s, d);
    try t.expect((try d.statFile("bin/tool")).mode & 0o111 != 0);
    try t.expect((try d.statFile("data")).mode & 0o111 == 0);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("tool", try d.readLink("bin/alias", &buf));
    try t.expectEqualStrings("elf", try d.readFileAlloc(a, "bin/tool", 100));
}

const probes = @import("probes.zig");
const archives = @import("archives.zig");

test "osRelease and stripAddress: the lines the report keeps, the load address dropped" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("ID=debian\nVERSION_ID=\"12\"\n", try probes.osRelease(a, "PRETTY_NAME=x\nID=debian\nID_LIKE=y\nVERSION_ID=\"12\"\n"));
    try t.expectEqualStrings("\tlibc.so.6 => /lib/libc.so.6", try probes.stripAddress(a, "\tlibc.so.6 => /lib/libc.so.6 (0x00007f1234abcdef)"));
    try t.expectEqualStrings("a (0xZZ) b", try probes.stripAddress(a, "a (0xZZ) b"));
    try t.expectEqualStrings("x", try probes.stripAddress(a, "x"));
}

test "inits: the objects the loader initialized, per record file, sorted, the toolchain path abbreviated" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("compile");
    try tmp.dir.writeFile(.{ .sub_path = "compile/ld.100", .data = "  100:\tfile=libc.so.6 [0]; needed by x\n  100:\tcalling init: /lib/libc.so.6\n  100:\tcalling init: /w/tc/lib/libA.so\n" });
    try tmp.dir.writeFile(.{ .sub_path = "compile/ld.101", .data = "  101:\tcalling init: /lib/libc.so.6\n" });
    try tmp.dir.writeFile(.{ .sub_path = "compile/other", .data = "calling init: /ignored\n" });
    const got = try probes.inits(a, tmp.dir, "compile", "/w/tc/");
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("compile init /lib/libc.so.6", got[0]);
    try t.expectEqualStrings("compile init <toolchain>/lib/libA.so", got[1]);
    try t.expectEqual(@as(usize, 0), (try probes.inits(a, tmp.dir, "run", "/w/tc/")).len);
}

/// `gz` inflated, with no window buffer (the windowed decoder of this release
/// mishandles a fixed-Huffman match at the end of its window).
fn gunzip(a: std.mem.Allocator, gz: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var out = std.Io.Writer.Allocating.init(a);
    _ = try dec.reader.streamRemaining(&out.writer);
    return out.written();
}

test "stand-in tar.gz: the top directory, its files with their modes, the programs' bytes; gunzip and untar round-trip" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tar = try archives.standInTar(a, "pkg", &.{ "file:package.json", "program:bin/node" }, "BUSYBOX");
    const gz = try archives.gzipStored(a, tar);
    const back = try gunzip(a, gz);
    try t.expectEqualSlices(u8, tar, back);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var tin: std.Io.Reader = .fixed(back);
    var it = std.tar.Iterator.init(&tin, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var names = std.ArrayList([]const u8).empty;
    while (try it.next()) |f| {
        try names.append(a, try a.dupe(u8, f.name));
        if (std.mem.eql(u8, f.name, "pkg/bin/node")) {
            try t.expectEqual(@as(u32, 0o755), f.mode & 0o777);
            try t.expectEqual(@as(u64, 7), f.size);
        }
        if (std.mem.eql(u8, f.name, "pkg/package.json")) try t.expectEqual(@as(u32, 0o644), f.mode & 0o777);
    }
    try t.expectEqual(@as(usize, 4), names.items.len); // pkg/, pkg/package.json, pkg/bin/, pkg/bin/node
    try t.expectEqualStrings("pkg/", names.items[0]);
    try t.expectError(error.BadEntry, archives.standInTar(a, "pkg", &.{"other:x"}, ""));
}

test "gzipStored: more than one stored block" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const data = try a.alloc(u8, 70000);
    for (data, 0..) |*b, i| b.* = @intCast(i % 251);
    const gz = try archives.gzipStored(a, data);
    try t.expectEqualSlices(u8, data, try gunzip(a, gz));
    const empty = try archives.gzipStored(a, "");
    try t.expectEqual(@as(usize, 0), (try gunzip(a, empty)).len);
}

const proto_checks = @import("proto_checks.zig");

test "restBlock: the begin and end marker lines and everything between, nothing around" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const src = "head\n" ++ proto_checks.rest_begin ++ "\nfn url():\n    pass\n" ++ proto_checks.rest_end ++ "\ntail\n";
    try t.expectEqualStrings(proto_checks.rest_begin ++ "\nfn url():\n    pass\n" ++ proto_checks.rest_end ++ "\n", try proto_checks.restBlock(a, src));
    try t.expectEqualStrings("", try proto_checks.restBlock(a, "no markers\n"));
}

test "treeDiff: null when the trees are the same; names a changed, a missing and an extra file" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("g/sub");
    try tmp.dir.makePath("o/sub");
    try tmp.dir.writeFile(.{ .sub_path = "g/same.mojo", .data = "x\n" });
    try tmp.dir.writeFile(.{ .sub_path = "o/same.mojo", .data = "x\n" });
    var g = try tmp.dir.openDir("g", .{ .iterate = true });
    defer g.close();
    var o = try tmp.dir.openDir("o", .{ .iterate = true });
    defer o.close();
    try t.expect((try proto_checks.treeDiff(a, g, "g", o, "o")) == null);
    try tmp.dir.writeFile(.{ .sub_path = "g/changed.mojo", .data = "one\ntwo\n" });
    try tmp.dir.writeFile(.{ .sub_path = "o/changed.mojo", .data = "one\n2\n" });
    try tmp.dir.writeFile(.{ .sub_path = "g/sub/gone.mojo", .data = "g" });
    try tmp.dir.writeFile(.{ .sub_path = "o/extra.mojo", .data = "e" });
    const d = (try proto_checks.treeDiff(a, g, "g", o, "o")).?;
    try t.expect(std.mem.indexOf(u8, d, "diff -r -u g/changed.mojo o/changed.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "-two\n+2\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "Only in g: sub/gone.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "Only in o: extra.mojo\n") != null);
}

test "lineCount and tooLong: a last line without a newline counts; only .mojo files of 1000 lines or more are named" {
    try t.expectEqual(@as(usize, 0), proto_checks.lineCount(""));
    try t.expectEqual(@as(usize, 1), proto_checks.lineCount("a"));
    try t.expectEqual(@as(usize, 1), proto_checks.lineCount("a\n"));
    try t.expectEqual(@as(usize, 2), proto_checks.lineCount("a\nb"));
    try t.expectEqual(@as(usize, 3), proto_checks.lineCount("a\n\nb\n"));
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const line = "x\n";
    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{ .sub_path = "ok.mojo", .data = line ** 999 });
    try tmp.dir.writeFile(.{ .sub_path = "long.txt", .data = line ** 2000 });
    try t.expect((try proto_checks.tooLong(a, tmp.dir)) == null);
    try tmp.dir.writeFile(.{ .sub_path = "sub/big.mojo", .data = line ** 1000 });
    try t.expectEqualStrings("sub/big.mojo (1000 lines)", (try proto_checks.tooLong(a, tmp.dir)).?);
}

const aws_checks = @import("aws_checks.zig");
const parity = @import("parity.zig");

test "holds: whole lines with their leading spaces removed; a needle may span lines but not match a tail" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const module = "struct S:\n    var a: Int\n        var b: Int\n    def f(self):\n";
    try t.expect(try aws_checks.holds(a, module, "var a: Int"));
    try t.expect(try aws_checks.holds(a, module, "var a: Int\nvar b: Int"));
    try t.expect(try aws_checks.holds(a, module, "struct S:\n   var a: Int"));
    // The tail of a longer line is not a line.
    try t.expect(!try aws_checks.holds(a, module, "a: Int"));
    try t.expect(!try aws_checks.holds(a, module, "var a: Int\ndef f(self):"));
    // A needle that opens with spaces cannot match: the haystack's lines have none.
    try t.expect(!try aws_checks.holds(a, module, "  var a: Int"));
    try t.expect(try aws_checks.holds(a, module, "def f(self):"));
}

test "parity: the report words of a difference, signal cases compare only the first stderr line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const same = parity.Run{ .rc = 0, .out = "o", .err = "e" };
    try t.expectEqualStrings("", try parity.differences(a, same, same, .exact));
    try t.expectEqualStrings(" stdout stderr exit(0 vs 3)", try parity.differences(a, same, .{ .rc = 3, .out = "x", .err = "y" }, .exact));
    const e = parity.Run{ .rc = 134, .out = "", .err = "Stack dump\n0x1234 frame\n" };
    const b = parity.Run{ .rc = 134, .out = "", .err = "Stack dump\n0x9999 other\n" };
    try t.expectEqualStrings("", try parity.differences(a, e, b, .signal));
    try t.expectEqualStrings(" stderr", try parity.differences(a, e, b, .exact));
    try t.expectEqualStrings(" stderr-first-line", try parity.differences(a, e, .{ .rc = 134, .out = "", .err = "Other\n" }, .signal));
    // An empty stderr under a signal means no dump was printed: a difference.
    try t.expectEqualStrings(" stderr-first-line", try parity.differences(a, .{ .rc = 134, .out = "", .err = "" }, .{ .rc = 134, .out = "", .err = "" }, .signal));
    try t.expectEqualStrings("a b|c|d", try parity.flatten(a, "a b\nc\ndropped", 7));
}

const minised = @import("minised.zig");
const cov = @import("cov_checks.zig");

test "minised: the expressions cov_plant uses" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("x = 2 @FACTOR@\ny = 2\n", try minised.run(a, "s/@FACTOR@/2/", "x = @FACTOR@ @FACTOR@\ny = @FACTOR@\n"));
    // Two commands; only the first match of each line.
    try t.expectEqualStrings("a07b01 @N@\n", try minised.run(a, "s/@N@/07/; s/@V@/01/", "a@N@b@V@ @N@\n"));
    // Anchors, `.` any character, another delimiter, `\&` a literal ampersand and `&` the match.
    try t.expectEqualStrings("    copy(&.{ r0 });\n  copy(src);\n", try minised.run(a, "s|^    copy(src);$|    copy(\\&.{ r0 });|", "    copy(src);\n  copy(src);\n"));
    try t.expectEqualStrings("else x-import;\n", try minised.run(a, "s#else args.import;$#else x-import;#", "else args.import;\n"));
    try t.expectEqualStrings("else argsXimport; else args.import; \n", try minised.run(a, "s/else args.import;$/&/", "else argsXimport; else args.import; \n"));
    try t.expectEqualStrings("[ab]\n", try minised.run(a, "s/ab/[&]/", "ab\n"));
    // An empty replacement; a pattern with the delimiter escaped.
    try t.expectEqualStrings("a  b\n", try minised.run(a, "s|try v.appendSlice(x);||", "a try v.appendSlice(x); b\n"));
    try t.expectEqualStrings("a-b\n", try minised.run(a, "s/a\\/b/a-b/", "a/b\n"));
    // A line the pattern is not at the start of is untouched by ^.
    try t.expectEqualStrings("  x\n", try minised.run(a, "s/^x/y/", "  x\n"));
    // No trailing newline stays none.
    try t.expectEqualStrings("y", try minised.run(a, "s/x/y/", "x"));
}

test "minised: what it does not do is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "s/a*/b/", "s/[ab]/c/", "s/a/b/g", "y/a/b/", "s/a/b", "", "s/\\(a\\)/\\1/" }) |bad| {
        try t.expectError(error.UnsupportedSed, minised.run(a, bad, "a\n"));
    }
}

test "strings, hasPlaceholder, plain directories" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const ss = try cov.strings(a, "ab\x00tests\x01value.mojo\x00x\x7f/lib64/ld.so\x00", 4);
    try t.expectEqual(@as(usize, 3), ss.len);
    try t.expectEqualStrings("tests", ss[0]);
    try t.expect(cov.hasString(ss, "value.mojo"));
    try t.expect(!cov.hasString(ss, "value"));
    try t.expect(cov.hasPlaceholder("..\x00/________\x00..", false));
    try t.expect(!cov.hasPlaceholder("/_______\x00", false)); // seven
    try t.expect(cov.hasPlaceholder("/__________/src", true));
    try t.expect(!cov.hasPlaceholder("/__________\x00/src", true));
    try t.expect(!cov.hasPlaceholder("/__________", true));
}

test "blockCounts, normalize and withoutRuntime: the link lines of the two builds compare equal once normalized" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("2,3,", try cov.blockCounts(a, "  main:\n    Block counts: [3, 2]\n"));
    const mojo = "cc\n-target\nx86_64-linux-gnu.2.28\n/w/tc/lib/libstd.so\n/w/b/mojo_archive-7f.a\n-lm\n-o\n/w/out/exe\n----\n";
    const branch = "cc\n-target\nx86_64-linux-gnu.2.28\n/w/tc/lib/libstd.so\n/w/b/cov_branch_link/pg.o\n-Wl,--whole-archive\n/r/libclang_rt.profile-x86_64.a\n-Wl,--no-whole-archive\n-lm\n-o\n/w/other/exe\n----\n";
    const m = try cov.normalize(a, mojo, "/w/tc", "x86_64-linux-gnu.2.28", .mojo);
    const b = try cov.withoutRuntime(a, try cov.normalize(a, branch, "/w/tc", "x86_64-linux-gnu.2.28", .branch));
    try t.expectEqualStrings("cc\n-target\n<target>\n<TC>/lib/libstd.so\n<object>\n-lm\n-o\n<out>\n", m);
    try t.expectEqualStrings(m, b);
    // A runtime not in a whole-archive group, or something else in it, is reported.
    try t.expectEqualStrings("a\n<no profile runtime>\n", try cov.withoutRuntime(a, "a\n"));
    try t.expectEqualStrings("-Wl,x\n<unexpected in the whole archive> -lfoo\n<no profile runtime>\n", try cov.withoutRuntime(a, "-Wl,x\n-Wl,--whole-archive\n-lfoo\n-Wl,--no-whole-archive\n"));
}
