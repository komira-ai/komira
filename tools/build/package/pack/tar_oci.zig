//! komira_pack: the `tar` and `oci` commands.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const Args = pack_common.Args;
const Entry = pack_common.Entry;
const allow = pack_common.allow;
const bundleEntries = pack_common.bundleEntries;
const descriptor = pack_common.descriptor;
const digestOf = pack_common.digestOf;
const epoch = pack_common.epoch;
const fail = pack_common.fail;
const gzip = pack_common.gzip;
const member = pack_common.member;
const memberInt = pack_common.memberInt;
const memberStr = pack_common.memberStr;
const need = pack_common.need;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const normalizedRepo = pack_common.normalizedRepo;
const oci_config_type = pack_common.oci_config_type;
const oci_index_type = pack_common.oci_index_type;
const oci_layer_type = pack_common.oci_layer_type;
const oci_manifest_type = pack_common.oci_manifest_type;
const plain = pack_common.plain;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;
const str = pack_common.str;
const toJson = pack_common.toJson;
const writeFile = pack_common.writeFile;
const writeTar = pack_common.writeTar;

pub fn cmdTar(alloc: Alloc, a: Args) !void {
    allow(a, &.{});
    const entries = try bundleEntries(alloc, need(a.bundle, "--bundle"), need(a.prefix, "--prefix"));
    const tar = try writeTar(alloc, entries);
    try writeFile(std.fs.cwd(), need(a.out, "--out"), try gzip(alloc, tar));
}

pub fn cmdOci(alloc: Alloc, a: Args) !void {
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
