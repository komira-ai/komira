//! komira_pack: a library's native files in its conda package
//! (docs/design/native_packaging.md, slice 8, "the packer").
//!
//! A library that owns C ships it in its own package (tools/build/package/conda.bzl
//! states which files): its shared library at lib/<SONAME> with the unversioned
//! link name beside it (`--lib-shared SONAME=FILE`), or, for per-library state,
//! static archives at lib/<NAME> (`--lib-static NAME=FILE`). For each file the
//! package carries one `lib_files` row of metadata.json, `{kind, path, sha256}`
//! (`kind` `shared`, `link` or `static`; a link's sha256 is that of the bytes
//! it resolves to), the way `doc_files` carries the README; one info/paths.json
//! row (a link is a `softlink`); and the run requirement `__glibc >=<floor>`,
//! the floor given by `--glibc-floor`, which conda.bzl reads from the platform
//! table's `os_floor` and never types.
//!
//! A shared library's NEEDED may name another komira library's shared library
//! only when that library is in the packed library's Mojo deps closure
//! (`--closure-owner SONAME`, one per shared library the closure ships): the
//! package's requirements are its Mojo deps, so an owner outside the closure
//! would not be installed with it. `conda` refuses such a package.
//!
//! Every function that can refuse returns `error.Refused` with the reason in
//! `why`, so the unit tests below can see each refusal; the commands print it.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const Args = pack_common.Args;
const all = pack_common.all;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const one = pack_common.one;
const sha256Hex = pack_common.sha256Hex;
const str = pack_common.str;

pub const Error = error{Refused} || Alloc.Error;

/// Why the last `error.Refused` was returned.
pub var why: []const u8 = "";

fn refuse(alloc: Alloc, comptime fmt: []const u8, args: anytype) Error {
    why = try std.fmt.allocPrint(alloc, fmt, args);
    return error.Refused;
}

pub const lib_dir = "lib/";

pub const Kind = enum { shared, link, static };

pub const LibFile = struct {
    /// Where the file is installed: lib/<name>.
    path: []const u8,
    kind: Kind,
    /// The bytes at `path`; for a link, the bytes its target holds.
    data: []const u8,
    /// A link's target, relative to its directory (the SONAME); "" otherwise.
    target: []const u8 = "",

    /// The mode of its tar member.
    pub fn mode(f: LibFile) u32 {
        return switch (f.kind) {
            .shared => 0o755,
            .link => 0o777,
            .static => 0o644,
        };
    }
};

fn lessLib(_: void, x: LibFile, y: LibFile) bool {
    return std.mem.lessThan(u8, x.path, y.path);
}

