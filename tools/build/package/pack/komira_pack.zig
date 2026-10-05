//! komira_pack: the package formats made from a bundle, byte for byte
//! reproducible.
//!
//! usage:
//!   komira_pack tar --bundle <dir> --prefix <top>/ --out <file.tar.gz>
//!   komira_pack conda ...           (a `.conda` conda package; see below)
//!   komira_pack conda-meta ...      (the metapackage: pins the members whose manifests it is given, no file)
//!   komira_pack conda-check ...     (reads a package directory back and refuses what is wrong; both kinds)
//!   komira_pack oci --bundle <dir> --name <n> --version <v> --repo <r>
//!       --manifest <base manifest> --manifest-digest sha256:<hex>
//!       --config <base config>
//!       [--layer <base layer blob>]...
//!       --out <layout dir> --archive <file.tar> --digest <file>
//!
//! `tar` writes the bundle under <top>/ as a gzip-compressed ustar archive.
//! `oci` writes an OCI image layout: the base image's layers, then one layer
//! holding the bundle at /opt/<name>/, with the entrypoint
//! /opt/<name>/bin/<name>. `--archive` is the same layout as one tar plus a
//! Docker `manifest.json`, which `docker load` reads; `--digest` holds the
//! image manifest digest.
//!
//! `conda` writes one Mojo package as a conda v2 package (`.conda`) for linux-64:
//! a zip of three stored members (`metadata.json`, `pkg-*.tar.zst` holding
//! `lib/mojo/<name>.mojoc` and any `--doc-file` under `share/doc/<name>/`,
//! `info-*.tar.zst` holding `info/`). Every flag is
//! documented at cmdConda. Its zstd streams are made of raw blocks: valid zstd
//! with no compression, so no encoder version can change the bytes. A `.mojoc`
//! is compressed already, and the rest is a few hundred bytes.
//!
//! What makes the bytes reproducible:
//!   * entries sorted bytewise by path, directories written explicitly;
//!   * mtime 0, uid/gid 0, empty user and group names;
//!   * mode 0755 for directories and for files with any exec bit, else 0644;
//!   * gzip: header mtime 0, OS 255 (unknown), zig's deflate at its default
//!     level;
//!   * JSON: object keys in sorted order, no whitespace; every timestamp
//!     1970-01-01T00:00:00Z.
//! A symbolic link, a file of 8 GiB or more, or a special file is refused.
//!
//! The base image is only read from the files named on the command line
//! (downloaded and hash-checked by the build before this runs). The tool
//! refuses unless the base manifest names exactly those blobs, in order, with
//! matching digests and sizes; base layers are copied, never decompressed.
//!
//! This is a static executable: it runs with no shell, no PATH and no
//! network. Exit status 2 on any malformed or unexpected input.

const std = @import("std");
const json = std.json;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Alloc = std.mem.Allocator;

