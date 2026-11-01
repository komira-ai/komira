//! The small package actions of tools/build/package (defs.bzl, conda.bzl), in
//! place of their busybox scripts: the OCI release manifest of an image, the
//! launcher's level test run, and the directory copy of the conda and release-set joins.

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
