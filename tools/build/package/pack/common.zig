//! komira_pack: what every command shares: the tar writer, gzip, hashing and
//! files, sorted JSON, and the command line.

const std = @import("std");
const json = std.json;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Alloc = std.mem.Allocator;

pub const epoch = "1970-01-01T00:00:00Z";
pub const oci_manifest_type = "application/vnd.oci.image.manifest.v1+json";
pub const oci_config_type = "application/vnd.oci.image.config.v1+json";
pub const oci_index_type = "application/vnd.oci.image.index.v1+json";
pub const oci_layer_type = "application/vnd.oci.image.layer.v1.tar+gzip";
const max_file = 8 * 1024 * 1024 * 1024 - 1;

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("komira_pack: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

// ---- tar ----------------------------------------------------------------

pub const Entry = struct {
    path: []const u8, // directories end with '/'
    mode: u32,
    data: []const u8, // empty for directories
};

pub fn lessEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn octal(field: []u8, value: u64) void {
    // Zero-padded octal filling all but the last byte, which is NUL.
    var v = value;
    var i: usize = field.len - 1;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    if (v != 0) fail("value {d} does not fit a {d}-byte tar field", .{ value, field.len });
    field[field.len - 1] = 0;
}

fn header(out: *std.ArrayList(u8), name: []const u8, typeflag: u8, mode: u32, size: u64) !void {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..name.len], name);
    octal(h[100..108], mode);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], size);
    octal(h[136..148], 0);
    h[156] = typeflag;
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    @memset(h[148..156], ' ');
    var sum: u32 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[155] = ' ';
    try out.appendSlice(&h);
}

fn pad(out: *std.ArrayList(u8), size: usize) !void {
    const rem = size % 512;
    if (rem != 0) try out.appendNTimes(0, 512 - rem);
}

pub fn writeTar(alloc: Alloc, entries: []Entry) ![]u8 {
    std.mem.sort(Entry, entries, {}, lessEntry);
    var out = std.ArrayList(u8).init(alloc);
    for (entries, 0..) |e, i| {
        if (i > 0 and std.mem.eql(u8, e.path, entries[i - 1].path)) fail("duplicate path {s}", .{e.path});
        const is_dir = e.path[e.path.len - 1] == '/';
        if (e.path.len > 100) {
            // A PAX extended header carries the full path.
            var rec_len: usize = " path=\n".len + e.path.len;
            var digits: usize = 1;
            while (true) {
                const n = std.fmt.count("{d}", .{rec_len + digits});
                if (n == digits) break;
                digits = @intCast(n);
            }
            rec_len += digits;
            const rec = try std.fmt.allocPrint(alloc, "{d} path={s}\n", .{ rec_len, e.path });
            try header(&out, "././@PaxHeader", 'x', 0o644, rec.len);
            try out.appendSlice(rec);
            try pad(&out, rec.len);
            try header(&out, e.path[0..100], if (is_dir) '5' else '0', e.mode, e.data.len);
        } else {
            try header(&out, e.path, if (is_dir) '5' else '0', e.mode, e.data.len);
        }
        try out.appendSlice(e.data);
        try pad(&out, e.data.len);
    }
    try out.appendNTimes(0, 1024);
    return out.toOwnedSlice();
}

