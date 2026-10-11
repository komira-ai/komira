//! The image writer's cases (pack.zig).

const std = @import("std");
const C = @import("common.zig");
const P = @import("pack.zig");
const J = @import("json.zig");
const sha = @import("sha256.zig");
const T = @import("tar.zig");
const F = @import("tar_fixture.zig");
const D = @import("fs_fixture.zig");

const Value = J.Value;
const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;
const s = P.s;
const num = P.num;
const obj = P.obj;

const BASE_CONFIG = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"config\":{\"Cmd\":[\"/bin/x\"],\"User\":\"65532\",\"Labels\":{\"k\":\"v\"}},\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:aa\"]},\"history\":[{\"created_by\":\"base\"}],\"created\":\"the base time\"}";

fn named() P.Named {
    return .{ .name = "floor", .version = "0.1.0", .repo = "komira/base", .entrypoint = "/komira/bin/supervisor" };
}

const LAYER = "gzip bytes of a base layer";

fn base() P.Base {
    const manifest = C.fmt(
        "{{\"schemaVersion\":2,\"mediaType\":\"{s}\",\"config\":{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}},\"layers\":[{{\"mediaType\":\"{s}\",\"digest\":\"{s}\",\"size\":{d}}}]}}",
        .{ P.MANIFEST_TYPE, P.CONFIG_TYPE, sha.digest(BASE_CONFIG), BASE_CONFIG.len, P.LAYER_TYPE, sha.digest(LAYER), LAYER.len },
    );
    const layers = C.a().dupe([]const u8, &.{LAYER}) catch C.oom();
    return .{ .pin = sha.digest(manifest), .manifest = manifest, .config = BASE_CONFIG, .layers = layers };
}

/// A base of two distinct layers, whose manifest is edited by `edit` and
/// pinned again: only what `edit` changed can be refused.
fn edited(edit: anytype) P.Base {
    const layers = C.a().dupe([]const u8, &.{ "gzip bytes of layer zero", "gzip bytes of layer one" }) catch C.oom();
    var m = obj(&.{
        .{ .k = "schemaVersion", .v = num(2) },
        .{ .k = "mediaType", .v = s(P.MANIFEST_TYPE) },
        .{ .k = "config", .v = P.descriptor(P.CONFIG_TYPE, BASE_CONFIG) },
        .{ .k = "layers", .v = P.arr(&.{ P.descriptor(P.LAYER_TYPE, layers[0]), P.descriptor(P.LAYER_TYPE, layers[1]) }) },
    });
    edit.f(&m);
    const manifest = m.toJson();
    return .{ .pin = sha.digest(manifest), .manifest = manifest, .config = BASE_CONFIG, .layers = layers };
}

const Unedited = struct {
    fn f(_: *Value) void {}
};

/// Sets `key` of the manifest's member `at` (`config`), or of its layer
/// `at`; a `nul` value removes the key.
fn setIn(m: *Value, at: []const u8, key: []const u8, v: Value) void {
    const idx = std.fmt.parseInt(usize, at, 10) catch null;
    var d = if (idx) |i| m.get("layers").?.asArr().?[i].clone() else m.get(at).?.clone();
    if (v == .nul) d.remove(key) else d.set(key, v) catch unreachable;
    if (idx) |i| {
        const ls = m.get("layers").?.clone();
        ls.arr[i] = d;
        m.set("layers", ls) catch unreachable;
    } else {
        m.set(at, d) catch unreachable;
    }
}

test "pack: the_config_names_the_entrypoint_layer_and_version" {
    const c = try F.ok(P.config(BASE_CONFIG, "sha256:bb", named()));
    try eqs("{\"architecture\":\"amd64\",\"config\":{\"Entrypoint\":[\"/komira/bin/supervisor\"],\"Labels\":{\"k\":\"v\",\"org.opencontainers.image.version\":\"0.1.0\"},\"User\":\"65532\"}," ++
        "\"created\":\"1970-01-01T00:00:00Z\",\"history\":[{\"created_by\":\"base\"},{\"created\":\"1970-01-01T00:00:00Z\",\"created_by\":\"komira oci_tree floor 0.1.0\"}]," ++
        "\"os\":\"linux\",\"rootfs\":{\"diff_ids\":[\"sha256:aa\",\"sha256:bb\"],\"type\":\"layers\"}}", c.toJson());
    const arm = std.mem.replaceOwned(u8, C.a(), BASE_CONFIG, "amd64", "arm64") catch C.oom();
    try F.expectFail(P.config(arm, "sha256:bb", named()), "base config is not linux/amd64");
}

