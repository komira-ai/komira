//! The rule table (include.zig, KINDS): a README and a task page are held
//! by the same rules and differ only by their row, so each test here runs
//! one rule on both kinds, each refusal word for word.

const std = @import("std");
const inc = @import("include.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const MAIN = "def main():\n    print(1)\n";

fn refusals(a: std.mem.Allocator, kind: *const inc.Kind, text: []const u8, display: []const u8, listed: []const inc.Listed) ![]const u8 {
    const c = try inc.check(a, kind, text, display, listed);
    return std.mem.join(a, "\n", c.refusals);
}

test "the table has a row for a README and one for a task page, found by name" {
    try t.expectEqual(@as(usize, 2), inc.KINDS.len);
    try t.expectEqual(&inc.README, inc.kindNamed("readme").?);
    try t.expectEqual(&inc.TASK, inc.kindNamed("task").?);
    try t.expectEqual(@as(?*const inc.Kind, null), inc.kindNamed("Readme"));
    try t.expectEqual(@as(?*const inc.Kind, null), inc.kindNamed(""));
}

test "an include outside its kind's directory or extensions is refused, for each kind" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const readme_shape = "a source-first README shows examples/<name>.mojo or examples/<name>.expected_output.txt, a file of examples/ beside it";
    const task_shape = "a task page shows <name>.py or <name>.txt, a file beside it named alone";
    const cases = [_]struct { kind: *const inc.Kind, path: []const u8, want: []const u8 }{
        // A README names a file of examples/, a .mojo or its expected output.
        .{ .kind = &inc.README, .path = "a.mojo", .want = readme_shape },
        .{ .kind = &inc.README, .path = "examples/a.py", .want = readme_shape },
        .{ .kind = &inc.README, .path = "examples/a.txt", .want = readme_shape },
        .{ .kind = &inc.README, .path = "examples/.mojo", .want = readme_shape },
        .{ .kind = &inc.README, .path = "examples/sub/a.mojo", .want = readme_shape },
        .{ .kind = &inc.README, .path = "examples/..a.mojo", .want = readme_shape },
        // A task page names a .py or .txt of its own directory, alone.
        .{ .kind = &inc.TASK, .path = "examples/a.py", .want = task_shape },
        .{ .kind = &inc.TASK, .path = "a.mojo", .want = task_shape },
        .{ .kind = &inc.TASK, .path = "a.expected_output.md", .want = task_shape },
        .{ .kind = &inc.TASK, .path = ".py", .want = task_shape },
        .{ .kind = &inc.TASK, .path = "../a.py", .want = task_shape },
    };
    for (cases) |k| {
        const text = try std.fmt.allocPrint(a, "<!-- include {s} -->\n```mojo\n```\n", .{k.path});
        const want = try std.fmt.allocPrint(a, "d/page.md:1: include \"{s}\": {s}", .{ k.path, k.want });
        try t.expectEqualStrings(want, try refusals(a, k.kind, text, "d/page.md", &.{}));
        // Nothing to fill from: `fill` leaves the page as it was.
        const c = try inc.check(a, k.kind, text, "d/page.md", &.{});
        try t.expect(!c.fillable);
        try t.expectEqualStrings(text, c.filled);
    }
}

test "the fence word is the extension's, for each kind" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { kind: *const inc.Kind, path: []const u8, word: []const u8, other: []const u8, ext: []const u8 }{
        .{ .kind = &inc.README, .path = "examples/a.mojo", .word = "mojo", .other = "python", .ext = ".mojo" },
        .{ .kind = &inc.TASK, .path = "a.py", .word = "python", .other = "py", .ext = ".py" },
        .{ .kind = &inc.TASK, .path = "a.txt", .word = "text", .other = "output", .ext = ".txt" },
    };
    for (cases) |k| {
        const listed = [_]inc.Listed{.{ .path = k.path, .data = "1\n" }};
        const good = try std.fmt.allocPrint(a, "<!-- include {s} -->\n```{s}\n1\n```\n", .{ k.path, k.word });
        try t.expectEqualStrings("", try refusals(a, k.kind, good, "page.md", &listed));
        const bad = try std.fmt.allocPrint(a, "<!-- include {s} -->\n```{s}\n1\n```\n", .{ k.path, k.other });
        const want = try std.fmt.allocPrint(a, "page.md:2: include {s} is shown in a ```{s} fence; a {s} file is shown in ```{s}", .{ k.path, k.other, k.ext, k.word });
        const got = try inc.check(a, k.kind, bad, "page.md", &listed);
        try t.expectEqualStrings(want, try std.mem.join(a, "\n", got.refusals));
        try t.expect(!got.fillable);
    }
}

