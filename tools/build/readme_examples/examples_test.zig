//! A README's examples: which fences are examples, the refusals (each naming
//! its line), hidden lines, and the shipped-README link refusal.

const std = @import("std");
const ex = @import("examples.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

fn examplesOf(a: std.mem.Allocator, text: []const u8) ![]const ex.Example {
    return switch (try ex.extract(a, text, "R.md", false)) {
        .examples => |e| e,
        .refused => |why| {
            std.debug.print("refused: {s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
}

/// The refusal message for `text`, or "" when it is accepted.
fn refusal(a: std.mem.Allocator, text: []const u8, links: bool) ![]const u8 {
    return switch (try ex.extract(a, text, "R.md", links)) {
        .examples => "",
        .refused => |why| why,
    };
}

/// `<line>|<code>` per code line.
fn join(a: std.mem.Allocator, e: ex.Example) ![]const u8 {
    var s = std.ArrayList(u8).init(a);
    for (e.code, e.code_lines) |c, n| try s.writer().print("{d}|{s}\n", .{ n, c });
    return s.items;
}

test "only exactly mojo is an example" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exs = try examplesOf(a, "# T\n```mojo\nprint(1)\n```\n```text\nsketch()\n```\n```\nplain\n```\n" ++
        "~~~mojo\nprint(2)\n~~~\n```sh\npixi add x\n```\n");
    try t.expectEqual(@as(usize, 2), exs.len);
    try t.expectEqual(@as(usize, 2), exs[0].line);
    try t.expectEqualStrings("3|print(1)\n", try join(a, exs[0]));
    try t.expectEqual(@as(usize, 11), exs[1].line);
    try t.expectEqualStrings("12|print(2)\n", try join(a, exs[1]));
}

test "no example is an empty list" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(@as(usize, 0), (try examplesOf(arena.allocator(), "# T\n\nprose\n```text\nx\n```\n")).len);
}

test "an indented fence is dedented by its indent" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exs = try examplesOf(a, "- item\n\n  ```mojo\n  if True:\n      pass\n  ```\n");
    try t.expectEqualStrings("4|if True:\n5|    pass\n", try join(a, exs[0]));
}

test "a word after mojo is refused" {
    // The vocabulary after `mojo` is closed and holds `module` alone: no skip word.
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "R.md:2: `mojo skip`: an example's info string is `mojo` or `mojo module`; nothing else may follow `mojo`" ++
            " (there is no skip word: fence a sketch that cannot run as ```text)",
        try refusal(a, "a\n```mojo skip\nx\n```\n", false),
    );
    try t.expect(std.mem.startsWith(u8, try refusal(a, "```mojo ignore\n```\n", false), "R.md:1: `mojo ignore`"));
    for ([_][]const u8{ "mojo module skip", "mojo Module", "mojo modules", "mojo main" }) |info| {
        const why = try refusal(a, try std.fmt.allocPrint(a, "```{s}\n```\n", .{info}), false);
        try t.expect(std.mem.startsWith(u8, why, try std.fmt.allocPrint(a, "R.md:1: `{s}`", .{info})));
    }
}

test "the fence tag is the mode" {
    // `mojo module` is an example in module mode; `mojo` is not, whatever
    // its code declares. Hidden lines attach to either.
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exs = try examplesOf(a, "```mojo\nstruct T:\n    pass\n```\n<!-- mojo-hidden x = 1 -->\n```mojo module\ndef main():\n    pass\n```\n" ++
        "~~~mojo  module\n~~~\n");
    try t.expectEqual(@as(usize, 3), exs.len);
    try t.expect(!exs[0].module);
    try t.expect(exs[1].module);
    try t.expectEqualStrings("5|x = 1\n7|def main():\n8|    pass\n", try join(a, exs[1]));
    try t.expect(exs[2].module);
    try t.expect((try ex.infoRefusal(a, "mojo module")) == null);
}

test "an indented module fence keeps its mode" {
    // The mode comes from the tag alone, wherever the fence sits: a
    // `mojo module` fence inside a list item is a whole program, dedented by
    // the fence's indent like any other example.
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exs = try examplesOf(a, "- item\n\n  ```mojo module\n  def main():\n      pass\n  ```\n");
    try t.expectEqual(@as(usize, 1), exs.len);
    try t.expect(exs[0].module);
    try t.expectEqualStrings("4|def main():\n5|    pass\n", try join(a, exs[0]));
}

