//! komira_pack: the package formats made from a bundle, byte for byte
//! reproducible.
//!
//! usage:
//!   komira_pack tar --bundle <dir> --prefix <top>/ --out <file.tar.gz>
//!   komira_pack conda ...           (a `.conda` conda package; see below)
//!   komira_pack conda-check ...     (reads one back and refuses what is wrong)
//!   komira_pack conda-meta ...      (the metapackage: pins every approved library, no file)
//!   komira_pack conda-meta-check ...  (reads it back)
//!   komira_pack conda-set ...       (verifies a whole release set, then writes it as one directory)
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
//! `lib/mojo/<name>.mojoc`, `info-*.tar.zst` holding `info/`). Every flag is
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
const conda_build = "0";
const conda_metadata = "{\"conda_pkg_format_version\":2}";
const mojo_conda_name = "mojo-compiler";
const payload_dir = "lib/mojo/";
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

/// The first tab-separated column of every line that is not blank or a `#`
/// comment: the package names the approved list holds.
fn approvedNames(alloc: Alloc, path: []const u8) ![][]const u8 {
    const text = readAll(alloc, path);
    var list = std.ArrayList([]const u8).init(alloc);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#') continue;
        try list.append(line[0 .. std.mem.indexOfScalar(u8, line, '\t') orelse line.len]);
    }
    if (list.items.len == 0) fail("{s}: approves no package", .{path});
    return list.toOwnedSlice();
}

fn isApproved(names: []const []const u8, n: []const u8) bool {
    for (names) |a| if (std.mem.eql(u8, a, n)) return true;
    return false;
}

/// A published name: the prefix, then lowercase letters, digits and `_`. Compared
/// exactly (never folded: `komira_json` and `komira-json` are two names in a channel).
fn publishableName(n: []const u8, prefix: []const u8) bool {
    if (prefix.len == 0 or !std.mem.startsWith(u8, n, prefix) or n.len == prefix.len) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// A full git commit id: 40 lowercase hex digits.
fn fullCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// The sha256 a manifest carries as `approved_names_sha256`: the sorted names,
/// one per line (each ending in a newline). An uploader recomputes it from
/// names.tsv at the release commit with
/// `grep -vE '^(#|$)' names.tsv | cut -f1 | LC_ALL=C sort | sha256sum`.
fn namesDigest(alloc: Alloc, approved: []const []const u8) ![64]u8 {
    const names_sorted = try alloc.dupe([]const u8, approved);
    std.mem.sort([]const u8, names_sorted, {}, lessStr);
    var joined = std.ArrayList(u8).init(alloc);
    for (names_sorted) |n| {
        try joined.appendSlice(n);
        try joined.append('\n');
    }
    return sha256Hex(joined.items);
}

fn decimal(s: []const u8) bool {
    if (s.len == 0 or s.len > 9 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

fn guardFor(subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, conda_subdir)) return "__linux";
    fail("subdir `{s}`: this tool writes {s} only (an arm64 or macOS package needs its own payload and guard)", .{ subdir, conda_subdir });
}

/// The run requirements, in the order they are written and checked: the
/// platform guard, the exact Mojo pin, then each direct dependency at this
/// version, sorted. Direct dependencies only: every package is lockstep, so
/// the solver's closure is the build's.
fn runRequirements(alloc: Alloc, subdir: []const u8, pin: []const u8, version: []const u8, deps: []const []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    try list.append(try std.fmt.allocPrint(alloc, "{s} =={s}", .{ mojo_conda_name, pin }));
    const sorted = try alloc.dupe([]const u8, deps);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    for (sorted) |d| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s}", .{ d, version }));
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

/// Refuses a library that opens a shared library by name at run time: such a
/// package needs the conda package that ships it in its run requirements, and
/// this tool does not derive that yet, so it says so instead of publishing a
/// package that fails on a clean machine.
fn refuseDlopen(alloc: Alloc, dir_path: []const u8) !void {
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
            fail("{s}: opens a shared library at run time (OwnedDLHandle); its conda package must depend on the package shipping that library, which this tool does not derive yet", .{w.path});
    }
    if (files == 0) fail("sources {s} hold no .mojo file", .{dir_path});
}

/// `<prefix>.<stamp>` from --version-prefix (the one line, MAJOR.MINOR) and
/// --stamp (a decimal; 0 is an unstamped build).
fn versionOf(alloc: Alloc, a: Args) ![]const u8 {
    const prefix_text = std.mem.trim(u8, readAll(alloc, need(one(a, "--version-prefix"), "--version-prefix")), " \t\r\n");
    var parts = std.mem.splitScalar(u8, prefix_text, '.');
    const major = parts.next() orelse "";
    const minor = parts.next() orelse "";
    if (!decimal(major) or !decimal(minor) or parts.next() != null) fail("version prefix `{s}` is not MAJOR.MINOR", .{prefix_text});
    const stamp = need(one(a, "--stamp"), "--stamp");
    if (!decimal(stamp)) fail("--stamp `{s}` is not a decimal number without leading zeros", .{stamp});
    return std.fmt.allocPrint(alloc, "{s}.{s}.{s}", .{ major, minor, stamp });
}