const epoch = "1970-01-01T00:00:00Z";
const oci_manifest_type = "application/vnd.oci.image.manifest.v1+json";
const oci_config_type = "application/vnd.oci.image.config.v1+json";
const oci_index_type = "application/vnd.oci.image.index.v1+json";
const oci_layer_type = "application/vnd.oci.image.layer.v1.tar+gzip";
const max_file = 8 * 1024 * 1024 * 1024 - 1;

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("komira_pack: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

// ---- tar ----------------------------------------------------------------

const Entry = struct {
    path: []const u8, // directories end with '/'
    mode: u32,
    data: []const u8, // empty for directories
};

fn lessEntry(_: void, a: Entry, b: Entry) bool {
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

fn writeTar(alloc: Alloc, entries: []Entry) ![]u8 {
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
fn bundleEntries(alloc: Alloc, bundle: []const u8, prefix: []const u8) ![]Entry {
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

fn gzip(alloc: Alloc, data: []const u8) ![]u8 {
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

fn sha256Hex(data: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(data, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

fn digestOf(alloc: Alloc, data: []const u8) ![]const u8 {
    return std.fmt.allocPrint(alloc, "sha256:{s}", .{sha256Hex(data)});
}

fn readAll(alloc: Alloc, path: []const u8) []u8 {
    return std.fs.cwd().readFileAlloc(alloc, path, max_file) catch |err|
        fail("cannot read {s}: {s}", .{ path, @errorName(err) });
}

fn writeFile(dir: std.fs.Dir, path: []const u8, data: []const u8) !void {
    var f = try dir.createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

// ---- JSON ----------------------------------------------------------------

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `v` as compact JSON with every object's keys in sorted order.
fn writeSorted(alloc: Alloc, v: json.Value, w: anytype) !void {
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

fn toJson(alloc: Alloc, v: json.Value) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try writeSorted(alloc, v, out.writer());
    return out.toOwnedSlice();
}

fn str(s: []const u8) json.Value {
    return .{ .string = s };
}

fn newObject(alloc: Alloc) json.Value {
    return .{ .object = json.ObjectMap.init(alloc) };
}

fn newArray(alloc: Alloc) json.Value {
    return .{ .array = json.Array.init(alloc) };
}

fn member(v: json.Value, key: []const u8, what: []const u8) json.Value {
    if (v != .object) fail("{s}: not a JSON object", .{what});
    return v.object.get(key) orelse fail("{s}: no `{s}`", .{ what, key });
}

fn memberStr(v: json.Value, key: []const u8, what: []const u8) []const u8 {
    const m = member(v, key, what);
    if (m != .string) fail("{s}: `{s}` is not a string", .{ what, key });
    return m.string;
}

fn memberInt(v: json.Value, key: []const u8, what: []const u8) i64 {
    const m = member(v, key, what);
    if (m != .integer) fail("{s}: `{s}` is not an integer", .{ what, key });
    return m.integer;
}

fn descriptor(alloc: Alloc, media_type: []const u8, data: []const u8) !json.Value {
    var d = newObject(alloc);
    try d.object.put("mediaType", str(media_type));
    try d.object.put("digest", str(try digestOf(alloc, data)));
    try d.object.put("size", .{ .integer = @intCast(data.len) });
    return d;
}

/// A repository name as docker spells it in full: a first component without
/// `.` or `:` (and not `localhost`) is on docker.io, and a single-component
/// name there is under `library/`.
fn normalizedRepo(alloc: Alloc, repo: []const u8) ![]const u8 {
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse
        return std.fmt.allocPrint(alloc, "docker.io/library/{s}", .{repo});
    const first = repo[0..slash];
    if (std.mem.indexOfAny(u8, first, ".:") != null or std.mem.eql(u8, first, "localhost")) return repo;
    return std.fmt.allocPrint(alloc, "docker.io/{s}", .{repo});
}

// ---- arguments -----------------------------------------------------------

const Args = struct {
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

fn need(v: ?[]const u8, flag: []const u8) []const u8 {
    return v orelse fail("missing {s}", .{flag});
}

fn plain(s: []const u8, what: []const u8, extra: []const u8) []const u8 {
    if (s.len == 0) fail("{s} is empty", .{what});
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '+') continue;
        if (std.mem.indexOfScalar(u8, extra, c) != null) continue;
        fail("{s} `{s}` holds `{c}`", .{ what, s, c });
    }
    return s;
}

fn parseArgs(alloc: Alloc, argv: []const [:0]u8) !Args {
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
fn allow(a: Args, names: []const []const u8) void {
    for (a.extra.items) |kv| {
        var ok = false;
        for (names) |n| ok = ok or std.mem.eql(u8, n, kv[0]);
        if (!ok) fail("unknown argument {s}", .{kv[0]});
    }
}

/// The one value of `flag`, or null; given twice is an error.
fn one(a: Args, flag: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (a.extra.items) |kv| {
        if (!std.mem.eql(u8, kv[0], flag)) continue;
        if (found != null) fail("{s} given twice", .{flag});
        found = kv[1];
    }
    return found;
}

/// Every value of `flag`, in order.
fn all(alloc: Alloc, a: Args, flag: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    for (a.extra.items) |kv| if (std.mem.eql(u8, kv[0], flag)) try list.append(kv[1]);
    return list.toOwnedSlice();
}

fn cmdTar(alloc: Alloc, a: Args) !void {
    allow(a, &.{});
    const entries = try bundleEntries(alloc, need(a.bundle, "--bundle"), need(a.prefix, "--prefix"));
    const tar = try writeTar(alloc, entries);
    try writeFile(std.fs.cwd(), need(a.out, "--out"), try gzip(alloc, tar));
}

fn cmdOci(alloc: Alloc, a: Args) !void {
    allow(a, &.{});
    const name = plain(need(a.name, "--name"), "name", "");
    const version = plain(need(a.version, "--version"), "version", "~");
    const repo = plain(need(a.repo, "--repo"), "repo", "/:");

    // The base: exactly the pinned blobs, in the manifest's order.
    const base_manifest_bytes = readAll(alloc, need(a.manifest, "--manifest"));
    const pinned = need(a.manifest_digest, "--manifest-digest");
    if (!std.mem.eql(u8, pinned, try digestOf(alloc, base_manifest_bytes)))
        fail("base manifest does not hash to its pin {s}", .{pinned});
    const base_manifest = try json.parseFromSliceLeaky(json.Value, alloc, base_manifest_bytes, .{});
    const mt = memberStr(base_manifest, "mediaType", "base manifest");
    if (!std.mem.eql(u8, mt, oci_manifest_type)) fail("base manifest: mediaType {s}, want {s}", .{ mt, oci_manifest_type });
    if (memberInt(base_manifest, "schemaVersion", "base manifest") != 2) fail("base manifest: schemaVersion is not 2", .{});
    const base_config_bytes = readAll(alloc, need(a.config, "--config"));
    const cdesc = member(base_manifest, "config", "base manifest");
    const want_config = memberStr(cdesc, "digest", "base manifest config");
    if (!std.mem.eql(u8, want_config, try digestOf(alloc, base_config_bytes)))
        fail("base config does not hash to {s}", .{want_config});
    if (memberInt(cdesc, "size", "base manifest config") != @as(i64, @intCast(base_config_bytes.len))) fail("base config: size differs", .{});
    const base_layers = member(base_manifest, "layers", "base manifest");
    if (base_layers != .array) fail("base manifest: `layers` is not an array", .{});
    if (base_layers.array.items.len != a.layers.items.len)
        fail("base manifest names {d} layers, {d} given", .{ base_layers.array.items.len, a.layers.items.len });
    const layer_bytes = try alloc.alloc([]u8, a.layers.items.len);
    for (a.layers.items, base_layers.array.items, 0..) |path, d, i| {
        layer_bytes[i] = readAll(alloc, path);
        const want = memberStr(d, "digest", "base layer");
        if (!std.mem.eql(u8, want, try digestOf(alloc, layer_bytes[i])))
            fail("base layer {d} ({s}) does not hash to {s}", .{ i, path, want });
        if (memberInt(d, "size", "base layer") != @as(i64, @intCast(layer_bytes[i].len))) fail("base layer {d}: size differs", .{i});
        if (!std.mem.eql(u8, memberStr(d, "mediaType", "base layer"), oci_layer_type)) fail("base layer {d}: not {s}", .{ i, oci_layer_type });
    }

    // Our layer: the bundle at /opt/<name>/.
    const prefix = try std.fmt.allocPrint(alloc, "opt/{s}/", .{name});
    const layer_tar = try writeTar(alloc, try bundleEntries(alloc, need(a.bundle, "--bundle"), prefix));
    const layer_gz = try gzip(alloc, layer_tar);

    // The config: the base's, with our layer, entrypoint and label.
    var config = try json.parseFromSliceLeaky(json.Value, alloc, base_config_bytes, .{});
    if (!std.mem.eql(u8, memberStr(config, "architecture", "base config"), "amd64") or
        !std.mem.eql(u8, memberStr(config, "os", "base config"), "linux"))
        fail("base config is not linux/amd64", .{});
    var rootfs = member(config, "rootfs", "base config");
    var diff_ids = member(rootfs, "diff_ids", "base config rootfs");
    if (diff_ids != .array or diff_ids.array.items.len != base_layers.array.items.len)
        fail("base config: {d} layers but a different number of diff_ids", .{base_layers.array.items.len});
    try diff_ids.array.append(str(try digestOf(alloc, layer_tar)));
    try rootfs.object.put("diff_ids", diff_ids);
    try config.object.put("rootfs", rootfs);

    var cc = config.object.get("config") orelse newObject(alloc);
    if (cc != .object) fail("base config: `config` is not an object", .{});
    var entrypoint = newArray(alloc);
    try entrypoint.array.append(str(try std.fmt.allocPrint(alloc, "/{s}bin/{s}", .{ prefix, name })));
    try cc.object.put("Entrypoint", entrypoint);
    _ = cc.object.orderedRemove("Cmd");
    var labels = cc.object.get("Labels") orelse newObject(alloc);
    if (labels != .object) fail("base config: `Labels` is not an object", .{});
    try labels.object.put("org.opencontainers.image.version", str(version));
    try cc.object.put("Labels", labels);
    try config.object.put("config", cc);

    var history = config.object.get("history") orelse newArray(alloc);
    if (history != .array) fail("base config: `history` is not an array", .{});
    var h = newObject(alloc);
    try h.object.put("created", str(epoch));
    try h.object.put("created_by", str(try std.fmt.allocPrint(alloc, "komira mojo_bundle {s} {s}", .{ name, version })));
    try history.array.append(h);
    try config.object.put("history", history);
    try config.object.put("created", str(epoch));
    const config_bytes = try toJson(alloc, config);

    // The manifest.
    var layers = newArray(alloc);
    for (base_layers.array.items) |d| try layers.array.append(d);
    try layers.array.append(try descriptor(alloc, oci_layer_type, layer_gz));
    var manifest = newObject(alloc);
    try manifest.object.put("schemaVersion", .{ .integer = 2 });
    try manifest.object.put("mediaType", str(oci_manifest_type));
    try manifest.object.put("config", try descriptor(alloc, oci_config_type, config_bytes));
    try manifest.object.put("layers", layers);
    const manifest_bytes = try toJson(alloc, manifest);
    const manifest_digest = try digestOf(alloc, manifest_bytes);

    // index.json: one manifest, tagged <version> and named with the full
    // reference in io.containerd.image.name, which is what `docker load`
    // (containerd image store) names the image by. containerd takes that name
    // verbatim, so it is written normalized as docker does
    // (`komira/hello` -> `docker.io/komira/hello`); a short name loads as an
    // image `docker run` cannot find.
    var mdesc = try descriptor(alloc, oci_manifest_type, manifest_bytes);
    var platform = newObject(alloc);
    try platform.object.put("architecture", str("amd64"));
    try platform.object.put("os", str("linux"));
    try mdesc.object.put("platform", platform);
    var ann = newObject(alloc);
    try ann.object.put("io.containerd.image.name", str(try std.fmt.allocPrint(alloc, "{s}:{s}", .{ try normalizedRepo(alloc, repo), version })));
    try ann.object.put("org.opencontainers.image.ref.name", str(version));
    try mdesc.object.put("annotations", ann);
    var manifests = newArray(alloc);
    try manifests.array.append(mdesc);
    var index = newObject(alloc);
    try index.object.put("schemaVersion", .{ .integer = 2 });
    try index.object.put("mediaType", str(oci_index_type));
    try index.object.put("manifests", manifests);
    const index_bytes = try toJson(alloc, index);

    // Docker's manifest.json, for `docker load`.
    var dm = newObject(alloc);
    try dm.object.put("Config", str(try std.fmt.allocPrint(alloc, "blobs/sha256/{s}", .{sha256Hex(config_bytes)})));
    var dlayers = newArray(alloc);
    for (layer_bytes) |b| try dlayers.array.append(str(try std.fmt.allocPrint(alloc, "blobs/sha256/{s}", .{sha256Hex(b)})));
    try dlayers.array.append(str(try std.fmt.allocPrint(alloc, "blobs/sha256/{s}", .{sha256Hex(layer_gz)})));
    try dm.object.put("Layers", dlayers);
    var tags = newArray(alloc);
    try tags.array.append(str(try std.fmt.allocPrint(alloc, "{s}:{s}", .{ repo, version })));
    try dm.object.put("RepoTags", tags);
    var docker_manifest = newArray(alloc);
    try docker_manifest.array.append(dm);
    const docker_manifest_bytes = try toJson(alloc, docker_manifest);

    // The layout directory and the archive hold the same files.
    var blobs = std.ArrayList([]const u8).init(alloc);
    for (layer_bytes) |b| try blobs.append(b);
    try blobs.append(layer_gz);
    try blobs.append(config_bytes);
    try blobs.append(manifest_bytes);
    const oci_layout = "{\"imageLayoutVersion\":\"1.0.0\"}";

    const out_path = need(a.out, "--out");
    try std.fs.cwd().makePath(out_path);
    var out = try std.fs.cwd().openDir(out_path, .{});
    defer out.close();
    try out.makePath("blobs/sha256");
    var entries = std.ArrayList(Entry).init(alloc);
    try entries.append(.{ .path = "blobs/", .mode = 0o755, .data = "" });
    try entries.append(.{ .path = "blobs/sha256/", .mode = 0o755, .data = "" });
    for (blobs.items) |b| {
        const p = try std.fmt.allocPrint(alloc, "blobs/sha256/{s}", .{sha256Hex(b)});
        var seen = false;
        for (entries.items) |e| seen = seen or std.mem.eql(u8, e.path, p);
        if (seen) continue; // the same blob twice (e.g. two identical base layers)
        try writeFile(out, p, b);
        try entries.append(.{ .path = p, .mode = 0o644, .data = b });
    }
    try writeFile(out, "oci-layout", oci_layout);
    try writeFile(out, "index.json", index_bytes);
    try entries.append(.{ .path = "oci-layout", .mode = 0o644, .data = oci_layout });
    try entries.append(.{ .path = "index.json", .mode = 0o644, .data = index_bytes });
    try entries.append(.{ .path = "manifest.json", .mode = 0o644, .data = docker_manifest_bytes });
    try writeFile(std.fs.cwd(), need(a.archive, "--archive"), try writeTar(alloc, entries.items));
    try writeFile(std.fs.cwd(), need(a.digest, "--digest"), try std.fmt.allocPrint(alloc, "{s}\n", .{manifest_digest}));
}

// ---- conda ---------------------------------------------------------------
//
// One Mojo package as a conda v2 package. The layout, and why each choice,
// is in packaging/conda/README.md.

const conda_subdir = "linux-64";
/// The kci platform of `conda_subdir` (kci_api's platform table, which
/// the manifest probe holds this to: kci refuses a manifest whose platform
/// and subdir disagree).
const conda_platform = "linux-x86_64";
const conda_metadata = "{\"conda_pkg_format_version\":2}";
const mojo_conda_name = "mojo-compiler";
const payload_dir = "lib/mojo/";
/// Where a package's documentation is installed: share/doc/<conda name>/.
const doc_dir = "share/doc/";
const license_member = "info/licenses/LICENSE";
const zstd_window_byte: u8 = 0x38; // exponent 7, mantissa 0: a 128 KiB window
const zstd_block_max: usize = 128 * 1024;

fn put16(out: *std.ArrayList(u8), v: u16) !void {
    var b: [2]u8 = undefined;
    std.mem.writeInt(u16, &b, v, .little);
    try out.appendSlice(&b);
}

fn put32(out: *std.ArrayList(u8), v: u32) !void {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, v, .little);
    try out.appendSlice(&b);
}

/// `data` as one zstd frame of raw blocks: no dictionary, no checksum, a
/// 128 KiB window, the content size stated. Valid zstd that no encoder
/// version can change.
fn zstdRaw(alloc: Alloc, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try out.appendSlice(&[_]u8{ 0x28, 0xB5, 0x2F, 0xFD, 0xC0, zstd_window_byte });
    var fcs: [8]u8 = undefined;
    std.mem.writeInt(u64, &fcs, data.len, .little);
    try out.appendSlice(&fcs);
    var at: usize = 0;
    while (true) {
        const n = @min(zstd_block_max, data.len - at);
        const last = at + n == data.len;
        const hdr: u32 = (@as(u32, @intCast(n)) << 3) | @intFromBool(last); // block type 0: Raw
        try out.appendSlice(&[_]u8{ @truncate(hdr), @truncate(hdr >> 8), @truncate(hdr >> 16) });
        try out.appendSlice(data[at .. at + n]);
        at += n;
        if (last) break;
    }
    return out.toOwnedSlice();
}

fn zstdDecode(alloc: Alloc, data: []const u8, what: []const u8) []u8 {
    const window = alloc.alloc(u8, 8 * 1024 * 1024) catch fail("out of memory", .{});
    var fbs = std.io.fixedBufferStream(data);
    var dz = std.compress.zstd.decompressor(fbs.reader(), .{ .window_buffer = window });
    return dz.reader().readAllAlloc(alloc, 1 << 31) catch |err|
        fail("{s}: not a valid zstd stream: {s}", .{ what, @errorName(err) });
}

const ZipMember = struct { name: []const u8, data: []const u8 };

const zip_date: u16 = 0x0021; // 1980-01-01, the earliest a zip can say

/// A zip of stored members in the given order: no extra fields, no comment,
/// no data descriptors, every date 1980-01-01 00:00:00, mode 0644.
fn zipStored(alloc: Alloc, members: []const ZipMember) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    const offsets = try alloc.alloc(u32, members.len);
    for (members, 0..) |m, i| {
        if (m.data.len >= 0xffff_0000 or out.items.len >= 0xffff_0000)
            fail("{s}: a conda member of 4 GiB or more needs zip64, which this tool does not write", .{m.name});
        offsets[i] = @intCast(out.items.len);
        try put32(&out, 0x04034b50);
        try put16(&out, 20);
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, zip_date);
        try put32(&out, std.hash.Crc32.hash(m.data));
        try put32(&out, @intCast(m.data.len));
        try put32(&out, @intCast(m.data.len));
        try put16(&out, @intCast(m.name.len));
        try put16(&out, 0);
        try out.appendSlice(m.name);
        try out.appendSlice(m.data);
    }
    const cd_at = out.items.len;
    for (members, 0..) |m, i| {
        try put32(&out, 0x02014b50);
        try put16(&out, 0x031e); // made by: unix, spec 3.0
        try put16(&out, 20);
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, zip_date);
        try put32(&out, std.hash.Crc32.hash(m.data));
        try put32(&out, @intCast(m.data.len));
        try put32(&out, @intCast(m.data.len));
        try put16(&out, @intCast(m.name.len));
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, 0);
        try put16(&out, 0);
        try put32(&out, 0o100644 << 16);
        try put32(&out, offsets[i]);
        try out.appendSlice(m.name);
    }
    const cd_len = out.items.len - cd_at;
    try put32(&out, 0x06054b50);
    try put16(&out, 0);
    try put16(&out, 0);
    try put16(&out, @intCast(members.len));
    try put16(&out, @intCast(members.len));
    try put32(&out, @intCast(cd_len));
    try put32(&out, @intCast(cd_at));
    try put16(&out, 0);
    return out.toOwnedSlice();
}

fn rd16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

fn rd32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

/// The members of a zip written by zipStored, read back through its central
/// directory and checked against each local header; anything else is refused.
fn readZip(alloc: Alloc, z: []const u8, what: []const u8) ![]ZipMember {
    if (z.len < 22 or rd32(z, z.len - 22) != 0x06054b50) fail("{s}: no end-of-central-directory record in its last 22 bytes (a comment, or not a zip)", .{what});
    const e = z.len - 22;
    const n = rd16(z, e + 10);
    if (rd16(z, e + 8) != n or rd16(z, e + 4) != 0 or rd16(z, e + 6) != 0) fail("{s}: a split or inconsistent zip", .{what});
    var at: usize = rd32(z, e + 16);
    var list = std.ArrayList(ZipMember).init(alloc);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (at + 46 > z.len or rd32(z, at) != 0x02014b50) fail("{s}: bad central directory entry {d}", .{ what, i });
        const method = rd16(z, at + 10);
        const flags = rd16(z, at + 8);
        const crc = rd32(z, at + 16);
        const csize = rd32(z, at + 20);
        const usize32 = rd32(z, at + 24);
        const nlen = rd16(z, at + 28);
        const xlen = rd16(z, at + 30);
        const clen = rd16(z, at + 32);
        const off = rd32(z, at + 42);
        if (at + 46 + nlen > z.len) fail("{s}: truncated central directory", .{what});
        const name = z[at + 46 ..][0..nlen];
        if (method != 0 or flags != 0) fail("{s}: member {s} is not stored without flags", .{ what, name });
        if (xlen != 0 or clen != 0) fail("{s}: member {s} has an extra field or comment", .{ what, name });
        if (csize != usize32) fail("{s}: member {s}: sizes differ", .{ what, name });
        if (@as(usize, off) + 30 + nlen + csize > z.len or rd32(z, off) != 0x04034b50) fail("{s}: member {s}: bad local header", .{ what, name });
        const lnlen = rd16(z, off + 26);
        if (lnlen != nlen or rd16(z, off + 28) != 0 or !std.mem.eql(u8, z[off + 30 ..][0..lnlen], name) or
            rd16(z, off + 6) != 0 or rd16(z, off + 8) != 0 or rd32(z, off + 14) != crc or rd32(z, off + 18) != csize or rd32(z, off + 22) != usize32)
            fail("{s}: member {s}: local header differs from the central directory", .{ what, name });
        const data = z[off + 30 + lnlen ..][0..csize];
        if (std.hash.Crc32.hash(data) != crc) fail("{s}: member {s}: bad CRC-32", .{ what, name });
        try list.append(.{ .name = name, .data = data });
        at += 46 + nlen;
    }
    if (at != e) fail("{s}: bytes between the central directory and its end record", .{what});
    return list.toOwnedSlice();
}

const TarFile = struct { name: []const u8, mode: u32, data: []const u8 };

fn octalVal(field: []const u8, what: []const u8) u64 {
    var v: u64 = 0;
    for (field) |c| {
        if (c == 0 or c == ' ') break;
        if (c < '0' or c > '7') fail("{s}: a tar header field is not octal", .{what});
        v = v * 8 + (c - '0');
    }
    return v;
}

fn allZero(b: []const u8) bool {
    for (b) |c| if (c != 0) return false;
    return true;
}

/// The regular files of a tar written by writeTar, refusing any header that
/// breaks the determinism rules (mtime, owner, names) or any other entry type.
fn readTar(alloc: Alloc, t: []const u8, what: []const u8) ![]TarFile {
    var list = std.ArrayList(TarFile).init(alloc);
    var at: usize = 0;
    while (true) {
        if (at + 512 > t.len) fail("{s}: truncated tar", .{what});
        const h = t[at .. at + 512];
        if (allZero(h)) break;
        const name = h[0 .. std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100];
        if (h[156] != '0') fail("{s}: {s}: entry type `{c}`; only regular files belong in a conda package", .{ what, name, h[156] });
        var sum: u64 = 0;
        for (h, 0..) |c, i| sum += if (i >= 148 and i < 156) ' ' else c;
        if (sum != octalVal(h[148..156], what)) fail("{s}: {s}: bad tar header checksum", .{ what, name });
        if (octalVal(h[136..148], what) != 0 or octalVal(h[108..116], what) != 0 or octalVal(h[116..124], what) != 0 or
            !allZero(h[265..329]))
            fail("{s}: {s}: mtime, uid, gid, user and group must all be zero/empty", .{ what, name });
        const size: usize = @intCast(octalVal(h[124..136], what));
        const mode: u32 = @intCast(octalVal(h[100..108], what));
        at += 512;
        if (at + size > t.len) fail("{s}: {s}: truncated tar member", .{ what, name });
        try list.append(.{ .name = name, .mode = mode, .data = t[at .. at + size] });
        at += (size + 511) / 512 * 512;
    }
    if (!allZero(t[at..])) fail("{s}: bytes after the end of the tar", .{what});
    return list.toOwnedSlice();
}

fn findTar(files: []const TarFile, name: []const u8) ?TarFile {
    for (files) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}


// ---- names, versions, requirements ---------------------------------------

/// A conda name this repository writes: a lowercase letter, then lowercase
/// letters, digits and `_`. Compared exactly, never folded (`komira_json` and
/// `komira-json` are two names in a channel). Which names are PUBLISHED is not
/// decided here: the artifact declarations of the release tool say so.
fn validName(n: []const u8) bool {
    if (n.len == 0 or !std.ascii.isLower(n[0])) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// A Mojo import name: what the `.mojoc` is called.
fn validImport(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0])) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// A full git commit id: 40 lowercase hex digits.
fn fullCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn decimal(s: []const u8) bool {
    if (s.len == 0 or s.len > 9 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The version of every package: the Mojo compiler version they are built
/// with, pinned by the platform table, so a conda version: it starts with a digit and holds
/// letters, digits, `.`, `_` and `+` only (a `-` would make the file name
/// ambiguous).
fn compilerVersion(v: []const u8) []const u8 {
    if (v.len == 0 or !std.ascii.isDigit(v[0])) fail("compiler version `{s}` does not start with a digit", .{v});
    for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+')) fail("compiler version `{s}` holds `{c}`", .{ v, c });
    return v;
}

/// The build string of a release: `h<first 8 hex of the source commit>_<N>`,
/// N the build number. An unstamped build (N is 0, no commit) is
/// `h00000000_0`. Two builds of one name and version differ in N, and in the
/// commit they came from, so the string names both.
fn buildString(alloc: Alloc, commit: []const u8, number: i64) ![]const u8 {
    const head: []const u8 = if (commit.len >= 8) commit[0..8] else "00000000";
    return std.fmt.allocPrint(alloc, "h{s}_{d}", .{ head, number });
}

fn guardFor(subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, conda_subdir)) return "__linux";
    fail("subdir `{s}`: this tool writes {s} only (an arm64 or macOS package needs its own payload and guard)", .{ subdir, conda_subdir });
}

/// The run requirements of a library, in the order they are written and
/// checked: the platform guard, the exact Mojo pin, then each direct
/// dependency at this version AND this build string (`name ==V BUILD`), sorted.
/// Every package of a release is lockstep, so a dependency's build string is
/// this package's. Direct dependencies only: the solver's closure is the
/// build's.
fn runRequirements(alloc: Alloc, subdir: []const u8, pin: []const u8, version: []const u8, build: []const u8, deps: []const []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    try list.append(try std.fmt.allocPrint(alloc, "{s} =={s}", .{ mojo_conda_name, pin }));
    const sorted = try alloc.dupe([]const u8, deps);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    for (sorted) |d| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s} {s}", .{ d, version, build }));
    return list.toOwnedSlice();
}