/// The unversioned link name of SONAME `lib<x>.so.<digits>` (`lib<x>.so`), or
/// null when the SONAME is not of that shape.
pub fn linkName(soname: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOf(u8, soname, ".so.") orelse return null;
    const digits = soname[at + ".so.".len ..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    if (!plainName(soname[0..at]) or !std.mem.startsWith(u8, soname, "lib")) return null;
    return soname[0 .. at + ".so".len];
}

fn plainName(n: []const u8) bool {
    if (n.len == 0) return false;
    for (n) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_')) return false;
    return true;
}

/// A static archive's file name: `lib<lowercase, digits, _>.a`.
fn staticName(n: []const u8) bool {
    return n.len > "lib.a".len and std.mem.startsWith(u8, n, "lib") and std.mem.endsWith(u8, n, ".a") and
        plainName(n["lib".len .. n.len - ".a".len]);
}

pub const Given = struct { name: []const u8, data: []const u8 };

/// The files of a package: the shared library (at most one) and its link,
/// then each static archive, sorted by path.
pub fn libFilesOf(alloc: Alloc, shared: []const Given, statics: []const Given) Error![]LibFile {
    var list = std.ArrayList(LibFile).init(alloc);
    if (shared.len > 1) return refuse(alloc, "{d} shared libraries given; a library ships one, lib<library>_native.so.1", .{shared.len});
    for (shared) |s| {
        const link = linkName(s.name) orelse return refuse(alloc, "shared library name `{s}` is not lib<name>.so.<number>", .{s.name});
        if (s.data.len == 0) return refuse(alloc, "{s} is empty", .{s.name});
        try list.append(.{ .path = try std.fmt.allocPrint(alloc, lib_dir ++ "{s}", .{s.name}), .kind = .shared, .data = s.data });
        try list.append(.{ .path = try std.fmt.allocPrint(alloc, lib_dir ++ "{s}", .{link}), .kind = .link, .data = s.data, .target = s.name });
    }
    for (statics) |s| {
        if (!staticName(s.name)) return refuse(alloc, "static archive name `{s}` is not lib<name>.a", .{s.name});
        if (s.data.len == 0) return refuse(alloc, "{s} is empty", .{s.name});
        try list.append(.{ .path = try std.fmt.allocPrint(alloc, lib_dir ++ "{s}", .{s.name}), .kind = .static, .data = s.data });
    }
    const files = try list.toOwnedSlice();
    std.mem.sort(LibFile, files, {}, lessLib);
    for (files[0..files.len -| 1], 0..) |f, i| {
        if (std.mem.eql(u8, f.path, files[i + 1].path)) return refuse(alloc, "{s} given twice", .{f.path});
    }
    return files;
}

fn given(alloc: Alloc, a: Args, flag: []const u8) ![]Given {
    var list = std.ArrayList(Given).init(alloc);
    for (try all(alloc, a, flag)) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse pack_common.fail("{s} `{s}` is not <file name>=<file>", .{ flag, v });
        try list.append(.{ .name = v[0..eq], .data = pack_common.readAll(alloc, v[eq + 1 ..]) });
    }
    return list.toOwnedSlice();
}

/// The `--lib-shared` and `--lib-static` files of the command line.
pub fn libFiles(alloc: Alloc, a: Args) ![]LibFile {
    const files = libFilesOf(alloc, try given(alloc, a, "--lib-shared"), try given(alloc, a, "--lib-static")) catch |err| switch (err) {
        error.Refused => pack_common.fail("{s}", .{why}),
        else => return err,
    };
    return files;
}

/// The `__glibc` run requirement of a package shipping native files, from the
/// floor version given (`2.34`): `__glibc >=2.34`.
pub fn glibcRequirement(alloc: Alloc, floor: []const u8) Error![]const u8 {
    var parts = std.mem.splitScalar(u8, floor, '.');
    var n: usize = 0;
    while (parts.next()) |p| : (n += 1) {
        if (p.len == 0) return refuse(alloc, "glibc floor `{s}` is not <major>.<minor>", .{floor});
        for (p) |c| if (!std.ascii.isDigit(c)) return refuse(alloc, "glibc floor `{s}` is not <major>.<minor>", .{floor});
    }
    if (n != 2) return refuse(alloc, "glibc floor `{s}` is not <major>.<minor>", .{floor});
    return std.fmt.allocPrint(alloc, "__glibc >={s}", .{floor});
}

/// The `__glibc` requirement of the command line: `--glibc-floor` is given
/// exactly when the package ships native files.
pub fn glibcOf(alloc: Alloc, a: Args, files: []const LibFile) !?[]const u8 {
    const floor = one(a, "--glibc-floor");
    if (files.len == 0) {
        if (floor != null) pack_common.fail("--glibc-floor is given, but the package ships no native file", .{});
        return null;
    }
    const f = floor orelse pack_common.fail("the package ships native files and no --glibc-floor (the platform table's os_floor)", .{});
    return glibcRequirement(alloc, f) catch |err| switch (err) {
        error.Refused => pack_common.fail("{s}", .{why}),
        else => return err,
    };
}

// ---- NEEDED --------------------------------------------------------------