/// The source commit of a stamp (--commit): empty only for an unstamped build.
fn commitOf(a: Args, stamp: []const u8) []const u8 {
    const commit = one(a, "--commit") orelse "";
    if (commit.len != 0 and !fullCommit(commit)) fail("--commit `{s}` is not a full lowercase 40-digit hex commit id", .{commit});
    if (!std.mem.eql(u8, stamp, "0") and commit.len == 0) fail("a stamped package (N={s}) must carry --commit, the commit its stamp was derived from", .{stamp});
    return commit;
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

/// komira_pack conda --name N --version-prefix FILE --stamp N --timestamp-ms T
///     --subdir linux-64 --mojo-pin V --license SPDX --summary S --home URL
///     --payload F.mojoc [--dep NAME]... --sources DIR --names FILE
///     --name-prefix P --extra-file info/licenses/LICENSE=FILE... --label L
///     --out F.conda --conda-manifest F.json --digest F
///
/// The version is `<prefix>.<stamp>` (the prefix is the one line of
/// --version-prefix, MAJOR.MINOR; stamp 0 is an unstamped build). The name and
/// every --dep must be in the approved list --names, and carry --name-prefix.
fn cmdConda(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--version-prefix", "--stamp", "--timestamp-ms", "--subdir", "--mojo-pin", "--license", "--summary", "--home", "--payload", "--dep", "--sources", "--names", "--name-prefix", "--extra-file", "--label", "--conda-manifest", "--commit" });
    const name = need(a.name, "--name");
    const prefix = need(one(a, "--name-prefix"), "--name-prefix");
    const approved = try approvedNames(alloc, need(one(a, "--names"), "--names"));
    if (!publishableName(name, prefix)) fail("name `{s}` is not `{s}` + lowercase letters, digits and _", .{ name, prefix });
    if (!isApproved(approved, name)) fail("name `{s}` is not in the approved list {s}; adding a name is a reviewed change to that file", .{ name, need(one(a, "--names"), "--names") });
    const deps = try all(alloc, a, "--dep");
    for (deps, 0..) |d, i| {
        if (!publishableName(d, prefix)) fail("dependency `{s}` is not a publishable name", .{d});
        if (!isApproved(approved, d)) fail("dependency `{s}` of {s} is not in the approved list: a package may not depend on one that is not published", .{ d, name });
        if (std.mem.eql(u8, d, name)) fail("{s} depends on itself", .{name});
        for (deps[0..i]) |e| if (std.mem.eql(u8, d, e)) fail("dependency {s} given twice", .{d});
    }
    const subdir = need(one(a, "--subdir"), "--subdir");
    _ = guardFor(subdir);
    const pin = plain(need(one(a, "--mojo-pin"), "--mojo-pin"), "mojo pin", "");
    if (!decimal(std.mem.sliceTo(pin, '.'))) fail("mojo pin `{s}` is not an exact version", .{pin});

    const version = try versionOf(alloc, a);
    const stamp = need(one(a, "--stamp"), "--stamp");
    const ts_text = need(one(a, "--timestamp-ms"), "--timestamp-ms");
    const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch fail("--timestamp-ms `{s}` is not an integer", .{ts_text});

    // The source commit the stamp was derived from (release_version.sh). A
    // stamped package must carry it, so a stamp is tied to git and not just to
    // a number someone typed; an unstamped one carries it only if given.
    const commit = commitOf(a, stamp);

    try refuseDlopen(alloc, need(one(a, "--sources"), "--sources"));

    const payload = readAll(alloc, need(one(a, "--payload"), "--payload"));
    if (payload.len == 0) fail("the payload is empty: a zero-byte .mojoc is a silent build failure", .{});
    const payload_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, name });
    const payload_sha = sha256Hex(payload);

    // info/
    const depends = try runRequirements(alloc, subdir, pin, version, deps);
    var index = newObject(alloc);
    try index.object.put("arch", str("x86_64"));
    try index.object.put("build", str(conda_build));
    try index.object.put("build_number", .{ .integer = 0 });
    try index.object.put("depends", try strArray(alloc, depends));
    try index.object.put("license", str(need(one(a, "--license"), "--license")));
    try index.object.put("name", str(name));
    try index.object.put("platform", str("linux"));
    try index.object.put("subdir", str(subdir));
    try index.object.put("timestamp", .{ .integer = timestamp });
    try index.object.put("version", str(version));

    var path_row = newObject(alloc);
    try path_row.object.put("_path", str(payload_path));
    try path_row.object.put("path_type", str("hardlink"));
    try path_row.object.put("sha256", str(&payload_sha));
    try path_row.object.put("size_in_bytes", .{ .integer = @intCast(payload.len) });
    var rows = newArray(alloc);
    try rows.array.append(path_row);
    var paths = newObject(alloc);
    try paths.object.put("paths", rows);
    try paths.object.put("paths_version", .{ .integer = 1 });

    var info_entries = std.ArrayList(Entry).init(alloc);
    try info_entries.append(.{ .path = "info/index.json", .mode = 0o644, .data = try jsonLine(alloc, index) });
    try info_entries.append(.{ .path = "info/paths.json", .mode = 0o644, .data = try jsonLine(alloc, paths) });
    try aboutAndLicense(alloc, a, &info_entries);

    const stem = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, conda_build });
    var pkg_entries = [_]Entry{.{ .path = payload_path, .mode = 0o644, .data = payload }};
    const conda = try assembleConda(alloc, stem, &pkg_entries, info_entries.items);
    const conda_sha = sha256Hex(conda);

    var m = newObject(alloc);
    const names_digest = try namesDigest(alloc, approved);
    try m.object.put("approved_names_sha256", str(&names_digest));
    try m.object.put("artifact_type", str("conda"));
    try m.object.put("build", str(conda_build));
    try m.object.put("build_number", .{ .integer = 0 });
    try m.object.put("depends", try strArray(alloc, depends));
    try m.object.put("file_name", str(try std.fmt.allocPrint(alloc, "{s}.conda", .{stem})));
    try m.object.put("kind", str("library"));
    try m.object.put("label", str(need(one(a, "--label"), "--label")));
    try m.object.put("mojo_pin", str(pin));
    try m.object.put("name", str(name));
    try m.object.put("payload_path", str(payload_path));
    try m.object.put("payload_sha256", str(&payload_sha));
    try m.object.put("schema", .{ .integer = 1 });
    try m.object.put("sha256", str(&conda_sha));
    try m.object.put("size", .{ .integer = @intCast(conda.len) });
    try m.object.put("source_commit", str(commit));
    try m.object.put("stamped", .{ .bool = !std.mem.eql(u8, stamp, "0") });
    try m.object.put("subdir", str(subdir));
    try m.object.put("version", str(version));

    try writeFile(std.fs.cwd(), need(a.out, "--out"), conda);
    try writeFile(std.fs.cwd(), need(one(a, "--conda-manifest"), "--conda-manifest"), try jsonLine(alloc, m));
    try writeFile(std.fs.cwd(), need(a.digest, "--digest"), try std.fmt.allocPrint(alloc, "sha256:{s}\n", .{conda_sha}));
}

