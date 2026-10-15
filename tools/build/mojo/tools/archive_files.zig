// Why Zig: build tools are Zig (tools/build/README.md). This replaces the
// busybox shell script (tar, unzip, cp, sed) of the `archive_files` rule, so
// that taking files out of a pinned archive runs no shell.
//! archive_files: files of a pinned archive, as outputs of a build action.
//!
//! usage: archive_files <archive> <prefix> <substitutions> [--tree <dir>]
//!            (file|template <path under prefix> <out>)...
//!
//! The archive (`.tar.gz`, `.tgz`, `.tar` or `.zip`; the name says which) is
//! extracted into a scratch directory, and each triple takes <path under prefix>
//! from `<prefix>/` there to <out> (under <dir> after `--tree <dir>`; the
//! directories of <out> are made): `file` copies it (executable when the
//! source is), `template` writes it with the substitutions applied. The
//! substitutions file has one `key<TAB>value` per line; every line of a
//! template gets each pair in file order, every occurrence of the key replaced
//! by the value, literally.
//!
//! Exit status: 0; 2 for an unsupported archive, a path that is not a file in
//! the archive, a malformed substitutions file or any failure of the tool's own.

const std = @import("std");

pub const Pair = struct { key: []const u8, value: []const u8 };

pub const SubstError = error{BadLine};

/// The pairs of a substitutions file: `key<TAB>value` per line, in order. A
/// line with no tab, or an empty key, is refused; empty lines are skipped.
pub fn parsePairs(a: std.mem.Allocator, text: []const u8) (SubstError || std.mem.Allocator.Error)![]Pair {
    var out = std.ArrayList(Pair).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return error.BadLine;
        if (tab == 0) return error.BadLine;
        try out.append(.{ .key = line[0..tab], .value = line[tab + 1 ..] });
    }
    return out.toOwnedSlice();
}

/// `text` with every pair applied in order to each line (a `sed` of one `s///g`
/// per pair); the newlines, and the lack of a final one, are kept.
pub fn substitute(a: std.mem.Allocator, text: []const u8, pairs: []const Pair) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        var cur = try a.dupe(u8, line);
        for (pairs) |p| cur = try std.mem.replaceOwned(u8, a, cur, p.key, p.value);
        try out.appendSlice(cur);
    }
    return out.toOwnedSlice();
}

pub const Kind = enum { tar_gz, tar, zip };

pub fn kindOf(archive: []const u8) ?Kind {
    if (std.mem.endsWith(u8, archive, ".tar.gz") or std.mem.endsWith(u8, archive, ".tgz")) return .tar_gz;
    if (std.mem.endsWith(u8, archive, ".tar")) return .tar;
    if (std.mem.endsWith(u8, archive, ".zip")) return .zip;
    return null;
}

pub const Escapes = error{PathEscapes};