test "near misses are refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "Mojo", "MOJO", "mojo,", ".mojo", "{.mojo}", "\u{1F525}", "mojo-example" }) |w| {
        try t.expect((try ex.infoRefusal(a, w)) != null);
    }
    try t.expect((try ex.infoRefusal(a, "mojo")) == null);
    try t.expect((try ex.infoRefusal(a, "text")) == null);
    try t.expect((try ex.infoRefusal(a, "python")) == null);
    try t.expectEqualStrings(
        "R.md:3: `Mojo` is not `mojo`: write ```mojo for an example that runs, or ```text for a sketch",
        try refusal(a, "x\n\n```Mojo\nprint(1)\n```\n", false),
    );
}

test "every refusal is reported in line order" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const why = try refusal(a, "```mojo skip\n```\n<!-- mojo-hidden x = 1 -->\n\n```Mojo\n```\n", false);
    var it = std.mem.splitScalar(u8, why, '\n');
    var lines = std.ArrayList([]const u8).init(a);
    while (it.next()) |l| try lines.append(l);
    try t.expectEqual(@as(usize, 3), lines.items.len);
    try t.expect(std.mem.startsWith(u8, lines.items[0], "R.md:1: "));
    try t.expect(std.mem.startsWith(u8, lines.items[1], "R.md:3: a mojo-hidden comment must end"));
    try t.expect(std.mem.startsWith(u8, lines.items[2], "R.md:5: "));
}

test "an unclosed example is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("R.md:2: the ```mojo example is never closed", try refusal(arena.allocator(), "a\n```mojo\nprint(1)\n", false));
}

test "hidden lines before and after" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const exs = try examplesOf(a, "<!-- mojo-hidden from std.testing import assert_equal -->\n" ++
        "```mojo\n" ++
        "var x = 2\n" ++
        "```\n" ++
        "<!-- mojo-hidden\n" ++
        "assert_equal(x, 2)\n" ++
        "    -->\n");
    try t.expectEqual(@as(usize, 1), exs.len);
    try t.expectEqualStrings("1|from std.testing import assert_equal\n3|var x = 2\n6|assert_equal(x, 2)\n", try join(a, exs[0]));
}

test "a hidden comment must touch an example" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "R.md:1: a mojo-hidden comment must end on the line just before a ```mojo fence" ++
            " or start on the line just after its closing fence; this one runs nowhere",
        try refusal(a, "<!-- mojo-hidden x = 1 -->\n\n```mojo\nprint(1)\n```\n", false),
    );
    // Next to a fence that is not an example.
    try t.expect(std.mem.startsWith(u8, try refusal(a, "<!-- mojo-hidden x = 1 -->\n```text\nx\n```\n", false), "R.md:1: a mojo-hidden"));
}

test "a misspelled marker is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "R.md:1: `<!-- mojo_hidden`: the hidden-lines marker is exactly `<!-- mojo-hidden`",
        try refusal(a, "<!-- mojo_hidden x = 1 -->\n```mojo\nprint(1)\n```\n", false),
    );
    try t.expect(std.mem.startsWith(u8, try refusal(a, "<!-- Mojo-hidden\nx\n-->\n```mojo\n```\n", false), "R.md:1: `<!-- Mojo-hidden`"));
    // An ordinary comment is prose.
    try t.expectEqualStrings("", try refusal(a, "<!-- a note -->\n```mojo\nprint(1)\n```\n", false));
}

test "an unclosed hidden comment is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const why = try refusal(arena.allocator(), "<!-- mojo-hidden\nx = 1\n```mojo\n```\n", false);
    try t.expect(std.mem.indexOf(u8, why, "R.md:1: a mojo-hidden comment is never closed") != null);
}

test "a shipped readme refuses relative links" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "See [api](api.md), [top](#use), [site](https://example.org/x).\n\n```mojo\nprint(1)\n```\n";
    try t.expectEqualStrings("", try refusal(a, text, false));
    try t.expectEqualStrings(
        "R.md:1: api.md: a relative link in a README that ships in its package; the installed copy" ++
            " has no such file. Link an absolute URL, or an #anchor of this README",
        try refusal(a, text, true),
    );
}