fn memberBool(v: json.Value, key: []const u8, what: []const u8) bool {
    const m = member(v, key, what);
    if (m != .bool) fail("{s}: `{s}` is not a boolean", .{ what, key });
    return m.bool;
}

fn expectEq(what: []const u8, got: []const u8, want: []const u8) void {
    if (!std.mem.eql(u8, got, want)) fail("{s}: is `{s}`, must be `{s}`", .{ what, got, want });
}

/// komira_pack conda-check --package F.conda --conda-manifest F.json
///     --payload F.mojoc --expect-subdir S --names FILE --name-prefix P
///     --mojo-pin V [--require-stamped true] --out MARKER
///
/// Reads the package back, not through the code that wrote it: the zip, both
/// zstd streams (through zig's decoder), both tars, then every property a
/// consumer or the channel relies on. Writes MARKER only when all hold; exit 2
/// naming the first that does not.
fn cmdCondaCheck(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--package", "--conda-manifest", "--payload", "--expect-subdir", "--names", "--name-prefix", "--mojo-pin", "--require-stamped" });
    const pkg_path = need(one(a, "--package"), "--package");
    const bytes = readAll(alloc, pkg_path);
    const approved = try approvedNames(alloc, need(one(a, "--names"), "--names"));
    const prefix = need(one(a, "--name-prefix"), "--name-prefix");
    const subdir = need(one(a, "--expect-subdir"), "--expect-subdir");
    const pin = need(one(a, "--mojo-pin"), "--mojo-pin");
    const payload = readAll(alloc, need(one(a, "--payload"), "--payload"));

    const zip = try readZip(alloc, bytes, "package");
    if (zip.len != 3) fail("package: {d} members, must be 3 (metadata.json, pkg-*, info-*)", .{zip.len});
    expectEq("member 0 name", zip[0].name, "metadata.json");
    expectEq("metadata.json", zip[0].data, conda_metadata);
    if (!std.mem.startsWith(u8, zip[1].name, "pkg-") or !std.mem.endsWith(u8, zip[1].name, ".tar.zst")) fail("member 1 `{s}` is not pkg-*.tar.zst", .{zip[1].name});
    if (!std.mem.startsWith(u8, zip[2].name, "info-") or !std.mem.endsWith(u8, zip[2].name, ".tar.zst")) fail("member 2 `{s}` is not info-*.tar.zst", .{zip[2].name});
    const stem = zip[1].name["pkg-".len .. zip[1].name.len - ".tar.zst".len];
    expectEq("info member stem", zip[2].name["info-".len .. zip[2].name.len - ".tar.zst".len], stem);

    const info = try readTar(alloc, zstdDecode(alloc, zip[2].data, "info tar"), "info tar");
    const pkg = try readTar(alloc, zstdDecode(alloc, zip[1].data, "pkg tar"), "pkg tar");

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
    const name = memberStr(index, "name", "index");
    const version = memberStr(index, "version", "index");
    if (!publishableName(name, prefix)) fail("name `{s}` is not a publishable name", .{name});
    if (!isApproved(approved, name)) fail("name `{s}` is not in the approved list", .{name});
    expectEq("index subdir", memberStr(index, "subdir", "index"), subdir);
    expectEq("index platform", memberStr(index, "platform", "index"), "linux");
    expectEq("index arch", memberStr(index, "arch", "index"), "x86_64");
    expectEq("index build", memberStr(index, "build", "index"), conda_build);
    if (memberInt(index, "build_number", "index") != 0) fail("index build_number is not 0", .{});
    expectEq("member stem", stem, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, conda_build }));
    var vparts = std.mem.splitScalar(u8, version, '.');
    const v_major = vparts.next() orelse "";
    const v_minor = vparts.next() orelse "";
    const v_stamp = vparts.next() orelse "";
    if (!decimal(v_major) or !decimal(v_minor) or !decimal(v_stamp) or vparts.next() != null) fail("version `{s}` is not MAJOR.MINOR.N", .{version});
    const stamped = !std.mem.eql(u8, v_stamp, "0");
    if (one(a, "--require-stamped") != null) {
        if (!stamped) fail("version {s} was never stamped (N is 0): a release has a real N", .{version});
        // A release is tied to git: a positive commit time, and the commit the stamp came from.
        if (memberInt(index, "timestamp", "index") <= 0) fail("version {s} is stamped but its index timestamp is not positive: a release carries its commit's time", .{version});
    }
    const depends = member(index, "depends", "index");
    if (depends != .array or depends.array.items.len < 2) fail("index depends is not an array of at least the guard and the mojo pin", .{});
    const items = depends.array.items;
    for (items) |d| if (d != .string) fail("index depends holds a non-string", .{});
    expectEq("depends[0] (platform guard)", items[0].string, guardFor(subdir));
    expectEq("depends[1] (mojo pin)", items[1].string, try std.fmt.allocPrint(alloc, "{s} =={s}", .{ mojo_conda_name, pin }));
    var prev: []const u8 = "";
    for (items[2..]) |d| {
        const sp = std.mem.indexOf(u8, d.string, " ==") orelse fail("depends entry `{s}` is not `<name> ==<version>`", .{d.string});
        const dn = d.string[0..sp];
        if (!publishableName(dn, prefix) or !isApproved(approved, dn)) fail("depends on `{s}`, which is not an approved published package", .{dn});
        if (std.mem.eql(u8, dn, name)) fail("{s} depends on itself", .{name});
        expectEq("depends version of a dependency", d.string[sp + 3 ..], version);
        if (prev.len != 0 and !std.mem.lessThan(u8, prev, dn)) fail("depends is not sorted and unique at `{s}`", .{dn});
        prev = dn;
    }

    // pkg/: one file, the payload, byte for byte.
    if (pkg.len != 1) fail("pkg tar: {d} files, must be exactly the .mojoc", .{pkg.len});
    const want_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, name });
    expectEq("pkg tar member", pkg[0].name, want_path);
    if (pkg[0].mode != 0o644) fail("pkg tar: {s} has mode {o}, must be 644", .{ pkg[0].name, pkg[0].mode });
    if (pkg[0].data.len == 0) fail("pkg tar: the payload is empty", .{});
    if (!std.mem.eql(u8, pkg[0].data, payload)) fail("pkg tar: the payload differs from the library's .mojoc ({d} bytes against {d})", .{ pkg[0].data.len, payload.len });

    // paths.json describes exactly that file.
    const paths = try json.parseFromSliceLeaky(json.Value, alloc, paths_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, paths), paths_raw)) fail("info/paths.json is not sorted compact JSON with one trailing newline", .{});
    if (memberInt(paths, "paths_version", "paths") != 1) fail("paths_version is not 1", .{});
    const rows = member(paths, "paths", "paths");
    if (rows != .array or rows.array.items.len != 1) fail("info/paths.json must list exactly one file", .{});
    expectEq("paths _path", memberStr(rows.array.items[0], "_path", "paths row"), want_path);
    expectEq("paths path_type", memberStr(rows.array.items[0], "path_type", "paths row"), "hardlink");
    expectEq("paths sha256", memberStr(rows.array.items[0], "sha256", "paths row"), &sha256Hex(payload));
    if (memberInt(rows.array.items[0], "size_in_bytes", "paths row") != @as(i64, @intCast(payload.len))) fail("paths size_in_bytes differs", .{});

    // The manifest agrees with the file it describes.
    const man_raw = readAll(alloc, need(one(a, "--conda-manifest"), "--conda-manifest"));
    const man = try json.parseFromSliceLeaky(json.Value, alloc, man_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, man), man_raw)) fail("manifest is not sorted compact JSON with one trailing newline", .{});
    if (memberInt(man, "schema", "manifest") != 1) fail("manifest schema is not 1", .{});
    expectEq("manifest artifact_type", memberStr(man, "artifact_type", "manifest"), "conda");
    expectEq("manifest name", memberStr(man, "name", "manifest"), name);
    expectEq("manifest version", memberStr(man, "version", "manifest"), version);
    expectEq("manifest subdir", memberStr(man, "subdir", "manifest"), subdir);
    expectEq("manifest build", memberStr(man, "build", "manifest"), conda_build);
    expectEq("manifest file_name", memberStr(man, "file_name", "manifest"), try std.fmt.allocPrint(alloc, "{s}.conda", .{stem}));
    expectEq("manifest sha256", memberStr(man, "sha256", "manifest"), &sha256Hex(bytes));
    if (memberInt(man, "size", "manifest") != @as(i64, @intCast(bytes.len))) fail("manifest size differs from the file", .{});
    expectEq("manifest payload_sha256", memberStr(man, "payload_sha256", "manifest"), &sha256Hex(payload));
    expectEq("manifest payload_path", memberStr(man, "payload_path", "manifest"), want_path);
    expectEq("manifest mojo_pin", memberStr(man, "mojo_pin", "manifest"), pin);
    if (memberBool(man, "stamped", "manifest") != stamped) fail("manifest `stamped` disagrees with the version", .{});
    const man_commit = memberStr(man, "source_commit", "manifest");
    if (man_commit.len != 0 and !fullCommit(man_commit)) fail("manifest source_commit `{s}` is not a full lowercase 40-digit hex commit id", .{man_commit});
    if (stamped and man_commit.len == 0) fail("manifest source_commit is empty on a stamped package", .{});
    if (one(a, "--require-stamped") != null and !fullCommit(man_commit)) fail("a release must carry the source commit of its stamp in the manifest", .{});
    const names_digest = try namesDigest(alloc, approved);
    expectEq("manifest approved_names_sha256", memberStr(man, "approved_names_sha256", "manifest"), &names_digest);
    const mdeps = member(man, "depends", "manifest");
    if (mdeps != .array or mdeps.array.items.len != items.len) fail("manifest depends differ from info/index.json", .{});
    for (items, mdeps.array.items) |x, y| if (y != .string or !std.mem.eql(u8, x.string, y.string)) fail("manifest depends differ from info/index.json", .{});

    std.debug.print("komira_pack conda-check: {s} {s} ({s}) ok\n", .{ name, version, subdir });
    try writeFile(std.fs.cwd(), need(a.out, "--out"), "ok\n");
}


