//! `migrate` and `migrate --verify`: the file each example becomes, the
//! README they leave, the refusals, and the proof over the migrated README of
//! src/anomaly (the fixture of tests//functional/readme_examples/source_first,
//! whose files that library compiles and runs).

const std = @import("std");
const examples = @import("examples.zig");
const inc = @import("include.zig");
const mig = @import("migrate.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

fn ex(module: bool, code: []const []const u8) examples.Example {
    return .{ .line = 1, .module = module, .code = code, .code_lines = &.{} };
}

test "a mojo example's leading imports, a parenthesised one too, go above main; the rest is indented into it" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = [_][]const u8{ "from a import (", "    x,", "    y,", ")", "", "from b import z", "", "# set up", "var q = x", "" };
    try t.expectEqualStrings("from a import (\n    x,\n    y,\n)\n\nfrom b import z\n\n\ndef main() raises:\n    # set up\n    var q = x\n", try mig.exampleFile(a, ex(false, &code)));
}

test "an example of imports alone keeps them in main; one of comments alone gets pass" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("def main() raises:\n    from a import b\n", try mig.exampleFile(a, ex(false, &.{"from a import b"})));
    try t.expectEqualStrings("def main() raises:\n    # nothing\n    pass\n", try mig.exampleFile(a, ex(false, &.{"# nothing"})));
    try t.expectEqualStrings("def main() raises:\n    print(1)\n", try mig.exampleFile(a, ex(false, &.{ "", "print(1)", "" })));
}

test "a module example is its lines as they are, without blank lines at either end" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code = [_][]const u8{ "", "struct S:", "    var x: Int", "", "def main():", "    pass", "" };
    try t.expectEqualStrings("struct S:\n    var x: Int\n\ndef main():\n    pass\n", try mig.exampleFile(a, ex(true, &code)));
}

const SMALL = "# R\n\n<!-- mojo-hidden\nfrom std.testing import assert_equal\n-->\n```mojo\nvar x = 1\n```\n<!-- mojo-hidden assert_equal(x, 1) -->\n\n" ++
    "~~~~mojo module\ndef main():\n    print(\"```\")\n~~~~\nTail.\n";

test "migrate makes each example a file and its fence and hidden comments an include, keeping every other line" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = switch (try mig.migrate(a, SMALL, "R.md")) {
        .migrated => |m| m,
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    try t.expectEqual(@as(usize, 2), m.files.len);
    try t.expectEqualStrings("examples/example_1.mojo", m.files[0].path);
    try t.expectEqualStrings("from std.testing import assert_equal\n\n\ndef main() raises:\n    var x = 1\n    assert_equal(x, 1)\n", m.files[0].data);
    try t.expectEqualStrings("examples/example_2.mojo", m.files[1].path);
    try t.expectEqualStrings("def main():\n    print(\"```\")\n", m.files[1].data);
    try t.expectEqualStrings("# R\n\n<!-- include examples/example_1.mojo -->\n```mojo\nfrom std.testing import assert_equal\n\n\ndef main() raises:\n    var x = 1\n    assert_equal(x, 1)\n```\n\n" ++
        "<!-- include examples/example_2.mojo -->\n~~~~mojo\ndef main():\n    print(\"```\")\n~~~~\nTail.\n", m.readme);
    // And the proof holds.
    try t.expectEqual(@as(usize, 0), (try mig.verify(a, SMALL, "R.md", m.readme, m.files)).len);
}

fn refusalOf(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    return switch (try mig.migrate(a, text, "R.md")) {
        .migrated => "",
        .refused => |why| why,
    };
}

test "migrate refuses a README already source-first, an indented example, a line ending in a space, and what the reader refuses" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("R.md:1: the README holds an include marker already: migrate reads a README of the inline model", try refusalOf(a, "<!-- include examples/a.mojo -->\n```mojo\n```\n"));
    try t.expectEqualStrings("R.md:3: the example is indented (in a list item, say): an include marker starts its line, so move the fence out first", try refusalOf(a, "- item\n\n  ```mojo\n  print(1)\n  ```\n"));
    try t.expectEqualStrings("R.md:2: the line ends in a space or a tab, which a shown file may not", try refusalOf(a, "```mojo\nprint(1) \n```\n"));
    try t.expectEqualStrings("R.md:1: `mojo skip`: an example's info string is `mojo` or `mojo module`; nothing else may follow `mojo` (there is no skip word: fence a sketch that cannot run as ```text)", try refusalOf(a, "```mojo skip\n```\n"));
}

// ---- the anomaly fixture ----------------------------------------------------------

const DISPLAY = "src/anomaly/README.md";

const Fixture = struct {
    inline_readme: []const u8,
    readme: []const u8,
    files: []const inc.Listed,
};