/// Every directory named by `prefix` (e.g. "opt/hello/" -> "opt/", "opt/hello/"),
/// then the bundle's files and directories under it.
pub fn bundleEntries(alloc: Alloc, bundle: []const u8, prefix: []const u8) ![]Entry {
    if (prefix.len == 0 or prefix[prefix.len - 1] != '/' or prefix[0] == '/')
        fail("prefix `{s}` must be a relative path ending in /", .{prefix});
    var list = std.ArrayList(Entry).init(alloc);
    var at: usize = 0;
    while (std.mem.indexOfScalarPos(u8, prefix, at, '/')) |slash| {
        const part = prefix[at..slash];
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            fail("prefix `{s}` has an empty, . or .. part", .{prefix});
        try list.append(.{ .path = prefix[0 .. slash + 1], .mode = 0o755, .data = "" });
        at = slash + 1;
    }
    var dir = std.fs.cwd().openDir(bundle, .{ .iterate = true }) catch |err|
        fail("cannot open bundle {s}: {s}", .{ bundle, @errorName(err) });
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next()) |w| {
        switch (w.kind) {
            .directory => try list.append(.{
                .path = try std.fmt.allocPrint(alloc, "{s}{s}/", .{ prefix, w.path }),
                .mode = 0o755,
                .data = "",
            }),
            .file => {
                const st = try dir.statFile(w.path);
                if (st.size > max_file) fail("{s}: 8 GiB or larger", .{w.path});
                const data = try dir.readFileAlloc(alloc, w.path, max_file);
                try list.append(.{
                    .path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, w.path }),
                    .mode = if ((st.mode & 0o111) != 0) 0o755 else 0o644,
                    .data = data,
                });
                files += 1;
            },
            else => fail("{s}/{s}: not a regular file or directory ({s})", .{ bundle, w.path, @tagName(w.kind) }),
        }
    }
    if (files == 0) fail("bundle {s} holds no files", .{bundle});
    return list.toOwnedSlice();
}

pub fn gzip(alloc: Alloc, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    // ID1 ID2, CM=deflate, FLG=0, MTIME=0, XFL=0, OS=255.
    try out.appendSlice(&[_]u8{ 0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255 });
    var fbs = std.io.fixedBufferStream(data);
    try std.compress.flate.compress(fbs.reader(), out.writer(), .{});
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u32, trailer[0..4], std.hash.Crc32.hash(data), .little);
    std.mem.writeInt(u32, trailer[4..8], @truncate(data.len), .little);
    try out.appendSlice(&trailer);
    return out.toOwnedSlice();
}

// ---- hashing and files ---------------------------------------------------

pub fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

pub fn digestOf(alloc: Alloc, data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "sha256:{s}", .{sha256Hex(data)});
}

pub fn readAll(alloc: Alloc, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_file) catch |err|
        fail("cannot read {s}: {s}", .{ path, @errorName(err) });
}

pub fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

// ---- JSON ----------------------------------------------------------------

pub fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `v` as compact JSON with every object's keys in sorted order.
pub fn writeSorted(alloc: Alloc, v: json.Value, w: anytype) !void {
    switch (v) {
        .object => |obj| {
            const keys = try alloc.dupe([]const u8, obj.keys());
            std.mem.sort([]const u8, keys, {}, lessStr);
            try w.writeByte('{');
            for (keys, 0..) |k, i| {
                if (i > 0) try w.writeByte(',');
                try json.encodeJsonString(k, .{}, w);
                try w.writeByte(':');
                try writeSorted(alloc, obj.get(k).?, w);
            }
            try w.writeByte('}');
        },
        .array => |arr| {
            try w.writeByte('[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try w.writeByte(',');
                try writeSorted(alloc, item, w);
            }
            try w.writeByte(']');
        },
        else => try json.stringify(v, .{}, w),
    }
}

pub fn toJson(alloc: Alloc, v: json.Value) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try writeSorted(alloc, v, out.writer());
    return out.toOwnedSlice();
}

pub fn str(s: []const u8) json.Value {
    return .{ .string = s };
}

pub fn newObject(alloc: Alloc) json.Value {
    return .{ .object = json.ObjectMap.init(alloc) };
}

pub fn newArray(alloc: Alloc) json.Value {
    return .{ .array = json.Array.init(alloc) };
}

pub fn member(v: json.Value, key: []const u8, what: []const u8) json.Value {
    if (v != .object) fail("{s}: not a JSON object", .{what});
    return v.object.get(key) orelse fail("{s}: no `{s}`", .{ what, key });
}

pub fn memberStr(v: json.Value, key: []const u8, what: []const u8) []const u8 {
    const m = member(v, key, what);
    if (m != .string) fail("{s}: `{s}` is not a string", .{ what, key });
    return m.string;
}

pub fn memberInt(v: json.Value, key: []const u8, what: []const u8) i64 {
    const m = member(v, key, what);
    if (m != .integer) fail("{s}: `{s}` is not an integer", .{ what, key });
    return m.integer;
}

