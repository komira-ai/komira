//! Unit tests of the readme_api_coverage scanners and census helpers. The whole
//! lint, on a planted tree and on the real one, is functional/readme_api_coverage
//! (the census must equal its expected files byte for byte) and
//! negative/readme_api_coverage (one planted defect each).
const std = @import("std");
const S = @import("readme_api_scan.zig");
const C = @import("readme_api_coverage.zig");
const t = std.testing;

fn arena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(t.allocator);
}

fn expectExport(e: S.Export, name: []const u8, orig: []const u8, path: []const u8, line: usize) !void {
    try t.expectEqualStrings(name, e.name);
    try t.expectEqualStrings(orig, e.orig);
    try t.expectEqualStrings(path, e.path);
    try t.expectEqual(line, e.line);
}

test "exports: relative, aliased, parenthesised, continued, module, own-name and declared" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\"""Docs.
        \\from .doc import Hidden
        \\"""
        \\from .greet import hello, farewell as bye
        \\from .shapes import (
        \\    Square,  # a comment
        \\    _private,
        \\    Circle,
        \\)
        \\from .box import \
        \\    Box
        \\from . import errors
        \\from mypkg.errors import NOT_FOUND as MISSING
        \\from other import Foreign
        \\# from .x import Commented
        \\from .star import *
        \\comptime ANSWER = 42
        \\def top_level() raises:
        \\    pass
        \\struct _Hidden:
        \\    pass
        \\struct Public:
        \\    pass
        \\
    ;
    const es = try S.exports(a, "mypkg", src);
    const want = [_][5][]const u8{
        .{ "hello", "hello", "greet", "4", "" },
        .{ "bye", "farewell", "greet", "4", "" },
        .{ "Square", "Square", "shapes", "5", "" },
        .{ "Circle", "Circle", "shapes", "5", "" },
        .{ "Box", "Box", "box", "10", "" },
        .{ "errors", "errors", "-", "12", "" },
        .{ "MISSING", "NOT_FOUND", "errors", "13", "" },
        .{ "*", "*", ".star", "16", "" },
        .{ "ANSWER", "ANSWER", "__init__", "17", "" },
        .{ "top_level", "top_level", "__init__", "18", "" },
        .{ "Public", "Public", "__init__", "22", "" },
    };
    try t.expectEqual(want.len, es.len);
    for (want, es) |w, e| try expectExport(e, w[0], w[1], w[2], try std.fmt.parseInt(usize, w[3], 10));
}

test "exports: a deeper module path and a parent module" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const es = try S.exports(a, "p", "from .a.b import X\nfrom ..up import Y\n");
    try t.expectEqual(@as(usize, 2), es.len);
    try expectExport(es[0], "X", "X", "a/b", 1);
    try expectExport(es[1], "Y", "Y", "/up", 2);
}

test "exports: the import needs 'import' followed by a blank; a lone module names nothing" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const es = try S.exports(a, "p", "from .a import(X)\nfrom .b\nfrom .c imported Y\nfrom .d import Z\n");
    try t.expectEqual(@as(usize, 1), es.len);
    try t.expectEqualStrings("Z", es[0].name);
}

fn methodsOf(a: std.mem.Allocator, src: []const u8) ![]S.Method {
    var out = std.ArrayList(S.Method).empty;
    try S.methods(a, "f.mojo", src, &out);
    return out.toOwnedSlice(a);
}

test "methods: public def/fn at four spaces of a column-0 struct; header may span lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\struct Box[
        \\    T: AnyType,
        \\](Copyable):
        \\    def get(self) -> Int: ...
        \\    fn put(mut self): ...
        \\    def _secret(self): ...
        \\    def __init__(out self): ...
        \\    def write_to(self, mut w): ...
        \\    def write_repr_to(self, mut w): ...
        \\    comptime Z = 1
        \\    """Docs.
        \\    def in_docs(self): ...
        \\    """
        \\        def deeper(self): ...
        \\def free(): ...
        \\    def not_in_struct(self): ...
        \\struct Next:
        \\    def get(self): ...
        \\
    ;
    const ms = try methodsOf(a, src);
    try t.expectEqual(@as(usize, 3), ms.len);
    try t.expectEqualStrings("Box", ms[0].strukt);
    try t.expectEqualStrings("get", ms[0].name);
    try t.expectEqual(@as(usize, 4), ms[0].line);
    try t.expectEqualStrings("put", ms[1].name);
    try t.expectEqualStrings("Next", ms[2].strukt);
    try t.expectEqual(@as(usize, 18), ms[2].line);
}

