//! The cases of the new section (changelog.zig `assemble`): its heading is `## 0.1.<n>` for a stamped build and
//! `## Unreleased` for an unstamped one; it holds the bullets of every fragment in file-name order, placed
//! before the first release heading and leaving the rest of the file as it was; a CHANGELOG.md that has a
//! `## Unreleased` heading, or no release heading, or a first second-level heading that is no version is refused
//! naming the file and the line.
const std = @import("std");
const lib = @import("changelog_lib");
const t = std.testing;

const PATH = "python/CHANGELOG.md";
const DIR = "python/changelog.d/";

const Frag = lib.changelog.Fragment;

const PREAMBLE = "# Changelog\n\nWhat each release added.\n\n";
const RELEASES = "## 0.1.1512\n\nThe first release.\n\n- **Platforms.** Linux.\n\n## 0.1.1500\n\n- **Older.** text\n";

fn make(a: std.mem.Allocator, changelog: []const u8, fragments: []const Frag, heading: []const u8) ![]u8 {
    var why: []const u8 = "";
    return lib.changelog.assemble(a, &why, .{ .changelog_path = PATH, .changelog = changelog, .fragments_dir = DIR, .fragments = fragments }, heading);
}

fn refusal(a: std.mem.Allocator, changelog: []const u8, fragments: []const Frag) ![]const u8 {
    var why: []const u8 = "";
    _ = lib.changelog.assemble(a, &why, .{ .changelog_path = PATH, .changelog = changelog, .fragments_dir = DIR, .fragments = fragments }, "0.1.9") catch |e| switch (e) {
        error.Refused => return why,
        else => return e,
    };
    return error.TestExpectedRefusal;
}

test "the section holds the bullets of the fragments in file-name order, whatever order they come in" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const fragments = [_]Frag{
        .{ .name = "zeta.md", .text = "- **Zeta.** z\n" },
        .{ .name = "alpha.md", .text = "- **Alpha.** a\n  continued\n" },
        .{ .name = "alpha-two.md", .text = "- **Alpha two.** a2\n" },
        .{ .name = "beta.md", .text = "- **Beta.** b\n" },
    };
    const want = PREAMBLE ++ "## 0.1.1600\n\n- **Alpha two.** a2\n- **Alpha.** a\n  continued\n- **Beta.** b\n- **Zeta.** z\n\n" ++ RELEASES;
    try t.expectEqualStrings(want, try make(a, PREAMBLE ++ RELEASES, &fragments, "0.1.1600"));
}

test "the section goes before the first release heading and every other byte of the file is kept" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const changelog = PREAMBLE ++ "Notes with `## code` in them.\n\n```\n## not a heading\n```\n\n" ++ RELEASES;
    const out = try make(a, changelog, &.{.{ .name = "x.md", .text = "- **X.** x\n" }}, "0.1.1600");
    const at = std.mem.indexOf(u8, changelog, "## 0.1.1512").?;
    try t.expectEqualStrings(changelog[0..at], out[0..at]);
    try t.expectEqualStrings(try std.mem.concat(a, u8, &.{ "## 0.1.1600\n\n- **X.** x\n\n", changelog[at..] }), out[at..]);
}

test "an unstamped build heads the section Unreleased" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    for ([_][]const u8{ "0", "" }) |stamp| {
        const heading = try lib.changelog.headingOf(a, &why, stamp);
        const out = try make(a, PREAMBLE ++ RELEASES, &.{.{ .name = "x.md", .text = "- **X.** x\n" }}, heading);
        try t.expectEqualStrings(PREAMBLE ++ "## Unreleased\n\n- **X.** x\n\n" ++ RELEASES, out);
    }
}

test "a stamp gives the version 0.1.<n> the wheel has, and a stamp that is no such number is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    var why: []const u8 = "";
    try t.expectEqualStrings("0.1.1600", try lib.changelog.headingOf(a, &why, "1600"));
    try t.expectEqualStrings("0.1.999999999", try lib.changelog.headingOf(a, &why, "999999999"));
    for ([_][]const u8{ "01", "-3", "1.5", "abc", "16 00", "0x10" }) |stamp| {
        try t.expectError(error.Refused, lib.changelog.headingOf(a, &why, stamp));
        try t.expectEqualStrings(try std.fmt.allocPrint(a, "the stamp `{s}` is not a positive number without leading zeros", .{stamp}), why);
    }
}

test "with no fragment the section says so, so the release still has its section" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(PREAMBLE ++ "## 0.1.9\n\n" ++ lib.changelog.no_entries ++ "\n\n" ++ RELEASES, try make(a, PREAMBLE ++ RELEASES, &.{}, "0.1.9"));
}

test "a blank line is put between the text above and the section when the file has none" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const frag = [_]Frag{.{ .name = "x.md", .text = "- **X.** x\n" }};
    try t.expectEqualStrings("# Changelog\n\n## 0.1.9\n\n- **X.** x\n\n## 0.1.1\n", try make(a, "# Changelog\n## 0.1.1\n", &frag, "0.1.9"));
    try t.expectEqualStrings("# Changelog\nno newline\n\n## 0.1.9\n\n- **X.** x\n\n## 0.1.1\n", try make(a, "# Changelog\nno newline\n## 0.1.1\n", &frag, "0.1.9"));
    try t.expectEqualStrings("## 0.1.9\n\n- **X.** x\n\n## 0.1.1\n", try make(a, "## 0.1.1\n", &frag, "0.1.9"));
}

test "a CHANGELOG.md with an Unreleased heading is refused naming the line, wherever the heading is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const why = PATH ++ ":5: a `## Unreleased` heading: entries go in " ++ DIR ++ " as files, and the release writes its section";
    try t.expectEqualStrings(why, try refusal(a, "# Changelog\n\ntext\n\n## Unreleased\n\n- **X.** x\n\n## 0.1.1512\n", &.{}));
    try t.expectEqualStrings(why, try refusal(a, "# Changelog\n\ntext\n\n## unreleased  \n\n## 0.1.1512\n", &.{}));
    try t.expectEqualStrings(PATH ++ ":7: a `## Unreleased` heading: entries go in " ++ DIR ++ " as files, and the release writes its section", try refusal(a, "# Changelog\n\n## 0.1.1512\n\n- **X.** x\n\n## Unreleased\n", &.{}));
}

test "a CHANGELOG.md with no release heading is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const want = PATH ++ ": no release heading (`## <version>`) to put the new section before";
    try t.expectEqualStrings(want, try refusal(a, "", &.{}));
    try t.expectEqualStrings(want, try refusal(a, "# Changelog\n\nNo release yet.\n\n### 0.1.5\n", &.{}));
    try t.expectEqualStrings(want, try refusal(a, "# Changelog\n\n```\n## 0.1.5\n```\n", &.{}));
}

test "a first second-level heading that is no version is refused naming the line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "Notes", "0", "1.", "0.1.x", ".1.2" }) |heading| {
        const text = try std.fmt.allocPrint(a, "# Changelog\n\n## {s}\n\n## 0.1.1512\n", .{heading});
        const want = try std.fmt.allocPrint(a, PATH ++ ":3: the first second-level heading is `## {s}`, not a release heading `## <version>` (numbers joined by dots)", .{heading});
        try t.expectEqualStrings(want, try refusal(a, text, &.{}));
    }
}

test "the refusals come before any fragment is read" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_]Frag{.{ .name = "BAD.md", .text = "" }};
    try t.expectEqualStrings(PATH ++ ": no release heading (`## <version>`) to put the new section before", try refusal(a, "# Changelog\n", &bad));
}
