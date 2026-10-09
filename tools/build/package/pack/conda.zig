//! komira_pack: the conda v2 package format (zstd raw blocks, a stored zip, the
//! tar reader), names and requirements, and the `conda` command.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const pack_conda_meta = @import("conda_meta.zig");
const Args = pack_common.Args;
const Entry = pack_common.Entry;
const all = pack_common.all;
const allow = pack_common.allow;
const fail = pack_common.fail;
const lessEntry = pack_common.lessEntry;
const lessStr = pack_common.lessStr;
const need = pack_common.need;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const one = pack_common.one;
const plain = pack_common.plain;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;
const str = pack_common.str;
const writeFile = pack_common.writeFile;
const writeSorted = pack_common.writeSorted;
const writeTar = pack_common.writeTar;
const Member = pack_conda_meta.Member;

// ---- conda ---------------------------------------------------------------
//
// One Mojo package as a conda v2 package. The layout, and why each choice,
// is in packaging/conda/README.md.

const conda_subdir = "linux-64";
/// The kci platform of `conda_subdir` (kci_api's platform table, which
/// the manifest probe holds this to: kci refuses a manifest whose platform
/// and subdir disagree).
const conda_platform = "linux-x86_64";
pub const conda_metadata = "{\"conda_pkg_format_version\":2}";
const mojo_conda_name = "mojo-compiler";
pub const payload_dir = "lib/mojo/";
/// Where a package's documentation is installed: share/doc/<conda name>/.
const doc_dir = "share/doc/";
pub const license_member = "info/licenses/LICENSE";
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

pub fn zstdDecode(alloc: Alloc, data: []const u8, what: []const u8) []u8 {
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
pub fn readZip(alloc: Alloc, z: []const u8, what: []const u8) ![]ZipMember {
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

pub const TarFile = struct { name: []const u8, mode: u32, data: []const u8 };

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
pub fn readTar(alloc: Alloc, t: []const u8, what: []const u8) ![]TarFile {
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

pub fn findTar(files: []const TarFile, name: []const u8) ?TarFile {
    for (files) |f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}


// ---- names, versions, requirements ---------------------------------------

/// A conda name this repository writes: a lowercase letter, then lowercase
/// letters, digits and `_`. Compared exactly, never folded (`komira_json` and
/// `komira-json` are two names in a channel). Which names are PUBLISHED is not
/// decided here: the artifact declarations of the release tool say so.
pub fn validName(n: []const u8) bool {
    if (n.len == 0 or !std.ascii.isLower(n[0])) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// A Mojo import name: what the `.mojoc` is called.
fn validImport(n: []const u8) bool {
    if (n.len == 0 or std.ascii.isDigit(n[0])) return false;
    for (n) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// A full git commit id: 40 lowercase hex digits.
pub fn fullCommit(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
    return true;
}

fn decimal(s: []const u8) bool {
    if (s.len == 0 or s.len > 9 or (s.len > 1 and s[0] == '0')) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The version of every package: the Mojo compiler version they are built
/// with, pinned by the platform table, so a conda version: it starts with a digit and holds
/// letters, digits, `.`, `_` and `+` only (a `-` would make the file name
/// ambiguous).
pub fn compilerVersion(v: []const u8) []const u8 {
    if (v.len == 0 or !std.ascii.isDigit(v[0])) fail("compiler version `{s}` does not start with a digit", .{v});
    for (v) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '+')) fail("compiler version `{s}` holds `{c}`", .{ v, c });
    return v;
}

/// The build string of a release: `h<first 8 hex of the source commit>_<N>`,
/// N the build number. An unstamped build (N is 0, no commit) is
/// `h00000000_0`. Two builds of one name and version differ in N, and in the
/// commit they came from, so the string names both.
pub fn buildString(alloc: Alloc, commit: []const u8, number: i64) ![]const u8 {
    const head: []const u8 = if (commit.len >= 8) commit[0..8] else "00000000";
    return std.fmt.allocPrint(alloc, "h{s}_{d}", .{ head, number });
}

fn guardFor(subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, conda_subdir)) return "__linux";
    fail("subdir `{s}`: this tool writes {s} only (an arm64 or macOS package needs its own payload and guard)", .{ subdir, conda_subdir });
}

/// The run requirements of a library, in the order they are written and
/// checked: the platform guard, the exact Mojo pin, then each direct
/// dependency at this version AND this build string (`name ==V BUILD`), sorted.
/// Every package of a release is lockstep, so a dependency's build string is
/// this package's. Direct dependencies only: the solver's closure is the
/// build's.
pub fn runRequirements(alloc: Alloc, subdir: []const u8, pin: []const u8, version: []const u8, build: []const u8, deps: []const []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    try list.append(try std.fmt.allocPrint(alloc, "{s} =={s}", .{ mojo_conda_name, pin }));
    const sorted = try alloc.dupe([]const u8, deps);
    std.mem.sort([]const u8, sorted, {}, lessStr);
    for (sorted) |d| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s} {s}", .{ d, version, build }));
    return list.toOwnedSlice();
}

/// The run requirements of the metapackage: the platform guard, then every
/// member at exactly its version and build string, sorted by name. No compiler
/// pin: the members carry it.
pub fn metaRequirements(alloc: Alloc, subdir: []const u8, members: []const Member) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.append(guardFor(subdir));
    for (members) |m| try list.append(try std.fmt.allocPrint(alloc, "{s} =={s} {s}", .{ m.name, m.version, m.build }));
    return list.toOwnedSlice();
}

