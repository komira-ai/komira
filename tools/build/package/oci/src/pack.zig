//! `komira_oci image`: an OCI image layout of the pinned base plus one
//! layer, a tree (tree.zig) laid at /, with the entrypoint named.
//!
//! The base is exactly the pinned blobs: the manifest must hash to its pin
//! and name the given config and layers, in order, by digest and size. The
//! config is the base's with the layer's diff_id, the Entrypoint, no Cmd,
//! the version label and one history entry added. The bytes depend only on
//! the tree and the base: tar entries are sorted, mtime, uid and gid are 0,
//! modes 0755/0644 (tree.zig), JSON keys are sorted and every timestamp is
//! 1970-01-01T00:00:00Z. The layer's gzip stream is the caller's; this file
//! does no I/O but reading the tree and writing the image.

const std = @import("std");
const C = @import("common.zig");
const json = @import("json.zig");
const sha256 = @import("sha256.zig");
const tar = @import("tar.zig");
const Fail = C.Fail;
const Value = json.Value;
const Item = tar.Item;

pub const MANIFEST_TYPE = "application/vnd.oci.image.manifest.v1+json";
pub const CONFIG_TYPE = "application/vnd.oci.image.config.v1+json";
pub const INDEX_TYPE = "application/vnd.oci.image.index.v1+json";
pub const LAYER_TYPE = "application/vnd.oci.image.layer.v1.tar+gzip";
const EPOCH = "1970-01-01T00:00:00Z";

pub fn s(x: []const u8) Value {
    return .{ .str = x };
}

pub fn num(n: usize) Value {
    return .{ .num = C.fmt("{d}", .{n}) };
}

pub fn obj(members: []const json.Member) Value {
    return .{ .obj = C.a().dupe(json.Member, members) catch C.oom() };
}

pub fn arr(items: []const Value) Value {
    return .{ .arr = C.a().dupe(Value, items) catch C.oom() };
}

pub fn descriptor(media_type: []const u8, data: []const u8) Value {
    return obj(&.{ .{ .k = "mediaType", .v = s(media_type) }, .{ .k = "digest", .v = s(sha256.digest(data)) }, .{ .k = "size", .v = num(data.len) } });
}

/// What names the image: `name` and `version` (history, tag), `repo`, and
/// the absolute `entrypoint`.
pub const Named = struct {
    name: []const u8,
    version: []const u8,
    repo: []const u8,
    entrypoint: []const u8,
};

/// `text` if it is non-empty and holds only letters, digits, `_.+-` and `extra`.
pub fn plain(text: []const u8, what: []const u8, extra: []const u8) Fail![]const u8 {
    if (text.len == 0) return C.fail("{s} is empty", .{what});
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (it.nextCodepointSlice()) |c| {
        const ok = c.len == 1 and (std.ascii.isAlphanumeric(c[0]) or C.contains("_.+-", c) or C.contains(extra, c));
        if (!ok) return C.fail("{s} `{s}` holds `{s}`", .{ what, text, c });
    }
    return text;
}

/// A repository name as docker spells it in full: a first component without
/// `.` or `:` (and not `localhost`) is on docker.io, and a single-component
/// name there is under `library/`.
pub fn normalizedRepo(repo: []const u8) []const u8 {
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return C.fmt("docker.io/library/{s}", .{repo});
    const first = repo[0..slash];
    if (C.contains(first, ".") or C.contains(first, ":") or C.eql(first, "localhost")) return repo;
    return C.fmt("docker.io/{s}", .{repo});
}