fn rd(comptime T: type, b: []const u8, off: u64) Error!T {
    if (off > b.len or b.len - off < @sizeOf(T)) {
        why = "ELF: a header or table points past the end of the file";
        return error.Refused;
    }
    const at: usize = @intCast(off);
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

const SHT_DYNAMIC: u32 = 6;
const DT_NULL: u64 = 0;
const DT_NEEDED: u64 = 1;

/// The NEEDED entries of a 64-bit little-endian ELF shared object, in order,
/// read from its SHT_DYNAMIC section and the string table it links. Refused:
/// any other file, no dynamic section, a name outside its string table.
pub fn needed(alloc: Alloc, elf: []const u8) Error![]const []const u8 {
    if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF") or elf[4] != 2 or elf[5] != 1) {
        why = "not a 64-bit little-endian ELF file";
        return error.Refused;
    }
    const shoff = try rd(u64, elf, 0x28);
    const shentsize = try rd(u16, elf, 0x3A);
    const shnum = try rd(u16, elf, 0x3C);
    if (shentsize != 64) {
        why = "ELF: section header entries are not 64 bytes";
        return error.Refused;
    }
    var list = std.ArrayList([]const u8).init(alloc);
    var seen = false;
    var i: u64 = 0;
    while (i < shnum) : (i += 1) {
        const sh = shoff + i * 64;
        if (try rd(u32, elf, sh + 4) != SHT_DYNAMIC) continue;
        if (seen) {
            why = "ELF: two dynamic sections";
            return error.Refused;
        }
        seen = true;
        const off = try rd(u64, elf, sh + 0x18);
        const size = try rd(u64, elf, sh + 0x20);
        const link = try rd(u32, elf, sh + 0x28);
        if (link >= shnum) {
            why = "ELF: the dynamic section links no section";
            return error.Refused;
        }
        const str_sh = shoff + @as(u64, link) * 64;
        const str_off = try rd(u64, elf, str_sh + 0x18);
        const str_size = try rd(u64, elf, str_sh + 0x20);
        if (str_off > elf.len or elf.len - str_off < str_size) {
            why = "ELF: the dynamic string table points past the end of the file";
            return error.Refused;
        }
        const strtab = elf[@intCast(str_off)..@intCast(str_off + str_size)];
        var at: u64 = 0;
        while (at + 16 <= size) : (at += 16) {
            const tag = try rd(u64, elf, off + at);
            if (tag == DT_NULL) break;
            if (tag != DT_NEEDED) continue;
            const name_at = try rd(u64, elf, off + at + 8);
            if (name_at >= strtab.len) {
                why = "ELF: a NEEDED name points outside the dynamic string table";
                return error.Refused;
            }
            const rest = strtab[@intCast(name_at)..];
            const end = std.mem.indexOfScalar(u8, rest, 0) orelse {
                why = "ELF: a NEEDED name has no terminating NUL";
                return error.Refused;
            };
            try list.append(rest[0..end]);
        }
    }
    if (!seen) {
        why = "ELF: no dynamic section (not a shared object)";
        return error.Refused;
    }
    return list.toOwnedSlice();
}

/// Refused when `needed` names a komira library's shared library (`libkomira_`)
/// that is not among `owners`, the shared libraries of the Mojo deps closure.
pub fn checkNeededOwners(alloc: Alloc, library: []const u8, path: []const u8, needs: []const []const u8, owners: []const []const u8) Error!void {
    for (needs) |n| {
        if (!std.mem.startsWith(u8, n, "libkomira_")) continue;
        var found = false;
        for (owners) |o| found = found or std.mem.eql(u8, o, n);
        if (!found) return refuse(alloc, "{s}: {s} has NEEDED {s}, whose library is not in the Mojo deps closure of {s}; its package requires only its Mojo deps, so that library would not be installed with it. Add the library owning {s} to the deps of {s}", .{ library, path, n, library, n, library });
    }
}