/// `base()` with its manifest's one `from` replaced by `to`, pinned again.
fn resized(from: []const u8, to: []const u8) !P.Base {
    var b = base();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, b.manifest, from));
    b.manifest = std.mem.replaceOwned(u8, C.a(), b.manifest, from, to) catch C.oom();
    b.pin = sha.digest(b.manifest);
    return b;
}

fn withLayers(b: P.Base, layers: []const []const u8) P.Base {
    var r = b;
    r.layers = C.a().dupe([]const u8, layers) catch C.oom();
    return r;
}

test "pack: the_base_must_be_exactly_the_pinned_blobs" {
    try std.testing.expectEqual(@as(usize, 1), (try F.ok(P.checkBase(base()))).len);
    var b = base();
    b.pin = sha.digest("other");
    try F.expectFailContains(P.checkBase(b), "does not hash to its pin");
    b = base();
    b.config = BASE_CONFIG ++ " ";
    try F.expectFailContains(P.checkBase(b), "base config does not hash");
    b = withLayers(base(), &.{LAYER ++ "\x00"});
    try F.expectFail(P.checkBase(b), C.fmt("base layer 0 does not hash to {s}", .{sha.digest(LAYER)}));
    b = withLayers(base(), &.{ LAYER, "" });
    try F.expectFail(P.checkBase(b), "base manifest names 1 layers, 2 given");
    // A size off by one under a correct digest, with the pin recomputed, so
    // only the size check can refuse it.
    const n = BASE_CONFIG.len;
    b = try resized(C.fmt("\"size\":{d}}},\"layers\"", .{n}), C.fmt("\"size\":{d}}},\"layers\"", .{n + 1}));
    try F.expectFail(P.checkBase(b), "base config: size differs");
    const l = LAYER.len;
    b = try resized(C.fmt("\"size\":{d}}}]", .{l}), C.fmt("\"size\":{d}}}]", .{l - 1}));
    try F.expectFail(P.checkBase(b), "base layer 0: size differs");
}

fn refusedBy(comptime edit: fn (*Value) void) []const u8 {
    if (P.checkBase(edited(struct {
        const f = edit;
    }))) |_| {
        return "accepted";
    } else |_| return C.msg;
}

fn setLayerKey(comptime i: []const u8, comptime key: []const u8, comptime v: fn () Value) fn (*Value) void {
    return struct {
        fn f(m: *Value) void {
            setIn(m, i, key, v());
        }
    }.f;
}

fn nul() Value {
    return .nul;
}

fn val(comptime x: Value) fn () Value {
    return struct {
        fn f() Value {
            return x;
        }
    }.f;
}

fn numOne() Value {
    return num(1);
}

