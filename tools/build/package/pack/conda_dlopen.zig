//! komira_pack: the shared libraries a library's package opens at run time
//! (`mojo_library(dlopen = [...])`), checked against its sources, and the
//! conda-forge requirements they add to its package.
//!
//! The build gives the packer one `--dlopen <soname>=<requirement>` per
//! declared soname, the requirement taken from
//! tools/build/package/system_libs.bzl (a declaration that table lacks is
//! refused at analysis, before the packer runs). The packer reads the
//! library's sources: a source that opens a shared library names
//! `OwnedDLHandle` in its code, and the sonames it opens are its string
//! literals of the form `lib<name>.so[.<digits>]...`. Across those sources
//! the sonames must be exactly the declared ones; otherwise the package is
//! refused, naming both lists. Each declared requirement is then a run
//! requirement of the package, after the others, in soname order, once.
//!
//! What the reader counts as code: comments (`#` to the end of the line)
//! and triple-quoted strings (docstrings) are skipped, so a comment naming
//! `OwnedDLHandle("libz.so.1")` opens nothing. A soname held in a file that
//! does not itself name `OwnedDLHandle` is not seen; such a library is
//! refused (its declaration names a soname no opening source holds), never
//! packaged without the requirement.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const fail = pack_common.fail;
const lessStr = pack_common.lessStr;
const newArray = pack_common.newArray;
const newObject = pack_common.newObject;
const str = pack_common.str;

/// One declared shared library: the soname the sources open and the conda
/// requirement of the conda-forge package that ships it.
pub const Dlopen = struct { soname: []const u8, requirement: []const u8 };

/// A source file of the library: its path (for the refusal) and its text.
pub const Source = struct { path: []const u8, text: []const u8 };

fn lessDlopen(_: void, x: Dlopen, y: Dlopen) bool {
    return std.mem.lessThan(u8, x.soname, y.soname);
}

/// `lib<name>.so` with an optional tail of `.<digits>` parts: what a source
/// names when it opens a library by its soname (`libz.so.1`,
/// `libbz2.so.1.0`). `liblz4.dylib` and `libfoo.so.x` are not.
pub fn isSoname(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "lib")) return false;
    const at = std.mem.indexOf(u8, s, ".so") orelse return false;
    if (at == 3) return false;
    for (s[3..at]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '+')) return false;
    var rest = s[at + 3 ..];
    while (rest.len != 0) {
        if (rest[0] != '.' or rest.len < 2) return false;
        var i: usize = 1;
        while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
        if (i == 1) return false;
        rest = rest[i..];
    }
    return true;
}

/// A conda requirement on a package outside the release: `<name> <constraint>`,
/// the name lowercase letters, digits and `_.-`, the constraint version
/// characters and `<>=!,*`. Null when it is one, else what is wrong.
pub fn requirementProblem(r: []const u8) ?[]const u8 {
    const sp = std.mem.indexOfScalar(u8, r, ' ') orelse return "it is not `<name> <constraint>`";
    const name = r[0..sp];
    const cons = r[sp + 1 ..];
    if (name.len == 0 or cons.len == 0) return "it is not `<name> <constraint>`";
    for (name) |c| if (!(std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '_' or c == '.' or c == '-')) return "its name holds a character other than a-z, 0-9, `_`, `.`, `-`";
    for (cons) |c| if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "._+<>=!,*", c) != null)) return "its constraint holds a character other than a version's or `<>=!,*`";
    return null;
}

/// The `--dlopen <soname>=<requirement>` values, sorted by soname. A value
/// that is not that shape, a soname that is not one, a requirement that is
/// not one, or a soname given twice is a usage error (the build writes these).
pub fn parseDlopens(alloc: Alloc, values: []const []const u8) ![]Dlopen {
    var list = std.ArrayList(Dlopen).init(alloc);
    for (values) |v| {
        const eq = std.mem.indexOfScalar(u8, v, '=') orelse fail("--dlopen `{s}` is not <soname>=<requirement>", .{v});
        const so = v[0..eq];
        const req = v[eq + 1 ..];
        if (!isSoname(so)) fail("--dlopen `{s}`: `{s}` is not a soname (lib<name>.so[.<digits>]...)", .{ v, so });
        if (requirementProblem(req)) |why| fail("--dlopen `{s}`: requirement `{s}`: {s}", .{ v, req, why });
        for (list.items) |d| if (std.mem.eql(u8, d.soname, so)) fail("--dlopen {s} given twice", .{so});
        try list.append(.{ .soname = so, .requirement = req });
    }
    const out = try list.toOwnedSlice();
    std.mem.sort(Dlopen, out, {}, lessDlopen);
    return out;
}

