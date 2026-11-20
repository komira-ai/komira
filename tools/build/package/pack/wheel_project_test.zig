//! The pyproject's [project] as the wheel rule reads it: the design's table
//! read field by field, and each thing the rule does not read refused with a
//! reason naming it.

const std = @import("std");
const project = @import("wheel_project.zig");
const fixture = @import("wheel_testing.zig");
const t = std.testing;

fn refusal(src: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    var d = project.Diag{};
    if (project.parse(arena.allocator(), &d, src)) |_| {
        arena.deinit();
        return error.TestUnexpectedResult;
    } else |err| try t.expectEqual(error.Refused, err);
    const msg = try t.allocator.dupe(u8, d.msg);
    arena.deinit();
    return msg;
}

fn expectRefused(src: []const u8, want: []const u8) !void {
    const msg = try refusal(src);
    defer t.allocator.free(msg);
    try t.expectEqualStrings(want, msg);
}

const head =
    \\[project]
    \\name = "komira"
    \\dynamic = ["version"]
    \\description = "d"
    \\readme = "README.md"
    \\requires-python = ">=3.13"
    \\license = "Apache-2.0"
    \\license-files = ["LICENSE"]
    \\
;

test "the design's [project] is read field by field" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const p = try fixture.parsed(arena.allocator());
    try t.expectEqualStrings("komira", p.name);
    try t.expectEqualStrings("SQL over local files, with libkomira, the komira query engine, in process", p.description);
    try t.expectEqualStrings("README.md", p.readme);
    try t.expectEqualStrings(">=3.13", p.requires_python);
    try t.expectEqualStrings("Apache-2.0", p.license);
    try t.expectEqual(@as(usize, 2), p.license_files.len);
    try t.expectEqualStrings("NOTICE", p.license_files[1]);
    try t.expectEqualStrings("The komira authors", p.authors[0]);
    try t.expectEqual(@as(usize, 4), p.keywords.len);
    try t.expectEqual(@as(usize, 3), p.classifiers.len);
    try t.expectEqualStrings("Typing :: Typed", p.classifiers[2]);
    try t.expectEqual(@as(usize, 1), p.dependencies.len);
    try t.expectEqualStrings("pyarrow", p.dependencies[0]);
    // Extras sorted by name, whatever the file's order.
    try t.expectEqualStrings("pandas", p.extras[0].name);
    try t.expectEqualStrings("polars", p.extras[1].name);
    try t.expectEqualStrings("Issue tracker", p.urls[1].label);
}

test "escapes, a trailing comma, CRLF line ends and an empty table are read" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var d = project.Diag{};
    const p = try project.parse(arena.allocator(), &d, head ++ "keywords = [\"a\\\"b\", \"c\\\\d\",]\r\n[project.urls]\r\n");
    try t.expectEqualStrings("a\"b", p.keywords[0]);
    try t.expectEqualStrings("c\\d", p.keywords[1]);
    try t.expectEqual(@as(usize, 0), p.urls.len);
}

test "a key [project] does not read is refused, naming the key" {
    const msg = try refusal(head ++ "scripts = \"x\"\n");
    defer t.allocator.free(msg);
    try t.expect(std.mem.startsWith(u8, msg, "pyproject line 9: `scripts` of [project] is not read by the wheel rule"));
}

test "another table, such as [build-system], is refused" {
    try expectRefused("[build-system]\nrequires = []\n" ++ head, "pyproject line 1: the table [build-system] is not read by the wheel rule (it reads [project], [project.optional-dependencies] and [project.urls]; the wheel is built by a Buck2 rule, not a build backend)");
    try expectRefused(head ++ "[[project.x]]\n", "pyproject line 9: an array of tables is not read by the wheel rule");
    try expectRefused(head ++ "[project]\n", "pyproject line 9: the table [project] is given twice");
    try expectRefused(head ++ "[project\n", "pyproject line 9: a table header is not closed");
}

test "every required key is required" {
    try expectRefused("[project]\ndynamic = [\"version\"]\n", "pyproject: [project] has no `name`");
    try expectRefused("[project]\nname = \"komira\"\ndynamic = [\"version\"]\n", "pyproject: [project] has no `description`");
    try expectRefused("[project]\nname = \"k\"\ndescription = \"d\"\n", "pyproject: [project] has no `readme`");
    try expectRefused("[project]\nname = \"k\"\ndescription = \"d\"\nreadme = \"R.md\"\n", "pyproject: [project] has no `requires-python`");
    try expectRefused("[project]\nname = \"k\"\ndescription = \"d\"\nreadme = \"R.md\"\nrequires-python = \">=3\"\n", "pyproject: [project] has no `license` (an SPDX expression)");
    try expectRefused("[project]\nname = \"k\"\ndescription = \"d\"\nreadme = \"R.md\"\nrequires-python = \">=3\"\nlicense = \"MIT\"\n", "pyproject: [project] has no `license-files`");
    try expectRefused("[project]\nname = \"k\"\ndescription = \"d\"\nreadme = \"R.md\"\nrequires-python = \">=3\"\nlicense = \"MIT\"\nlicense-files = [\"L\"]\n", "pyproject: [project] has no `dynamic = [\"version\"]`: the wheel rule stamps the version");
}

