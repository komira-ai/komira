//! Unit tests of archive_files.zig: the substitutions (literal, in order, per
//! line, sed's treatment of the last newline), the archive kinds, extraction of
//! tar, tar.gz and zip (executable bits, links, an escaping member), over
//! archives built in memory. The whole tool is run by every third_party
//! `archive_files` target.
const std = @import("std");
const A = @import("archive_files.zig");
const t = std.testing;

// ---- archives built in memory ---------------------------------------------------

pub const Entry = struct {
    name: []const u8,
    /// '0' file, '5' directory, '2' symlink.
    kind: u8 = '0',
    mode: u32 = 0o644,
    data: []const u8 = "",
    link: []const u8 = "",
};

fn octal(buf: []u8, v: u64) void {
    @memset(buf, '0');
    var i: usize = buf.len - 1; // the last byte is the terminator
    buf[i] = 0;
    var x = v;
    while (i > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
        if (x == 0) break;
    }
}

pub fn tar(a: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    for (entries) |e| {
        var h = [_]u8{0} ** 512;
        // A name over 100 bytes is split at a `/` into the ustar prefix field and the name.
        var name_part = e.name;
        if (e.name.len > 100) {
            var i = e.name.len - 1;
            if (e.name[i] == '/') i -= 1;
            while (i > 0) : (i -= 1) {
                if (e.name[i] == '/' and e.name.len - i - 1 <= 100 and i <= 155) break;
            }
            @memcpy(h[345 .. 345 + i], e.name[0..i]);
            name_part = e.name[i + 1 ..];
        }
        @memcpy(h[0..name_part.len], name_part);
        octal(h[100..108], e.mode);
        octal(h[108..116], 0);
        octal(h[116..124], 0);
        octal(h[124..136], e.data.len);
        octal(h[136..148], 0);
        @memset(h[148..156], ' ');
        h[156] = e.kind;
        @memcpy(h[157 .. 157 + e.link.len], e.link);
        @memcpy(h[257..262], "ustar");
        h[262] = 0;
        @memcpy(h[263..265], "00");
        var sum: u64 = 0;
        for (h) |b| sum += b;
        octal(h[148..155], sum);
        h[154] = 0;
        h[155] = ' ';
        try out.appendSlice(a, &h);
        try out.appendSlice(a, e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(a, 0, pad);
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

/// A gzip stream of `bytes` in stored (uncompressed) deflate blocks.
pub fn gzip(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    var off: usize = 0;
    while (true) {
        const n = @min(bytes.len - off, 65535);
        const last = off + n == bytes.len;
        try out.append(a, if (last) 1 else 0);
        try out.writer(a).writeInt(u16, @intCast(n), .little);
        try out.writer(a).writeInt(u16, @intCast(~@as(u16, @intCast(n))), .little);
        try out.appendSlice(a, bytes[off .. off + n]);
        off += n;
        if (last) break;
    }
    try out.writer(a).writeInt(u32, std.hash.Crc32.hash(bytes), .little);
    try out.writer(a).writeInt(u32, @intCast(bytes.len), .little);
    return out.toOwnedSlice(a);
}

/// `data` as a raw deflate stream of one fixed-Huffman block holding only literals:
/// a real Huffman-coded body for the zip reader's inflate path (the standard
/// library of this release has no compressor to make one).
fn fixedLiterals(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var acc: u32 = 0;
    var n: u5 = 0;
    const Put = struct {
        fn bits(o: *std.ArrayList(u8), al: std.mem.Allocator, ac: *u32, nn: *u5, v: u32, count: u5) !void {
            ac.* |= v << nn.*;
            nn.* += count;
            while (nn.* >= 8) {
                try o.append(al, @truncate(ac.*));
                ac.* >>= 8;
                nn.* -= 8;
            }
        }
        // A Huffman code is packed most significant bit first.
        fn code(o: *std.ArrayList(u8), al: std.mem.Allocator, ac: *u32, nn: *u5, v: u32, count: u5) !void {
            var rev: u32 = 0;
            var i: u5 = 0;
            while (i < count) : (i += 1) rev |= ((v >> i) & 1) << (count - 1 - i);
            try bits(o, al, ac, nn, rev, count);
        }
    };
    try Put.bits(&out, a, &acc, &n, 0b011, 3); // final block, fixed Huffman
    for (data) |b| {
        if (b < 144) try Put.code(&out, a, &acc, &n, 0x30 + @as(u32, b), 8) else try Put.code(&out, a, &acc, &n, 0x190 + @as(u32, b) - 144, 9);
    }
    try Put.code(&out, a, &acc, &n, 0, 7); // end of block
    if (n > 0) try out.append(a, @truncate(acc));
    return out.toOwnedSlice(a);
}

// A zip of stored entries: (name, data, unix mode).
const ZipEntry = struct { name: []const u8, data: []const u8 = "", mode: u32 = 0o644, deflate: bool = false };

fn zip(a: std.mem.Allocator, entries: []const ZipEntry) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var offsets = std.ArrayList(u32).empty;
    const w = out.writer(a);
    var bodies = std.ArrayList([]const u8).empty;
    for (entries) |e| {
        if (e.deflate) {
            try bodies.append(a, try fixedLiterals(a, e.data));
        } else try bodies.append(a, e.data);
    }
    for (entries, 0..) |e, i| {
        try offsets.append(a, @intCast(out.items.len));
        const crc = std.hash.Crc32.hash(e.data);
        const body = bodies.items[i];
        const method: u16 = if (e.deflate) 8 else 0;
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, method, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(body.len), .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try out.appendSlice(a, e.name);
        try out.appendSlice(a, body);
    }
    const cd_start: u32 = @intCast(out.items.len);
    for (entries, 0..) |e, i| {
        const crc = std.hash.Crc32.hash(e.data);
        const dir = e.name[e.name.len - 1] == '/';
        try w.writeInt(u32, 0x02014b50, .little);
        try w.writeInt(u16, (3 << 8) | 20, .little);
        try w.writeInt(u16, 20, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, if (e.deflate) 8 else 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0x21, .little);
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, @intCast(bodies.items[i].len), .little);
        try w.writeInt(u32, @intCast(e.data.len), .little);
        try w.writeInt(u16, @intCast(e.name.len), .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeInt(u32, (e.mode << 16) | (if (dir) @as(u32, 0x10) else 0), .little);
        try w.writeInt(u32, offsets.items[i], .little);
        try out.appendSlice(a, e.name);
    }
    const cd_size: u32 = @intCast(out.items.len - cd_start);
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u16, @intCast(entries.len), .little);
    try w.writeInt(u32, cd_size, .little);
    try w.writeInt(u32, cd_start, .little);
    try w.writeInt(u16, 0, .little);
    return out.toOwnedSlice(a);
}

// ---- the tests ---------------------------------------------------------------------

test "parsePairs: key<TAB>value lines in order; no tab or an empty key is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ps = try A.parsePairs(a, "@A@\tone\n\n.\t[x]\n$v\t\n");
    try t.expectEqual(@as(usize, 3), ps.len);
    try t.expectEqualStrings("@A@", ps[0].key);
    try t.expectEqualStrings("one", ps[0].value);
    try t.expectEqualStrings(".", ps[1].key);
    try t.expectEqualStrings("[x]", ps[1].value);
    try t.expectEqualStrings("", ps[2].value);
    try t.expectError(error.BadLine, A.parsePairs(a, "novalue\n"));
    try t.expectError(error.BadLine, A.parsePairs(a, "\tvalue\n"));
    try t.expectEqual(@as(usize, 0), (try A.parsePairs(a, "")).len);
}

