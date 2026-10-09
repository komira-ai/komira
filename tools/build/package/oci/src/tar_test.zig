//! The tar reader and writer's cases (tar.zig).

const std = @import("std");
const C = @import("common.zig");
const T = @import("tar.zig");
const F = @import("tar_fixture.zig");

const eqs = std.testing.expectEqualStrings;
const Kind = T.Kind;

fn expectEq(want: anytype, got: anytype) !void {
    try std.testing.expectEqual(@as(@TypeOf(got), want), got);
}

test "tar: reads_files_dirs_links_and_modes" {
    const t = F.tar(&[_]F.E{
        .{ "etc/", '5', 0o755, "", "" },
        .{ "etc/a", '0', 0o644, "hello", "" },
        .{ "bin/sh", '0', 0o4755, "x", "" },
        .{ "etc/b", '2', 0o777, "", "a" },
        .{ "etc/c", '1', 0o644, "", "etc/a" },
        .{ "dev/null", '3', 0o666, "", "" },
    });
    const e = try F.ok(T.read(t));
    const Want = struct { []const u8, Kind, u32, u64, []const u8 };
    const want = [_]Want{
        .{ "etc/", .dir, 0o755, 0, "" },
        .{ "etc/a", .file, 0o644, 5, "" },
        .{ "bin/sh", .file, 0o4755, 1, "" },
        .{ "etc/b", .symlink, 0o777, 0, "a" },
        .{ "etc/c", .hardlink, 0o644, 0, "etc/a" },
        .{ "dev/null", .other, 0o666, 0, "" },
    };
    try expectEq(want.len, e.len);
    for (want, e) |w, g| {
        try eqs(w[0], g.path);
        try expectEq(w[1], g.kind);
        try expectEq(w[2], g.mode);
        try expectEq(w[3], g.size);
        try eqs(w[4], g.link);
    }
}

test "tar: reads_a_pax_path_and_a_gnu_long_name" {
    const long = F.cat(F.rep("d/", 70), "f");
    const r0 = C.fmt(" path={s}\n", .{long});
    const record = C.fmt("{d}{s}", .{ r0.len + C.fmt("{d}", .{r0.len + 3}).len, r0 });
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, record, "");
    F.entry(&t, "short", '0', 0o755, "ab", "");
    F.entry(&t, "././@LongLink", 'L', 0o644, C.fmt("{s}2\x00", .{long}), "");
    F.entry(&t, "short2", '0', 0o644, "", "");
    const e = try F.ok(T.read(F.end(t.items)));
    try eqs(long, e[0].path);
    try expectEq(@as(u32, 0o755), e[0].mode);
    try expectEq(@as(u64, 2), e[0].size);
    try eqs(F.cat(long, "2"), e[1].path);
}

fn item(p: []const u8, m: u32, d: []const u8) T.Item {
    return .{ .path = p, .mode = m, .data = d };
}

test "tar: writes_what_it_reads_back_sorted" {
    const long = F.cat(F.rep("d/", 60), "file");
    const t = try F.ok(T.write(&[_]T.Item{ item("b", 0o644, "bee"), item(long, 0o755, "x"), item("a/", 0o755, "") }));
    try expectEq(@as(usize, 0), t.len % 512);
    const got = try F.ok(T.read(t));
    try expectEq(@as(usize, 3), got.len);
    try eqs("a/", got[0].path);
    try expectEq(Kind.dir, got[0].kind);
    try expectEq(@as(u32, 0o755), got[0].mode);
    try expectEq(@as(u64, 0), got[0].size);
    try eqs("b", got[1].path);
    try expectEq(Kind.file, got[1].kind);
    try expectEq(@as(u32, 0o644), got[1].mode);
    try expectEq(@as(u64, 3), got[1].size);
    try eqs(long, got[2].path);
    try expectEq(Kind.file, got[2].kind);
    try expectEq(@as(u32, 0o755), got[2].mode);
    try expectEq(@as(u64, 1), got[2].size);
    // The same items give the same bytes; uid, gid and mtime are 0.
    try std.testing.expectEqualSlices(u8, t, try F.ok(T.write(&[_]T.Item{ item("a/", 0o755, ""), item(long, 0o755, "x"), item("b", 0o644, "bee") })));
    try std.testing.expectEqualSlices(u8, "00000000000\x00", t[136..148]);
    try F.expectFailContains(T.write(&[_]T.Item{ item("a", 0o644, ""), item("a", 0o755, "") }), "a given twice");
    // Two zero blocks end it, after the last entry's data block.
    for (t[t.len - 1024 ..]) |b| try expectEq(@as(u8, 0), b);
    try expectEq(@as(u8, 'x'), t[t.len - 1536]);
}