test "an empty license-files, or a dynamic other than [\"version\"], is refused" {
    const no_lic = "[project]\nname = \"k\"\ndynamic = [\"version\"]\ndescription = \"d\"\nreadme = \"R.md\"\nrequires-python = \">=3\"\nlicense = \"MIT\"\nlicense-files = []\n";
    try expectRefused(no_lic, "pyproject: `license-files` is empty, and a wheel without its licence text is refused");
    try expectRefused("[project]\ndynamic = [\"version\", \"readme\"]\n", "pyproject line 2: `dynamic` must be exactly [\"version\"]: the wheel rule stamps the version and states every other field from the file");
}

test "a name or an extra that is not normalised is refused" {
    try expectRefused("[project]\nname = \"Komira\"\ndynamic = [\"version\"]\ndescription = \"d\"\nreadme = \"R.md\"\nrequires-python = \">=3\"\nlicense = \"MIT\"\nlicense-files = [\"L\"]\n", "pyproject: the name `Komira` is not a normalised name (lowercase letters, digits, single `-`)");
    try expectRefused(head ++ "[project.optional-dependencies]\nPandas = [\"pandas\"]\n", "pyproject line 10: the extra `Pandas` is not a normalised name (lowercase letters, digits, single `-`)");
    try t.expect(project.normalName("query-engine2"));
    try t.expect(!project.normalName("a--b"));
    try t.expect(!project.normalName("-a"));
    try t.expect(!project.normalName("a_b"));
    try t.expect(!project.normalName(""));
}

test "a requirement of an extra with its own marker is refused" {
    try expectRefused(head ++ "[project.optional-dependencies]\npandas = [\"pandas; python_version > '3'\"]\n", "pyproject line 10: the requirement `pandas; python_version > '3'` of the extra `pandas` has a marker; the wheel rule writes the extra's marker itself and reads none in the file");
}

test "values that would break METADATA's lines or lists are refused" {
    try expectRefused(head ++ "keywords = [\"a,b\"]\n", "pyproject line 9: the keyword `a,b` holds `,`, which separates keywords in METADATA");
    try expectRefused(head ++ "authors = [{ name = \"A, B\" }]\n", "pyproject line 9: an author name holds `,`, which separates authors in METADATA");
    try expectRefused(head ++ "authors = [{ name = \"A\", email = \"a@example.com\" }]\n", "pyproject line 9: an author must be exactly { name = \"...\" } (the wheel rule writes no e-mail address)");
    try expectRefused(head ++ "authors = [\"A\"]\n", "pyproject line 9: `authors` must be an array of inline tables");
    try expectRefused(head ++ "classifiers = [\"\"]\n", "pyproject: `classifiers` is empty");
    try expectRefused(head ++ "[project.urls]\n\"a,b\" = \"https://example.com\"\n", "pyproject line 10: the URL label `a,b` holds `,`, which ends the label in METADATA");
}

test "TOML the rule does not read is refused with its line" {
    try expectRefused(head ++ "x = 1\n", "pyproject line 9: a value starting `1` is not read by the wheel rule (it reads basic strings, arrays of them, and arrays of inline tables of them)");
    try expectRefused(head ++ "x = 'lit'\n", "pyproject line 9: a value starting `'` is not read by the wheel rule (it reads basic strings, arrays of them, and arrays of inline tables of them)");
    try expectRefused(head ++ "x = \"\"\"a\"\"\"\n", "pyproject line 9: a multi-line string is not read by the wheel rule");
    try expectRefused(head ++ "x = \"a\\n\"\n", "pyproject line 9: the escape `\\n` is not read by the wheel rule");
    try expectRefused(head ++ "x = \"a\n", "pyproject line 9: a string is not closed");
    try expectRefused(head ++ "a.b = \"x\"\n", "pyproject line 9: a dotted key is not read by the wheel rule");
    try expectRefused(head ++ "name = \"other\"\n", "pyproject line 9: `name` is given twice (first on line 2)");
    try expectRefused(head ++ "keywords = [\"a\" \"b\"]\n", "pyproject line 9: `,` or `]` expected in an array");
    try expectRefused(head ++ "keywords = [\"a\", { name = \"b\" }]\n", "pyproject line 9: an array mixes strings and tables");
    try expectRefused(head ++ "keywords = [\"a\"", "pyproject line 9: an array is not closed");
    try expectRefused(head ++ "description2 = \"a\" junk\n", "pyproject line 9: unexpected `j` after a value");
    try expectRefused("name = \"k\"\n", "pyproject line 1: a key outside any table");
    try expectRefused(head ++ "authors = [{ name = \"a\" name = \"b\" }]\n", "pyproject line 9: `,` or `}` expected in an inline table");
    try expectRefused(head ++ "authors = [{ name = \"a\", name = \"b\" }]\n", "pyproject line 9: `name` is given twice in an inline table");
    try expectRefused(head ++ "description = [\"a\"]\n", "pyproject line 9: `description` is given twice (first on line 4)");
    try expectRefused(head ++ "keywords = \"a\"\n", "pyproject line 9: `keywords` must be an array of strings");
    try expectRefused("[project]\nname = [\"k\"]\n", "pyproject line 2: `name` must be a string");
    try expectRefused(head ++ "x =\n", "pyproject line 9: a value starting `\n` is not read by the wheel rule (it reads basic strings, arrays of them, and arrays of inline tables of them)");
}
