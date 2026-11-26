//! The wheel's zip: what is written reads back member for member, with its
//! mode and date; a member that compresses is deflated and one that does not
//! is stored; the stamp's commit time is the DOS date of every member; and a
//! zip this writer would not write is refused, each defect by name.

const std = @import("std");
const diag = @import("native_policy").diag;
const zip = @import("zip.zig");
const t = std.testing;

const members = [_]zip.Member{
    .{ .name = "komira/__init__.py", .data = "a" ** 400 },
    .{ .name = "komira/_lib/libkomira.so", .data = "\x01\x7f\x03", .mode = 0o755 },
    .{ .name = "komira/py.typed", .data = "" },
};

fn written(alloc: std.mem.Allocator) ![]u8 {
    var d = diag.Diag{};
    return zip.write(alloc, &d, &members, .{});
}

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

test "every member reads back with its bytes, mode and order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const z = try written(a);
    var d = diag.Diag{};
    const back = try zip.read(a, &d, z);
    try t.expectEqual(members.len, back.len);
    for (members, back) |want, got| {
        try t.expectEqualStrings(want.name, got.name);
        try t.expectEqualSlices(u8, want.data, got.data);
        try t.expectEqual(want.mode, got.mode);
        try t.expectEqual(@as(u16, 0x0021), got.stamp.date);
        try t.expectEqual(@as(u16, 0), got.stamp.time);
    }
}

test "a member that compresses is deflated, one that does not is stored, and the dates are 1980-01-01" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const z = try written(arena.allocator());
    // The first local header: method at 8, time at 10, date at 12.
    try t.expectEqual(@as(u16, 8), rd16(z, 8));
    try t.expectEqual(@as(u16, 0), rd16(z, 10));
    try t.expectEqual(@as(u16, 0x0021), rd16(z, 12));
    // The second member, three bytes, is stored: its local header follows the
    // first one's name and deflated body.
    const first_len = std.mem.readInt(u32, z[18..22], .little);
    const second = 30 + members[0].name.len + first_len;
    try t.expectEqual(@as(u16, 0), rd16(z, second + 8));
}

test "the same members give the same bytes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualSlices(u8, try written(a), try written(a));
}

test "a mode other than 0644 and 0755 is refused when writing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = diag.Diag{};
    try t.expectError(error.Refused, zip.write(arena.allocator(), &d, &.{.{ .name = "x", .data = "", .mode = 0o600 }}, .{}));
    try t.expectEqualStrings("x: mode 600 is neither 0644 nor 0755", d.msg);
}

test "more members than a zip32 directory counts is refused when writing" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const many = try a.alloc(zip.Member, 0x10000);
    for (many) |*m| m.* = .{ .name = "x", .data = "" };
    var d = diag.Diag{};
    try t.expectError(error.Refused, zip.write(a, &d, many, .{}));
    try t.expectEqualStrings("65536 members: a wheel of more than 65535 needs zip64, which this tool does not write", d.msg);
}

fn readRefusal(a: std.mem.Allocator, z: []const u8) ![]const u8 {
    var d = diag.Diag{};
    try t.expectError(error.Refused, zip.read(a, &d, z));
    return d.msg;
}

test "a damaged or foreign zip is refused, each defect by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = try written(a);

    try t.expectEqualStrings("no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)", try readRefusal(a, "not a zip"));

    const commented = try std.mem.concat(a, u8, &.{ good, "x" });
    try t.expectEqualStrings("no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)", try readRefusal(a, commented));

    // The first member's CRC, in its local header only.
    var crc = try a.dupe(u8, good);
    crc[14] ^= 1;
    try t.expectEqualStrings("member komira/__init__.py: local header differs from the central directory", try readRefusal(a, crc));

    // A flag bit in both headers.
    const cd = std.mem.readInt(u32, good[good.len - 6 ..][0..4], .little);
    var flagged = try a.dupe(u8, good);
    flagged[6] = 8;
    flagged[cd + 8] = 8;
    try t.expectEqualStrings("member komira/__init__.py: general-purpose flags 8 (encryption, a data descriptor or another encoding)", try readRefusal(a, flagged));

    // Another method in the central directory.
    var method = try a.dupe(u8, good);
    method[cd + 10] = 12;
    try t.expectEqualStrings("member komira/__init__.py: compression method 12 is neither stored nor deflated", try readRefusal(a, method));

    // A symbolic link's external attributes.
    var link = try a.dupe(u8, good);
    std.mem.writeInt(u32, link[cd + 38 ..][0..4], 0o120777 << 16, .little);
    try t.expectEqualStrings("member komira/__init__.py: external attributes a1ff0000 are not a regular file of mode 0644 or 0755", try readRefusal(a, link));

    // A data byte changed in a stored member: its CRC no longer holds.
    var body = try a.dupe(u8, good);
    const first_len = std.mem.readInt(u32, good[18..22], .little);
    const second = 30 + members[0].name.len + first_len;
    body[second + 30 + members[1].name.len] ^= 0xff;
    try t.expectEqualStrings("member komira/_lib/libkomira.so: bad CRC-32", try readRefusal(a, body));

    // A deflated body that is not deflate.
    var bad = try a.dupe(u8, good);
    bad[30 + members[0].name.len] = 0xff;
    try t.expectEqualStrings("member komira/__init__.py: not a valid deflate stream", try readRefusal(a, bad));

    // The end record's central directory size off by one.
    var cdlen = try a.dupe(u8, good);
    cdlen[cdlen.len - 10] +%= 1;
    try t.expectEqualStrings("the central directory does not end where its end record says", try readRefusal(a, cdlen));

    // A split archive.
    var split = try a.dupe(u8, good);
    split[split.len - 18] = 1;
    try t.expectEqualStrings("a split or inconsistent zip", try readRefusal(a, split));

    // An extra field announced in the central directory.
    var extra = try a.dupe(u8, good);
    extra[cd + 30] = 1;
    try t.expectEqualStrings("member komira/__init__.py has an extra field or a comment", try readRefusal(a, extra));

    // A central entry that is not one.
    var sig = try a.dupe(u8, good);
    sig[cd] = 0;
    try t.expectEqualStrings("bad central directory entry 0", try readRefusal(a, sig));
}

test "a commit time is the DOS date and time of every member, in UTC" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d = diag.Diag{};
    // 2026-11-20 14:48:49 UTC: (46 << 9) | (11 << 5) | 20, (14 << 11) | (48 << 5) | 24.
    const s = try zip.stampOf(a, &d, 1795186129_000);
    try t.expectEqual(@as(u16, (46 << 9) | (11 << 5) | 20), s.date);
    try t.expectEqual(@as(u16, (14 << 11) | (48 << 5) | 24), s.time);
    const z = try zip.write(a, &d, &members, s);
    for (try zip.read(a, &d, z)) |m| {
        try t.expectEqual(s.date, m.stamp.date);
        try t.expectEqual(s.time, m.stamp.time);
    }
    // Unstamped (0), and any time before 1980, is 1980-01-01 00:00:00.
    try t.expectEqual(zip.Stamp{}, try zip.stampOf(a, &d, 0));
    try t.expectEqual(zip.Stamp{}, try zip.stampOf(a, &d, 86400000));
    try t.expectError(error.Refused, zip.stampOf(a, &d, -1));
    try t.expectEqualStrings("the commit time -1 ms is before the epoch", d.msg);
    try t.expectError(error.Refused, zip.stampOf(a, &d, 4354819200_000));
    try t.expectEqualStrings("the commit time 4354819200000 ms is after 2107, which a zip cannot date", d.msg);
}