/// The run requirements of the metapackage: the platform guard, then every
/// member at exactly its version and build string, sorted by name. No compiler
/// pin: the members carry it.
fn metaRequirements(alloc: Alloc, subdir: []const u8, members: []const Member) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    for (members) |m| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s} {s}", .{ m.name, m.version, m.build }));
    return list.toOwnedSlice();
}

fn strArray(alloc: Alloc, items: []const []const u8) !json.Value {
    var arr = newArray(alloc);
    for (items) |s| try arr.array.append(str(s));
    return arr;
}

fn jsonLine(alloc: Alloc, v: json.Value) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try writeSorted(alloc, v, out.writer());
    try out.append('\n');
    return out.toOwnedSlice();
}

/// Null if no source under `dir_path` opens a shared library by name at run
/// time; otherwise why this tool cannot package the library. Such a package
/// needs the conda package that ships the shared library in its run
/// requirements, and this tool does not derive that yet, so it says so instead
/// of publishing a package that fails on a clean machine.
fn dlopenReason(alloc: Alloc, dir_path: []const u8) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err|
        fail("cannot open sources {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next()) |w| {
        if (w.kind != .file or !std.mem.endsWith(u8, w.path, ".mojo")) continue;
        files += 1;
        const text = try dir.readFileAlloc(alloc, w.path, 1 << 28);
        if (std.mem.indexOf(u8, text, "OwnedDLHandle") != null)
            return try std.fmt.allocPrint(alloc, "{s}: opens a shared library at run time (OwnedDLHandle); its conda package must depend on the package shipping that library, which this tool does not derive yet", .{w.path});
    }
    if (files == 0) fail("sources {s} hold no .mojo file", .{dir_path});
    return null;
}

