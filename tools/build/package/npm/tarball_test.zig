//! The tarball: members written and read back with their names, bytes and
//! modes, in order, the same bytes twice; each header a ustar regular file
//! of npm pack's date with owner 0, which std.tar reads; and a gzip stream or
//! tar archive this writer would not write refused by its exact message: a
//! foreign gzip header, a bad CRC or length, a link, a directory, another
//! date, a member outside package/, another owner, padding that is not zero,
//! an archive cut short and one without its end. Writing a name over 100
//! bytes, a mode other than 0644 and 0755, or a member outside package/ is
//! refused too.

const std = @import("std");
const diag = @import("native_policy").diag;
const tarball = @import("tarball.zig");
const t = std.testing;
const Alloc = std.mem.Allocator;

fn members() []const tarball.Member {
    return &.{
        .{ .name = "package/package.json", .data = "{}\n" },
        .{ .name = "package/native/libkomira.so", .data = "\x7fELF" ++ "x" ** 700, .mode = 0o755 },
        .{ .name = "package/empty", .data = "" },
    };
}

fn tarOf(a: Alloc) ![]u8 {
    var d = diag.Diag{};
    return tarball.writeTar(a, &d, members());
}

fn refusal(a: Alloc, z: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, tarball.read(a, &d, z));
    return d.msg;
}

fn tarRefusal(a: Alloc, tar: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, tarball.readTar(a, &d, tar));
    return d.msg;
}

/// The header `h` with its checksum computed again, as a writer that set
/// its fields would.
fn rechecksum(h: []u8) void {
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h[0..512]) |b| sum += b;
    var v = sum;
    var i: usize = 6;
    while (i > 0) {
        i -= 1;
        h[148 + i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    h[154] = 0;
    h[155] = ' ';
}

test "written and read back: names, bytes and modes in order, and the same bytes twice" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const z = try tarball.write(a, &d, members());
    try t.expectEqualSlices(u8, z, try tarball.write(a, &d, members()));
    const got = try tarball.read(a, &d, z);
    try t.expectEqual(members().len, got.len);
    for (members(), got) |w, g| {
        try t.expectEqualStrings(w.name, g.name);
        try t.expectEqualSlices(u8, w.data, g.data);
        try t.expectEqual(w.mode, g.mode);
    }
}

test "every header is a ustar regular file of npm pack's date, owner and group 0, and std.tar reads the members" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarOf(a);
    const h = tar[0..512];
    try t.expectEqualStrings("package/package.json", h[0..20]);
    try t.expectEqualStrings("0000644\x00", h[100..108]);
    try t.expectEqualStrings("0000000\x00", h[108..116]);
    try t.expectEqualStrings("0000000\x00", h[116..124]);
    try t.expectEqualStrings("00000000003\x00", h[124..136]);
    try t.expectEqualStrings("03560116604\x00", h[136..148]);
    try t.expectEqual(@as(u8, '0'), h[156]);
    try t.expectEqualStrings("ustar\x0000", h[257..265]);
    // Two zero blocks end it.
    try t.expect(std.mem.allEqual(u8, tar[tar.len - 1024 ..], 0));

    var r: std.Io.Reader = .fixed(tar);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&r, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var n: usize = 0;
    while (try it.next()) |f| : (n += 1) {
        const w = members()[n];
        try t.expectEqualStrings(w.name, f.name);
        try t.expectEqual(@as(u64, w.data.len), f.size);
        try t.expectEqual(w.mode, f.mode);
        try t.expect(f.kind == .file);
    }
    try t.expectEqual(members().len, n);
}

test "gzip: a foreign header, a CRC or a length that disagrees, and a stream that is not deflate are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const z = try tarball.write(a, &d, members());

    const named = try a.dupe(u8, z);
    named[3] = 0x08; // FNAME: a file name follows the header.
    try t.expectEqualStrings("gzip: the tarball does not start with the gzip header this tool writes (deflate, no flags, no time, OS 255)", try refusal(a, named));
    try t.expectEqualStrings("gzip: the tarball does not start with the gzip header this tool writes (deflate, no flags, no time, OS 255)", try refusal(a, "PK\x03\x04"));

    const crc = try a.dupe(u8, z);
    crc[crc.len - 8] ^= 1;
    try t.expectEqualStrings("gzip: the inflated bytes do not have the trailer's CRC-32", try refusal(a, crc));

    const len = try a.dupe(u8, z);
    len[len.len - 4] ^= 1;
    const tar = try tarOf(a);
    try t.expectEqualStrings(try std.fmt.allocPrint(a, "gzip: the inflated bytes are {d} long, not the trailer's {d}", .{ tar.len, tar.len ^ 1 }), try refusal(a, len));

    // A stored block header (BTYPE 11) is no valid deflate stream.
    const bad = try std.mem.concat(a, u8, &.{ &tarball.gzip_header, "\x07\x00\x00\x00", "\x00" ** 8 });
    try t.expectEqualStrings("gzip: the tarball is not a valid deflate stream", try refusal(a, bad));
}