// ---- the metapackage and the release set ---------------------------------
//
// A release is a SET: one package per approved name, in lockstep, and a
// metapackage that pins all of them and carries no file. The set is verified
// as a whole (`conda-set`) before anything is offered to an uploader.

/// The metapackage's name: the one line of `--meta-name-file`. It is a name of
/// its own, never `<prefix>` + something, so it cannot be mistaken for a library
/// and a list of libraries cannot claim it.
fn metaNameOf(alloc: Alloc, a: Args, approved: []const []const u8, prefix: []const u8) []const u8 {
    const raw = std.mem.trim(u8, readAll(alloc, need(one(a, "--meta-name-file"), "--meta-name-file")), " \t\r\n");
    if (raw.len == 0) fail("--meta-name-file holds no name", .{});
    for (raw) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) fail("metapackage name `{s}` is not lowercase letters, digits and _", .{raw});
    if (isApproved(approved, raw)) fail("metapackage name `{s}` is also a library on the approved list", .{raw});
    if (std.mem.startsWith(u8, raw, prefix)) fail("metapackage name `{s}` carries the library prefix `{s}`: it would read as a library", .{ raw, prefix });
    return raw;
}

/// The run requirements of the metapackage: the platform guard, then every
/// approved library at exactly this version, sorted.
fn metaRequirements(alloc: Alloc, subdir: []const u8, version: []const u8, approved: []const []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    const sorted = try alloc.dupe([]const u8, approved);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    for (sorted) |d| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s}", .{ d, version }));
    return list.toOwnedSlice();
}