fn walk(dir: []const u8, rel: []const u8, out: *C.List(Item)) Fail!void {
    var d = std.fs.cwd().openDir(dir, .{ .iterate = true }) catch |e| return C.fail("cannot read {s}: {s}", .{ dir, C.ioErr(e) });
    defer d.close();
    var it = d.iterate();
    while (it.next() catch |e| return C.fail("cannot read {s}: {s}", .{ dir, C.ioErr(e) })) |ent| {
        if (!C.utf8Valid(ent.name)) return C.fail("{s}: a name that is not UTF-8: {s}", .{ dir, C.debugOsStr(ent.name) });
        const p = C.fmt("{s}{s}", .{ rel, ent.name });
        const full = C.pathJoin(dir, ent.name);
        const m = C.lstat(full) catch |e| return C.fail("cannot read {s}: {s}", .{ p, C.ioErr(e) });
        if (m.isDir()) {
            C.push(Item, out, .{ .path = C.fmt("{s}/", .{p}), .mode = 0o755, .data = "" });
            try walk(full, C.fmt("{s}/", .{p}), out);
        } else if (m.isFile()) {
            const data = C.readFile(full) catch |e| return C.fail("cannot read {s}: {s}", .{ p, C.ioErr(e) });
            C.push(Item, out, .{ .path = p, .mode = if (m.mode & 0o111 != 0) 0o755 else 0o644, .data = data });
        } else {
            return C.fail("{s}: not a regular file or directory", .{p});
        }
    }
}

/// The tree's directories and files as layer entries, under no prefix.
pub fn treeItems(root: []const u8) Fail![]Item {
    var out = C.list(Item);
    try walk(root, "", &out);
    for (out.items) |i| {
        if (!C.endsWith(i.path, "/")) return out.items;
    }
    return C.fail("tree {s} holds no files", .{root});
}

/// The pinned base: its manifest's bytes and pinned digest, its config's
/// bytes, and each layer blob in the manifest's order.
pub const Base = struct {
    manifest: []const u8,
    pin: []const u8,
    config: []const u8,
    layers: []const []const u8,
};

fn field(v: Value, key: []const u8, what: []const u8) Fail!Value {
    return v.get(key) orelse return C.fail("{s}: no `{s}`", .{ what, key });
}

fn fieldStr(v: Value, key: []const u8, what: []const u8) Fail![]const u8 {
    return (try field(v, key, what)).asStr() orelse return C.fail("{s}: `{s}` is not a string", .{ what, key });
}

fn fieldNum(v: Value, key: []const u8, what: []const u8) Fail![]const u8 {
    return switch (try field(v, key, what)) {
        .num => |n| n,
        else => return C.fail("{s}: `{s}` is not a number", .{ what, key }),
    };
}

/// The base manifest's layer descriptors, refused unless the base is
/// exactly the pinned blobs.
pub fn checkBase(b: Base) Fail![]Value {
    if (!C.eql(sha256.digest(b.manifest), b.pin)) return C.fail("base manifest does not hash to its pin {s}", .{b.pin});
    const m = json.parse(b.manifest) catch return C.fail("base manifest: {s}", .{C.msg});
    const mt = try fieldStr(m, "mediaType", "base manifest");
    if (!C.eql(mt, MANIFEST_TYPE)) return C.fail("base manifest: mediaType {s}, want {s}", .{ mt, MANIFEST_TYPE });
    if (!C.eql(try fieldNum(m, "schemaVersion", "base manifest"), "2")) return C.failS("base manifest: schemaVersion is not 2");
    const c = try field(m, "config", "base manifest");
    const want = try fieldStr(c, "digest", "base manifest config");
    if (!C.eql(sha256.digest(b.config), want)) return C.fail("base config does not hash to {s}", .{want});
    if (!C.eql(try fieldNum(c, "size", "base manifest config"), C.fmt("{d}", .{b.config.len}))) return C.failS("base config: size differs");
    const ls = (try field(m, "layers", "base manifest")).asArr() orelse return C.failS("base manifest: `layers` is not an array");
    if (ls.len != b.layers.len) return C.fail("base manifest names {d} layers, {d} given", .{ ls.len, b.layers.len });
    for (ls, b.layers, 0..) |d, blob, i| {
        const want_d = try fieldStr(d, "digest", "base layer");
        if (!C.eql(sha256.digest(blob), want_d)) return C.fail("base layer {d} does not hash to {s}", .{ i, want_d });
        if (!C.eql(try fieldNum(d, "size", "base layer"), C.fmt("{d}", .{blob.len}))) return C.fail("base layer {d}: size differs", .{i});
        if (!C.eql(try fieldStr(d, "mediaType", "base layer"), LAYER_TYPE)) return C.fail("base layer {d}: not {s}", .{ i, LAYER_TYPE });
    }
    const out = C.a().alloc(Value, ls.len) catch C.oom();
    for (ls, 0..) |d, i| out[i] = d.clone();
    return out;
}

