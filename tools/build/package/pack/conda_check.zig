//! komira_pack: the `conda-check` command (a package read back).

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const pack_conda = @import("conda.zig");
const pack_conda_meta = @import("conda_meta.zig");
const Args = pack_common.Args;
const all = pack_common.all;
const allow = pack_common.allow;
const fail = pack_common.fail;
const lessStr = pack_common.lessStr;
const member = pack_common.member;
const memberInt = pack_common.memberInt;
const memberStr = pack_common.memberStr;
const need = pack_common.need;
const one = pack_common.one;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;
const writeFile = pack_common.writeFile;
const DocFile = pack_conda.DocFile;
const TarFile = pack_conda.TarFile;
const buildString = pack_conda.buildString;
const compilerVersion = pack_conda.compilerVersion;
const conda_metadata = pack_conda.conda_metadata;
const docFiles = pack_conda.docFiles;
const findTar = pack_conda.findTar;
const fullCommit = pack_conda.fullCommit;
const jsonLine = pack_conda.jsonLine;
const lessDoc = pack_conda.lessDoc;
const license_member = pack_conda.license_member;
const metaRequirements = pack_conda.metaRequirements;
const payload_dir = pack_conda.payload_dir;
const readTar = pack_conda.readTar;
const readZip = pack_conda.readZip;
const runRequirements = pack_conda.runRequirements;
const validName = pack_conda.validName;
const zstdDecode = pack_conda.zstdDecode;
const Member = pack_conda_meta.Member;
const expectEq = pack_conda_meta.expectEq;
const memberBool = pack_conda_meta.memberBool;
const readContractManifest = pack_conda_meta.readContractManifest;
const readMembers = pack_conda_meta.readMembers;

// ---- reading a package back ----------------------------------------------

const Parts = struct { stem: []const u8, info: []TarFile, pkg: []TarFile };

/// The zip layout and both tars. Not through the code that wrote the package.
pub fn readParts(alloc: Alloc, bytes: []const u8) !Parts {
    const zip = try readZip(alloc, bytes, "package");
    if (zip.len != 3) fail("package: {d} members, must be 3 (metadata.json, pkg-*, info-*)", .{zip.len});
    expectEq("member 0 name", zip[0].name, "metadata.json");
    expectEq("metadata.json", zip[0].data, conda_metadata);
    if (!std.mem.startsWith(u8, zip[1].name, "pkg-") or !std.mem.endsWith(u8, zip[1].name, ".tar.zst")) fail("member 1 `{s}` is not pkg-*.tar.zst", .{zip[1].name});
    if (!std.mem.startsWith(u8, zip[2].name, "info-") or !std.mem.endsWith(u8, zip[2].name, ".tar.zst")) fail("member 2 `{s}` is not info-*.tar.zst", .{zip[2].name});
    const stem = zip[1].name["pkg-".len .. zip[1].name.len - ".tar.zst".len];
    expectEq("info member stem", zip[2].name["info-".len .. zip[2].name.len - ".tar.zst".len], stem);
    return .{
        .stem = stem,
        .info = try readTar(alloc, zstdDecode(alloc, zip[2].data, "info tar"), "info tar"),
        .pkg = try readTar(alloc, zstdDecode(alloc, zip[1].data, "pkg tar"), "pkg tar"),
    };
}

fn sortedNames(alloc: Alloc, dir_path: []const u8) ![][]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err|
        fail("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var list = std.ArrayList([]const u8).init(alloc);
    var it = dir.iterate();
    while (try it.next()) |e| try list.append(try alloc.dupe(u8, e.name));
    const names = try list.toOwnedSlice();
    std.mem.sort([]const u8, names, {}, lessStr);
    return names;
}

