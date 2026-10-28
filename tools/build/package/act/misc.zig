//! The small package actions of tools/build/package (defs.bzl, conda.bzl), in
//! place of their busybox scripts: the OCI release manifest of an image, the
//! launcher's level test run, the conda manifest read back by kci's parser,
//! and the directory copy of the conda and release-set joins.

const std = @import("std");
const U = @import("act_util");

/// The artifact manifest of an image (`oci_image[release]`): compact JSON in
/// the key order of kci's `render_artifact_manifest`, one trailing newline.
/// Refuses, naming the reason, a digest that is not `sha256:<64 lowercase
/// hex>`, and a member name that is not a kci artifact name
/// ([a-z][a-z0-9_]*: the release set keys members by it), naming the image,
/// its repository and where the name came from. The version and the layout's
/// name are plain (mojo_bundle, oci_tree and buck2 refuse anything else), so
/// nothing needs escaping.
pub const OciManifest = struct {
    digest_path: []const u8,
    digest: []const u8,
    name: []const u8,
    version: []const u8,
    platform: []const u8,
    file: []const u8,
    label: []const u8,
    repo: []const u8,
    from: []const u8,
};

pub fn ociManifest(a: std.mem.Allocator, out: *U.Out, m: OciManifest) ![]u8 {
    const d = U.trimNewlines(m.digest);
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, d, prefix) or d.len - prefix.len != 64) {
        return refuseOci(out, m, "{s} holds '{s}', not sha256:<64 hex>", .{ m.digest_path, d });
    }
    const hex = d[prefix.len..];
    for (hex) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) {
            return refuseOci(out, m, "{s} holds '{s}', not sha256:<64 lowercase hex>", .{ m.digest_path, d });
        }
    }
    var ok = m.name.len > 0 and m.name[0] >= 'a' and m.name[0] <= 'z';
    for (m.name) |c| {
        if (!((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_')) ok = false;
    }
    if (!ok) return refuseOci(out, m, "member name '{s}' ({s}) is not a kci artifact name ([a-z][a-z0-9_]*)", .{ m.name, m.from });
    return std.fmt.allocPrint(a, "{{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"OCI\",\"name\":\"{s}\",\"version\":\"{s}\",\"platform\":\"{s}\",\"file\":\"{s}\",\"sha256\":\"{s}\"}}\n", .{ m.name, m.version, m.platform, m.file, hex });
}

fn refuseOci(out: *U.Out, m: OciManifest, comptime fmt: []const u8, args: anytype) error{ Refused, OutOfMemory } {
    try out.writer().print("oci_image[release] of {s} (repository {s}): ", .{ m.label, m.repo });
    try out.writer().print(fmt, args);
    try out.append('\n');
    return error.Refused;
}

/// What the conda manifest check requires of the probe's one line: it starts
/// `OK CONDA ` and ends with ` metadata=metadata.json
/// metadata_path=<dir>/metadata.json render-identical=yes`.
pub fn kciLineOk(a: std.mem.Allocator, line: []const u8, dir: []const u8) !bool {
    const want = try std.fmt.allocPrint(a, " metadata=metadata.json metadata_path={s}/metadata.json render-identical=yes", .{dir});
    const head = "OK CONDA ";
    return line.len >= head.len + want.len and std.mem.startsWith(u8, line, head) and std.mem.endsWith(u8, line, want);
}

/// `text` with the first `<dir>/` of each line removed (`sed "s|$DIR/||"`).
pub fn stripDir(a: std.mem.Allocator, text: []const u8, dir: []const u8) ![]u8 {
    const needle = try std.fmt.allocPrint(a, "{s}/", .{dir});
    var b = std.ArrayList(u8).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try b.append(a, '\n');
        first = false;
        if (std.mem.indexOf(u8, line, needle)) |at| {
            try b.appendSlice(a, line[0..at]);
            try b.appendSlice(a, line[at + needle.len ..]);
        } else try b.appendSlice(a, line);
    }
    return b.toOwnedSlice(a);
}

/// The directory an uploader copies is the package, its manifest and its
/// metadata, nothing else: three entries, `manifest.json` a file,
/// `metadata.json` not empty, exactly one name ending `.conda`. Returns null
/// when it is so, else the listing for the refusal.
pub fn condaDirListing(a: std.mem.Allocator, dir_path: []const u8) !?[]u8 {
    var d = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    defer d.close();
    const names = try U.listNames(a, d);
    var conda: usize = 0;
    for (names) |n| {
        if (n.len > 0 and n[0] != '.' and std.mem.endsWith(u8, n, ".conda")) conda += 1;
    }
    const manifest_ok = blk: {
        const st = d.statFile("manifest.json") catch break :blk false;
        break :blk st.kind == .file;
    };
    const metadata_ok = blk: {
        const st = d.statFile("metadata.json") catch break :blk false;
        break :blk st.size > 0;
    };
    if (names.len == 3 and manifest_ok and metadata_ok and conda == 1) return null;
    return try U.spaced(a, names);
}