test "methods: a struct line in a docstring or a comment is not a struct" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const ms = try methodsOf(a, "\"\"\"\nstruct Fake:\n    def m(self): ...\n\"\"\"\n# struct Also:\n    def n(self): ...\n");
    try t.expectEqual(@as(usize, 0), ms.len);
}

fn usesOf(a: std.mem.Allocator, src: []const u8) !std.StringHashMap(void) {
    var keys = std.StringHashMap(void).init(a);
    var st = S.Ids{};
    for (try S.records(a, src)) |l| try st.feed(a, l, &keys);
    return keys;
}

test "uses: identifiers and attributes in code; not strings, comments, imports, declarations" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const src =
        \\from mypkg import Imported
        \\from mypkg import (
        \\    Multi,
        \\    Lines,
        \\)
        \\import os
        \\def main() raises:
        \\def helper(x: Int):
        \\    var local = used_fn(x)
        \\    s = obj.method("not_used_in_string") # nor_this
        \\    t = 'single_quoted'
        \\    u = """
        \\ triple_quoted
        \\    """
        \\    struct Declared: ...
        \\    v = After.attr.chain
    ;
    var uses = try usesOf(a, src);
    for ([_][]const u8{ "n\tused_fn", "n\tx", "n\tobj", "n\tmethod", "a\tmethod", "n\tAfter", "n\tattr", "a\tattr", "a\tchain", "n\ts", "n\tt", "n\tu", "n\tv" }) |k| try t.expect(uses.contains(k));
    for ([_][]const u8{ "n\tImported", "n\tMulti", "n\tLines", "n\tos", "n\tmain", "n\thelper", "n\tlocal", "n\tnot_used_in_string", "n\tnor_this", "n\tsingle_quoted", "n\ttriple_quoted", "n\tDeclared", "a\tobj", "a\tAfter" }) |k| try t.expect(!uses.contains(k));
}

test "uses: a string left open on one line runs to its end on a later one; a one-quote string ends with its line" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var uses = try usesOf(a, "x = '''\nhidden = 1\n''' + visible\ny = 'unterminated\nafter_line\n");
    try t.expect(uses.contains("n\tvisible"));
    try t.expect(uses.contains("n\tafter_line"));
    try t.expect(!uses.contains("n\thidden"));
    try t.expect(!uses.contains("n\tunterminated"));
}

test "percent: one decimal, an exact tie rounds to even, nothing exported is a dash" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("-", try C.percent(a, 0, 0, "%"));
    try t.expectEqualStrings("0.0%", try C.percent(a, 0, 5, "%"));
    try t.expectEqualStrings("100.0", try C.percent(a, 5, 5, ""));
    try t.expectEqualStrings("33.3", try C.percent(a, 1, 3, ""));
    try t.expectEqualStrings("66.7", try C.percent(a, 2, 3, ""));
    try t.expectEqualStrings("6.2", try C.percent(a, 1, 16, ""));
    try t.expectEqualStrings("18.8", try C.percent(a, 3, 16, ""));
    try t.expectEqualStrings("56.2", try C.percent(a, 9, 16, ""));
}

test "ledger: comments and blanks skipped; malformed and repeated rows are findings" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var report = std.ArrayList(u8).empty;
    const text = "# c\n\n  \npkg\tSym\twhy\npkg\tType.method\twhy\nbad row\npkg\tSym\tagain\npkg\tSym2\t \n9pkg\tS\tr\npkg\ta.b.c\tr\n";
    const rows = try C.parseLedger(a, "l.tsv", text, &report);
    try t.expectEqual(@as(usize, 2), rows.len);
    try t.expectEqualStrings("Type.method", rows[1].sym);
    try t.expectEqual(@as(usize, 5), rows[1].line);
    try t.expectEqualStrings(
        "l.tsv:6: a row is <package><TAB><symbol><TAB><reason>, with a reason\n" ++
            "l.tsv:7: pkg Sym has a row already, on line 4\n" ++
            "l.tsv:8: a row is <package><TAB><symbol><TAB><reason>, with a reason\n" ++
            "l.tsv:9: a row is <package><TAB><symbol><TAB><reason>, with a reason\n" ++
            "l.tsv:10: a row is <package><TAB><symbol><TAB><reason>, with a reason\n",
        report.items,
    );
}