/// What one source holds: whether its code names `OwnedDLHandle`, and the
/// sonames among its one-line string literals, each once, in order of
/// appearance. Comments and triple-quoted strings are not code.
pub const Scan = struct { opens: bool, sonames: [][]const u8 };

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

pub fn scanSource(alloc: Alloc, text: []const u8) !Scan {
    var opens = false;
    var found = std.ArrayList([]const u8).init(alloc);
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '#') {
            while (i < text.len and text[i] != '\n') i += 1;
        } else if ((c == '"' or c == '\'') and i + 2 < text.len and text[i + 1] == c and text[i + 2] == c) {
            const close = [3]u8{ c, c, c };
            i = if (std.mem.indexOfPos(u8, text, i + 3, &close)) |e| e + 3 else text.len;
        } else if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < text.len and text[j] != c and text[j] != '\n') : (j += 1) {
                if (text[j] == '\\') j += 1;
            }
            const end = @min(j, text.len);
            const lit = text[i + 1 .. end];
            if (isSoname(lit)) {
                var seen = false;
                for (found.items) |f| seen = seen or std.mem.eql(u8, f, lit);
                if (!seen) try found.append(lit);
            }
            i = end + 1;
        } else if (identChar(c)) {
            var j = i;
            while (j < text.len and identChar(text[j])) j += 1;
            if (std.mem.eql(u8, text[i..j], "OwnedDLHandle")) opens = true;
            i = j;
        } else i += 1;
    }
    return .{ .opens = opens, .sonames = try found.toOwnedSlice() };
}

/// Null when the sources open exactly the `declared` sonames (sorted, as
/// parseDlopens returns them), or open nothing and declare nothing;
/// otherwise why the package cannot be made: a source opens a soname the
/// declaration omits, the declaration names one no opening source holds,
/// or the library declares sonames and no source opens a library.
pub fn dlopenReason(alloc: Alloc, sources: []const Source, declared: []const Dlopen) !?[]const u8 {
    var opener: ?[]const u8 = null;
    var found = std.ArrayList([]const u8).init(alloc);
    for (sources) |s| {
        const scan = try scanSource(alloc, s.text);
        if (!scan.opens) continue;
        if (opener == null) opener = s.path;
        for (scan.sonames) |so| {
            var seen = false;
            for (found.items) |f| seen = seen or std.mem.eql(u8, f, so);
            if (!seen) try found.append(so);
        }
    }
    var decl = std.ArrayList(u8).init(alloc);
    for (declared, 0..) |d, i| {
        if (i != 0) try decl.appendSlice(", ");
        try decl.appendSlice(d.soname);
    }
    if (opener == null) {
        if (declared.len == 0) return null;
        return try std.fmt.allocPrint(alloc, "it declares `dlopen` [{s}], but no source opens a shared library (OwnedDLHandle); remove the stale declaration", .{decl.items});
    }
    std.mem.sort([]const u8, found.items, {}, lessStr);
    var same = found.items.len == declared.len and found.items.len != 0;
    if (same) {
        for (found.items, declared) |f, d| same = same and std.mem.eql(u8, f, d.soname);
    }
    if (same) return null;
    var names = std.ArrayList(u8).init(alloc);
    for (found.items, 0..) |f, i| {
        if (i != 0) try names.appendSlice(", ");
        try names.appendSlice(f);
    }
    return try std.fmt.allocPrint(alloc, "{s}: opens a shared library at run time (OwnedDLHandle); its sources name [{s}] and the library declares `dlopen` [{s}]: each soname it opens must be declared, and only those (tools/build/package/system_libs.bzl names the conda package its package then requires)", .{ opener.?, names.items, decl.items });
}

