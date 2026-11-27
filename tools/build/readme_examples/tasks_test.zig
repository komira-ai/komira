//! The common-tasks check (tasks.zig): what passes, its report, and each
//! refusal of the catalogue and of a task directory, word for word.

const std = @import("std");
const tasks = @import("tasks.zig");
const include = @import("include.zig");
const t = std.testing;

const Arena = std.heap.ArenaAllocator;

const CATALOGUE =
    \\[
    \\  {"rank": 1, "slug": "read-csv-file", "category": "Read", "question": "How do I read a CSV file?", "status": "works"},
    \\  {"rank": 2, "slug": "write-csv", "category": "Write", "question": "How do I write a CSV file?", "status": "partial", "issues": ["komira-ai/komira#12"]},
    \\  {"rank": 3, "slug": "read-excel", "category": "Read", "question": "How do I read Excel?", "status": "gap", "issues": ["komira-ai/komira#7", "komira-ai/kbf#30"]}
    \\]
;

const EXAMPLE = "import komira\nprint(1)\n";
const EXPECTED = "1\n";
const PAGE = "# How do I read a CSV file?\n\nAnswer.\n\n<!-- include example.py -->\n```python\nimport komira\nprint(1)\n```\n\n<!-- include expected_output.txt -->\n```text\n1\n```\n";
const PAGE2 = "# How do I write a CSV file?\n\n<!-- include example.py -->\n```python\nimport komira\nprint(1)\n```\n\n<!-- include expected_output.txt -->\n```text\n1\n```\n";

const FILES = [_]tasks.File{
    .{ .name = "example.py", .data = EXAMPLE },
    .{ .name = "expected_output.txt", .data = EXPECTED },
    .{ .name = "page.md", .data = PAGE },
};

fn good(name: []const u8) tasks.Task {
    return .{ .name = name, .files = &FILES };
}

/// A task directory `name` holding `files`.
fn holding(name: []const u8, files: []const tasks.File) tasks.Task {
    return .{ .name = name, .files = files };
}

/// The refusals of `catalogue` with `list`, under the display `d`.
fn refusals(a: std.mem.Allocator, catalogue: []const u8, list: []const tasks.Task) ![]const []const u8 {
    const r = try tasks.check(a, "d", "c.json", catalogue, list);
    return r.refusals;
}

fn expectOnly(catalogue: []const u8, list: []const tasks.Task, want: []const u8) !void {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const got = try refusals(arena.allocator(), catalogue, list);
    if (got.len != 1) {
        for (got) |g| std.debug.print("refusal: {s}\n", .{g});
        return error.TestExpectedOneRefusal;
    }
    try t.expectEqualStrings(want, got[0]);
}

/// CATALOGUE with the entry of rank 1 replaced by `entry`.
fn withFirst(a: std.mem.Allocator, entry: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, CATALOGUE, "{\"rank\": 1").?;
    const end = std.mem.indexOfPos(u8, CATALOGUE, start, "},\n").? + 1;
    return std.mem.concat(a, u8, &.{ CATALOGUE[0..start], entry, CATALOGUE[end..] });
}

fn expectFirstRefused(entry: []const u8, want: []const u8) !void {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const cat = try withFirst(arena.allocator(), entry);
    try expectOnly(cat, &.{}, want);
}

test "a catalogue and task directories that agree pass, and the report names each directory and its status" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const two = holding("2-write-csv", &.{
        .{ .name = "example.py", .data = EXAMPLE },
        .{ .name = "expected_output.txt", .data = EXPECTED },
        .{ .name = "page.md", .data = PAGE2 },
        .{ .name = "probe_native.error.txt", .data = "ParseError: no\n" },
        .{ .name = "probe_native.py", .data = "raise SystemExit\n" },
    });
    const r = try tasks.check(arena.allocator(), "d", "c.json", CATALOGUE, &.{ good("1-read-csv-file"), two });
    try t.expectEqual(@as(usize, 0), r.refusals.len);
    try t.expectEqualStrings("1-read-csv-file works\n2-write-csv partial\n", r.report);
}