/// komira_pack conda-check --dir D --kind library|metapackage --name N
///     --expect-subdir S [--require-stamped true] --out MARKER
///   library:     --import-name I --mojo-pin V --payload F.mojoc [--dep NAME]...
///                [--doc-file REL=FILE]...
///   metapackage: --member-manifest M.json... [--mojo-pin V]
///
/// V is the Mojo compiler version: the package's version must BE it (a package
/// whose version is not the pinned compiler's is refused).
///
/// Reads the package directory back, not through the code that wrote it: the
/// manifest (it must be the artifact-manifest contract exactly), the metadata,
/// the zip, both zstd streams (through zig's decoder), both tars, then every
/// property a consumer or the channel relies on, against the values the CALLER
/// states (the expected name, subdir, pin, payload, dependencies, members).
/// Writes MARKER only when all hold; exit 2 naming the first that does not.
///
/// A library's pkg tar holds exactly the payload and the --doc-file files the
/// caller states, byte-equal, at share/doc/N/REL, and nothing else; paths.json
/// lists exactly those, and metadata.json's `doc_files` names exactly those
/// docs with their sha256, so a doc in the info tar, a missing row or a
/// changed byte is refused. A metapackage carries no doc.
///
/// A directory holding only REFUSED (the package could not be made) is a valid
/// refusal and writes MARKER saying so, except under --require-stamped, where
/// it is the failure, naming the reason: that is what asking for a release
/// of a library with no package does.
pub fn cmdCondaCheck(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--dir", "--kind", "--expect-subdir", "--import-name", "--mojo-pin", "--payload", "--dep", "--doc-file", "--member-manifest", "--require-stamped" });
    const dir = need(one(a, "--dir"), "--dir");
    const name = need(a.name, "--name");
    const kind = need(one(a, "--kind"), "--kind");
    const is_meta = std.mem.eql(u8, kind, "metapackage");
    if (!is_meta and !std.mem.eql(u8, kind, "library")) fail("--kind `{s}` is not library or metapackage", .{kind});
    const subdir = need(one(a, "--expect-subdir"), "--expect-subdir");
    const require_stamped = one(a, "--require-stamped") != null;
    const listing = try sortedNames(alloc, dir);

    if (listing.len == 1 and std.mem.eql(u8, listing[0], "REFUSED")) {
        const why = std.mem.trim(u8, readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/REFUSED", .{dir})), " \t\r\n");
        if (why.len == 0) fail("{s}/REFUSED holds no reason", .{dir});
        if (require_stamped) fail("{s} has no package, so there is nothing to release: {s}", .{ name, why });
        std.debug.print("komira_pack conda-check: {s} is refused: {s}\n", .{ name, why });
        try writeFile(std.fs.cwd(), need(a.out, "--out"), "refused\n");
        return;
    }
    // The listing is sorted, so where the package falls depends on its name
    // (`komira_*` sorts before `manifest.json`, `rest_url-*` after
    // `metadata.json`): find it among the three, never by position.
    var file_name: []const u8 = "";
    var n_conda: usize = 0;
    var has_manifest = false;
    var has_metadata = false;
    for (listing) |entry| {
        if (std.mem.eql(u8, entry, "manifest.json")) {
            has_manifest = true;
        } else if (std.mem.eql(u8, entry, "metadata.json")) {
            has_metadata = true;
        } else if (std.mem.endsWith(u8, entry, ".conda")) {
            file_name = entry;
            n_conda += 1;
        }
    }
    if (listing.len != 3 or n_conda != 1 or !has_manifest or !has_metadata)
        fail("{s} must hold exactly one .conda, manifest.json and metadata.json (or only REFUSED)", .{dir});
    const bytes = readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, file_name }));

    // The manifest: the contract, and the file it describes.
    const man_path = try std.fmt.allocPrint(alloc, "{s}/manifest.json", .{dir});
    const man = try readContractManifest(alloc, man_path);
    expectEq("manifest name", memberStr(man, "name", "manifest"), name);
    expectEq("manifest subdir", memberStr(man, "subdir", "manifest"), subdir);
    if (std.mem.eql(u8, subdir, "noarch")) fail("subdir noarch is never published: a compiled package names its platform", .{});
    expectEq("manifest file", memberStr(man, "file", "manifest"), file_name);
    expectEq("manifest sha256", memberStr(man, "sha256", "manifest"), &sha256Hex(bytes));
    const version = memberStr(man, "version", "manifest");

    const parts = try readParts(alloc, bytes);
    const info = parts.info;
    const pkg = parts.pkg;
    if (!validName(name)) fail("name `{s}` is not a conda name", .{name});
    if (one(a, "--mojo-pin")) |pin| expectEq("version (it must be the Mojo compiler version)", version, compilerVersion(pin));

    // info/: exactly the files a consumer reads, plus licences.
    var saw_license = false;
    for (info) |f| {
        const known = std.mem.eql(u8, f.name, "info/about.json") or std.mem.eql(u8, f.name, "info/index.json") or std.mem.eql(u8, f.name, "info/paths.json");
        if (std.mem.eql(u8, f.name, license_member)) saw_license = true;
        if (!known and !std.mem.startsWith(u8, f.name, "info/licenses/")) fail("info tar: unexpected member {s}", .{f.name});
        if (f.mode != 0o644) fail("info tar: {s} has mode {o}, must be 644", .{ f.name, f.mode });
    }
    if (!saw_license) fail("info tar: no {s}", .{license_member});
    const index_raw = (findTar(info, "info/index.json") orelse fail("info tar: no info/index.json", .{})).data;
    const paths_raw = (findTar(info, "info/paths.json") orelse fail("info tar: no info/paths.json", .{})).data;
    if (findTar(info, "info/about.json") == null) fail("info tar: no info/about.json", .{});
    const index = try json.parseFromSliceLeaky(json.Value, alloc, index_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, index), index_raw)) fail("info/index.json is not sorted compact JSON with one trailing newline", .{});

    // index.json
    if (index != .object) fail("info/index.json is not an object", .{});
    const want_keys = [_][]const u8{ "arch", "build", "build_number", "depends", "license", "name", "platform", "subdir", "timestamp", "version" };
    if (index.object.count() != want_keys.len) fail("info/index.json has {d} keys, must be exactly {d} (a `noarch` key among them is a refusal)", .{ index.object.count(), want_keys.len });
    for (want_keys) |k| _ = member(index, k, "info/index.json");
    expectEq("index name", memberStr(index, "name", "index"), name);
    expectEq("index version", memberStr(index, "version", "index"), version);
    expectEq("index subdir", memberStr(index, "subdir", "index"), subdir);
    expectEq("index platform", memberStr(index, "platform", "index"), "linux");
    expectEq("index arch", memberStr(index, "arch", "index"), "x86_64");
    _ = compilerVersion(version);
    const build = memberStr(index, "build", "index");
    const number = memberInt(index, "build_number", "index");
    if (number < 0) fail("index build_number {d} is negative", .{number});
    expectEq("file name", file_name, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}.conda", .{ name, version, build }));
    expectEq("member stem", parts.stem, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{ name, version, build }));
    const stamped = number != 0;
    const timestamp = memberInt(index, "timestamp", "index");
    if (require_stamped) {
        if (!stamped) fail("version {s} was never stamped (the build number is 0): a release has a real build number", .{version});
        // A release is tied to git: a positive commit time, and the commit the stamp came from.
        if (timestamp <= 0) fail("version {s} is stamped but its index timestamp is not positive: a release carries its commit's time", .{version});
    }

    // The run requirements are re-derived from what the caller states.
    var members: []const Member = &.{};
    if (is_meta) {
        members = try readMembers(alloc, a);
        for (members) |m| {
            if (std.mem.eql(u8, m.name, name)) fail("the metapackage `{s}` is also a member", .{name});
            expectEq("member version", m.version, version);
            expectEq("member build", m.build, build);
            if (m.build_number != number) fail("member {s} has build number {d}, the metapackage {d}", .{ m.name, m.build_number, number });
            expectEq("member subdir", m.subdir, subdir);
        }
    }
    const want = if (is_meta)
        try metaRequirements(alloc, subdir, members)
    else
        try runRequirements(alloc, subdir, need(one(a, "--mojo-pin"), "--mojo-pin"), version, build, try all(alloc, a, "--dep"));
    const depends = member(index, "depends", "index");
    if (depends != .array or depends.array.items.len != want.len) fail("index depends has {d} entries, must be {d} (the platform guard{s} and each requirement at its version)", .{ if (depends == .array) depends.array.items.len else 0, want.len, @as([]const u8, if (is_meta) "" else ", the exact compiler pin") });
    for (depends.array.items, want) |got, w| {
        if (got != .string) fail("index depends holds a non-string", .{});
        expectEq("requirement", got.string, w);
    }

    // pkg/ and paths.json.
    const paths = try json.parseFromSliceLeaky(json.Value, alloc, paths_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, paths), paths_raw)) fail("info/paths.json is not sorted compact JSON with one trailing newline", .{});
    if (memberInt(paths, "paths_version", "paths") != 1) fail("paths_version is not 1", .{});
    const rows = member(paths, "paths", "paths");
    if (rows != .array) fail("info/paths.json has no list of paths", .{});
    var payload: []const u8 = "";
    var want_path: []const u8 = "";
    const docs = try docFiles(alloc, a, name);
    if (is_meta) {
        if (docs.len != 0) fail("--doc-file is given for a metapackage, which ships no doc", .{});
        if (pkg.len != 0) fail("pkg tar: {d} files, a metapackage carries none", .{pkg.len});
        if (rows.array.items.len != 0) fail("info/paths.json lists a file: a metapackage carries none", .{});
    } else {
        const import_name = need(one(a, "--import-name"), "--import-name");
        payload = readAll(alloc, need(one(a, "--payload"), "--payload"));
        want_path = try std.fmt.allocPrint(alloc, "{s}{s}.mojoc", .{ payload_dir, import_name });
        if (payload.len == 0) fail("--payload is empty", .{});
        // What the pkg tar must hold: the payload and the stated docs, in path order.
        var want_list = std.ArrayList(DocFile).init(alloc);
        try want_list.append(.{ .path = want_path, .data = payload });
        for (docs) |d| try want_list.append(d);
        const want_files = try want_list.toOwnedSlice();
        std.mem.sort(DocFile, want_files, {}, lessDoc);
        if (pkg.len != want_files.len) fail("pkg tar: {d} files, must be exactly the .mojoc and the {d} declared doc file(s)", .{ pkg.len, docs.len });
        if (rows.array.items.len != want_files.len) fail("info/paths.json lists {d} files, must list exactly the .mojoc and the {d} declared doc file(s)", .{ rows.array.items.len, docs.len });
        for (want_files, pkg, rows.array.items) |w, f, row| {
            expectEq("pkg tar member", f.name, w.path);
            if (f.mode != 0o644) fail("pkg tar: {s} has mode {o}, must be 644", .{ f.name, f.mode });
            if (!std.mem.eql(u8, f.data, w.data)) {
                if (std.mem.eql(u8, w.path, want_path)) fail("pkg tar: the payload differs from the library's .mojoc ({d} bytes against {d})", .{ f.data.len, w.data.len });
                fail("pkg tar: {s} differs from the declared doc file ({d} bytes against {d})", .{ f.name, f.data.len, w.data.len });
            }
            expectEq("paths _path", memberStr(row, "_path", "paths row"), w.path);
            expectEq("paths path_type", memberStr(row, "path_type", "paths row"), "hardlink");
            expectEq("paths sha256", memberStr(row, "sha256", "paths row"), &sha256Hex(w.data));
            if (memberInt(row, "size_in_bytes", "paths row") != @as(i64, @intCast(w.data.len))) fail("paths size_in_bytes of {s} differs", .{w.path});
        }
    }

    // metadata.json agrees with the file and with the index.
    const md_raw = readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/metadata.json", .{dir}));
    const md = try json.parseFromSliceLeaky(json.Value, alloc, md_raw, .{});
    if (!std.mem.eql(u8, try jsonLine(alloc, md), md_raw)) fail("metadata.json is not sorted compact JSON with one trailing newline", .{});
    expectEq("metadata format", memberStr(md, "format", "metadata"), "kci.conda_metadata");
    if (memberInt(md, "schema_version", "metadata") != 1) fail("metadata schema_version is not 1", .{});
    expectEq("metadata kind", memberStr(md, "kind", "metadata"), kind);
    expectEq("metadata name", memberStr(md, "name", "metadata"), name);
    expectEq("metadata version", memberStr(md, "version", "metadata"), version);
    expectEq("metadata subdir", memberStr(md, "subdir", "metadata"), subdir);
    expectEq("metadata build", memberStr(md, "build", "metadata"), build);
    if (memberInt(md, "build_number", "metadata") != number) fail("metadata build_number differs from the index", .{});
    expectEq("metadata file_name", memberStr(md, "file_name", "metadata"), file_name);
    if (memberInt(md, "size", "metadata") != @as(i64, @intCast(bytes.len))) fail("metadata size differs from the file", .{});
    if (memberInt(md, "timestamp_ms", "metadata") != timestamp) fail("metadata timestamp_ms differs from the index", .{});
    if (memberBool(md, "stamped", "metadata") != stamped) fail("metadata `stamped` disagrees with the version", .{});
    const commit = memberStr(md, "source_commit", "metadata");
    if (commit.len != 0 and !fullCommit(commit)) fail("metadata source_commit `{s}` is not a full lowercase 40-digit hex commit id", .{commit});
    if (stamped and commit.len == 0) fail("metadata source_commit is empty on a stamped package", .{});
    // The build string names the commit and the number: h<8 hex of source_commit>_<N>.
    expectEq("index build (h<first 8 hex of the source commit>_<build number>)", build, try buildString(alloc, commit, number));
    if (require_stamped and !fullCommit(commit)) fail("a release must carry the source commit of its stamp in the metadata", .{});
    const mdeps = member(md, "depends", "metadata");
    if (mdeps != .array or mdeps.array.items.len != want.len) fail("metadata depends differ from info/index.json", .{});
    for (want, mdeps.array.items) |x, y| if (y != .string or !std.mem.eql(u8, x, y.string)) fail("metadata depends differ from info/index.json", .{});
    if (is_meta) {
        if (md.object.get("doc_files") != null) fail("metadata doc_files on a metapackage, which ships no doc", .{});
        for (members) |m| {
            expectEq("member source commit", m.commit, commit);
            if (m.timestamp != timestamp) fail("member {s} has another commit time", .{m.name});
        }
        const rows_md = member(md, "members", "metadata");
        if (rows_md != .array or rows_md.array.items.len != members.len) fail("metadata members differ from the member manifests", .{});
        for (members, rows_md.array.items) |m, r| {
            expectEq("metadata member name", memberStr(r, "name", "member row"), m.name);
            expectEq("metadata member version", memberStr(r, "version", "member row"), m.version);
            expectEq("metadata member build", memberStr(r, "build", "member row"), m.build);
            expectEq("metadata member sha256", memberStr(r, "sha256", "member row"), m.sha256);
        }
    } else {
        expectEq("metadata import_name", memberStr(md, "import_name", "metadata"), need(one(a, "--import-name"), "--import-name"));
        expectEq("metadata mojo_pin", memberStr(md, "mojo_pin", "metadata"), need(one(a, "--mojo-pin"), "--mojo-pin"));
        expectEq("metadata payload_path", memberStr(md, "payload_path", "metadata"), want_path);
        expectEq("metadata payload_sha256", memberStr(md, "payload_sha256", "metadata"), &sha256Hex(payload));
        const md_docs = member(md, "doc_files", "metadata");
        if (md_docs != .array or md_docs.array.items.len != docs.len) fail("metadata doc_files must name exactly the {d} declared doc file(s)", .{docs.len});
        for (docs, md_docs.array.items) |d, r| {
            if (r != .object or r.object.count() != 2) fail("metadata doc_files rows are {{path, sha256}}", .{});
            expectEq("metadata doc_files path", memberStr(r, "path", "doc_files row"), d.path);
            expectEq("metadata doc_files sha256", memberStr(r, "sha256", "doc_files row"), &sha256Hex(d.data));
        }
    }

    std.debug.print("komira_pack conda-check: {s} {s} ({s}, {s}) ok\n", .{ name, version, subdir, kind });
    try writeFile(std.fs.cwd(), need(a.out, "--out"), "ok\n");
}
