//! Unit tests of the readers kcov_check.zig decides by: the report normalizer and
//! the Cobertura line checks, the loader-record readers, `strings`, the ELF
//! dynamic-tag finder and the zip writer the `cases` mode builds its inputs with.
//! The checks themselves run on the built kcov (:kcov_check, :kcov_check_cases,
//! :kcov_reproducible, :kcov_identity).
const std = @import("std");
const K = @import("kcov_check_scan.zig");
const C = @import("kcov_check.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

test "normalize: every directory is renamed (literally), the first timestamp of a line is zeroed" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const xml = "<coverage timestamp=\"1760000000\" timestamp=\"5\"><source>/a.b/c</source>\n<class filename=\"/a.b/c/x.c\"/> /axb/c\n";
    const out = try K.normalize(a, xml, "/a.b/c", "@SRC@");
    try t.expectEqualStrings("<coverage timestamp=\"0\" timestamp=\"5\"><source>@SRC@</source>\n<class filename=\"@SRC@/x.c\"/> /axb/c\n", out);
    // A timestamp attribute that is not digits is left alone.
    try t.expectEqualStrings("timestamp=\"x\" timestamp=\"0\"\n", try K.normalize(a, "timestamp=\"x\" timestamp=\"12\"\n", "/nope", "n"));
    // No trailing newline stays none.
    try t.expectEqualStrings("a", try K.normalize(a, "a", "/z", "z"));
}

const report =
    "<package>\n" ++
    "<class name=\"cov_part_c\" filename=\"/r/cov_part.c\">\n<lines>\n<line number=\"3\" hits=\"7\"/>\n<line number=\"4\" hits=\"0\"/>\n</lines>\n</class>\n" ++
    "<class name=\"cov_fixture_c\" filename=\"/r/cov_fixture.c\"><lines>\n<line number=\"10\" hits=\"1\"/>\n<line number=\"11\" hits=\"0\"/>\n</lines>\n</class>\n" ++
    "<class name=\"x\" filename=\"/r/other_cov_fixture.c\">\n<line number=\"12\" hits=\"1\"/>\n</class>\n" ++
    "</package>\n";

test "classLines: the class of the file by its full path, not of a file ending in the same letters" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const c = try K.classLines(a, report, "cov_fixture.c");
    try t.expect(std.mem.indexOf(u8, c, "number=\"10\"") != null);
    try t.expect(std.mem.indexOf(u8, c, "number=\"12\"") == null);
    try t.expect(std.mem.indexOf(u8, c, "number=\"3\"") == null);
    try t.expectEqual(@as(usize, 0), (try K.classLines(a, report, "missing.c")).len);
}

test "lineHits: a hit needs a positive count, a miss exactly 0, and the line number matches whole" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const c = "<line number=\"10\" hits=\"1\"/>\n<line number=\"11\" hits=\"0\"/>\n<line number=\"2\" hits=\"05\"/>\n";
    try t.expect(try K.lineHits(a, c, 10, false));
    try t.expect(!try K.lineHits(a, c, 10, true));
    try t.expect(try K.lineHits(a, c, 11, true));
    try t.expect(!try K.lineHits(a, c, 11, false));
    try t.expect(!try K.lineHits(a, c, 1, false));
    try t.expect(!try K.lineHits(a, c, 2, true));
    try t.expect(!try K.lineHits(a, c, 99, false));
}

test "markerLines: 1-based numbers of the lines holding the exact marker" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src = "int a; /* COV:hit */\nint b;\nint c; /* COV:miss */\nint d; /* COV:hit */\n/* COV:hitx */\n";
    const hits = try K.markerLines(a, src, "hit");
    try t.expectEqual(@as(usize, 2), hits.len);
    try t.expectEqual(@as(usize, 1), hits[0]);
    try t.expectEqual(@as(usize, 4), hits[1]);
    try t.expectEqual(@as(usize, 3), (try K.markerLines(a, src, "miss"))[0]);
}

test "inits and initsStray: the objects a record initialised; glibc outside the program is fine, nothing else is" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const rec =
        "  100:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n" ++
        "  100:\tcalling init: /d/bin/../lib/libgcc_s.so.1\n" ++
        "  100:\tcalling init: /lib/x86_64-linux-gnu/libc.so.6\n" ++
        "  100:\tfile=libm.so.6 [0]; needed by x\n";
    const il = try K.inits(a, rec);
    try t.expectEqual(@as(usize, 2), il.len);
    try t.expect((try K.initsStray(a, il, "/d", "/decoy", &.{"libgcc_s.so.1"})) == null);
    // A glibc-named library of the program's own directory, or of the decoys, is stray.
    const own_libm = [_][]const u8{"/d/bin/../lib/libm.so.6"};
    try t.expectEqualStrings("/d/bin/../lib/libm.so.6", (try K.initsStray(a, &own_libm, "/d", "/decoy", &.{"libgcc_s.so.1"})).?);
    const decoy_libm = [_][]const u8{"/decoy/libm.so.6"};
    try t.expect((try K.initsStray(a, &decoy_libm, "/d", "/decoy", &.{})) != null);
    // A library that is not glibc's, outside everything, is stray.
    const other = [_][]const u8{"/usr/lib/libz.so.1"};
    try t.expect((try K.initsStray(a, &other, "/d", "/decoy", &.{})) != null);
    // A relative glibc path is not "outside".
    const rel = [_][]const u8{"libc.so.6"};
    try t.expect((try K.initsStray(a, &rel, "/d", "/decoy", &.{})) != null);
}

