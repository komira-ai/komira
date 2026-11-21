//! The cases of the README check (readme.zig): a README whose ```python block is the example byte for byte
//! passes; a block that differs by one line is refused naming that line; a README with no such block, with
//! CRLF line ends, with text added inside the block, or with a block that is cut short is refused.
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
