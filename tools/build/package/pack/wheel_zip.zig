//! komira_wheel: the zip a wheel is, written reproducibly and read back.
//!
//! Written: members in the order given; each deflated (deflate.zig, a pure
//! function of its input) when that is smaller, else stored; every date
//! 1980-01-01 00:00:00 (the earliest a zip can say); no extra field, comment,
//! data descriptor or zip64; the Unix mode in the external attributes (0755 for
//! an executable file, else 0644), so an installer keeps a library executable.
//!
//! Read: the central directory, each entry checked against its local header,
//! its CRC-32 and its sizes, deflated members inflated. A zip this writer would
//! not write (flags, extra fields, a comment, zip64, a split archive) is
//! refused: the read-back check reads the wheel the writer wrote, nothing else.

const std = @import("std");
const deflate = @import("deflate.zig");
const project = @import("wheel_project.zig");
const Alloc = std.mem.Allocator;
const Diag = project.Diag;
const Refused = project.Refused;
const refuse = project.refuse;

pub const Member = struct {
    name: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

const date: u16 = 0x0021; // 1980-01-01
const stored: u16 = 0;
const deflated: u16 = 8;
const limit: usize = 0xffff_0000;

fn put16(alloc: Alloc, out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

fn put32(alloc: Alloc, out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(alloc, &b);
}

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// The zip of `members`, in their order. A member or archive of 4 GiB or more
/// (zip64) is refused, as is a mode other than 0644 and 0755.
pub fn write(alloc: Alloc, d: *Diag, members: []const Member) Refused![]u8 {
    if (members.len > 0xffff) return refuse(d, alloc, "{d} members: a wheel of more than 65535 needs zip64, which this tool does not write", .{members.len});
    var out = std.ArrayList(u8).empty;
    const offsets = try alloc.alloc(u32, members.len);
    const methods = try alloc.alloc(u16, members.len);
    const csizes = try alloc.alloc(u32, members.len);
    for (members, 0..) |m, i| {
        if (m.mode != 0o644 and m.mode != 0o755) return refuse(d, alloc, "{s}: mode {o} is neither 0644 nor 0755", .{ m.name, m.mode });
        if (m.data.len >= limit or out.items.len >= limit)
            return refuse(d, alloc, "{s}: a wheel of 4 GiB or more needs zip64, which this tool does not write", .{m.name});
        const packed_data = try deflate.deflate(alloc, m.data);
        const use_deflate = packed_data.len < m.data.len;
        const body = if (use_deflate) packed_data else m.data;
        offsets[i] = @intCast(out.items.len);
        methods[i] = if (use_deflate) deflated else stored;
        csizes[i] = @intCast(body.len);
        try put32(alloc, &out, 0x04034b50);
        try put16(alloc, &out, 20);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, methods[i]);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, date);
        try put32(alloc, &out, std.hash.Crc32.hash(m.data));
        try put32(alloc, &out, csizes[i]);
        try put32(alloc, &out, @intCast(m.data.len));
        try put16(alloc, &out, @intCast(m.name.len));
        try put16(alloc, &out, 0);
        try out.appendSlice(alloc, m.name);
        try out.appendSlice(alloc, body);
    }
    if (out.items.len >= limit) return refuse(d, alloc, "a wheel of 4 GiB or more needs zip64, which this tool does not write", .{});
    const cd_at = out.items.len;
    for (members, 0..) |m, i| {
        try put32(alloc, &out, 0x02014b50);
        try put16(alloc, &out, 0x031e); // made by: unix, spec 3.0
        try put16(alloc, &out, 20);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, methods[i]);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, date);
        try put32(alloc, &out, std.hash.Crc32.hash(m.data));
        try put32(alloc, &out, csizes[i]);
        try put32(alloc, &out, @intCast(m.data.len));
        try put16(alloc, &out, @intCast(m.name.len));
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put16(alloc, &out, 0);
        try put32(alloc, &out, (0o100000 | m.mode) << 16);
        try put32(alloc, &out, offsets[i]);
        try out.appendSlice(alloc, m.name);
    }
    const cd_len = out.items.len - cd_at;
    try put32(alloc, &out, 0x06054b50);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, 0);
    try put16(alloc, &out, @intCast(members.len));
    try put16(alloc, &out, @intCast(members.len));
    try put32(alloc, &out, @intCast(cd_len));
    try put32(alloc, &out, @intCast(cd_at));
    try put16(alloc, &out, 0);
    return out.toOwnedSlice(alloc);
}

