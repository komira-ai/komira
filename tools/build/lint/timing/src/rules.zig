//! The wall-clock ledger: which Zig files read a clock or sleep, counted
//! against a TSV of rows, so that what remains of the tree's real time is
//! written down and the list only shrinks.
//!
//! A test never asserts on elapsed time and never waits on a deadline that
//! fails it (the gate's tests move the clock they run on; see
//! tools/build/run/testkit.zig). The ways a Zig file reads real time or waits
//! for it are scanned for (`tokens`): a `use` row (path, token, count, reason)
//! says how many sites of the token the file has. More than the row says is a
//! new use of real time; fewer is a row to lower; none is a row to remove; a
//! file with sites and no row is a finding. Comment lines and the text after
//! a `//` outside a string are not read.
//!
//! The list is a TSV: `#` comment lines, blank lines, and rows of exactly five
//! tab-separated fields: `use`, path, token, count (a positive integer) and a
//! reason (not empty). What review holds, not this tool: a row is never added
//! for a new site in a test without a reason review accepts (a fixture that
//! must block until it is killed is one; an assertion on elapsed time is not).

const std = @import("std");
const Alloc = std.mem.Allocator;

/// The spellings scanned for, as (name, text). Built by concatenation so that
/// this file does not hold them itself.
pub const tokens = [_]struct { name: []const u8, text: []const u8 }{
    .{ .name = "Instant", .text = "std.time." ++ "Instant" },
    .{ .name = "milliTimestamp", .text = "milli" ++ "Timestamp(" },
    .{ .name = "nanoTimestamp", .text = "nano" ++ "Timestamp(" },
    .{ .name = "timestamp", .text = "std.time." ++ "timestamp(" },
    .{ .name = "Thread.sleep", .text = "Thread." ++ "sleep(" },
    .{ .name = "sleepMs", .text = "sleep" ++ "Ms(" },
    .{ .name = "nanosleep", .text = "nano" ++ "sleep(" },
    .{ .name = "monotonicMs", .text = "monotonic" ++ "Ms(" },
};

pub const Counts = [tokens.len]usize;

pub fn total(c: Counts) usize {
    var n: usize = 0;
    for (c) |x| n += x;
    return n;
}

/// `line` without a comment: the text up to a `//` that is outside a string.
fn code(line: []const u8) []const u8 {
    var in_str = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const ch = line[i];
        if (in_str) {
            if (ch == '\\') {
                i += 1;
            } else if (ch == '"') in_str = false;
        } else if (ch == '"') {
            in_str = true;
        } else if (ch == '/' and i + 1 < line.len and line[i + 1] == '/') return line[0..i];
    }
    return line;
}

/// The sites of each token in the Zig source `text`.
pub fn scan(text: []const u8) Counts {
    var counts = [_]usize{0} ** tokens.len;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        const c = code(l);
        for (tokens, 0..) |t, k| {
            var from: usize = 0;
            while (std.mem.indexOfPos(u8, c, from, t.text)) |at| {
                counts[k] += 1;
                from = at + t.text.len;
            }
        }
    }
    return counts;
}

pub const File = struct { path: []const u8, counts: Counts };

pub fn isZig(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".zig");
}

/// The Zig files under `dir` (opened with `.iterate = true`) with at least one
/// site, sorted by path.
pub fn collect(alloc: Alloc, dir: std.fs.Dir) ![]const File {
    var out = std.ArrayList(File).empty;
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    while (try walker.next()) |e| {
        switch (e.kind) {
            .file, .sym_link => {},
            else => continue,
        }
        if (!isZig(e.path)) continue;
        const text = dir.readFileAlloc(alloc, e.path, 1 << 24) catch |err| switch (err) {
            error.IsDir => continue,
            else => return err,
        };
        const counts = scan(text);
        if (total(counts) > 0) try out.append(alloc, .{ .path = try alloc.dupe(u8, e.path), .counts = counts });
    }
    std.mem.sort(File, out.items, {}, byPath);
    return out.toOwnedSlice(alloc);
}