test "substitute: literal keys (regex characters and & and \\ mean themselves), every occurrence, in pair order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ps = [_]A.Pair{ .{ .key = "a.b", .value = "X&Y" }, .{ .key = "[v]", .value = "\\n/" }, .{ .key = "$(N)", .value = "7" } };
    try t.expectEqualStrings("X&Y aXb X&Y \\n/ 7 7\nline2\n", try A.substitute(a, "a.b aXb a.b [v] $(N) $(N)\nline2\n", &ps));
}

test "substitute: later pairs see earlier output; no final newline is not added" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ps = [_]A.Pair{ .{ .key = "A", .value = "B" }, .{ .key = "B", .value = "C" } };
    try t.expectEqualStrings("C C", try A.substitute(a, "A B", &ps));
    try t.expectEqualStrings("", try A.substitute(a, "", &ps));
    try t.expectEqualStrings("C\n\nC\n", try A.substitute(a, "A\n\nB\n", &ps));
    try t.expectEqualStrings("unchanged\n", try A.substitute(a, "unchanged\n", &.{}));
}

test "kindOf: by the name's ending" {
    try t.expect(A.kindOf("x/a-1.0.tar.gz").? == .tar_gz);
    try t.expect(A.kindOf("a.tgz").? == .tar_gz);
    try t.expect(A.kindOf("a.tar").? == .tar);
    try t.expect(A.kindOf("a.zip").? == .zip);
    try t.expect(A.kindOf("a.tar.xz") == null);
    try t.expect(A.kindOf("a.gz") == null);
    try t.expect(A.kindOf("a") == null);
}