pub fn strArray(alloc: Alloc, items: []const []const u8) !json.Value {
    var arr = newArray(alloc);
    for (items) |s| try arr.array.append(str(s));
    return arr;
}

pub fn jsonLine(alloc: Alloc, v: json.Value) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    try writeSorted(alloc, v, out.writer());
    try out.append('\n');
    return out.toOwnedSlice();
}

/// Null if no source under `dir_path` opens a shared library by name at run
/// time; otherwise why this tool cannot package the library. Such a package
/// needs the conda package that ships the shared library in its run
/// requirements, and this tool does not derive that yet, so it says so instead
/// of publishing a package that fails on a clean machine.
fn dlopenReason(alloc: Alloc, dir_path: []const u8) !?[]const u8 {
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
            return try std.fmt.allocPrint(alloc, "{s}: opens a shared library at run time (OwnedDLHandle); its conda package must depend on the package shipping that library, which this tool does not derive yet", .{w.path});
    }
    if (files == 0) fail("sources {s} hold no .mojo file", .{dir_path});
    return null;
}

/// The source commit of a stamp (--commit): empty only for an unstamped build.
fn commitOf(a: Args, stamp: []const u8) []const u8 {
    const commit = one(a, "--commit") orelse "";
    if (commit.len != 0 and !fullCommit(commit)) fail("--commit `{s}` is not a full lowercase 40-digit hex commit id", .{commit});
    if (!std.mem.eql(u8, stamp, "0") and commit.len == 0) fail("a stamped package (N={s}) must carry --commit, the commit its stamp was derived from", .{stamp});
    return commit;
}

/// A documentation file of a library package (`--doc-file <rel>=<file>`): its
/// path in the package, share/doc/<name>/<rel>, and its bytes.
pub const DocFile = struct { path: []const u8, data: []const u8 };

pub fn lessDoc(_: void, x: DocFile, y: DocFile) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// The `--doc-file` values, placed under share/doc/<name>/ and sorted by path.
/// <rel> is relative, made of `/`-separated components that are neither empty
/// nor `.` nor `..`, in letters, digits and `_.-`; the whole path fits a plain
/// tar name (100 bytes), since conda-check reads no extended header. The same
/// path twice is refused. The bytes are read here; each is installed mode 0644.
pub fn docFiles(alloc: Alloc, a: Args, name: []const u8) ![]DocFile {
    var list = std.ArrayList(DocFile).init(alloc);
    for (try all(alloc, a, "--doc-file")) |df| {
        const eq = std.mem.indexOfScalar(u8, df, '=') orelse fail("--doc-file `{s}` is not <relative path>=<file>", .{df});
        const rel = df[0..eq];
        if (rel.len == 0) fail("--doc-file `{s}` names no path", .{df});
        var parts = std.mem.splitScalar(u8, rel, '/');
        while (parts.next()) |c| {
            if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, ".."))
                fail("--doc-file path `{s}` must be relative, with no empty, `.` or `..` component", .{rel});
        }
        for (rel) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '-' or c == '/'))
                fail("--doc-file path `{s}` holds `{c}`", .{ rel, c });
        }
        const path = try std.fmt.allocPrint(alloc, "{s}{s}/{s}", .{ doc_dir, name, rel });
        if (path.len > 100) fail("--doc-file path `{s}` is {d} bytes; it must fit 100", .{ path, path.len });
        for (list.items) |d| if (std.mem.eql(u8, d.path, path)) fail("--doc-file {s} given twice", .{rel});
        try list.append(.{ .path = path, .data = readAll(alloc, df[eq + 1 ..]) });
    }
    const docs = try list.toOwnedSlice();
    std.mem.sort(DocFile, docs, {}, lessDoc);
    return docs;
}

