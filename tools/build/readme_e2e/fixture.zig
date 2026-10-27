//! Made-up packages for the tests: a `.conda` the way `mopm pack` lays one out
//! (a zip of stored members holding `pkg-*.tar.zst` and `info-*.tar.zst`).
//! The zstd frames hold one raw block each, which every zstd reader takes.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Entry = struct { name: []const u8, bytes: []const u8 };

/// A zstd frame holding `content` in one raw block (at most 128 KiB).
pub fn zstdRaw(a: Allocator, content: []const u8) ![]u8 {
    std.debug.assert(content.len <= (1 << 17));
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, &.{ 0x28, 0xb5, 0x2f, 0xfd });
    // Single segment, a 4-byte content size, no checksum, no dictionary.
    try out.append(a, 0xa0);
    var size: [4]u8 = undefined;
    std.mem.writeInt(u32, &size, @intCast(content.len), .little);
    try out.appendSlice(a, &size);
    // The one block: last, raw, `content.len` bytes.
    var head: [3]u8 = undefined;
    const word: u32 = (@as(u32, @intCast(content.len)) << 3) | 1;
    head[0] = @truncate(word);
    head[1] = @truncate(word >> 8);
    head[2] = @truncate(word >> 16);
    try out.appendSlice(a, &head);
    try out.appendSlice(a, content);
    return out.items;
}

/// A tar of regular files, each mode 0644.
pub fn tarOf(a: Allocator, entries: []const Entry) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var tw: std.tar.Writer = .{ .underlying_writer = &aw.writer };
    for (entries) |e| try tw.writeFileBytes(e.name, e.bytes, .{ .mode = 0o644, .mtime = 1 });
    try tw.finishPedantically();
    return aw.toOwnedSlice();
}

/// A tar holding one symbolic link, for the refusal of one.
pub fn tarWithLink(a: Allocator, name: []const u8, target: []const u8) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(a);
    var tw: std.tar.Writer = .{ .underlying_writer = &aw.writer };
    try tw.writeLink(name, target, .{ .mode = 0o777, .mtime = 1 });
    try tw.finishPedantically();
    return aw.toOwnedSlice();
}

fn zipMember(a: Allocator, out: *std.ArrayList(u8), name: []const u8, data: []const u8, method: u16) !void {
    var h: [30]u8 = undefined;
    std.mem.writeInt(u32, h[0..4], 0x04034b50, .little);
    std.mem.writeInt(u16, h[4..6], 20, .little);
    std.mem.writeInt(u16, h[6..8], 0, .little);
    std.mem.writeInt(u16, h[8..10], method, .little);
    std.mem.writeInt(u16, h[10..12], 0, .little);
    std.mem.writeInt(u16, h[12..14], 0x21, .little);
    std.mem.writeInt(u32, h[14..18], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, h[18..22], @intCast(data.len), .little);
    std.mem.writeInt(u32, h[22..26], @intCast(data.len), .little);
    std.mem.writeInt(u16, h[26..28], @intCast(name.len), .little);
    std.mem.writeInt(u16, h[28..30], 0, .little);
    try out.appendSlice(a, &h);
    try out.appendSlice(a, name);
    try out.appendSlice(a, data);
}

/// A `.conda` whose payload holds `payload` (zstd of a tar) as stored zip members.
pub fn condaOf(a: Allocator, stem: []const u8, pkg_tar: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try zipMember(a, &out, "metadata.json", "{\"conda_pkg_format_version\": 2}", 0);
    const info = try tarOf(a, &.{.{ .name = "info/index.json", .bytes = "{}" }});
    try zipMember(a, &out, try std.fmt.allocPrint(a, "info-{s}.tar.zst", .{stem}), try zstdRaw(a, info), 0);
    try zipMember(a, &out, try std.fmt.allocPrint(a, "pkg-{s}.tar.zst", .{stem}), try zstdRaw(a, pkg_tar), 0);
    return out.items;
}

/// The same with the payload member deflated (method 8), which no reader here takes.
pub fn condaDeflated(a: Allocator, stem: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try zipMember(a, &out, try std.fmt.allocPrint(a, "pkg-{s}.tar.zst", .{stem}), "x", 8);
    return out.items;
}

/// A static native library a package declares, as `mopm pack` lays one out for a workspace member:
/// `lib/<soname>` (`lib<stem>.a`) named by `static_file` from `lib/mojo/`. `ship = false` declares it
/// and leaves the file out, a package that cannot be linked.
pub const Static = struct { soname: []const u8, bytes: []const u8, ship: bool = true };

/// A package as `mopm pack` makes it: `lib/mojo/<name>.mojoc` (the bytes given)
/// and `lib/mojo/<name>.mopm.json` naming `deps`.
pub fn package(a: Allocator, name: []const u8, version: []const u8, build: []const u8, mojoc: []const u8, deps: []const []const u8) ![]u8 {
    return packageWith(a, name, version, build, mojoc, deps, &.{});
}

/// The same, shipping `natives`.
pub fn packageWith(a: Allocator, name: []const u8, version: []const u8, build: []const u8, mojoc: []const u8, deps: []const []const u8, natives: []const Static) ![]u8 {
    var meta: std.ArrayList(u8) = .empty;
    try meta.appendSlice(a, try std.fmt.allocPrint(a, "{{\"deps\":[", .{}));
    for (deps, 0..) |d, i| {
        if (i != 0) try meta.append(a, ',');
        try meta.appendSlice(a, try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"range\":\"*\"}}", .{d}));
    }
    try meta.appendSlice(a, "],\"name\":\"");
    try meta.appendSlice(a, name);
    try meta.appendSlice(a, "\"");
    if (natives.len != 0) {
        try meta.appendSlice(a, ",\"native\":[");
        for (natives, 0..) |n, i| {
            if (i != 0) try meta.append(a, ',');
            const stem = n.soname["lib".len .. n.soname.len - ".a".len];
            try meta.appendSlice(a, try std.fmt.allocPrint(a, "{{\"id\":\"{s}\",\"kind\":\"static\",\"soname\":\"{s}\",\"static_file\":\"../{s}\"}}", .{ stem, n.soname, n.soname }));
        }
        try meta.append(a, ']');
    }
    try meta.appendSlice(a, try std.fmt.allocPrint(a, ",\"schema\":1,\"version\":\"{s}\"}}", .{version}));
    var entries: std.ArrayList(Entry) = .empty;
    try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "lib/mojo/{s}.mojoc", .{name}), .bytes = mojoc });
    try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "lib/mojo/{s}.mopm.json", .{name}), .bytes = meta.items });
    for (natives) |n| {
        if (n.ship) try entries.append(a, .{ .name = try std.fmt.allocPrint(a, "lib/{s}", .{n.soname}), .bytes = n.bytes });
    }
    const tar = try tarOf(a, entries.items);
    return condaOf(a, try std.fmt.allocPrint(a, "mojo-{s}-{s}-{s}", .{ name, version, build }), tar);
}
