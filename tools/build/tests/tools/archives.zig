//! tests_act's `stand-in-archive`: a `.tar.gz` whose one top directory holds the
//! files a fixture names, written without a tar or gzip program (a ustar writer and
//! a gzip stream of stored blocks).

const std = @import("std");
const A = std.mem.Allocator;

fn octal(dst: []u8, v: u64) void {
    @memset(dst, '0');
    var i: usize = dst.len - 1;
    dst[i] = 0;
    var x = v;
    while (i > 0 and x > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
    }
}

/// Appends a ustar entry; `kind` is '0' (file) or '5' (directory, `name` ends in /).
pub fn tarEntry(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, kind: u8, mode: u32, data: []const u8) !void {
    if (name.len > 99) return error.NameTooLong;
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..name.len], name);
    octal(h[100..108], mode);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], data.len);
    octal(h[136..148], 0);
    @memset(h[148..156], ' ');
    h[156] = kind;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    var sum: u32 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[154] = 0;
    h[155] = ' ';
    try out.appendSlice(alloc, &h);
    try out.appendSlice(alloc, data);
    try out.appendNTimes(alloc, 0, (512 - data.len % 512) % 512);
}

/// A gzip stream holding `data` in stored (uncompressed) deflate blocks.
pub fn gzipStored(a: A, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, &.{ 0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xff });
    var at: usize = 0;
    while (true) {
        const n = @min(data.len - at, 65535);
        const last = at + n == data.len;
        try out.append(a, if (last) 1 else 0);
        try out.writer(a).writeInt(u16, @intCast(n), .little);
        try out.writer(a).writeInt(u16, ~@as(u16, @intCast(n)), .little);
        try out.appendSlice(a, data[at .. at + n]);
        at += n;
        if (last) break;
    }
    try out.writer(a).writeInt(u32, std.hash.Crc32.hash(data), .little);
    try out.writer(a).writeInt(u32, @truncate(data.len), .little);
    return out.toOwnedSlice(a);
}

/// The tar of directory `top` holding the entries `file:<path>` (one line of
/// text, mode 644) and `program:<path>` (a copy of `program_bytes`, mode 755).
pub fn standInTar(a: A, top: []const u8, entries: []const []const u8, program_bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    var dirs = std.StringHashMap(void).init(a);
    const top_dir = try std.fmt.allocPrint(a, "{s}/", .{top});
    try tarEntry(a, &out, top_dir, '5', 0o755, "");
    try dirs.put(top_dir, {});
    for (entries) |e| {
        const colon = std.mem.indexOfScalar(u8, e, ':') orelse return error.BadEntry;
        const kind = e[0..colon];
        const path = e[colon + 1 ..];
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, path, at, '/')) |s| {
            const d = try std.fmt.allocPrint(a, "{s}/{s}/", .{ top, path[0..s] });
            if (!dirs.contains(d)) {
                try tarEntry(a, &out, d, '5', 0o755, "");
                try dirs.put(d, {});
            }
            at = s + 1;
        }
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ top, path });
        if (std.mem.eql(u8, kind, "file")) {
            try tarEntry(a, &out, full, '0', 0o644, "a stand-in file of test 54\n");
        } else if (std.mem.eql(u8, kind, "program")) {
            try tarEntry(a, &out, full, '0', 0o755, program_bytes);
        } else return error.BadEntry;
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

/// stand-in-archive <busybox> <out> <top> <entry>...
pub fn standInArchive(a: A, args: []const []const u8) !void {
    if (args.len < 3) return error.Usage;
    const bb = try std.fs.cwd().readFileAlloc(a, args[0], 1 << 30);
    const tar = try standInTar(a, args[2], args[3..], bb);
    const gz = try gzipStored(a, tar);
    const f = try std.fs.cwd().createFile(args[1], .{});
    defer f.close();
    try f.writeAll(gz);
}
