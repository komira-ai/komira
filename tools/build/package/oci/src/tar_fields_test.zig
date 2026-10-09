//! Cases for every header field's width and offset, every type flag the
//! reader accepts, and the bytes the writer emits, checked against headers
//! laid out here from the ustar field table, not from the writer.

const std = @import("std");
const C = @import("common.zig");
const T = @import("tar.zig");
const F = @import("tar_fixture.zig");

const eqs = std.testing.expectEqualStrings;
const eqb = std.testing.expectEqualSlices;
const Kind = T.Kind;

fn expectEq(want: anytype, got: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(got), want), got);
}

/// A ustar header from literal field bytes: name 0..100, mode 100..108,
/// uid 108..116, gid 116..124, size 124..136, mtime 136..148, checksum
/// 148..156 (six octal digits, NUL, space), type flag 156, link 157..257,
/// magic 257..263, version 263..265, prefix 345..500.
fn ustar(name: []const u8, mode: *const [8]u8, size: *const [12]u8, flag: u8) []u8 {
    const h = C.a().alloc(u8, 512) catch C.oom();
    @memset(h, 0);
    @memcpy(h[0..name.len], name);
    @memcpy(h[100..108], mode);
    @memcpy(h[108..116], "0000000\x00");
    @memcpy(h[116..124], "0000000\x00");
    @memcpy(h[124..136], size);
    @memcpy(h[136..148], "00000000000\x00");
    @memset(h[148..156], ' ');
    h[156] = flag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    var sum: u32 = 0;
    for (h) |b| sum += b;
    @memcpy(h[148..156], C.fmt("{o:0>6}\x00 ", .{sum}));
    return h;
}

fn item(p: []const u8, mode: u32, data: []const u8) T.Item {
    return .{ .path = p, .mode = mode, .data = data };
}

fn zeros(out: *C.List(u8), n: usize) void {
    out.appendNTimes(0, n) catch C.oom();
}

fn sameBlocks(want: []const u8, got: []const u8) !void {
    try expectEq(want.len, got.len);
    var i: usize = 0;
    while (i < want.len) : (i += 512) {
        if (!std.mem.eql(u8, want[i .. i + 512], got[i .. i + 512])) {
            std.debug.print("block {d} differs\n", .{i / 512});
            try eqb(u8, want[i .. i + 512], got[i .. i + 512]);
        }
    }
}

test "tar_fields: the_writer_emits_these_bytes_exactly" {
    const dir = ustar("a/", "0000755\x00", "00000000000\x00", '5');
    // The checksum by hand: 3189 = 0o6165.
    try eqb(u8, "006165\x00 ", dir[148..156]);
    var want = C.list(u8);
    C.add(&want, dir);
    C.add(&want, ustar("a/f", "0000644\x00", "00000000002\x00", '0'));
    C.add(&want, "hi");
    zeros(&want, 510);
    zeros(&want, 1024);
    const got = try F.ok(T.write(&[_]T.Item{ item("a/f", 0o644, "hi"), item("a/", 0o755, "") }));
    try expectEq(5 * 512, got.len);
    try sameBlocks(want.items, got);
    // A path of 101 bytes: a pax header whose one record is 111 bytes long,
    // then the entry under the path's first 100 bytes.
    const p = F.rep("p", 101);
    var want2 = C.list(u8);
    C.add(&want2, ustar("././@PaxHeader", "0000644\x00", "00000000157\x00", 'x'));
    const r = C.fmt("111 path={s}\n", .{p});
    try expectEq(111, r.len);
    C.add(&want2, r);
    zeros(&want2, 512 - 111);
    C.add(&want2, ustar(p[0..100], "0000644\x00", "00000000000\x00", '0'));
    zeros(&want2, 1024);
    try sameBlocks(want2.items, try F.ok(T.write(&[_]T.Item{item(p, 0o644, "")})));
    // A path of exactly 100 bytes fills the name field: no pax header.
    const p100 = F.rep("p", 100);
    var want3 = C.list(u8);
    C.add(&want3, ustar(p100, "0000644\x00", "00000000000\x00", '0'));
    zeros(&want3, 1024);
    try sameBlocks(want3.items, try F.ok(T.write(&[_]T.Item{item(p100, 0o644, "")})));
}

fn headerOf(size: u64) ![]u8 {
    var h = C.list(u8);
    try F.ok(T.putHeader(&h, "f", '0', 0o644, size));
    return h.items;
}

