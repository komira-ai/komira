//! komira_pack: the `conda-install` command (a package unpacked into a clean prefix).
//!
//! usage: komira_pack conda-install --dir D --prefix P [--runtime-lib NAME=FILE]...
//!                                  [--require-depend "NAME ==VERSION"]...
//!
//! D holds one `.conda`. Its pkg tar is written under P as an installer does:
//! every member at its path, a regular file with its mode, a symbolic link as
//! a link. The install is refused unless the pkg tar and `info/paths.json`
//! name the same paths, each file's sha256 and size are the row's, and each
//! row's path type matches the member (a link is a `softlink`). A path may be
//! written once; an absolute path, a `.` or `..` component, or a link target
//! with a directory part is refused.
//!
//! Each `--runtime-lib NAME=FILE` is then written to `lib/NAME` (mode 0755):
//! the libraries the package's own requirements install beside it (the Mojo
//! runtime of the `mojo-compiler` requirement), which this command cannot
//! resolve; the caller names them. A name the package already ships is
//! refused, as two packages owning one path are.
//!
//! Each `--require-depend R` demands that `depends` of the package's
//! info/index.json hold the requirement R verbatim (`mojo-compiler ==<pin>`):
//! the runtime libraries are taken from the toolchain, so only this shows the
//! package itself asks for the compiler that provides them.
//!
//! Nothing is searched, downloaded or run: the prefix holds what the package
//! and the named files hold, so a program loading from it shows what an
//! installed environment would load.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const pack_conda = @import("conda.zig");
const pack_conda_check = @import("conda_check.zig");
const Args = pack_common.Args;
const TarFile = pack_conda.TarFile;
const all = pack_common.all;
const allow = pack_common.allow;
const fail = pack_common.fail;
const need = pack_common.need;
const one = pack_common.one;
const readAll = pack_common.readAll;
const sha256Hex = pack_common.sha256Hex;

/// `error.Refused` (the reason in `why`) or the file system's own error.
pub const Error = anyerror;

/// Why the last `error.Refused` was returned.
pub var why: []const u8 = "";

fn refuse(alloc: Alloc, comptime fmt: []const u8, args: anytype) Error {
    why = try std.fmt.allocPrint(alloc, fmt, args);
    return error.Refused;
}

/// A relative path with no empty, `.` or `..` component.
pub fn relativePath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

fn rowOf(rows: []const json.Value, path: []const u8) ?json.Value {
    for (rows) |r| {
        if (r != .object) continue;
        const p = r.object.get("_path") orelse continue;
        if (p == .string and std.mem.eql(u8, p.string, path)) return r;
    }
    return null;
}

fn rowStr(alloc: Alloc, row: json.Value, key: []const u8, path: []const u8) Error![]const u8 {
    const v = row.object.get(key) orelse return refuse(alloc, "info/paths.json: the row of {s} has no `{s}`", .{ path, key });
    if (v != .string) return refuse(alloc, "info/paths.json: `{s}` of {s} is not a string", .{ key, path });
    return v.string;
}

fn parent(root: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try root.makePath(d);
}

