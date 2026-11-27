//! tests_act's `stand-in-archive`: a `.tar.gz` whose one top directory holds the
//! files a fixture names, written without a tar or gzip program (a ustar writer and
//! a gzip stream of stored blocks); and its `npm-repack`: an npm tarball written
//! again with files left out or added, or with scripts in its package.json.

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

/// Where a name longer than the 99 bytes of a ustar name field is cut: at
/// the first `/` whose directories fit the 155-byte prefix field and whose
/// rest fits the name field. Null when there is none.
pub fn ustarCut(name: []const u8) ?usize {
    for (name, 0..) |c, i| {
        if (c != '/' or i > 155) continue;
        const rest = name.len - i - 1;
        if (rest > 0 and rest <= 99) return i;
    }
    return null;
}

/// Appends a ustar entry; `kind` is '0' (file) or '5' (directory, `name` ends in /).
/// A name longer than 99 bytes has its leading directories in the prefix field.
pub fn tarEntry(alloc: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, kind: u8, mode: u32, data: []const u8) !void {
    var prefix: []const u8 = "";
    var base = name;
    if (name.len > 99) {
        const cut = ustarCut(name) orelse return error.NameTooLong;
        prefix = name[0..cut];
        base = name[cut + 1 ..];
    }
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..base.len], base);
    @memcpy(h[345 .. 345 + prefix.len], prefix);
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

// ---- npm-repack ----------------------------------------------------------------

/// A file `repackTar` adds, at `path` below the top directory.
pub const Add = struct { path: []const u8, data: []const u8 };

/// A script `repackTar` gives the package's package.json.
pub const Script = struct { name: []const u8, command: []const u8 };

/// What `repackTar` changes: the files it leaves out and the ones it adds (by
/// their path below the tarball's top directory, as npm reads them), and the
/// scripts it writes into package.json.
pub const Edits = struct {
    drops: []const []const u8 = &.{},
    adds: []const Add = &.{},
    scripts: []const Script = &.{},
};

fn jsonString(a: A, out: *std.ArrayList(u8), s: []const u8) !void {
    try out.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            0...0x1f => try out.writer(a).print("\\u{x:0>4}", .{c}),
            else => try out.append(a, c),
        }
    }
    try out.append(a, '"');
}

/// The package.json `text` with a `"scripts"` member holding `scripts`,
/// written first in its object. `error.HasScripts` when it has one already
/// (two would be a duplicate key), `error.NotAnObject` when it has no `{`.
pub fn withScripts(a: A, text: []const u8, scripts: []const Script) ![]u8 {
    if (std.mem.indexOf(u8, text, "\"scripts\"") != null) return error.HasScripts;
    const brace = std.mem.indexOfScalar(u8, text, '{') orelse return error.NotAnObject;
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, text[0 .. brace + 1]);
    try out.appendSlice(a, "\"scripts\":{");
    for (scripts, 0..) |sc, i| {
        if (i > 0) try out.append(a, ',');
        try jsonString(a, &out, sc.name);
        try out.append(a, ':');
        try jsonString(a, &out, sc.command);
    }
    try out.append(a, '}');
    const rest = text[brace + 1 ..];
    if (std.mem.trimLeft(u8, rest, " \t\r\n").len > 0 and std.mem.trimLeft(u8, rest, " \t\r\n")[0] != '}') try out.append(a, ',');
    try out.appendSlice(a, rest);
    return out.toOwnedSlice(a);
}