fn byPath(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

pub const Result = struct {
    /// Files with at least one site.
    files: usize,
    /// Finding lines written to the report.
    findings: usize,
};

const Row = struct { line: usize, path: []const u8, token: usize, count: usize, seen: bool = false };

fn tokenIndex(name: []const u8) ?usize {
    for (tokens, 0..) |t, k| {
        if (std.mem.eql(u8, t.name, name)) return k;
    }
    return null;
}

/// Checks `found` against the list `text` (named `name` in the report).
pub fn check(alloc: Alloc, name: []const u8, text: []const u8, found: []const File, report: *std.ArrayList(u8)) !Result {
    const w = report.writer(alloc);
    var findings: usize = 0;
    var rows = std.ArrayList(Row).empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const l = std.mem.trimRight(u8, raw, "\r");
        if (l.len == 0 or l[0] == '#') continue;
        var f: [6][]const u8 = undefined;
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, l, '\t');
        while (it.next()) |x| {
            if (n < f.len) f[n] = x;
            n += 1;
        }
        if (n != 5) {
            try w.print("{s}:{d}: a row has {d} fields, not 5 (use, path, token, count, reason)\n", .{ name, line_no, n });
            findings += 1;
            continue;
        }
        if (!std.mem.eql(u8, f[0], "use")) {
            try w.print("{s}:{d}: the kind is `{s}`, not `use`\n", .{ name, line_no, f[0] });
            findings += 1;
            continue;
        }
        const tk = tokenIndex(f[2]) orelse {
            try w.print("{s}:{d}: `{s}` is not a token this list counts\n", .{ name, line_no, f[2] });
            findings += 1;
            continue;
        };
        const count = std.fmt.parseInt(usize, f[3], 10) catch 0;
        if (count == 0) {
            try w.print("{s}:{d}: the count `{s}` is not a positive integer\n", .{ name, line_no, f[3] });
            findings += 1;
            continue;
        }
        if (std.mem.trim(u8, f[4], " ").len == 0) {
            try w.print("{s}:{d}: the reason is empty\n", .{ name, line_no });
            findings += 1;
            continue;
        }
        var dup = false;
        for (rows.items) |r| {
            if (r.token == tk and std.mem.eql(u8, r.path, f[1])) dup = true;
        }
        if (dup) {
            try w.print("{s}:{d}: {s}: a second `{s}` row for this file\n", .{ name, line_no, f[1], f[2] });
            findings += 1;
            continue;
        }
        try rows.append(alloc, .{ .line = line_no, .path = f[1], .token = tk, .count = count });
    }

    for (found) |file| {
        for (file.counts, 0..) |n, k| {
            if (n == 0) continue;
            var hit: ?*Row = null;
            for (rows.items) |*r| {
                if (r.token == k and std.mem.eql(u8, r.path, file.path)) hit = r;
            }
            const row = hit orelse {
                try w.print("{s}: {d} `{s}` site(s) with no row in {s}: a test waits on a clock it moves itself, or on the process or event it waits for, never on real time; or add a row review accepts\n", .{ file.path, n, tokens[k].name, name });
                findings += 1;
                continue;
            };
            row.seen = true;
            if (n > row.count) {
                try w.print("{s}:{d}: {s}: {d} `{s}` site(s), the row says {d}: a new use of real time\n", .{ name, row.line, file.path, n, tokens[k].name, row.count });
                findings += 1;
            } else if (n < row.count) {
                try w.print("{s}:{d}: {s}: {d} `{s}` site(s) remain, the row says {d}: lower the row\n", .{ name, row.line, file.path, n, tokens[k].name, row.count });
                findings += 1;
            }
        }
    }
    for (rows.items) |r| {
        if (r.seen) continue;
        try w.print("{s}:{d}: {s}: no `{s}` site in this file: remove the row\n", .{ name, r.line, r.path, tokens[r.token].name });
        findings += 1;
    }
    return .{ .files = found.len, .findings = findings };
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
            try mw.print("timing: the planted defect was not refused as expected: no finding holds `{s}`; {d} finding(s):\n{s}", .{ m, r.findings, report });
        } else if (!v.ok) {
            try mw.print("timing: the planted defect was not refused: no finding over {d} file(s)", .{r.files});
        } else {
            try mw.print("timing: the planted defect was refused as expected ({d} finding(s)):\n{s}", .{ r.findings, report });
        }
    } else if (r.findings > 0) {
        try mw.print("timing: {d} finding(s) over {d} Zig file(s) that read real time\n{s}", .{ r.findings, r.files, report });
    } else {
        try mw.print("timing: {d} Zig file(s) that read real time checked against {s}", .{ r.files, name });
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

fn src(comptime tok: []const u8) []const u8 {
    return "fn f() void {\n    " ++ tok ++ ";\n}\n";
}

test "each spelling is counted once per site, and the right token" {
    const sleep_call = src("sleep" ++ "Ms(5)");
    const c = scan(sleep_call);
    try testing.expectEqual(@as(usize, 1), c[tokenIndex("sleepMs").?]);
    try testing.expectEqual(@as(usize, 1), total(c));
    const two = scan("a(" ++ "std.time." ++ "Instant.now());\nb(" ++ "std.time." ++ "Instant.now());\n");
    try testing.expectEqual(@as(usize, 2), two[tokenIndex("Instant").?]);
    const t = scan("x(milli" ++ "Timestamp()); y(nano" ++ "Timestamp()); z(std.Thread." ++ "sleep(1)); w(posix.nano" ++ "sleep(1, 0)); v(sys.monotonic" ++ "Ms());\n");
    try testing.expectEqual(@as(usize, 5), total(t));
    for (t[0..]) |n| try testing.expect(n <= 1);
}

test "comments and the text after a // outside a string are not read; a // inside a string is" {
    const sp = "sleep" ++ "Ms(";
    try testing.expectEqual(@as(usize, 0), total(scan("// " ++ sp ++ "1)\n")));
    try testing.expectEqual(@as(usize, 0), total(scan("    /// uses " ++ sp ++ "1)\n")));
    try testing.expectEqual(@as(usize, 0), total(scan("f(); // then " ++ sp ++ "1)\n")));
    try testing.expectEqual(@as(usize, 1), total(scan("f(\"http://x\"); " ++ sp ++ "1);\n")));
    try testing.expectEqual(@as(usize, 1), total(scan("f(\"a\\\"//\"); " ++ sp ++ "1);\n")));
}

fn runCheck(a: Alloc, list: []const u8, files: []const File) !struct { r: Result, report: []const u8 } {
    var report = std.ArrayList(u8).empty;
    const r = try check(a, "list.tsv", list, files, &report);
    return .{ .r = r, .report = report.items };
}

fn one(token: []const u8, n: usize) Counts {
    var c = [_]usize{0} ** tokens.len;
    c[tokenIndex(token).?] = n;
    return c;
}

test "a site with no row, a grown count, a shrunk count and a stale row are each a finding" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const row = "use\tx/a_test.zig\tsleepMs\t2\tthe fixture blocks until it is killed\n";
    // As listed: clean.
    var r = try runCheck(a, row, &.{.{ .path = "x/a_test.zig", .counts = one("sleepMs", 2) }});
    try testing.expectEqual(@as(usize, 0), r.r.findings);
    // No row for the file.
    r = try runCheck(a, row, &.{
        .{ .path = "x/a_test.zig", .counts = one("sleepMs", 2) },
        .{ .path = "y/b_test.zig", .counts = one("Instant", 1) },
    });
    try testing.expectEqual(@as(usize, 1), r.r.findings);
    try testing.expect(std.mem.indexOf(u8, r.report, "y/b_test.zig: 1 `Instant` site(s) with no row in list.tsv") != null);
    // Grown.
    r = try runCheck(a, row, &.{.{ .path = "x/a_test.zig", .counts = one("sleepMs", 3) }});
    try testing.expect(std.mem.indexOf(u8, r.report, "list.tsv:1: x/a_test.zig: 3 `sleepMs` site(s), the row says 2: a new use of real time") != null);
    // Shrunk.
    r = try runCheck(a, row, &.{.{ .path = "x/a_test.zig", .counts = one("sleepMs", 1) }});
    try testing.expect(std.mem.indexOf(u8, r.report, "1 `sleepMs` site(s) remain, the row says 2: lower the row") != null);
    // Ported: the row stays.
    r = try runCheck(a, row, &.{});
    try testing.expect(std.mem.indexOf(u8, r.report, "list.tsv:1: x/a_test.zig: no `sleepMs` site in this file: remove the row") != null);
    // A second token in a listed file is its own site.
    r = try runCheck(a, row, &.{.{ .path = "x/a_test.zig", .counts = blk: {
        var c = one("sleepMs", 2);
        c[tokenIndex("Instant").?] = 1;
        break :blk c;
    } }});
    try testing.expectEqual(@as(usize, 1), r.r.findings);
}