/// The `__glibc` requirement the packer writes, returned only after every
/// packed shared library's NEEDED passed the closure check: the requirement
/// cannot be written without the check.
pub fn checkedGlibc(alloc: Alloc, library: []const u8, files: []const LibFile, floor: []const u8, owners: []const []const u8) Error![]const u8 {
    for (files) |f| {
        if (f.kind != .shared) continue;
        const needs = needed(alloc, f.data) catch |err| switch (err) {
            error.Refused => return refuse(alloc, "{s}: {s}", .{ f.path, why }),
            else => return err,
        };
        try checkNeededOwners(alloc, library, f.path, needs, owners);
    }
    return glibcRequirement(alloc, floor);
}

/// `checkedGlibc` of the command line (`komira_pack conda`).
pub fn packedGlibc(alloc: Alloc, a: Args, library: []const u8, files: []const LibFile) !?[]const u8 {
    // Refuses a --glibc-floor missing or given without native files.
    _ = try glibcOf(alloc, a, files);
    if (files.len == 0) return null;
    return checkedGlibc(alloc, library, files, one(a, "--glibc-floor").?, try all(alloc, a, "--closure-owner")) catch |err| switch (err) {
        error.Refused => pack_common.fail("{s}", .{why}),
        else => return err,
    };
}

/// Refused unless the pkg tar member at `l.path` (its `mode`, `link` target
/// and `data`) is `l`: a shared library 0755 with its bytes, its link name a
/// symbolic link (0777) to the SONAME holding no data, a static archive 0644.
pub fn checkMember(alloc: Alloc, mode: u32, link: []const u8, data: []const u8, l: LibFile) Error!void {
    if (mode != l.mode()) return refuse(alloc, "pkg tar: {s} has mode {o}, must be {o}", .{ l.path, mode, l.mode() });
    if (!std.mem.eql(u8, link, l.target)) return refuse(alloc, "pkg tar: {s} links to `{s}`, must be `{s}`", .{ l.path, link, l.target });
    const want: []const u8 = if (l.kind == .link) "" else l.data;
    if (!std.mem.eql(u8, data, want)) return refuse(alloc, "pkg tar: {s} differs from the library's native file ({d} bytes against {d})", .{ l.path, data.len, want.len });
}

// ---- rows ----------------------------------------------------------------

/// The info/paths.json row of a packed native file.
pub fn pathRow(alloc: Alloc, f: LibFile) !json.Value {
    var row = newObject(alloc);
    try row.object.put("_path", str(f.path));
    try row.object.put("path_type", str(if (f.kind == .link) "softlink" else "hardlink"));
    try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(f.data))));
    try row.object.put("size_in_bytes", .{ .integer = @intCast(f.data.len) });
    return row;
}

pub fn find(files: []const LibFile, path: []const u8) ?LibFile {
    for (files) |f| if (std.mem.eql(u8, f.path, path)) return f;
    return null;
}

/// metadata.json's `lib_files`: one `{kind, path, sha256}` row per file, in
/// path order.
pub fn metadataRows(alloc: Alloc, files: []const LibFile) !json.Value {
    var rows = newArray(alloc);
    for (files) |f| {
        var row = newObject(alloc);
        try row.object.put("kind", str(@tagName(f.kind)));
        try row.object.put("path", str(f.path));
        try row.object.put("sha256", str(try alloc.dupe(u8, &sha256Hex(f.data))));
        try rows.array.append(row);
    }
    return rows;
}

fn rowStr(alloc: Alloc, row: json.Value, key: []const u8) Error![]const u8 {
    const v = row.object.get(key) orelse return refuse(alloc, "a lib_files row has no `{s}`", .{key});
    if (v != .string) return refuse(alloc, "a lib_files row's `{s}` is not a string", .{key});
    return v.string;
}