/// dlopenReason over every `.mojo` file under `dir_path` (the library's
/// `[src]` tree), in path order.
pub fn dlopenReasonDir(alloc: Alloc, dir_path: []const u8, declared: []const Dlopen) !?[]const u8 {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err|
        fail("cannot open sources {s}: {s}", .{ dir_path, @errorName(err) });
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var list = std.ArrayList(Source).init(alloc);
    while (try walker.next()) |w| {
        if (w.kind != .file or !std.mem.endsWith(u8, w.path, ".mojo")) continue;
        try list.append(.{ .path = try alloc.dupe(u8, w.path), .text = try dir.readFileAlloc(alloc, w.path, 1 << 28) });
    }
    if (list.items.len == 0) fail("sources {s} hold no .mojo file", .{dir_path});
    std.mem.sort(Source, list.items, {}, struct {
        fn less(_: void, x: Source, y: Source) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    return dlopenReason(alloc, list.items, declared);
}

/// `base` (the platform guard, the compiler pin, the komira dependencies)
/// followed by the requirement of each declared shared library, in soname
/// order, each requirement once: a library's run requirements.
pub fn withSystemRequirements(alloc: Alloc, base: []const []const u8, dl: []const Dlopen) ![][]const u8 {
    var list = std.ArrayList([]const u8).init(alloc);
    try list.appendSlice(base);
    for (dl, 0..) |d, i| {
        var dup = false;
        for (dl[0..i]) |e| dup = dup or std.mem.eql(u8, e.requirement, d.requirement);
        if (!dup) try list.append(d.requirement);
    }
    return list.toOwnedSlice();
}

/// metadata.json's `dlopen`: one `{requirement, soname}` per declared shared
/// library, in soname order. The key is written only when there is one, so
/// a package that opens nothing is byte-identical to one written before
/// declarations existed.
pub fn dlopenRows(alloc: Alloc, dl: []const Dlopen) !json.Value {
    var rows = newArray(alloc);
    for (dl) |d| {
        var row = newObject(alloc);
        try row.object.put("requirement", str(d.requirement));
        try row.object.put("soname", str(d.soname));
        try rows.array.append(row);
    }
    return rows;
}

// ---- tests (//tools/build/package:komira_pack_unit) ------------------------

const testing = std.testing;

fn testAlloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.heap.page_allocator);
}

/// The refusal, or a test failure (not a panic, so the other tests still run).
fn refusal(why: ?[]const u8) ![]const u8 {
    return why orelse error.ExpectedARefusal;
}

const zlib = Dlopen{ .soname = "libz.so.1", .requirement = "libzlib >=1.2.13,<2" };
const lz4 = Dlopen{ .soname = "liblz4.so.1", .requirement = "lz4-c >=1.9.3,<2" };

// The opening source of komira_zlib, reduced: the soname sits in a comptime
// constant beside a macOS name that is not a soname, and the call names the
// constant, not the literal.
const zlib_src =
    \\comptime _LIBZ: StaticString = (
    \\    "libz.dylib" if CompilationTarget.is_macos() else "libz.so.1"
    \\)
    \\def _open() raises -> OwnedDLHandle:
    \\    return OwnedDLHandle(_LIBZ)
    \\
;

test "isSoname: sonames and near misses" {
    for ([_][]const u8{ "libz.so.1", "libbz2.so.1.0", "liblz4.so.1", "libz.so", "libstdc++.so.6", "liblzma.so.5" }) |s| try testing.expect(isSoname(s));
    for ([_][]const u8{ "libz.dylib", "lib.so.1", "libz.so.", "libz.so.x", "libz.so1", "z.so.1", "libz.so.1.", "libz soname.so.1", "liblz4 dlopen failed" }) |s| try testing.expect(!isSoname(s));
}

test "requirementProblem: the map's rows pass, malformed ones do not" {
    for ([_][]const u8{ "libzlib >=1.2.13,<2", "lz4-c >=1.9.3,<2", "bzip2 >=1.0.8,<2", "xz >=5.2.5,<6", "zstd >=1.5.2,<2" }) |r| try testing.expect(requirementProblem(r) == null);
    for ([_][]const u8{ "libzlib", "libzlib ", " >=1", "LibZlib >=1", "libzlib >=1;rm" }) |r| try testing.expect(requirementProblem(r) != null);
}

