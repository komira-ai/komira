//! One mopm: every package names the same mopm version.
//!
//! Each package built with `mojo_package` names its mopm in its own
//! `mopm-toolchain.toml` (`[toolchain]`, `mopm = "<version>"`). Nothing else
//! compares the packages with each other: the lock check holds each table to
//! its own lock, and the toolchain check holds each lock to its own file. This
//! tool reads every file of that name in the tree and refuses unless they all
//! name one version, and that version is the one the release flow builds with.
//!
//! What is read: every file named `mopm-toolchain.toml` at any depth of the
//! tree (`collect`). A file whose path has a row in the exceptions list is a
//! fixture that tests a version, and is not compared. The rest, the checked
//! set, must name one version: the reference is the version most packages name
//! (a tie goes to the release flow's, then to the first path), and each package
//! that names another is a finding naming both. The release flow's version is
//! a finding when it differs from the reference. An empty checked set is a
//! finding, never a pass; so is a file with no `mopm` key under `[toolchain]`.
//!
//! The exceptions list is a TSV: `#` comment lines, blank lines, and rows of
//! exactly three tab-separated fields: `except`, the path of the file and a
//! reason (not empty). A row whose file is not in the tree is a finding.

const std = @import("std");
const Alloc = std.mem.Allocator;

pub const file_name = "mopm-toolchain.toml";

/// A `mopm-toolchain.toml` of the tree and the version it names (null when it
/// names none).
pub const File = struct { path: []const u8, version: ?[]const u8 };

/// The version the `mopm` key of the `[toolchain]` table names, or null.
pub fn parseVersion(text: []const u8) ?[]const u8 {
    var in_toolchain = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0 or l[0] == '#') continue;
        if (l[0] == '[') {
            in_toolchain = std.mem.eql(u8, l, "[toolchain]");
            continue;
        }
        if (!in_toolchain) continue;
        if (!std.mem.startsWith(u8, l, "mopm")) continue;
        var rest = std.mem.trimLeft(u8, l["mopm".len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len < 2 or rest[0] != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        if (end == 1) return null;
        return rest[1..end];
    }
    return null;
}

fn isToml(path: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(path), file_name);
}

/// The `mopm-toolchain.toml` files under `dir` (opened with `.iterate = true`),
/// sorted by path.
pub fn collect(alloc: Alloc, dir: std.fs.Dir) ![]const File {
    var out = std.ArrayList(File).empty;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |e| {
        switch (e.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!isToml(e.path)) continue;
        const text = dir.readFileAlloc(alloc, e.path, 1 << 20) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        const v = parseVersion(text);
        try out.append(alloc, .{
            .path = try alloc.dupe(u8, e.path),
            .version = if (v) |x| try alloc.dupe(u8, x) else null,
        });
    }
    std.mem.sort(File, out.items, {}, byPath);
    return out.toOwnedSlice(alloc);
}