test "tar: a link, a directory, another date, a member outside package/, another owner, nonzero padding, a short archive and a missing end are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try tarOf(a);
    var d = diag.Diag{};
    try t.expectEqual(@as(usize, 3), (try tarball.readTar(a, &d, good)).len);

    const link = try a.dupe(u8, good);
    link[156] = '2';
    rechecksum(link[0..512]);
    try t.expectEqualStrings("tar: package/package.json has type `2`, not a regular file (0)", try tarRefusal(a, link));

    const dir = try a.dupe(u8, good);
    dir[156] = '5';
    rechecksum(dir[0..512]);
    try t.expectEqualStrings("tar: package/package.json has type `5`, not a regular file (0)", try tarRefusal(a, dir));

    const dated = try a.dupe(u8, good);
    @memcpy(dated[136..148], "00000000000\x00");
    rechecksum(dated[0..512]);
    try t.expectEqualStrings("tar: package/package.json is dated 0, not 499162500 (1985-10-26 08:15:00 UTC, npm pack's date)", try tarRefusal(a, dated));

    const outside = try a.dupe(u8, good);
    @memcpy(outside[0..8], "elsewhr/");
    rechecksum(outside[0..512]);
    try t.expectEqualStrings("tar: elsewhr/package.json is not under package/", try tarRefusal(a, outside));

    const owned = try a.dupe(u8, good);
    @memcpy(owned[108..116], "0001750\x00");
    rechecksum(owned[0..512]);
    try t.expectEqualStrings("tar: the header of package/package.json is not the one this tool writes for its name, mode and size (another owner, checksum, format or field)", try tarRefusal(a, owned));

    const sum = try a.dupe(u8, good);
    sum[150] ^= 1;
    try t.expectEqualStrings("tar: the header of package/package.json is not the one this tool writes for its name, mode and size (another owner, checksum, format or field)", try tarRefusal(a, sum));

    const odd = try a.dupe(u8, good);
    @memcpy(odd[100..108], "0000600\x00");
    rechecksum(odd[0..512]);
    try t.expectEqualStrings("tar: package/package.json has mode 600, neither 0644 nor 0755", try tarRefusal(a, odd));

    const padded = try a.dupe(u8, good);
    padded[512 + 3] = 'x'; // after the 3 bytes of package.json
    try t.expectEqualStrings("tar: the padding after package/package.json is not zero", try tarRefusal(a, padded));

    try t.expectEqualStrings("tar: the archive ends inside a header, before its two zero blocks", try tarRefusal(a, good[0..100]));
    try t.expectEqualStrings("tar: package/package.json is 3 bytes, past the end of the archive", try tarRefusal(a, good[0..512]));
    try t.expectEqualStrings("tar: package/package.json is not padded to a whole block before the archive ends", try tarRefusal(a, good[0..520]));
    try t.expectEqualStrings("tar: the archive does not end with exactly two zero blocks", try tarRefusal(a, good[0 .. good.len - 512]));
    const extra = try std.mem.concat(a, u8, &.{ good, "\x00" ** 512 });
    try t.expectEqualStrings("tar: the archive does not end with exactly two zero blocks", try tarRefusal(a, extra));
}

test "write: a name over 100 bytes, a mode other than 0644 and 0755, and a member outside package/ are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    const long = "package/" ++ "n" ** 93;
    try t.expectError(error.Refused, tarball.writeTar(a, &d, &.{.{ .name = long, .data = "" }}));
    try t.expectEqualStrings("tar: the member name `" ++ long ++ "` is 101 bytes; a ustar name holds 1 to 100", d.msg);
    _ = try tarball.writeTar(a, &d, &.{.{ .name = long[0..100], .data = "" }});
    try t.expectError(error.Refused, tarball.writeTar(a, &d, &.{.{ .name = "package/x", .data = "", .mode = 0o600 }}));
    try t.expectEqualStrings("tar: package/x has mode 600, neither 0644 nor 0755", d.msg);
    try t.expectError(error.Refused, tarball.writeTar(a, &d, &.{.{ .name = "other/x", .data = "" }}));
    try t.expectEqualStrings("tar: other/x is not under package/", d.msg);
}