/// komira_pack conda-meta --names FILE --name-prefix P --meta-name-file FILE
///     --version-prefix FILE --stamp N --timestamp-ms T [--commit SHA]
///     --subdir linux-64 --license SPDX --summary S --home URL
///     --extra-file info/licenses/LICENSE=FILE --label L
///     --out F.conda --conda-manifest F.json --digest F
///
/// The metapackage: no file, run requirements that are exactly every approved
/// library at this version. Installing it installs the whole release set, and a
/// registry that receives it LAST makes it the switch for users.
fn cmdCondaMeta(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--names", "--name-prefix", "--meta-name-file", "--version-prefix", "--stamp", "--timestamp-ms", "--commit", "--subdir", "--license", "--summary", "--home", "--extra-file", "--label", "--conda-manifest" });
    const prefix = need(one(a, "--name-prefix"), "--name-prefix");
    const approved = try approvedNames(alloc, need(one(a, "--names"), "--names"));
    const name = metaNameOf(alloc, a, approved, prefix);
    const subdir = need(one(a, "--subdir"), "--subdir");
    _ = guardFor(subdir);
    const version = try versionOf(alloc, a);
    const stamp = need(one(a, "--stamp"), "--stamp");
    const ts_text = need(one(a, "--timestamp-ms"), "--timestamp-ms");
    const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch fail("--timestamp-ms `{s}` is not an integer", .{ts_text});
    const commit = commitOf(a, stamp);

    const depends = try metaRequirements(alloc, subdir, version, approved);
    var index = newObject(alloc);
    try index.object.put("arch", str("x86_64"));
    try index.object.put("build", str(conda_build));
    try index.object.put("build_number", .{ .integer = 0 });
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
    const stem = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, conda_build });
    var no_files = [_]Entry{};
    const conda = try assembleConda(alloc, stem, &no_files, info_entries.items);
    const conda_sha = sha256Hex(conda);

    var m = newObject(alloc);
    const names_digest = try namesDigest(alloc, approved);
    try m.object.put("approved_names_sha256", str(&names_digest));
    try m.object.put("artifact_type", str("conda"));
    try m.object.put("build", str(conda_build));
    try m.object.put("build_number", .{ .integer = 0 });
    try m.object.put("depends", try strArray(alloc, depends));
    try m.object.put("file_name", str(try std.fmt.allocPrint(alloc, "{s}.conda", .{stem})));
    try m.object.put("kind", str("metapackage"));
    try m.object.put("label", str(need(one(a, "--label"), "--label")));
    try m.object.put("name", str(name));
    try m.object.put("schema", .{ .integer = 1 });
    try m.object.put("sha256", str(&conda_sha));
    try m.object.put("size", .{ .integer = @intCast(conda.len) });
    try m.object.put("source_commit", str(commit));
    try m.object.put("stamped", .{ .bool = !std.mem.eql(u8, stamp, "0") });
    try m.object.put("subdir", str(subdir));
    try m.object.put("version", str(version));

    try writeFile(std.fs.cwd(), need(a.out, "--out"), conda);
    try writeFile(std.fs.cwd(), need(one(a, "--conda-manifest"), "--conda-manifest"), try jsonLine(alloc, m));
    try writeFile(std.fs.cwd(), need(a.digest, "--digest"), try std.fmt.allocPrint(alloc, "sha256:{s}\n", .{conda_sha}));
}

/// The package's own `info/index.json`, read back from the zip.
fn packageIndex(alloc: Alloc, bytes: []const u8, what: []const u8) !json.Value {
    const zip = try readZip(alloc, bytes, what);
    if (zip.len != 3) fail("{s}: {d} members, must be 3 (metadata.json, pkg-*, info-*)", .{ what, zip.len });
    const info = try readTar(alloc, zstdDecode(alloc, zip[2].data, "info tar"), "info tar");
    const raw = (findTar(info, "info/index.json") orelse fail("{s}: no info/index.json", .{what})).data;
    return json.parseFromSliceLeaky(json.Value, alloc, raw, .{});
}