/// The `paths.json` row of one installed file.
fn pathRow(alloc: Alloc, path: []const u8, data: []const u8) !json.Value {
    var row = newObject(alloc);
    try row.object.put("_path", str(path));
    try row.object.put("path_type", str("hardlink"));
    try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(data))));
    try row.object.put("size_in_bytes", .{ .integer = @intCast(data.len) });
    return row;
}

/// The info/ entries every package carries besides index.json and paths.json:
/// about.json, and the licence given as `--extra-file info/licenses/LICENSE=F`.
pub fn aboutAndLicense(alloc: Alloc, a: Args, info_entries: *std.ArrayList(Entry)) !void {
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
pub fn assembleConda(alloc: Alloc, stem: []const u8, pkg_entries: []Entry, info_entries: []Entry) ![]u8 {
    const pkg_tar = try writeTar(alloc, pkg_entries);
    const info_tar = try writeTar(alloc, info_entries);
    const members = [_]ZipMember{
        .{ .name = "metadata.json", .data = conda_metadata },
        .{ .name = try std.fmt.allocPrint(alloc, "pkg-{s}.tar.zst", .{stem}), .data = try zstdRaw(alloc, pkg_tar) },
        .{ .name = try std.fmt.allocPrint(alloc, "info-{s}.tar.zst", .{stem}), .data = try zstdRaw(alloc, info_tar) },
    };
    return zipStored(alloc, &members);
}

// ---- the output directory and the manifest contract ----------------------
//
// Every package is written as one DIRECTORY (--out-dir):
//
//   <name>-<version>-<build>.conda   the package; this is the name the channel
//                              carries. <version> is the Mojo compiler version,
//                              <build> is `h<8 hex of the source commit>_<N>`
//   manifest.json              the artifact manifest, exactly the contract of
//                              kci's `kci_artifact_manifest`: ten keys,
//                              compact, in this order, one trailing newline:
//                                format (`kci.artifact_manifest`),
//                                schema_version (the integer 1), artifact_type
//                                (`CONDA`), name, version, platform (the kci
//                                platform of the subdir: `linux-x86_64`),
//                                subdir, file (the package's name above,
//                                relative to the manifest), sha256 (of that
//                                file), metadata (`metadata.json`, the file
//                                below)
//   metadata.json              everything else the build knows (sorted compact
//                              JSON): format (`kci.conda_metadata`),
//                              schema_version (1), kind, build, build_number,
//                              size, depends, mojo_pin, source_commit, stamped,
//                              timestamp_ms, label, payload_path,
//                              payload_sha256, ...
//
// The format names and majors are kci's (kci_api's format table). Nothing
// run-specific (a run id, an attempt) is written here: these files are action
// outputs, and a per-run value would make every run a cache miss.
//
// The manifest names metadata.json as a bare file name: kci's parser requires
// `metadata` on a CONDA artifact and refuses one that is not a file next to
// the manifest, so copying the directory cannot separate the two. The probe
// //tools/build/package/manifest_probe:conda_manifest_kci runs kci's parser
// over a package this tool wrote, so the two cannot drift apart.
//
// A library the tool cannot package (native code, no tests, a dependency with
// no package, a run-time shared library) is written as a directory holding one
// file, REFUSED, whose text is the reason. That is a value, not an error, so a
// build of every target in the repository still succeeds; asking for the
// package's release is what fails (`conda-check --require-stamped`).

fn openOut(a: Args) std.fs.Dir {
    const p = need(one(a, "--out-dir"), "--out-dir");
    std.fs.cwd().makePath(p) catch |err| fail("cannot create {s}: {s}", .{ p, @errorName(err) });
    return std.fs.cwd().openDir(p, .{}) catch |err| fail("cannot open {s}: {s}", .{ p, @errorName(err) });
}

fn writeRefusal(alloc: Alloc, a: Args, why: []const u8) !void {
    if (why.len == 0) fail("a refusal needs its reason", .{});
    var d = openOut(a);
    defer d.close();
    try writeFile(d, "REFUSED", try std.fmt.allocPrint(alloc, "{s}\n", .{why}));
}

/// The contract manifest, byte for byte what kci's `render_artifact_manifest`
/// writes for a CONDA artifact (its key order: `metadata` last).
/// The metadata file a CONDA manifest names: next to it, under this name.
pub const conda_manifest_metadata = "metadata.json";

/// The kci platform of a conda subdir this tool writes (only `conda_subdir`).
pub fn platformFor(subdir: []const u8) []const u8 {
    if (std.mem.eql(u8, subdir, conda_subdir)) return conda_platform;
    fail("subdir `{s}`: this tool writes {s} only, whose kci platform is {s}", .{ subdir, conda_subdir, conda_platform });
}

pub fn contractManifest(alloc: Alloc, name: []const u8, version: []const u8, subdir: []const u8, file: []const u8, sha: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(alloc);
    const w = out.writer();
    try w.writeAll("{\"format\":\"kci.artifact_manifest\",\"schema_version\":1,\"artifact_type\":\"CONDA\"");
    const vals = [_][2][]const u8{ .{ "name", name }, .{ "version", version }, .{ "platform", platformFor(subdir) }, .{ "subdir", subdir }, .{ "file", file }, .{ "sha256", sha }, .{ "metadata", conda_manifest_metadata } };
    for (vals) |kv| {
        try w.writeAll(",\"");
        try w.writeAll(kv[0]);
        try w.writeAll("\":");
        try json.encodeJsonString(kv[1], .{}, w);
    }
    try w.writeAll("}\n");
    return out.toOwnedSlice();
}

pub fn emitPackage(alloc: Alloc, a: Args, stem: []const u8, conda: []const u8, name: []const u8, version: []const u8, build: []const u8, number: i64, subdir: []const u8, metadata: *json.Value) !void {
    const conda_sha = sha256Hex(conda);
    const file = try std.fmt.allocPrint(alloc, "{s}.conda", .{stem});
    try metadata.object.put("build", str(build));
    try metadata.object.put("build_number", .{ .integer = number });
    try metadata.object.put("file_name", str(file));
    try metadata.object.put("name", str(name));
    try metadata.object.put("format", str("kci.conda_metadata"));
    try metadata.object.put("schema_version", .{ .integer = 1 });
    try metadata.object.put("size", .{ .integer = @intCast(conda.len) });
    try metadata.object.put("subdir", str(subdir));
    try metadata.object.put("version", str(version));
    var d = openOut(a);
    defer d.close();
    try writeFile(d, file, conda);
    try writeFile(d, "manifest.json", try contractManifest(alloc, name, version, subdir, file, &conda_sha));
    try writeFile(d, conda_manifest_metadata, try jsonLine(alloc, metadata.*));
}

/// komira_pack conda --name N --import-name I --stamp N
///     --timestamp-ms T [--commit SHA] --subdir linux-64 --mojo-pin V
///     --license SPDX --summary S --home URL --payload F.mojoc [--dep NAME]...
///     --sources DIR --extra-file info/licenses/LICENSE=FILE --label L
///     [--doc-file REL=FILE]... --out-dir D
/// komira_pack conda --name N --refuse REASON --out-dir D
///
/// The version is --mojo-pin V, the Mojo compiler version the library was built
/// with, and the run requirement `mojo-compiler ==V` pins the same value. The
/// release iteration is the build number --stamp N (0 is an unstamped build),
/// and the build string is `h<8 hex of --commit>_<N>`. N (the option) is the
/// CONDA name, I the import name (the `.mojoc`'s name); each --dep is the
/// conda name of a direct dependency. With --refuse, the package is not made
/// and D holds REFUSED instead.
///
/// Each --doc-file is installed at share/doc/N/REL (docFiles): a file in the
/// pkg tar, one paths.json row, and one `doc_files` row ({path, sha256}) of
/// metadata.json. A library's README.md is passed as REL README.md
/// (conda.bzl). metadata.json carries `doc_files` always, [] when none.
pub fn cmdConda(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--stamp", "--timestamp-ms", "--subdir", "--mojo-pin", "--license", "--summary", "--home", "--payload", "--dep", "--sources", "--import-name", "--extra-file", "--doc-file", "--label", "--commit", "--refuse", "--out-dir" });
    const name = need(a.name, "--name");
    if (one(a, "--refuse")) |why| {
        try writeRefusal(alloc, a, why);
        return;
    }
    if (!validName(name)) fail("name `{s}` is not lowercase letters, digits and _, starting with a letter", .{name});
    const import_name = need(one(a, "--import-name"), "--import-name");
    if (!validImport(import_name)) fail("import name `{s}` is not a Mojo identifier", .{import_name});
    const deps = try all(alloc, a, "--dep");
    for (deps, 0..) |d, i| {
        if (!validName(d)) fail("dependency `{s}` is not a conda name", .{d});
        if (std.mem.eql(u8, d, name)) fail("{s} depends on itself", .{name});
        for (deps[0..i]) |e| if (std.mem.eql(u8, d, e)) fail("dependency {s} given twice", .{d});
    }
    const subdir = need(one(a, "--subdir"), "--subdir");
    _ = guardFor(subdir);
    const pin = plain(need(one(a, "--mojo-pin"), "--mojo-pin"), "mojo pin", "");
    if (!decimal(std.mem.sliceTo(pin, '.'))) fail("mojo pin `{s}` is not an exact version", .{pin});

    const version = compilerVersion(pin);
    const stamp = need(one(a, "--stamp"), "--stamp");
    if (!decimal(stamp)) fail("--stamp `{s}` is not a decimal number without leading zeros", .{stamp});
    const number = std.fmt.parseInt(i64, stamp, 10) catch unreachable;
    const ts_text = need(one(a, "--timestamp-ms"), "--timestamp-ms");
    const timestamp = std.fmt.parseInt(i64, ts_text, 10) catch fail("--timestamp-ms `{s}` is not an integer", .{ts_text});

    // The source commit the stamp was derived from (release_version.sh). A
    // stamped package must carry it, so a stamp is tied to git and not just to
    // a number someone typed; an unstamped one carries it only if given.
    const commit = commitOf(a, stamp);
    const build = try buildString(alloc, commit, number);

    if (try dlopenReason(alloc, need(one(a, "--sources"), "--sources"))) |why| {
        try writeRefusal(alloc, a, why);
        return;
    }

    const payload = readAll(alloc, need(one(a, "--payload"), "--payload"));
    if (payload.len == 0) fail("the payload is empty: a zero-byte .mojoc is a silent build failure", .{});
    const payload_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, import_name });
    const payload_sha = sha256Hex(payload);
    const docs = try docFiles(alloc, a, name);

    // info/
    const depends = try runRequirements(alloc, subdir, pin, version, build, deps);
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

    // pkg/: the payload and the doc files, sorted by path (writeTar sorts
    // the tar the same way), and one paths.json row each in that order.
    var pkg_list = std.ArrayList(Entry).init(alloc);
    try pkg_list.append(.{ .path = payload_path, .mode = 0o644, .data = payload });
    for (docs) |d| try pkg_list.append(.{ .path = d.path, .mode = 0o644, .data = d.data });
    const pkg_entries = try pkg_list.toOwnedSlice();
    std.mem.sort(Entry, pkg_entries, {}, lessEntry);
    var rows = newArray(alloc);
    for (pkg_entries) |e| try rows.array.append(try pathRow(alloc, e.path, e.data));
    var paths = newObject(alloc);
    try paths.object.put("paths", rows);
    try paths.object.put("paths_version", .{ .integer = 1 });

    var info_entries = std.ArrayList(Entry).init(alloc);
    try info_entries.append(.{ .path = "info/index.json", .mode = 0o644, .data = try jsonLine(alloc, index) });
    try info_entries.append(.{ .path = "info/paths.json", .mode = 0o644, .data = try jsonLine(alloc, paths) });
    try aboutAndLicense(alloc, a, &info_entries);

    const stem = try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, build });
    const conda = try assembleConda(alloc, stem, pkg_entries, info_entries.items);

    var doc_rows = newArray(alloc);
    for (docs) |d| {
        var row = newObject(alloc);
        try row.object.put("path", str(d.path));
        try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(d.data))));
        try doc_rows.array.append(row);
    }
    var m = newObject(alloc);
    try m.object.put("depends", try strArray(alloc, depends));
    try m.object.put("doc_files", doc_rows);
    try m.object.put("import_name", str(import_name));
    try m.object.put("kind", str("library"));
    try m.object.put("label", str(need(one(a, "--label"), "--label")));
    try m.object.put("mojo_pin", str(pin));
    try m.object.put("payload_path", str(payload_path));
    try m.object.put("payload_sha256", str(&payload_sha));
    try m.object.put("source_commit", str(commit));
    try m.object.put("stamped", .{ .bool = !std.mem.eql(u8, stamp, "0") });
    try m.object.put("timestamp_ms", .{ .integer = timestamp });
    try emitPackage(alloc, a, stem, conda, name, version, build, number, subdir, &m);
}
