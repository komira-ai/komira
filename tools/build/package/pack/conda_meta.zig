//! komira_pack: the `conda-meta` command (the metapackage).

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const pack_conda = @import("conda.zig");
const Args = pack_common.Args;
const Entry = pack_common.Entry;
const all = pack_common.all;
const allow = pack_common.allow;
const fail = pack_common.fail;
const member = pack_common.member;
const memberInt = pack_common.memberInt;
const memberStr = pack_common.memberStr;
const need = pack_common.need;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const one = pack_common.one;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;
const str = pack_common.str;
const aboutAndLicense = pack_conda.aboutAndLicense;
const assembleConda = pack_conda.assembleConda;
const conda_manifest_metadata = pack_conda.conda_manifest_metadata;
const contractManifest = pack_conda.contractManifest;
const emitPackage = pack_conda.emitPackage;
const jsonLine = pack_conda.jsonLine;
const metaRequirements = pack_conda.metaRequirements;
const platformFor = pack_conda.platformFor;
const strArray = pack_conda.strArray;
const validName = pack_conda.validName;

// ---- the metapackage -----------------------------------------------------
//
// A metapackage has no file and requires every member at exactly its version.
// WHICH packages are members is not known to the build system (a Buck rule
// cannot enumerate targets): the release tool passes the members' manifests.

/// A member as its own manifest.json and metadata.json state it, after the
/// package file was read and hashed.
pub const Member = struct {
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

pub fn memberBool(v: json.Value, key: []const u8, what: []const u8) bool {
    const m = member(v, key, what);
    if (m != .bool) fail("{s}: `{s}` is not a boolean", .{ what, key });
    return m.bool;
}

pub fn expectEq(what: []const u8, got: []const u8, want: []const u8) void {
    if (!std.mem.eql(u8, got, want)) fail("{s}: is `{s}`, must be `{s}`", .{ what, got, want });
}

/// The manifest at `path` must be exactly the contract: parsed, then rendered
/// again, it is the same bytes (so the ten keys, their order, the compact
/// form and the newline are all checked at once).
pub fn readContractManifest(alloc: Alloc, path: []const u8) !json.Value {
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

pub fn dirOf(path: []const u8) []const u8 {
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
pub fn readMembers(alloc: Alloc, a: Args) ![]Member {
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
pub fn cmdCondaMeta(alloc: Alloc, a: Args) !void {
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
