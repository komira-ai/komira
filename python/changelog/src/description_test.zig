//! The cases of the wheel's description (changelog.zig `description`, `nest`, `pin` and `linksOf`): the README, a
//! blank line, then the changelog with every heading one level down, the lines of a fenced block and text that only
//! looks like a heading left as they are, and a heading with no level below it refused naming the line; in a
//! stamped build every link to the repository's `main` pinned to the build's commit, other links left as they
//! are, and a stamp without a commit, a commit without a stamp, or a commit that is not 40 lower-case hexadecimal
//! digits refused.
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
    return lib.changelog.description(a, &why, readme, PATH, changelog, .main);
}

const COMMIT = "0123456789abcdef0123456789abcdef01234567";

fn pinned(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var why: []const u8 = "";
    return lib.changelog.pin(a, &why, text, COMMIT);
}

fn linksRefusal(a: std.mem.Allocator, stamp: []const u8, commit: ?[]const u8) ![]const u8 {
    var why: []const u8 = "";
    try t.expectError(error.Refused, lib.changelog.linksOf(a, &why, stamp, commit));
    return why;
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
    try t.expectError(error.Refused, lib.changelog.description(a, &why, "# komira\n", PATH, "# C\n###### x\n", .main));
    try t.expectEqualStrings(PATH ++ ":2: a level 6 heading cannot go one level down", why);
}

test "every link to a file or a directory of main is pinned to the commit" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "[install](https://github.com/komira-ai/komira/blob/main/docs/install.md) and " ++
        "[pages](https://github.com/komira-ai/komira/tree/main/python/docs/)\n" ++
        "```text\nhttps://github.com/komira-ai/komira/blob/main/python/CHANGELOG.md\n```\n";
    const want = "[install](https://github.com/komira-ai/komira/blob/" ++ COMMIT ++ "/docs/install.md) and " ++
        "[pages](https://github.com/komira-ai/komira/tree/" ++ COMMIT ++ "/python/docs/)\n" ++
        "```text\nhttps://github.com/komira-ai/komira/blob/" ++ COMMIT ++ "/python/CHANGELOG.md\n```\n";
    try t.expectEqualStrings(want, try pinned(a, text));
}

test "a link that is not to a file or a directory of main is left as it is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "https://github.com/komira-ai/komira\n" ++
        "https://github.com/komira-ai/komira/issues\n" ++
        "https://github.com/komira-ai/komira/blob/mainline/x.md\n" ++
        "https://github.com/komira-ai/komira/blob/other/x.md\n" ++
        "https://github.com/komira-ai/komira/blob/main\n" ++
        "https://github.com/someone/komira/blob/main/x.md\n" ++
        "github.com/komira-ai/komira/blob/main/x.md\n" ++
        "https://github.com/komira-ai/komira/";
    try t.expectEqualStrings(text, try pinned(a, text));
    try t.expectEqualStrings("", try pinned(a, ""));
}

test "a commit that is not 40 lower-case hexadecimal digits is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", COMMIT[0..39], COMMIT ++ "0", "0123456789ABCDEF0123456789abcdef01234567", "0123456789abcdeg0123456789abcdef01234567", "main" }) |commit| {
        var why: []const u8 = "";
        try t.expectError(error.Refused, lib.changelog.pin(a, &why, "text", commit));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "the commit `{s}` is not 40 lower-case hexadecimal digits", .{commit}), why);
    }
}

test "a stamped description links to its commit and an unstamped one to main" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectEqualStrings(COMMIT, (try lib.changelog.linksOf(a, &why, "1623", COMMIT)).commit);
    try t.expectEqual(@as(lib.changelog.Links, .main), try lib.changelog.linksOf(a, &why, "0", null));
    try t.expectEqual(@as(lib.changelog.Links, .main), try lib.changelog.linksOf(a, &why, "", null));

    const readme = "# komira\n\n[install](https://github.com/komira-ai/komira/blob/main/docs/install.md)\n";
    const changelog = "# Changelog\n\n[how](https://github.com/komira-ai/komira/blob/main/python/README.md)\n\n## 0.1.9\n";
    try t.expectEqualStrings(
        "# komira\n\n[install](https://github.com/komira-ai/komira/blob/" ++ COMMIT ++ "/docs/install.md)\n\n" ++
            "## Changelog\n\n[how](https://github.com/komira-ai/komira/blob/" ++ COMMIT ++ "/python/README.md)\n\n### 0.1.9\n",
        try lib.changelog.description(a, &why, readme, PATH, changelog, .{ .commit = COMMIT }),
    );
    try t.expectEqualStrings(
        "# komira\n\n[install](https://github.com/komira-ai/komira/blob/main/docs/install.md)\n\n" ++
            "## Changelog\n\n[how](https://github.com/komira-ai/komira/blob/main/python/README.md)\n\n### 0.1.9\n",
        try described(a, readme, changelog),
    );
}

test "a stamp with no commit, a commit with no stamp and a bad commit or stamp are refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings("the stamp `1623` is given with no commit: a stamped description pins its links to the commit the wheel is built from", try linksRefusal(a, "1623", null));
    try t.expectEqualStrings("the commit `" ++ COMMIT ++ "` is given for an unstamped build, whose description links to `main`: a commit needs a stamp", try linksRefusal(a, "0", COMMIT));
    try t.expectEqualStrings("the commit `" ++ COMMIT ++ "` is given for an unstamped build, whose description links to `main`: a commit needs a stamp", try linksRefusal(a, "", COMMIT));
    try t.expectEqualStrings("the commit `main` is not 40 lower-case hexadecimal digits", try linksRefusal(a, "1623", "main"));
    try t.expectEqualStrings("the stamp `07` is not a positive number without leading zeros", try linksRefusal(a, "07", COMMIT));
}