/// The source commit of a stamp (--commit): empty only for an unstamped build.
fn commitOf(a: Args, stamp: []const u8) []const u8 {
    const commit = one(a, "--commit") orelse "";
    if (commit.len != 0 and !fullCommit(commit)) fail("--commit `{s}` is not a full lowercase 40-digit hex commit id", .{commit});
    if (!std.mem.eql(u8, stamp, "0") and commit.len == 0) fail("a stamped package (N={s}) must carry --commit, the commit its stamp was derived from", .{stamp});
    return commit;
}

/// A documentation file of a library package (`--doc-file <rel>=<file>`): its
/// path in the package, share/doc/<name>/<rel>, and its bytes.
const DocFile = struct { path: []const u8, data: []const u8 };

fn lessDoc(_: void, x: DocFile, y: DocFile) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// The `--doc-file` values, placed under share/doc/<name>/ and sorted by path.
/// <rel> is relative, made of `/`-separated components that are neither empty
/// nor `.` nor `..`, in letters, digits and `_.-`; the whole path fits a plain
/// tar name (100 bytes), since conda-check reads no extended header. The same
/// path twice is refused. The bytes are read here; each is installed mode 0644.
fn docFiles(alloc: Alloc, a: Args, name: []const u8) ![]DocFile {
    var list = std.ArrayList(DocFile).init(alloc);
    for (try all(alloc, a, "--doc-file")) |df| {
        const eq = std.mem.indexOfScalar(u8, df, '=') orelse fail("--doc-file `{s}` is not <relative path>=<file>", .{df});
        const rel = df[0..eq];
        if (rel.len == 0) fail("--doc-file `{s}` names no path", .{df});
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |c| {
            if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, ".."))
                fail("--doc-file path `{s}` must be relative, with no empty, `.` or `..` component", .{rel});
        }
        for (rel) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '/'))
                fail("--doc-file path `{s}` holds `{c}`", .{ rel, c });
        }
        const path = try std.fmt.allocPrint(alloc, "{s}{s}/{s}", .{ doc_dir, name, rel });
        if (path.len > 100) fail("--doc-file path `{s}` is {d} bytes; it must fit 100", .{ path, path.len });
        for (list.items) |d| if (std.mem.eql(u8, d.path, path)) fail("--doc-file {s} given twice", .{rel});
        try list.append(.{ .path = path, .data = readAll(alloc, df[eq + 1 ..]) });
    }
    const docs = try list.toOwnedSlice();
    std.mem.sort(DocFile, docs, {}, lessDoc);
    return docs;
}

/// The `paths.json` row of one installed file.
fn pathRow(alloc: Alloc, path: []const u8, data: []const u8) !json.Value {
    var row = newObject(alloc);
    try row.object.put("_path", str(path));
    try row.object.put("path_type", str("hardlink"));
    try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(data))));
    try row.object.put("size_in_bytes", .{ .integer = @intCast(data.len) });
    return row;
}

/// The info/ entries every package carries besides index.json and paths.json:
/// about.json, and the licence given as `--extra-file info/licenses/LICENSE=F`.
fn aboutAndLicense(alloc: Alloc, a: Args, info_entries: *std.ArrayList(Entry)) !void {
    const summary = need(one(a, "--summary"), "--summary");
    var about = newObject(alloc);
    try about.object.put("description", str(summary));
    try about.object.put("home", str(need(one(a, "--home"), "--home")));
    try about.object.put("license", str(need(one(a, "--license"), "--license")));
    try about.object.put("summary", str(summary));
    try info_entries.append(.{ .path = "info/about.json", .mode = 0o644, .data = try jsonLine(alloc, about) });
    var have_license = false;
    for (try all(alloc, a, "--extra-file")) |ef| {
        const eq = std.mem.indexOfScalar(u8, ef, '=') orelse fail("--extra-file `{s}` is not info/<path>=<file>", .{ef});
        const dest = ef[0..eq];
        if (!std.mem.startsWith(u8, dest, "info/licenses/") or std.mem.indexOf(u8, dest, "..") != null or dest.len > 100)
            fail("--extra-file destination `{s}` must be a short path under info/licenses/", .{dest});
        have_license = have_license or std.mem.eql(u8, dest, license_member);
        try info_entries.append(.{ .path = dest, .mode = 0o644, .data = readAll(alloc, ef[eq + 1 ..]) });
    }
    if (!have_license) fail("no {s}: Apache-2.0 requires the licence text to accompany a redistributed package", .{license_member});
}

/// The `.conda` zip of a package: metadata.json, then the pkg and info tars.
fn assembleConda(alloc: Alloc, stem: []const u8, pkg_entries: []Entry, info_entries: []Entry) ![]u8 {
    const pkg_tar = try writeTar(alloc, pkg_entries);
    const info_tar = try writeTar(alloc, info_entries);
    const members = [_]ZipMember{
        .{ .name = "metadata.json", .data = conda_metadata },
        .{ .name = try std.fmt.allocPrint(alloc, "pkg-{s}.tar.zst", .{stem}), .data = try zstdRaw(alloc, pkg_tar) },
        .{ .name = try std.fmt.allocPrint(alloc, "info-{s}.tar.zst", .{stem}), .data = try zstdRaw(alloc, info_tar) },
    };
    return zipStored(alloc, &members);
}

// ---- the output directory and the manifest contract ----------------------
//
// Every package is written as one DIRECTORY (--out-dir):
//
//   <name>-<version>-<build>.conda   the package; this is the name the channel
//                              carries. <version> is the Mojo compiler version,
//                              <build> is `h<8 hex of the source commit>_<N>`
//   manifest.json              the artifact manifest, exactly the contract of
//                              kci's `kci_artifact_manifest`: ten keys,
//                              compact, in this order, one trailing newline:
//                                format (`kci.artifact_manifest`),
//                                schema_version (the integer 1), artifact_type
//                                (`CONDA`), name, version, platform (the kci
//                                platform of the subdir: `linux-x86_64`),
//                                subdir, file (the package's name above,
//                                relative to the manifest), sha256 (of that
//                                file), metadata (`metadata.json`, the file
//                                below)
//   metadata.json              everything else the build knows (sorted compact
//                              JSON): format (`kci.conda_metadata`),
//                              schema_version (1), kind, build, build_number,
//                              size, depends, mojo_pin, source_commit, stamped,
//                              timestamp_ms, label, payload_path,
//                              payload_sha256, ...
//
// The format names and majors are kci's (kci_api's format table). Nothing
// run-specific (a run id, an attempt) is written here: these files are action
// outputs, and a per-run value would make every run a cache miss.
//
// The manifest names metadata.json as a bare file name: kci's parser requires
// `metadata` on a CONDA artifact and refuses one that is not a file next to
// the manifest, so copying the directory cannot separate the two. The probe
// //tools/build/package/manifest_probe:conda_manifest_kci runs kci's parser
// over a package this tool wrote, so the two cannot drift apart.
//
// A library the tool cannot package (native code, no tests, a dependency with
// no package, a run-time shared library) is written as a directory holding one
// file, REFUSED, whose text is the reason. That is a value, not an error, so a
// build of every target in the repository still succeeds; asking for the
// package's release is what fails (`conda-check --require-stamped`).

