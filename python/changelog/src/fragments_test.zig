//! The cases of what a fragment of python/changelog.d may be (changelog.zig): a file named `<slug>.md` of
//! bullets with indented continuation lines passes; a name that is not a slug, an empty file, a line that is
//! neither a bullet nor a continuation, a heading, a continuation with no bullet before it and a carriage
//! return are each refused naming the file and the line.
const std = @import("std");
const lib = @import("changelog_lib");
const t = std.testing;

const CHANGELOG = "# Changelog\n\nWhat each release added.\n\n## 0.1.7\n\n- **Old.** text\n";
const DIR = "python/changelog.d/";

const Frag = lib.changelog.Fragment;

fn inputs(fragments: []const Frag) lib.changelog.Inputs {
    return .{ .changelog_path = "python/CHANGELOG.md", .changelog = CHANGELOG, .fragments_dir = DIR, .fragments = fragments };
}

fn passes(a: std.mem.Allocator, fragments: []const Frag) ![]u8 {
    var why: []const u8 = "";
    return lib.changelog.assemble(a, &why, inputs(fragments), "0.1.9") catch |e| {
        if (e == error.Refused) std.debug.print("refused: {s}\n", .{why});
        return e;
    };
}

fn refusal(a: std.mem.Allocator, fragments: []const Frag) ![]const u8 {
    var why: []const u8 = "";
    _ = lib.changelog.assemble(a, &why, inputs(fragments), "0.1.9") catch |e| switch (e) {
        error.Refused => return why,
        else => return e,
    };
    return error.TestExpectedRefusal;
}

fn one(a: std.mem.Allocator, name: []const u8, text: []const u8) ![]const u8 {
    return refusal(a, &.{.{ .name = name, .text = text }});
}

test "a fragment of bullets with indented continuation lines is taken as it is" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const text = "- **First.** one line\n  and its continuation,\n    indented further.\n- **Second.** another bullet\n";
    const out = try passes(a, &.{.{ .name = "first-and-second.md", .text = text }});
    try t.expectEqualStrings("# Changelog\n\nWhat each release added.\n\n## 0.1.9\n\n" ++
        "- **First.** one line\n  and its continuation,\n    indented further.\n- **Second.** another bullet\n\n" ++
        "## 0.1.7\n\n- **Old.** text\n", out);
}

test "a slug may hold digits and inner hyphens" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    _ = try passes(a, &.{ .{ .name = "3-11.md", .text = "- **a.** b\n" }, .{ .name = "python-3-11-and-3-12.md", .text = "- **c.** d\n" } });
    try t.expect(lib.changelog.isFragmentName("a.md"));
    try t.expect(lib.changelog.isFragmentName("0.md"));
}

test "blank lines before the first bullet and after the last are cut, and those between are kept" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const out = try passes(a, &.{.{ .name = "x.md", .text = "\n  \n- **A.** a\n\n- **B.** b\n  \n\n" }});
    try t.expectEqualStrings("# Changelog\n\nWhat each release added.\n\n## 0.1.9\n\n- **A.** a\n\n- **B.** b\n\n## 0.1.7\n\n- **Old.** text\n", out);
}

test "a name that is not a slug followed by .md is refused naming it" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const bad = [_][]const u8{ "Notes.md", "my_change.md", "-first.md", "a b.md", "notes.txt", "notes", ".md", "notes.md.md.txt", "sub/notes.md", "caf\xc3\xa9.md", "notes.MD", ".notes.md" };
    for (bad) |name| {
        const want = try std.fmt.allocPrint(a, DIR ++ "{s}: the name is not `<slug>.md` with a slug of lower-case letters, digits and hyphens that does not start with a hyphen", .{name});
        try t.expectEqualStrings(want, try one(a, name, "- **A.** a\n"));
        try t.expect(!lib.changelog.isFragmentName(name));
    }
}

test "an empty fragment is refused naming the file, whatever blank lines it holds" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    for ([_][]const u8{ "", "\n", "\n\n  \n" }) |text| {
        try t.expectEqualStrings(DIR ++ "empty.md: the fragment is empty: it holds no bullet", try one(a, "empty.md", text));
    }
}

test "a line that is neither a bullet nor a continuation is refused naming the file and the line" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const want = DIR ++ "prose.md:3: the line is neither a bullet (`- `) nor a continuation indented two spaces";
    try t.expectEqualStrings(want, try one(a, "prose.md", "- **A.** a\n  more\nplain text\n"));
    try t.expectEqualStrings(DIR ++ "prose.md:1: the line is neither a bullet (`- `) nor a continuation indented two spaces", try one(a, "prose.md", "* **A.** a\n"));
    try t.expectEqualStrings(DIR ++ "prose.md:2: the line is neither a bullet (`- `) nor a continuation indented two spaces", try one(a, "prose.md", "- **A.** a\n -one space\n"));
    try t.expectEqualStrings(DIR ++ "prose.md:2: the line is neither a bullet (`- `) nor a continuation indented two spaces", try one(a, "prose.md", "- **A.** a\n\tcontinued with a tab\n"));
    try t.expectEqualStrings(DIR ++ "prose.md:1: the line is neither a bullet (`- `) nor a continuation indented two spaces", try one(a, "prose.md", "-**A.** a\n"));
}

test "a heading is refused naming the file and the line, whatever its level" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const want = DIR ++ "head.md:1: a heading: a fragment holds bullets only, and the title is the bold text of its bullet";
    try t.expectEqualStrings(want, try one(a, "head.md", "# Title\n- **A.** a\n"));
    try t.expectEqualStrings(DIR ++ "head.md:2: a heading: a fragment holds bullets only, and the title is the bold text of its bullet", try one(a, "head.md", "- **A.** a\n## 0.1.8\n"));
    try t.expectEqualStrings(DIR ++ "head.md:3: a heading: a fragment holds bullets only, and the title is the bold text of its bullet", try one(a, "head.md", "- **A.** a\n\n###### deep\n"));
}

test "an indented line before the first bullet is refused" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(DIR ++ "lead.md:2: an indented line before the first bullet: a continuation continues a bullet", try one(a, "lead.md", "\n  text before any bullet\n- **A.** a\n"));
}

test "a carriage return is refused naming the line it is on" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    try t.expectEqualStrings(DIR ++ "crlf.md:2: the line holds a carriage return: a fragment's lines end with a line feed alone", try one(a, "crlf.md", "- **A.** a\n  more\r\n"));
}

test "of two bad fragments the one first by name is the one refused, and no output is made" {
    var ar = std.heap.ArenaAllocator.init(t.allocator);
    defer ar.deinit();
    const a = ar.allocator();
    const got = try refusal(a, &.{ .{ .name = "zeta.md", .text = "text\n" }, .{ .name = "alpha.md", .text = "# h\n" } });
    try t.expectEqualStrings(DIR ++ "alpha.md:1: a heading: a fragment holds bullets only, and the title is the bold text of its bullet", got);
}
