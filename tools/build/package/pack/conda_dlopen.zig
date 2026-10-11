//! komira_pack: the shared libraries a library's package opens at run time
//! (`mojo_library(dlopen = [...])`), checked against its sources, and the
//! conda-forge requirements they add to its package.
//!
//! The build gives the packer one `--dlopen <soname>=<requirement>` per
//! declared soname, the requirement taken from
//! tools/build/package/system_libs.bzl (a declaration that table lacks is
//! refused at analysis, before the packer runs). The packer reads every
//! `.mojo` file of the library's `[src]` tree:
//!
//! - The library OPENS a shared library if any of its sources names
//!   `OwnedDLHandle` in its code (comments and docstrings are not code).
//! - If it opens, the sonames FOUND are every string literal, in ALL its
//!   sources (not only the ones naming `OwnedDLHandle`), whose whole content
//!   is a soname, `lib<name>.so[.<digits>]...`, or is a path (it holds a
//!   `/`) whose last component is one: `"/usr/lib/liblz4.so.1"` and
//!   `"lib/liblz4.so.1"` both count as `liblz4.so.1`. Any quote form
//!   counts: `"..."`, `'...'`, `"""..."""`, `'''...'''`, and each of them
//!   with the raw prefix (`r"..."`). A triple-quoted string is read the
//!   same way, docstrings included: prose whose text after its last `/` is
//!   a soname counts as that soname (`"""Loads the library from
//!   /usr/lib/liblz4.so.1"""` counts as `liblz4.so.1`), which fails closed
//!   (it must be declared); other prose names none.
//! - The declared sonames must EQUAL the found ones; otherwise the package
//!   is refused, naming both sets and the sources holding each literal. A
//!   library that opens and holds no soname literal is refused too, even
//!   declaring nothing: what it opens cannot be seen.
//! - If it does not open, declaring `dlopen` is refused as stale.
//!
//! Each declared requirement is then a run requirement of the package,
//! after the others, in soname order, once.
//!
//! What the reader counts as code: comments (`#` to the end of the line)
//! and string literals are not code, so a comment or a docstring naming
//! `OwnedDLHandle("libz.so.1")` opens nothing. Strings end where the Mojo
//! lexer ends them: a backslash escapes the next character in every kind,
//! raw (`r"..."`) and triple-quoted ones included.
//!
//! The trade-off: the literals found are not tied to the call that opens.
//! A soname-shaped string anywhere in a library that opens (a constant kept
//! in another file, a name in a message) must be declared, so a stray one
//! refuses the package until it is declared or reworded: the check fails
//! closed, never packaging a library without a requirement it may need.
//!
//! Known limits, which fail OPEN (the package is made without the
//! requirement): a soname the sources build at run time from parts
//! (`"lib" + name + ".so.1"`) or spell with an escape (`"libz\x2eso.1"`) is
//! not found, since the reader compares a literal's bytes as written; and
//! only `.mojo` files are read, so a source named `*.🔥` is not (a library
//! whose only opener is one is read as opening nothing). The
//! installed-package checks are PLANNED, not built (step S12, the
//! installed-bytes checks of docs/design/continuous_publish.md), and their
//! design does not yet cover a run-time dlopen requirement
//! (komira-ai/komira#1327), so today this static check is the only guard.

const std = @import("std");
const json = std.json;
const Alloc = std.mem.Allocator;
const pack_common = @import("common.zig");
const fail = pack_common.fail;
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
/// string literals whose whole content is a soname (any quote form,
/// triple-quoted and raw included), each once, in order of appearance.
/// Comments and string literals are not code.
pub const Scan = struct { opens: bool, sonames: [][]const u8 };

fn identChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// The soname a literal names, or null: its whole content when that is a
/// soname, else, for a path (it holds a `/`), its last component when that
/// is one (`"/usr/lib/liblz4.so.1"` and `"lib/liblz4.so.1"` name
/// `liblz4.so.1`).
pub fn literalSoname(lit: []const u8) ?[]const u8 {
    const last = if (std.mem.lastIndexOfScalar(u8, lit, '/')) |k| lit[k + 1 ..] else lit;
    return if (isSoname(last)) last else null;
}