fn byPath(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

pub const Result = struct {
    /// Files compared (the checked set).
    files: usize,
    /// Finding lines written to the report.
    findings: usize,
};

const Exception = struct { path: []const u8, seen: bool = false, line: usize };

/// Checks `found` against the exceptions `text` (named `name` in the report)
/// and the version the release flow builds with, `release`.
pub fn check(alloc: Alloc, name: []const u8, text: []const u8, release: []const u8, found: []const File, report: *std.ArrayList(u8)) !Result {
    const w = report.writer(alloc);
    var findings: usize = 0;
    var rows = std.ArrayList(Exception).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const l = std.mem.trimRight(u8, raw, "\r");
        if (l.len == 0 or l[0] == '#') continue;
        var f: [4][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, l, '\t');
        while (it.next()) |x| {
            if (n < f.len) f[n] = x;
            n += 1;
        }
        if (n != 3) {
            try w.print("{s}:{d}: a row has {d} fields, not 3 (except, path, reason)\n", .{ name, line_no, n });
            findings += 1;
            continue;
        }
        if (!std.mem.eql(u8, f[0], "except")) {
            try w.print("{s}:{d}: the kind is `{s}`, not `except`\n", .{ name, line_no, f[0] });
            findings += 1;
            continue;
        }
        if (std.mem.trim(u8, f[2], " ").len == 0) {
            try w.print("{s}:{d}: the reason is empty\n", .{ name, line_no });
            findings += 1;
            continue;
        }
        var dup = false;
        for (rows.items) |r| {
            if (std.mem.eql(u8, r.path, f[1])) dup = true;
        }
        if (dup) {
            try w.print("{s}:{d}: {s}: a second row for this file\n", .{ name, line_no, f[1] });
            findings += 1;
            continue;
        }
        try rows.append(alloc, .{ .path = f[1], .line = line_no });
    }

    var checked = std.ArrayList(File).empty;
    for (found) |file| {
        var excepted = false;
        for (rows.items) |*r| {
            if (std.mem.eql(u8, r.path, file.path)) {
                r.seen = true;
                excepted = true;
            }
        }
        if (!excepted) try checked.append(alloc, file);
    }
    for (rows.items) |r| {
        if (r.seen) continue;
        try w.print("{s}:{d}: {s}: no such {s} in the tree: remove the row\n", .{ name, r.line, r.path, file_name });
        findings += 1;
    }

    if (checked.items.len == 0) {
        try w.print("no {s} outside the exceptions: an empty set of packages checks nothing\n", .{file_name});
        findings += 1;
        return .{ .files = 0, .findings = findings };
    }

    // The reference: the version most packages name, a tie going to the
    // release flow's, then to the first path.
    var best: ?[]const u8 = null;
    var best_n: usize = 0;
    for (checked.items) |file| {
        const v = file.version orelse continue;
        var n: usize = 0;
        for (checked.items) |o| {
            if (o.version) |ov| {
                if (std.mem.eql(u8, ov, v)) n += 1;
            }
        }
        const wins = best == null or n > best_n or (n == best_n and std.mem.eql(u8, v, release) and !std.mem.eql(u8, best.?, release));
        if (wins) {
            best = v;
            best_n = n;
        }
    }
    for (checked.items) |file| {
        const v = file.version orelse {
            try w.print("{s}: no `mopm = \"<version>\"` under [toolchain]\n", .{file.path});
            findings += 1;
            continue;
        };
        if (!std.mem.eql(u8, v, best.?)) {
            try w.print("{s}: names mopm {s}, the other packages name {s}\n", .{ file.path, v, best.? });
            findings += 1;
        }
    }
    if (best) |b| {
        if (!std.mem.eql(u8, b, release)) {
            try w.print("the release flow builds with mopm {s} (release/readme_e2e/packages.bzl MOPM), the packages name {s}\n", .{ release, b });
            findings += 1;
        }
    }
    return .{ .files = checked.items.len, .findings = findings };
}

/// With no `expect`, passes when there is no finding. With `expect`
/// (substrings), passes only when there are findings and the report holds
/// every one of them: a planted defect the check must refuse.
pub const Verdict = struct { ok: bool, missing: ?[]const u8 = null };

pub fn verdict(r: Result, report: []const u8, expect: []const []const u8) Verdict {
    if (expect.len == 0) return .{ .ok = r.findings == 0 };
    for (expect) |e| {
        if (std.mem.indexOf(u8, report, e) == null) return .{ .ok = false, .missing = e };
    }
    return .{ .ok = r.findings > 0 };
}

pub const Rendered = struct { json: []const u8, message: []const u8 };

pub fn render(alloc: Alloc, name: []const u8, r: Result, v: Verdict, report: []const u8, expect: []const []const u8) !Rendered {
    var message = std.ArrayList(u8).empty;
    const mw = message.writer(alloc);
    if (expect.len > 0) {
        if (v.missing) |m| {
            try mw.print("one_mopm: the planted defect was not refused as expected: no finding holds `{s}`; {d} finding(s):\n{s}", .{ m, r.findings, report });
        } else if (!v.ok) {
            try mw.print("one_mopm: the planted defect was not refused: no finding over {d} file(s)", .{r.files});
        } else {
            try mw.print("one_mopm: the planted defect was refused as expected ({d} finding(s)):\n{s}", .{ r.findings, report });
        }
    } else if (r.findings > 0) {
        try mw.print("one_mopm: {d} finding(s) over {d} {s} file(s)\n{s}", .{ r.findings, r.files, file_name, report });
    } else {
        try mw.print("one_mopm: {d} {s} file(s) name one mopm version (exceptions in {s})", .{ r.files, file_name, name });
    }
    var json = std.Io.Writer.Allocating.init(alloc);
    const jw = &json.writer;
    try jw.print("{{\"version\": 1, \"data\": {{\"status\": \"{s}\", \"message\": ", .{if (v.ok) "success" else "failure"});
    try std.json.Stringify.encodeJsonString(message.items, .{}, jw);
    try jw.writeAll("}}\n");
    return .{ .json = try json.toOwnedSlice(), .message = try message.toOwnedSlice(alloc) };
}

