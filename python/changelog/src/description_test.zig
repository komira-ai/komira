//! The cases of the wheel's description (changelog.zig `description` and `nest`): the README, a blank line, then
//! the changelog with every heading one level down, the lines of a fenced block and text that only looks like a
//! heading left as they are, and a heading with no level below it refused naming the line.
const std = @import("std");
const lib = @import("changelog_lib");
const t = std.testing;

const PATH = "python/CHANGELOG.md";

fn nested(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var why: []const u8 = "";
    return lib.changelog.nest(a, &why, PATH, text);
}

fn described(a: std.mem.Allocator, readme: []const u8, changelog: []const u8) ![]u8 {
    var why: []const u8 = "";
    return lib.changelog.description(a, &why, readme, PATH, changelog);
}

test "every heading goes one level down" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("## Changelog\n\ntext\n\n### 0.1.9\n\n#### Deeper\n\n##### Deepest\n\n- **A.** a\n", try nested(a, "# Changelog\n\ntext\n\n## 0.1.9\n\n### Deeper\n\n#### Deepest\n\n- **A.** a\n"));
}

test "a fenced block and a line that is no heading are left as they are" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "# Top\n```sh\n# a comment\n## another\n```\n#hashtag\n####### seven\n  # indented\nnot # a heading\n```\n# open fence to the end\n";
    const want = "## Top\n```sh\n# a comment\n## another\n```\n#hashtag\n####### seven\n  # indented\nnot # a heading\n```\n# open fence to the end\n";
    try t.expectEqualStrings(want, try nested(a, text));
}

test "a level 6 heading is refused naming the file and the line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.changelog.nest(a, &why, PATH, "# a\n\n###### too deep\n"));
    try t.expectEqualStrings(PATH ++ ":3: a level 6 heading cannot go one level down", why);
}

test "the description is the README, one blank line, and the nested changelog" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const readme = "# komira\n\nSQL over local files.\n\n## What works\n";
    const changelog = "# Changelog\n\n## 0.1.9\n\n- **A.** a\n";
    const want = "# komira\n\nSQL over local files.\n\n## What works\n\n## Changelog\n\n### 0.1.9\n\n- **A.** a\n";
    try t.expectEqualStrings(want, try described(a, readme, changelog));
    // the README's own trailing blank lines do not add to the one between
    try t.expectEqualStrings(want, try described(a, readme ++ "\n\n", changelog));
}

test "a changelog heading that cannot nest is refused in the description" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.changelog.description(a, &why, "# komira\n", PATH, "# C\n###### x\n"));
    try t.expectEqualStrings(PATH ++ ":2: a level 6 heading cannot go one level down", why);
}
