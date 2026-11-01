//! Extracting a gzipped tar as `tar -xzf` does, for the node and python rules: modes from
//! the archive (executable if any execute bit is set, else 0644), the
//! modification time of each file from its header (so that what a program
//! writes about a source file, such as Python's `.pyc` files, is the same
//! bytes at every run), links kept as links, directories 0755. Only the entries below one top directory, and
//! of those only the ones a predicate keeps, are written, at their path below
//! the top directory.
const std = @import("std");

pub const Error = error{PathEscapes};

/// The path of `name` below the directory `top` (`./` and `//` and `.`
/// components dropped), built in `buf`; null when `name` is not below `top`
/// (including `top` itself, which has an empty remainder); a `..` component
/// is refused.
pub fn below(name: []const u8, top: []const u8, buf: []u8) Error!?[]const u8 {
    var it = std.mem.tokenizeScalar(u8, name, '/');
    var first = true;
    var inside = false;
    var n: usize = 0;
    var dotdot = false;
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) dotdot = true;
        if (first) {
            first = false;
            inside = std.mem.eql(u8, c, top);
            continue;
        }
        if (!inside) continue;
        if (n + c.len + 1 > buf.len) return error.PathEscapes;
        if (n > 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n .. n + c.len], c);
        n += c.len;
    }
    if (dotdot) return error.PathEscapes;
    if (!inside) return null;
    return buf[0..n];
}

pub fn modeOf(tar_mode: u32) std.fs.File.Mode {
    return if (tar_mode & 0o111 != 0) 0o755 else 0o644;
}

/// The modification time (seconds) a tar header block states: octal digits,
/// or GNU's base-256 form; null when it states none that can be read.
pub fn headerMtime(header: *const [512]u8) ?u64 {
    const field = header[136..148];
    if (field[0] & 0x80 != 0) {
        var v: u64 = field[0] & 0x7f;
        for (field[1..]) |b| v = (v << 8) | b;
        return v;
    }
    var v: u64 = 0;
    var any = false;
    for (field) |c| {
        if (c == ' ' or c == 0) {
            if (any) break;
            continue;
        }
        if (c < '0' or c > '7') return null;
        v = (v << 3) | (c - '0');
        any = true;
    }
    return if (any) v else null;
}

/// Extracts the entries of the tar read from `reader` that are below `top` and
/// that `keep` accepts (it is given the path below `top`) into `dest`. The tar
/// iterator has read exactly the header block of an entry when it returns it,
/// so `header_buffer` is that header (the standard library's File has no mtime).
pub fn extractTar(dest: std.fs.Dir, reader: *std.Io.Reader, top: []const u8, comptime keep: fn ([]const u8) bool) !void {
    var name_buf: [4096]u8 = undefined;
    var link_buf: [4096]u8 = undefined;
    var rel_buf: [4096]u8 = undefined;
    var it = std.tar.Iterator.init(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        const mtime = headerMtime(&it.header_buffer);
        const rest = (try below(f.name, top, &rel_buf)) orelse continue;
        if (rest.len == 0 or !keep(rest)) continue;
        switch (f.kind) {
            .directory => try dest.makePath(rest),
            .file => {
                if (std.fs.path.dirname(rest)) |d| try dest.makePath(d);
                const file = try dest.createFile(rest, .{ .mode = modeOf(f.mode) });
                defer file.close();
                var fbuf: [64 * 1024]u8 = undefined;
                var fw = file.writer(&fbuf);
                try it.streamRemaining(f, &fw.interface);
                try fw.interface.flush();
                try file.chmod(modeOf(f.mode));
                if (mtime) |m| {
                    const ns = @as(i128, m) * std.time.ns_per_s;
                    try file.updateTimes(ns, ns);
                }
            },
            .sym_link => {
                if (std.fs.path.dirname(rest)) |d| try dest.makePath(d);
                dest.deleteFile(rest) catch {};
                try dest.symLink(f.link_name, rest, .{});
            },
        }
    }
}

/// `extractTar` over the gzip stream `bytes`. The stream is inflated into memory
/// first, with no window buffer: the standard library's windowed decoder mishandles a
/// fixed-Huffman match that reaches the end of its window, and a stream read to its
/// end also has its gzip trailer (CRC and length) checked.
pub fn extractTgz(a: std.mem.Allocator, dest: std.fs.Dir, bytes: []const u8, top: []const u8, comptime keep: fn ([]const u8) bool) !void {
    var in: std.Io.Reader = .fixed(bytes);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var tar_bytes = std.Io.Writer.Allocating.init(a);
    defer tar_bytes.deinit();
    _ = dec.reader.streamRemaining(&tar_bytes.writer) catch |e| return if (e == error.ReadFailed) (dec.err orelse e) else e;
    var tar: std.Io.Reader = .fixed(tar_bytes.written());
    return extractTar(dest, &tar, top, keep);
}

pub fn keepAll(_: []const u8) bool {
    return true;
}
