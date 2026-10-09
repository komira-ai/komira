// Why Zig: build tools are Zig (tools/build/README.md), and this one could
// not be Rust in any case. The Rust toolchain unpacks its own conda libraries
// with it (toolchains/rust/BUCK `rustc_libs`), so a Rust version would be a
// bootstrap cycle.
//! conda_unpack: extract the Mojo compiler closure out of a `.conda` package.
//!
//! usage: conda_unpack <package.conda> <out_dir> [--keep <member>]...
//!            [--lib <library.conda> <member>]...
//!        conda_unpack --only-libs <out_dir> (--lib <library.conda> <member>)...
//!
//! The second form writes only the `--lib` members (and CLOSURE_MANIFEST):
//! shared libraries from pinned packages for a tool that is not the Mojo
//! compiler.
//!
//! A `.conda` file is a zip holding `pkg-*.tar.zst` (the payload) and
//! `info-*.tar.zst` (metadata). This tool needs nothing from the host: it is a
//! static executable built from this file by the pinned zig, so the toolchain
//! can be unpacked on a worker that has no unzip, zstd or python.
//!
//! What it writes into <out_dir>:
//!   * the closure members only: `bin/mojo`, everything under `lib/`, and
//!     `share/max/modular.cfg`. (`bin/lld`, the crash handler and man pages
//!     are not needed to compile and are left out of every action's inputs,
//!     unless named with `--keep <member>`. Neither toolchain keeps one: a
//!     macOS compile links through the cc on PATH, measured on a macOS
//!     worker, not through modular.cfg's `lld_path`.) The compiler's
//!     runtime library is `lib/libKGENCompilerRTShared.so` or, in an
//!     osx-arm64 package, `.dylib`.
//!   * `share/max/modular.cfg` with the package's install-prefix placeholder
//!     replaced by `@@MOJO_TOOLCHAIN_ROOT@@`. The wrapper renders it at run
//!     time, so no absolute path enters an action key.
//!   * for each `--lib <library.conda> <member>`: that one member of another
//!     package (e.g. `lib/libstdc++.so.6` from a C++ runtime package), so the
//!     compiler's own dependencies come from pinned bytes rather than from
//!     the worker. A member that is a symbolic link in the package (a
//!     library's SONAME usually is) is written as a regular file holding the
//!     bytes of the file it resolves to; outputs contain no links. A member
//!     must live under `lib/`, must not collide with a compiler member, and
//!     must not carry an install-prefix placeholder.
//!   * `CLOSURE_MANIFEST`: the sorted list of members, one per line. The
//!     wrapper refuses to run (exit 2) if any member is missing or empty.
//!
//! Exit status 2 on any malformed or unexpected input.

const std = @import("std");

const token = "@@MOJO_TOOLCHAIN_ROOT@@";
const cfg_path = "share/max/modular.cfg";
const required = [_][]const u8{
    "bin/mojo",
    "lib/mojo/std.mojoc",
    cfg_path,
};
// One of these must be present: linux packages carry the `.so`, osx-arm64
// packages the `.dylib`.
const required_one_of = [_][]const u8{
    "lib/libKGENCompilerRTShared.so",
    "lib/libKGENCompilerRTShared.dylib",
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("conda_unpack: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn keep(name: []const u8, extra: []const []const u8) bool {
    if (std.mem.eql(u8, name, "bin/mojo")) return true;
    for (extra) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    if (std.mem.eql(u8, name, cfg_path)) return true;
    return std.mem.startsWith(u8, name, "lib/");
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

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Value of `"prefix_placeholder"` in paths.json for the entry whose `_path`
/// is `path`, or null if that entry has none. Fails if any OTHER kept member
/// carries a placeholder: only modular.cfg is rewritten.
fn findPlaceholder(json: []const u8, extra: []const []const u8) ?[]const u8 {
    const path_key = "\"_path\"";
    const ph_key = "\"prefix_placeholder\"";
    var found: ?[]const u8 = null;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, json, pos, path_key)) |p| {
        const next = std.mem.indexOfPos(u8, json, p + path_key.len, path_key) orelse json.len;
        const obj = json[p..next];
        const name = stringValue(obj, path_key) orelse fail("paths.json: unreadable _path", .{});
        if (stringValue(obj, ph_key)) |ph| {
            if (keep(name, extra)) {
                if (!std.mem.eql(u8, name, cfg_path)) {
                    fail("paths.json: closure member {s} carries an install-prefix placeholder; only {s} is rewritten", .{ name, cfg_path });
                }
                found = ph;
            }
        }
        pos = next;
    }
    return found;
}

