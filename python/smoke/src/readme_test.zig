//! The cases of the README check (readme.zig): a README whose ```python block is the example byte for byte
//! passes; a block that differs by one line is refused naming that line; a README with no such block, with
//! CRLF line ends, with text added inside the block, or with a block that is cut short is refused; the same for
//! the README's ```text block, which is the expected output with `<cwd>` left as written.
const std = @import("std");
const lib = @import("pypi_smoke_lib");
const t = std.testing;

const EXAMPLE = "import komira\n\nprint(komira.__version__)\n";
const HEAD = "python/README.md shows no ```python block equal to python/examples/quickstart.py: ";

fn refusal(a: std.mem.Allocator, readme: []const u8, example: []const u8) ![]const u8 {
    return (try lib.readme.readmeShowsExample(a, readme, example)) orelse error.TestExpectedRefusal;
}

test "a README holding the example as a python block, with text around it, passes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try lib.readme.readmeShowsExample(a, "# komira\n\n## What works\n\n```python\n" ++ EXAMPLE ++ "```\n\n- more\n", EXAMPLE)) == null);
}

test "a block that differs by one line is refused naming the line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const readme = "```python\nimport komira\n\nprint(komira.abi_version())\n```\n";
    try t.expectEqualStrings(HEAD ++ "line 3 of the closest block reads 'print(komira.abi_version())', the example's reads 'print(komira.__version__)'", try refusal(a, readme, EXAMPLE));
}

test "a README with no python block is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(HEAD ++ "the README has no line that is exactly ```python", try refusal(a, "# komira\n\n```bash\npip install komira\n```\n", EXAMPLE));
    try t.expectEqualStrings(HEAD ++ "the README has no line that is exactly ```python", try refusal(a, "", EXAMPLE));
}

test "a README with CRLF line ends is not equal, whether the fences or only the block lines have them" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(HEAD ++ "the README has no line that is exactly ```python", try refusal(a, "```python\r\nimport komira\r\n\r\nprint(komira.__version__)\r\n```\r\n", EXAMPLE));
    try t.expectEqualStrings(HEAD ++ "line 1 of the closest block reads 'import komira\r', the example's reads 'import komira'", try refusal(a, "```python\nimport komira\r\n\r\nprint(komira.__version__)\r\n```\n", EXAMPLE));
}

test "text added inside the block, after its last line, or a closing fence that is missing is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(HEAD ++ "line 4 of the closest block reads 'print(1)', the example's reads '(the example ends)'", try refusal(a, "```python\n" ++ EXAMPLE ++ "print(1)\n```\n", EXAMPLE));
    try t.expectEqualStrings(HEAD ++ "line 3 of the closest block reads '(the block ends)', the example's reads 'print(komira.__version__)'", try refusal(a, "```python\nimport komira\n\n```\n", EXAMPLE));
    try t.expectEqualStrings(HEAD ++ "line 4 of the closest block reads '(the README ends)', the example's reads '(the example ends)'", try refusal(a, "```python\n" ++ EXAMPLE, EXAMPLE));
}

test "a block with a trailing space after the fence word or a different fence is not the block" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(HEAD ++ "the README has no line that is exactly ```python", try refusal(a, "```python \n" ++ EXAMPLE ++ "```\n", EXAMPLE));
    try t.expectEqualStrings(HEAD ++ "the README has no line that is exactly ```python", try refusal(a, "~~~python\n" ++ EXAMPLE ++ "~~~\n", EXAMPLE));
}

test "of several python blocks the one that agrees with the example longest is the one named, and any equal block passes" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const readme = "```python\nprint(0)\n```\n\n```python\nimport komira\n\nprint(1)\n```\n";
    try t.expectEqualStrings(HEAD ++ "line 3 of the closest block reads 'print(1)', the example's reads 'print(komira.__version__)'", try refusal(a, readme, EXAMPLE));
    try t.expect((try lib.readme.readmeShowsExample(a, "```python\nprint(0)\n```\n\n```python\n" ++ EXAMPLE ++ "```\n", EXAMPLE)) == null);
}

test "an example that does not end with a line feed is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(HEAD ++ "the example does not end with a line feed", try refusal(a, "```python\nx\n```\n", "x"));
    try t.expectEqualStrings(HEAD ++ "the example does not end with a line feed", try refusal(a, "```python\n```\n", ""));
}

const PAGE_HEAD = "docs/install.md shows no ```text block equal to python/examples/quickstart.expected: ";
const OUTPUT = "0.1.7\n1001\nregistered readings\nTrue\n";

fn pageRefusal(a: std.mem.Allocator, page: []const u8, want: []const u8) ![]const u8 {
    return (try lib.readme.docShowsBlock(a, lib.readme.install_page_output, page, want)) orelse error.TestExpectedRefusal;
}