/// Writes the members of `pkg` under `root`, checked against `paths`
/// (info/paths.json, parsed).
pub fn installInto(alloc: Alloc, root: std.fs.Dir, pkg: []const TarFile, paths: json.Value) Error!void {
    if (paths != .object) return refuse(alloc, "info/paths.json is not an object", .{});
    const listed = paths.object.get("paths") orelse return refuse(alloc, "info/paths.json has no `paths`", .{});
    if (listed != .array) return refuse(alloc, "info/paths.json `paths` is not a list", .{});
    const rows = listed.array.items;
    if (rows.len != pkg.len) return refuse(alloc, "info/paths.json lists {d} paths, the pkg tar holds {d} members", .{ rows.len, pkg.len });
    for (pkg) |f| {
        if (!relativePath(f.name)) return refuse(alloc, "pkg tar member `{s}` is not a relative path", .{f.name});
        const row = rowOf(rows, f.name) orelse return refuse(alloc, "pkg tar member {s} has no row in info/paths.json", .{f.name});
        const want_type: []const u8 = if (f.link.len != 0) "softlink" else "hardlink";
        const got_type = try rowStr(alloc, row, "path_type", f.name);
        if (!std.mem.eql(u8, got_type, want_type)) return refuse(alloc, "info/paths.json: {s} is `{s}`, the pkg tar member is a `{s}`", .{ f.name, got_type, want_type });
        try parent(root, f.name);
        if (f.link.len != 0) {
            if (!relativePath(f.link) or std.mem.indexOfScalar(u8, f.link, '/') != null) return refuse(alloc, "pkg tar: {s} links to `{s}`, which is not a name beside it", .{ f.name, f.link });
            try root.symLink(f.link, f.name, .{});
            continue;
        }
        const sha = try rowStr(alloc, row, "sha256", f.name);
        if (!std.mem.eql(u8, sha, &sha256Hex(f.data))) return refuse(alloc, "info/paths.json: the sha256 of {s} is {s}, the member's is {s}", .{ f.name, sha, &sha256Hex(f.data) });
        const size = row.object.get("size_in_bytes") orelse return refuse(alloc, "info/paths.json: the row of {s} has no `size_in_bytes`", .{f.name});
        if (size != .integer or size.integer != @as(i64, @intCast(f.data.len))) return refuse(alloc, "info/paths.json: the size of {s} differs from the member's {d} bytes", .{ f.name, f.data.len });
        try writeNew(root, f.name, f.mode & 0o777, f.data);
    }
}

fn writeNew(root: std.fs.Dir, path: []const u8, mode: u32, data: []const u8) !void {
    var file = try root.createFile(path, .{ .exclusive = true, .mode = @intCast(mode) });
    defer file.close();
    try file.writeAll(data);
}

/// `lib/<name>` with `data`, mode 0755, for a library the package's
/// requirements install beside it.
pub fn addRuntime(alloc: Alloc, root: std.fs.Dir, name: []const u8, data: []const u8) Error!void {
    if (!relativePath(name) or std.mem.indexOfScalar(u8, name, '/') != null) return refuse(alloc, "runtime library name `{s}` is not a file name", .{name});
    if (data.len == 0) return refuse(alloc, "runtime library {s} is empty", .{name});
    const path = try std.fmt.allocPrint(alloc, "lib/{s}", .{name});
    root.access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            try parent(root, path);
            try writeNew(root, path, 0o755, data);
            return;
        },
        else => return err,
    };
    return refuse(alloc, "runtime library {s} would overwrite lib/{s}, which the package ships", .{ name, name });
}

/// Refuses unless `depends` of `index` (info/index.json, parsed) holds `want`.
pub fn requireDepend(alloc: Alloc, index: json.Value, want: []const u8) Error!void {
    if (index != .object) return refuse(alloc, "info/index.json is not an object", .{});
    const deps = index.object.get("depends") orelse return refuse(alloc, "info/index.json has no `depends`", .{});
    if (deps != .array) return refuse(alloc, "info/index.json `depends` is not a list", .{});
    for (deps.array.items) |d| {
        if (d == .string and std.mem.eql(u8, d.string, want)) return;
    }
    return refuse(alloc, "info/index.json `depends` does not hold `{s}`", .{want});
}

fn theConda(alloc: Alloc, dir_path: []const u8) ![]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err|
        fail("cannot open {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var found: ?[]const u8 = null;
    var it = dir.iterate();
    while (try it.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".conda")) continue;
        if (found != null) fail("{s} holds two .conda files", .{dir_path});
        found = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir_path, e.name });
    }
    return found orelse fail("{s} holds no .conda file", .{dir_path});
}