pub fn descriptor(alloc: Alloc, media_type: []const u8, data: []const u8) !json.Value {
    var d = newObject(alloc);
    try d.object.put("mediaType", str(media_type));
    try d.object.put("digest", str(try digestOf(alloc, data)));
    try d.object.put("size", .{ .integer = @intCast(data.len) });
    return d;
}

/// A repository name as docker spells it in full: a first component without
/// `.` or `:` (and not `localhost`) is on docker.io, and a single-component
/// name there is under `library/`.
pub fn normalizedRepo(alloc: Alloc, repo: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse
        return std.fmt.allocPrint(alloc, "docker.io/library/{s}", .{repo});
    const first = repo[0..slash];
    if (std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost")) return repo;
    return std.fmt.allocPrint(alloc, "docker.io/{s}", .{repo});
}

// ---- arguments -----------------------------------------------------------

pub const Args = struct {
    bundle: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    out: ?[]const u8 = null,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    repo: ?[]const u8 = null,
    manifest: ?[]const u8 = null,
    manifest_digest: ?[]const u8 = null,
    config: ?[]const u8 = null,
    archive: ?[]const u8 = null,
    digest: ?[]const u8 = null,
    layers: std.ArrayList([]const u8),
    // Every other `--flag value`, in order; a command names the ones it takes
    // (`allow`) and reads them with `one` and `all`.
    extra: std.ArrayList([2][]const u8),
};

pub fn need(v: ?[]const u8, flag: []const u8) []const u8 {
    return v orelse fail("missing {s}", .{flag});
}

pub fn plain(s: []const u8, what: []const u8, extra: []const u8) []const u8 {
    if (s.len == 0) fail("{s} is empty", .{what});
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '+') continue;
        if (std.mem.indexOfScalar(u8, extra, c) != null) continue;
        fail("{s} `{s}` holds `{c}`", .{ what, s, c });
    }
    return s;
}

pub fn parseArgs(alloc: Alloc, argv: []const [:0]u8) !Args {
    var a = Args{ .layers = std.ArrayList([]const u8).init(alloc), .extra = std.ArrayList([2][]const u8).init(alloc) };
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) fail("{s} needs a value", .{argv[i]});
        const k = argv[i];
        const v: []const u8 = argv[i + 1];
        if (std.mem.eql(u8, k, "--layer")) {
            try a.layers.append(v);
            continue;
        }
        const slot: *?[]const u8 = if (std.mem.eql(u8, k, "--bundle")) &a.bundle else if (std.mem.eql(u8, k, "--prefix")) &a.prefix else if (std.mem.eql(u8, k, "--out")) &a.out else if (std.mem.eql(u8, k, "--name")) &a.name else if (std.mem.eql(u8, k, "--version")) &a.version else if (std.mem.eql(u8, k, "--repo")) &a.repo else if (std.mem.eql(u8, k, "--manifest")) &a.manifest else if (std.mem.eql(u8, k, "--manifest-digest")) &a.manifest_digest else if (std.mem.eql(u8, k, "--config")) &a.config else if (std.mem.eql(u8, k, "--archive")) &a.archive else if (std.mem.eql(u8, k, "--digest")) &a.digest else {
            try a.extra.append(.{ k, v });
            continue;
        };
        if (slot.* != null) fail("{s} given twice", .{k});
        slot.* = v;
    }
    return a;
}

// ---- commands ------------------------------------------------------------

/// The flags of `a` outside the fixed fields must all be in `names`.
pub fn allow(a: Args, names: []const []const u8) void {
    for (a.extra.items) |kv| {
        var ok = false;
        for (names) |n| ok = ok or std.mem.eql(u8, n, kv[0]);
        if (!ok) fail("unknown argument {s}", .{kv[0]});
    }
}

/// The one value of `flag`, or null; given twice is an error.
pub fn one(a: Args, flag: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (a.extra.items) |kv| {
        if (!std.mem.eql(u8, kv[0], flag)) continue;
        if (found != null) fail("{s} given twice", .{flag});
        found = kv[1];
    }
    return found;
}

/// Every value of `flag`, in order.
pub fn all(alloc: Alloc, a: Args, flag: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    for (a.extra.items) |kv| if (std.mem.eql(u8, kv[0], flag)) try list.append(kv[1]);
    return list.toOwnedSlice();
}