test "no task directory passes with an empty report" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const r = try tasks.check(arena.allocator(), "d", "c.json", CATALOGUE, &.{});
    try t.expectEqual(@as(usize, 0), r.refusals.len);
    try t.expectEqualStrings("", r.report);
}

test "a catalogue that is not JSON, not an array or empty is refused" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const got = try refusals(arena.allocator(), "[{", &.{});
    try t.expectEqual(@as(usize, 1), got.len);
    try t.expect(std.mem.startsWith(u8, got[0], "c.json: not JSON: "));
    try expectOnly("{\"rank\": 1}", &.{}, "c.json: not a non-empty JSON array");
    try expectOnly("[]", &.{}, "c.json: not a non-empty JSON array");
}

test "an entry that is not an object is refused" {
    try expectFirstRefused("7", "c.json: entry 1 is not an object");
}

test "entries out of rank order, or with a rank that is not an integer, are refused" {
    try expectFirstRefused(
        "{\"rank\": 4, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\"}",
        "c.json: entry 1 does not have \"rank\": 1 (the entries are in rank order from 1)",
    );
    try expectFirstRefused(
        "{\"rank\": \"1\", \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\"}",
        "c.json: entry 1 does not have \"rank\": 1 (the entries are in rank order from 1)",
    );
    try expectFirstRefused(
        "{\"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\"}",
        "c.json: entry 1 does not have \"rank\": 1 (the entries are in rank order from 1)",
    );
}

test "an unknown key is refused by name" {
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\", \"isues\": []}",
        "c.json: rank 1: unknown key \"isues\"",
    );
}

test "a missing, empty or non-string field is refused by name" {
    try expectFirstRefused(
        "{\"rank\": 1, \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\"}",
        "c.json: rank 1: no \"slug\"",
    );
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"\", \"question\": \"How do I a?\", \"status\": \"works\"}",
        "c.json: rank 1: \"category\" is not a non-empty string",
    );
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": 5, \"status\": \"works\"}",
        "c.json: rank 1: \"question\" is not a non-empty string",
    );
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\"}",
        "c.json: rank 1: no \"status\"",
    );
}

test "a slug that is not lowercase letters, digits and single hyphens is refused" {
    const bad = [_][]const u8{ "Read-csv", "read--csv", "-read", "read-", "read_csv", "read csv" };
    for (bad) |s| {
        var arena = Arena.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const entry = try std.fmt.allocPrint(a, "{{\"rank\": 1, \"slug\": \"{s}\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"works\"}}", .{s});
        const want = try std.fmt.allocPrint(a, "c.json: rank 1: slug \"{s}\" is not lowercase letters, digits and single hyphens", .{s});
        try expectOnly(try withFirst(a, entry), &.{}, want);
    }
}

test "two entries with one slug are refused, naming the first" {
    const cat =
        \\[
        \\  {"rank": 1, "slug": "x", "category": "Read", "question": "How do I a?", "status": "works"},
        \\  {"rank": 2, "slug": "x", "category": "Read", "question": "How do I b?", "status": "works"}
        \\]
    ;
    try expectOnly(cat, &.{}, "c.json: rank 2: slug \"x\" is also rank 1's");
}

test "a question that is not How do I ...? is refused" {
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"Read a CSV file\", \"status\": \"works\"}",
        "c.json: rank 1: the question does not start \"How do I \" and end \"?\"",
    );
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I read a CSV file\", \"status\": \"works\"}",
        "c.json: rank 1: the question does not start \"How do I \" and end \"?\"",
    );
}

test "a status other than works, partial or gap is refused" {
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"done\"}",
        "c.json: rank 1: status \"done\" is not works, partial or gap",
    );
}

test "a gap with no issues is refused" {
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"gap\"}",
        "c.json: rank 1: a gap names the issues that block it in \"issues\"",
    );
}