/// Refused unless `rows` (metadata.json's `lib_files`, null when absent) names
/// exactly `files`: one `{kind, path, sha256}` row each, in path order, the
/// sha256 that of the file's bytes. A package with no native file has no
/// `lib_files` key.
pub fn checkRows(alloc: Alloc, rows: ?json.Value, files: []const LibFile) Error!void {
    const r = rows orelse {
        if (files.len != 0) return refuse(alloc, "metadata has no lib_files, but the package ships {d} native file(s)", .{files.len});
        return;
    };
    if (files.len == 0) return refuse(alloc, "metadata has lib_files, but the package ships no native file", .{});
    if (r != .array) return refuse(alloc, "metadata lib_files is not a list", .{});
    for (files) |f| {
        var listed = false;
        for (r.array.items) |row| {
            if (row == .object) {
                const p = row.object.get("path") orelse continue;
                listed = listed or (p == .string and std.mem.eql(u8, p.string, f.path));
            }
        }
        if (!listed) return refuse(alloc, "metadata lib_files has no row for {s}", .{f.path});
    }
    if (r.array.items.len != files.len) return refuse(alloc, "metadata lib_files has {d} rows, the package ships {d} native file(s)", .{ r.array.items.len, files.len });
    for (files, r.array.items) |f, row| {
        if (row != .object or row.object.count() != 3) return refuse(alloc, "metadata lib_files rows are {{kind, path, sha256}}", .{});
        const path = try rowStr(alloc, row, "path");
        if (!std.mem.eql(u8, path, f.path)) return refuse(alloc, "metadata lib_files row `{s}` where {s} belongs (rows are in path order)", .{ path, f.path });
        const kind = try rowStr(alloc, row, "kind");
        if (!std.mem.eql(u8, kind, @tagName(f.kind))) return refuse(alloc, "metadata lib_files: {s} is kind `{s}`, not `{s}`", .{ f.path, kind, @tagName(f.kind) });
        const sha = try rowStr(alloc, row, "sha256");
        if (!std.mem.eql(u8, sha, &sha256Hex(f.data))) return refuse(alloc, "metadata lib_files: the sha256 of {s} is {s}, the file's is {s}", .{ f.path, sha, &sha256Hex(f.data) });
    }
}

// ---- tests ---------------------------------------------------------------
//
// Each test names the defect it catches: a sha256 row that differs from its
// file, rows missing a file, a constant `__glibc`, a NEEDED owner outside the
// closure. They run as a build action (`:komira_pack_unit`), and komira_pack
// is not built unless they pass.

const testing = std.testing;

fn testFiles(alloc: Alloc) ![]LibFile {
    return libFilesOf(alloc, &.{.{ .name = "libkomira_x_native.so.1", .data = "\x7fELF shared" }}, &.{.{ .name = "libkomira_x_holder.a", .data = "!<arch>\n" }});
}

test "a shared library ships with its link name, and a static archive beside it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const files = try testFiles(arena.allocator());
    try testing.expectEqual(@as(usize, 3), files.len);
    try testing.expectEqualStrings("lib/libkomira_x_holder.a", files[0].path);
    try testing.expectEqual(Kind.static, files[0].kind);
    try testing.expectEqualStrings("lib/libkomira_x_native.so", files[1].path);
    try testing.expectEqual(Kind.link, files[1].kind);
    try testing.expectEqualStrings("libkomira_x_native.so.1", files[1].target);
    try testing.expectEqualStrings("lib/libkomira_x_native.so.1", files[2].path);
    try testing.expectEqual(Kind.shared, files[2].kind);
    try testing.expectEqual(@as(?[]const u8, null), linkName("libkomira_x_native.so"));
    try testing.expectError(error.Refused, libFilesOf(arena.allocator(), &.{.{ .name = "libx.so", .data = "x" }}, &.{}));
}

test "lib_files rows: the rows written are accepted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    try checkRows(alloc, try metadataRows(alloc, files), files);
    try checkRows(alloc, null, &.{});
}

test "lib_files rows: a planted sha256 mismatch is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    const rows = try metadataRows(alloc, files);
    try rows.array.items[2].object.put("sha256", str(try alloc.dupe(u8, &sha256Hex("other bytes"))));
    try testing.expectError(error.Refused, checkRows(alloc, rows, files));
    try testing.expect(std.mem.indexOf(u8, why, "the sha256 of lib/libkomira_x_native.so.1") != null);
}

