//! The rules of a task page (task_page.zig): includes, fences that show no
//! file, and the title, each refusal word for word with its line.

const std = @import("std");
const page = @import("task_page.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const Q = "How do I a?";
const EXAMPLE = "import komira\nprint(1)\n";
const EXPECTED = "1\n";

const FILES = [_]page.File{
    .{ .name = "example.py", .data = EXAMPLE },
    .{ .name = "expected_output.txt", .data = EXPECTED },
    .{ .name = "page.md", .data = "" },
};

// Line 5 is the first marker, line 6 its fence; line 11 the second, 12 its fence.
const HEAD = "# How do I a?\n\nAnswer.\n\n";
const SHOW_EXAMPLE = "<!-- include example.py -->\n```python\nimport komira\nprint(1)\n```\n";
const SHOW_EXPECTED = "<!-- include expected_output.txt -->\n```text\n1\n```\n";
const GOOD = HEAD ++ SHOW_EXAMPLE ++ "\n" ++ SHOW_EXPECTED;

fn refusals(a: std.mem.Allocator, text: []const u8, files: []const page.File) ![]const []const u8 {
    var out = std.ArrayList([]const u8).empty;
    try page.check(a, &out, "p.md", Q, text, files);
    return out.items;
}

fn expectRefusals(text: []const u8, files: []const page.File, want: []const []const u8) !void {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const got = try refusals(arena.allocator(), text, files);
    if (got.len != want.len) {
        for (got) |g| std.debug.print("refusal: {s}\n", .{g});
    }
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

fn expectOne(text: []const u8, want: []const u8) !void {
    try expectRefusals(text, &FILES, &.{want});
}

test "a page that includes both files, each in its fence, passes" {
    try expectRefusals(GOOD, &FILES, &.{});
    // Prose between the code and its output, and CRLF line ends, change nothing.
    try expectRefusals(HEAD ++ SHOW_EXAMPLE ++ "\nPrints:\n\n" ++ SHOW_EXPECTED, &FILES, &.{});
    try expectRefusals("# How do I a?\r\n\r\n<!-- include example.py -->\r\n```python\r\nimport komira\r\nprint(1)\r\n```\r\n<!-- include expected_output.txt -->\r\n```text\r\n1\r\n```\r\n", &FILES, &.{});
}

test "a page whose first line is not the question is refused" {
    try expectOne("# A\n\n" ++ SHOW_EXAMPLE ++ SHOW_EXPECTED, "p.md:1: the first line is not \"# How do I a?\"");
    try expectRefusals("", &FILES, &.{
        "p.md:1: the first line is not \"# How do I a?\"",
        "p.md: the page does not show example.py: no <!-- include example.py --> before a fence",
        "p.md: the page does not show expected_output.txt: no <!-- include expected_output.txt --> before a fence",
    });
}

test "an include whose fence differs from the file by one byte is stale, naming the first differing line" {
    try expectOne(HEAD ++ "<!-- include example.py -->\n```python\nimport komira\nprint(2)\n```\n\n" ++ SHOW_EXPECTED, "p.md:6: include example.py is stale (first difference at line 2 of example.py)");
    try expectOne(HEAD ++ SHOW_EXAMPLE ++ "\n<!-- include expected_output.txt -->\n```text\n1\n2\n```\n", "p.md:12: include expected_output.txt is stale (first difference at line 2 of expected_output.txt)");
    // An empty fence against a file of one line.
    try expectOne(HEAD ++ SHOW_EXAMPLE ++ "\n<!-- include expected_output.txt -->\n```text\n```\n", "p.md:12: include expected_output.txt is stale (first difference at line 1 of expected_output.txt)");
}

test "a file without a final line feed never equals its fence" {
    const files = [_]page.File{ .{ .name = "example.py", .data = "import komira\nprint(1)" }, FILES[1] };
    try expectRefusals(GOOD, &files, &.{"p.md:6: include example.py is stale (first difference at line 3 of example.py)"});
}

test "an include in a fence of another word is refused, naming the word its extension needs" {
    try expectOne(HEAD ++ "<!-- include example.py -->\n```py\nimport komira\nprint(1)\n```\n\n" ++ SHOW_EXPECTED, "p.md:6: include example.py is shown in a ```py fence; a .py file is shown in ```python");
    try expectOne(HEAD ++ SHOW_EXAMPLE ++ "\n<!-- include expected_output.txt -->\n```output\n1\n```\n", "p.md:12: include expected_output.txt is shown in a ```output fence; a .txt file is shown in ```text");
}

test "an include of a path, a missing file, a directory or another extension is refused" {
    const extra = FILES ++ [_]page.File{ .{ .name = "data.csv", .data = "a\n" }, .{ .name = "sub", .data = null } };
    const cases = [_]struct { marker: []const u8, want: []const u8 }{
        .{ .marker = "<!-- include ../example.py -->", .want = "p.md:16: include \"../example.py\" is not the name of a file of the task directory" },
        .{ .marker = "<!-- include /etc/example.py -->", .want = "p.md:16: include \"/etc/example.py\" is not the name of a file of the task directory" },
        .{ .marker = "<!-- include .. -->", .want = "p.md:16: include \"..\" is not the name of a file of the task directory" },
        .{ .marker = "<!-- include  -->", .want = "p.md:16: include \"\" is not the name of a file of the task directory" },
        .{ .marker = "<!-- include gone.py -->", .want = "p.md:16: include gone.py: the task directory has no such file" },
        .{ .marker = "<!-- include sub -->", .want = "p.md:16: include sub: a directory, not a file" },
        .{ .marker = "<!-- include data.csv -->", .want = "p.md:16: include data.csv: a page includes only .py and .txt files" },
    };
    inline for (cases) |k| {
        try expectRefusals(GOOD ++ "\n" ++ k.marker ++ "\n```python\nx\n```\n", &extra, &.{k.want});
    }
}

test "an include before an indented fence, or a fence left open, is refused" {
    try expectRefusals(GOOD ++ "\n<!-- include example.py -->\n  ```python\n  import komira\n  ```\n", &FILES, &.{"p.md:16: include example.py: the fence after it does not start its line"});
    try expectOne(HEAD ++ SHOW_EXAMPLE ++ "\n<!-- include expected_output.txt -->\n```text\n1\n", "p.md:12: include expected_output.txt: the fence is not closed");
}

test "an included file with a carriage return is refused" {
    const files = [_]page.File{ FILES[0], .{ .name = "expected_output.txt", .data = "1\r\n" } };
    try expectRefusals(GOOD, &files, &.{"p.md:11: include expected_output.txt: the file holds a carriage return"});
}

test "a marker that is not alone on its line, or not at its start, is no marker" {
    try expectRefusals(HEAD ++ " <!-- include example.py -->\n```python\nimport komira\nprint(1)\n```\n\n" ++ SHOW_EXPECTED, &FILES, &.{
        "p.md:6: a ```python fence that shows no file: put <!-- include <file> --> or <!-- not-tested: <reason> --> on the line before it",
        "p.md: the page does not show example.py: no <!-- include example.py --> before a fence",
    });
    // A blank line between the marker and the fence breaks the pair too.
    try expectRefusals(HEAD ++ "<!-- include example.py -->\n\n```python\nimport komira\nprint(1)\n```\n\n" ++ SHOW_EXPECTED, &FILES, &.{
        "p.md:7: a ```python fence that shows no file: put <!-- include <file> --> or <!-- not-tested: <reason> --> on the line before it",
        "p.md: the page does not show example.py: no <!-- include example.py --> before a fence",
    });
}

test "a python fence that shows no file needs a not-tested reason" {
    try expectOne(GOOD ++ "\n```python\nimport psycopg\n```\n", "p.md:16: a ```python fence that shows no file: put <!-- include <file> --> or <!-- not-tested: <reason> --> on the line before it");
    try expectRefusals(GOOD ++ "\n<!-- not-tested: no Postgres in the check -->\n```python\nimport psycopg\n```\n", &FILES, &.{});
    try expectOne(GOOD ++ "\n<!-- not-tested:  -->\n```python\nimport psycopg\n```\n", "p.md:16: a not-tested marker gives no reason");
}

test "hand-typed output after code or an include is refused; elsewhere a text fence is the page's own" {
    // Directly after the included program, with only a blank line between.
    try expectOne(HEAD ++ SHOW_EXAMPLE ++ "\n```text\n1\n```\n\n" ++ SHOW_EXPECTED, "p.md:11: a ```text fence after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it");
    // After an untested sql fence.
    try expectOne(GOOD ++ "\n<!-- not-tested: shown, not run -->\n```sql\nSELECT 1\n```\n```text\n1\n```\n", "p.md:20: a ```text fence after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it");
    // After an include of a text file: the text fence that follows it is the same rule.
    try expectOne(GOOD ++ "\n```text\n2\n```\n", "p.md:16: a ```text fence after code shows output no run printed: include its file, or put <!-- not-tested: <reason> --> on the line before it");
    // Marked, or after prose, or after an unlabelled fence: allowed.
    try expectRefusals(GOOD ++ "\n<!-- not-tested: Postgres prints this -->\n```text\nINSERT 0 4\n```\n", &FILES, &.{});
    try expectRefusals(GOOD ++ "\nA table:\n\n```text\na | b\n```\n", &FILES, &.{});
    try expectRefusals(GOOD ++ "\n```\nplain\n```\n```text\na\n```\n", &FILES, &.{});
}

test "the marker words are spelled in one place" {
    try t.expectEqualStrings("<!-- ", page.MARKERS.open);
    try t.expectEqualStrings("include ", page.MARKERS.include);
    try t.expectEqualStrings("not-tested: ", page.MARKERS.not_tested);
    try t.expectEqualStrings(" -->", page.MARKERS.close);
}