test "issues that are empty, not an array, or not komira-ai/<repo>#<n> are refused" {
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"gap\", \"issues\": []}",
        "c.json: rank 1: \"issues\" is not a non-empty array",
    );
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"gap\", \"issues\": \"komira-ai/komira#1\"}",
        "c.json: rank 1: \"issues\" is not a non-empty array",
    );
    const bad = [_][]const u8{ "#12", "komira#12", "komira-ai/komira#", "komira-ai/komira#012", "komira-ai/#12", "komira-ai/Komira#12", "komira-ai/komira#1a", "other/komira#12", "komira-ai/komira" };
    for (bad) |s| {
        var arena = Arena.init(t.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const entry = try std.fmt.allocPrint(a, "{{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"gap\", \"issues\": [\"{s}\"]}}", .{s});
        try expectOnly(try withFirst(a, entry), &.{}, "c.json: rank 1: an issue is not komira-ai/<repo>#<n>");
    }
    try expectFirstRefused(
        "{\"rank\": 1, \"slug\": \"a\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"gap\", \"issues\": [3]}",
        "c.json: rank 1: an issue is not komira-ai/<repo>#<n>",
    );
}

test "a directory not named <rank>-<slug> is refused" {
    const bad = [_][]const u8{ "read-csv-file", "01-read-csv-file", "1", "x1-read", "-read" };
    for (bad) |name| {
        var arena = Arena.init(t.allocator);
        defer arena.deinit();
        const want = try std.fmt.allocPrint(arena.allocator(), "d/{s}: a task directory is named <rank>-<slug>", .{name});
        try expectOnly(CATALOGUE, &.{good(name)}, want);
    }
}

test "a directory whose slug the catalogue does not have is refused" {
    try expectOnly(CATALOGUE, &.{good("1-read-csv")}, "d/1-read-csv: the catalogue has no slug \"read-csv\"");
}

test "a directory whose rank is not its slug's is refused, naming the slug's rank" {
    try expectOnly(CATALOGUE, &.{good("4-read-csv-file")}, "d/4-read-csv-file: slug \"read-csv-file\" is rank 1 in the catalogue");
    try expectOnly(CATALOGUE, &.{good("2-read-csv-file")}, "d/2-read-csv-file: slug \"read-csv-file\" is rank 1 in the catalogue");
}

test "a directory of a gap is refused" {
    try expectOnly(CATALOGUE, &.{good("3-read-excel")}, "d/3-read-excel: rank 3 is a gap, which has no example");
}

test "a directory of a refused entry is named only by the catalogue's refusal" {
    // The entry is refused for its status; its slug still finds it.
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const cat = try withFirst(arena.allocator(), "{\"rank\": 1, \"slug\": \"read-csv-file\", \"category\": \"Read\", \"question\": \"How do I a?\", \"status\": \"maybe\"}");
    try expectOnly(cat, &.{good("1-read-csv-file")}, "c.json: rank 1: status \"maybe\" is not works, partial or gap");
}

test "a file or subdirectory other than the three and probes is refused" {
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &(FILES ++ [_]tasks.File{.{ .name = "data.csv", .data = "a\n" }}))}, "d/1-read-csv-file/data.csv: a task directory holds only example.py, expected_output.txt, page.md and probe_<name>.py with probe_<name>.error.txt");
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &(FILES ++ [_]tasks.File{.{ .name = "out", .data = null }}))}, "d/1-read-csv-file/out/: a task directory holds no directory");
    // A probe name with a capital or a hyphen is no probe.
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &(FILES ++ [_]tasks.File{.{ .name = "probe_Native.py", .data = "x\n" }}))}, "d/1-read-csv-file/probe_Native.py: a task directory holds only example.py, expected_output.txt, page.md and probe_<name>.py with probe_<name>.error.txt");
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &(FILES ++ [_]tasks.File{.{ .name = "probe_.py", .data = "x\n" }}))}, "d/1-read-csv-file/probe_.py: a task directory holds only example.py, expected_output.txt, page.md and probe_<name>.py with probe_<name>.error.txt");
}

/// That the refusals of `list` against CATALOGUE are exactly `want`, in order.
fn expectAll(list: []const tasks.Task, want: []const []const u8) !void {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const got = try refusals(arena.allocator(), CATALOGUE, list);
    try t.expectEqual(want.len, got.len);
    for (want, got) |w, g| try t.expectEqualStrings(w, g);
}