/// The tar of the npm tarball `gz` (gzip over tar) with `edits` made. Every
/// file is kept, in its order, with its bytes and mode (755 when an execute
/// bit was set, else 644) under the same top directory, but the dropped ones;
/// package.json gets the scripts; the added files follow. Directory entries
/// are left out (npm makes a file's directories), and a link is refused (an
/// npm tarball has none). Each dropped path must be a file of the tarball, an
/// added one must not be, and scripts need a package.json.
pub fn repackTar(a: A, gz: []const u8, edits: Edits) ![]u8 {
    var in: std.Io.Reader = .fixed(gz);
    var dec = std.compress.flate.Decompress.init(&in, .gzip, &.{});
    var raw = std.Io.Writer.Allocating.init(a);
    _ = dec.reader.streamRemaining(&raw.writer) catch |e| return if (e == error.ReadFailed) (dec.err orelse e) else e;
    var tin: std.Io.Reader = .fixed(raw.written());
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(&tin, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var out = std.ArrayList(u8).empty;
    var top: ?[]const u8 = null;
    const dropped = try a.alloc(bool, edits.drops.len);
    @memset(dropped, false);
    var manifest = false;
    var kept = std.StringHashMap(void).init(a);
    while (try it.next()) |f| {
        switch (f.kind) {
            .directory => continue,
            .sym_link => return error.LinkInTarball,
            .file => {},
        }
        const slash = std.mem.indexOfScalar(u8, f.name, '/') orelse return error.NoTopDirectory;
        if (top) |tp| {
            if (!std.mem.eql(u8, tp, f.name[0..slash])) return error.TwoTopDirectories;
        } else top = try a.dupe(u8, f.name[0..slash]);
        const rel = try a.dupe(u8, f.name[slash + 1 ..]);
        var data = std.Io.Writer.Allocating.init(a);
        try it.streamRemaining(f, &data.writer);
        var bytes: []const u8 = data.written();
        var drop = false;
        for (edits.drops, 0..) |d, i| {
            if (std.mem.eql(u8, d, rel)) {
                dropped[i] = true;
                drop = true;
            }
        }
        if (drop) continue;
        if (std.mem.eql(u8, rel, "package.json")) {
            manifest = true;
            if (edits.scripts.len > 0) bytes = try withScripts(a, bytes, edits.scripts);
        }
        try kept.put(rel, {});
        const full = try std.fmt.allocPrint(a, "{s}/{s}", .{ top.?, rel });
        try tarEntry(a, &out, full, '0', if (f.mode & 0o111 != 0) 0o755 else 0o644, bytes);
    }
    for (dropped) |hit| {
        if (!hit) return error.DropNotInTarball;
    }
    if (edits.scripts.len > 0 and !manifest) return error.NoManifest;
    const tp = top orelse return error.EmptyTarball;
    for (edits.adds) |ad| {
        if (kept.contains(ad.path)) return error.AddInTarball;
        try tarEntry(a, &out, try std.fmt.allocPrint(a, "{s}/{s}", .{ tp, ad.path }), '0', 0o644, ad.data);
    }
    try out.appendNTimes(a, 0, 1024);
    return out.toOwnedSlice(a);
}

/// npm-repack <in.tgz> <out.tgz> (--drop <path> | --add <path>=<file> | --script <name>=<command>)...
pub fn npmRepack(a: A, args: []const []const u8) !void {
    if (args.len < 2 or args.len % 2 != 0) return error.Usage;
    var drops = std.ArrayList([]const u8).empty;
    var adds = std.ArrayList(Add).empty;
    var scripts = std.ArrayList(Script).empty;
    var i: usize = 2;
    while (i < args.len) : (i += 2) {
        const flag = args[i];
        const v = args[i + 1];
        if (std.mem.eql(u8, flag, "--drop")) {
            try drops.append(a, v);
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse return error.Usage;
        if (std.mem.eql(u8, flag, "--add")) {
            try adds.append(a, .{ .path = v[0..eq], .data = try std.fs.cwd().readFileAlloc(a, v[eq + 1 ..], 1 << 30) });
        } else if (std.mem.eql(u8, flag, "--script")) {
            try scripts.append(a, .{ .name = v[0..eq], .command = v[eq + 1 ..] });
        } else return error.Usage;
    }
    const gz = try std.fs.cwd().readFileAlloc(a, args[0], 1 << 31);
    const tar = try repackTar(a, gz, .{ .drops = drops.items, .adds = adds.items, .scripts = scripts.items });
    const out = try gzipStored(a, tar);
    if (std.fs.path.dirname(args[1])) |d| try std.fs.cwd().makePath(d);
    const f = try std.fs.cwd().createFile(args[1], .{});
    defer f.close();
    try f.writeAll(out);
}
