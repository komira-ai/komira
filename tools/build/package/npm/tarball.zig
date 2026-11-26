//! komira_npm: the tarball an npm package is, written reproducibly and read
//! back.
//!
//! Written: a gzip stream (no name, no time, OS 255; the packer's deflate.zig,
//! a pure function of its input) over a ustar archive of the members in the
//! order given, each a regular file under `package/`, with mode 0644 or 0755,
//! owner and group 0 with no names, and one fixed mtime: 499162500 seconds
//! after the epoch, the time `npm pack` gives every member. No directory,
//! link, PAX or GNU entry; a name over 100 bytes is refused rather than split.
//! The archive ends with two zero blocks.
//!
//! Read: the gzip header must be the one written, the inflated bytes must
//! match the trailer's CRC-32 and length, and every header must be exactly
//! the header this writer writes for its name, mode and size, so a foreign
//! field (another mtime, an owner, a link, a prefix) is refused. The
//! read-back check reads what the writer wrote, nothing else.

const std = @import("std");
const deflate = @import("pack_deflate");
const diag = @import("native_policy").diag;
const Alloc = std.mem.Allocator;
const Diag = diag.Diag;
const Refused = diag.Refused;
const refuse = diag.refuse;

/// Seconds after the epoch: the fixed time `npm pack` dates every member with.
pub const mtime: u64 = 499162500;

/// Every member's path starts with it: npm drops the first component.
pub const root = "package/";

pub const Member = struct {
    name: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

const block = 512;

/// The 10 bytes of the gzip header written: deflate, no flags, no time, no
/// extra flags, OS 255 (unknown).
pub const gzip_header = [_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255 };

/// `value` as zero-padded octal filling all of `field` but its last byte,
/// which is NUL; false when it does not fit.
fn octal(field: []u8, value: u64) bool {
    var v = value;
    var i: usize = field.len - 1;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    field[field.len - 1] = 0;
    return v == 0;
}

/// The ustar header of a regular file `name` of mode `mode` and `size` bytes.
pub fn header(alloc: Alloc, d: *Diag, name: []const u8, mode: u32, size: u64) Refused![block]u8 {
    if (name.len == 0 or name.len > 100) return refuse(d, alloc, "tar: the member name `{s}` is {d} bytes; a ustar name holds 1 to 100", .{ name, name.len });
    if (mode != 0o644 and mode != 0o755) return refuse(d, alloc, "tar: {s} has mode {o}, neither 0644 nor 0755", .{ name, mode });
    var h = [_]u8{0} ** block;
    @memcpy(h[0..name.len], name);
    _ = octal(h[100..108], mode);
    _ = octal(h[108..116], 0);
    _ = octal(h[116..124], 0);
    if (!octal(h[124..136], size)) return refuse(d, alloc, "tar: {s} is {d} bytes, more than a ustar size field holds", .{ name, size });
    _ = octal(h[136..148], mtime);
    h[156] = '0';
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    _ = octal(h[148..155], sum);
    h[155] = ' ';
    return h;
}

fn pad(alloc: Alloc, out: *std.ArrayList(u8), size: usize) Alloc.Error!void {
    const rem = size % block;
    if (rem != 0) try out.appendNTimes(alloc, 0, block - rem);
}

/// The ustar archive of `members`, in their order.
pub fn writeTar(alloc: Alloc, d: *Diag, members: []const Member) Refused![]u8 {
    var out = std.ArrayList(u8).empty;
    for (members) |m| {
        if (!std.mem.startsWith(u8, m.name, root)) return refuse(d, alloc, "tar: {s} is not under {s}", .{ m.name, root });
        const h = try header(alloc, d, m.name, m.mode, m.data.len);
        try out.appendSlice(alloc, &h);
        try out.appendSlice(alloc, m.data);
        try pad(alloc, &out, m.data.len);
    }
    try out.appendNTimes(alloc, 0, 2 * block);
    return out.toOwnedSlice(alloc);
}

/// `data` as a gzip stream with the header above.
pub fn gzip(alloc: Alloc, data: []const u8) Alloc.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(alloc, &gzip_header);
    try out.appendSlice(alloc, try deflate.deflate(alloc, data));
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
    try out.appendSlice(alloc, &trailer);
    return out.toOwnedSlice(alloc);
}

/// The tarball of `members`, in their order.
pub fn write(alloc: Alloc, d: *Diag, members: []const Member) Refused![]u8 {
    return gzip(alloc, try writeTar(alloc, d, members));
}

