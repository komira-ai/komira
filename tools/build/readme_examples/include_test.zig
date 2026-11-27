//! A source-first README's includes: what the freshness check refuses (each
//! refusal naming its line), what `fill` writes, and the comments a renderer
//! drops (marker_comments.json, the cases shared with the package site).

const std = @import("std");
const inc = @import("include.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const D = "src/p/README.md";
const MAIN = "def main():\n    pass\n";

fn check(a: std.mem.Allocator, text: []const u8, listed: []const inc.Listed) !inc.Checked {
    return inc.check(a, text, D, listed);
}

fn refusals(a: std.mem.Allocator, c: inc.Checked) ![]const u8 {
    return std.mem.join(a, "\n", c.refusals);
}

const STALE_README = "# p\n\n<!-- include examples/a.mojo -->\n```mojo\ndef main():\n    print(1)\n```\n\nAfter.\n";

test "a README whose include is its file byte for byte passes, and fill changes nothing" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, STALE_README, &.{.{ .path = "examples/a.mojo", .data = "def main():\n    print(1)\n" }});
    try t.expectEqualStrings("", try refusals(a, c));
    try t.expect(c.fillable);
    try t.expectEqual(@as(usize, 1), c.shown);
    try t.expectEqualStrings(STALE_README, c.filled);
}

test "a file changed without fill is stale at its first differing line, and fill rewrites that fence body alone" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, STALE_README, &.{.{ .path = "examples/a.mojo", .data = "def main():\n    print(2)\n    print(3)\n" }});
    try t.expectEqualStrings("src/p/README.md:6: include examples/a.mojo is stale: this line is not line 2 of src/p/examples/a.mojo; " ++ inc.FILL_HINT, try refusals(a, c));
    try t.expect(c.fillable);
    try t.expectEqualStrings("# p\n\n<!-- include examples/a.mojo -->\n```mojo\ndef main():\n    print(2)\n    print(3)\n```\n\nAfter.\n", c.filled);
}

test "a fence shorter than the file is stale where it ends" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "<!-- include examples/a.mojo -->\n```mojo\ndef main():\n```\n";
    const c = try check(a, text, &.{.{ .path = "examples/a.mojo", .data = MAIN }});
    // Line 4 is the closing fence, where the file still has `    pass`.
    try t.expectEqualStrings("src/p/README.md:4: include examples/a.mojo is stale: this line is not line 2 of src/p/examples/a.mojo; " ++ inc.FILL_HINT, try refusals(a, c));
}

test "fill keeps every byte outside the fences: carriage returns and a missing final line feed" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "a\r\n<!-- include examples/a.mojo -->\r\n```mojo\r\nold\r\n```";
    const c = try check(a, text, &.{.{ .path = "examples/a.mojo", .data = "new\n" }});
    try t.expect(c.fillable);
    try t.expectEqualStrings("a\r\n<!-- include examples/a.mojo -->\r\n```mojo\r\nnew\r\n```", c.filled);
}

test "a file holding a line that would close the fence gets a longer fence from fill" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = "def main():\n    print(\"\"\"\n```\n\"\"\")\n";
    const text = "<!-- include examples/a.mojo -->\n```mojo\ndef main():\n```\n";
    const c = try check(a, text, &.{.{ .path = "examples/a.mojo", .data = file }});
    try t.expectEqualStrings("src/p/README.md:2: include examples/a.mojo: src/p/examples/a.mojo holds a line that closes a fence of 3, so its fence is 4 long; " ++ inc.FILL_HINT, try refusals(a, c));
    try t.expectEqualStrings("<!-- include examples/a.mojo -->\n````mojo\n" ++ file ++ "````\n", c.filled);
    // Filled, it passes.
    const again = try check(a, c.filled, &.{.{ .path = "examples/a.mojo", .data = file }});
    try t.expectEqualStrings("", try refusals(a, again));
}

test "a README with no example and no listed file passes, showing none" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, "# p\n\n```sh\nmopm add p\n```\n", &.{});
    try t.expectEqualStrings("", try refusals(a, c));
    try t.expectEqual(@as(usize, 0), c.shown);
}

test "every mojo fence is an include: a plain one and a module one are refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, "```mojo\nprint(1)\n```\n\n```mojo module\ndef main():\n    pass\n```\n", &.{});
    try t.expectEqualStrings("src/p/README.md:1: a ```mojo fence that shows no file: every example of a source-first README is a file of examples/," ++
        " shown by <!-- include examples/<name>.mojo --> on the line before its fence\n" ++
        "src/p/README.md:5: a ```mojo module fence that shows no file: every example of a source-first README is a file of examples/," ++
        " shown by <!-- include examples/<name>.mojo --> on the line before its fence", try refusals(a, c));
}