/// komira_pack conda-meta-check --package F.conda --conda-manifest F.json
///     --names FILE --name-prefix P --meta-name-file FILE --expect-subdir S
///     [--require-stamped true] --out MARKER
///
/// Reads the metapackage back: it holds no file, and its requirements are the
/// guard and EVERY approved library, each at its own version, sorted.
fn cmdCondaMetaCheck(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--package", "--conda-manifest", "--names", "--name-prefix", "--meta-name-file", "--expect-subdir", "--require-stamped" });
    const bytes = readAll(alloc, need(one(a, "--package"), "--package"));
    const approved = try approvedNames(alloc, need(one(a, "--names"), "--names"));
    const prefix = need(one(a, "--name-prefix"), "--name-prefix");
    const meta_name = metaNameOf(alloc, a, approved, prefix);
    const subdir = need(one(a, "--expect-subdir"), "--expect-subdir");
    const zip = try readZip(alloc, bytes, "package");
    if (zip.len != 3) fail("package: {d} members, must be 3 (metadata.json, pkg-*, info-*)", .{zip.len});
    expectEq("member 0 name", zip[0].name, "metadata.json");
    expectEq("metadata.json", zip[0].data, conda_metadata);
    if (!std.mem.startsWith(u8, zip[1].name, "pkg-") or !std.mem.endsWith(u8, zip[1].name, ".tar.zst")) fail("member 1 `{s}` is not pkg-*.tar.zst", .{zip[1].name});
    if (!std.mem.startsWith(u8, zip[2].name, "info-") or !std.mem.endsWith(u8, zip[2].name, ".tar.zst")) fail("member 2 `{s}` is not info-*.tar.zst", .{zip[2].name});
    const stem = zip[1].name["pkg-".len .. zip[1].name.len - ".tar.zst".len];
    expectEq("info member stem", zip[2].name["info-".len .. zip[2].name.len - ".tar.zst".len], stem);
    const pkg = try readTar(alloc, zstdDecode(alloc, zip[1].data, "pkg tar"), "pkg tar");
    if (pkg.len != 0) fail("pkg tar: {d} files, a metapackage carries none", .{pkg.len});
    const info = try readTar(alloc, zstdDecode(alloc, zip[2].data, "info tar"), "info tar");
    for (info) |f| {
        const known = std.mem.eql(u8, f.name, "info/about.json") or std.mem.eql(u8, f.name, "info/index.json") or std.mem.eql(u8, f.name, "info/paths.json");
        if (!known and !std.mem.startsWith(u8, f.name, "info/licenses/")) fail("info tar: unexpected member {s}", .{f.name});
    }
    if (findTar(info, license_member) == null) fail("info tar: no {s}", .{license_member});
    const index_raw = (findTar(info, "info/index.json") orelse fail("info tar: no info/index.json", .{})).data;
    const index = try json.parseFromSliceLeaky(json.Value, alloc, index_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, index), index_raw)) fail("info/index.json is not sorted compact JSON with one trailing newline", .{});
    const paths_raw = (findTar(info, "info/paths.json") orelse fail("info tar: no info/paths.json", .{})).data;
    if (!std.mem.eql(u8, paths_raw, "{\"paths\":[],\"paths_version\":1}\n")) fail("info/paths.json lists a file: a metapackage carries none", .{});

    if (index != .object or index.object.count() != 10) fail("info/index.json is not an object of exactly the ten keys", .{});
    expectEq("index name", memberStr(index, "name", "index"), meta_name);
    const version = memberStr(index, "version", "index");
    expectEq("index subdir", memberStr(index, "subdir", "index"), subdir);
    expectEq("index platform", memberStr(index, "platform", "index"), "linux");
    expectEq("index arch", memberStr(index, "arch", "index"), "x86_64");
    expectEq("index build", memberStr(index, "build", "index"), conda_build);
    expectEq("member stem", stem, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ meta_name, version, conda_build }));
    var vparts = std.mem.splitScalar(u8, version, '.');
    _ = vparts.next();
    _ = vparts.next();
    const v_stamp = vparts.next() orelse "";
    const stamped = !std.mem.eql(u8, v_stamp, "0");
    if (one(a, "--require-stamped") != null) {
        if (!stamped) fail("version {s} was never stamped (N is 0): a release has a real N", .{version});
        if (memberInt(index, "timestamp", "index") <= 0) fail("version {s} is stamped but its index timestamp is not positive: a release carries its commit's time", .{version});
    }
    const want = try metaRequirements(alloc, subdir, version, approved);
    const depends = member(index, "depends", "index");
    if (depends != .array or depends.array.items.len != want.len) fail("metapackage depends is not the guard and every one of the {d} approved libraries", .{want.len - 1});
    for (depends.array.items, want) |got, w| {
        if (got != .string) fail("index depends holds a non-string", .{});
        expectEq("metapackage requirement", got.string, w);
    }

    const man_raw = readAll(alloc, need(one(a, "--conda-manifest"), "--conda-manifest"));
    const man = try json.parseFromSliceLeaky(json.Value, alloc, man_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, man), man_raw)) fail("manifest is not sorted compact JSON with one trailing newline", .{});
    expectEq("manifest kind", memberStr(man, "kind", "manifest"), "metapackage");
    expectEq("manifest name", memberStr(man, "name", "manifest"), meta_name);
    expectEq("manifest version", memberStr(man, "version", "manifest"), version);
    expectEq("manifest file_name", memberStr(man, "file_name", "manifest"), try std.fmt.allocPrint(alloc, "{s}.conda", .{stem}));
    expectEq("manifest sha256", memberStr(man, "sha256", "manifest"), &sha256Hex(bytes));
    if (memberInt(man, "size", "manifest") != @as(i64, @intCast(bytes.len))) fail("manifest size differs from the file", .{});
    if (memberBool(man, "stamped", "manifest") != stamped) fail("manifest `stamped` disagrees with the version", .{});
    const man_commit = memberStr(man, "source_commit", "manifest");
    if (man_commit.len != 0 and !fullCommit(man_commit)) fail("manifest source_commit `{s}` is not a full lowercase 40-digit hex commit id", .{man_commit});
    if (one(a, "--require-stamped") != null and !fullCommit(man_commit)) fail("a release must carry the source commit of its stamp in the manifest", .{});
    const names_digest = try namesDigest(alloc, approved);
    expectEq("manifest approved_names_sha256", memberStr(man, "approved_names_sha256", "manifest"), &names_digest);

    std.debug.print("komira_pack conda-meta-check: {s} {s} ({s}) pins {d} libraries, ok\n", .{ meta_name, version, subdir, approved.len });
    try writeFile(std.fs.cwd(), need(a.out, "--out"), "ok\n");
}

const SetEntry = struct {
    role: []const u8, // "member" or "metapackage"
    name: []const u8,
    version: []const u8,
    subdir: []const u8,
    file_name: []const u8,
    sha256: []const u8,
    size: i64,
    commit: []const u8,
    names_digest: []const u8,
    stamped: bool,
    depends: []const []const u8,
    bytes: []const u8,
};

fn problem(alloc: Alloc, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) void {
    list.append(std.fmt.allocPrint(alloc, fmt, args) catch fail("out of memory", .{})) catch fail("out of memory", .{});
}

