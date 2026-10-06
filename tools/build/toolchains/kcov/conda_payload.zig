//! conda_payload: write the payload tar of a `.conda` package.
//!
//! usage: conda_payload <package.conda> <out.tar>
//!
//! A `.conda` file is a zip (stored entries, zip64 size fields) holding
//! `pkg-*.tar.zst`, the payload, and `info-*.tar.zst`. The pinned busybox
//! reads neither zip64 nor zstd, so kcov_build.sh runs this and untars the
//! result with busybox. The zip walk is the one of
//! tools/build/mojo/tools/conda_unpack.zig, which this does not change: an
//! edit there would re-key every Mojo action.
//!
//! Exit status 2 on a usage error or a malformed package.

const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("conda_payload: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn le16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn le32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn le64(b: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, b[at..][0..8], .little);
}

/// Compressed size from a local header's zip64 extra field (id 0x0001).
fn zip64CompressedSize(extra: []const u8, usize_is_64: bool) ?u64 {
    var i: usize = 0;
    while (i + 4 <= extra.len) {
        const id = le16(extra, i);
        const len = le16(extra, i + 2);
        if (i + 4 + len > extra.len) return null;
        if (id == 0x0001) {
            var at = i + 4;
            if (usize_is_64) at += 8;
            if (at + 8 > i + 4 + len) return null;
            return le64(extra, at);
        }
        i += 4 + len;
    }
    return null;
}

/// The bytes of the `pkg-*.tar.zst` member.
fn payload(data: []const u8, path: []const u8) []const u8 {
    var off: usize = 0;
    while (off + 30 <= data.len and le32(data, off) == 0x04034b50) {
        const flags = le16(data, off + 6);
        const method = le16(data, off + 8);
        var csize: u64 = le32(data, off + 18);
        const usize32 = le32(data, off + 22);
        const nlen = le16(data, off + 26);
        const xlen = le16(data, off + 28);
        const start = off + 30 + nlen + xlen;
        if (start > data.len) fail("{s}: truncated zip local header at offset {d}", .{ path, off });
        const name = data[off + 30 .. off + 30 + nlen];
        const extra = data[off + 30 + nlen .. start];
        if (flags & 0x8 != 0) fail("{s}: zip data descriptors are not supported", .{name});
        if (method != 0) fail("{s}: zip compression method {d}; only stored (0) is supported", .{ name, method });
        if (csize == 0xffffffff) {
            csize = zip64CompressedSize(extra, usize32 == 0xffffffff) orelse
                fail("{s}: zip64 size field missing", .{name});
        }
        if (start + csize > data.len) fail("{s}: entry runs past end of file", .{name});
        const body = data[start .. start + @as(usize, @intCast(csize))];
        if (std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst")) return body;
        off = start + @as(usize, @intCast(csize));
    }
    fail("{s}: no pkg-*.tar.zst member", .{path});
}

pub fn main() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    if (args.len != 3) fail("usage: conda_payload <package.conda> <out.tar>", .{});
    const data = try std.fs.cwd().readFileAlloc(a, args[1], 1 << 31);
    var fbs = std.io.fixedBufferStream(payload(data, args[1]));
    // The decoder refuses a frame whose window does not fit; conda-forge
    // packages use far smaller windows.
    const window = try a.alloc(u8, 1 << 27);
    var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
    try writeAll(&dz, args[2]);
}

fn writeAll(dz: anytype, path: []const u8) !void {
    var out = try std.fs.cwd().createFile(path, .{});
    defer out.close();
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = try dz.reader().read(&buf);
        if (n == 0) break;
        try out.writeAll(buf[0..n]);
    }
}