test "fill writes a stale page of either kind from its files, lengthening a fence the file would close, and a second fill changes nothing" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const file = "s = \"\"\"\n```\n\"\"\"\nprint(s)\n";
    const cases = [_]struct { kind: *const inc.Kind, path: []const u8, word: []const u8 }{
        .{ .kind = &inc.README, .path = "examples/a.mojo", .word = "mojo" },
        .{ .kind = &inc.TASK, .path = "example.py", .word = "python" },
    };
    for (cases) |k| {
        const listed = [_]inc.Listed{.{ .path = k.path, .data = file }};
        const text = try std.fmt.allocPrint(a, "Intro.\n\n<!-- include {s} -->\n```{s}\nold\n```\n\nAfter.\n", .{ k.path, k.word });
        const c = try inc.check(a, k.kind, text, "page.md", &listed);
        try t.expect(c.fillable);
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "page.md:4: include {s}: {s} holds a line that closes a fence of 3, so its fence is 4 long; {s}", .{ k.path, k.path, k.kind.fill_hint }), c.refusals[0]);
        const want = try std.fmt.allocPrint(a, "Intro.\n\n<!-- include {s} -->\n````{s}\n{s}````\n\nAfter.\n", .{ k.path, k.word, file });
        try t.expectEqualStrings(want, c.filled);
        const again = try inc.check(a, k.kind, c.filled, "page.md", &listed);
        try t.expectEqual(@as(usize, 0), again.refusals.len);
        try t.expectEqualStrings(c.filled, again.filled);
    }
}

test "a README may show an example's expected output with the same marker, and need not" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = [_]inc.Listed{
        .{ .path = "examples/a.mojo", .data = MAIN },
        .{ .path = "examples/a.expected_output.txt", .data = "1\n" },
    };
    const program = "<!-- include examples/a.mojo -->\n```mojo\ndef main():\n    print(1)\n```\n\nPrints:\n\n";
    // Shown right after the program: an include, so not output typed by hand.
    const shown = try inc.check(a, &inc.README, program ++ "<!-- include examples/a.expected_output.txt -->\n```text\n1\n```\n", "src/p/README.md", &listed);
    try t.expectEqual(@as(usize, 0), shown.refusals.len);
    try t.expectEqual(@as(usize, 2), shown.shown);
    // Not shown: the README passes, and the run still compares it (readme.bzl).
    const unshown = try inc.check(a, &inc.README, program, "src/p/README.md", &listed);
    try t.expectEqual(@as(usize, 0), unshown.refusals.len);
    try t.expectEqual(@as(usize, 1), unshown.shown);
    // Stale: named at its line, and `fill` mends it as any include.
    const stale = try inc.check(a, &inc.README, program ++ "<!-- include examples/a.expected_output.txt -->\n```text\n2\n```\n", "src/p/README.md", &listed);
    try t.expectEqualStrings("src/p/README.md:11: include examples/a.expected_output.txt is stale: this line is not line 1 of src/p/examples/a.expected_output.txt; " ++ inc.FILL_HINT, try std.mem.join(a, "\n", stale.refusals));
    try t.expectEqualStrings(program ++ "<!-- include examples/a.expected_output.txt -->\n```text\n1\n```\n", stale.filled);
    // Its fence word is `text`, as for any output.
    try t.expectEqualStrings("src/p/README.md:10: include examples/a.expected_output.txt is shown in a ```output fence; a .expected_output.txt file is shown in ```text", try refusals(a, &inc.README, program ++ "<!-- include examples/a.expected_output.txt -->\n```output\n1\n```\n", "src/p/README.md", &listed));
}

test "an expected output listed without its program is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const listed = [_]inc.Listed{.{ .path = "examples/b.expected_output.txt", .data = "1\n" }};
    try t.expectEqualStrings("src/p/README.md: examples/b.expected_output.txt is the expected output of examples/b.mojo, which is not listed", try refusals(a, &inc.README, "# p\n", "src/p/README.md", &listed));
}