/// One artifact of the set, read from the package ITSELF (its own info/index.json
/// and its bytes) and from its manifest, with every disagreement noted.
fn readSetEntry(alloc: Alloc, role: []const u8, pair: []const u8, problems: *std.ArrayList([]const u8)) !SetEntry {
    const eq = std.mem.indexOfScalar(u8, pair, '=') orelse fail("`{s}` is not <manifest>=<file>", .{pair});
    const man_path = pair[0..eq];
    const file_path = pair[eq + 1 ..];
    const bytes = readAll(alloc, file_path);
    const man = try json.parseFromSliceLeaky(json.Value, alloc, readAll(alloc, man_path), .{});
    const index = try packageIndex(alloc, bytes, file_path);
    const name = memberStr(man, "name", man_path);
    const version = memberStr(man, "version", man_path);
    if (!std.mem.eql(u8, memberStr(index, "name", "index"), name)) problem(alloc, problems, "{s}: the package's own name is `{s}`, its manifest says `{s}`", .{ file_path, memberStr(index, "name", "index"), name });
    if (!std.mem.eql(u8, memberStr(index, "version", "index"), version)) problem(alloc, problems, "{s}: the package's own version is {s}, its manifest says {s}", .{ name, memberStr(index, "version", "index"), version });
    const subdir = memberStr(index, "subdir", "index");
    if (!std.mem.eql(u8, memberStr(man, "subdir", man_path), subdir)) problem(alloc, problems, "{s}: manifest subdir differs from the package's", .{name});
    const file_name = memberStr(man, "file_name", man_path);
    const want_file = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}.conda", .{ name, version, conda_build });
    if (!std.mem.eql(u8, file_name, want_file)) problem(alloc, problems, "{s}: file_name `{s}` is not `{s}`", .{ name, file_name, want_file });
    const sha = sha256Hex(bytes);
    if (!std.mem.eql(u8, memberStr(man, "sha256", man_path), &sha)) problem(alloc, problems, "{s}: the manifest's sha256 is not the file's ({s})", .{ name, &sha });
    if (memberInt(man, "size", man_path) != @as(i64, @intCast(bytes.len))) problem(alloc, problems, "{s}: the manifest's size is not the file's", .{name});
    const kind = memberStr(man, "kind", man_path);
    if (!std.mem.eql(u8, kind, if (std.mem.eql(u8, role, "member")) "library" else "metapackage")) problem(alloc, problems, "{s}: manifest kind `{s}` is not that of a {s}", .{ name, kind, role });
    const idx_depends = member(index, "depends", "index");
    const man_depends = member(man, "depends", man_path);
    var same = idx_depends == .array and man_depends == .array and idx_depends.array.items.len == man_depends.array.items.len;
    if (same) for (idx_depends.array.items, man_depends.array.items) |x, y| {
        same = same and x == .string and y == .string and std.mem.eql(u8, x.string, y.string);
    };
    if (!same) problem(alloc, problems, "{s}: the manifest's depends differ from the package's own", .{name});
    var deps = std.ArrayList([]const u8).init(alloc);
    if (idx_depends == .array) for (idx_depends.array.items) |d| if (d == .string) try deps.append(d.string);
    return .{
        .role = role,
        .name = name,
        .version = version,
        .subdir = subdir,
        .file_name = file_name,
        .sha256 = try alloc.dupe(u8, &sha),
        .size = @intCast(bytes.len),
        .commit = memberStr(man, "source_commit", man_path),
        .names_digest = memberStr(man, "approved_names_sha256", man_path),
        .stamped = memberBool(man, "stamped", man_path),
        .depends = try deps.toOwnedSlice(),
        .bytes = bytes,
    };
}

fn setEntryJson(alloc: Alloc, e: SetEntry) !json.Value {
    var o = newObject(alloc);
    try o.object.put("depends", try strArray(alloc, e.depends));
    try o.object.put("file_name", str(e.file_name));
    try o.object.put("name", str(e.name));
    try o.object.put("path", str(try std.fmt.allocPrint(alloc, "{s}.conda", .{e.name})));
    try o.object.put("role", str(e.role));
    try o.object.put("sha256", str(e.sha256));
    try o.object.put("size", .{ .integer = e.size });
    try o.object.put("source_commit", str(e.commit));
    try o.object.put("subdir", str(e.subdir));
    try o.object.put("version", str(e.version));
    return o;
}

fn lessSetEntry(_: void, x: SetEntry, y: SetEntry) bool {
    return std.mem.lessThan(u8, x.name, y.name);
}