/// The base config with the layer (`diff_id`, the digest of its tar), the
/// entrypoint, the version label and a history entry added, Cmd removed.
pub fn config(base: []const u8, diff_id: []const u8, n: Named) Fail!Value {
    var c = json.parse(base) catch return C.fail("base config: {s}", .{C.msg});
    if (!C.eql(try fieldStr(c, "architecture", "base config"), "amd64") or !C.eql(try fieldStr(c, "os", "base config"), "linux")) {
        return C.failS("base config is not linux/amd64");
    }
    var rootfs = (try field(c, "rootfs", "base config")).clone();
    const old_ids = (try field(rootfs, "diff_ids", "base config rootfs")).asArr() orelse return C.failS("base config: `diff_ids` is not an array");
    var ids = C.list(Value);
    for (old_ids) |v| C.push(Value, &ids, v.clone());
    C.push(Value, &ids, s(diff_id));
    try rootfs.set("diff_ids", .{ .arr = ids.items });
    try c.set("rootfs", rootfs);
    var cc = if (c.get("config")) |v| v.clone() else obj(&.{});
    cc.set("Entrypoint", arr(&.{s(n.entrypoint)})) catch return C.fail("base config: `config`: {s}", .{C.msg});
    cc.remove("Cmd");
    var labels = if (cc.get("Labels")) |v| v.clone() else obj(&.{});
    labels.set("org.opencontainers.image.version", s(n.version)) catch return C.fail("base config: `Labels`: {s}", .{C.msg});
    try cc.set("Labels", labels);
    try c.set("config", cc);
    var history = C.list(Value);
    if (c.get("history")) |h| {
        const old = h.asArr() orelse return C.failS("base config: `history` is not an array");
        for (old) |v| C.push(Value, &history, v.clone());
    }
    C.push(Value, &history, obj(&.{ .{ .k = "created", .v = s(EPOCH) }, .{ .k = "created_by", .v = s(C.fmt("komira oci_tree {s} {s}", .{ n.name, n.version })) } }));
    try c.set("history", .{ .arr = history.items });
    try c.set("created", s(EPOCH));
    return c;
}

/// An image's files: the layout's blobs and JSON, and Docker's manifest.json.
pub const Image = struct {
    /// Every blob, base layers first, then the layer, config and manifest.
    blobs: []const []const u8,
    index: []const u8,
    docker_manifest: []const u8,
    manifest_digest: []const u8,
};

fn blobPath(b: []const u8) Value {
    return s(C.fmt("blobs/sha256/{s}", .{sha256.hex(b)}));
}