fn fixture(a: std.mem.Allocator) !Fixture {
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const dir = try std.fs.path.join(a, &.{ work, "anomaly" });
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    var files = std.ArrayList(inc.Listed).empty;
    for (1..5) |n| {
        const path = try mig.fileName(a, n);
        try files.append(a, .{ .path = path, .data = try d.readFileAlloc(a, path, 1 << 20) });
    }
    return .{
        .inline_readme = try d.readFileAlloc(a, "inline.md", 1 << 20),
        .readme = try d.readFileAlloc(a, "README.md", 1 << 20),
        .files = files.items,
    };
}

test "migrate of src/anomaly's README is the fixture, byte for byte" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    const m = switch (try mig.migrate(a, f.inline_readme, DISPLAY)) {
        .migrated => |m| m,
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    try t.expectEqualStrings(f.readme, m.readme);
    try t.expectEqual(f.files.len, m.files.len);
    for (f.files, m.files) |want, got| {
        try t.expectEqualStrings(want.path, got.path);
        try t.expectEqualStrings(want.data, got.data);
    }
}

test "migrate --verify proves the fixture: fresh, the same programs, the README changed only inside its examples" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    const refused = try mig.verify(a, f.inline_readme, DISPLAY, f.readme, f.files);
    try t.expectEqualStrings("", try std.mem.join(a, "\n", refused));
}

test "migrate --verify refuses one extra edit of the prose, naming its line" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    const edited = try std.mem.replaceOwned(u8, a, f.readme, "A series is checked before", "A series is validated before");
    const refused = try mig.verify(a, f.inline_readme, DISPLAY, edited, f.files);
    try t.expectEqualStrings("src/anomaly/README.md:20: the migrated README differs from the old one outside the examples:" ++
        " `A series is validated before anything computes on it:` where the old one has `A series is checked before anything computes on it:` (its line 20)", try std.mem.join(a, "\n", refused));
}

test "migrate --verify refuses a changed assert in a file and its fence, naming the file's line and the README's" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    const from = "assert_equal(good.validate(), SERIES_OK)";
    const to = "assert_equal(good.validate(), SERIES_REJECT_UNORDERED)";
    // Both changed, so the README is fresh: only the proof can tell.
    const readme = try std.mem.replaceOwned(u8, a, f.readme, from, to);
    const files = try a.dupe(inc.Listed, f.files);
    files[0].data = try std.mem.replaceOwned(u8, a, files[0].data, from, to);
    const refused = try mig.verify(a, f.inline_readme, DISPLAY, readme, files);
    try t.expectEqualStrings("src/anomaly/examples/example_1.mojo:9: not the program the gate runs today for the example at src/anomaly/README.md:23:" ++
        " `" ++ to ++ "` where that program has `" ++ from ++ "`\n" ++
        "src/anomaly/README.md:32: the example from old line 23 shows other code than it ran: `" ++ to ++ "` where the old README has `" ++ from ++ "`", try std.mem.join(a, "\n", refused));
}

test "migrate --verify refuses a missing file and one no example has" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    const files = [_]inc.Listed{ f.files[0], f.files[1], f.files[2], .{ .path = "examples/notes.txt", .data = "x\n" } };
    const refused = try mig.verify(a, f.inline_readme, DISPLAY, f.readme, &files);
    try t.expectEqualStrings("src/anomaly/README.md:98: include examples/example_4.mojo: no such example: the library's readme_examples (its BUCK file) lists no examples/example_4.mojo\n" ++
        "src/anomaly/README.md: examples/notes.txt is listed in readme_examples and no <!-- include examples/notes.txt --> shows it\n" ++
        "src/anomaly/README.md: examples/notes.txt is no example's file: the old README has 4 examples, so the files are example_1 to example_4\n" ++
        "src/anomaly/README.md: examples/example_4.mojo, the example at line 90, is missing", try std.mem.join(a, "\n", refused));
}

test "migrate --verify refuses an include naming another example's file" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const f = try fixture(a);
    // The first two includes swapped, with their fences: fresh, but out of order.
    const one = "<!-- include examples/example_1.mojo -->";
    const two = "<!-- include examples/example_2.mojo -->";
    var readme = try std.mem.replaceOwned(u8, a, f.readme, one, "@ONE@");
    readme = try std.mem.replaceOwned(u8, a, readme, two, one);
    readme = try std.mem.replaceOwned(u8, a, readme, "@ONE@", two);
    // The fences now show the other file, so fill would rewrite both: stale.
    const refused = try mig.verify(a, f.inline_readme, DISPLAY, readme, f.files);
    const text = try std.mem.join(a, "\n", refused);
    try t.expect(std.mem.indexOf(u8, text, "src/anomaly/README.md:22: the include of the example at old line 23 names examples/example_2.mojo, not examples/example_1.mojo") != null);
    try t.expect(std.mem.indexOf(u8, text, "src/anomaly/README.md:44: the include of the example at old line 42 names examples/example_1.mojo, not examples/example_2.mojo") != null);
    try t.expect(std.mem.indexOf(u8, text, "is stale") != null);
}