/// komira_pack conda-set --names FILE --name-prefix P --meta-name-file FILE
///     --mojo-pin V --external NAME... --member MANIFEST=FILE... --meta MANIFEST=FILE
///     --out-dir DIR
///
/// Verifies a release set as a whole and, only if it is complete and consistent,
/// writes DIR: every package as `<name>.conda` and `release_set.json`. Every
/// problem is reported, not only the first. Refuses (exit 2) when:
///   * an approved name has no package, or a package is not an approved name;
///   * versions, subdir, source commit or approved-list digest are not one value
///     across the set (lockstep), or a package is unstamped;
///   * a package's requirement is neither an approved library at the set's
///     version nor an allowed external (`--external`; the compiler at its pin);
///   * the metapackage does not pin every library, or pins anything else;
///   * a package's manifest disagrees with the package's own bytes.
fn cmdCondaSet(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--names", "--name-prefix", "--meta-name-file", "--mojo-pin", "--external", "--member", "--meta", "--out-dir" });
    const approved = try approvedNames(alloc, need(one(a, "--names"), "--names"));
    const prefix = need(one(a, "--name-prefix"), "--name-prefix");
    const meta_name = metaNameOf(alloc, a, approved, prefix);
    const pin = need(one(a, "--mojo-pin"), "--mojo-pin");
    const externals = try all(alloc, a, "--external");
    if (externals.len == 0) fail("no --external: every package requires at least the platform guard", .{});
    var problems = std.ArrayList([]const u8).init(alloc);

    var entries = std.ArrayList(SetEntry).init(alloc);
    for (try all(alloc, a, "--member")) |pair| try entries.append(try readSetEntry(alloc, "member", pair, &problems));
    const meta = try readSetEntry(alloc, "metapackage", need(one(a, "--meta"), "--meta"), &problems);
    if (entries.items.len == 0) fail("no --member: a release set of nothing", .{});

    // completeness: the approved list and the packages are the same set
    for (approved) |n| {
        var found = false;
        for (entries.items) |e| found = found or std.mem.eql(u8, e.name, n);
        if (!found) problem(alloc, &problems, "missing member: `{s}` is approved but no package for it is in the set", .{n});
    }
    for (entries.items, 0..) |e, i| {
        if (!isApproved(approved, e.name)) problem(alloc, &problems, "`{s}` is in the set but not on the approved list", .{e.name});
        for (entries.items[0..i]) |p| if (std.mem.eql(u8, p.name, e.name)) problem(alloc, &problems, "`{s}` is in the set twice", .{e.name});
    }
    if (!std.mem.eql(u8, meta.name, meta_name)) problem(alloc, &problems, "the metapackage is named `{s}`, the approved name is `{s}`", .{ meta.name, meta_name });

    // lockstep, and a release
    const names_digest = try namesDigest(alloc, approved);
    var all_entries = std.ArrayList(SetEntry).init(alloc);
    try all_entries.appendSlice(entries.items);
    try all_entries.append(meta);
    for (all_entries.items) |e| {
        if (!std.mem.eql(u8, e.version, meta.version)) problem(alloc, &problems, "version skew: `{s}` is {s}, the metapackage is {s}", .{ e.name, e.version, meta.version });
        if (!std.mem.eql(u8, e.subdir, meta.subdir)) problem(alloc, &problems, "`{s}` is for {s}, the metapackage for {s}", .{ e.name, e.subdir, meta.subdir });
        if (!std.mem.eql(u8, e.commit, meta.commit)) problem(alloc, &problems, "`{s}` was stamped from commit `{s}`, the metapackage from `{s}`", .{ e.name, e.commit, meta.commit });
        if (!e.stamped) problem(alloc, &problems, "`{s}` was never stamped: a release is stamped", .{e.name});
        if (!fullCommit(e.commit)) problem(alloc, &problems, "`{s}` carries no full source commit", .{e.name});
        if (!std.mem.eql(u8, e.names_digest, &names_digest)) problem(alloc, &problems, "`{s}` was built against another approved list (approved_names_sha256 {s}, this list {s})", .{ e.name, e.names_digest, &names_digest });
    }

    // every requirement of a library is inside the set or an allowed external
    for (entries.items) |e| {
        for (e.depends) |d| {
            const sp = std.mem.indexOf(u8, d, " ==");
            const dn = if (sp) |i| d[0..i] else d;
            var external = false;
            for (externals) |x| external = external or std.mem.eql(u8, x, dn);
            if (external) {
                if (std.mem.eql(u8, dn, mojo_conda_name)) {
                    const want = try std.fmt.allocPrint(alloc, "{s} =={s}", .{ mojo_conda_name, pin });
                    if (!std.mem.eql(u8, d, want)) problem(alloc, &problems, "`{s}` requires `{s}`, the set's compiler is `{s}`", .{ e.name, d, want });
                }
                continue;
            }
            if (!isApproved(approved, dn)) {
                problem(alloc, &problems, "`{s}` requires `{s}`, which is outside the release set", .{ e.name, dn });
                continue;
            }
            const ver = if (sp) |i| d[i + 3 ..] else "";
            if (!std.mem.eql(u8, ver, e.version)) problem(alloc, &problems, "`{s}` requires `{s}`, not at its own version {s}", .{ e.name, d, e.version });
        }
    }

    // the metapackage pins exactly the approved libraries
    const want_meta = try metaRequirements(alloc, meta.subdir, meta.version, approved);
    var meta_ok = meta.depends.len == want_meta.len;
    if (meta_ok) for (meta.depends, want_meta) |g, w| {
        meta_ok = meta_ok and std.mem.eql(u8, g, w);
    };
    if (!meta_ok) problem(alloc, &problems, "the metapackage's requirements are not exactly the guard and every approved library at {s}", .{meta.version});

    if (problems.items.len != 0) {
        for (problems.items) |p| std.debug.print("komira_pack conda-set: {s}\n", .{p});
        fail("{d} problem(s): the set is not a release", .{problems.items.len});
    }

    // upload order: members sorted by name, the metapackage LAST
    std.mem.sort(SetEntry, entries.items, {}, lessSetEntry);
    var artifacts = newArray(alloc);
    var order = newArray(alloc);
    for (entries.items) |e| {
        try artifacts.array.append(try setEntryJson(alloc, e));
        try order.array.append(str(e.file_name));
    }
    try artifacts.array.append(try setEntryJson(alloc, meta));
    try order.array.append(str(meta.file_name));
    var set = newObject(alloc);
    try set.object.put("approved_names_sha256", str(&names_digest));
    try set.object.put("artifact_type", str("conda-release-set"));
    try set.object.put("artifacts", artifacts);
    try set.object.put("member_count", .{ .integer = @intCast(entries.items.len) });
    try set.object.put("metapackage", str(meta.name));
    try set.object.put("mojo_pin", str(pin));
    try set.object.put("schema", .{ .integer = 1 });
    try set.object.put("source_commit", str(meta.commit));
    try set.object.put("subdir", str(meta.subdir));
    try set.object.put("upload_order", order);
    try set.object.put("version", str(meta.version));

    const out_dir = need(one(a, "--out-dir"), "--out-dir");
    try std.fs.cwd().makePath(out_dir);
    var dir = try std.fs.cwd().openDir(out_dir, .{});
    defer dir.close();
    for (all_entries.items) |e| try writeFile(dir, try std.fmt.allocPrint(alloc, "{s}.conda", .{e.name}), e.bytes);
    try writeFile(dir, "release_set.json", try jsonLine(alloc, set));
    std.debug.print("komira_pack conda-set: {d} libraries and the metapackage `{s}`, version {s}, ok\n", .{ entries.items.len, meta.name, meta.version });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) fail("usage: komira_pack tar|oci|conda|conda-check|conda-meta|conda-meta-check|conda-set --flag value ...", .{});
    const a = try parseArgs(alloc, argv);
    if (std.mem.eql(u8, argv[1], "tar")) {
        try cmdTar(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "oci")) {
        try cmdOci(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda")) {
        try cmdConda(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-check")) {
        try cmdCondaCheck(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-meta")) {
        try cmdCondaMeta(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-meta-check")) {
        try cmdCondaMetaCheck(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "conda-set")) {
        try cmdCondaSet(alloc, a);
    } else fail("unknown command {s}", .{argv[1]});
}
