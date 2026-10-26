//! The release set of one platform: each member directory checked, the set
//! hash, and `release.json`.
//!
//! This is the format `kci.release_set` major 2, written by the BUILD step of
//! the release machine before it was retired and read by whatever publishes
//! next. It is byte-compatible with that writer.
//!
//! `release.json` is sorted compact JSON (keys bytewise, members bytewise by
//! name), one trailing newline:
//!
//!   {"format":"kci.release_set","members":[{"artifact_type":..,"build":..,
//!    "dir":"<name>","kind":..,"name":..,"platform":..,"sha256":..,
//!    "subdir":..,"version":..}, ...],"platform":"linux-x86_64",
//!    "produced_by":{"attempt":1,"run_id":"gh-123"},"revision":"<40 hex>",
//!    "schema_version":2,"set_hash":"<64 hex>"}
//!
//! The set hash is the sha256, as 64 lowercase hex characters, of the text
//!
//!   release_set TAB 2 TAB <revision> TAB <platform> LF
//!
//! then one line per member (the metapackage included),
//!
//!   <name> TAB <platform> TAB <version> TAB <build> TAB <subdir> TAB
//!   <artifact_type> TAB <sha256> LF
//!
//! the lines sorted bytewise. The revision and the platform are in the hash;
//! who built it (`produced_by`) is not.
//!
//! A member directory (one conda package, as `<lib>_conda[release]` leaves
//! it) holds exactly `manifest.json`, the package file and `metadata.json`,
//! each a regular file and none a symlink. It is refused when:
//!   - the manifest is not `kci.artifact_manifest` major 1 of a CONDA
//!     package named as the directory is, for the release's platform (or
//!     `noarch`), with its platform's conda subdir;
//!   - `file` or `metadata` is not a bare name, or they are one name;
//!   - the package file is empty or its sha256 is not the manifest's;
//!   - the metadata is not `kci.conda_metadata` major 1, or disagrees with
//!     the manifest (name, version, subdir, file name), or its `size` is not
//!     the file's, or it is not `stamped`.
//!
//! Not ported from the retired writer: a second pass over every member that
//! catches a build writing into a sibling's directory (the set is one
//! copied tree, so none does), the requirement closure (every requirement of
//! a library names another library of the set), the OCI and PYTHON member
//! types (this set has only CONDA), and the refusal of a key given twice in
//! a JSON file (std.json keeps the last).
const std = @import("std");
const util = @import("util.zig");

pub const RELEASE_PLATFORM = "linux-x86_64";
pub const SCHEMA_VERSION = 2;
pub const RUN_ID_MAX_BYTES = 63;

pub const Refused = error{Refused};

/// Where a refusal says why.
pub const Ctx = struct {
    a: std.mem.Allocator,
    why: []const u8 = "",
    /// An unstamped package is never released. Only the pull request's check
    /// of an unstamped set (//release:release_set built without a stamp)
    /// turns this off, to hold the real packages to every other check.
    require_stamped: bool = true,

    pub fn fail(self: *Ctx, comptime fmt: []const u8, args: anytype) error{Refused} {
        self.why = std.fmt.allocPrint(self.a, fmt, args) catch "out of memory";
        return error.Refused;
    }
};

pub const Member = struct {
    name: []const u8,
    version: []const u8,
    build: []const u8,
    kind: []const u8,
    platform: []const u8,
    subdir: []const u8,
    artifact_type: []const u8,
    sha256: []const u8,
};

fn safeText(c: u8) bool {
    return c >= 0x20 and c <= 0x7e and c != '"' and c != '\\';
}

/// A field written into the hashed text and the JSON: printable ASCII with no
/// quote or backslash (so no TAB or LF either), and not empty.
fn checkField(ctx: *Ctx, name: []const u8, what: []const u8, v: []const u8) !void {
    if (v.len == 0) return ctx.fail("artifact '{s}': {s} is empty", .{ name, what });
    for (v) |c| if (!safeText(c)) {
        return ctx.fail("artifact '{s}': {s} '{s}' holds a byte outside printable ASCII, or a quote or backslash", .{ name, what, v });
    };
}