test "pack: every_base_refusal_has_its_own_case" {
    try std.testing.expectEqual(@as(usize, 2), (try F.ok(P.checkBase(edited(Unedited)))).len);
    // The manifest's own fields.
    try eqs(C.fmt("base manifest: mediaType {s}, want {s}", .{ P.INDEX_TYPE, P.MANIFEST_TYPE }), refusedBy(struct {
        fn f(m: *Value) void {
            m.set("mediaType", s(P.INDEX_TYPE)) catch unreachable;
        }
    }.f));
    try eqs("base manifest: no `mediaType`", refusedBy(struct {
        fn f(m: *Value) void {
            m.remove("mediaType");
        }
    }.f));
    try eqs("base manifest: `mediaType` is not a string", refusedBy(struct {
        fn f(m: *Value) void {
            m.set("mediaType", num(1)) catch unreachable;
        }
    }.f));
    try eqs("base manifest: schemaVersion is not 2", refusedBy(struct {
        fn f(m: *Value) void {
            m.set("schemaVersion", num(1)) catch unreachable;
        }
    }.f));
    try eqs("base manifest: `schemaVersion` is not a number", refusedBy(struct {
        fn f(m: *Value) void {
            m.set("schemaVersion", s("2")) catch unreachable;
        }
    }.f));
    try eqs("base manifest: no `config`", refusedBy(struct {
        fn f(m: *Value) void {
            m.remove("config");
        }
    }.f));
    try eqs("base manifest config: no `digest`", refusedBy(setLayerKey("config", "digest", nul)));
    try eqs("base manifest config: `size` is not a number", refusedBy(setLayerKey("config", "size", val(.{ .str = "1" }))));
    try eqs("base manifest: no `layers`", refusedBy(struct {
        fn f(m: *Value) void {
            m.remove("layers");
        }
    }.f));
    try eqs("base manifest: `layers` is not an array", refusedBy(struct {
        fn f(m: *Value) void {
            m.set("layers", obj(&.{})) catch unreachable;
        }
    }.f));
    // Each layer, the last one included.
    inline for (.{ "0", "1" }) |i| {
        try eqs("base layer " ++ i ++ ": not " ++ P.LAYER_TYPE, refusedBy(setLayerKey(i, "mediaType", val(.{ .str = P.CONFIG_TYPE }))));
        try eqs("base layer: no `mediaType`", refusedBy(setLayerKey(i, "mediaType", nul)));
        try eqs("base layer " ++ i ++ " does not hash to sha256:00", refusedBy(setLayerKey(i, "digest", val(.{ .str = "sha256:00" }))));
        try eqs("base layer: no `digest`", refusedBy(setLayerKey(i, "digest", nul)));
        try eqs("base layer " ++ i ++ ": size differs", refusedBy(setLayerKey(i, "size", numOne)));
        try eqs("base layer: no `size`", refusedBy(setLayerKey(i, "size", nul)));
    }
    // Fewer blobs given than the manifest names, and more.
    const two = edited(Unedited);
    try F.expectFail(P.checkBase(withLayers(two, two.layers[0..1])), "base manifest names 2 layers, 1 given");
    try F.expectFail(P.checkBase(withLayers(two, &.{})), "base manifest names 2 layers, 0 given");
    // The blobs swapped: each digest names the other one.
    try F.expectFailPrefix(P.checkBase(withLayers(two, &.{ two.layers[1], two.layers[0] })), "base layer 0 does not hash to ");
    // A manifest that is not JSON, pinned as it is.
    var b = base();
    b.manifest = "{\"schemaVersion\":2,}";
    b.pin = sha.digest(b.manifest);
    try F.expectFailPrefix(P.checkBase(b), "base manifest: JSON: ");
    // image() refuses what checkBase refuses.
    b = base();
    b.pin = sha.digest("other");
    try F.expectFailPrefix(P.image(b, "t", "g", named()), "");
}

fn configRefused(from: []const u8, to: []const u8) ![]const u8 {
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, BASE_CONFIG, from));
    const c = std.mem.replaceOwned(u8, C.a(), BASE_CONFIG, from, to) catch C.oom();
    return F.failText(P.config(c, "sha256:bb", named()));
}

test "pack: every_config_refusal_has_its_own_case" {
    try eqs("base config is not linux/amd64", try configRefused("\"os\":\"linux\"", "\"os\":\"windows\""));
    try eqs("base config: no `architecture`", try configRefused("\"architecture\":\"amd64\",", ""));
    try eqs("base config: no `os`", try configRefused("\"os\":\"linux\",", ""));
    try eqs("base config: no `rootfs`", try configRefused(",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:aa\"]}", ""));
    try eqs("base config: `diff_ids` is not an array", try configRefused("\"diff_ids\":[\"sha256:aa\"]", "\"diff_ids\":\"sha256:aa\""));
    try eqs("base config rootfs: no `diff_ids`", try configRefused(",\"diff_ids\":[\"sha256:aa\"]", ""));
    try eqs("base config rootfs: no `diff_ids`", try configRefused("\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[\"sha256:aa\"]}", "\"rootfs\":[]"));
    try eqs("base config: `config`: cannot set `Entrypoint`: not an object", try configRefused("\"config\":{\"Cmd\":[\"/bin/x\"],\"User\":\"65532\",\"Labels\":{\"k\":\"v\"}}", "\"config\":[]"));
    try eqs("base config: `Labels`: cannot set `org.opencontainers.image.version`: not an object", try configRefused("\"Labels\":{\"k\":\"v\"}", "\"Labels\":1"));
    try eqs("base config: `history` is not an array", try configRefused("\"history\":[{\"created_by\":\"base\"}]", "\"history\":{}"));
    try expect(C.startsWith(try configRefused("\"created\":\"the base time\"}", "\"created\":"), "base config: JSON: "));
    // What the base config may leave out: no `config`, `Labels` or `history`.
    const bare = "{\"architecture\":\"amd64\",\"os\":\"linux\",\"rootfs\":{\"type\":\"layers\",\"diff_ids\":[]}}";
    try eqs(
        "{\"architecture\":\"amd64\",\"config\":{\"Entrypoint\":[\"/komira/bin/supervisor\"],\"Labels\":{\"org.opencontainers.image.version\":\"0.1.0\"}},\"created\":\"1970-01-01T00:00:00Z\",\"history\":[{\"created\":\"1970-01-01T00:00:00Z\",\"created_by\":\"komira oci_tree floor 0.1.0\"}],\"os\":\"linux\",\"rootfs\":{\"diff_ids\":[\"sha256:bb\"],\"type\":\"layers\"}}",
        (try F.ok(P.config(bare, "sha256:bb", named()))).toJson(),
    );
}