fn openOut(a: Args) std.fs.Dir {
    const p = need(one(a, "--out-dir"), "--out-dir");
    std.fs.cwd().makePath(p) catch |err| fail("cannot create {s}: {s}", .{ p, @errorName(err) });
    return std.fs.cwd().openDir(p, .{}) catch |err| fail("cannot open {s}: {s}", .{ p, @errorName(err) });
}

fn writeRefusal(alloc: Alloc, a: Args, why: []const u8) !void {
    if (why.len == 0) fail("a refusal needs its reason", .{});
    var d = openOut(a);
    defer d.close();
    try writeFile(d, "REFUSED", try std.fmt.allocPrint(alloc, "{s}\n", .{why}));
}

/// The contract manifest, byte for byte what kci's `render_artifact_manifest`
/// writes for a CONDA artifact (its key order: `metadata` last).
/// The metadata file a CONDA manifest names: next to it, under this name.
const conda_manifest_metadata = "metadata.json";

/// The kci platform of a conda subdir this tool writes (only `conda_subdir`).
fn platformFor(subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, conda_subdir)) return conda_platform;
    fail("subdir `{s}`: this tool writes {s} only, whose kci platform is {s}", .{ subdir, conda_subdir, conda_platform });
}

fn contractManifest(alloc: Alloc, name: []const u8, version: []const u8, subdir: []const u8, file: []const u8, sha: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    const w = out.writer();
    try w.writeAll("{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"CONDA\"");
    const vals = [_][2][]const u8{ .{ "name", name }, .{ "version", version }, .{ "platform", platformFor(subdir) }, .{ "subdir", subdir }, .{ "file", file }, .{ "sha256", sha }, .{ "metadata", conda_manifest_metadata } };
    for (vals) |kv| {
        try w.writeAll(",\"");
        try w.writeAll(kv[0]);
        try w.writeAll("\":");
        try json.encodeJsonString(kv[1], .{}, w);
    }
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

fn emitPackage(alloc: Alloc, a: Args, stem: []const u8, conda: []const u8, name: []const u8, version: []const u8, build: []const u8, number: i64, subdir: []const u8, metadata: *json.Value) !void {
    const conda_sha = sha256Hex(conda);
    const file = try std.fmt.allocPrint(alloc, "{s}.conda", .{stem});
    try metadata.object.put("build", str(build));
    try metadata.object.put("build_number", .{ .integer = number });
    try metadata.object.put("file_name", str(file));
    try metadata.object.put("name", str(name));
    try metadata.object.put("format", str("kci.conda_metadata"));
    try metadata.object.put("schema_version", .{ .integer = 1 });
    try metadata.object.put("size", .{ .integer = @intCast(conda.len) });
    try metadata.object.put("subdir", str(subdir));
    try metadata.object.put("version", str(version));
    var d = openOut(a);
    defer d.close();
    try writeFile(d, file, conda);
    try writeFile(d, "manifest.json", try contractManifest(alloc, name, version, subdir, file, &conda_sha));
    try writeFile(d, conda_manifest_metadata, try jsonLine(alloc, metadata.*));
}

/// komira_pack conda --name N --import-name I --stamp N
///     --timestamp-ms T [--commit SHA] --subdir linux-64 --mojo-pin V
///     --license SPDX --summary S --home URL --payload F.mojoc [--dep NAME]...
///     --sources DIR --extra-file info/licenses/LICENSE=FILE --label L
///     [--doc-file REL=FILE]... --out-dir D
/// komira_pack conda --name N --refuse REASON --out-dir D
///
/// The version is --mojo-pin V, the Mojo compiler version the library was built
/// with, and the run requirement `mojo-compiler ==V` pins the same value. The
/// release iteration is the build number --stamp N (0 is an unstamped build),
/// and the build string is `h<8 hex of --commit>_<N>`. N (the option) is the
/// CONDA name, I the import name (the `.mojoc`'s name); each --dep is the
/// conda name of a direct dependency. With --refuse, the package is not made
/// and D holds REFUSED instead.
///
/// Each --doc-file is installed at share/doc/N/REL (docFiles): a file in the
/// pkg tar, one paths.json row, and one `doc_files` row ({path, sha256}) of
/// metadata.json. A library's README.md is passed as REL README.md
/// (conda.bzl). metadata.json carries `doc_files` always, [] when none.
fn cmdConda(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--stamp", "--timestamp-ms", "--subdir", "--mojo-pin", "--license", "--summary", "--home", "--payload", "--dep", "--sources", "--import-name", "--extra-file", "--doc-file", "--label", "--commit", "--refuse", "--out-dir" });
    const name = need(a.name, "--name");
    if (one(a, "--refuse")) |why| {
        try writeRefusal(alloc, a, why);
        return;
    }
    if (!validName(name)) fail("name `{s}` is not lowercase letters, digits and _, starting with a letter", .{name});
    const import_name = need(one(a, "--import-name"), "--import-name");
    if (!validImport(import_name)) fail("import name `{s}` is not a Mojo identifier", .{import_name});
    const deps = try all(alloc, a, "--dep");
    for (deps, 0..) |d, i| {
        if (!validName(d)) fail("dependency `{s}` is not a conda name", .{d});
        if (std.mem.eql(u8, d, name)) fail("{s} depends on itself", .{name});
        for (deps[0..i]) |e| if (std.mem.eql(u8, d, e)) fail("dependency {s} given twice", .{d});
    }
    const subdir = need(one(a, "--subdir"), "--subdir");
    _ = guardFor(subdir);
    const pin = plain(need(one(a, "--mojo-pin"), "--mojo-pin"), "mojo pin", "");
    if (!decimal(std.mem.sliceTo(pin, '.'))) fail("mojo pin `{s}` is not an exact version", .{pin});

    const version = compilerVersion(pin);
    const stamp = need(one(a, "--stamp"), "--stamp");
    if (!decimal(stamp)) fail("--stamp `{s}` is not a decimal number without leading zeros", .{stamp});
    const number = std.fmt.parseInt(i64, stamp, 10) catch unreachable;
    const ts_text = need(one(a, "--timestamp-ms"), "--timestamp-ms");
    const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch fail("--timestamp-ms `{s}` is not an integer", .{ts_text});

    // The source commit the stamp was derived from (release_version.sh). A
    // stamped package must carry it, so a stamp is tied to git and not just to
    // a number someone typed; an unstamped one carries it only if given.
    const commit = commitOf(a, stamp);
    const build = try buildString(alloc, commit, number);

    if (try dlopenReason(alloc, need(one(a, "--sources"), "--sources"))) |why| {
        try writeRefusal(alloc, a, why);
        return;
    }

    const payload = readAll(alloc, need(one(a, "--payload"), "--payload"));
    if (payload.len == 0) fail("the payload is empty: a zero-byte .mojoc is a silent build failure", .{});
    const payload_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, import_name });
    const payload_sha = sha256Hex(payload);
    const docs = try docFiles(alloc, a, name);

    // info/
    const depends = try runRequirements(alloc, subdir, pin, version, build, deps);
    var index = newObject(alloc);
    try index.object.put("arch", str("x86_64"));
    try index.object.put("build", str(build));
    try index.object.put("build_number", .{ .integer = number });
    try index.object.put("depends", try strArray(alloc, depends));
    try index.object.put("license", str(need(one(a, "--license"), "--license")));
    try index.object.put("name", str(name));
    try index.object.put("platform", str("linux"));
    try index.object.put("subdir", str(subdir));
    try index.object.put("timestamp", .{ .integer = timestamp });
    try index.object.put("version", str(version));

    // pkg/: the payload and the doc files, sorted by path (writeTar sorts
    // the tar the same way), and one paths.json row each in that order.
    var pkg_list = std.ArrayList(Entry).init(alloc);
    try pkg_list.append(.{ .path = payload_path, .mode = 0o644, .data = payload });
    for (docs) |d| try pkg_list.append(.{ .path = d.path, .mode = 0o644, .data = d.data });
    const pkg_entries = try pkg_list.toOwnedSlice();
    std.mem.sort(Entry, pkg_entries, {}, lessEntry);
    var rows = newArray(alloc);
    for (pkg_entries) |e| try rows.array.append(try pathRow(alloc, e.path, e.data));
    var paths = newObject(alloc);
    try paths.object.put("paths", rows);
    try paths.object.put("paths_version", .{ .integer = 1 });

    var info_entries = std.ArrayList(Entry).init(alloc);
    try info_entries.append(.{ .path = "info/index.json", .mode = 0o644, .data = try jsonLine(alloc, index) });
    try info_entries.append(.{ .path = "info/paths.json", .mode = 0o644, .data = try jsonLine(alloc, paths) });
    try aboutAndLicense(alloc, a, &info_entries);

    const stem = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, build });
    const conda = try assembleConda(alloc, stem, pkg_entries, info_entries.items);

    var doc_rows = newArray(alloc);
    for (docs) |d| {
        var row = newObject(alloc);
        try row.object.put("path", str(d.path));
        try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(d.data))));
        try doc_rows.array.append(row);
    }
    var m = newObject(alloc);
    try m.object.put("depends", try strArray(alloc, depends));
    try m.object.put("doc_files", doc_rows);
    try m.object.put("import_name", str(import_name));
    try m.object.put("kind", str("library"));
    try m.object.put("label", str(need(one(a, "--label"), "--label")));
    try m.object.put("mojo_pin", str(pin));
    try m.object.put("payload_path", str(payload_path));
    try m.object.put("payload_sha256", str(&payload_sha));
    try m.object.put("source_commit", str(commit));
    try m.object.put("stamped", .{ .bool = !std.mem.eql(u8, stamp, "0") });
    try m.object.put("timestamp_ms", .{ .integer = timestamp });
    try emitPackage(alloc, a, stem, conda, name, version, build, number, subdir, &m);
}