fn condaSubdir(platform: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, platform, RELEASE_PLATFORM)) return "linux-64";
    if (std.mem.eql(u8, platform, "noarch")) return "noarch";
    return null;
}

fn objectOf(ctx: *Ctx, name: []const u8, file: []const u8, v: std.json.Value) !std.json.ObjectMap {
    if (v != .object) return ctx.fail("artifact '{s}': {s} is not a JSON object", .{ name, file });
    return v.object;
}

fn strOf(ctx: *Ctx, name: []const u8, file: []const u8, o: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const v = o.get(key) orelse return ctx.fail("artifact '{s}': {s} has no '{s}'", .{ name, file, key });
    if (v != .string) return ctx.fail("artifact '{s}': {s}: '{s}' is not a string", .{ name, file, key });
    return v.string;
}

fn intOf(ctx: *Ctx, name: []const u8, file: []const u8, o: std.json.ObjectMap, key: []const u8) !i64 {
    const v = o.get(key) orelse return ctx.fail("artifact '{s}': {s} has no '{s}'", .{ name, file, key });
    if (v != .integer) return ctx.fail("artifact '{s}': {s}: '{s}' is not an integer", .{ name, file, key });
    return v.integer;
}

fn bare(ctx: *Ctx, name: []const u8, key: []const u8, v: []const u8) !void {
    if (std.mem.indexOfScalar(u8, v, '/') != null or std.mem.eql(u8, v, ".") or std.mem.eql(u8, v, "..") or v.len == 0) {
        return ctx.fail("artifact '{s}': the manifest's '{s}' is '{s}', not a file name in the artifact's directory", .{ name, key, v });
    }
    if (std.mem.eql(u8, v, "manifest.json")) {
        return ctx.fail("artifact '{s}': the manifest's '{s}' names the manifest itself", .{ name, key });
    }
}

fn parseJson(ctx: *Ctx, name: []const u8, file: []const u8, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, ctx.a, text, .{}) catch |e| {
        return ctx.fail("artifact '{s}': {s} is not JSON: {s}", .{ name, file, @errorName(e) });
    };
}