/// Appends the soname `lit` names to `list` if it names one not held yet.
fn holdOnce(list: *std.ArrayList([]const u8), lit: []const u8) !void {
    const so = literalSoname(lit) orelse return;
    for (list.items) |f| if (std.mem.eql(u8, f, so)) return;
    try list.append(so);
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
            // Ends at the first unescaped triple of its quote: a backslash
            // escapes the next character, as in the Mojo lexer (raw strings
            // included: `r"""a\"""` is unterminated to it). It names the
            // soname literalSoname finds, docstrings included: prose whose
            // text after its last `/` is a soname names that one (fails
            // closed); other prose names none.
            var j = i + 3;
            while (j < text.len and !(j + 2 < text.len and text[j] == c and text[j + 1] == c and text[j + 2] == c)) : (j += 1) {
                if (text[j] == '\\') j += 1;
            }
            try holdOnce(&found, text[i + 3 .. @min(j, text.len)]);
            i = @min(j + 3, text.len);
        } else if (c == '"' or c == '\'') {
            var j = i + 1;
            while (j < text.len and text[j] != c and text[j] != '\n') : (j += 1) {
                if (text[j] == '\\') j += 1;
            }
            const end = @min(j, text.len);
            try holdOnce(&found, text[i + 1 .. end]);
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

/// A soname found and the sources holding it, in source order.
const Held = struct { soname: []const u8, paths: std.ArrayList([]const u8) };

fn lessHeld(_: void, x: Held, y: Held) bool {
    return std.mem.lessThan(u8, x.soname, y.soname);
}

/// Null when the library opens nothing and declares nothing, or opens and
/// its sources hold exactly the `declared` sonames (sorted, as parseDlopens
/// returns them); otherwise why the package cannot be made. It opens when a
/// source names `OwnedDLHandle` in its code; once it does, the soname
/// literals of every source count, not only the opening ones'.
pub fn dlopenReason(alloc: Alloc, sources: []const Source, declared: []const Dlopen) !?[]const u8 {
    var opener: ?[]const u8 = null;
    var held = std.ArrayList(Held).init(alloc);
    for (sources) |s| {
        const scan = try scanSource(alloc, s.text);
        if (scan.opens and opener == null) opener = s.path;
        for (scan.sonames) |so| {
            var at: ?usize = null;
            for (held.items, 0..) |h, k| {
                if (std.mem.eql(u8, h.soname, so)) at = k;
            }
            if (at == null) {
                try held.append(.{ .soname = so, .paths = std.ArrayList([]const u8).init(alloc) });
                at = held.items.len - 1;
            }
            try held.items[at.?].paths.append(s.path);
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
    std.mem.sort(Held, held.items, {}, lessHeld);
    var same = held.items.len == declared.len and held.items.len != 0;
    if (same) {
        for (held.items, declared) |h, d| same = same and std.mem.eql(u8, h.soname, d.soname);
    }
    if (same) return null;
    var names = std.ArrayList(u8).init(alloc);
    var where = std.ArrayList(u8).init(alloc);
    for (held.items, 0..) |h, i| {
        if (i != 0) {
            try names.appendSlice(", ");
            try where.appendSlice("; ");
        }
        try names.appendSlice(h.soname);
        try where.appendSlice(h.soname);
        try where.appendSlice(" in ");
        for (h.paths.items, 0..) |p, k| {
            if (k != 0) try where.appendSlice(", ");
            try where.appendSlice(p);
        }
    }
    if (held.items.len == 0) try where.appendSlice("none");
    return try std.fmt.allocPrint(alloc, "{s}: opens a shared library at run time (OwnedDLHandle); its sources name [{s}] and the library declares `dlopen` [{s}]: once a library opens one, each soname-shaped string literal in its sources must be declared, and only those (tools/build/package/system_libs.bzl names the conda package its package then requires); the literals are held in: {s}", .{ opener.?, names.items, decl.items, where.items });
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
    // string is still read.
    const near = try scanSource(a, "MyOwnedDLHandle = 1\nOwnedDLHandles = 2\ny = \"a#b\" + \"libbz2.so.1.0\"\n");
    try testing.expect(!near.opens);
    try testing.expectEqual(@as(usize, 1), near.sonames.len);
    try testing.expectEqualStrings("libbz2.so.1.0", near.sonames[0]);
    // An escaped quote does not end the literal: `"\""` is one literal, so
    // the next one is `"libq.so.1"`. A reader that ended the first literal
    // at its escaped quote would pair the quotes the other way and read
    // `libq.so.1` as code, missing the soname.
    const esc = try scanSource(a, "y = \"\\\"\" + \"libq.so.1\"\n");
    try testing.expectEqual(@as(usize, 1), esc.sonames.len);
    try testing.expectEqualStrings("libq.so.1", esc.sonames[0]);
}

/// `text` opens and holds exactly [libz.so.1], and with nothing declared
/// the library is refused. A scanner that stops reading at a docstring or a
/// comment sees "opens nothing, declares nothing" and accepts: the package
/// would ship without the requirement.
fn expectOpensZlibAndRefusedUndeclared(text: []const u8) !void {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const scan = try scanSource(a, text);
    try testing.expect(scan.opens);
    try testing.expectEqual(@as(usize, 1), scan.sonames.len);
    try testing.expectEqualStrings("libz.so.1", scan.sonames[0]);
    const why = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = text }}, &.{}));
    try testing.expect(std.mem.indexOf(u8, why, "x.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [libz.so.1] and the library declares `dlopen` []") != null);
}