/// The image of `base` plus the layer `layer_tar` (gzipped: `layer_gz`).
pub fn image(base: Base, layer_tar: []const u8, layer_gz: []const u8, n: Named) Fail!Image {
    var layers = C.list(Value);
    C.add2(Value, &layers, try checkBase(base));
    const config_bytes = (try config(base.config, sha256.digest(layer_tar), n)).toJson();
    C.push(Value, &layers, descriptor(LAYER_TYPE, layer_gz));
    const manifest = obj(&.{
        .{ .k = "schemaVersion", .v = num(2) },
        .{ .k = "mediaType", .v = s(MANIFEST_TYPE) },
        .{ .k = "config", .v = descriptor(CONFIG_TYPE, config_bytes) },
        .{ .k = "layers", .v = .{ .arr = layers.items } },
    });
    const manifest_bytes = manifest.toJson();
    // index.json: one manifest, tagged <version> and named with the full
    // reference in io.containerd.image.name, which `docker load` (containerd
    // image store) names the image by, verbatim; so it is normalized as
    // docker does (`komira/base` -> `docker.io/komira/base`).
    var mdesc = descriptor(MANIFEST_TYPE, manifest_bytes);
    try mdesc.set("platform", obj(&.{ .{ .k = "architecture", .v = s("amd64") }, .{ .k = "os", .v = s("linux") } }));
    try mdesc.set("annotations", obj(&.{
        .{ .k = "io.containerd.image.name", .v = s(C.fmt("{s}:{s}", .{ normalizedRepo(n.repo), n.version })) },
        .{ .k = "org.opencontainers.image.ref.name", .v = s(n.version) },
    }));
    const index = obj(&.{ .{ .k = "schemaVersion", .v = num(2) }, .{ .k = "mediaType", .v = s(INDEX_TYPE) }, .{ .k = "manifests", .v = arr(&.{mdesc}) } });
    var dlayers = C.list(Value);
    for (base.layers) |b| C.push(Value, &dlayers, blobPath(b));
    C.push(Value, &dlayers, blobPath(layer_gz));
    const docker = arr(&.{obj(&.{
        .{ .k = "Config", .v = blobPath(config_bytes) },
        .{ .k = "Layers", .v = .{ .arr = dlayers.items } },
        .{ .k = "RepoTags", .v = arr(&.{s(C.fmt("{s}:{s}", .{ n.repo, n.version }))}) },
    })});
    var blobs = C.list([]const u8);
    C.add2([]const u8, &blobs, base.layers);
    C.push([]const u8, &blobs, layer_gz);
    C.push([]const u8, &blobs, config_bytes);
    const manifest_digest = sha256.digest(manifest_bytes);
    C.push([]const u8, &blobs, manifest_bytes);
    return .{ .blobs = blobs.items, .index = index.toJson(), .docker_manifest = docker.toJson(), .manifest_digest = manifest_digest };
}

pub const OCI_LAYOUT = "{\"imageLayoutVersion\":\"1.0.0\"}";

pub const File = struct { path: []const u8, data: []const u8 };

/// The layout's files (path, bytes): each blob once, `oci-layout`,
/// `index.json`; and the archive's items, the same plus `manifest.json`.
pub const Files = struct { layout: []File, items: []Item };

pub fn files(img: Image) Files {
    var layout = C.list(File);
    for (img.blobs) |b| {
        const p = C.fmt("blobs/sha256/{s}", .{sha256.hex(b)});
        // The same blob twice (two identical base layers) is one file.
        const seen = for (layout.items) |f| {
            if (C.eql(f.path, p)) break true;
        } else false;
        if (!seen) C.push(File, &layout, .{ .path = p, .data = b });
    }
    C.push(File, &layout, .{ .path = "oci-layout", .data = OCI_LAYOUT });
    C.push(File, &layout, .{ .path = "index.json", .data = img.index });
    var items = C.list(Item);
    C.push(Item, &items, .{ .path = "blobs/", .mode = 0o755, .data = "" });
    C.push(Item, &items, .{ .path = "blobs/sha256/", .mode = 0o755, .data = "" });
    for (layout.items) |f| C.push(Item, &items, .{ .path = f.path, .mode = 0o644, .data = f.data });
    C.push(Item, &items, .{ .path = "manifest.json", .mode = 0o644, .data = img.docker_manifest });
    return .{ .layout = layout.items, .items = items.items };
}

fn writeOne(p: []const u8, data: []const u8) Fail!void {
    C.writeFile(p, data) catch |e| return C.fail("cannot write {s}: {s}", .{ p, C.ioErr(e) });
}

/// Writes the layout under `out`, the archive at `archive` and the digest.
pub fn write(img: Image, out: []const u8, archive: []const u8, digest: []const u8) Fail!void {
    const fs = files(img);
    std.fs.cwd().makePath(C.pathJoin(out, "blobs/sha256")) catch |e| return C.fail("cannot create {s}: {s}", .{ out, C.ioErr(e) });
    for (fs.layout) |f| try writeOne(C.pathJoin(out, f.path), f.data);
    try writeOne(archive, try tar.write(fs.items));
    try writeOne(digest, C.fmt("{s}\n", .{img.manifest_digest}));
}