test "hasString: a whole printable run of at least the minimum length" {
    try t.expect(K.hasString("\x00\x01GCC_3.0\x00", 7, "GCC_3.0"));
    try t.expect(!K.hasString("\x00xGCC_3.0\x00", 7, "GCC_3.0"));
    try t.expect(!K.hasString("\x00GCC_3.0x\x00", 7, "GCC_3.0"));
    try t.expect(K.hasString("GCC_3.0", 7, "GCC_3.0"));
    try t.expect(!K.hasString("GCC_3.", 7, "GCC_3.0"));
    try t.expect(K.hasString("ab\x00GCC_3.0\n", 7, "GCC_3.0")); // a newline ends a run
}

fn elf(buf: *[512]u8, tags: []const [2]u32) void {
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[32..36], 64, .little); // e_phoff
    std.mem.writeInt(u16, buf[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, buf[56..58], 2, .little); // e_phnum
    // ph 0: PT_LOAD; ph 1: PT_DYNAMIC at 256, 16 bytes per tag.
    std.mem.writeInt(u32, buf[64..68], 1, .little);
    std.mem.writeInt(u32, buf[120..124], 2, .little);
    std.mem.writeInt(u32, buf[128..132], 256, .little);
    std.mem.writeInt(u32, buf[152..156], @intCast(tags.len * 16), .little);
    for (tags, 0..) |tg, i| {
        std.mem.writeInt(u32, buf[256 + i * 16 ..][0..4], tg[0], .little);
        std.mem.writeInt(u32, buf[260 + i * 16 ..][0..4], tg[1], .little);
    }
}

test "dynTagOff: the offset of a tag in PT_DYNAMIC; the null entry ends the search" {
    var buf: [512]u8 = undefined;
    elf(&buf, &.{ .{ 1, 0 }, .{ 21, 0 }, .{ 29, 0 }, .{ 0, 0 }, .{ 15, 0 } });
    try t.expectEqual(@as(?usize, 256 + 16), K.dynTagOff(&buf, 21));
    try t.expectEqual(@as(?usize, 256 + 32), K.dynTagOff(&buf, 29));
    try t.expectEqual(@as(?usize, null), K.dynTagOff(&buf, 15)); // after DT_NULL
    // A tag whose high half is not 0 is not that tag.
    elf(&buf, &.{ .{ 21, 1 }, .{ 0, 0 } });
    try t.expectEqual(@as(?usize, null), K.dynTagOff(&buf, 21));
    try t.expectEqual(@as(?usize, null), K.dynTagOff("short", 21));
}

test "zipMember: a stored member with 32-bit sizes, or zip64 sizes in an extra field" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const plain = try K.zipMember(a, "pkg-x.tar.zst", 0, false, "abcd");
    try t.expectEqualSlices(u8, &.{ 0x50, 0x4b, 0x03, 0x04, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x00 }, plain[0..10]);
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, plain[18..22], .little));
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, plain[22..26], .little));
    try t.expectEqual(@as(u16, 13), std.mem.readInt(u16, plain[26..28], .little));
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, plain[28..30], .little));
    try t.expectEqualStrings("pkg-x.tar.zstabcd", plain[30..]);
    const z = try K.zipMember(a, "p", 8, true, "xy");
    try t.expectEqual(@as(u16, 8), std.mem.readInt(u16, z[8..10], .little));
    try t.expectEqual(@as(u32, 0xffffffff), std.mem.readInt(u32, z[18..22], .little));
    try t.expectEqual(@as(u16, 20), std.mem.readInt(u16, z[28..30], .little));
    try t.expectEqualSlices(u8, &.{ 0x01, 0x00, 0x10, 0x00, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0 }, z[31..51]);
    try t.expectEqualStrings("xy", z[51..]);
}

test "modeString and listing: type, permissions, sha256 of files, sorted by path" {
    try t.expectEqualStrings("-rwxr-xr-x", &K.modeString(.file, 0o755));
    try t.expectEqualStrings("drwxr-xr-x", &K.modeString(.directory, 0o755));
    try t.expectEqualStrings("-rw-r--r--", &K.modeString(.file, 0o644));
    try t.expectEqualStrings("-rwsr-xr-t", &K.modeString(.file, 0o5755));
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("lib");
    try tmp.dir.writeFile(.{ .sub_path = "lib/b", .data = "hello" });
    try tmp.dir.writeFile(.{ .sub_path = "a", .data = "" });
    const path = try tmp.dir.realpathAlloc(a, ".");
    const l = try C.listing(a, path);
    var lines = std.mem.splitScalar(u8, std.mem.trimRight(u8, l, "\n"), '\n');
    var paths = std.ArrayList([]const u8).empty;
    while (lines.next()) |x| try paths.append(a, x[std.mem.lastIndexOfScalar(u8, x, ' ').? + 1 ..]);
    try t.expectEqual(@as(usize, 4), paths.items.len);
    try t.expectEqualStrings(".", paths.items[0]);
    try t.expectEqualStrings("./a", paths.items[1]);
    try t.expectEqualStrings("./lib", paths.items[2]);
    try t.expectEqualStrings("./lib/b", paths.items[3]);
    try t.expect(std.mem.indexOf(u8, l, "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824 ./lib/b") != null);
}