fn stringValue(obj: []const u8, key: []const u8) ?[]const u8 {
    const k = std.mem.indexOf(u8, obj, key) orelse return null;
    const open = std.mem.indexOfScalarPos(u8, obj, k + key.len, '"') orelse return null;
    const close = std.mem.indexOfScalarPos(u8, obj, open + 1, '"') orelse return null;
    return obj[open + 1 .. close];
}

/// The `pkg-*.tar.zst` and `info-*.tar.zst` bodies of a `.conda` file.
const CondaParts = struct { pkg: []const u8, info: []const u8 };

fn condaParts(data: []const u8, path: []const u8) CondaParts {
    var pkg: ?[]const u8 = null;
    var info: ?[]const u8 = null;
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
        const body = data[start .. start + csize];
        off = start + @as(usize, @intCast(csize));
        if (std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst")) pkg = body;
        if (std.mem.startsWith(u8, name, "info-") and std.mem.endsWith(u8, name, ".tar.zst")) info = body;
    }
    return .{
        .pkg = pkg orelse fail("{s}: no pkg-*.tar.zst member", .{path}),
        .info = info orelse fail("{s}: no info-*.tar.zst member", .{path}),
    };
}

const LibEntry = struct { link: ?[]const u8, bytes: []const u8, mode: u32 };

/// Writes `member` of the library package at `path` into `out` as a regular
/// file, following symbolic links within the member's own directory.
fn extractLib(
    a: std.mem.Allocator,
    out: std.fs.Dir,
    path: []const u8,
    member: []const u8,
    window: []u8,
    name_buf: *[std.fs.MAX_PATH_BYTES]u8,
    link_buf: *[std.fs.MAX_PATH_BYTES]u8,
) !void {
    if (!std.mem.startsWith(u8, member, "lib/") or std.mem.indexOf(u8, member, "..") != null)
        fail("--lib member {s}: must be a path under lib/", .{member});
    const data = std.fs.cwd().readFileAlloc(a, path, 1 << 31) catch |e|
        fail("cannot read {s}: {s}", .{ path, @errorName(e) });
    const parts = condaParts(data, path);

    // Every entry under lib/: links are resolved after the whole payload is read.
    var entries = std.StringHashMap(LibEntry).init(a);
    {
        var fbs = std.io.fixedBufferStream(parts.pkg);
        var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
        var it = std.tar.iterator(dz.reader(), .{ .file_name_buffer = name_buf, .link_name_buffer = link_buf });
        while (try it.next()) |f| {
            if (!std.mem.startsWith(u8, f.name, "lib/")) continue;
            const name = try a.dupe(u8, f.name);
            switch (f.kind) {
                .file => try entries.put(name, .{ .link = null, .bytes = try f.reader().readAllAlloc(a, 1 << 30), .mode = f.mode }),
                .sym_link => try entries.put(name, .{ .link = try a.dupe(u8, f.link_name), .bytes = "", .mode = 0 }),
                else => {},
            }
        }
    }

    var name: []const u8 = member;
    var hops: usize = 0;
    var entry = entries.get(name) orelse fail("{s} has no member {s}", .{ path, member });
    while (entry.link) |target| {
        if (std.mem.indexOfScalar(u8, target, '/') != null)
            fail("{s}: link {s} -> {s} leaves its directory", .{ path, name, target });
        hops += 1;
        if (hops > 8) fail("{s}: too many links resolving {s}", .{ path, member });
        name = try std.fs.path.join(a, &.{ std.fs.path.dirname(name).?, target });
        entry = entries.get(name) orelse fail("{s}: link target {s} of {s} is not in the package", .{ path, name, member });
    }
    if (entry.bytes.len == 0) fail("{s}: {s} is empty", .{ path, name });

    // The bytes are copied verbatim, so neither name may carry a placeholder.
    var fbs = std.io.fixedBufferStream(parts.info);
    var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
    var it = std.tar.iterator(dz.reader(), .{ .file_name_buffer = name_buf, .link_name_buffer = link_buf });
    var saw_paths = false;
    while (try it.next()) |f| {
        if (f.kind != .file or !std.mem.eql(u8, f.name, "info/paths.json")) continue;
        saw_paths = true;
        const pj = try f.reader().readAllAlloc(a, 1 << 26);
        const path_key = "\"_path\"";
        var pos: usize = 0;
        while (std.mem.indexOfPos(u8, pj, pos, path_key)) |p| {
            const next = std.mem.indexOfPos(u8, pj, p + path_key.len, path_key) orelse pj.len;
            const obj = pj[p..next];
            const n = stringValue(obj, path_key) orelse fail("{s}: paths.json: unreadable _path", .{path});
            if ((std.mem.eql(u8, n, member) or std.mem.eql(u8, n, name)) and stringValue(obj, "\"prefix_placeholder\"") != null)
                fail("{s}: {s} carries an install-prefix placeholder", .{ path, n });
            pos = next;
        }
    }
    if (!saw_paths) fail("{s}: no info/paths.json", .{path});

    if (std.fs.path.dirname(member)) |d| try out.makePath(d);
    const mode: std.fs.File.Mode = if (entry.mode & 0o111 != 0) 0o755 else 0o644;
    const file = out.createFile(member, .{ .exclusive = true, .mode = mode }) catch |e|
        fail("cannot create {s} (a compiler member of the same name?): {s}", .{ member, @errorName(e) });
    defer file.close();
    try file.writeAll(entry.bytes);
}