/// Check the member directory `name` of `release_dir` (file header) and
/// return what it holds.
pub fn verifyMember(ctx: *Ctx, release_dir: std.fs.Dir, name: []const u8, release_platform: []const u8) !Member {
    const a = ctx.a;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (release_dir.readLink(name, &link_buf)) |_| {
        return ctx.fail("artifact '{s}': it is a symlink, not a directory: a link can name bytes outside the release directory", .{name});
    } else |e| switch (e) {
        error.NotLink => {},
        error.FileNotFound => return ctx.fail("artifact '{s}': it is not in the release directory", .{name}),
        else => return ctx.fail("artifact '{s}': cannot be read: {s}", .{ name, @errorName(e) }),
    }
    var dir = release_dir.openDir(name, .{ .iterate = true, .no_follow = true }) catch |e| {
        return ctx.fail("artifact '{s}': cannot be opened as a directory: {s}", .{ name, @errorName(e) });
    };
    defer dir.close();
    var entries = std.ArrayList([]const u8).empty;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file) {
            return ctx.fail("artifact '{s}': the directory's '{s}' is not a regular file (a {s}): the directory holds regular files only, and a link can name bytes outside the release directory", .{ name, e.name, @tagName(e.kind) });
        }
        try entries.append(a, try a.dupe(u8, e.name));
    }

    const manifest_text = dir.readFileAlloc(a, "manifest.json", 1 << 20) catch {
        return ctx.fail("artifact '{s}': the build left no manifest.json", .{name});
    };
    const m = try objectOf(ctx, name, "manifest.json", try parseJson(ctx, name, "manifest.json", manifest_text));
    const format = try strOf(ctx, name, "manifest.json", m, "format");
    if (!std.mem.eql(u8, format, "kci.artifact_manifest")) {
        return ctx.fail("artifact '{s}': manifest.json is format '{s}', not kci.artifact_manifest", .{ name, format });
    }
    if (try intOf(ctx, name, "manifest.json", m, "schema_version") != 1) {
        return ctx.fail("artifact '{s}': manifest.json is not schema_version 1", .{name});
    }
    const artifact_type = try strOf(ctx, name, "manifest.json", m, "artifact_type");
    if (!std.mem.eql(u8, artifact_type, "CONDA")) {
        return ctx.fail("artifact '{s}': artifact_type '{s}': this set has CONDA members only", .{ name, artifact_type });
    }
    const mname = try strOf(ctx, name, "manifest.json", m, "name");
    if (!std.mem.eql(u8, mname, name)) {
        return ctx.fail("artifact '{s}': the built manifest's name '{s}' is not the artifact's name (compared exactly)", .{ name, mname });
    }
    const version = try strOf(ctx, name, "manifest.json", m, "version");
    const platform = try strOf(ctx, name, "manifest.json", m, "platform");
    if (!std.mem.eql(u8, platform, release_platform) and !std.mem.eql(u8, platform, "noarch")) {
        return ctx.fail("artifact '{s}': platform '{s}' is neither the release's '{s}' nor 'noarch'", .{ name, platform, release_platform });
    }
    const subdir = try strOf(ctx, name, "manifest.json", m, "subdir");
    const want_subdir = condaSubdir(platform) orelse "";
    if (!std.mem.eql(u8, subdir, want_subdir)) {
        return ctx.fail("artifact '{s}': subdir '{s}' is not platform {s}'s conda subdir '{s}'", .{ name, subdir, platform, want_subdir });
    }
    const file = try strOf(ctx, name, "manifest.json", m, "file");
    const metadata = try strOf(ctx, name, "manifest.json", m, "metadata");
    const sha = try strOf(ctx, name, "manifest.json", m, "sha256");
    if (!util.isSha256Hex(sha)) return ctx.fail("artifact '{s}': the manifest's sha256 is not 64 lowercase hex characters", .{name});
    try bare(ctx, name, "file", file);
    try bare(ctx, name, "metadata", metadata);
    if (std.mem.eql(u8, file, metadata)) {
        return ctx.fail("artifact '{s}': the manifest's 'file' and 'metadata' are the same name '{s}'", .{ name, file });
    }
    for (entries.items) |entry| {
        if (!std.mem.eql(u8, entry, "manifest.json") and !std.mem.eql(u8, entry, file) and !std.mem.eql(u8, entry, metadata)) {
            return ctx.fail("artifact '{s}': the directory holds '{s}', which its manifest does not name; it holds exactly manifest.json, the file and the metadata", .{ name, entry });
        }
    }

    const data = dir.readFileAlloc(a, file, 1 << 31) catch {
        return ctx.fail("artifact '{s}': its file '{s}' is not in the directory", .{ name, file });
    };
    if (data.len == 0) return ctx.fail("artifact '{s}': its file '{s}' is EMPTY", .{ name, file });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, sha)) {
        return ctx.fail("artifact '{s}': the sha256 of '{s}' is {s} but its manifest says {s}", .{ name, file, &actual, sha });
    }

    const meta_text = dir.readFileAlloc(a, metadata, 1 << 24) catch {
        return ctx.fail("artifact '{s}': its metadata '{s}' is not in the directory", .{ name, metadata });
    };
    const md = try objectOf(ctx, name, metadata, try parseJson(ctx, name, metadata, meta_text));
    const mformat = try strOf(ctx, name, metadata, md, "format");
    if (!std.mem.eql(u8, mformat, "kci.conda_metadata")) {
        return ctx.fail("artifact '{s}': {s} is format '{s}', not kci.conda_metadata", .{ name, metadata, mformat });
    }
    if (try intOf(ctx, name, metadata, md, "schema_version") != 1) {
        return ctx.fail("artifact '{s}': {s} is not schema_version 1", .{ name, metadata });
    }
    const kind = try strOf(ctx, name, metadata, md, "kind");
    if (!std.mem.eql(u8, kind, "library") and !std.mem.eql(u8, kind, "metapackage")) {
        return ctx.fail("artifact '{s}': {s}: kind '{s}' is neither library nor metapackage", .{ name, metadata, kind });
    }
    const agree = [_][2][]const u8{
        .{ "name", mname },
        .{ "version", version },
        .{ "subdir", subdir },
        .{ "file_name", file },
    };
    for (agree) |kv| {
        const got = try strOf(ctx, name, metadata, md, kv[0]);
        if (!std.mem.eql(u8, got, kv[1])) {
            return ctx.fail("artifact '{s}': its metadata says {s} '{s}' but its manifest says '{s}'", .{ name, kv[0], got, kv[1] });
        }
    }
    if (try intOf(ctx, name, metadata, md, "size") != @as(i64, @intCast(data.len))) {
        return ctx.fail("artifact '{s}': its metadata says size {d} but '{s}' is {d} bytes", .{ name, try intOf(ctx, name, metadata, md, "size"), file, data.len });
    }
    const stamped = md.get("stamped") orelse return ctx.fail("artifact '{s}': {s} has no 'stamped'", .{ name, metadata });
    if (stamped != .bool) return ctx.fail("artifact '{s}': {s}: 'stamped' is not a boolean", .{ name, metadata });
    if (ctx.require_stamped and !stamped.bool) {
        return ctx.fail("artifact '{s}': its metadata says stamped is not true; an unstamped package is never released", .{name});
    }
    const build = try strOf(ctx, name, metadata, md, "build");

    const member = Member{
        .name = name,
        .version = version,
        .build = build,
        .kind = kind,
        .platform = platform,
        .subdir = subdir,
        .artifact_type = artifact_type,
        .sha256 = sha,
    };
    try checkField(ctx, name, "name", member.name);
    try checkField(ctx, name, "version", member.version);
    try checkField(ctx, name, "build", member.build);
    try checkField(ctx, name, "kind", member.kind);
    try checkField(ctx, name, "platform", member.platform);
    try checkField(ctx, name, "subdir", member.subdir);
    return member;
}