test "malformed rows are findings" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { row: []const u8, want: []const u8 }{
        .{ .row = "use\tx\tsleepMs\t1\n", .want = "a row has 4 fields, not 5" },
        .{ .row = "script\tx\tsleepMs\t1\twhy\n", .want = "the kind is `script`, not `use`" },
        .{ .row = "use\tx\tsleep\t1\twhy\n", .want = "`sleep` is not a token this list counts" },
        .{ .row = "use\tx\tsleepMs\t0\twhy\n", .want = "the count `0` is not a positive integer" },
        .{ .row = "use\tx\tsleepMs\tmany\twhy\n", .want = "the count `many` is not a positive integer" },
        .{ .row = "use\tx\tsleepMs\t1\t \n", .want = "the reason is empty" },
        .{ .row = "use\tx\tsleepMs\t1\ta\nuse\tx\tsleepMs\t1\tb\n", .want = "list.tsv:2: x: a second `sleepMs` row for this file" },
    };
    for (cases) |c| {
        const r = try runCheck(a, c.row, &.{});
        if (std.mem.indexOf(u8, r.report, c.want) == null) {
            std.debug.print("row {s}: report {s}\n", .{ c.row, r.report });
            return error.TestUnexpectedResult;
        }
    }
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

test "the walk reads Zig files only, with sites only, sorted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const sp = "sleep" ++ "Ms(1);\n";
    try tmp.dir.makePath("b");
    try tmp.dir.writeFile(.{ .sub_path = "b/z.zig", .data = sp });
    try tmp.dir.writeFile(.{ .sub_path = "a.zig", .data = sp ++ sp });
    try tmp.dir.writeFile(.{ .sub_path = "none.zig", .data = "const x = 1;\n" });
    try tmp.dir.writeFile(.{ .sub_path = "note.md", .data = sp });
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const found = try collect(arena.allocator(), tmp.dir);
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("a.zig", found[0].path);
    try testing.expectEqual(@as(usize, 2), found[0].counts[tokenIndex("sleepMs").?]);
    try testing.expectEqualStrings("b/z.zig", found[1].path);
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