test "lib_files rows: rows missing a file are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    // The link's row dropped: the rows are the files with one left out.
    const rows = try metadataRows(alloc, &.{ files[0], files[2] });
    try testing.expectError(error.Refused, checkRows(alloc, rows, files));
    try testing.expect(std.mem.indexOf(u8, why, "no row for lib/libkomira_x_native.so") != null);
    // No lib_files at all, on a package shipping files.
    try testing.expectError(error.Refused, checkRows(alloc, null, files));
}

test "__glibc is the floor given, never a constant" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    // A floor no platform row has: a constant requirement cannot pass both.
    try testing.expectEqualStrings("__glibc >=2.17", try glibcRequirement(alloc, "2.17"));
    try testing.expectEqualStrings("__glibc >=2.34", try glibcRequirement(alloc, "2.34"));
    try testing.expectError(error.Refused, glibcRequirement(alloc, "glibc-2.34"));
    try testing.expectError(error.Refused, glibcRequirement(alloc, "2"));
}

/// A minimal ELF64 shared object: a null section, a dynamic section holding
/// one NEEDED per name, and its string table.
pub fn testElf(alloc: Alloc, names: []const []const u8) ![]u8 {
    var strtab = std.ArrayList(u8).init(alloc);
    try strtab.append(0);
    var dyn = std.ArrayList(u8).init(alloc);
    for (names) |n| {
        try dyn.writer().writeInt(u64, DT_NEEDED, .little);
        try dyn.writer().writeInt(u64, strtab.items.len, .little);
        try strtab.appendSlice(n);
        try strtab.append(0);
    }
    try dyn.writer().writeInt(u64, DT_NULL, .little);
    try dyn.writer().writeInt(u64, 0, .little);
    const dyn_off: u64 = 64;
    const str_off: u64 = dyn_off + dyn.items.len;
    const sh_off: u64 = str_off + strtab.items.len;
    var out = std.ArrayList(u8).init(alloc);
    var eh = [_]u8{0} ** 64;
    @memcpy(eh[0..4], "\x7fELF");
    eh[4] = 2;
    eh[5] = 1;
    std.mem.writeInt(u64, eh[0x28..0x30], sh_off, .little);
    std.mem.writeInt(u16, eh[0x3A..0x3C], 64, .little);
    std.mem.writeInt(u16, eh[0x3C..0x3E], 3, .little);
    try out.appendSlice(&eh);
    try out.appendSlice(dyn.items);
    try out.appendSlice(strtab.items);
    try out.appendNTimes(0, 64); // section 0
    var sh = [_]u8{0} ** 64;
    std.mem.writeInt(u32, sh[4..8], SHT_DYNAMIC, .little);
    std.mem.writeInt(u64, sh[0x18..0x20], dyn_off, .little);
    std.mem.writeInt(u64, sh[0x20..0x28], dyn.items.len, .little);
    std.mem.writeInt(u32, sh[0x28..0x2C], 2, .little);
    try out.appendSlice(&sh);
    sh = [_]u8{0} ** 64;
    std.mem.writeInt(u32, sh[4..8], 3, .little);
    std.mem.writeInt(u64, sh[0x18..0x20], str_off, .little);
    std.mem.writeInt(u64, sh[0x20..0x28], strtab.items.len, .little);
    try out.appendSlice(&sh);
    return out.toOwnedSlice();
}

test "NEEDED is read from the dynamic section" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const elf = try testElf(alloc, &.{ "libkomira_crypto_native.so.1", "libc.so.6" });
    const needs = try needed(alloc, elf);
    try testing.expectEqual(@as(usize, 2), needs.len);
    try testing.expectEqualStrings("libkomira_crypto_native.so.1", needs[0]);
    try testing.expectEqualStrings("libc.so.6", needs[1]);
    // The string table's section header cut off: a table past the end of the file.
    try testing.expectError(error.Refused, needed(alloc, elf[0 .. elf.len - 64]));
    try testing.expectError(error.Refused, needed(alloc, "!<arch>\n"));
}