pub fn cmdCondaInstall(alloc: Alloc, a: Args) !void {
    allow(a, &.{ "--dir", "--runtime-lib", "--require-depend" });
    const bytes = readAll(alloc, try theConda(alloc, need(one(a, "--dir"), "--dir")));
    const parts = try pack_conda_check.readParts(alloc, bytes);
    const paths_tar = pack_conda.findTar(parts.info, "info/paths.json") orelse fail("package: no info/paths.json", .{});
    const paths = try json.parseFromSliceLeaky(json.Value, alloc, paths_tar.data, .{});
    const index_tar = pack_conda.findTar(parts.info, "info/index.json") orelse fail("package: no info/index.json", .{});
    const index = try json.parseFromSliceLeaky(json.Value, alloc, index_tar.data, .{});
    for (try all(alloc, a, "--require-depend")) |want| {
        requireDepend(alloc, index, want) catch |err| switch (err) {
            error.Refused => fail("{s}", .{why}),
            else => return err,
        };
    }
    const prefix = need(a.prefix, "--prefix");
    try std.fs.cwd().makePath(prefix);
    var root = try std.fs.cwd().openDir(prefix, .{});
    defer root.close();
    installInto(alloc, root, parts.pkg, paths) catch |err| switch (err) {
        error.Refused => fail("{s}", .{why}),
        else => return err,
    };
    for (try all(alloc, a, "--runtime-lib")) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse fail("--runtime-lib `{s}` is not <file name>=<file>", .{v});
        addRuntime(alloc, root, v[0..eq], readAll(alloc, v[eq + 1 ..])) catch |err| switch (err) {
            error.Refused => fail("{s}", .{why}),
            else => return err,
        };
    }
    std.debug.print("komira_pack conda-install: {d} members into {s} ok\n", .{ parts.pkg.len, prefix });
}

// ---- tests ---------------------------------------------------------------
//
// Each test names the defect it catches. They run as a build action
// (`:komira_pack_unit`), and komira_pack is not built unless they pass.

const testing = std.testing;

const lib_bytes = "\x7fELF a shared library";

fn pathsDoc(alloc: Alloc, rows: []const [3][]const u8) !json.Value {
    // Rows of {_path, path_type, data}: the sha256 and size are those of data.
    var list = pack_common.newArray(alloc);
    for (rows) |r| {
        var row = pack_common.newObject(alloc);
        try row.object.put("_path", pack_common.str(r[0]));
        try row.object.put("path_type", pack_common.str(r[1]));
        try row.object.put("sha256", pack_common.str(try alloc.dupe(u8, &sha256Hex(r[2]))));
        try row.object.put("size_in_bytes", .{ .integer = @intCast(r[2].len) });
        try list.array.append(row);
    }
    var doc = pack_common.newObject(alloc);
    try doc.object.put("paths", list);
    return doc;
}

fn sample(alloc: Alloc) !struct { pkg: [2]TarFile, rows: json.Value } {
    return .{
        .pkg = .{
            .{ .name = "lib/libx.so", .mode = 0o755, .data = lib_bytes },
            .{ .name = "lib/libx.so.1", .mode = 0o777, .data = "", .link = "libx.so" },
        },
        .rows = try pathsDoc(alloc, &.{ .{ "lib/libx.so", "hardlink", lib_bytes }, .{ "lib/libx.so.1", "softlink", lib_bytes } }),
    };
}

test "a package is written as it is: bytes, mode and a link" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try sample(alloc);
    try installInto(alloc, tmp.dir, &s.pkg, s.rows);
    const got = try tmp.dir.readFileAlloc(alloc, "lib/libx.so", 1 << 20);
    try testing.expectEqualStrings(lib_bytes, got);
    const st = try tmp.dir.statFile("lib/libx.so");
    try testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.mode & 0o777)));
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("libx.so", try tmp.dir.readLink("lib/libx.so.1", &buf));
}

