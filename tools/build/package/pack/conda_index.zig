//! komira_pack: the `conda-index` command (a local channel).

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const pack_conda = @import("conda.zig");
const pack_conda_meta = @import("conda_meta.zig");
const pack_conda_check = @import("conda_check.zig");
const Args = pack_common.Args;
const all = pack_common.all;
const allow = pack_common.allow;
const fail = pack_common.fail;
const memberStr = pack_common.memberStr;
const need = pack_common.need;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const one = pack_common.one;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;
const str = pack_common.str;
const writeFile = pack_common.writeFile;
const findTar = pack_conda.findTar;
const jsonLine = pack_conda.jsonLine;
const dirOf = pack_conda_meta.dirOf;
const expectEq = pack_conda_meta.expectEq;
const readContractManifest = pack_conda_meta.readContractManifest;
const readParts = pack_conda_check.readParts;

// ---- a local channel -----------------------------------------------------

const IndexedPackage = struct { subdir: []const u8, file: []const u8, bytes: []const u8, record: json.Value };

fn lessIndexed(_: void, x: IndexedPackage, y: IndexedPackage) bool {
    const c = std.mem.order(u8, x.subdir, y.subdir);
    if (c != .eq) return c == .lt;
    return std.mem.lessThan(u8, x.file, y.file);
}

fn emptyRepodata(alloc: Alloc, subdir: []const u8) !json.Value {
    var info = newObject(alloc);
    try info.object.put("subdir", str(subdir));
    var r = newObject(alloc);
    try r.object.put("info", info);
    try r.object.put("packages", newObject(alloc));
    try r.object.put("packages.conda", newObject(alloc));
    try r.object.put("removed", newArray(alloc));
    try r.object.put("repodata_version", .{ .integer = 1 });
    return r;
}

/// komira_pack conda-index --out-dir D --package-manifest M.json...
///
/// A LOCAL conda channel made from packages this tool wrote, so a release can
/// be installed (and validated: kci run --channel file:///D) before anything
/// is published. Each --package-manifest is a package directory's artifact manifest
/// (the contract, exactly); the file it names must have its sha256. D must
/// not exist or be empty. For each package, `D/<subdir>/<file>` is a copy of
/// the file, and `D/<subdir>/repodata.json` lists it under `packages.conda`
/// as its own info/index.json (read back out of the package, never re-derived)
/// plus `sha256` and `size`; `D/noarch/repodata.json` is written empty, as a
/// conda client reads it too. Every repodata.json is sorted compact JSON with
/// one trailing newline: `{"info":{"subdir":S},"packages":{},
/// "packages.conda":{...},"removed":[],"repodata_version":1}`. Refused: no
/// --package-manifest, the same file twice, a package whose index.json names another
/// name, version, subdir or file than its manifest, a `noarch` package, and a
/// D that holds anything.
pub fn cmdCondaIndex(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--out-dir", "--package-manifest" });
    const out = need(one(a, "--out-dir"), "--out-dir");
    const manifests = try all(alloc, a, "--package-manifest");
    if (manifests.len == 0) fail("conda-index needs at least one --package-manifest", .{});
    if (std.fs.cwd().openDir(out, .{ .iterate = true })) |d_const| {
        var d = d_const;
        defer d.close();
        var it = d.iterate();
        if (try it.next()) |e| fail("--out-dir {s} is not empty (it holds {s}): a channel is written whole, never merged", .{ out, e.name });
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => fail("cannot open {s}: {s}", .{ out, @errorName(err) }),
    }

    var list = std.ArrayList(IndexedPackage).init(alloc);
    for (manifests) |m| {
        const doc = try readContractManifest(alloc, m);
        const file = memberStr(doc, "file", m);
        const subdir = memberStr(doc, "subdir", m);
        const bytes = readAll(alloc, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dirOf(m), file }));
        expectEq("the sha256 of the file the manifest names", &sha256Hex(bytes), memberStr(doc, "sha256", m));
        if (std.mem.eql(u8, subdir, "noarch")) fail("{s}: subdir noarch is never published: a compiled package names its platform", .{m});
        const parts = try readParts(alloc, bytes);
        const index_raw = (findTar(parts.info, "info/index.json") orelse fail("{s}: info tar: no info/index.json", .{file})).data;
        var record = json.parseFromSliceLeaky(json.Value, alloc, index_raw, .{}) catch |err|
            fail("{s}: info/index.json is not JSON: {s}", .{ file, @errorName(err) });
        if (record != .object) fail("{s}: info/index.json is not an object", .{file});
        const what = try std.fmt.allocPrint(alloc, "{s}: info/index.json", .{file});
        expectEq(what, memberStr(record, "name", what), memberStr(doc, "name", m));
        expectEq(what, memberStr(record, "version", what), memberStr(doc, "version", m));
        expectEq(what, memberStr(record, "subdir", what), subdir);
        expectEq("file name", file, try std.fmt.allocPrint(alloc, "{s}-{s}-{s}.conda", .{ memberStr(record, "name", what), memberStr(record, "version", what), memberStr(record, "build", what) }));
        if (record.object.get("sha256") != null or record.object.get("size") != null) fail("{s} already holds sha256 or size", .{what});
        try record.object.put("sha256", str(memberStr(doc, "sha256", m)));
        try record.object.put("size", .{ .integer = @intCast(bytes.len) });
        for (list.items) |p| if (std.mem.eql(u8, p.file, file) and std.mem.eql(u8, p.subdir, subdir)) fail("{s}/{s} is given twice", .{ subdir, file });
        try list.append(.{ .subdir = subdir, .file = file, .bytes = bytes, .record = record });
    }
    const pkgs = try list.toOwnedSlice();
    std.mem.sort(IndexedPackage, pkgs, {}, lessIndexed);

    std.fs.cwd().makePath(out) catch |err| fail("cannot create {s}: {s}", .{ out, @errorName(err) });
    var root = std.fs.cwd().openDir(out, .{}) catch |err| fail("cannot open {s}: {s}", .{ out, @errorName(err) });
    defer root.close();
    var i: usize = 0;
    while (i < pkgs.len) {
        const subdir = pkgs[i].subdir;
        var repodata = try emptyRepodata(alloc, subdir);
        try root.makePath(subdir);
        var n: usize = 0;
        while (i < pkgs.len and std.mem.eql(u8, pkgs[i].subdir, subdir)) : (i += 1) {
            try writeFile(root, try std.fmt.allocPrint(alloc, "{s}/{s}", .{ subdir, pkgs[i].file }), pkgs[i].bytes);
            try repodata.object.getPtr("packages.conda").?.object.put(pkgs[i].file, pkgs[i].record);
            n += 1;
        }
        try writeFile(root, try std.fmt.allocPrint(alloc, "{s}/repodata.json", .{subdir}), try jsonLine(alloc, repodata));
        std.debug.print("komira_pack conda-index: {s}/repodata.json lists {d} package(s)\n", .{ subdir, n });
    }
    try root.makePath("noarch");
    try writeFile(root, "noarch/repodata.json", try jsonLine(alloc, try emptyRepodata(alloc, "noarch")));
}