test "a NEEDED owner missing from the Mojo closure is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const needs = try needed(alloc, try testElf(alloc, &.{ "libkomira_crypto_native.so.1", "libc.so.6" }));
    const lib = "lib/libkomira_http_core_native.so.1";
    // komira_http_core with komira_crypto in its closure: accepted.
    try checkNeededOwners(alloc, "komira_http_core", lib, needs, &.{ "libkomira_crypto_native.so.1", "libkomira_http_core_native.so.1" });
    // komira_http_core packed with its crypto dependency removed: refused.
    try testing.expectError(error.Refused, checkNeededOwners(alloc, "komira_http_core", lib, needs, &.{"libkomira_http_core_native.so.1"}));
    try testing.expect(std.mem.indexOf(u8, why, "NEEDED libkomira_crypto_native.so.1") != null);
}

test "the packer's __glibc comes only after the NEEDED check" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const elf = try testElf(alloc, &.{ "libkomira_crypto_native.so.1", "libc.so.6" });
    const files = try libFilesOf(alloc, &.{.{ .name = "libkomira_http_core_native.so.1", .data = elf }}, &.{});
    try testing.expectEqualStrings("__glibc >=2.17", try checkedGlibc(alloc, "komira_http_core", files, "2.17", &.{"libkomira_crypto_native.so.1"}));
    try testing.expectError(error.Refused, checkedGlibc(alloc, "komira_http_core", files, "2.17", &.{"libkomira_http_core_native.so.1"}));
    try testing.expect(std.mem.indexOf(u8, why, "NEEDED libkomira_crypto_native.so.1") != null);
}

test "lib_files rows: a sha256 mismatch on ANY row is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    for (files, 0..) |f, i| {
        const rows = try metadataRows(alloc, files);
        try rows.array.items[i].object.put("sha256", str(try alloc.dupe(u8, &sha256Hex("other bytes"))));
        try testing.expectError(error.Refused, checkRows(alloc, rows, files));
        const want = try std.fmt.allocPrint(alloc, "the sha256 of {s} is", .{f.path});
        try testing.expect(std.mem.indexOf(u8, why, want) != null);
    }
}

test "lib_files rows: a row for a file the package does not ship is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    // One extra row after the files' rows.
    var rows = try metadataRows(alloc, files);
    const extra = try metadataRows(alloc, &.{.{ .path = "lib/libz_extra.a", .kind = .static, .data = "!<arch>\n" }});
    try rows.array.append(extra.array.items[0]);
    try testing.expectError(error.Refused, checkRows(alloc, rows, files));
    try testing.expect(std.mem.indexOf(u8, why, "rows, the package ships") != null);
    // Rows on a package shipping no native file.
    try testing.expectError(error.Refused, checkRows(alloc, try metadataRows(alloc, files), &.{}));
    try testing.expect(std.mem.indexOf(u8, why, "ships no native file") != null);
}

test "pkg tar members: a native file's mode, link target and bytes are checked" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const files = try testFiles(alloc);
    // As the packer writes them: accepted.
    try checkMember(alloc, 0o644, "", files[0].data, files[0]);
    try checkMember(alloc, 0o777, "libkomira_x_native.so.1", "", files[1]);
    try checkMember(alloc, 0o755, "", files[2].data, files[2]);
    // A shared library that is not executable.
    try testing.expectError(error.Refused, checkMember(alloc, 0o644, "", files[2].data, files[2]));
    // A static archive that is.
    try testing.expectError(error.Refused, checkMember(alloc, 0o755, "", files[0].data, files[0]));
    // The link name pointing elsewhere, or a regular file.
    try testing.expectError(error.Refused, checkMember(alloc, 0o777, "libother.so.1", "", files[1]));
    try testing.expectError(error.Refused, checkMember(alloc, 0o777, "", files[1].data, files[1]));
    // Changed bytes.
    try testing.expectError(error.Refused, checkMember(alloc, 0o755, "", "\x7fELF other", files[2]));
}