/// The header's checksum written again after an edit, as `%07o\0`
/// (byte 155 NUL: the sum must count all eight checksum bytes as spaces).
fn resum(h: []u8) void {
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h[0..512]) |b| sum += b;
    @memcpy(h[148..156], C.fmt("{o:0>7}\x00", .{sum}));
}

fn withPax(r: []const u8) C.Fail![]T.Entry {
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, r, "");
    F.entry(&t, "f", '0', 0o644, "", "");
    return T.read(F.end(t.items));
}

test "tar: each_malformed_pax_record_is_refused" {
    const cases = [_][2][]const u8{
        .{ "abc", "tar: a pax record without a length" },
        .{ "x path=a\n", "tar: a pax record length is not a number" },
        .{ "9 a=b\n", "tar: a malformed pax record" },
        .{ "7 a=b\n", "tar: a malformed pax record" },
        .{ "6 a=bX", "tar: a malformed pax record" },
        .{ "2 \n", "tar: a malformed pax record" },
        .{ "0 a=b\n", "tar: a malformed pax record" },
        .{ "5 ab\n", "tar: a pax record without `=`" },
        .{ "6 \xff=b\n", "tar: a pax key is not UTF-8" },
        .{ "7 a=\xffb\n", "tar: a pax value is not UTF-8" },
        .{ "9 size=x\n", "tar: a pax size is not a number" },
        .{ "6 a=b\n6 a=c\n", "tar: pax key `a` given twice" },
    };
    for (cases) |c| try F.expectFail(withPax(c[0]), c[1]);
    // Every record is read, not only the first.
    try eqs("xyz", (try F.ok(withPax("6 a=b\n12 path=xyz\n")))[0].path);
}

test "tar: a_pax_size_is_the_size_of_the_next_entry_only" {
    // The header says 0; the pax record says 3.
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, "10 size=3\n", "");
    C.add(&t, F.header("f", '0', 0o644, 0, ""));
    C.add(&t, "abc");
    F.padBlock(&t);
    F.entry(&t, "g", '0', 0o644, "z", "");
    const e = try F.ok(T.read(F.end(t.items)));
    try expectEq(@as(usize, 2), e.len);
    try eqs("f", e[0].path);
    try expectEq(@as(u64, 3), e[0].size);
    try eqs("g", e[1].path);
    try expectEq(@as(u64, 1), e[1].size);
    // Not the size of a long-name header that comes between.
    const long = F.rep("n", 120);
    var t2 = C.list(u8);
    F.entry(&t2, "PaxHeader", 'x', 0o644, "10 size=2\n", "");
    F.entry(&t2, "././@LongLink", 'L', 0o644, long, "");
    C.add(&t2, F.header("short", '0', 0o644, 0, ""));
    C.add(&t2, "ab");
    F.padBlock(&t2);
    const e2 = try F.ok(T.read(F.end(t2.items)));
    try eqs(long, e2[0].path);
    try expectEq(@as(u64, 2), e2[0].size);
}

/// A header for `f` edited by the caller, then read: `fresh` gives one,
/// `readEdited` re-sums it and reads it with the two zero blocks after it.
fn fresh() []u8 {
    return F.header("f", '0', 0o644, 0, "");
}

fn readEdited(h: []u8) C.Fail![]T.Entry {
    resum(h);
    var t = C.list(u8);
    C.add(&t, h);
    t.appendNTimes(0, 1024 + 512) catch C.oom();
    return T.read(t.items);
}