test "scanSource: code after a module docstring is read" {
    // Every Mojo module begins with one; the closing quotes end it.
    try expectOpensZlibAndRefusedUndeclared("\"\"\"doc\"\"\"\nh = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: code after a comment line is read" {
    // A comment ends at its newline, alone and after a docstring.
    try expectOpensZlibAndRefusedUndeclared("# opens zlib\nh = OwnedDLHandle(\"libz.so.1\")\n");
    try expectOpensZlibAndRefusedUndeclared("\"\"\"doc\"\"\"\n# opens zlib\nh = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: code after a multi-line docstring holding quotes is read" {
    // A lone `"` or `'` inside the docstring neither ends it nor opens a
    // literal; only the matching triple closes it, for either quote kind.
    try expectOpensZlibAndRefusedUndeclared("\"\"\"Opens zlib's \"libz\".\n\nIt's one \" and one ' here.\n\"\"\"\nh = OwnedDLHandle(\"libz.so.1\")\n");
    try expectOpensZlibAndRefusedUndeclared("'''Opens \"libz\".\nIt's here.\n'''\nh = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: code after a single-quoted string on the same line is read" {
    // A single-quoted literal ends at its closing `'`, not at the newline.
    try expectOpensZlibAndRefusedUndeclared("m = 'r'; h = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: a single-quoted soname literal is held" {
    var arena = testAlloc();
    defer arena.deinit();
    const scan = try scanSource(arena.allocator(), "h = OwnedDLHandle('libz.so.1')\n");
    try testing.expect(scan.opens);
    try testing.expectEqual(@as(usize, 1), scan.sonames.len);
    try testing.expectEqualStrings("libz.so.1", scan.sonames[0]);
}

test "scanSource: an escaped quote inside single quotes does not end the literal" {
    // `'a\'b'` is one literal. Ended at the escaped quote, the reader would
    // open a literal at the real closing `'` and run it to the newline,
    // swallowing the call.
    try expectOpensZlibAndRefusedUndeclared("m = 'a\\'b'; h = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: a raw-string prefix does not hide the literal" {
    // Mojo's `r"..."`: the prefix is read as an identifier and the literal
    // after it as a literal.
    try expectOpensZlibAndRefusedUndeclared("h = OwnedDLHandle(r\"libz.so.1\")\n");
}

test "scanSource: a backslash-quote inside a raw string does not end it" {
    // The Mojo 1.0 lexer, like Python's, does not end `r"a\"b"` at `\"`
    // (`r"a\"` alone is "unterminated string"; farm probe, fix round 3). A
    // reader treating backslashes in a raw string as plain characters would
    // end it at `\"` and swallow the call into the next literal.
    try expectOpensZlibAndRefusedUndeclared("p = r\"a\\\"b\"; h = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: an escaped quote inside a triple-quoted string does not end it" {
    // `"""x \""" y"""` is one string to the Mojo lexer. Ended at `\"""`, the
    // reader would start a new triple-quoted string at the real end and
    // swallow the code up to the next docstring: an opening source read as
    // opening nothing, its package made without the requirement.
    try expectOpensZlibAndRefusedUndeclared("\"\"\"x \\\"\"\" y\"\"\"\nh = OwnedDLHandle(\"libz.so.1\")\n\"\"\"end\"\"\"\n");
}

test "scanSource: an empty string literal does not open a triple-quoted string" {
    // `""` is two quotes, not the start of `"""`. A reader that opened a
    // triple-quoted string on two quotes would swallow the rest of the file
    // (sweep mutant M1, fix round 4).
    try expectOpensZlibAndRefusedUndeclared("x = \"\"\nh = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: an escaped backslash ends a one-line string at its quote" {
    // In `"a\\"` the backslash escapes the backslash, so the next quote ends
    // the literal. A reader that let a backslash escape only a quote would
    // read `\"` as an escaped quote and swallow the call on the same line
    // (sweep mutant M2, fix round 4).
    try expectOpensZlibAndRefusedUndeclared("x = \"a\\\\\"; h = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: a triple-single-quoted string holding a quote ends at its triple" {
    // `'''it's'''` is one string. A reader that knew only `"""` would pair
    // the quotes two by two, be left inside a literal at the odd one, and
    // swallow the call on the same line; `'''a'''` (an even count) would
    // not show it (sweep mutant M3, fix round 4).
    try expectOpensZlibAndRefusedUndeclared("d = '''it's'''; h = OwnedDLHandle(\"libz.so.1\")\n");
}

test "scanSource: OwnedDLHandle imported under another name opens" {
    // The rule is that the code names `OwnedDLHandle`, not that it calls it
    // by that name: here the call is `DL(...)`. A reader that counted only
    // `OwnedDLHandle(` would see nothing open and accept the undeclared
    // soname (mutant F1, fix round 6).
    try expectOpensZlibAndRefusedUndeclared("from std.ffi import OwnedDLHandle as DL\nh = DL(\"libz.so.1\")\n");
}

test "scanSource: OwnedDLHandle named only in a type annotation opens" {
    // The annotation names it with no `(` after the name; the handle comes
    // from a helper (mutant F1, fix round 6).
    try expectOpensZlibAndRefusedUndeclared("var h: OwnedDLHandle = _load(\"libz.so.1\")\n");
}

test "scanSource: OwnedDLHandle named only as a type parameter opens" {
    // `alloc[OwnedDLHandle]` is followed by `]`, not `(` (mutant F1, fix
    // round 6).
    try expectOpensZlibAndRefusedUndeclared("var p = alloc[OwnedDLHandle](1)\np.init_pointee_move(_load(\"libz.so.1\"))\n");
}

test "scanSource: OwnedDLHandle named only qualified opens" {
    // `std.ffi.OwnedDLHandle(...)`, with no import: the name follows a `.`.
    // A reader that skipped a name after `.` (as an attribute of something
    // else; mutant Q) or read `.` as part of an identifier, so the token is
    // `std.ffi.OwnedDLHandle` (mutant Q2), sees nothing open and accepts
    // the undeclared soname (fix round 7).
    try expectOpensZlibAndRefusedUndeclared("h = std.ffi.OwnedDLHandle(\"libz.so.1\")\n");
}

/// A `[src]` tree with a module at its top that opens nothing and the
/// opener one directory down, at sub/opener.mojo; `dlopenReasonDir` over it
/// with `declared`. The top module keeps a reader that skipped
/// subdirectories from stopping at "no .mojo file": it would read the tree
/// as opening nothing (sweep mutant X2, fix round 4).
fn reasonForSubdirOpener(a: Alloc, declared: []const Dlopen) !?[]const u8 {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile("top.mojo", "def f() -> Int:\n    return 1\n");
    try tmp.dir.makeDir("sub");
    try tmp.dir.writeFile("sub/opener.mojo", "h = OwnedDLHandle(\"libz.so.1\")\n");
    const root = try tmp.dir.realpathAlloc(a, ".");
    return dlopenReasonDir(a, root, declared);
}

test "dlopenReasonDir: an opener in a subdirectory, undeclared, is refused" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const why = try refusal(try reasonForSubdirOpener(a, &.{}));
    try testing.expect(std.mem.indexOf(u8, why, "sub/opener.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [libz.so.1] and the library declares `dlopen` []") != null);
}

test "dlopenReasonDir: an opener in a subdirectory, declared, is accepted" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(?[]const u8, null), try reasonForSubdirOpener(a, &.{zlib}));
}

test "isSoname: a version of several multi-digit parts" {
    try testing.expect(isSoname("libz.so.1.2.13"));
    try testing.expect(isSoname("libfoo.so.10"));
}

test "isSoname: underscores and dashes in the name" {
    try testing.expect(isSoname("libgcc_s.so.1"));
    try testing.expect(isSoname("libLLVM-17.so.1"));
}

test "isSoname: a dot in the name is not a soname" {
    // `lib<name>.so`, the name without dots: `libpython3.12.so.1.0` is
    // refused as a --dlopen value and not held by the scan (a source opening
    // it is then refused as opening an undeclared library, never accepted).
    try testing.expect(!isSoname("libpython3.12.so.1.0"));
    try testing.expect(!isSoname("libz.1.so.1"));
}

test "dlopenReason: a soname opened twice in one source counts once" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // z, lz4, z: the repeat is not next to its first (a reader comparing only
    // with the last one held keeps both)
    const text = "a = OwnedDLHandle(\"libz.so.1\")\nb = OwnedDLHandle(\"liblz4.so.1\")\nc = OwnedDLHandle(\"libz.so.1\")\n";
    const scan = try scanSource(a, text);
    try testing.expectEqual(@as(usize, 2), scan.sonames.len);
    try testing.expect((try dlopenReason(a, &.{.{ .path = "x.mojo", .text = text }}, &.{ lz4, zlib })) == null);
}

test "dlopenReason: a soname opened in two sources counts once" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const z = "h = OwnedDLHandle(\"libz.so.1\")\n";
    const l = "h = OwnedDLHandle(\"liblz4.so.1\")\n";
    try testing.expect((try dlopenReason(a, &.{ .{ .path = "a.mojo", .text = z }, .{ .path = "b.mojo", .text = l }, .{ .path = "c.mojo", .text = z } }, &.{ lz4, zlib })) == null);
}

test "dlopenReason: a declared soname held only by a source that opens nothing is accepted" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // names.mojo holds the lz4 soname but does not name OwnedDLHandle; the
    // library opens (zlib_ffi.mojo does), so every source's literals are
    // found: [liblz4.so.1, libz.so.1], as declared. Before fix round 7 only
    // opening sources were read and this was refused; reading them all is
    // what refuses the undeclared case below (P2).
    try testing.expectEqual(@as(?[]const u8, null), try dlopenReason(a, &.{ .{ .path = "names.mojo", .text = "LZ4 = \"liblz4.so.1\"\n" }, .{ .path = "zlib_ffi.mojo", .text = zlib_src } }, &.{ lz4, zlib }));
}

test "dlopenReason: a soname held in a source that opens nothing, undeclared, is refused" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // P2 (fix round 7): names.mojo keeps the lz4 soname in a constant and
    // ffi.mojo opens both libraries, lz4 through the constant; only libz is
    // declared. A reader of the opening sources alone finds [libz.so.1] and
    // accepts: the package would ship without lz4-c.
    const names = "comptime LZ4 = \"liblz4.so.1\"\n";
    const ffi = "from .names import LZ4\nz = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle(LZ4)\n";
    const why = try refusal(try dlopenReason(a, &.{ .{ .path = "ffi.mojo", .text = ffi }, .{ .path = "names.mojo", .text = names } }, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, why, "ffi.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [liblz4.so.1, libz.so.1] and the library declares `dlopen` [libz.so.1]") != null);
    // the refusal names the source holding each literal, in soname order,
    // every source of a literal held twice
    try testing.expect(std.mem.endsWith(u8, why, "the literals are held in: liblz4.so.1 in names.mojo; libz.so.1 in ffi.mojo"));
    const twice = try refusal(try dlopenReason(a, &.{ .{ .path = "ffi.mojo", .text = ffi }, .{ .path = "names.mojo", .text = "comptime LZ4 = \"liblz4.so.1\"\nZ = \"libz.so.1\"\n" } }, &.{}));
    try testing.expect(std.mem.endsWith(u8, twice, "the literals are held in: liblz4.so.1 in names.mojo; libz.so.1 in ffi.mojo, names.mojo"));
    // declared both: accepted
    try testing.expectEqual(@as(?[]const u8, null), try dlopenReason(a, &.{ .{ .path = "ffi.mojo", .text = ffi }, .{ .path = "names.mojo", .text = names } }, &.{ lz4, zlib }));
}

test "dlopenReason: a triple-quoted soname literal is found" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // P3 (fix round 7): `OwnedDLHandle("""liblz4.so.1""")`, and its `'''`
    // and raw forms. A reader that skipped every triple-quoted string as a
    // docstring finds [libz.so.1] and accepts with only libz declared.
    for ([_][]const u8{
        "z = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle(\"\"\"liblz4.so.1\"\"\")\n",
        "z = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle('''liblz4.so.1''')\n",
        "z = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle(r\"\"\"liblz4.so.1\"\"\")\n",
    }) |text| {
        const why = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = text }}, &.{zlib}));
        try testing.expect(std.mem.indexOf(u8, why, "its sources name [liblz4.so.1, libz.so.1] and the library declares `dlopen` [libz.so.1]") != null);
    }
    // a docstring of prose whose text after its last `/` (here the whole
    // text: it has none) is not a soname names none: declared exactly
    // libz, accepted
    const doc = "\"\"\"Opens libz.so.1 and never liblz4.so.1.\"\"\"\nz = OwnedDLHandle(\"libz.so.1\")\n";
    try testing.expectEqual(@as(?[]const u8, null), try dlopenReason(a, &.{.{ .path = "x.mojo", .text = doc }}, &.{zlib}));
}

test "dlopenReason: a docstring of prose ending in a soname path counts as that soname" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // Fix round 9 pins current behaviour: literalSoname takes the text
    // after a literal's last `/`, docstrings included, so this prose names
    // liblz4.so.1 and, with only libz declared, the package is refused
    // (fail closed). A reader that skipped prose would accept it.
    const doc = "\"\"\"Loads the library from /usr/lib/liblz4.so.1\"\"\"\nz = OwnedDLHandle(\"libz.so.1\")\n";
    const why = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = doc }}, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, why, "its sources name [liblz4.so.1, libz.so.1] and the library declares `dlopen` [libz.so.1]") != null);
    // declared both: accepted
    try testing.expectEqual(@as(?[]const u8, null), try dlopenReason(a, &.{.{ .path = "x.mojo", .text = doc }}, &.{ lz4, zlib }));
}

