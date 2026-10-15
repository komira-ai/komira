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
    try tmp.dir.writeFile("b.mojo", "x");
    try tmp.dir.writeFile(".hidden", "x");
    try tmp.dir.makePath("a_dir/inner");
    try tmp.dir.writeFile("a_dir/inner/f", "x");
    try t.expectEqualStrings(".hidden a_dir b.mojo ", try T.listingWords(a, tmp.dir));
}

test "grepFiles: files under the directory, nested, that hold the string, sorted" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("d/e");
    try tmp.dir.writeFile("d/e/z.txt", "has needle here");
    try tmp.dir.writeFile("d/a.txt", "needle");
    try tmp.dir.writeFile("d/none.txt", "nothing");
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
    try tmp.dir.writeFile("src/data", "d");
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
    try tmp.dir.writeFile("compile/ld.100", "  100:\tfile=libc.so.6 [0]; needed by x\n  100:\tcalling init: /lib/libc.so.6\n  100:\tcalling init: /w/tc/lib/libA.so\n");
    try tmp.dir.writeFile("compile/ld.101", "  101:\tcalling init: /lib/libc.so.6\n");
    try tmp.dir.writeFile("compile/other", "calling init: /ignored\n");
    const got = try probes.inits(a, tmp.dir, "compile", "/w/tc/");
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("compile init /lib/libc.so.6", got[0]);
    try t.expectEqualStrings("compile init <toolchain>/lib/libA.so", got[1]);
    try t.expectEqual(@as(usize, 0), (try probes.inits(a, tmp.dir, "run", "/w/tc/")).len);
}

test "stand-in tar.gz: the top directory, its files with their modes, the programs' bytes; gunzip and untar round-trip" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const tar = try archives.standInTar(a, "pkg", &.{ "file:package.json", "program:bin/node" }, "BUSYBOX");
    const gz = try archives.gzipStored(a, tar);
    var fbs = std.io.fixedBufferStream(gz);
    var dec = std.compress.gzip.decompressor(fbs.reader());
    const back = try dec.reader().readAllAlloc(a, 1 << 20);
    try t.expectEqualSlices(u8, tar, back);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var tfbs = std.io.fixedBufferStream(back);
    var it = std.tar.iterator(tfbs.reader(), .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var names = std.ArrayList([]const u8).init(a);
    while (try it.next()) |f| {
        try names.append(try a.dupe(u8, f.name));
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
    var fbs = std.io.fixedBufferStream(gz);
    var dec = std.compress.gzip.decompressor(fbs.reader());
    try t.expectEqualSlices(u8, data, try dec.reader().readAllAlloc(a, 1 << 20));
    const empty = try archives.gzipStored(a, "");
    var efbs = std.io.fixedBufferStream(empty);
    var edec = std.compress.gzip.decompressor(efbs.reader());
    try t.expectEqual(@as(usize, 0), (try edec.reader().readAllAlloc(a, 100)).len);
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
    try tmp.dir.writeFile("g/same.mojo", "x\n");
    try tmp.dir.writeFile("o/same.mojo", "x\n");
    var g = try tmp.dir.openDir("g", .{ .iterate = true });
    defer g.close();
    var o = try tmp.dir.openDir("o", .{ .iterate = true });
    defer o.close();
    try t.expect((try proto_checks.treeDiff(a, g, "g", o, "o")) == null);
    try tmp.dir.writeFile("g/changed.mojo", "one\ntwo\n");
    try tmp.dir.writeFile("o/changed.mojo", "one\n2\n");
    try tmp.dir.writeFile("g/sub/gone.mojo", "g");
    try tmp.dir.writeFile("o/extra.mojo", "e");
    const d = (try proto_checks.treeDiff(a, g, "g", o, "o")).?;
    try t.expect(std.mem.indexOf(u8, d, "diff -r -u g/changed.mojo o/changed.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "-two\n+2\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "Only in g: sub/gone.mojo\n") != null);
    try t.expect(std.mem.indexOf(u8, d, "Only in o: extra.mojo\n") != null);
}