test "a text fence right after any code needs a reason, for each kind; after prose it does not" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const typed = "a ```text fence right after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it";
    for (inc.KINDS) |kind| {
        try t.expectEqualStrings("p.md:5: " ++ typed, try refusals(a, kind, "```sh\nls\n```\n\n```text\na\n```\n", "p.md", &.{}));
        try t.expectEqualStrings("", try refusals(a, kind, "```sh\nls\n```\n\n<!-- not-tested: what ls printed once -->\n```text\na\n```\n", "p.md", &.{}));
        try t.expectEqualStrings("", try refusals(a, kind, "```sh\nls\n```\n\nIt prints:\n\n```text\na\n```\n", "p.md", &.{}));
    }
}

test "a code fence that shows no file: a README refuses it even with a reason, a task page takes the reason" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("p.md:2: a ```mojo fence that shows no file: " ++ inc.README.code_rule, try refusals(a, &inc.README, "<!-- not-tested: needs a GPU -->\n```mojo\nx\n```\n", "p.md", &.{}));
    try t.expectEqualStrings("", try refusals(a, &inc.TASK, "<!-- not-tested: needs Postgres -->\n```python\nx\n```\n", "p.md", &.{}));
    // Another kind's code word is not code to this one.
    try t.expectEqualStrings("", try refusals(a, &inc.README, "```python\nx\n```\n", "p.md", &.{}));
    try t.expectEqualStrings("", try refusals(a, &inc.TASK, "```mojo\nx\n```\n", "p.md", &.{}));
}

test "hidden lines and misspelt markers are refused on a task page as on a README" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("p.md:1: hidden lines (`<!-- mojo-hidden`) are the inline model's: a task page shows the whole file, so the lines go in the example's file\n" ++
        "p.md:2: `<!-- Include example.py -->` is not a marker: an include is the whole line `<!-- include <file> -->` and a reason the whole line `<!-- not-tested: <reason> -->`, each at the start of its line", try refusals(a, &inc.TASK, "<!-- mojo-hidden x = 1 -->\n<!-- Include example.py -->\n", "p.md", &.{}));
}

test "a file that may not be shown is refused for each kind: empty, a byte order mark, a carriage return, no final line feed, a trailing space" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bad = [_]struct { data: []const u8, why: []const u8 }{
        .{ .data = "", .why = "is empty" },
        .{ .data = "\n", .why = "is empty" },
        .{ .data = "\xEF\xBB\xBFx\n", .why = "starts with a byte order mark" },
        .{ .data = "x\r\n", .why = "holds a carriage return" },
        .{ .data = "x", .why = "does not end in a line feed" },
        .{ .data = "x\ny \n", .why = ":2: the line ends in a space or a tab" },
    };
    const cases = [_]struct { kind: *const inc.Kind, path: []const u8, word: []const u8 }{
        .{ .kind = &inc.README, .path = "examples/a.mojo", .word = "mojo" },
        .{ .kind = &inc.TASK, .path = "example.py", .word = "python" },
    };
    for (cases) |k| {
        for (bad) |b| {
            const text = try std.fmt.allocPrint(a, "<!-- include {s} -->\n```{s}\nx\n```\n", .{ k.path, k.word });
            const sep = if (b.why[0] == ':') "" else " ";
            const want = try std.fmt.allocPrint(a, "d/page.md:1: include {s}: d/{s}{s}{s}", .{ k.path, k.path, sep, b.why });
            const c = try inc.check(a, k.kind, text, "d/page.md", &.{.{ .path = k.path, .data = b.data }});
            try t.expectEqualStrings(want, try std.mem.join(a, "\n", c.refusals));
            try t.expect(!c.fillable);
        }
    }
}

test "a listed file no include can show: a README refuses it, a task directory's other files are its own" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("p.md: examples/notes.txt is listed in readme_examples and no <!-- include examples/notes.txt --> shows it", try refusals(a, &inc.README, "# p\n", "p.md", &.{.{ .path = "examples/notes.txt", .data = "n\n" }}));
    try t.expectEqualStrings("", try refusals(a, &inc.TASK, "# p\n", "p.md", &.{ .{ .path = "data.csv", .data = "a\n" }, .{ .path = "probe_x.py", .data = "x\n" } }));
}