test "every listed file is shown by exactly one include" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "<!-- include examples/a.mojo -->\n```mojo\n" ++ MAIN ++ "```\n<!-- include examples/a.mojo -->\n```mojo\n" ++ MAIN ++ "```\n";
    const c = try check(a, text, &.{ .{ .path = "examples/a.mojo", .data = MAIN }, .{ .path = "examples/b.mojo", .data = MAIN } });
    try t.expectEqualStrings("src/p/README.md:6: include examples/a.mojo: line 1 shows it already; each file is shown once\n" ++
        "src/p/README.md: examples/b.mojo is listed in readme_examples and no <!-- include examples/b.mojo --> shows it", try refusals(a, c));
    try t.expectEqual(@as(usize, 1), c.shown);
}

test "a text fence right after an included one needs a not-tested reason; other text fences stay inline" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "<!-- include examples/a.mojo -->\n```mojo\n" ++ MAIN ++ "```\n" ++ // 1-5
        "\n```text\n1\n```\n" ++ // 6-9: refused
        "\n<!-- not-tested: printed by hand -->\n```text\n1\n```\n" ++ // 10-14
        "\nProse.\n\n```text\nsketch\n```\n" ++ // 15-20: inline
        "<!-- not-tested:  -->\n```text\nx\n```\n"; // 21-24: no reason
    const c = try check(a, text, &.{.{ .path = "examples/a.mojo", .data = MAIN }});
    try t.expectEqualStrings("src/p/README.md:7: a ```text fence right after an included example shows output no run printed: put <!-- not-tested: <reason> --> on the line before it\n" ++
        "src/p/README.md:21: a not-tested marker gives no reason", try refusals(a, c));
}

test "hidden lines and misspelt markers are refused; other comments, one starting with mojo too, are not" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "<!-- mojo-hidden x = 1 -->\n<!--include examples/a.mojo-->\n<!-- Include examples/a.mojo -->\n<!-- not-tested -->\n" ++
        "<!-- include examples/a.mojo --> trailing\n<!-- TODO: fine -->\n<!-- not tested: by hand -->\n<!-- mojo version note -->\n<!-- Mojo-hidden y = 2 -->\n";
    const c = try check(a, text, &.{});
    const near = "is not a marker: an include is the whole line `<!-- include examples/<name>.mojo -->` and a reason the whole line `<!-- not-tested: <reason> -->`, each at the start of its line";
    try t.expectEqualStrings("src/p/README.md:1: hidden lines (`<!-- mojo-hidden`) are the inline model's: a source-first README shows the whole file, so the lines go in the example's file\n" ++
        "src/p/README.md:2: `<!--include examples/a.mojo-->` " ++ near ++ "\n" ++
        "src/p/README.md:3: `<!-- Include examples/a.mojo -->` " ++ near ++ "\n" ++
        "src/p/README.md:4: `<!-- not-tested -->` " ++ near ++ "\n" ++
        "src/p/README.md:5: `<!-- include examples/a.mojo --> trailing` " ++ near ++ "\n" ++
        "src/p/README.md:7: `<!-- not tested: by hand -->` " ++ near ++ "\n" ++
        "src/p/README.md:9: `<!-- Mojo-hidden y = 2 -->` " ++ near, try refusals(a, c));
}

test "an include names a listed examples/<name>.mojo shown in a closed ```mojo fence that starts its line" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "<!-- include ../a.mojo -->\n```mojo\n```\n" ++ // 1-3
        "<!-- include examples/sub/a.mojo -->\n```mojo\n```\n" ++ // 4-6
        "<!-- include examples/a.py -->\n```mojo\n```\n" ++ // 7-9
        "<!-- include examples/a.mojo -->\n```python\n```\n" ++ // 10-12
        "<!-- include examples/b.mojo -->\n\n" ++ // 13-14
        "<!-- include examples/c.mojo -->\n  ```mojo\n  ```\n" ++ // 15-17
        "<!-- include examples/e.mojo -->\n```mojo\n```\n" ++ // 18-20
        "<!-- include examples/d.mojo -->\n```mojo\n"; // 21-22
    const listed = [_]inc.Listed{
        .{ .path = "examples/a.mojo", .data = MAIN },
        .{ .path = "examples/b.mojo", .data = MAIN },
        .{ .path = "examples/c.mojo", .data = MAIN },
        .{ .path = "examples/d.mojo", .data = MAIN },
    };
    const c = try check(a, text, &listed);
    try t.expect(!c.fillable);
    try t.expectEqualStrings("src/p/README.md:1: include \"../a.mojo\": a README shows examples/<name>.mojo, a file of the examples directory beside it\n" ++
        "src/p/README.md:4: include \"examples/sub/a.mojo\": a README shows examples/<name>.mojo, a file of the examples directory beside it\n" ++
        "src/p/README.md:7: include \"examples/a.py\": a README shows examples/<name>.mojo, a file of the examples directory beside it\n" ++
        "src/p/README.md:11: include examples/a.mojo is shown in a ```python fence; a .mojo file is shown in ```mojo\n" ++
        "src/p/README.md:13: the include of examples/b.mojo is not on the line just before a fence\n" ++
        "src/p/README.md:16: include examples/c.mojo: the fence after it does not start its line\n" ++
        "src/p/README.md:18: include examples/e.mojo: no such example: the library's readme_examples (its BUCK file) lists no examples/e.mojo\n" ++
        "src/p/README.md:22: include examples/d.mojo: the fence is never closed\n" ++
        "src/p/README.md: examples/b.mojo is listed in readme_examples and no <!-- include examples/b.mojo --> shows it", try refusals(a, c));
    // Nothing to fill from: the README is as it was.
    try t.expectEqualStrings(text, c.filled);
}