fn inflate(alloc: Alloc, raw: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(raw);
    // No window buffer: the decoder writes straight into the output, which
    // keeps the history (deflate_test.zig says why).
    var dec = std.compress.flate.Decompress.init(&in, .raw, &.{});
    var out = std.Io.Writer.Allocating.init(alloc);
    _ = try dec.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// The members of `z`, in central-directory order, with their data inflated
/// and their mode; anything this module's writer would not write is refused.
pub fn read(alloc: Alloc, d: *Diag, z: []const u8) Refused![]Member {
    if (z.len < 22 or rd32(z, z.len - 22) != 0x06054b50) return refuse(d, alloc, "no end-of-central-directory record in the last 22 bytes (a comment, or not a zip)", .{});
    const e = z.len - 22;
    const n = rd16(z, e + 10);
    if (rd16(z, e + 8) != n or rd16(z, e + 4) != 0 or rd16(z, e + 6) != 0) return refuse(d, alloc, "a split or inconsistent zip", .{});
    var at: usize = rd32(z, e + 16);
    if (at + rd32(z, e + 12) != e) return refuse(d, alloc, "the central directory does not end where its end record says", .{});
    var list = std.ArrayList(Member).empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (at + 46 > e or rd32(z, at) != 0x02014b50) return refuse(d, alloc, "bad central directory entry {d}", .{i});
        const flags = rd16(z, at + 8);
        const method = rd16(z, at + 10);
        const crc = rd32(z, at + 16);
        const csize = rd32(z, at + 20);
        const usize32 = rd32(z, at + 24);
        const nlen = rd16(z, at + 28);
        const xlen = rd16(z, at + 30);
        const clen = rd16(z, at + 32);
        const attrs = rd32(z, at + 38);
        const off = rd32(z, at + 42);
        if (at + 46 + nlen > e) return refuse(d, alloc, "truncated central directory", .{});
        const name = z[at + 46 ..][0..nlen];
        if (flags != 0) return refuse(d, alloc, "member {s}: general-purpose flags {d} (encryption, a data descriptor or another encoding)", .{ name, flags });
        if (method != stored and method != deflated) return refuse(d, alloc, "member {s}: compression method {d} is neither stored nor deflated", .{ name, method });
        if (xlen != 0 or clen != 0) return refuse(d, alloc, "member {s} has an extra field or a comment", .{name});
        if (method == stored and csize != usize32) return refuse(d, alloc, "member {s}: stored, but its sizes differ", .{name});
        const kind = attrs >> 28;
        const mode = (attrs >> 16) & 0o7777;
        if (kind != 0o10 or (mode != 0o644 and mode != 0o755)) return refuse(d, alloc, "member {s}: external attributes {x} are not a regular file of mode 0644 or 0755", .{ name, attrs });
        if (@as(usize, off) + 30 + nlen + csize > cdStart(z, e) or rd32(z, off) != 0x04034b50) return refuse(d, alloc, "member {s}: bad local header", .{name});
        const lnlen = rd16(z, off + 26);
        if (lnlen != nlen or rd16(z, off + 28) != 0 or !std.mem.eql(u8, z[off + 30 ..][0..lnlen], name) or
            rd16(z, off + 6) != flags or rd16(z, off + 8) != method or rd32(z, off + 14) != crc or rd32(z, off + 18) != csize or rd32(z, off + 22) != usize32)
            return refuse(d, alloc, "member {s}: local header differs from the central directory", .{name});
        const raw = z[off + 30 + lnlen ..][0..csize];
        const data = if (method == stored) raw else inflate(alloc, raw) catch
            return refuse(d, alloc, "member {s}: not a valid deflate stream", .{name});
        if (data.len != usize32) return refuse(d, alloc, "member {s}: inflates to {d} bytes, not {d}", .{ name, data.len, usize32 });
        if (std.hash.Crc32.hash(data) != crc) return refuse(d, alloc, "member {s}: bad CRC-32", .{name});
        try list.append(alloc, .{ .name = name, .data = data, .mode = mode });
        at += 46 + nlen;
    }
    return list.toOwnedSlice(alloc);
}

fn cdStart(z: []const u8, e: usize) usize {
    return rd32(z, e + 16);
}