test "the install page's output block passes when equal, and is named by page, fence and file when not" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expect((try lib.readme.docShowsBlock(a, lib.readme.install_page_output, "# Install\n\n```text\n" ++ OUTPUT ++ "```\n", OUTPUT)) == null);
    try t.expectEqualStrings(PAGE_HEAD ++ "line 2 of the closest block reads '1000', the expected output's reads '1001'", try pageRefusal(a, "```text\n0.1.7\n1000\nregistered readings\nTrue\n```\n", OUTPUT));
    try t.expectEqualStrings(PAGE_HEAD ++ "line 5 of the closest block reads '(the page ends)', the expected output's reads '(the expected output ends)'", try pageRefusal(a, "```text\n" ++ OUTPUT, OUTPUT));
    try t.expectEqualStrings(PAGE_HEAD ++ "the expected output does not end with a line feed", try pageRefusal(a, "```text\n```\n", "True"));
}

test "a python block does not stand for the output block, nor a text block for the example" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(PAGE_HEAD ++ "the page has no line that is exactly ```text", try pageRefusal(a, "```python\n" ++ OUTPUT ++ "```\n", OUTPUT));
    try t.expectEqualStrings(
        "docs/install.md shows no ```python block equal to python/examples/quickstart.py: the page has no line that is exactly ```python",
        (try lib.readme.docShowsBlock(a, lib.readme.install_page_example, "```text\n" ++ EXAMPLE ++ "```\n", EXAMPLE)).?,
    );
}

fn newest(a: std.mem.Allocator, text: []const u8) ![]const u8 {
    var why: []const u8 = "";
    return lib.readme.newestRelease(a, &why, "python/CHANGELOG.md", text) catch |e| switch (e) {
        error.Refused => return why,
        else => return e,
    };
}

test "the newest release is the first version heading, after an Unreleased one" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("0.1.1600", try newest(a, "# Changelog\n\n## 0.1.1600\n\n- more\n\n## 0.1.1512\n"));
    try t.expectEqualStrings("0.1.1600", try newest(a, "# Changelog\n\n## Unreleased\n\n- next\n\n## 0.1.1600\n"));
    try t.expectEqualStrings("0.1.1512", try newest(a, "## 0.1.1512"));
}

test "a changelog with no release, or whose newest heading is no version, is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("python/CHANGELOG.md lists no release: no heading `## <version>`", try newest(a, "# Changelog\n\n## Unreleased\n\n- next\n"));
    try t.expectEqualStrings("python/CHANGELOG.md lists no release: no heading `## <version>`", try newest(a, ""));
    try t.expectEqualStrings("python/CHANGELOG.md lists no release: no heading `## <version>`", try newest(a, "### 0.1.1\n"));
    const bad = [_][]const u8{ "## v0.1.1", "## 0.1.1 (first)", "## 1", "## 0..1", "## 0.1.", "## ", "## 0.1.1\r" };
    for (bad) |heading| {
        const want = try std.fmt.allocPrint(a, "python/CHANGELOG.md: the newest release's heading is '{s}', not `## <version>` (numbers joined by dots)", .{heading});
        try t.expectEqualStrings(want, try newest(a, try std.fmt.allocPrint(a, "# Changelog\n\n{s}\n\n## 0.1.1\n", .{heading})));
    }
}

test "an output block that shows another release's version or another ABI version is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const expected = "<version>\n<abi_version>\nregistered readings\nTrue\n";
    const page = "```text\n0.1.1512\n1001\nregistered readings\nTrue\n```\n";
    try t.expect((try lib.readme.docShowsBlock(a, lib.readme.install_page_output, page, try lib.install.expectedText(a, expected, "0.1.1512", 1001, "<cwd>"))) == null);
    try t.expectEqualStrings(PAGE_HEAD ++ "line 1 of the closest block reads '0.1.1512', the expected output's reads '0.1.1600'", try pageRefusal(a, page, try lib.install.expectedText(a, expected, "0.1.1600", 1001, "<cwd>")));
    try t.expectEqualStrings(PAGE_HEAD ++ "line 2 of the closest block reads '1001', the expected output's reads '1002'", try pageRefusal(a, page, try lib.install.expectedText(a, expected, "0.1.1512", 1002, "<cwd>")));
}

test "a README text block is the expected output with <cwd> left as written, and differing on that line is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const expected = "<version>\nno such file: <cwd>/weather.parquet\n";
    const want = try lib.install.expectedText(a, expected, "0.1.1512", 1001, "<cwd>");
    const good = "# komira\n\n```text\n0.1.1512\nno such file: <cwd>/weather.parquet\n```\n";
    try t.expect((try lib.readme.docShowsBlock(a, lib.readme.readme_output, good, want)) == null);
    const bad = "```text\n0.1.1512\nno such file: /work/run/weather.parquet\n```\n";
    try t.expectEqualStrings(
        "python/README.md shows no ```text block equal to python/examples/quickstart.expected: line 2 of the closest block reads 'no such file: /work/run/weather.parquet', the expected output's reads 'no such file: <cwd>/weather.parquet'",
        (try lib.readme.docShowsBlock(a, lib.readme.readme_output, bad, want)).?,
    );
}
