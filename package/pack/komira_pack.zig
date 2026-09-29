//! komira_pack: the package formats made from a bundle, byte for byte
//! reproducible.
//!
//! usage:
//!   komira_pack tar --bundle <dir> --prefix <top>/ --out <file.tar.gz>
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
    var a = Args{ .layers = std.ArrayList([]const u8).init(alloc) };
    var i: usize = 2;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) fail("{s} needs a value", .{argv[i]});
        const k = argv[i];
        const v: []const u8 = argv[i + 1];
        if (std.mem.eql(u8, k, "--layer")) {
            try a.layers.append(v);
            continue;
        }
        const slot: *?[]const u8 = if (std.mem.eql(u8, k, "--bundle")) &a.bundle else if (std.mem.eql(u8, k, "--prefix")) &a.prefix else if (std.mem.eql(u8, k, "--out")) &a.out else if (std.mem.eql(u8, k, "--name")) &a.name else if (std.mem.eql(u8, k, "--version")) &a.version else if (std.mem.eql(u8, k, "--repo")) &a.repo else if (std.mem.eql(u8, k, "--manifest")) &a.manifest else if (std.mem.eql(u8, k, "--manifest-digest")) &a.manifest_digest else if (std.mem.eql(u8, k, "--config")) &a.config else if (std.mem.eql(u8, k, "--archive")) &a.archive else if (std.mem.eql(u8, k, "--digest")) &a.digest else fail("unknown argument {s}", .{k});
        if (slot.* != null) fail("{s} given twice", .{k});
        slot.* = v;
    }
    return a;
}

// ---- commands ------------------------------------------------------------

fn cmdTar(alloc: Alloc, a: Args) !void {
    const entries = try bundleEntries(alloc, need(a.bundle, "--bundle"), need(a.prefix, "--prefix"));
    const tar = try writeTar(alloc, entries);
    try writeFile(std.fs.cwd(), need(a.out, "--out"), try gzip(alloc, tar));
}

fn cmdOci(alloc: Alloc, a: Args) !void {
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    if (argv.len < 2) fail("usage: komira_pack tar|oci --flag value ...", .{});
    const a = try parseArgs(alloc, argv);
    if (std.mem.eql(u8, argv[1], "tar")) {
        try cmdTar(alloc, a);
    } else if (std.mem.eql(u8, argv[1], "oci")) {
        try cmdOci(alloc, a);
    } else fail("unknown command {s}", .{argv[1]});
}