test "dlopenReason: a path literal counts as the soname it ends in" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // Fix round 8: `OwnedDLHandle("/usr/lib/liblz4.so.1")`, absolute and
    // relative, with only libz declared. A reader that compared only a
    // literal's whole content with the soname form finds [libz.so.1] and
    // accepts: the package would ship without lz4-c.
    for ([_][]const u8{
        "z = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle(\"/usr/lib/liblz4.so.1\")\n",
        "z = OwnedDLHandle(\"libz.so.1\")\nl = OwnedDLHandle(\"lib/liblz4.so.1\")\n",
    }) |text| {
        const why = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = text }}, &.{zlib}));
        try testing.expect(std.mem.indexOf(u8, why, "its sources name [liblz4.so.1, libz.so.1] and the library declares `dlopen` [libz.so.1]") != null);
        // declared both: accepted
        try testing.expectEqual(@as(?[]const u8, null), try dlopenReason(a, &.{.{ .path = "x.mojo", .text = text }}, &.{ lz4, zlib }));
    }
    // a path whose last component is not a soname names none; a soname
    // in a middle component does not count
    for ([_][]const u8{ "/usr/lib/", "/usr/lib/liblz4.so.1/x", "lib/liblz4.dylib" }) |lit| try testing.expectEqual(@as(?[]const u8, null), literalSoname(lit));
    try testing.expectEqualStrings("liblz4.so.1", literalSoname("./liblz4.so.1").?);
}