fn lessBytes(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.order(u8, x, y) == .lt;
}

fn lessName(_: void, x: Member, y: Member) bool {
    return std.mem.order(u8, x.name, y.name) == .lt;
}

/// The text the set hash is taken of (file header).
pub fn setHashText(a: std.mem.Allocator, revision: []const u8, platform: []const u8, members: []const Member) ![]const u8 {
    const lines = try a.alloc([]const u8, members.len);
    for (members, lines) |m, *l| {
        l.* = try std.fmt.allocPrint(a, "{s}\t{s}\t{s}\t{s}\t{s}\t{s}\t{s}\n", .{ m.name, m.platform, m.version, m.build, m.subdir, m.artifact_type, m.sha256 });
    }
    std.mem.sort([]const u8, lines, {}, lessBytes);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, try std.fmt.allocPrint(a, "release_set\t{d}\t{s}\t{s}\n", .{ SCHEMA_VERSION, revision, platform }));
    for (lines) |l| try out.appendSlice(a, l);
    return out.items;
}

pub fn setHash(a: std.mem.Allocator, revision: []const u8, platform: []const u8, members: []const Member) ![]const u8 {
    const text = try setHashText(a, revision, platform, members);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower));
}

pub const Identity = struct {
    revision: []const u8,
    platform: []const u8,
    run_id: []const u8,
    attempt: u32,
};