const TwoSame = struct {
    fn f(m: *Value) void {
        const d = m.get("layers").?.asArr().?[0];
        m.set("layers", P.arr(&.{ d.clone(), d.clone() })) catch unreachable;
    }
};

test "pack: two_identical_base_layers_are_one_file" {
    const e = edited(TwoSame);
    const b = withLayers(e, &.{ e.layers[0], e.layers[0] });
    const img = try F.ok(P.image(b, "layer tar", "layer gz", named()));
    const fs = P.files(img);
    try std.testing.expectEqual(@as(usize, 6), fs.layout.len);
    _ = try F.ok(T.write(fs.items));
    // Docker's manifest.json still names the base layer twice.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, img.docker_manifest, sha.hex(b.layers[0])));
}

test "pack: a_tree_holds_files_and_directories_only" {
    const d = D.scratch("pack", "empty");
    try F.expectFail(P.treeItems(d), C.fmt("tree {s} holds no files", .{d}));
    D.mkdir(D.path(d, "sub"));
    try F.expectFail(P.treeItems(d), C.fmt("tree {s} holds no files", .{d}));
    const m = D.scratch("pack", "modes");
    D.mkdir(D.path(m, "bin"));
    D.writeMode(D.path(m, "bin/x"), "exe", 0o700);
    D.writeMode(D.path(m, "bin/r"), "", 0o600);
    D.writeMode(D.path(m, "top"), "t", 0o640);
    // Any one exec bit makes 0755: the group's alone, the others' alone.
    D.writeMode(D.path(m, "bin/g"), "", 0o610);
    D.writeMode(D.path(m, "bin/o"), "", 0o601);
    const got = C.a().dupe(T.Item, try F.ok(P.treeItems(m))) catch C.oom();
    std.mem.sort(T.Item, got, {}, struct {
        fn lt(_: void, x: T.Item, y: T.Item) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    const want = [_]T.Item{
        .{ .path = "bin/", .mode = 0o755, .data = "" },
        .{ .path = "bin/g", .mode = 0o755, .data = "" },
        .{ .path = "bin/o", .mode = 0o755, .data = "" },
        .{ .path = "bin/r", .mode = 0o644, .data = "" },
        .{ .path = "bin/x", .mode = 0o755, .data = "exe" },
        .{ .path = "top", .mode = 0o644, .data = "t" },
    };
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try eqs(w.path, g.path);
        try std.testing.expectEqual(w.mode, g.mode);
        try eqs(w.data, g.data);
    }
    D.symlink("top", D.path(m, "bin/link"));
    try F.expectFail(P.treeItems(m), "bin/link: not a regular file or directory");
}

test "pack: a_tree_name_that_is_not_utf8_is_refused" {
    const d = D.scratch("pack", "not_utf8");
    D.mkdir(D.path(d, "sub"));
    D.write(D.path(d, "sub/a\xff"), "x");
    try F.expectFail(P.treeItems(d), C.fmt("{s}: a name that is not UTF-8: \"a\\xFF\"", .{D.path(d, "sub")}));
}

test "pack: the_image_adds_one_layer_and_tags_the_version" {
    const img = try F.ok(P.image(base(), "layer tar", "layer gz", named()));
    const m = try F.ok(J.parse(img.blobs[img.blobs.len - 1]));
    const layers = m.get("layers").?.asArr().?;
    try std.testing.expectEqual(@as(usize, 2), layers.len);
    try eqs(sha.digest("layer gz"), layers[1].get("digest").?.asStr().?);
    try eqs(sha.digest(img.blobs[img.blobs.len - 1]), img.manifest_digest);
    const c = try F.ok(J.parse(img.blobs[2]));
    try eqs(sha.digest(img.blobs[2]), m.get("config").?.get("digest").?.asStr().?);
    const ids = c.get("rootfs").?.get("diff_ids").?.asArr().?;
    try eqs(sha.digest("layer tar"), ids[1].asStr().?);
    try expect(C.contains(img.index, "\"io.containerd.image.name\":\"docker.io/komira/base:0.1.0\""));
    try expect(C.contains(img.docker_manifest, "\"RepoTags\":[\"komira/base:0.1.0\"]"));
    const fs = P.files(img);
    try std.testing.expectEqual(@as(usize, 6), fs.layout.len);
    try eqs("oci-layout", fs.layout[4].path);
    try eqs("index.json", fs.layout[5].path);
    try std.testing.expectEqual(@as(usize, 9), fs.items.len);
    // index.json and Docker's manifest.json, whole.
    try eqs(C.fmt(
        "{{\"manifests\":[{{\"annotations\":{{\"io.containerd.image.name\":\"docker.io/komira/base:0.1.0\",\"org.opencontainers.image.ref.name\":\"0.1.0\"}}," ++
            "\"digest\":\"{s}\",\"mediaType\":\"{s}\",\"platform\":{{\"architecture\":\"amd64\",\"os\":\"linux\"}},\"size\":{d}}}],\"mediaType\":\"{s}\",\"schemaVersion\":2}}",
        .{ img.manifest_digest, P.MANIFEST_TYPE, img.blobs[3].len, P.INDEX_TYPE },
    ), img.index);
    try eqs(C.fmt(
        "[{{\"Config\":\"blobs/sha256/{s}\",\"Layers\":[\"blobs/sha256/{s}\",\"blobs/sha256/{s}\"],\"RepoTags\":[\"komira/base:0.1.0\"]}}]",
        .{ sha.hex(img.blobs[2]), sha.hex(LAYER), sha.hex("layer gz") },
    ), img.docker_manifest);
    // Same inputs, same bytes.
    try eqs(img.manifest_digest, (try F.ok(P.image(base(), "layer tar", "layer gz", named()))).manifest_digest);
}

// Every name, media type and mode spelled out here, not taken from the
// constants the code uses: a constant changed in the code is caught.
test "pack: the_layout_and_archive_name_these_files_with_these_bytes" {
    const img = try F.ok(P.image(base(), "layer tar", "layer gz", named()));
    const layer0 = LAYER;
    const cfg = img.blobs[2];
    const manifest = img.blobs[3];
    try eqs(C.fmt("sha256:{s}", .{sha.hex("x")}), sha.digest("x"));
    try eqs(C.fmt(
        "{{\"config\":{{\"digest\":\"{s}\",\"mediaType\":\"application/vnd.oci.image.config.v1+json\",\"size\":{d}}}," ++
            "\"layers\":[{{\"digest\":\"{s}\",\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+gzip\",\"size\":{d}}}," ++
            "{{\"digest\":\"{s}\",\"mediaType\":\"application/vnd.oci.image.layer.v1.tar+gzip\",\"size\":8}}]," ++
            "\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"schemaVersion\":2}}",
        .{ sha.digest(cfg), cfg.len, sha.digest(layer0), layer0.len, sha.digest("layer gz") },
    ), manifest);
    try eqs(C.fmt(
        "{{\"manifests\":[{{\"annotations\":{{\"io.containerd.image.name\":\"docker.io/komira/base:0.1.0\",\"org.opencontainers.image.ref.name\":\"0.1.0\"}}," ++
            "\"digest\":\"{s}\",\"mediaType\":\"application/vnd.oci.image.manifest.v1+json\",\"platform\":{{\"architecture\":\"amd64\",\"os\":\"linux\"}},\"size\":{d}}}]," ++
            "\"mediaType\":\"application/vnd.oci.image.index.v1+json\",\"schemaVersion\":2}}",
        .{ sha.digest(manifest), manifest.len },
    ), img.index);
    const fs = P.files(img);
    const blob = struct {
        fn f(b: []const u8) []const u8 {
            return C.fmt("blobs/sha256/{s}", .{sha.hex(b)});
        }
    }.f;
    const want = [_]P.File{
        .{ .path = blob(layer0), .data = layer0 },
        .{ .path = blob("layer gz"), .data = "layer gz" },
        .{ .path = blob(cfg), .data = cfg },
        .{ .path = blob(manifest), .data = manifest },
        .{ .path = "oci-layout", .data = "{\"imageLayoutVersion\":\"1.0.0\"}" },
        .{ .path = "index.json", .data = img.index },
    };
    try std.testing.expectEqual(want.len, fs.layout.len);
    for (want, fs.layout) |w, g| {
        try eqs(w.path, g.path);
        try eqs(w.data, g.data);
    }
    // The archive: the layout, its two directories and Docker's manifest.json,
    // each with its own mode.
    var wanted = C.list(T.Item);
    for (want) |w| C.push(T.Item, &wanted, .{ .path = w.path, .mode = 0o644, .data = w.data });
    C.push(T.Item, &wanted, .{ .path = "blobs/", .mode = 0o755, .data = "" });
    C.push(T.Item, &wanted, .{ .path = "blobs/sha256/", .mode = 0o755, .data = "" });
    C.push(T.Item, &wanted, .{ .path = "manifest.json", .mode = 0o644, .data = img.docker_manifest });
    const got = C.a().dupe(T.Item, fs.items) catch C.oom();
    const lt = struct {
        fn f(_: void, x: T.Item, y: T.Item) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.f;
    std.mem.sort(T.Item, got, {}, lt);
    std.mem.sort(T.Item, wanted.items, {}, lt);
    try std.testing.expectEqual(wanted.items.len, got.len);
    for (wanted.items, got) |w, g| {
        try eqs(w.path, g.path);
        try std.testing.expectEqual(w.mode, g.mode);
        try eqs(w.data, g.data);
    }
}

test "pack: write_lays_every_file_and_names_what_it_cannot_write" {
    const img = try F.ok(P.image(base(), "layer tar", "layer gz", named()));
    const d = D.scratch("pack", "write");
    const out = D.path(d, "out");
    const archive = D.path(d, "archive.tar");
    const digest = D.path(d, "digest");
    try F.ok(P.write(img, out, archive, digest));
    const fs = P.files(img);
    for (fs.layout) |f| try eqs(f.data, D.read(D.path(out, f.path)));
    try std.testing.expectEqualSlices(u8, try F.ok(T.write(fs.items)), D.read(archive));
    try eqs(C.fmt("{s}\n", .{img.manifest_digest}), D.read(digest));
    // Each target that cannot be written is named.
    try F.expectFailPrefix(P.write(img, archive, D.path(d, "a2"), D.path(d, "d2")), C.fmt("cannot create {s}: ", .{archive}));
    const out3 = D.path(d, "out3");
    const blocked = D.path(out3, C.fmt("blobs/sha256/{s}", .{sha.hex(img.blobs[3])}));
    D.mkdirAll(blocked);
    try F.expectFailPrefix(P.write(img, out3, D.path(d, "a3"), D.path(d, "d3")), C.fmt("cannot write {s}: ", .{blocked}));
    D.mkdirAll(D.path(d, "a4"));
    try F.expectFailPrefix(P.write(img, D.path(d, "out4"), D.path(d, "a4"), D.path(d, "d4")), C.fmt("cannot write {s}: ", .{D.path(d, "a4")}));
    D.mkdirAll(D.path(d, "d5"));
    try F.expectFailPrefix(P.write(img, D.path(d, "out5"), D.path(d, "a5"), D.path(d, "d5")), C.fmt("cannot write {s}: ", .{D.path(d, "d5")}));
}

test "pack: names_are_plain_and_repositories_normalized" {
    try eqs("docker.io/library/hello", P.normalizedRepo("hello"));
    try eqs("docker.io/komira/base", P.normalizedRepo("komira/base"));
    try eqs("ghcr.io/a/b", P.normalizedRepo("ghcr.io/a/b"));
    try eqs("localhost/a", P.normalizedRepo("localhost/a"));
    // A first component with a `:` (a port) or a `.` is a registry.
    try eqs("host:5000/a", P.normalizedRepo("host:5000/a"));
    try eqs("a.b/c", P.normalizedRepo("a.b/c"));
    // Each of the four marks is plain on its own; others are not.
    for ([_][]const u8{ "a_b", "a.b", "a+b", "a-b" }) |x| try eqs(x, try F.ok(P.plain(x, "name", "")));
    for ([_][]const u8{ "a/b", "a:b", "a~b", "a@b" }) |x| try F.expectFailPrefix(P.plain(x, "name", ""), "");
    try eqs("0.1.0~rc1", try F.ok(P.plain("0.1.0~rc1", "version", "~")));
    try F.expectFail(P.plain("a b", "name", ""), "name `a b` holds ` `");
    try F.expectFail(P.plain("", "name", ""), "name is empty");
}