test "a member whose bytes differ from the row's sha256 is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var s = try sample(alloc);
    s.pkg[0].data = "\x7fELF another build";
    try testing.expectError(error.Refused, installInto(alloc, tmp.dir, &s.pkg, s.rows));
    try testing.expect(std.mem.indexOf(u8, why, "the sha256 of lib/libx.so is") != null);
}

test "a member with no row, or a row with no member, is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try sample(alloc);
    try testing.expectError(error.Refused, installInto(alloc, tmp.dir, s.pkg[0..1], s.rows));
    try testing.expect(std.mem.indexOf(u8, why, "lists 2 paths, the pkg tar holds 1") != null);
    const other = try pathsDoc(alloc, &.{ .{ "lib/liby.so", "hardlink", lib_bytes }, .{ "lib/libx.so.1", "softlink", lib_bytes } });
    try testing.expectError(error.Refused, installInto(alloc, tmp.dir, &s.pkg, other));
    try testing.expect(std.mem.indexOf(u8, why, "lib/libx.so has no row") != null);
}

test "a link row for a regular member, and an escaping path, are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try sample(alloc);
    const wrong = try pathsDoc(alloc, &.{ .{ "lib/libx.so", "softlink", lib_bytes }, .{ "lib/libx.so.1", "softlink", lib_bytes } });
    try testing.expectError(error.Refused, installInto(alloc, tmp.dir, &s.pkg, wrong));
    try testing.expect(std.mem.indexOf(u8, why, "is `softlink`, the pkg tar member is a `hardlink`") != null);
    try testing.expect(!relativePath("../x"));
    try testing.expect(!relativePath("/x"));
    try testing.expect(!relativePath("a//b"));
    try testing.expect(relativePath("lib/libx.so"));
    const up = [_]TarFile{.{ .name = "lib/up", .mode = 0o777, .data = "", .link = "../etc" }};
    const up_rows = try pathsDoc(alloc, &.{.{ "lib/up", "softlink", "" }});
    try testing.expectError(error.Refused, installInto(alloc, tmp.dir, &up, up_rows));
}

test "a runtime library beside the package, and one that would overwrite it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const s = try sample(alloc);
    try installInto(alloc, tmp.dir, &s.pkg, s.rows);
    try addRuntime(alloc, tmp.dir, "libruntime.so", "\x7fELF runtime");
    _ = try tmp.dir.statFile("lib/libruntime.so");
    try testing.expectError(error.Refused, addRuntime(alloc, tmp.dir, "libx.so", "\x7fELF other"));
    try testing.expect(std.mem.indexOf(u8, why, "would overwrite lib/libx.so") != null);
    try testing.expectError(error.Refused, addRuntime(alloc, tmp.dir, "sub/libx.so", "x"));
    try testing.expectError(error.Refused, addRuntime(alloc, tmp.dir, "libempty.so", ""));
}

fn indexDoc(alloc: Alloc, deps: []const []const u8) !json.Value {
    var list = pack_common.newArray(alloc);
    for (deps) |d| try list.array.append(pack_common.str(d));
    var doc = pack_common.newObject(alloc);
    try doc.object.put("depends", list);
    return doc;
}

test "a package that does not depend on the pinned compiler is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const with = try indexDoc(alloc, &.{ "__linux", "__glibc >=2.34", "mojo-compiler ==1.0.0" });
    try requireDepend(alloc, with, "mojo-compiler ==1.0.0");
    const without = try indexDoc(alloc, &.{ "__linux", "__glibc >=2.34" });
    try testing.expectError(error.Refused, requireDepend(alloc, without, "mojo-compiler ==1.0.0"));
    try testing.expect(std.mem.indexOf(u8, why, "does not hold `mojo-compiler ==1.0.0`") != null);
    // Another pin is not the pin.
    const other = try indexDoc(alloc, &.{"mojo-compiler ==0.9.0"});
    try testing.expectError(error.Refused, requireDepend(alloc, other, "mojo-compiler ==1.0.0"));
    try testing.expectError(error.Refused, requireDepend(alloc, pack_common.newObject(alloc), "x"));
}