test "a file that may not be shown is refused at its include" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var text = std.ArrayList(u8).empty;
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |n| try text.writer(a).print("<!-- include examples/{s}.mojo -->\n```mojo\n```\n", .{n});
    const listed = [_]inc.Listed{
        .{ .path = "examples/a.mojo", .data = "" },
        .{ .path = "examples/b.mojo", .data = "\xEF\xBB\xBFdef main():\n    pass\n" },
        .{ .path = "examples/c.mojo", .data = "def main():\r\n    pass\r\n" },
        .{ .path = "examples/d.mojo", .data = "def main():\n    pass \n" },
        .{ .path = "examples/e.mojo", .data = "def main():\n\tpass\t\n" },
    };
    const c = try check(a, text.items, &listed);
    try t.expect(!c.fillable);
    try t.expectEqualStrings("src/p/README.md:1: include examples/a.mojo: src/p/examples/a.mojo is empty\n" ++
        "src/p/README.md:4: include examples/b.mojo: src/p/examples/b.mojo starts with a byte order mark\n" ++
        "src/p/README.md:7: include examples/c.mojo: src/p/examples/c.mojo holds a carriage return\n" ++
        "src/p/README.md:10: include examples/d.mojo: src/p/examples/d.mojo:2: the line ends in a space or a tab\n" ++
        "src/p/README.md:13: include examples/e.mojo: src/p/examples/e.mojo:2: the line ends in a space or a tab", try refusals(a, c));
}

test "a marker inside a fence is code, not an include" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, "````markdown\n<!-- include examples/a.mojo -->\n```mojo\n```\n````\n", &.{});
    try t.expectEqualStrings("", try refusals(a, c));
}

test "spans cut lines where the Markdown reader does" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "a\nb\r\nc\rd";
    const sp = try inc.spans(a, text);
    try t.expectEqual(@as(usize, 4), sp.len);
    try t.expectEqualStrings("c", text[sp[2].start..sp[2].end]);
    try t.expectEqualStrings("\r", text[sp[2].end..sp[2].next]);
    try t.expectEqualStrings("d", text[sp[3].start..sp[3].end]);
    try t.expectEqual(text.len, sp[3].next);
    try t.expectEqual(@as(usize, 0), (try inc.spans(a, "")).len);
}

test "the renderer drops exactly the comments of every case of marker_comments.json" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const work = try std.process.getEnvVarOwned(a, "KOMIRA_TEST_WORK");
    const path = try std.fs.path.join(a, &.{ work, "marker_comments.json" });
    const text = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    try t.expectEqual(@as(i64, 1), v.object.get("version").?.integer);
    // The vector's words are the tool's, in the same order.
    const words = v.object.get("marker_words").?.array.items;
    try t.expectEqual(inc.MARKER_WORDS.len, words.len);
    for (inc.MARKER_WORDS, words) |w, j| try t.expectEqualStrings(w, j.string);
    const cases = v.object.get("cases").?.array.items;
    try t.expect(cases.len >= 10);
    for (cases) |c| {
        const name = c.object.get("name").?.string;
        const got = try inc.dropMarkers(a, c.object.get("markdown").?.string);
        t.expectEqualStrings(c.object.get("shown").?.string, got) catch |e| {
            std.debug.print("case \"{s}\"\n", .{name});
            return e;
        };
    }
}

test "a not-tested marker stands on the line just before a fence" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try check(a, "<!-- not-tested: by hand -->\n\nProse.\n<!-- not-tested: by hand -->\n```sh\nmopm add p\n```\n", &.{});
    try t.expectEqualStrings("src/p/README.md:1: a not-tested marker is not on the line just before a fence", try refusals(a, c));
}