test "dlopenReason: the refusal names the first source that opens" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // n.mojo comes first and opens nothing; a.mojo and b.mojo open
    const why = try refusal(try dlopenReason(a, &.{ .{ .path = "n.mojo", .text = "x = 1\n" }, .{ .path = "a.mojo", .text = zlib_src }, .{ .path = "b.mojo", .text = "h = OwnedDLHandle(\"liblz4.so.1\")\n" } }, &.{}));
    try testing.expect(std.mem.startsWith(u8, why, "a.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [liblz4.so.1, libz.so.1]"));
}

test "dlopenReason: a declared soname is accepted" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try dlopenReason(a, &.{.{ .path = "zlib_ffi.mojo", .text = zlib_src }}, &.{zlib})) == null);
    // nothing opened, nothing declared: accepted
    try testing.expect((try dlopenReason(a, &.{.{ .path = "x.mojo", .text = "def f(): pass\n" }}, &.{})) == null);
    // two sonames opened from two sources, out of soname order, both
    // declared: accepted (the opened list is sorted before it is compared)
    try testing.expect((try dlopenReason(a, &.{ .{ .path = "a.mojo", .text = zlib_src }, .{ .path = "b.mojo", .text = "h = OwnedDLHandle(\"liblz4.so.1\")\n" } }, &.{ lz4, zlib })) == null);
}