/// The identity's refusals: a full commit id, the released platform, a run id
/// of [a-z0-9_-] up to 63 bytes, an attempt that is a positive number.
pub fn checkIdentity(ctx: *Ctx, id: Identity) !void {
    if (!util.isFullCommitId(id.revision)) return ctx.fail("--revision '{s}' is not a full commit id (40 lowercase hex)", .{id.revision});
    if (!std.mem.eql(u8, id.platform, RELEASE_PLATFORM)) return ctx.fail("--platform '{s}' is not a platform released ({s})", .{ id.platform, RELEASE_PLATFORM });
    if (id.run_id.len == 0 or id.run_id.len > RUN_ID_MAX_BYTES) return ctx.fail("--run-id is {d} bytes; 1 to {d}", .{ id.run_id.len, RUN_ID_MAX_BYTES });
    for (id.run_id) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return ctx.fail("--run-id '{s}' holds a byte outside [a-z0-9_-] (label-safe ids only)", .{id.run_id});
    }
    if (id.attempt == 0) return ctx.fail("--attempt is not a positive number", .{});
}

/// `release.json`'s text for `members` (any order) built under `id`.
pub fn renderReleaseJson(ctx: *Ctx, id: Identity, members_in: []const Member) ![]const u8 {
    const a = ctx.a;
    try checkIdentity(ctx, id);
    if (members_in.len == 0) return ctx.fail("release set hash: the set is EMPTY", .{});
    const members = try a.dupe(Member, members_in);
    std.mem.sort(Member, members, {}, lessName);
    for (members, 0..) |m, i| {
        if (i > 0 and std.mem.eql(u8, members[i - 1].name, m.name)) return ctx.fail("member '{s}' is given twice", .{m.name});
        if (!util.isSha256Hex(m.sha256)) return ctx.fail("artifact '{s}': sha256 is not 64 lowercase hex characters", .{m.name});
    }
    const hash = try setHash(a, id.revision, id.platform, members);
    var out = std.ArrayList(u8).empty;
    try out.appendSlice(a, "{\"format\":\"kci.release_set\",\"members\":[");
    for (members, 0..) |m, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, try std.fmt.allocPrint(a, "{{\"artifact_type\":\"{s}\",\"build\":\"{s}\",\"dir\":\"{s}\",\"kind\":\"{s}\",\"name\":\"{s}\",\"platform\":\"{s}\",\"sha256\":\"{s}\",\"subdir\":\"{s}\",\"version\":\"{s}\"}}", .{
            m.artifact_type, m.build, m.name, m.kind, m.name, m.platform, m.sha256, m.subdir, m.version,
        }));
    }
    try out.appendSlice(a, try std.fmt.allocPrint(a, "],\"platform\":\"{s}\",\"produced_by\":{{\"attempt\":{d},\"run_id\":\"{s}\"}},\"revision\":\"{s}\",\"schema_version\":{d},\"set_hash\":\"{s}\"}}\n", .{
        id.platform, id.attempt, id.run_id, id.revision, SCHEMA_VERSION, hash,
    }));
    return out.items;
}

/// Check every directory of `release_dir` against `names` (the artifact
/// names, in order): the directory holds those and nothing else, and each is
/// a valid member. Returns the members in `names` order.
pub fn verifySet(ctx: *Ctx, release_dir: std.fs.Dir, names: []const []const u8, platform: []const u8) ![]Member {
    const a = ctx.a;
    var present = std.ArrayList([]const u8).empty;
    var it = release_dir.iterate();
    while (try it.next()) |e| try present.append(a, try a.dupe(u8, e.name));
    for (present.items) |p| {
        var declared = false;
        for (names) |n| {
            if (std.mem.eql(u8, n, p)) declared = true;
        }
        if (!declared) return ctx.fail("the release directory holds '{s}', which no artifact declares: it holds exactly the declared member directories", .{p});
    }
    var members = std.ArrayList(Member).empty;
    for (names) |n| {
        try members.append(a, try verifyMember(ctx, release_dir, n, platform));
    }
    return members.items;
}