test "symbols: names, then methods in the module the import names; overloads are one" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    const es = [_]S.Export{
        .{ .name = "Sq", .orig = "Sq", .path = "shapes", .line = 3 },
        .{ .name = "Sq", .orig = "Sq", .path = "shapes", .line = 4 },
        .{ .name = "errors", .orig = "errors", .path = "-", .line = 5 },
        .{ .name = "*", .orig = "*", .path = ".x", .line = 6 },
        .{ .name = "Alias", .orig = "Real", .path = "real", .line = 7 },
    };
    const ms = [_]S.Method{
        .{ .strukt = "Sq", .name = "area", .file = "src/p/other.mojo", .line = 1 },
        .{ .strukt = "Sq", .name = "area", .file = "src/p/shapes.mojo", .line = 2 },
        .{ .strukt = "Sq", .name = "area", .file = "src/p/shapes.mojo", .line = 9 },
        .{ .strukt = "Sq", .name = "perimeter", .file = "src/p/shapes.mojo", .line = 12 },
        .{ .strukt = "Real", .name = "go", .file = "src/p/other.mojo", .line = 4 },
    };
    var out = std.ArrayList(C.Symbol).empty;
    try C.symbolsOf(a, "p", "src/p", &es, &ms, &out);
    const want = [_][3][]const u8{
        .{ "name", "Sq", "src/p/__init__.mojo:3" },
        .{ "method", "Sq.area", "src/p/shapes.mojo:2" },
        .{ "method", "Sq.perimeter", "src/p/shapes.mojo:12" },
        .{ "name", "errors", "src/p/__init__.mojo:5" },
        .{ "name", "Alias", "src/p/__init__.mojo:7" },
        .{ "method", "Alias.go", "src/p/other.mojo:4" },
    };
    try t.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, s| {
        try t.expectEqualStrings(w[0], s.kind);
        try t.expectEqualStrings(w[1], s.sym);
        try t.expectEqualStrings(w[2], s.where);
    }
}

test "verdict text: control characters dropped, quote, backslash and tab escaped, 200 lines" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("a\\\"b\\\\c\\td\\n\\n", try C.escapedFindings(a, "a\"b\\c\td\x01\r\n\n"));
    var big = std.ArrayList(u8).empty;
    for (0..250) |_| try big.appendSlice(a, "x\n");
    const e = try C.escapedFindings(a, big.items);
    try t.expectEqual(@as(usize, 200), std.mem.count(u8, e, "\\n"));
}

fn touch(d: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |p| try d.makePath(p);
    const f = try d.createFile(path, .{});
    f.close();
}

test "packagesUnder: directories holding a file, not tests/, not files at the root; sorted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(tmp.dir, "src/zeta/x.mojo");
    try touch(tmp.dir, "src/alpha/deep/er/y.md");
    try touch(tmp.dir, "src/tests/e2e/z/z.mojo");
    try touch(tmp.dir, "src/loose.txt");
    try tmp.dir.makePath("src/empty/dir");
    const ps = try C.packagesUnder(a, tmp.dir, "src");
    try t.expectEqual(@as(usize, 2), ps.len);
    try t.expectEqualStrings("alpha", ps[0]);
    try t.expectEqualStrings("zeta", ps[1]);
    try t.expectEqual(@as(usize, 0), (try C.packagesUnder(a, tmp.dir, "nosuch")).len);
}

test "sourcesOf: the .mojo files of a package outside any tests/ directory, sorted" {
    var ar = arena();
    defer ar.deinit();
    const a = ar.allocator();
    var tmp = t.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try touch(tmp.dir, "src/p/b.mojo");
    try touch(tmp.dir, "src/p/a.mojo");
    try touch(tmp.dir, "src/p/sub/c.mojo");
    try touch(tmp.dir, "src/p/tests/t.mojo");
    try touch(tmp.dir, "src/p/sub/tests/u.mojo");
    try touch(tmp.dir, "src/p/notes.md");
    const fs = try C.sourcesOf(a, tmp.dir, "src", "p");
    const want = [_][]const u8{ "src/p/a.mojo", "src/p/b.mojo", "src/p/sub/c.mojo" };
    try t.expectEqual(want.len, fs.len);
    for (want, fs) |w, f| try t.expectEqualStrings(w, f);
}