test "each missing file is refused, and the page's include of it too" {
    try expectAll(&.{holding("1-read-csv-file", &.{ FILES[1], FILES[2] })}, &.{
        "d/1-read-csv-file: no example.py",
        "d/1-read-csv-file/page.md:5: include example.py: the task directory has no example.py",
    });
    try expectAll(&.{holding("1-read-csv-file", &.{ FILES[0], FILES[2] })}, &.{
        "d/1-read-csv-file: no expected_output.txt",
        "d/1-read-csv-file/page.md:11: include expected_output.txt: the task directory has no expected_output.txt",
    });
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &.{ FILES[0], FILES[1] })}, "d/1-read-csv-file: no page.md");
}

const PARTIAL = [_]tasks.File{
    .{ .name = "example.py", .data = EXAMPLE },
    .{ .name = "expected_output.txt", .data = EXPECTED },
    .{ .name = "page.md", .data = PAGE2 },
};

test "a probe without its error line, or an error line without its probe, is refused" {
    try expectOnly(CATALOGUE, &.{holding("2-write-csv", &(PARTIAL ++ [_]tasks.File{.{ .name = "probe_native.py", .data = "x\n" }}))}, "d/2-write-csv/probe_native.py: no probe_native.error.txt, the line the probe must fail with");
    try expectOnly(CATALOGUE, &.{holding("2-write-csv", &(PARTIAL ++ [_]tasks.File{.{ .name = "probe_native.error.txt", .data = "E: x\n" }}))}, "d/2-write-csv/probe_native.error.txt: no probe_native.py, the probe it is the failure of");
}

test "an error line that is not one line ended by a line feed is refused" {
    const bad = [_][]const u8{ "E: x", "E: x\ny\n", "\n", "", "E: x\r\n" };
    inline for (bad) |d| {
        try expectOnly(CATALOGUE, &.{holding("2-write-csv", &(PARTIAL ++ [_]tasks.File{
            .{ .name = "probe_native.error.txt", .data = d },
            .{ .name = "probe_native.py", .data = "x\n" },
        }))}, "d/2-write-csv/probe_native.error.txt: not one line ended by a line feed");
    }
}

test "a probe on a task that works is refused" {
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &(FILES ++ [_]tasks.File{
        .{ .name = "probe_native.error.txt", .data = "E: x\n" },
        .{ .name = "probe_native.py", .data = "x\n" },
    }))}, "d/1-read-csv-file: rank 1 works, and a probe is for a gap or partial task (what komira cannot do yet)");
}

test "the page's own refusals are reported, named by the page" {
    const page = "# Reading CSV\n\n<!-- include example.py -->\n```python\nimport komira\nprint(1)\n```\n\n<!-- include expected_output.txt -->\n```text\n1\n```\n";
    try expectOnly(CATALOGUE, &.{holding("1-read-csv-file", &.{ FILES[0], FILES[1], .{ .name = "page.md", .data = page } })}, "d/1-read-csv-file/page.md:1: the first line is not \"# How do I read a CSV file?\"");
}

test "every refusal is reported, and a refused check reports no directory" {
    var arena = Arena.init(t.allocator);
    defer arena.deinit();
    const one = holding("1-read-csv-file", &.{ .{ .name = "example.py", .data = "x\n" }, FILES[1], FILES[2] });
    const r = try tasks.check(arena.allocator(), "d", "c.json", CATALOGUE, &.{ one, good("3-read-excel") });
    try t.expectEqual(@as(usize, 2), r.refusals.len);
    try t.expectEqualStrings("d/1-read-csv-file/page.md:7: include example.py is stale: this line is not line 1 of d/1-read-csv-file/example.py; " ++ include.TASK.fill_hint, r.refusals[0]);
    try t.expectEqualStrings("d/3-read-excel: rank 3 is a gap, which has no example", r.refusals[1]);
    try t.expectEqualStrings("", r.report);
}