test "tar_fields: a_size_past_eleven_octal_digits_is_written_base_256" {
    const max: u64 = 0o77777777777;
    var h = try headerOf(max);
    try eqb(u8, "77777777777\x00", h[124..136]);
    try expectEq(max, try F.ok(T.number(h, 124, 12, "size")));
    // One over: 0x80, then the number big-endian in the other eleven bytes.
    h = try headerOf(max + 1);
    try eqb(u8, &[_]u8{ 0x80, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0 }, h[124..136]);
    try expectEq(max + 1, try F.ok(T.number(h, 124, 12, "size")));
    h = try headerOf(std.math.maxInt(u64));
    try eqb(u8, &[_]u8{ 0x80, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, h[124..136]);
    try expectEq(std.math.maxInt(u64), try F.ok(T.number(h, 124, 12, "size")));
    // The checksum still holds: the reader takes the header.
    var t = C.list(u8);
    C.add(&t, h);
    zeros(&t, 1024);
    try F.expectFail(T.read(t.items), "tar: an entry runs past the end");
}

test "tar_fields: each_numeric_field_is_read_at_its_width" {
    // (width, octal maximum): mode, uid, gid and checksum are 8 bytes; size
    // and mtime 12. The maximum fills all but the last byte; one over it is
    // base-256.
    const cases = [_]struct { usize, u64 }{ .{ 8, 0o7777777 }, .{ 12, 0o77777777777 } };
    for (cases) |c| {
        const width = c[0];
        const max = c[1];
        const f = C.a().alloc(u8, width) catch C.oom();
        @memset(f, 0);
        @memcpy(f[0 .. width - 1], C.fmt("{o}", .{max}));
        try expectEq(max, try F.ok(T.number(f, 0, width, "f")));
        // Every digit filled, no NUL: still the field's own bytes only.
        var g = C.list(u8);
        C.add(&g, f);
        g.items[width - 1] = '7';
        C.push(u8, &g, '1');
        try expectEq(max * 8 + 7, try F.ok(T.number(g.items, 0, width, "f")));
        // Base-256: the low seven bits of the first byte and the rest, big-endian.
        const b = C.a().alloc(u8, width) catch C.oom();
        @memset(b, 0);
        for (0..8) |i| b[width - 1 - i] = @truncate((max + 1) >> @intCast(8 * i));
        b[0] |= 0x80;
        try expectEq(max + 1, try F.ok(T.number(b, 0, width, "f")));
        try F.ok(T.octal(f, max));
        try F.expectFail(T.octal(f, max + 1), C.fmt("tar: {d} does not fit a {d}-byte field", .{ max + 1, width }));
    }
}

/// One entry `name` with `link` and `prefix`, read back.
fn one(name: []const u8, link: []const u8, prefix: []const u8, magic: *const [8]u8) C.Fail![]T.Entry {
    const h = ustar(name, "0000777\x00", "00000000000\x00", '2');
    @memcpy(h[157 .. 157 + link.len], link);
    @memcpy(h[345 .. 345 + prefix.len], prefix);
    @memcpy(h[257..265], magic);
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    @memcpy(h[148..156], C.fmt("{o:0>6}\x00 ", .{sum}));
    return T.read(F.end(h));
}

test "tar_fields: names_links_and_prefixes_fill_their_fields_exactly" {
    for ([_]usize{ 1, 99, 100 }) |n| {
        const name = F.rep("n", n);
        const link = F.rep("l", n);
        const e = try F.ok(one(name, link, "", "ustar\x0000"));
        try eqs(name, e[0].path);
        try eqs(link, e[0].link);
    }
    // A prefix of 154 and of 155 bytes (the whole field) is joined with `/`.
    for ([_]usize{ 1, 154, 155 }) |n| {
        const prefix = F.rep("q", n);
        const e = try F.ok(one(F.rep("n", 100), "t", prefix, "ustar\x0000"));
        try eqs(C.fmt("{s}/{s}", .{ prefix, F.rep("n", 100) }), e[0].path);
    }
    // Under GNU's magic and under none, the prefix bytes are not a prefix.
    for ([_]*const [8]u8{ "ustar  \x00", &[_]u8{0} ** 8 }) |magic| {
        try eqs("n", (try F.ok(one("n", "t", "q", magic)))[0].path);
    }
    // Longer than a field: the writer says it in a pax record instead.
    for ([_]usize{ 100, 101, 155, 156, 256, 257 }) |n| {
        const p = F.rep("w", n);
        const e = try F.ok(T.read(try F.ok(T.write(&[_]T.Item{item(p, 0o644, "")}))));
        try eqs(p, e[0].path);
    }
}

test "tar_fields: every_type_flag_the_reader_accepts" {
    const kinds = [_]struct { u8, Kind }{
        .{ '0', .file },
        .{ 0, .file },
        .{ '7', .file },
        .{ '1', .hardlink },
        .{ '2', .symlink },
        .{ '5', .dir },
        .{ '3', .other },
        .{ '4', .other },
        .{ '6', .other },
        .{ 'A', .other },
    };
    for (kinds) |k| {
        const e = try F.ok(T.read(F.tar(&[_]F.E{.{ "e", k[0], 0o640, "", "t" }})));
        const link: []const u8 = if (k[1] == .symlink or k[1] == .hardlink) "t" else "";
        try expectEq(1, e.len);
        try expectEq(k[1], e[0].kind);
        try expectEq(0o640, e[0].mode);
        try eqs(link, e[0].link);
    }
    // The four that are no entry: each is for the next one, or (g) for none.
    const heads = [_]struct { u8, []const u8, []const u8 }{ .{ 'L', "body", "t" }, .{ 'K', "e", "body" }, .{ 'g', "e", "t" } };
    for (heads) |hd| {
        const e = try F.ok(T.read(F.tar(&[_]F.E{ .{ "h", hd[0], 0o644, "body", "" }, .{ "e", '2', 0o777, "", "t" } })));
        try expectEq(1, e.len);
        try eqs(hd[1], e[0].path);
        try eqs(hd[2], e[0].link);
    }
    const e = try F.ok(T.read(F.tar(&[_]F.E{ .{ "h", 'x', 0o644, "11 path=pp\n", "" }, .{ "e", '0', 0o644, "", "" } })));
    try expectEq(1, e.len);
    try eqs("pp", e[0].path);
}

/// A pax record `<len> <key>=<value>\n`, its length counting itself.
fn rec(k: []const u8, v: []const u8) []u8 {
    const body = C.fmt(" {s}={s}\n", .{ k, v });
    const n = body.len + 3;
    std.debug.assert(C.fmt("{d}", .{n}).len == 3);
    return C.fmt("{d}{s}", .{ n, body });
}

test "tar_fields: a_pax_size_is_never_the_size_of_a_header_for_the_next_entry" {
    // A pax size of 2 then a header of each kind whose own size is not 2:
    // read at 2, its body would be cut and the next header misplaced.
    const long = F.rep("k", 120);
    const g = rec("comment", F.rep("c", 600));
    const cases = [_]struct { u8, []const u8, []const u8, []const u8 }{
        .{ 'K', long, "e", long },
        .{ 'L', long, long, "t" },
        // A global header of two blocks: read at 2 bytes, one block too few.
        .{ 'g', g, "e", "t" },
    };
    for (cases) |c| {
        var t = C.list(u8);
        F.entry(&t, "PaxHeader", 'x', 0o644, "10 size=2\n", "");
        F.entry(&t, "h", c[0], 0o644, c[1], "");
        C.add(&t, F.header("e", '2', 0o777, 0, "t"));
        C.add(&t, "ab");
        F.padBlock(&t);
        zeros(&t, 1024);
        const e = try F.ok(T.read(t.items));
        try expectEq(1, e.len);
        try eqs(c[2], e[0].path);
        try eqs(c[3], e[0].link);
        try expectEq(2, e[0].size);
    }
    // Nor of a second pax header: that one is refused as a second, not read
    // at the first one's size past the end of the archive.
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, "13 size=5000\n", "");
    F.entry(&t, "PaxHeader", 'x', 0o644, "", "");
    F.entry(&t, "e", '0', 0o644, "", "");
    zeros(&t, 1024);
    try F.expectFail(T.read(t.items), "tar: two pax headers for one entry");
}

