//! Unpacking an npm tarball as npm does: the first path component is dropped
//! whatever it is, links are not extracted, files are 0644 (0755 when the
//! tarball marks them executable) and directories 0755.
const std = @import("std");

pub const Stats = struct { files: usize = 0, links: usize = 0 };

pub const Error = error{PathEscapes};

/// The path of `name` below its first component, built in `buf`: empty and
/// `.` components are dropped; a `..` component or a leading `/` is refused.
pub fn stripFirst(name: []const u8, buf: []u8) Error![]const u8 {
    if (name.len > 0 and name[0] == '/') return error.PathEscapes;
    var it = std.mem.tokenizeScalar(u8, name, '/');
    var first = true;
    var n: usize = 0;
    var seen_dotdot = false;
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, ".")) continue;
        if (std.mem.eql(u8, c, "..")) seen_dotdot = true;
        if (first) {
            first = false;
            continue;
        }
        if (n + c.len + 1 > buf.len) return error.PathEscapes;
        if (n > 0) {
            buf[n] = '/';
            n += 1;
        }
        @memcpy(buf[n .. n + c.len], c);
        n += c.len;
    }
    if (seen_dotdot) return error.PathEscapes;
    return buf[0..n];
}

pub fn modeOf(tar_mode: u32) std.fs.File.Mode {
    return if (tar_mode & 0o111 != 0) 0o755 else 0o644;
}

/// Extracts the tar read from `reader` into `dest`.
pub fn unpackTar(dest: std.fs.Dir, reader: anytype) !Stats {
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var rel_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var stats = Stats{};
    while (try it.next()) |f| {
        if (f.kind == .sym_link) {
            stats.links += 1;
            continue;
        }
        const rel = try stripFirst(f.name, &rel_buf);
        if (rel.len == 0) continue;
        switch (f.kind) {
            .directory => try dest.makePath(rel),
            .file => {
                if (std.fs.path.dirname(rel)) |d| try dest.makePath(d);
                const file = try dest.createFile(rel, .{ .mode = modeOf(f.mode) });
                defer file.close();
                try f.writeAll(file);
                try file.chmod(modeOf(f.mode));
                stats.files += 1;
            },
            .sym_link => unreachable,
        }
    }
    return stats;
}

/// Extracts the gzipped tar `bytes` into `dest`.
pub fn unpackTgz(dest: std.fs.Dir, bytes: []const u8) !Stats {
    var fbs = std.io.fixedBufferStream(bytes);
    var dec = std.compress.gzip.decompressor(fbs.reader());
    return unpackTar(dest, dec.reader());
}
