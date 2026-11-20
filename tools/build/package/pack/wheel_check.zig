//! komira_wheel check: a wheel's output directory read back from its bytes,
//! and refused unless it is exactly what the rule asked for.
//!
//! What is held, in order:
//!   * the directory holds exactly manifest.json, METADATA and the wheel, and
//!     the manifest is the one `manifest` writes for that wheel (its sha256);
//!   * the wheel's file name is `<dist>-<version>-<tag>.whl`, the version the
//!     compiler version and stamp give;
//!   * the zip reads back (wheel_zip.zig), and no member path is given twice;
//!   * RECORD is the last member and lists every other member exactly once,
//!     with the sha256 and size of its bytes, and itself with neither;
//!   * WHEEL names the tag and says the wheel is not purelib;
//!   * METADATA is the one the pyproject, version and runtime requirements
//!     give, and the METADATA beside the manifest is the same bytes;
//!   * each licence file is at `.dist-info/licenses/<name>`, byte-equal to the
//!     file given, and no other licence member is there; the dist-info holds
//!     nothing but METADATA, WHEEL, RECORD and the licences, and no member is
//!     outside it and the import package;
//!   * `<import>/__init__.py`, `<import>/py.typed` and the native library are
//!     there, the library executable, and no member is one of the runtime
//!     libraries the wheel must not carry;
//!   * with `require_stamped`, the stamp is positive and comes with a source
//!     commit of 40 lowercase hex digits;
//!   * with a twin (the same wheel built again from inputs staged elsewhere),
//!     the two are the same bytes.

const std = @import("std");
const project = @import("wheel_project.zig");
const wheel = @import("wheel.zig");
const zip = @import("wheel_zip.zig");
const sha256Hex = @import("common.zig").sha256Hex;
const Alloc = std.mem.Allocator;
const Diag = project.Diag;
const Project = project.Project;
const Refused = project.Refused;
const refuse = project.refuse;

pub const Expect = struct {
    project: Project,
    readme: []const u8,
    version_base: []const u8,
    stamp: []const u8,
    commit: []const u8,
    tag: []const u8,
    platform: []const u8,
    runtime_requires: []const []const u8,
    import_name: []const u8,
    native_lib: []const u8,
    /// File names no member may have: the Mojo runtime's libraries.
    forbid: []const []const u8,
    licenses: []const wheel.File,
    require_stamped: bool,
};

/// The output directory as read: each file's name and bytes.
pub const Dir = struct {
    names: []const []const u8,
    manifest: []const u8,
    metadata: []const u8,
    wheel_name: []const u8,
    wheel: []const u8,
};