test "tar: numbers_are_octal_or_base_256" {
    // Base-256: 0x80 then big-endian bytes.
    var h = fresh();
    @memset(h[124..136], 0);
    h[124] = 0x80;
    h[135] = 3;
    try expectEq(@as(u64, 3), (try F.ok(readEdited(h)))[0].size);
    // Every byte counts, at its place.
    h = fresh();
    @memset(h[124..136], 0);
    h[124] = 0x80;
    h[134] = 1;
    h[135] = 2;
    try expectEq(@as(u64, 258), (try F.ok(readEdited(h)))[0].size);
    h = fresh();
    @memset(h[124..136], 0xff);
    try F.expectFail(readEdited(h), "tar: size overflows");
    // The first byte's low bits are the top of the number: 2^88 overflows.
    h = fresh();
    @memset(h[124..136], 0);
    h[124] = 0x81;
    try F.expectFail(readEdited(h), "tar: size overflows");
    h = fresh();
    @memcpy(h[124..136], "00000000z0\x00\x00");
    try F.expectFail(readEdited(h), "tar: size `00000000z0` is not octal");
    h = fresh();
    @memcpy(h[124..136], "0000000000\xff\x00");
    try F.expectFail(readEdited(h), "tar: size is not octal");
    // NULs and spaces around the digits; an empty field is 0.
    h = fresh();
    @memcpy(h[100..108], " 644 \x00\x00\x00");
    try expectEq(@as(u32, 0o644), (try F.ok(readEdited(h)))[0].mode);
    h = fresh();
    @memset(h[100..108], 0);
    try expectEq(@as(u32, 0), (try F.ok(readEdited(h)))[0].mode);
    // The mode keeps its low twelve bits.
    h = fresh();
    @memcpy(h[100..108], "0104755\x00");
    try expectEq(@as(u32, 0o4755), (try F.ok(readEdited(h)))[0].mode);
    // A name that is not UTF-8.
    h = fresh();
    h[0] = 0xff;
    try F.expectFail(readEdited(h), "tar: a name is not UTF-8");
}

test "tar: names_links_and_kinds" {
    var t = C.list(u8);
    // A ustar prefix is joined to the name; without the ustar magic it is not read.
    const h = F.header("c", '0', 0o644, 0, "");
    @memcpy(h[345..348], "a/b");
    resum(h);
    C.add(&t, h);
    @memset(h[257..263], 0);
    resum(h);
    C.add(&t, h);
    // Only links keep a link name; NUL and '7' are files; a global header is no entry.
    F.entry(&t, "file", '0', 0o644, "", "x");
    F.entry(&t, "dir/", '5', 0o755, "", "x");
    F.entry(&t, "hard", '1', 0o644, "", "file");
    F.entry(&t, "nul", 0, 0o644, "", "");
    F.entry(&t, "contig", '7', 0o644, "", "");
    F.entry(&t, "global", 'g', 0o644, "11 path=zz\n", "");
    const long = F.rep("t", 130);
    F.entry(&t, "././@LongLink", 'K', 0o644, long, "");
    F.entry(&t, "sym", '2', 0o777, "", "short");
    const got = try F.ok(T.read(F.end(t.items)));
    const Want = struct { []const u8, Kind, []const u8 };
    const want = [_]Want{
        .{ "a/b/c", .file, "" },
        .{ "c", .file, "" },
        .{ "file", .file, "" },
        .{ "dir/", .dir, "" },
        .{ "hard", .hardlink, "file" },
        .{ "nul", .file, "" },
        .{ "contig", .file, "" },
        .{ "sym", .symlink, long },
    };
    try expectEq(want.len, got.len);
    for (want, got) |w, g| {
        try eqs(w[0], g.path);
        try expectEq(w[1], g.kind);
        try eqs(w[2], g.link);
    }
}

/// A pax record `<len> <key>=<value>\n`, its length counting itself.
fn rec(k: []const u8, v: []const u8) []u8 {
    const body = C.fmt(" {s}={s}\n", .{ k, v });
    var n = body.len + 1;
    while (body.len + C.fmt("{d}", .{n}).len != n) {
        n = body.len + C.fmt("{d}", .{n}).len;
    }
    return C.fmt("{d}{s}", .{ n, body });
}

test "tar: a_long_name_long_link_or_pax_header_is_for_the_next_entry_only" {
    const long = F.rep("n", 120);
    const long2 = F.cat(F.rep("m/", 60), "x");
    const target = F.cat(F.rep("t/", 60), "x");
    const target2 = F.rep("u", 150);
    var t = C.list(u8);
    F.entry(&t, "././@LongLink", 'L', 0o644, long, "");
    F.entry(&t, "a", '0', 0o644, "", "");
    F.entry(&t, "b", '0', 0o644, "", "");
    F.entry(&t, "././@LongLink", 'K', 0o644, target, "");
    F.entry(&t, "l1", '2', 0o777, "", "s1");
    F.entry(&t, "l2", '2', 0o777, "", "s2");
    F.entry(&t, "PaxHeader", 'x', 0o644, F.cat(rec("path", long2), rec("linkpath", target2)), "");
    F.entry(&t, "l3", '2', 0o777, "", "s3");
    F.entry(&t, "l4", '2', 0o777, "", "s4");
    const got = try F.ok(T.read(F.end(t.items)));
    const want = [_][2][]const u8{ .{ long, "" }, .{ "b", "" }, .{ "l1", target }, .{ "l2", "s2" }, .{ long2, target2 }, .{ "l4", "s4" } };
    try expectEq(want.len, got.len);
    for (want, got) |w, g| {
        try eqs(w[0], g.path);
        try eqs(w[1], g.link);
    }
}