test "contained: not absolute, no .. component" {
    try t.expect(A.contained("a/b/c"));
    try t.expect(A.contained("a..b/c"));
    try t.expect(!A.contained("../a"));
    try t.expect(!A.contained("a/../b"));
    try t.expect(!A.contained("/etc/passwd"));
}

fn extractFrom(dir: std.fs.Dir, bytes: []const u8) !void {
    var rd: std.Io.Reader = .fixed(bytes);
    try A.extractTar(dir, &rd);
}

test "extractTar: directories, files with the executable bit, links; a prefix directory entry is fine" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const bytes = try tar(a, &.{
        .{ .name = "pkg-1.0/", .kind = '5', .mode = 0o755 },
        .{ .name = "pkg-1.0/src/", .kind = '5', .mode = 0o755 },
        .{ .name = "pkg-1.0/src/a.c", .mode = 0o664, .data = "int a;\n" },
        .{ .name = "pkg-1.0/run.sh", .mode = 0o755, .data = "echo" },
        .{ .name = "pkg-1.0/link", .kind = '2', .link = "src/a.c" },
    });
    try extractFrom(tmp.dir, bytes);
    var buf: [64]u8 = undefined;
    try t.expectEqualStrings("int a;\n", try tmp.dir.readFile("pkg-1.0/src/a.c", &buf));
    const st = try tmp.dir.statFile("pkg-1.0/src/a.c");
    try t.expect(st.mode & 0o100 == 0);
    const x = try tmp.dir.statFile("pkg-1.0/run.sh");
    try t.expect(x.mode & 0o100 != 0);
    try t.expectEqualStrings("src/a.c", try tmp.dir.readLink("pkg-1.0/link", &buf));
    try t.expectEqualStrings("int a;\n", try tmp.dir.readFile("pkg-1.0/link", &buf));
}

test "extractTar: a member that escapes is refused, and a gzip stream reads as the tar" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try t.expectError(error.PathEscapes, extractFrom(tmp.dir, try tar(a, &.{.{ .name = "p/../../evil", .data = "x" }})));
    const z = try gzip(a, try tar(a, &.{.{ .name = "p/f", .data = "gz" }}));
    var zin: std.Io.Reader = .fixed(z);
    var dec = std.compress.flate.Decompress.init(&zin, .gzip, &.{});
    var plain = std.Io.Writer.Allocating.init(a);
    _ = try dec.reader.streamRemaining(&plain.writer);
    try extractFrom(tmp.dir, plain.written());
    var buf: [8]u8 = undefined;
    try t.expectEqualStrings("gz", try tmp.dir.readFile("p/f", &buf));
}

test "extractZip: stored and deflated entries, directories, and the executable bit from the unix mode" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const big = "deflate me, deflate me, deflate me, deflate me, deflate me\n" ** 20;
    const bytes = try zip(a, &.{
        .{ .name = "bin/", .mode = 0o755 },
        .{ .name = "bin/tool", .data = "ELF", .mode = 0o755 },
        .{ .name = "bin/notes.txt", .data = "notes", .mode = 0o644 },
        .{ .name = "bin/packed", .data = big, .mode = 0o755, .deflate = true },
    });
    try A.extractZip(a, tmp.dir, bytes);
    var buf: [2048]u8 = undefined;
    try t.expectEqualStrings("ELF", try tmp.dir.readFile("bin/tool", &buf));
    try t.expectEqualStrings("notes", try tmp.dir.readFile("bin/notes.txt", &buf));
    try t.expectEqualStrings(big, try tmp.dir.readFile("bin/packed", &buf));
    try t.expect((try tmp.dir.statFile("bin/tool")).mode & 0o100 != 0);
    try t.expect((try tmp.dir.statFile("bin/packed")).mode & 0o100 != 0);
    try t.expect((try tmp.dir.statFile("bin/notes.txt")).mode & 0o100 == 0);
}

test "extractZip: a bad archive, a wrong checksum and an escaping name are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try t.expectError(error.BadZip, A.extractZip(a, tmp.dir, "not a zip file at all, not a zip"));
    try t.expectError(error.BadZip, A.extractZip(a, tmp.dir, ""));
    const good = try zip(a, &.{.{ .name = "f", .data = "abcdef" }});
    const bad = try a.dupe(u8, good);
    bad[30 + 1] = 'X'; // a byte of the stored data: the checksum no longer matches
    try t.expectError(error.BadZip, A.extractZip(a, tmp.dir, bad));
    try t.expectError(error.PathEscapes, A.extractZip(a, tmp.dir, try zip(a, &.{.{ .name = "../evil", .data = "x" }})));
}