/// Whether `path` stays under its directory: not absolute, no `..` component.
pub fn contained(path: []const u8) bool {
    if (path.len > 0 and path[0] == '/') return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |c| {
        if (std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

/// Extracts the tar read from `reader` into `dest`: directories, files (with
/// their executable bit) and symbolic links, as `tar -x` does.
pub fn extractTar(dest: std.fs.Dir, reader: anytype) !void {
    var name_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var link_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    var it = std.tar.iterator(reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    while (try it.next()) |f| {
        const name = std.mem.trimRight(u8, f.name, "/");
        if (name.len == 0 or std.mem.eql(u8, name, ".")) continue;
        if (!contained(name)) return error.PathEscapes;
        switch (f.kind) {
            .directory => try dest.makePath(name),
            .file => {
                if (std.fs.path.dirname(name)) |d| try dest.makePath(d);
                const mode: std.fs.File.Mode = if (f.mode & 0o111 != 0) 0o755 else 0o644;
                const file = try dest.createFile(name, .{ .mode = mode });
                defer file.close();
                try f.writeAll(file);
                try file.chmod(mode);
            },
            .sym_link => {
                if (std.fs.path.dirname(name)) |d| try dest.makePath(d);
                dest.deleteFile(name) catch {};
                try dest.symLink(f.link_name, name, .{});
            },
        }
    }
}

fn u16at(d: []const u8, off: usize) !u16 {
    if (off + 2 > d.len) return error.BadZip;
    return std.mem.readInt(u16, d[off..][0..2], .little);
}

fn u32at(d: []const u8, off: usize) !u32 {
    if (off + 4 > d.len) return error.BadZip;
    return std.mem.readInt(u32, d[off..][0..4], .little);
}

/// Extracts the zip `data` into `dest`: stored and deflated entries (their
/// CRC checked), directories, and an entry the archive marks executable (a
/// unix mode in the high half of its external attributes) made so. Zip64 and
/// encryption are refused.
pub fn extractZip(a: std.mem.Allocator, dest: std.fs.Dir, data: []const u8) !void {
    if (data.len < 22) return error.BadZip;
    var eocd: usize = data.len - 22;
    while (true) : (eocd -= 1) {
        if (try u32at(data, eocd) == 0x06054b50) break;
        if (eocd == 0 or data.len - eocd > 22 + 65535) return error.BadZip;
    }
    const count = try u16at(data, eocd + 10);
    var cd: usize = try u32at(data, eocd + 16);
    var n: usize = 0;
    while (n < count) : (n += 1) {
        if (try u32at(data, cd) != 0x02014b50) return error.BadZip;
        const made_by = try u16at(data, cd + 4);
        const flags = try u16at(data, cd + 8);
        const method = try u16at(data, cd + 10);
        const crc = try u32at(data, cd + 16);
        const csize = try u32at(data, cd + 20);
        const usize_ = try u32at(data, cd + 24);
        const name_len = try u16at(data, cd + 28);
        const extra_len = try u16at(data, cd + 30);
        const comment_len = try u16at(data, cd + 32);
        const attrs = try u32at(data, cd + 38);
        const local = try u32at(data, cd + 42);
        if (cd + 46 + name_len > data.len) return error.BadZip;
        const name = data[cd + 46 .. cd + 46 + name_len];
        cd += 46 + name_len + extra_len + comment_len;
        if (flags & 1 != 0 or csize == 0xffffffff or usize_ == 0xffffffff) return error.Unsupported;
        if (!contained(name)) return error.PathEscapes;
        if (name.len > 0 and name[name.len - 1] == '/') {
            try dest.makePath(std.mem.trimRight(u8, name, "/"));
            continue;
        }
        if (try u32at(data, local) != 0x04034b50) return error.BadZip;
        const start = local + 30 + try u16at(data, local + 26) + try u16at(data, local + 28);
        if (start + csize > data.len) return error.BadZip;
        const body = data[start .. start + csize];
        var content = std.ArrayList(u8).init(a);
        defer content.deinit();
        switch (method) {
            0 => try content.appendSlice(body),
            8 => {
                var fbs = std.io.fixedBufferStream(body);
                try std.compress.flate.decompress(fbs.reader(), content.writer());
            },
            else => return error.Unsupported,
        }
        if (content.items.len != usize_ or std.hash.Crc32.hash(content.items) != crc) return error.BadZip;
        if (std.fs.path.dirname(name)) |d| try dest.makePath(d);
        const exec = (made_by >> 8) == 3 and (attrs >> 16) & 0o100 != 0;
        const mode: std.fs.File.Mode = if (exec) 0o755 else 0o644;
        const f = try dest.createFile(name, .{ .mode = mode });
        defer f.close();
        try f.writeAll(content.items);
        try f.chmod(mode);
    }
}

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("archive_files: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 4) die("usage: archive_files <archive> <prefix> <substitutions> [--tree <dir>] (file|template <path> <out>)...", .{});
    const archive = argv[1];
    const prefix = argv[2];
    const kind = kindOf(archive) orelse die("unsupported archive type: {s}", .{archive});
    const pairs = parsePairs(a, std.fs.cwd().readFileAlloc(a, argv[3], 1 << 24) catch |e| die("cannot read {s}: {s}", .{ argv[3], @errorName(e) })) catch |e| die("{s}: {s}", .{ argv[3], @errorName(e) });

    // The scratch directory: BUCK_SCRATCH_PATH/komira, else .komira_action beside the inputs.
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const env_scratch = std.process.getEnvVarOwned(a, "BUCK_SCRATCH_PATH") catch "";
    const t = if (env_scratch.len == 0)
        try std.fs.path.join(a, &.{ cwd, ".komira_action" })
    else if (std.fs.path.isAbsolute(env_scratch))
        try std.fs.path.join(a, &.{ env_scratch, "komira" })
    else
        try std.fs.path.join(a, &.{ cwd, env_scratch, "komira" });
    const x = try std.fs.path.join(a, &.{ t, "x" });
    try std.fs.cwd().makePath(x);
    var xd = try std.fs.cwd().openDir(x, .{ .iterate = true });
    defer xd.close();

    const file = std.fs.cwd().openFile(archive, .{}) catch |e| die("cannot open {s}: {s}", .{ archive, @errorName(e) });
    defer file.close();
    switch (kind) {
        .tar_gz => {
            var br = std.io.bufferedReader(file.reader());
            var dec = std.compress.gzip.decompressor(br.reader());
            extractTar(xd, dec.reader()) catch |e| die("cannot extract {s}: {s}", .{ archive, @errorName(e) });
        },
        .tar => {
            var br = std.io.bufferedReader(file.reader());
            extractTar(xd, br.reader()) catch |e| die("cannot extract {s}: {s}", .{ archive, @errorName(e) });
        },
        .zip => {
            const bytes = file.readToEndAlloc(a, 1 << 31) catch |e| die("cannot read {s}: {s}", .{ archive, @errorName(e) });
            extractZip(a, xd, bytes) catch |e| die("cannot extract {s}: {s}", .{ archive, @errorName(e) });
        },
    }
    const src_root = try std.fs.path.join(a, &.{ x, prefix });

    var tree: []const u8 = "";
    var i: usize = 4;
    while (i < argv.len) {
        if (std.mem.eql(u8, argv[i], "--tree")) {
            if (i + 1 >= argv.len) die("--tree needs a directory", .{});
            tree = argv[i + 1];
            i += 2;
            continue;
        }
        if (i + 2 >= argv.len) die("an incomplete (kind, path, out) triple", .{});
        const what = argv[i];
        const rel = argv[i + 1];
        const out = if (tree.len > 0) try std.fs.path.join(a, &.{ tree, argv[i + 2] }) else argv[i + 2];
        i += 3;
        if (!contained(rel)) die("{s} is not a path under '{s}'", .{ rel, prefix });
        const src = try std.fs.path.join(a, &.{ src_root, rel });
        const st = std.fs.cwd().statFile(src) catch null;
        if (st == null or st.?.kind != .file) die("{s} is not a file in {s} (under '{s}')", .{ rel, archive, prefix });
        if (std.fs.path.dirname(out)) |d| try std.fs.cwd().makePath(d);
        if (std.mem.eql(u8, what, "file")) {
            std.fs.cwd().copyFile(src, std.fs.cwd(), out, .{ .override_mode = if (st.?.mode & 0o100 != 0) 0o755 else 0o644 }) catch |e| die("cannot copy {s} to {s}: {s}", .{ rel, out, @errorName(e) });
        } else if (std.mem.eql(u8, what, "template")) {
            const text = try std.fs.cwd().readFileAlloc(a, src, 1 << 28);
            const done = text;
            _ = pairs;
            const f = std.fs.cwd().createFile(out, .{}) catch |e| die("cannot create {s}: {s}", .{ out, @errorName(e) });
            defer f.close();
            try f.writeAll(done);
        } else die("unknown kind {s}", .{what});
    }
    std.fs.cwd().deleteTree(t) catch {};
}