// ---- the metapackage -----------------------------------------------------
//
// A metapackage has no file and requires every member at exactly its version.
// WHICH packages are members is not known to the build system (a Buck rule
// cannot enumerate targets): the release tool passes the members' manifests.

/// A member as its own manifest.json and metadata.json state it, after the
/// package file was read and hashed.
const Member = struct {
    name: []const u8,
    version: []const u8,
    subdir: []const u8,
    sha256: []const u8,
    build: []const u8,
    build_number: i64,
    commit: []const u8,
    timestamp: i64,
    stamped: bool,
    manifest: []const u8,
};

fn lessMember(_: void, x: Member, y: Member) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

fn memberBool(v: json.Value, key: []const u8, what: []const u8) bool {
    const m = member(v, key, what);
    if (m != .bool) fail("{s}: `{s}` is not a boolean", .{ what, key });
    return m.bool;
}

fn expectEq(what: []const u8, got: []const u8, want: []const u8) void {
    if (!std.mem.eql(u8, got, want)) fail("{s}: is `{s}`, must be `{s}`", .{ what, got, want });
}

/// The manifest at `path` must be exactly the contract: parsed, then rendered
/// again, it is the same bytes (so the ten keys, their order, the compact
/// form and the newline are all checked at once).
fn readContractManifest(alloc: Alloc, path: []const u8) !json.Value {
    const raw = readAll(alloc, path);
    const doc = json.parseFromSliceLeaky(json.Value, alloc, raw, .{}) catch |err|
        fail("{s}: not JSON: {s}", .{ path, @errorName(err) });
    if (doc != .object or doc.object.count() != 10) fail("{s}: the manifest has exactly the ten keys format, schema_version, artifact_type, name, version, platform, subdir, file, sha256, metadata", .{path});
    expectEq(path, memberStr(doc, "format", path), "kci.artifact_manifest");
    if (memberInt(doc, "schema_version", path) != 1) fail("{s}: the manifest's schema_version is not 1", .{path});
    expectEq(path, memberStr(doc, "metadata", path), conda_manifest_metadata);
    expectEq(path, memberStr(doc, "artifact_type", path), "CONDA");
    expectEq(path, memberStr(doc, "platform", path), platformFor(memberStr(doc, "subdir", path)));
    const again = try contractManifest(alloc, memberStr(doc, "name", path), memberStr(doc, "version", path), memberStr(doc, "subdir", path), memberStr(doc, "file", path), memberStr(doc, "sha256", path));
    if (!std.mem.eql(u8, again, raw)) fail("{s}: not the artifact manifest format (compact JSON, keys format, schema_version, artifact_type, name, version, platform, subdir, file, sha256, metadata in that order, one trailing newline)", .{path});
    return doc;
}

fn dirOf(path: []const u8) []const u8 {
    return std.fs.path.dirname(path) orelse ".";
}

fn readMember(alloc: Alloc, path: []const u8) !Member {
    const doc = try readContractManifest(alloc, path);
    const name = memberStr(doc, "name", path);
    const dir = dirOf(path);
    const file_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, memberStr(doc, "file", path) });
    const bytes = readAll(alloc, file_path);
    if (!std.mem.eql(u8, memberStr(doc, "sha256", path), &sha256Hex(bytes))) fail("{s}: the manifest's sha256 is not the file's", .{path});
    const meta_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, memberStr(doc, "metadata", path) });
    const meta = json.parseFromSliceLeaky(json.Value, alloc, readAll(alloc, meta_path), .{}) catch |err|
        fail("{s}: not JSON: {s}", .{ meta_path, @errorName(err) });
    expectEq(meta_path, memberStr(meta, "kind", meta_path), "library");
    expectEq(meta_path, memberStr(meta, "name", meta_path), name);
    expectEq(meta_path, memberStr(meta, "version", meta_path), memberStr(doc, "version", path));
    expectEq(meta_path, memberStr(meta, "subdir", meta_path), memberStr(doc, "subdir", path));
    expectEq(meta_path, memberStr(meta, "file_name", meta_path), memberStr(doc, "file", path));
    if (!validName(name)) fail("{s}: name `{s}` is not a conda name", .{ path, name });
    return .{
        .name = name,
        .version = memberStr(doc, "version", path),
        .subdir = memberStr(doc, "subdir", path),
        .sha256 = memberStr(doc, "sha256", path),
        .build = memberStr(meta, "build", meta_path),
        .build_number = memberInt(meta, "build_number", meta_path),
        .commit = memberStr(meta, "source_commit", meta_path),
        .timestamp = memberInt(meta, "timestamp_ms", meta_path),
        .stamped = memberBool(meta, "stamped", meta_path),
        .manifest = path,
    };
}

/// The members of the metapackage, from every --member-manifest: read, sorted
/// by name, and required to be one release: no name twice, one version, one
/// subdir, one source commit, one commit time.
fn readMembers(alloc: Alloc, a: Args) ![]Member {
    const paths = try all(alloc, a, "--member-manifest");
    if (paths.len == 0) fail("a metapackage needs at least one --member-manifest", .{});
    var list = std.ArrayList(Member).init(alloc);
    for (paths) |p| try list.append(try readMember(alloc, p));
    const members = try list.toOwnedSlice();
    std.mem.sort(Member, members, {}, lessMember);
    for (members[1..], 0..) |m, i| {
        const prev = members[i];
        if (std.mem.eql(u8, m.name, prev.name)) fail("member {s} given twice ({s} and {s})", .{ m.name, prev.manifest, m.manifest });
    }
    const f = members[0];
    for (members[1..]) |m| {
        if (!std.mem.eql(u8, m.version, f.version)) fail("members are not one release: {s} is at {s}, {s} at {s}", .{ f.name, f.version, m.name, m.version });
        if (!std.mem.eql(u8, m.subdir, f.subdir)) fail("members are not one subdir: {s} is {s}, {s} is {s}", .{ f.name, f.subdir, m.name, m.subdir });
        if (!std.mem.eql(u8, m.commit, f.commit)) fail("members are not one source commit: {s} and {s} differ", .{ f.name, m.name });
        if (!std.mem.eql(u8, m.build, f.build) or m.build_number != f.build_number) fail("members are not one release: {s} is build {s}, {s} is build {s}", .{ f.name, f.build, m.name, m.build });
        if (m.timestamp != f.timestamp or m.stamped != f.stamped) fail("members are not one release: {s} and {s} differ in commit time or stamp", .{ f.name, m.name });
    }
    return members;
}

/// komira_pack conda-meta --name N --member-manifest M.json... --license SPDX
///     --summary S --home URL --extra-file info/licenses/LICENSE=FILE
///     --label L --out-dir D
///
/// The metapackage: no file, run requirements that are exactly the platform
/// guard and every member at its own version and build string. Its version,
/// build, subdir, source commit and commit time are the members' (which must
/// agree); --mojo-pin V, if given, must be that version. Installing it
/// installs the whole set, and a registry that receives it LAST makes it the
/// switch for users.
fn cmdCondaMeta(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--member-manifest", "--mojo-pin", "--license", "--summary", "--home", "--extra-file", "--label", "--out-dir" });
    const name = need(a.name, "--name");
    if (!validName(name)) fail("metapackage name `{s}` is not lowercase letters, digits and _, starting with a letter", .{name});
    const members = try readMembers(alloc, a);
    for (members) |m| if (std.mem.eql(u8, m.name, name)) fail("metapackage name `{s}` is also a member", .{name});
    const version = members[0].version;
    if (one(a, "--mojo-pin")) |pin| expectEq("the members' version (it must be the compiler version)", version, pin);
    const build = members[0].build;
    const number = members[0].build_number;
    const subdir = members[0].subdir;
    const timestamp = members[0].timestamp;

    const depends = try metaRequirements(alloc, subdir, members);
    var index = newObject(alloc);
    try index.object.put("arch", str("x86_64"));
    try index.object.put("build", str(build));
    try index.object.put("build_number", .{ .integer = number });
    try index.object.put("depends", try strArray(alloc, depends));
    try index.object.put("license", str(need(one(a, "--license"), "--license")));
    try index.object.put("name", str(name));
    try index.object.put("platform", str("linux"));
    try index.object.put("subdir", str(subdir));
    try index.object.put("timestamp", .{ .integer = timestamp });
    try index.object.put("version", str(version));
    var paths = newObject(alloc);
    try paths.object.put("paths", newArray(alloc));
    try paths.object.put("paths_version", .{ .integer = 1 });

    var info_entries = std.ArrayList(Entry).init(alloc);
    try info_entries.append(.{ .path = "info/index.json", .mode = 0o644, .data = try jsonLine(alloc, index) });
    try info_entries.append(.{ .path = "info/paths.json", .mode = 0o644, .data = try jsonLine(alloc, paths) });
    try aboutAndLicense(alloc, a, &info_entries);
    const stem = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, build });
    var no_files = [_]Entry{};
    const conda = try assembleConda(alloc, stem, &no_files, info_entries.items);

    var rows = newArray(alloc);
    for (members) |m| {
        var row = newObject(alloc);
        try row.object.put("build", str(m.build));
        try row.object.put("name", str(m.name));
        try row.object.put("sha256", str(m.sha256));
        try row.object.put("version", str(m.version));
        try rows.array.append(row);
    }
    var md = newObject(alloc);
    try md.object.put("depends", try strArray(alloc, depends));
    try md.object.put("kind", str("metapackage"));
    try md.object.put("label", str(need(one(a, "--label"), "--label")));
    try md.object.put("members", rows);
    try md.object.put("source_commit", str(members[0].commit));
    try md.object.put("stamped", .{ .bool = members[0].stamped });
    try md.object.put("timestamp_ms", .{ .integer = timestamp });
    try emitPackage(alloc, a, stem, conda, name, version, build, number, subdir, &md);
}