test "tar_fields: a_field_may_be_filled_to_its_last_byte" {
    // Digits in every byte of the mode, mtime and checksum fields, no NUL;
    // a 155-byte prefix; a byte in the padding after the prefix. Each field
    // is read at its own offset and width, no further.
    const h = ustar("f", "00000640", "00000000000\x00", '0');
    @memcpy(h[136..148], "777777777777");
    @memset(h[345..500], 'q');
    h[500] = 'X';
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    @memcpy(h[148..156], C.fmt("{o:0>8}", .{sum}));
    const e = try F.ok(T.read(F.end(h)));
    try eqs(C.fmt("{s}/f", .{F.rep("q", 155)}), e[0].path);
    try expectEq(0o640, e[0].mode);
    try expectEq(0, e[0].size);
    // The mode keeps its low twelve bits, not thirteen.
    const h2 = ustar("f", "0014755\x00", "00000000000\x00", '0');
    try expectEq(0o4755, (try F.ok(T.read(F.end(h2))))[0].mode);
}

test "tar_fields: a_pax_record_with_no_key_says_so" {
    // `3 \n`: a length, a space and the newline, and nothing between.
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, "3 \n", "");
    F.entry(&t, "f", '0', 0o644, "", "");
    zeros(&t, 1024);
    try F.expectFail(T.read(t.items), "tar: a pax record without `=`");
}