test "dlopenReason: as many sonames declared as opened, but other names, is refused" {
    var arena = testAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    // komira_lz4 declaring zlib's soname: one opened, one declared, the
    // names differ. Accepted, its package would require libzlib and not
    // lz4-c, the package slice 3 must refuse.
    const lz4_src = "def _open() raises -> OwnedDLHandle:\n    return OwnedDLHandle(\"liblz4.so.1\")\n";
    const one = try refusal(try dlopenReason(a, &.{.{ .path = "lz4_ffi.mojo", .text = lz4_src }}, &.{zlib}));
    try testing.expect(std.mem.indexOf(u8, one, "lz4_ffi.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [liblz4.so.1] and the library declares `dlopen` [libz.so.1]") != null);
    // two opened, two declared, the first names equal and the second not:
    // every name is compared, not only the first
    const bz2 = Dlopen{ .soname = "libbz2.so.1.0", .requirement = "bzip2 >=1.0.8,<2" };
    const second = try refusal(try dlopenReason(a, &.{.{ .path = "c.mojo", .text = "a = OwnedDLHandle(\"libbz2.so.1.0\")\nb = OwnedDLHandle(\"libz.so.1\")\n" }}, &.{ bz2, lz4 }));
    try testing.expect(std.mem.indexOf(u8, second, "its sources name [libbz2.so.1.0, libz.so.1] and the library declares `dlopen` [libbz2.so.1.0, liblz4.so.1]") != null);
    // the first names differ and the second equal: not only the last
    const first = try refusal(try dlopenReason(a, &.{.{ .path = "c.mojo", .text = "a = OwnedDLHandle(\"libbz2.so.1.0\")\nb = OwnedDLHandle(\"libz.so.1\")\n" }}, &.{ lz4, zlib }));
    try testing.expect(std.mem.indexOf(u8, first, "its sources name [libbz2.so.1.0, libz.so.1] and the library declares `dlopen` [liblz4.so.1, libz.so.1]") != null);
    // names of one length: opens libz.so.1, declares libm.so.6 (a reader
    // comparing lengths, not bytes, accepts)
    const libm = Dlopen{ .soname = "libm.so.6", .requirement = "libm >=1,<2" };
    const same_len = try refusal(try dlopenReason(a, &.{.{ .path = "zlib_ffi.mojo", .text = zlib_src }}, &.{libm}));
    try testing.expect(std.mem.indexOf(u8, same_len, "its sources name [libz.so.1] and the library declares `dlopen` [libm.so.6]") != null);
    // opens a library by a name it cannot see and declares nothing: zero
    // opened and zero declared are equal counts, and still refused
    const unseen = try refusal(try dlopenReason(a, &.{.{ .path = "x.mojo", .text = "h = OwnedDLHandle(name)\n" }}, &.{}));
    try testing.expect(std.mem.indexOf(u8, unseen, "x.mojo: opens a shared library at run time (OwnedDLHandle); its sources name [] and the library declares `dlopen` []") != null);
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