fn longHdr(flag: u8) []u8 {
    var t = C.list(u8);
    F.entry(&t, "././@LongLink", flag, 0o644, "long", "");
    return t.items;
}

fn paxHdr() []u8 {
    var t = C.list(u8);
    F.entry(&t, "PaxHeader", 'x', 0o644, "", "");
    return t.items;
}

fn then(first: []const u8, more: []const u8) C.Fail![]T.Entry {
    var t = C.list(u8);
    C.add(&t, first);
    C.add(&t, more);
    F.entry(&t, "f", '2', 0o777, "", "x");
    return T.read(F.end(t.items));
}

test "tar: a_header_for_the_next_entry_comes_once_and_is_followed_by_one" {
    try F.expectFail(then(longHdr('L'), longHdr('L')), "tar: two long names for one entry");
    try F.expectFail(then(longHdr('K'), longHdr('K')), "tar: two long links for one entry");
    // An empty pax header is a header all the same.
    try F.expectFail(then(paxHdr(), paxHdr()), "tar: two pax headers for one entry");
    // One of each kind is fine; a global header is none of them.
    var g = C.list(u8);
    F.entry(&g, "global", 'g', 0o644, "", "");
    var all = C.list(u8);
    C.add(&all, longHdr('K'));
    C.add(&all, paxHdr());
    C.add(&all, g.items);
    const e = try F.ok(then(longHdr('L'), all.items));
    try eqs("long", e[0].path);
    try eqs("long", e[0].link);
    // A header with no entry after it: the archive was cut short.
    for ([_][]const u8{ longHdr('L'), longHdr('K'), paxHdr() }) |t| {
        try F.expectFail(T.read(F.end(t)), "tar: the archive ends after a header for no entry");
    }
}

test "tar: a_gnu_header_has_no_name_prefix" {
    // GNU's magic is `ustar  \0`; bytes 345.. hold its atime, not a prefix.
    const h = F.header("c", '0', 0o644, 0, "");
    @memcpy(h[257..265], "ustar  \x00");
    @memcpy(h[345..357], "15000000000\x00");
    resum(h);
    try eqs("c", (try F.ok(T.read(F.end(h))))[0].path);
}

fn sized(size: usize, total: usize, fill: u8) []u8 {
    var t = C.list(u8);
    C.add(&t, F.header("f", '0', 0o644, size, ""));
    t.appendNTimes(fill, total - 512) catch C.oom();
    return t.items;
}

test "tar: an_entry_ending_at_the_archive_end_still_wants_a_zero_block" {
    try F.expectFail(T.read(sized(2000, 512 + 1024, 0)), "tar: an entry runs past the end");
    // One byte past the end.
    try F.expectFail(T.read(sized(513, 1024, 1)), "tar: an entry runs past the end");
    try F.expectFail(T.read(sized(512, 1024, 1)), "tar: the archive ends without a zero block");
}

test "tar: long_paths_round_trip_at_every_length_boundary" {
    // 100 bytes fits the header; 101 takes a pax record, whose length
    // field grows from 3 to 4 digits between 989 and 990 bytes of path.
    for ([_]usize{ 99, 100, 101, 102, 988, 989, 990, 991 }) |n| {
        const path = F.rep("p", n);
        const t = try F.ok(T.write(&[_]T.Item{item(path, 0o644, "d")}));
        const e = try F.ok(T.read(t));
        try expectEq(@as(usize, 1), e.len);
        try expectEq(n, e[0].path.len);
        try expectEq(@as(u64, 1), e[0].size);
    }
    var f = [_]u8{0} ** 8;
    try F.ok(T.octal(&f, 0o7777777));
    try std.testing.expectEqualSlices(u8, "7777777\x00", &f);
    try F.expectFail(T.octal(&f, 0o10000000), "tar: 2097152 does not fit a 8-byte field");
    try F.expectFailPrefix(T.write(&[_]T.Item{item("a", 0o10000000, "")}), "");
}

test "tar: refuses_a_bad_checksum_and_a_truncated_archive" {
    const t = F.tar(&[_]F.E{.{ "a", '0', 0o644, "x", "" }});
    t[0] = 'b';
    try F.expectFailContains(T.read(t), "checksum");
    const t2 = F.tar(&[_]F.E{.{ "a", '0', 0o644, "x", "" }});
    try F.expectFailContains(T.read(t2[0..1024]), "zero block");
    try F.expectFailPrefix(T.read(t2[0..600]), "");
}
