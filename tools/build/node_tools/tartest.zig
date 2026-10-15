//! Test support: tar and gzip archives built in memory.
const std = @import("std");

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
    var out = std.ArrayList(u8).init(a);
    for (entries) |e| {
        var h = [_]u8{0} ** 512;
        @memcpy(h[0..e.name.len], e.name);
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
        try out.appendSlice(&h);
        try out.appendSlice(e.data);
        const pad = (512 - e.data.len % 512) % 512;
        try out.appendNTimes(0, pad);
    }
    try out.appendNTimes(0, 1024);
    return out.toOwnedSlice();
}

/// A gzip stream of `bytes` in stored (uncompressed) deflate blocks.
pub fn gzip(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(&.{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3 });
    var off: usize = 0;
    while (true) {
        const n = @min(bytes.len - off, 65535);
        const last = off + n == bytes.len;
        try out.append(if (last) 1 else 0);
        try out.writer().writeInt(u16, @intCast(n), .little);
        try out.writer().writeInt(u16, @intCast(~@as(u16, @intCast(n))), .little);
        try out.appendSlice(bytes[off .. off + n]);
        off += n;
        if (last) break;
    }
    try out.writer().writeInt(u32, std.hash.Crc32.hash(bytes), .little);
    try out.writer().writeInt(u32, @intCast(bytes.len), .little);
    return out.toOwnedSlice();
}

/// `package/package.json` of a package, and the files after it, as a .tgz.
pub fn tgz(a: std.mem.Allocator, name: []const u8, version: []const u8, more: []const Entry) ![]u8 {
    const pj = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"{s}\"}}", .{ name, version });
    var all = std.ArrayList(Entry).init(a);
    try all.append(.{ .name = "package/", .kind = '5', .mode = 0o755 });
    try all.append(.{ .name = "package/package.json", .data = pj });
    try all.appendSlice(more);
    return gzip(a, try tar(a, all.items));
}