// ---- tests -------------------------------------------------------------------

const testing = std.testing;

fn runCheck(a: Alloc, list: []const u8, release: []const u8, files: []const File) !struct { r: Result, report: []const u8 } {
    var report = std.ArrayList(u8).empty;
    const r = try check(a, "list.tsv", list, release, files, &report);
    return .{ .r = r, .report = report.items };
}

const fixture_row = "except\ttools/fx/mopm-toolchain.toml\tthe fixture pins the migration tool's default\n";

test "every package on one version passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), "", "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = "0.0.86" },
    });
    try testing.expectEqual(@as(usize, 0), r.r.findings);
    try testing.expectEqual(@as(usize, 2), r.r.files);
}

test "one package on another version is refused, naming it and both versions" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), "", "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = "0.0.73" },
        .{ .path = "src/c/mopm-toolchain.toml", .version = "0.0.86" },
    });
    try testing.expectEqual(@as(usize, 1), r.r.findings);
    try testing.expectEqualStrings("src/b/mopm-toolchain.toml: names mopm 0.0.73, the other packages name 0.0.86\n", r.report);
}

test "every package that differs is named" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), "", "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.85" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = "0.0.73" },
        .{ .path = "src/c/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/d/mopm-toolchain.toml", .version = "0.0.86" },
    });
    try testing.expectEqual(@as(usize, 2), r.r.findings);
    try testing.expect(std.mem.indexOf(u8, r.report, "src/a/mopm-toolchain.toml: names mopm 0.0.85") != null);
    try testing.expect(std.mem.indexOf(u8, r.report, "src/b/mopm-toolchain.toml: names mopm 0.0.73") != null);
}

test "an excepted fixture on another version passes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), fixture_row, "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "tools/fx/mopm-toolchain.toml", .version = "0.0.73" },
    });
    try testing.expectEqual(@as(usize, 0), r.r.findings);
    try testing.expectEqual(@as(usize, 1), r.r.files);
}

test "the same fixture without its row is refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), "", "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "tools/fx/mopm-toolchain.toml", .version = "0.0.73" },
    });
    try testing.expect(std.mem.indexOf(u8, r.report, "tools/fx/mopm-toolchain.toml: names mopm 0.0.73, the other packages name 0.0.86") != null);
}

test "an empty set is refused, not passed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try runCheck(a, "", "0.0.86", &.{});
    try testing.expectEqual(@as(usize, 1), r.r.findings);
    try testing.expect(std.mem.indexOf(u8, r.report, "an empty set of packages checks nothing") != null);
    // Only excepted files: still empty.
    r = try runCheck(a, fixture_row, "0.0.86", &.{.{ .path = "tools/fx/mopm-toolchain.toml", .version = "0.0.73" }});
    try testing.expect(std.mem.indexOf(u8, r.report, "an empty set of packages checks nothing") != null);
}

test "the release flow's version must be the packages'" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try runCheck(arena.allocator(), "", "0.0.90", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = "0.0.86" },
    });
    try testing.expectEqual(@as(usize, 1), r.r.findings);
    try testing.expect(std.mem.indexOf(u8, r.report, "the release flow builds with mopm 0.0.90 (release/readme_e2e/packages.bzl MOPM), the packages name 0.0.86") != null);
}