test "scanSource: code opens; comments and docstrings do not" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const code = try scanSource(a, zlib_src);
    try testing.expect(code.opens);
    try testing.expectEqual(@as(usize, 1), code.sonames.len);
    try testing.expectEqualStrings("libz.so.1", code.sonames[0]);
    // A comment naming the call and a soname, and a docstring doing the same:
    // nothing is opened and no soname is held (src/kci_release_set's
    // system_libs.mojo names OwnedDLHandle("libzstd.so.1") in a comment).
    const quiet = try scanSource(a, "# OwnedDLHandle(\"libzstd.so.1\")\ndef f():\n    \"\"\"OwnedDLHandle(\"libz.so.1\")\n    \"\"\"\n    x = \"# not a comment\"\n");
    try testing.expect(!quiet.opens);
    try testing.expectEqual(@as(usize, 0), quiet.sonames.len);
    // A longer identifier is not the type; a literal after a `#` inside a
    // string is still read; an escaped quote does not end the literal.
    const near = try scanSource(a, "MyOwnedDLHandle = 1\nOwnedDLHandles = 2\ny = \"a#b\" + \"libbz2.so.1.0\" + \"x\\\"libq.so.1\"\n");
    try testing.expect(!near.opens);
    try testing.expectEqual(@as(usize, 1), near.sonames.len);
    try testing.expectEqualStrings("libbz2.so.1.0", near.sonames[0]);
}

test "dlopenReason: a declared soname is accepted" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try dlopenReason(a, &.{.{ .path = "zlib_ffi.mojo", .text = zlib_src }}, &.{zlib})) == null);
    // nothing opened, nothing declared: accepted
    try testing.expect((try dlopenReason(a, &.{.{ .path = "x.mojo", .text = "def f(): pass\n" }}, &.{})) == null);
}

test "dlopenReason: an undeclared soname is refused, naming both lists" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const why = try refusal(try dlopenReason(a, &.{.{ .path = "zlib_ffi.mojo", .text = zlib_src }}, &.{}));
    try testing.expect(std.mem.indexOf(u8, why, "zlib_ffi.mojo: opens a shared library at run time (OwnedDLHandle)") != null);
    try testing.expect(std.mem.indexOf(u8, why, "its sources name [libz.so.1] and the library declares `dlopen` []") != null);
    // declared one, opens two (the second in another opening source)
    const two = try refusal(try dlopenReason(a, &.{ .{ .path = "a.mojo", .text = zlib_src }, .{ .path = "b.mojo", .text = "h = OwnedDLHandle(\"liblz4.so.1\")\n" } }, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, two, "its sources name [liblz4.so.1, libz.so.1] and the library declares `dlopen` [libz.so.1]") != null);
}

test "dlopenReason: a declaration no source opens is refused" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // declares two, opens one
    const extra = try refusal(try dlopenReason(a, &.{.{ .path = "zlib_ffi.mojo", .text = zlib_src }}, &.{ lz4, zlib }));
    try testing.expect(std.mem.indexOf(u8, extra, "its sources name [libz.so.1] and the library declares `dlopen` [liblz4.so.1, libz.so.1]") != null);
    // declares one, opens nothing at all
    const stale = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = "s = \"libz.so.1\"\n" }}, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, stale, "declares `dlopen` [libz.so.1], but no source opens a shared library") != null);
    // opens with no soname literal it can see (the name is built elsewhere)
    const hidden = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = "h = OwnedDLHandle(name)\n" }}, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, hidden, "its sources name [] and the library declares `dlopen` [libz.so.1]") != null);
}

test "withSystemRequirements: each declared requirement follows the base, once" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "__linux", "mojo-compiler ==1.0.0", "fx_plain ==1.0.0 h00000000_0" };
    const got = try withSystemRequirements(a, &base, &.{ lz4, zlib });
    const want = [_][]const u8{ "__linux", "mojo-compiler ==1.0.0", "fx_plain ==1.0.0 h00000000_0", "lz4-c >=1.9.3,<2", "libzlib >=1.2.13,<2" };
    try testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| try testing.expectEqualStrings(w, g);
    // two sonames of one package: the requirement once
    const twice = try withSystemRequirements(a, &.{}, &.{ .{ .soname = "liba.so.1", .requirement = "a >=1,<2" }, .{ .soname = "liba.so.2", .requirement = "a >=1,<2" } });
    try testing.expectEqual(@as(usize, 1), twice.len);
    // nothing declared: the base unchanged
    try testing.expectEqual(base.len, (try withSystemRequirements(a, &base, &.{})).len);
}

test "dlopenRows: one {requirement, soname} per declaration" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const rows = try dlopenRows(a, &.{zlib});
    try testing.expectEqual(@as(usize, 1), rows.array.items.len);
    try testing.expectEqualStrings("libzlib >=1.2.13,<2", rows.array.items[0].object.get("requirement").?.string);
    try testing.expectEqualStrings("libz.so.1", rows.array.items[0].object.get("soname").?.string);
}