fn writeManifest(a: std.mem.Allocator, out: std.fs.Dir, kept: [][]const u8) !void {
    std.mem.sort([]const u8, kept, {}, lessThan);
    var manifest = std.ArrayList(u8).init(a);
    for (kept) |k| {
        try manifest.appendSlice(k);
        try manifest.append('\n');
    }
    try out.writeFile("CLOSURE_MANIFEST", manifest.items);
}

/// `--only-libs <out_dir> (--lib <library.conda> <member>)...`
fn onlyLibs(a: std.mem.Allocator, args: []const [:0]u8) !void {
    const usage = "usage: conda_unpack --only-libs <out_dir> (--lib <library.conda> <member>)...";
    if (args.len < 6 or (args.len - 3) % 3 != 0) fail(usage, .{});
    var li: usize = 3;
    while (li < args.len) : (li += 3) {
        if (!std.mem.eql(u8, args[li], "--lib")) fail("expected --lib, got {s}", .{args[li]});
    }
    std.fs.cwd().makePath(args[2]) catch |e| fail("cannot create {s}: {s}", .{ args[2], @errorName(e) });
    var out = try std.fs.cwd().openDir(args[2], .{});
    defer out.close();
    const window = try a.alloc(u8, 1 << 27);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var kept = std.ArrayList([]const u8).init(a);
    li = 3;
    while (li < args.len) : (li += 3) {
        try extractLib(a, out, args[li + 1], args[li + 2], window, &name_buf, &link_buf);
        try kept.append(args[li + 2]);
    }
    try writeManifest(a, out, kept.items);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const args = try std.process.argsAlloc(a);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "--only-libs")) return onlyLibs(a, args);
    const usage = "usage: conda_unpack <package.conda> <out_dir> [--keep <member>]... [--lib <library.conda> <member>]...";
    if (args.len < 3) fail(usage, .{});
    // `--keep <member>`: one more package member to extract.
    // `--lib <library.conda> <member>`: one member of another package.
    var keep_members = std.ArrayList([]const u8).init(a);
    var libs = std.ArrayList([2][]const u8).init(a);
    var li: usize = 3;
    while (li < args.len) {
        if (std.mem.eql(u8, args[li], "--keep") and li + 1 < args.len) {
            if (std.mem.startsWith(u8, args[li + 1], "/") or std.mem.indexOf(u8, args[li + 1], "..") != null)
                fail("--keep {s}: expected a relative package member", .{args[li + 1]});
            try keep_members.append(args[li + 1]);
            li += 2;
        } else if (std.mem.eql(u8, args[li], "--lib") and li + 2 < args.len) {
            try libs.append(.{ args[li + 1], args[li + 2] });
            li += 3;
        } else fail(usage, .{});
    }
    const data = std.fs.cwd().readFileAlloc(a, args[1], 1 << 31) catch |e|
        fail("cannot read {s}: {s}", .{ args[1], @errorName(e) });
    std.fs.cwd().makePath(args[2]) catch |e| fail("cannot create {s}: {s}", .{ args[2], @errorName(e) });
    var out = try std.fs.cwd().openDir(args[2], .{});
    defer out.close();

    const window = try a.alloc(u8, 1 << 27);
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;

    var kept = std.ArrayList([]const u8).init(a);
    var paths_json: ?[]const u8 = null;
    var saw_pkg = false;

    var off: usize = 0;
    while (off + 30 <= data.len and le32(data, off) == 0x04034b50) {
        const flags = le16(data, off + 6);
        const method = le16(data, off + 8);
        var csize: u64 = le32(data, off + 18);
        const usize32 = le32(data, off + 22);
        const nlen = le16(data, off + 26);
        const xlen = le16(data, off + 28);
        const start = off + 30 + nlen + xlen;
        if (start > data.len) fail("truncated zip local header at offset {d}", .{off});
        const name = data[off + 30 .. off + 30 + nlen];
        const extra = data[off + 30 + nlen .. start];
        if (flags & 0x8 != 0) fail("{s}: zip data descriptors are not supported", .{name});
        if (method != 0) fail("{s}: zip compression method {d}; only stored (0) is supported", .{ name, method });
        if (csize == 0xffffffff) {
            csize = zip64CompressedSize(extra, usize32 == 0xffffffff) orelse
                fail("{s}: zip64 size field missing", .{name});
        }
        if (start + csize > data.len) fail("{s}: entry runs past end of file", .{name});
        const body = data[start .. start + csize];
        off = start + @as(usize, @intCast(csize));

        const is_pkg = std.mem.startsWith(u8, name, "pkg-") and std.mem.endsWith(u8, name, ".tar.zst");
        const is_info = std.mem.startsWith(u8, name, "info-") and std.mem.endsWith(u8, name, ".tar.zst");
        if (!is_pkg and !is_info) continue;

        var fbs = std.io.fixedBufferStream(body);
        var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
        var it = std.tar.iterator(dz.reader(), .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
        while (try it.next()) |f| {
            if (is_info) {
                if (f.kind == .file and std.mem.eql(u8, f.name, "info/paths.json")) {
                    paths_json = try f.reader().readAllAlloc(a, 1 << 26);
                }
                continue;
            }
            if (!keep(f.name, keep_members.items)) continue;
            if (f.kind != .file) fail("closure member {s} is not a regular file", .{f.name});
            if (std.fs.path.dirname(f.name)) |d| try out.makePath(d);
            const mode: std.fs.File.Mode = if (f.mode & 0o111 != 0) 0o755 else 0o644;
            const file = try out.createFile(f.name, .{ .exclusive = true, .mode = mode });
            defer file.close();
            var bw = std.io.bufferedWriter(file.writer());
            try f.writeAll(bw.writer());
            try bw.flush();
            try kept.append(try a.dupe(u8, f.name));
        }
        if (is_pkg) saw_pkg = true;
    }
    if (!saw_pkg) fail("{s}: no pkg-*.tar.zst member", .{args[1]});
    const pj = paths_json orelse fail("{s}: no info/paths.json", .{args[1]});

    for (required) |r| {
        var present = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k, r)) present = true;
        }
        if (!present) fail("package lacks required closure member {s}", .{r});
    }
    var runtime_found = false;
    for (required_one_of) |r| {
        for (kept.items) |k| {
            if (std.mem.eql(u8, k, r)) runtime_found = true;
        }
    }
    if (!runtime_found) fail("package lacks required closure member {s} (or {s})", .{ required_one_of[0], required_one_of[1] });
    for (keep_members.items) |e| {
        var present = false;
        for (kept.items) |k| {
            if (std.mem.eql(u8, k, e)) present = true;
        }
        if (!present) fail("--keep {s}: no such regular file in the package", .{e});
    }

    // Tokenize the install prefix in modular.cfg.
    const ph = findPlaceholder(pj, keep_members.items) orelse fail("paths.json names no prefix_placeholder for {s}", .{cfg_path});
    const cfg = try out.readFileAlloc(a, cfg_path, 1 << 24);
    const needle = try std.mem.concat(a, u8, &.{ ph, "/bin/mojo" });
    if (std.mem.indexOf(u8, cfg, needle) == null) fail("{s} does not name the placeholder as <prefix>/bin/mojo", .{cfg_path});
    const tokenized = try std.mem.replaceOwned(u8, a, cfg, ph, token);
    if (std.mem.indexOf(u8, tokenized, "= /") != null) fail("{s} still holds an absolute path after tokenizing", .{cfg_path});
    try out.writeFile(cfg_path, tokenized);

    for (libs.items) |l| {
        try extractLib(a, out, l[0], l[1], window, &name_buf, &link_buf);
        try kept.append(l[1]);
    }

    std.mem.sort([]const u8, kept.items, {}, lessThan);
    var manifest = std.ArrayList(u8).init(a);
    for (kept.items) |k| {
        try manifest.appendSlice(k);
        try manifest.append('\n');
    }
    try out.writeFile("CLOSURE_MANIFEST", manifest.items);
}
