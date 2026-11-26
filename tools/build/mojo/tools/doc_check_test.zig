//! Unit tests of doc_check.zig's parts: the declarations read from inspect's
//! output (what the check's awk program read), and the shown differences. The
//! whole tool is run by tests//negative/mojo_doc_json and the library docs.
const std = @import("std");
const D = @import("doc_check.zig");
const t = std.testing;

const sample =
    "decl\tpackages\t0\tname\tdocpkg\n" ++
    "decl\tpackages\t0\tsummary\tignored\n" ++
    "decl\tpackages\t0\tmodules\t0\tname\tshapes\n" ++
    "decl\tpackages\t0\tmodules\t0\tstructs\t0\tname\tGrid\n" ++
    "decl\tpackages\t0\tmodules\t0\tstructs\t0\tfields\t0\tname\tcells\n" ++
    "decl\tpackages\t0\tmodules\t0\tstructs\t0\tfunctions\t1\tname\tarea\n" ++
    "decl\tpackages\t0\tfunctions\t0\tname\tshout\n" ++
    "decl\tpackages\t0\tfunctions\t0\tname\tshout\n" ++
    "other\tpackages\t0\tname\tnotdecl\n" ++
    "decl\tpackages\tx\tname\tbadindex\n" ++
    "decl\tpackages\t5\tname\torphan_missing_parent_is_fine\n" ++
    "decl\tpackages\t0\tmodules\t3\tfunctions\t0\tname\tno_module_name\n" ++
    "name\tx\n" ++
    "\n";

fn has(list: []const []const u8, s: []const u8) bool {
    for (list) |x| {
        if (std.mem.eql(u8, x, s)) return true;
    }
    return false;
}

test "declarations: dotted paths of objects under the declaration kinds, sorted, unique" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const d = try D.declarations(arena.allocator(), sample);
    try t.expect(has(d, "docpkg"));
    try t.expect(has(d, "docpkg.shapes"));
    try t.expect(has(d, "docpkg.shapes.Grid"));
    try t.expect(has(d, "docpkg.shapes.Grid.area"));
    try t.expect(has(d, "docpkg.shout"));
    try t.expect(has(d, "orphan_missing_parent_is_fine"));
    // A struct field is no declaration the check walks; a bad index, another
    // root, a missing intermediate name and a bare `name` line are none.
    try t.expect(!has(d, "docpkg.shapes.Grid.cells"));
    try t.expect(!has(d, "badindex"));
    try t.expect(!has(d, "notdecl"));
    try t.expect(!has(d, "no_module_name"));
    // Sorted, and `shout` (listed twice) once.
    var shouts: usize = 0;
    for (d, 0..) |x, i| {
        if (std.mem.eql(u8, x, "docpkg.shout")) shouts += 1;
        if (i > 0) try t.expect(std.mem.lessThan(u8, d[i - 1], x));
    }
    try t.expectEqual(@as(usize, 1), shouts);
}

test "declarations: empty input has none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(usize, 0), (try D.declarations(arena.allocator(), "")).len);
}

test "differences: the changed lines only, golden's with - and the json's with +" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try D.differences(a, "a\nb\n    \"name\": \"greetings\",\nd\n", "a\nb\n    \"name\": \"greeting\",\nd\n", 40);
    try t.expectEqualStrings("-    \"name\": \"greetings\",\n+    \"name\": \"greeting\",\n", got);
}

test "differences: an added or removed tail, and at most max lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("+c\n", try D.differences(a, "a\nb\n", "a\nb\nc\n", 40));
    try t.expectEqualStrings("-c\n", try D.differences(a, "a\nb\nc\n", "a\nb\n", 40));
    try t.expectEqualStrings("-1\n-2\n", try D.differences(a, "1\n2\n3\n4\n", "x\ny\n", 2));
    try t.expectEqualStrings("", try D.differences(a, "same\n", "same\n", 40));
}

test "goldenAsCompared: each placeholder is the compiler's version, and nothing else changes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const raw = "{\n  \"x\": \"@MOJO_VERSION@ and @MOJO_VERSION@\",\n  \"version\": \"@MOJO_VERSION@\"\n}\n";
    try t.expectEqualStrings("{\n  \"x\": \"1.2.0 and 1.2.0\",\n  \"version\": \"1.2.0\"\n}\n", try D.goldenAsCompared(a, raw, "1.2.0"));
    try t.expectEqualStrings("{\n  \"x\": \"1.1.0 and 1.1.0\",\n  \"version\": \"1.1.0\"\n}\n", try D.goldenAsCompared(a, raw, "1.1.0"));
}

test "goldenAsCompared: with no version the golden is compared as written, the placeholder included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const raw = "{\"version\": \"@MOJO_VERSION@\"}";
    try t.expectEqualStrings(raw, try D.goldenAsCompared(arena.allocator(), raw, null));
}

test "goldenAsCompared: a golden that names a version literally is not rewritten, so it still fails on another compiler" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const raw = "{\"version\": \"1.1.0\"}";
    try t.expectEqualStrings(raw, try D.goldenAsCompared(arena.allocator(), raw, "1.2.0"));
}