fn inflate(alloc: Alloc, raw: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(raw);
    // No window buffer: the decoder writes straight into the output, which
    // keeps the history (the packer's deflate_test.zig says why).
    var dec = std.compress.flate.Decompress.init(&in, .raw, &.{});
    var out = std.Io.Writer.Allocating.init(alloc);
    _ = try dec.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

/// The bytes the gzip stream `z` holds, refused unless its header is the one
/// written and its trailer agrees with them.
pub fn gunzip(alloc: Alloc, d: *Diag, z: []const u8) Refused![]u8 {
    if (z.len < gzip_header.len + 8 or !std.mem.eql(u8, z[0..gzip_header.len], &gzip_header))
        return refuse(d, alloc, "gzip: the tarball does not start with the gzip header this tool writes (deflate, no flags, no time, OS 255)", .{});
    const raw = z[gzip_header.len .. z.len - 8];
    const data = inflate(alloc, raw) catch return refuse(d, alloc, "gzip: the tarball is not a valid deflate stream", .{});
    const crc = std.mem.readInt(u32, z[z.len - 8 ..][0..4], .little);
    const size = std.mem.readInt(u32, z[z.len - 4 ..][0..4], .little);
    if (std.hash.Crc32.hash(data) != crc) return refuse(d, alloc, "gzip: the inflated bytes do not have the trailer's CRC-32", .{});
    if (@as(u32, @truncate(data.len)) != size) return refuse(d, alloc, "gzip: the inflated bytes are {d} long, not the trailer's {d}", .{ data.len, size });
    return data;
}

fn parseOctal(field: []const u8) ?u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c == 0) break;
        if (c < '0' or c > '7') return null;
        v = std.math.mul(u64, v, 8) catch return null;
        v += c - '0';
    }
    return v;
}

fn zero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

/// The members of the ustar archive `tar`, in their order; anything this
/// module's writer would not write is refused.
pub fn readTar(alloc: Alloc, d: *Diag, tar: []const u8) Refused![]Member {
    var list = std.ArrayList(Member).empty;
    var at: usize = 0;
    while (true) {
        if (tar.len - at < block) return refuse(d, alloc, "tar: the archive ends inside a header, before its two zero blocks", .{});
        const h = tar[at..][0..block];
        if (zero(h)) break;
        const name = h[0 .. std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100];
        if (h[156] != '0') return refuse(d, alloc, "tar: {s} has type `{c}`, not a regular file (0)", .{ name, h[156] });
        const mode = parseOctal(h[100..108]) orelse return refuse(d, alloc, "tar: {s} has a mode field that is not octal", .{name});
        const size = parseOctal(h[124..136]) orelse return refuse(d, alloc, "tar: {s} has a size field that is not octal", .{name});
        const when = parseOctal(h[136..148]) orelse return refuse(d, alloc, "tar: {s} has an mtime field that is not octal", .{name});
        if (when != mtime) return refuse(d, alloc, "tar: {s} is dated {d}, not {d}, the fixed time npm pack gives every member", .{ name, when, mtime });
        if (!std.mem.startsWith(u8, name, root)) return refuse(d, alloc, "tar: {s} is not under {s}", .{ name, root });
        const want = try header(alloc, d, name, @intCast(mode & 0o7777), size);
        if (mode > 0o7777 or !std.mem.eql(u8, h, &want)) return refuse(d, alloc, "tar: the header of {s} is not the one this tool writes for its name, mode and size (another owner, checksum, format or field)", .{name});
        at += block;
        if (size > tar.len - at) return refuse(d, alloc, "tar: {s} is {d} bytes, past the end of the archive", .{ name, size });
        const n: usize = @intCast(size);
        const padded = (n + block - 1) / block * block;
        if (padded > tar.len - at) return refuse(d, alloc, "tar: {s} is not padded to a whole block before the archive ends", .{name});
        if (!zero(tar[at + n .. at + padded])) return refuse(d, alloc, "tar: the padding after {s} is not zero", .{name});
        try list.append(alloc, .{ .name = name, .data = tar[at..][0..n], .mode = @intCast(mode) });
        at += padded;
    }
    if (tar.len - at != 2 * block or !zero(tar[at..])) return refuse(d, alloc, "tar: the archive does not end with exactly two zero blocks", .{});
    return list.toOwnedSlice(alloc);
}

/// The members of the tarball `z`.
pub fn read(alloc: Alloc, d: *Diag, z: []const u8) Refused![]Member {
    return readTar(alloc, d, try gunzip(alloc, d, z));
}