test "a file with no version, and malformed or stale exception rows, are findings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = try runCheck(a, "", "0.0.86", &.{
        .{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" },
        .{ .path = "src/b/mopm-toolchain.toml", .version = null },
    });
    try testing.expect(std.mem.indexOf(u8, r.report, "src/b/mopm-toolchain.toml: no `mopm = ") != null);
    const ok = [_]File{.{ .path = "src/a/mopm-toolchain.toml", .version = "0.0.86" }};
    const cases = [_]struct { row: []const u8, want: []const u8 }{
        .{ .row = "except\tx\n", .want = "a row has 2 fields, not 3" },
        .{ .row = "skip\tx\twhy\n", .want = "the kind is `skip`, not `except`" },
        .{ .row = "except\tx\t \n", .want = "the reason is empty" },
        .{ .row = "except\tx\ta\nexcept\tx\tb\n", .want = "list.tsv:2: x: a second row for this file" },
        .{ .row = "except\tgone/mopm-toolchain.toml\twhy\n", .want = "list.tsv:1: gone/mopm-toolchain.toml: no such mopm-toolchain.toml in the tree: remove the row" },
    };
    for (cases) |c| {
        r = try runCheck(a, c.row, "0.0.86", &ok);
        if (std.mem.indexOf(u8, r.report, c.want) == null) {
            std.debug.print("row {s}: report {s}\n", .{ c.row, r.report });
            return error.TestUnexpectedResult;
        }
    }
}

test "parseVersion reads the mopm key of [toolchain] only" {
    try testing.expectEqualStrings("0.0.86", parseVersion("[toolchain]\nmopm = \"0.0.86\"\nmojo = \"1.0.0\"\n").?);
    try testing.expectEqualStrings("0.0.86", parseVersion("# c\n[toolchain]\n  mopm=\"0.0.86\"  \n").?);
    try testing.expect(parseVersion("[toolchain]\nmojo = \"1.0.0\"\n") == null);
    try testing.expect(parseVersion("[other]\nmopm = \"0.0.1\"\n[toolchain]\nmojo = \"1\"\n") == null);
    try testing.expect(parseVersion("[toolchain]\nmopm = 86\n") == null);
    try testing.expect(parseVersion("[toolchain]\nmopm = \"\"\n") == null);
    try testing.expect(parseVersion("[toolchain]\nmopm_extra = \"0.0.1\"\n") == null);
}

test "the walk reads files of that name only, sorted, with their versions" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.makePath("src/b");
    try tmp.dir.makePath("src/a");
    try tmp.dir.writeFile(.{ .sub_path = "src/b/mopm-toolchain.toml", .data = "[toolchain]\nmopm = \"0.0.2\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/a/mopm-toolchain.toml", .data = "[toolchain]\nmojo = \"1\"\n" });
    try tmp.dir.writeFile(.{ .sub_path = "src/a/mopm.toml", .data = "[toolchain]\nmopm = \"0.0.9\"\n" });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try collect(arena.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("src/a/mopm-toolchain.toml", found[0].path);
    try testing.expect(found[0].version == null);
    try testing.expectEqualStrings("0.0.2", found[1].version.?);
}

test "the verdict of a planted case needs findings that hold every expected text" {
    const bad = Result{ .files = 1, .findings = 1 };
    try testing.expect(verdict(bad, "abc", &.{}).ok == false);
    try testing.expect(verdict(.{ .files = 1, .findings = 0 }, "", &.{}).ok);
    try testing.expect(verdict(bad, "abc def", &.{ "abc", "def" }).ok);
    const v = verdict(bad, "abc", &.{ "abc", "zzz" });
    try testing.expect(!v.ok);
    try testing.expectEqualStrings("zzz", v.missing.?);
    try testing.expect(!verdict(.{ .files = 1, .findings = 0 }, "", &.{"abc"}).ok);
}

test "render: the result file says success or failure, with the planted case's message" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ok = try render(a, "l", .{ .files = 3, .findings = 0 }, .{ .ok = true }, "", &.{});
    try testing.expect(std.mem.indexOf(u8, ok.json, "\"status\": \"success\"") != null);
    const red = try render(a, "l", .{ .files = 3, .findings = 1 }, .{ .ok = false }, "x: finding\n", &.{});
    try testing.expect(std.mem.indexOf(u8, red.json, "\"status\": \"failure\"") != null);
    try testing.expect(std.mem.indexOf(u8, red.message, "x: finding") != null);
    const planted = try render(a, "l", .{ .files = 3, .findings = 1 }, .{ .ok = true }, "x: finding\n", &.{"finding"});
    try testing.expect(std.mem.indexOf(u8, planted.message, "refused as expected") != null);
}