fn find(members: []const zip.Member, name: []const u8) ?zip.Member {
    for (members) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

/// The directory's names must be exactly the three files, in any order.
pub fn checkNames(alloc: Alloc, d: *Diag, names: []const []const u8, wheel_name: []const u8) Refused!void {
    const want = [_][]const u8{ "METADATA", "manifest.json", wheel_name };
    if (names.len != want.len) return refuse(d, alloc, "the directory holds {d} files, not manifest.json, METADATA and {s}", .{ names.len, wheel_name });
    for (want) |w| {
        var n: usize = 0;
        for (names) |x| n += @intFromBool(std.mem.eql(u8, x, w));
        if (n != 1) return refuse(d, alloc, "the directory does not hold `{s}` once", .{w});
    }
}

/// RECORD against the members before it.
pub fn checkRecord(alloc: Alloc, d: *Diag, members: []const zip.Member, info: []const u8) Refused!void {
    const record_path = try std.fmt.allocPrint(alloc, "{s}/RECORD", .{info});
    if (members.len == 0 or !std.mem.eql(u8, members[members.len - 1].name, record_path))
        return refuse(d, alloc, "the last member is not {s}", .{record_path});
    const body = members[0 .. members.len - 1];
    const seen = try alloc.alloc(bool, body.len);
    @memset(seen, false);
    var self = false;
    var lines = std.mem.splitScalar(u8, members[members.len - 1].data, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        n += 1;
        if (line.len == 0) {
            if (lines.peek() == null) break;
            return refuse(d, alloc, "RECORD line {d} is empty", .{n});
        }
        var cols = std.mem.splitScalar(u8, line, ',');
        const path = cols.next().?;
        const hash = cols.next() orelse return refuse(d, alloc, "RECORD line {d} has no hash column", .{n});
        const size = cols.next() orelse return refuse(d, alloc, "RECORD line {d} has no size column", .{n});
        if (cols.next() != null) return refuse(d, alloc, "RECORD line {d} has more than three columns", .{n});
        if (std.mem.eql(u8, path, record_path)) {
            if (self or hash.len != 0 or size.len != 0) return refuse(d, alloc, "RECORD lists itself twice, or with a hash or size", .{});
            self = true;
            continue;
        }
        var idx: ?usize = null;
        for (body, 0..) |m, i| if (std.mem.eql(u8, m.name, path)) {
            idx = i;
        };
        const i = idx orelse return refuse(d, alloc, "RECORD lists `{s}`, which the wheel does not hold", .{path});
        if (seen[i]) return refuse(d, alloc, "RECORD lists `{s}` twice", .{path});
        seen[i] = true;
        const want_hash = try wheel.recordHash(alloc, body[i].data);
        if (!std.mem.eql(u8, hash, want_hash)) return refuse(d, alloc, "RECORD gives `{s}` the hash {s}, but its bytes hash to {s}", .{ path, hash, want_hash });
        const want_size = try std.fmt.allocPrint(alloc, "{d}", .{body[i].data.len});
        if (!std.mem.eql(u8, size, want_size)) return refuse(d, alloc, "RECORD gives `{s}` the size {s}, but it holds {s} bytes", .{ path, size, want_size });
    }
    if (!self) return refuse(d, alloc, "RECORD does not list itself", .{});
    for (body, seen) |m, ok| if (!ok) return refuse(d, alloc, "`{s}` is in the wheel but not in RECORD", .{m.name});
}

/// The wheel's members against what the rule asked for (every point of the
/// module doc but the directory, the manifest and the twin).
pub fn checkMembers(alloc: Alloc, d: *Diag, e: Expect, ver: []const u8, members: []const zip.Member, outside_metadata: []const u8) Refused!void {
    for (members, 0..) |m, i| {
        try wheel.checkPath(alloc, d, m.name);
        for (members[0..i]) |prev| if (std.mem.eql(u8, prev.name, m.name)) return refuse(d, alloc, "`{s}` is in the wheel twice", .{m.name});
        const base = if (std.mem.lastIndexOfScalar(u8, m.name, '/')) |s| m.name[s + 1 ..] else m.name;
        for (e.forbid) |f| if (std.mem.eql(u8, base, f))
            return refuse(d, alloc, "the wheel carries `{s}`, a library of the Mojo runtime, which comes from its own package and never from this wheel", .{m.name});
    }
    const info = try wheel.distInfo(alloc, e.project.name, ver);
    try checkRecord(alloc, d, members, info);

    const wheel_file = find(members, try std.fmt.allocPrint(alloc, "{s}/WHEEL", .{info})) orelse return refuse(d, alloc, "the wheel has no {s}/WHEEL", .{info});
    if (!std.mem.eql(u8, wheel_file.data, try wheel.renderWheel(alloc, e.tag)))
        return refuse(d, alloc, "WHEEL is not the one for the tag {s}:\n{s}", .{ e.tag, wheel_file.data });

    const meta = find(members, try std.fmt.allocPrint(alloc, "{s}/METADATA", .{info})) orelse return refuse(d, alloc, "the wheel has no {s}/METADATA", .{info});
    const want_meta = try wheel.renderMetadata(alloc, e.project, ver, e.runtime_requires, e.readme);
    if (!std.mem.eql(u8, meta.data, want_meta)) return refuse(d, alloc, "METADATA is not the one the pyproject, the version {s} and the runtime requirements give", .{ver});
    if (!std.mem.eql(u8, outside_metadata, meta.data)) return refuse(d, alloc, "the METADATA beside the manifest differs from the wheel's", .{});

    const lic_prefix = try std.fmt.allocPrint(alloc, "{s}/licenses/", .{info});
    for (e.licenses) |l| {
        const m = find(members, try std.fmt.allocPrint(alloc, "{s}{s}", .{ lic_prefix, l.path })) orelse
            return refuse(d, alloc, "the wheel has no licence file {s}{s}", .{ lic_prefix, l.path });
        if (!std.mem.eql(u8, m.data, l.data)) return refuse(d, alloc, "the licence file {s}{s} differs from the one given", .{ lic_prefix, l.path });
    }
    for (members) |m| {
        if (!std.mem.startsWith(u8, m.name, lic_prefix)) continue;
        var known = false;
        for (e.licenses) |l| known = known or std.mem.eql(u8, m.name[lic_prefix.len..], l.path);
        if (!known) return refuse(d, alloc, "the wheel carries the licence member {s}, which no licence file given is", .{m.name});
    }

    // The dist-info holds METADATA, WHEEL, RECORD and the licences, and
    // nothing else (no entry points, no stray file the rule did not write).
    const info_prefix = try std.fmt.allocPrint(alloc, "{s}/", .{info});
    for (members) |m| {
        if (!std.mem.startsWith(u8, m.name, info_prefix) or std.mem.startsWith(u8, m.name, lic_prefix)) continue;
        const rest = m.name[info_prefix.len..];
        if (!std.mem.eql(u8, rest, "METADATA") and !std.mem.eql(u8, rest, "WHEEL") and !std.mem.eql(u8, rest, "RECORD"))
            return refuse(d, alloc, "the wheel carries {s}, which the wheel rule does not write", .{m.name});
    }
    const pkg_prefix = try std.fmt.allocPrint(alloc, "{s}/", .{e.import_name});
    for (members) |m| {
        if (!std.mem.startsWith(u8, m.name, info_prefix) and !std.mem.startsWith(u8, m.name, pkg_prefix))
            return refuse(d, alloc, "the wheel carries {s}, outside {s} and {s}", .{ m.name, pkg_prefix, info_prefix });
    }

    const init = try std.fmt.allocPrint(alloc, "{s}/__init__.py", .{e.import_name});
    if (find(members, init) == null) return refuse(d, alloc, "the wheel has no {s}", .{init});
    const typed = try std.fmt.allocPrint(alloc, "{s}/py.typed", .{e.import_name});
    if (find(members, typed) == null) return refuse(d, alloc, "the wheel has no {s}: the package ships typed", .{typed});
    const lib = try std.fmt.allocPrint(alloc, "{s}/{s}/{s}", .{ e.import_name, wheel.native_dir, e.native_lib });
    const lm = find(members, lib) orelse return refuse(d, alloc, "the wheel has no {s}", .{lib});
    if (lm.mode != 0o755) return refuse(d, alloc, "{s} is not executable (mode {o})", .{ lib, lm.mode });
}

/// The whole check of an output directory, and its twin's wheel if given.
pub fn check(alloc: Alloc, d: *Diag, e: Expect, dir: Dir, twin: ?[]const u8) Refused!void {
    const ver = try wheel.version(alloc, d, e.version_base, e.stamp);
    if (e.require_stamped) {
        if (std.mem.eql(u8, e.stamp, "0")) return refuse(d, alloc, "the wheel is not stamped (version {s}): an unstamped build is a development output, never a release", .{ver});
        if (!isHex40(e.commit)) return refuse(d, alloc, "the stamp {s} comes with no source commit of 40 lowercase hex digits (`{s}`)", .{ e.stamp, e.commit });
    }
    const want_name = try wheel.fileName(alloc, e.project.name, ver, e.tag);
    if (!std.mem.eql(u8, dir.wheel_name, want_name)) return refuse(d, alloc, "the wheel is named {s}, not {s}", .{ dir.wheel_name, want_name });
    try checkNames(alloc, d, dir.names, want_name);
    const want_manifest = try wheel.manifest(alloc, e.project.name, ver, e.platform, want_name, &sha256Hex(dir.wheel));
    if (!std.mem.eql(u8, dir.manifest, want_manifest)) return refuse(d, alloc, "manifest.json is not the manifest of this wheel:\n{s}", .{dir.manifest});
    const members = try zip.read(alloc, d, dir.wheel);
    try checkMembers(alloc, d, e, ver, members, dir.metadata);
    if (twin) |t| {
        if (!std.mem.eql(u8, t, dir.wheel)) return refuse(d, alloc, "the wheel built twice from the same inputs, staged at two paths, is not the same bytes ({d} and {d} bytes): the build is not reproducible", .{ dir.wheel.len, t.len });
    }
}
