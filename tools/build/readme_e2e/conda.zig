//! Reading a mopm package (`.conda`), the way a client that installs one does.
//!
//! A package is a zip of stored members holding `pkg-*.tar.zst`, the payload,
//! and `info-*.tar.zst`. mopm writes only these payload paths (spec/channel.md,
//! "Inside a package"):
//!
//!     lib/mojo/<name>.mojoc          the compiled Mojo package
//!     lib/mojo/<name>.mopm.json      its metadata
//!     lib/<soname>                   a native library, when the package ships one
//!
//! `read` returns those files and refuses anything else: a link, a path that
//! leaves `lib/`, a name twice, a member over 512 MiB. The zip walk and the
//! zstd and tar reading are those of the compiler closure's unpacker
//! (tools/build/mojo/tools/conda_unpack.zig), which insists on the compiler's
//! members and so cannot be used here.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The window a zstd frame of a package may use.
pub const window_len: u32 = 1 << 27;

/// The largest member taken, on the size its tar header declares.
pub const max_member: u64 = 512 << 20;

pub const Error = error{ Corrupt, OutOfMemory };

pub const File = struct { name: []const u8, bytes: []const u8 };

fn corrupt(a: Allocator, why: *[]const u8, comptime fmt: []const u8, args: anytype) Error {
    why.* = std.fmt.allocPrint(a, fmt, args) catch "corrupt package";
    return error.Corrupt;
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

/// The body of the one `pkg-*.tar.zst` member of the zip `data`.
fn payload(a: Allocator, data: []const u8, why: *[]const u8) Error![]const u8 {
    var pkg: ?[]const u8 = null;
    var off: usize = 0;
    while (off + 30 <= data.len and le32(data, off) == 0x04034b50) {
        const flags = le16(data, off + 6);
        const method = le16(data, off + 8);
        var csize: u64 = le32(data, off + 18);
        const usize32 = le32(data, off + 22);
        const nlen = le16(data, off + 26);
        const xlen = le16(data, off + 28);
        const start = off + 30 + nlen + xlen;
        if (start > data.len) return corrupt(a, why, "truncated zip local header at offset {d}", .{off});
        const name = data[off + 30 .. off + 30 + nlen];
        const extra = data[off + 30 + nlen .. start];
        if (flags & 0x8 != 0) return corrupt(a, why, "{s}: zip data descriptors are not supported", .{name});
        if (method != 0) return corrupt(a, why, "{s}: zip compression method {d}; only stored (0) is supported", .{ name, method });
        if (csize == 0xffffffff) {
            csize = zip64CompressedSize(extra, usize32 == 0xffffffff) orelse
                return corrupt(a, why, "{s}: zip64 size field missing", .{name});
        }
        if (start + csize > data.len) return corrupt(a, why, "{s}: entry runs past the end of the file", .{name});
        const body = data[start .. start + @as(usize, @intCast(csize))];
        off = start + @as(usize, @intCast(csize));
        if (std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst")) {
            if (pkg != null) return corrupt(a, why, "more than one pkg-*.tar.zst member", .{});
            pkg = body;
        }
    }
    if (pkg) |p| return p;
    return corrupt(a, why, "no pkg-*.tar.zst member", .{});
}

/// Whether `name` is a payload path mopm writes: `lib/mojo/<file>`, `lib/<file>`, or the source of a
/// program the package ships, `lib/mojo/<package>.bins/<program>.mojo` (`[targets] bins`; `<program>` is
/// lower case letters, digits and underscores, as the registry requires).
fn allowed(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "lib/")) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    const rest = name["lib/".len..];
    var depth: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or seg[0] == '.') return false;
        depth += 1;
    }
    if (depth == 2) return std.mem.startsWith(u8, rest, "mojo/");
    if (depth == 3) return isProgramSource(rest);
    return depth == 1;
}

/// Whether `rest` (a path below `lib/`, three segments) is `mojo/<package>.bins/<program>.mojo`.
fn isProgramSource(rest: []const u8) bool {
    var it = std.mem.splitScalar(u8, rest, '/');
    if (!std.mem.eql(u8, it.next().?, "mojo")) return false;
    const dir = it.next().?;
    const file = it.next().?;
    if (!std.mem.endsWith(u8, dir, ".bins")) return false;
    if (!std.mem.endsWith(u8, file, ".mojo")) return false;
    for (file[0 .. file.len - ".mojo".len]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// The files of the package `data` (the bytes of a `.conda`), in archive order.
/// On `error.Corrupt`, `why` says what is wrong with it.
pub fn read(a: Allocator, data: []const u8, why: *[]const u8) Error![]const File {
    const body = try payload(a, data, why);
    const window = try a.alloc(u8, window_len + std.compress.zstd.block_size_max);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var zin: std.Io.Reader = .fixed(body);
    var dz = std.compress.zstd.Decompress.init(&zin, window, .{ .window_len = window_len });
    var it = std.tar.Iterator.init(&dz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var out: std.ArrayList(File) = .empty;
    while (true) {
        const next = it.next() catch |e| return corrupt(a, why, "payload: {s}", .{@errorName(e)});
        const f = next orelse break;
        switch (f.kind) {
            .directory => continue,
            .file => {},
            else => return corrupt(a, why, "{s}: not a regular file (a package holds regular files only)", .{f.name}),
        }
        if (!allowed(f.name)) return corrupt(a, why, "{s}: not a path a mopm package holds (lib/mojo/<file>, lib/mojo/<package>.bins/<program>.mojo or lib/<file>)", .{f.name});
        for (out.items) |o| {
            if (std.mem.eql(u8, o.name, f.name)) return corrupt(a, why, "{s} appears twice", .{f.name});
        }
        if (f.size > max_member) return corrupt(a, why, "{s}: {d} bytes, over the {d} a member may hold", .{ f.name, f.size, max_member });
        const bytes = it.reader.readAlloc(a, @intCast(f.size)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return corrupt(a, why, "{s}: {s}", .{ f.name, @errorName(e) }),
        };
        it.unread_file_bytes = 0;
        try out.append(a, .{ .name = try a.dupe(u8, f.name), .bytes = bytes });
    }
    return out.items;
}

/// The bytes of the file `name` of `files`, or null.
pub fn find(files: []const File, name: []const u8) ?[]const u8 {
    for (files) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.bytes;
    }
    return null;
}

/// Writes `files` below `dir`, each at its own path, none over a file that is there.
pub fn extract(dir: std.fs.Dir, files: []const File) !void {
    for (files) |f| {
        if (std.fs.path.dirname(f.name)) |d| try dir.makePath(d);
        const h = try dir.createFile(f.name, .{ .exclusive = true });
        defer h.close();
        try h.writeAll(f.bytes);
    }
}