// ---- reading a package back ----------------------------------------------

const Parts = struct { stem: []const u8, info: []TarFile, pkg: []TarFile };

/// The zip layout and both tars. Not through the code that wrote the package.
fn readParts(alloc: Alloc, bytes: []const u8) !Parts {
    const zip = try readZip(alloc, bytes, "package");
    if (zip.len != 3) fail("package: {d} members, must be 3 (metadata.json, pkg-*, info-*)", .{zip.len});
    expectEq("member 0 name", zip[0].name, "metadata.json");
    expectEq("metadata.json", zip[0].data, conda_metadata);
    if (!std.mem.startsWith(u8, zip[1].name, "pkg-") or !std.mem.endsWith(u8, zip[1].name, ".tar.zst")) fail("member 1 `{s}` is not pkg-*.tar.zst", .{zip[1].name});
    if (!std.mem.startsWith(u8, zip[2].name, "info-") or !std.mem.endsWith(u8, zip[2].name, ".tar.zst")) fail("member 2 `{s}` is not info-*.tar.zst", .{zip[2].name});
    const stem = zip[1].name["pkg-".len .. zip[1].name.len - ".tar.zst".len];
    expectEq("info member stem", zip[2].name["info-".len .. zip[2].name.len - ".tar.zst".len], stem);
    return .{
        .stem = stem,
        .info = try readTar(alloc, zstdDecode(alloc, zip[2].data, "info tar"), "info tar"),
        .pkg = try readTar(alloc, zstdDecode(alloc, zip[1].data, "pkg tar"), "pkg tar"),
    };
}

fn sortedNames(alloc: Alloc, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err|
        fail("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var list = std.ArrayList([]const u8).init(alloc);
    var it = dir.iterate();
    while (try it.next()) |e| try list.append(try alloc.dupe(u8, e.name));
    const names = try list.toOwnedSlice();
    std.mem.sort([]const u8, names, {}, lessStr);
    return names;
}

/// komira_pack conda-check --dir D --kind library|metapackage --name N
///     --expect-subdir S [--require-stamped true] --out MARKER
///   library:     --import-name I --mojo-pin V --payload F.mojoc [--dep NAME]...
///                [--doc-file REL=FILE]...
///   metapackage: --member-manifest M.json... [--mojo-pin V]
///
/// V is the Mojo compiler version: the package's version must BE it (a package
/// whose version is not the pinned compiler's is refused).
///
/// Reads the package directory back, not through the code that wrote it: the
/// manifest (it must be the artifact-manifest contract exactly), the metadata,
/// the zip, both zstd streams (through zig's decoder), both tars, then every
/// property a consumer or the channel relies on, against the values the CALLER
/// states (the expected name, subdir, pin, payload, dependencies, members).
/// Writes MARKER only when all hold; exit 2 naming the first that does not.
///
/// A library's pkg tar holds exactly the payload and the --doc-file files the
/// caller states, byte-equal, at share/doc/N/REL, and nothing else; paths.json
/// lists exactly those, and metadata.json's `doc_files` names exactly those
/// docs with their sha256, so a doc in the info tar, a missing row or a
/// changed byte is refused. A metapackage carries no doc.
///
/// A directory holding only REFUSED (the package could not be made) is a valid
/// refusal and writes MARKER saying so, except under --require-stamped, where
/// it is the failure, naming the reason: that is what asking for a release
/// of a library with no package does.
fn cmdCondaCheck(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--dir", "--kind", "--expect-subdir", "--import-name", "--mojo-pin", "--payload", "--dep", "--doc-file", "--member-manifest", "--require-stamped" });
    const dir = need(one(a, "--dir"), "--dir");
    const name = need(a.name, "--name");
    const kind = need(one(a, "--kind"), "--kind");
    const is_meta = std.mem.eql(u8, kind, "metapackage");
    if (!is_meta and !std.mem.eql(u8, kind, "library")) fail("--kind `{s}` is not library or metapackage", .{kind});
    const subdir = need(one(a, "--expect-subdir"), "--expect-subdir");
    const require_stamped = one(a, "--require-stamped") != null;
    const listing = try sortedNames(alloc, dir);

    if (listing.len == 1 and std.mem.eql(u8, listing[0], "REFUSED")) {
        const why = std.mem.trim(u8, readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/REFUSED", .{dir})), " \t\r\n");
        if (why.len == 0) fail("{s}/REFUSED holds no reason", .{dir});
        if (require_stamped) fail("{s} has no package, so there is nothing to release: {s}", .{ name, why });
        std.debug.print("komira_pack conda-check: {s} is refused: {s}\n", .{ name, why });
        try writeFile(std.fs.cwd(), need(a.out, "--out"), "refused\n");
        return;
    }
    // The listing is sorted, so where the package falls depends on its name
    // (`komira_*` sorts before `manifest.json`, `rest_url-*` after
    // `metadata.json`): find it among the three, never by position.
    var file_name: []const u8 = "";
    var n_conda: usize = 0;
    var has_manifest = false;
    var has_metadata = false;
    for (listing) |entry| {
        if (std.mem.eql(u8, entry, "manifest.json")) {
            has_manifest = true;
        } else if (std.mem.eql(u8, entry, "metadata.json")) {
            has_metadata = true;
        } else if (std.mem.endsWith(u8, entry, ".conda")) {
            file_name = entry;
            n_conda += 1;
        }
    }
    if (listing.len != 3 or n_conda != 1 or !has_manifest or !has_metadata)
        fail("{s} must hold exactly one .conda, manifest.json and metadata.json (or only REFUSED)", .{dir});
    const bytes = readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, file_name }));

    // The manifest: the contract, and the file it describes.
    const man_path = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{dir});
    const man = try readContractManifest(alloc, man_path);
    expectEq("manifest name", memberStr(man, "name", "manifest"), name);
    expectEq("manifest subdir", memberStr(man, "subdir", "manifest"), subdir);
    if (std.mem.eql(u8, subdir, "noarch")) fail("subdir noarch is never published: a compiled package names its platform", .{});
    expectEq("manifest file", memberStr(man, "file", "manifest"), file_name);
    expectEq("manifest sha256", memberStr(man, "sha256", "manifest"), &sha256Hex(bytes));
    const version = memberStr(man, "version", "manifest");

    const parts = try readParts(alloc, bytes);
    const info = parts.info;
    const pkg = parts.pkg;
    if (!validName(name)) fail("name `{s}` is not a conda name", .{name});
    if (one(a, "--mojo-pin")) |pin| expectEq("version (it must be the Mojo compiler version)", version, compilerVersion(pin));

    // info/: exactly the files a consumer reads, plus licences.
    var saw_license = false;
    for (info) |f| {
        const known = std.mem.eql(u8, f.name, "info/about.json") or std.mem.eql(u8, f.name, "info/index.json") or std.mem.eql(u8, f.name, "info/paths.json");
        if (std.mem.eql(u8, f.name, license_member)) saw_license = true;
        if (!known and !std.mem.startsWith(u8, f.name, "info/licenses/")) fail("info tar: unexpected member {s}", .{f.name});
        if (f.mode != 0o644) fail("info tar: {s} has mode {o}, must be 644", .{ f.name, f.mode });
    }
    if (!saw_license) fail("info tar: no {s}", .{license_member});
    const index_raw = (findTar(info, "info/index.json") orelse fail("info tar: no info/index.json", .{})).data;
    const paths_raw = (findTar(info, "info/paths.json") orelse fail("info tar: no info/paths.json", .{})).data;
    if (findTar(info, "info/about.json") == null) fail("info tar: no info/about.json", .{});
    const index = try json.parseFromSliceLeaky(json.Value, alloc, index_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, index), index_raw)) fail("info/index.json is not sorted compact JSON with one trailing newline", .{});

    // index.json
    if (index != .object) fail("info/index.json is not an object", .{});
    const want_keys = [_][]const u8{ "arch", "build", "build_number", "depends", "license", "name", "platform", "subdir", "timestamp", "version" };
    if (index.object.count() != want_keys.len) fail("info/index.json has {d} keys, must be exactly {d} (a `noarch` key among them is a refusal)", .{ index.object.count(), want_keys.len });
    for (want_keys) |k| _ = member(index, k, "info/index.json");
    expectEq("index name", memberStr(index, "name", "index"), name);
    expectEq("index version", memberStr(index, "version", "index"), version);
    expectEq("index subdir", memberStr(index, "subdir", "index"), subdir);
    expectEq("index platform", memberStr(index, "platform", "index"), "linux");
    expectEq("index arch", memberStr(index, "arch", "index"), "x86_64");
    _ = compilerVersion(version);
    const build = memberStr(index, "build", "index");
    const number = memberInt(index, "build_number", "index");
    if (number < 0) fail("index build_number {d} is negative", .{number});
    expectEq("file name", file_name, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}.conda", .{ name, version, build }));
    expectEq("member stem", parts.stem, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, build }));
    const stamped = number != 0;
    const timestamp = memberInt(index, "timestamp", "index");
    if (require_stamped) {
        if (!stamped) fail("version {s} was never stamped (the build number is 0): a release has a real build number", .{version});
        // A release is tied to git: a positive commit time, and the commit the stamp came from.
        if (timestamp <= 0) fail("version {s} is stamped but its index timestamp is not positive: a release carries its commit's time", .{version});
    }

    // The run requirements are re-derived from what the caller states.
    var members: []const Member = &.{};
    if (is_meta) {
        members = try readMembers(alloc, a);
        for (members) |m| {
            if (std.mem.eql(u8, m.name, name)) fail("the metapackage `{s}` is also a member", .{name});
            expectEq("member version", m.version, version);
            expectEq("member build", m.build, build);
            if (m.build_number != number) fail("member {s} has build number {d}, the metapackage {d}", .{ m.name, m.build_number, number });
            expectEq("member subdir", m.subdir, subdir);
        }
    }
    const want = if (is_meta)
        try metaRequirements(alloc, subdir, members)
    else
        try runRequirements(alloc, subdir, need(one(a, "--mojo-pin"), "--mojo-pin"), version, build, try all(alloc, a, "--dep"));
    const depends = member(index, "depends", "index");
    if (depends != .array or depends.array.items.len != want.len) fail("index depends has {d} entries, must be {d} (the platform guard{s} and each requirement at its version)", .{ if (depends == .array) depends.array.items.len else 0, want.len, @as([]const u8, if (is_meta) "" else ", the exact compiler pin") });
    for (depends.array.items, want) |got, w| {
        if (got != .string) fail("index depends holds a non-string", .{});
        expectEq("requirement", got.string, w);
    }

    // pkg/ and paths.json.
    const paths = try json.parseFromSliceLeaky(json.Value, alloc, paths_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, paths), paths_raw)) fail("info/paths.json is not sorted compact JSON with one trailing newline", .{});
    if (memberInt(paths, "paths_version", "paths") != 1) fail("paths_version is not 1", .{});
    const rows = member(paths, "paths", "paths");
    if (rows != .array) fail("info/paths.json has no list of paths", .{});
    var payload: []const u8 = "";
    var want_path: []const u8 = "";
    const docs = try docFiles(alloc, a, name);
    if (is_meta) {
        if (docs.len != 0) fail("--doc-file is given for a metapackage, which ships no doc", .{});
        if (pkg.len != 0) fail("pkg tar: {d} files, a metapackage carries none", .{pkg.len});
        if (rows.array.items.len != 0) fail("info/paths.json lists a file: a metapackage carries none", .{});
    } else {
        const import_name = need(one(a, "--import-name"), "--import-name");
        payload = readAll(alloc, need(one(a, "--payload"), "--payload"));
        want_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, import_name });
        if (payload.len == 0) fail("--payload is empty", .{});
        // What the pkg tar must hold: the payload and the stated docs, in path order.
        var want_list = std.ArrayList(DocFile).init(alloc);
        try want_list.append(.{ .path = want_path, .data = payload });
        for (docs) |d| try want_list.append(d);
        const want_files = try want_list.toOwnedSlice();
        std.mem.sort(DocFile, want_files, {}, lessDoc);
        if (pkg.len != want_files.len) fail("pkg tar: {d} files, must be exactly the .mojoc and the {d} declared doc file(s)", .{ pkg.len, docs.len });
        if (rows.array.items.len != want_files.len) fail("info/paths.json lists {d} files, must list exactly the .mojoc and the {d} declared doc file(s)", .{ rows.array.items.len, docs.len });
        for (want_files, pkg, rows.array.items) |w, f, row| {
            expectEq("pkg tar member", f.name, w.path);
            if (f.mode != 0o644) fail("pkg tar: {s} has mode {o}, must be 644", .{ f.name, f.mode });
            if (!std.mem.eql(u8, f.data, w.data)) {
                if (std.mem.eql(u8, w.path, want_path)) fail("pkg tar: the payload differs from the library's .mojoc ({d} bytes against {d})", .{ f.data.len, w.data.len });
                fail("pkg tar: {s} differs from the declared doc file ({d} bytes against {d})", .{ f.name, f.data.len, w.data.len });
            }
            expectEq("paths _path", memberStr(row, "_path", "paths row"), w.path);
            expectEq("paths path_type", memberStr(row, "path_type", "paths row"), "hardlink");
            expectEq("paths sha256", memberStr(row, "sha256", "paths row"), &sha256Hex(w.data));
            if (memberInt(row, "size_in_bytes", "paths row") != @as(i64, @intCast(w.data.len))) fail("paths size_in_bytes of {s} differs", .{w.path});
        }
    }

    // metadata.json agrees with the file and with the index.
    const md_raw = readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/metadata.json", .{dir}));
    const md = try json.parseFromSliceLeaky(json.Value, alloc, md_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, md), md_raw)) fail("metadata.json is not sorted compact JSON with one trailing newline", .{});
    expectEq("metadata format", memberStr(md, "format", "metadata"), "kci.conda_metadata");
    if (memberInt(md, "schema_version", "metadata") != 1) fail("metadata schema_version is not 1", .{});
    expectEq("metadata kind", memberStr(md, "kind", "metadata"), kind);
    expectEq("metadata name", memberStr(md, "name", "metadata"), name);
    expectEq("metadata version", memberStr(md, "version", "metadata"), version);
    expectEq("metadata subdir", memberStr(md, "subdir", "metadata"), subdir);
    expectEq("metadata build", memberStr(md, "build", "metadata"), build);
    if (memberInt(md, "build_number", "metadata") != number) fail("metadata build_number differs from the index", .{});
    expectEq("metadata file_name", memberStr(md, "file_name", "metadata"), file_name);
    if (memberInt(md, "size", "metadata") != @as(i64, @intCast(bytes.len))) fail("metadata size differs from the file", .{});
    if (memberInt(md, "timestamp_ms", "metadata") != timestamp) fail("metadata timestamp_ms differs from the index", .{});
    if (memberBool(md, "stamped", "metadata") != stamped) fail("metadata `stamped` disagrees with the version", .{});
    const commit = memberStr(md, "source_commit", "metadata");
    if (commit.len != 0 and !fullCommit(commit)) fail("metadata source_commit `{s}` is not a full lowercase 40-digit hex commit id", .{commit});
    if (stamped and commit.len == 0) fail("metadata source_commit is empty on a stamped package", .{});
    // The build string names the commit and the number: h<8 hex of source_commit>_<N>.
    expectEq("index build (h<first 8 hex of the source commit>_<build number>)", build, try buildString(alloc, commit, number));
    if (require_stamped and !fullCommit(commit)) fail("a release must carry the source commit of its stamp in the metadata", .{});
    const mdeps = member(md, "depends", "metadata");
    if (mdeps != .array or mdeps.array.items.len != want.len) fail("metadata depends differ from info/index.json", .{});
    for (want, mdeps.array.items) |x, y| if (y != .string or !std.mem.eql(u8, x, y.string)) fail("metadata depends differ from info/index.json", .{});
    if (is_meta) {
        if (md.object.get("doc_files") != null) fail("metadata doc_files on a metapackage, which ships no doc", .{});
        for (members) |m| {
            expectEq("member source commit", m.commit, commit);
            if (m.timestamp != timestamp) fail("member {s} has another commit time", .{m.name});
        }
        const rows_md = member(md, "members", "metadata");
        if (rows_md != .array or rows_md.array.items.len != members.len) fail("metadata members differ from the member manifests", .{});
        for (members, rows_md.array.items) |m, r| {
            expectEq("metadata member name", memberStr(r, "name", "member row"), m.name);
            expectEq("metadata member version", memberStr(r, "version", "member row"), m.version);
            expectEq("metadata member build", memberStr(r, "build", "member row"), m.build);
            expectEq("metadata member sha256", memberStr(r, "sha256", "member row"), m.sha256);
        }
    } else {
        expectEq("metadata import_name", memberStr(md, "import_name", "metadata"), need(one(a, "--import-name"), "--import-name"));
        expectEq("metadata mojo_pin", memberStr(md, "mojo_pin", "metadata"), need(one(a, "--mojo-pin"), "--mojo-pin"));
        expectEq("metadata payload_path", memberStr(md, "payload_path", "metadata"), want_path);
        expectEq("metadata payload_sha256", memberStr(md, "payload_sha256", "metadata"), &sha256Hex(payload));
        const md_docs = member(md, "doc_files", "metadata");
        if (md_docs != .array or md_docs.array.items.len != docs.len) fail("metadata doc_files must name exactly the {d} declared doc file(s)", .{docs.len});
        for (docs, md_docs.array.items) |d, r| {
            if (r != .object or r.object.count() != 2) fail("metadata doc_files rows are {{path, sha256}}", .{});
            expectEq("metadata doc_files path", memberStr(r, "path", "doc_files row"), d.path);
            expectEq("metadata doc_files sha256", memberStr(r, "sha256", "doc_files row"), &sha256Hex(d.data));
        }
    }

    std.debug.print("komira_pack conda-check: {s} {s} ({s}, {s}) ok\n", .{ name, version, subdir, kind });
    try writeFile(std.fs.cwd(), need(a.out, "--out"), "ok\n");
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) fail("usage: komira_pack tar|oci|conda|conda-meta|conda-check --flag value ...", .{});
    const a = try parseArgs(alloc, argv);
    if (std.mem.eql(u8, argv[1], "tar")) {
        try cmdTar(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "oci")) {
        try cmdOci(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda")) {
        try cmdConda(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-meta")) {
        try cmdCondaMeta(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-check")) {
        try cmdCondaCheck(alloc, a);
    } else fail("unknown command {s}", .{argv[1]});
}
