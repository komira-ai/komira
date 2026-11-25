//! The cases of //release:unpublished_cases, a `zig_test` run as a build action.
//!
//! Every Mojo library under src/ is either published (a member of PACKAGES in
//! release/readme_e2e/packages.bzl) or has a row in release/UNPUBLISHED.md that says why it is not, so
//! the ledger cannot go stale. A Mojo library is a directory `src/<name>` with a `BUCK` file and at
//! least one `.mojo` file outside its `tests/` (the paths come from `src_library_paths`, unpublished.bzl).
//! What it refuses, each with a message naming the library and the fix:
//!  - a library that is neither a member nor in the ledger;
//!  - a ledger row for a member (published: delete the row), or for a directory that is no library;
//!  - a member of PACKAGES that is no library (so a path list that reads as empty is never vacuous);
//!  - a row that does not parse: its name, its link `../src/<name>/`, a reason outside REASONS, an
//!    empty detail; rows out of sorted order or listed twice;
//!  - a row whose reason is "depends on an unpublished library" whose detail names no library in
//!    backticks (in such a detail only library names are in backticks), or names one that is published or is no library: that reason goes stale the day the
//!    dependency is published, and this is the day it is refused;
//!  - a count table that does not hold one row per reason with the number of rows that give it.
//! The cases take the real files and change one thing each, or take small texts, and expect the exact
//! message.

const std = @import("std");
const t = std.testing;
const Allocator = std.mem.Allocator;

const LEDGER = "release/UNPUBLISHED.md";
const PACKAGES = "PACKAGES in release/readme_e2e/packages.bzl";

/// The reasons a library is not published, as the ledger spells them.
const REASONS = [_][]const u8{
    "no README example",
    "test-only",
    "internal",
    "native dependency pending",
    "renamed or superseded",
    "depends on an unpublished library",
    "none",
};
const DEPENDS = "depends on an unpublished library";

/// The names `n` that have `src/<n>/BUCK` and a `src/<n>/...mojo` outside `src/<n>/tests/`, sorted.
fn libraries(ar: Allocator, paths: []const u8) ![]const []const u8 {
    var bucks = std.StringHashMap(void).init(ar);
    var mojo = std.StringHashMap(void).init(ar);
    var it = std.mem.splitScalar(u8, paths, '\n');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, p, "src/")) continue;
        const rest = p["src/".len..];
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse continue;
        const name = rest[0..slash];
        const inner = rest[slash + 1 ..];
        if (name.len == 0) continue;
        if (std.mem.eql(u8, inner, "BUCK")) try bucks.put(name, {});
        if (std.mem.endsWith(u8, inner, ".mojo") and !std.mem.startsWith(u8, inner, "tests/")) try mojo.put(name, {});
    }
    var out = std.ArrayList([]const u8){};
    var keys = bucks.keyIterator();
    while (keys.next()) |k| if (mojo.contains(k.*)) try out.append(ar, k.*);
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.toOwnedSlice(ar);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// The package names of `PACKAGES = { ... }` in packages.bzl.
fn members(ar: Allocator, bzl: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var inside = false;
    var it = std.mem.splitScalar(u8, bzl, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "PACKAGES = {")) {
            inside = true;
            continue;
        }
        if (!inside) continue;
        if (std.mem.startsWith(u8, line, "}")) break;
        const s = std.mem.trim(u8, line, " \t");
        if (s.len < 2 or s[0] != '"') continue;
        const end = std.mem.indexOfScalarPos(u8, s, 1, '"') orelse continue;
        try out.append(ar, s[1..end]);
    }
    return out.toOwnedSlice(ar);
}

const Row = struct { name: []const u8, reason: []const u8, detail: []const u8, line: usize };
const Count = struct { reason: []const u8, n: usize, line: usize };

const Ledger = struct { rows: []const Row, counts: []const Count };

const Parsed = union(enum) { ok: Ledger, refused: []const u8 };

/// The cells of a table line `| a | b | c |`, trimmed, or null when the line is no table row.
fn cells(ar: Allocator, line: []const u8) !?[]const []const u8 {
    const s = std.mem.trim(u8, line, " \t\r");
    if (s.len < 2 or s[0] != '|' or s[s.len - 1] != '|') return null;
    var out = std.ArrayList([]const u8){};
    var it = std.mem.splitScalar(u8, s[1 .. s.len - 1], '|');
    while (it.next()) |c| try out.append(ar, std.mem.trim(u8, c, " \t"));
    return try out.toOwnedSlice(ar);
}

fn isReason(s: []const u8) bool {
    for (REASONS) |r| if (std.mem.eql(u8, r, s)) return true;
    return false;
}

fn isNumber(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// The library rows (first cell a link `[`<name>`](../src/<name>/)`) and the count rows (first cell a
/// reason, second a number) of the ledger.
fn parse(ar: Allocator, md: []const u8) !Parsed {
    var rows = std.ArrayList(Row){};
    var counts = std.ArrayList(Count){};
    var it = std.mem.splitScalar(u8, md, '\n');
    var n: usize = 0;
    while (it.next()) |line| {
        n += 1;
        const cs = (try cells(ar, line)) orelse continue;
        if (cs.len == 2 and isReason(cs[0]) and isNumber(cs[1])) {
            try counts.append(ar, .{ .reason = cs[0], .n = try std.fmt.parseInt(usize, cs[1], 10), .line = n });
            continue;
        }
        if (cs.len == 0 or !std.mem.startsWith(u8, cs[0], "[`")) continue;
        if (cs.len != 3) return .{ .refused = try std.fmt.allocPrint(ar, "{s}:{d}: a library row has three cells (library, reason, detail), this one has {d} (a `|` in the detail splits it: write it another way)", .{ LEDGER, n, cs.len }) };
        const close = std.mem.indexOf(u8, cs[0], "`]") orelse
            return .{ .refused = try std.fmt.allocPrint(ar, "{s}:{d}: the library cell is not [`<name>`](../src/<name>/)", .{ LEDGER, n }) };
        const name = cs[0][2..close];
        const want = try std.fmt.allocPrint(ar, "[`{s}`](../src/{s}/)", .{ name, name });
        if (!std.mem.eql(u8, cs[0], want)) return .{ .refused = try std.fmt.allocPrint(ar, "{s}:{d}: the library cell of {s} is not {s}", .{ LEDGER, n, name, want }) };
        if (!isReason(cs[1])) return .{ .refused = try std.fmt.allocPrint(ar, "{s}:{d}: {s} gives the reason \"{s}\", which is not one of the reasons the ledger lists", .{ LEDGER, n, name, cs[1] }) };
        if (cs[2].len == 0) return .{ .refused = try std.fmt.allocPrint(ar, "{s}:{d}: {s} has no detail: say what the reason is, in this library", .{ LEDGER, n, name }) };
        try rows.append(ar, .{ .name = name, .reason = cs[1], .detail = cs[2], .line = n });
    }
    return .{ .ok = .{ .rows = try rows.toOwnedSlice(ar), .counts = try counts.toOwnedSlice(ar) } };
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |x| if (std.mem.eql(u8, x, name)) return true;
    return false;
}

fn rowOf(rows: []const Row, name: []const u8) ?Row {
    for (rows) |r| if (std.mem.eql(u8, r.name, name)) return r;
    return null;
}

/// The names in backticks of a detail cell.
fn ticked(ar: Allocator, detail: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8){};
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, detail, i, '`')) |open| {
        const close = std.mem.indexOfScalarPos(u8, detail, open + 1, '`') orelse break;
        try out.append(ar, detail[open + 1 .. close]);
        i = close + 1;
    }
    return out.toOwnedSlice(ar);
}

/// Null when every library is a member or has a well-formed row, and the ledger holds nothing else;
/// else the refusal.
fn check(ar: Allocator, paths: []const u8, bzl: []const u8, md: []const u8) !?[]const u8 {
    const libs = try libraries(ar, paths);
    const published = try members(ar, bzl);
    const ledger = switch (try parse(ar, md)) {
        .ok => |l| l,
        .refused => |why| return why,
    };
    const rows = ledger.rows;
    for (published) |name| {
        if (!contains(libs, name)) return try std.fmt.allocPrint(ar, "{s} is in {s} and src/{s} is no Mojo library (no BUCK, or no .mojo outside tests/)", .{ name, PACKAGES, name });
    }
    for (rows, 0..) |r, i| {
        if (i > 0) {
            const prev = rows[i - 1].name;
            if (std.mem.eql(u8, prev, r.name)) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} is listed twice", .{ LEDGER, r.line, r.name });
            if (std.mem.order(u8, prev, r.name) != .lt) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} is not in sorted order (it follows {s})", .{ LEDGER, r.line, r.name, prev });
        }
        if (contains(published, r.name)) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} is published (it is in {s}): delete its row", .{ LEDGER, r.line, r.name, PACKAGES });
        if (!contains(libs, r.name)) return try std.fmt.allocPrint(ar, "{s}:{d}: src/{s} is no Mojo library (no BUCK, or no .mojo outside tests/): delete its row", .{ LEDGER, r.line, r.name });
    }
    for (libs) |name| {
        if (!contains(published, name) and rowOf(rows, name) == null) return try std.fmt.allocPrint(
            ar,
            "src/{s} is a Mojo library that is neither in {s} nor in {s}: publish it, or add its row with the reason it is not published",
            .{ name, PACKAGES, LEDGER },
        );
    }
    for (rows) |r| {
        if (!std.mem.eql(u8, r.reason, DEPENDS)) continue;
        const deps = try ticked(ar, r.detail);
        if (deps.len == 0) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} says it depends on an unpublished library and names none in backticks", .{ LEDGER, r.line, r.name });
        for (deps) |d| {
            if (contains(published, d)) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} names `{s}` as an unpublished dependency, and {s} is published: drop it from the detail, and give the reason that is left", .{ LEDGER, r.line, r.name, d, d });
            if (rowOf(rows, d) == null) return try std.fmt.allocPrint(ar, "{s}:{d}: {s} names `{s}` as an unpublished dependency, and the ledger has no row for {s}", .{ LEDGER, r.line, r.name, d, d });
        }
    }
    for (REASONS) |reason| {
        var have: usize = 0;
        for (rows) |r| {
            if (std.mem.eql(u8, r.reason, reason)) have += 1;
        }
        var found: ?Count = null;
        for (ledger.counts) |c| {
            if (!std.mem.eql(u8, c.reason, reason)) continue;
            if (found != null) return try std.fmt.allocPrint(ar, "{s}:{d}: the count of \"{s}\" is given twice", .{ LEDGER, c.line, reason });
            found = c;
        }
        const c = found orelse return try std.fmt.allocPrint(ar, "{s}: the count table has no row for \"{s}\" ({d} rows give it)", .{ LEDGER, reason, have });
        if (c.n != have) return try std.fmt.allocPrint(ar, "{s}:{d}: the count of \"{s}\" says {d}, and {d} rows give that reason", .{ LEDGER, c.line, reason, c.n, have });
    }
    return null;
}

// ---- the cases ----------------------------------------------------------------

fn read(ar: Allocator, name: []const u8) ![]const u8 {
    const work = try std.process.getEnvVarOwned(ar, "KOMIRA_TEST_WORK");
    return std.fs.cwd().readFileAlloc(ar, try std.fs.path.join(ar, &.{ work, name }), 64 << 20);
}

const Real = struct { paths: []const u8, bzl: []const u8, md: []const u8 };

fn real(ar: Allocator) !Real {
    return .{
        .paths = try read(ar, "src_library_paths.txt"),
        .bzl = try read(ar, "packages.bzl"),
        .md = try read(ar, "UNPUBLISHED.md"),
    };
}

fn expectRefusal(ar: Allocator, paths: []const u8, bzl: []const u8, md: []const u8, want: []const u8) !void {
    const got = (try check(ar, paths, bzl, md)) orelse {
        std.debug.print("accepted; wanted the refusal: {s}\n", .{want});
        return error.Accepted;
    };
    try t.expectEqualStrings(want, got);
}

/// `s` with its one occurrence of `from` replaced by `to`; fails the case when `from` is absent.
fn edit(ar: Allocator, s: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, s, from));
    return std.mem.replaceOwned(u8, ar, s, from, to);
}

/// The ledger line of `name`, with its newline.
fn lineOf(ar: Allocator, md: []const u8, name: []const u8) ![]const u8 {
    const start = std.mem.indexOf(u8, md, try std.fmt.allocPrint(ar, "| [`{s}`]", .{name})) orelse return error.NoRow;
    const end = std.mem.indexOfScalarPos(u8, md, start, '\n') orelse return error.NoRow;
    return md[start .. end + 1];
}

/// The 1-based line number of the ledger row of `name`.
fn lineNo(ar: Allocator, md: []const u8, name: []const u8) !usize {
    const start = std.mem.indexOf(u8, md, try std.fmt.allocPrint(ar, "| [`{s}`]", .{name})) orelse return error.NoRow;
    return std.mem.count(u8, md[0..start], "\n") + 1;
}

test "every Mojo library under src/ is published or in the ledger (the real files)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    if (try check(ar, r.paths, r.bzl, r.md)) |why| {
        std.debug.print("{s}\n", .{why});
        return error.Refused;
    }
    // The real tree is not vacuous: it has libraries, members and rows.
    try t.expect((try libraries(ar, r.paths)).len > 0);
    try t.expect((try members(ar, r.bzl)).len > 0);
    try t.expect((try parse(ar, r.md)).ok.rows.len > 0);
}

test "a library whose row is deleted is refused, naming it and the fix" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    const first = (try parse(ar, r.md)).ok.rows[0];
    const dropped = try edit(ar, r.md, try lineOf(ar, r.md, first.name), "");
    // Its count no longer matches either, but the missing row is said first.
    try expectRefusal(ar, r.paths, r.bzl, dropped, try std.fmt.allocPrint(
        ar,
        "src/{s} is a Mojo library that is neither in PACKAGES in release/readme_e2e/packages.bzl nor in release/UNPUBLISHED.md: publish it, or add its row with the reason it is not published",
        .{first.name},
    ));
}

test "a new library directory with no row is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    const paths = try std.mem.concat(ar, u8, &.{ r.paths, "src/zz_new_lib/BUCK\nsrc/zz_new_lib/zz_new_lib.mojo\n" });
    try expectRefusal(ar, paths, r.bzl, r.md, "src/zz_new_lib is a Mojo library that is neither in PACKAGES in release/readme_e2e/packages.bzl nor in release/UNPUBLISHED.md: publish it, or add its row with the reason it is not published");
}

test "a library published while its row stays is refused: delete the row" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    const first = (try parse(ar, r.md)).ok.rows[0];
    const bzl = try edit(ar, r.bzl, "PACKAGES = {\n", try std.fmt.allocPrint(ar, "PACKAGES = {{\n    \"{s}\": \"0.1.0\",\n", .{first.name}));
    try expectRefusal(ar, r.paths, bzl, r.md, try std.fmt.allocPrint(
        ar,
        "release/UNPUBLISHED.md:{d}: {s} is published (it is in PACKAGES in release/readme_e2e/packages.bzl): delete its row",
        .{ try lineNo(ar, r.md, first.name), first.name },
    ));
}

test "a row whose library directory is gone is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const paths = "src/a_lib/BUCK\nsrc/a_lib/a.mojo\n";
    const bzl = "PACKAGES = {\n}\n";
    const md = "| [`a_lib`](../src/a_lib/) | none | every import is published |\n" ++
        "| [`b_gone`](../src/b_gone/) | none | x |\n" ++ comptime countTable("none", 2);
    try expectRefusal(ar, paths, bzl, md, "release/UNPUBLISHED.md:2: src/b_gone is no Mojo library (no BUCK, or no .mojo outside tests/): delete its row");
}

/// A count table giving `n` to `reason` and 0 to every other reason.
fn countTable(comptime reason: []const u8, comptime n: usize) []const u8 {
    comptime var s: []const u8 = "\n| Reason | Libraries |\n|---|---|\n";
    inline for (REASONS) |r| {
        s = s ++ "| " ++ r ++ " | " ++ (if (std.mem.eql(u8, r, reason)) std.fmt.comptimePrint("{d}", .{n}) else "0") ++ " |\n";
    }
    return s;
}

test "what makes a directory a Mojo library: a BUCK and a .mojo outside tests/, directly under src/" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const paths =
        \\src/both/BUCK
        \\src/both/src/both/x.mojo
        \\src/no_buck/x.mojo
        \\src/no_mojo/BUCK
        \\src/no_mojo/README.md
        \\src/tests_only/BUCK
        \\src/tests_only/tests/test_x.mojo
        \\src/tests/e2e/deep/BUCK
        \\src/tests/e2e/deep/deep.mojo
        \\docs/x.mojo
        \\
    ;
    const libs = try libraries(ar, paths);
    try t.expectEqual(@as(usize, 1), libs.len);
    try t.expectEqualStrings("both", libs[0]);
}

test "a member of PACKAGES that is no library is refused, so an empty path list is never vacuous" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    const first = (try members(ar, r.bzl))[0];
    try expectRefusal(ar, "", r.bzl, r.md, try std.fmt.allocPrint(
        ar,
        "{s} is in PACKAGES in release/readme_e2e/packages.bzl and src/{s} is no Mojo library (no BUCK, or no .mojo outside tests/)",
        .{ first, first },
    ));
}

test "rows out of order, listed twice, or that do not parse are refused, naming the line" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const paths = "src/a/BUCK\nsrc/a/a.mojo\nsrc/b/BUCK\nsrc/b/b.mojo\n";
    const bzl = "PACKAGES = {\n}\n";
    const a = "| [`a`](../src/a/) | none | d |\n";
    const b = "| [`b`](../src/b/) | none | d |\n";
    try t.expect((try check(ar, paths, bzl, a ++ b ++ comptime countTable("none", 2))) == null);
    try expectRefusal(ar, paths, bzl, b ++ a ++ comptime countTable("none", 2), "release/UNPUBLISHED.md:2: a is not in sorted order (it follows b)");
    try expectRefusal(ar, paths, bzl, a ++ a ++ b ++ comptime countTable("none", 3), "release/UNPUBLISHED.md:2: a is listed twice");
    try expectRefusal(ar, paths, bzl, a ++ "| [`b`](../src/c/) | none | d |\n", "release/UNPUBLISHED.md:2: the library cell of b is not [`b`](../src/b/)");
    try expectRefusal(ar, paths, bzl, a ++ "| [`b`](../src/b/) | lazy | d |\n", "release/UNPUBLISHED.md:2: b gives the reason \"lazy\", which is not one of the reasons the ledger lists");
    try expectRefusal(ar, paths, bzl, a ++ "| [`b`](../src/b/) | none | |\n", "release/UNPUBLISHED.md:2: b has no detail: say what the reason is, in this library");
    try expectRefusal(ar, paths, bzl, a ++ "| [`b`](../src/b/) | none |\n", "release/UNPUBLISHED.md:2: a library row has three cells (library, reason, detail), this one has 2 (a `|` in the detail splits it: write it another way)");
    try expectRefusal(ar, paths, bzl, a ++ "| [`b`](../src/b/) | none | x | y |\n", "release/UNPUBLISHED.md:2: a library row has three cells (library, reason, detail), this one has 4 (a `|` in the detail splits it: write it another way)");
    // A row ending in a carriage return or trailing blanks reads as the same row.
    try t.expect((try check(ar, paths, bzl, "| [`a`](../src/a/) | none | d |  \r\n" ++ b ++ comptime countTable("none", 2))) == null);
    try expectRefusal(ar, paths, bzl, a ++ "| [`b](../src/b/) | none | d |\n", "release/UNPUBLISHED.md:2: the library cell is not [`<name>`](../src/<name>/)");
}

test "an unpublished-dependency reason must name unpublished libraries, so publishing the dependency makes it stale and refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const paths = "src/a/BUCK\nsrc/a/a.mojo\nsrc/b/BUCK\nsrc/b/b.mojo\nsrc/p/BUCK\nsrc/p/p.mojo\n";
    const bzl = "PACKAGES = {\n    \"p\": \"0.1.0\",\n}\n";
    const b = "| [`b`](../src/b/) | no README example | its README has no example |\n";
    const tail = "\n| no README example | 1 |\n| test-only | 0 |\n| internal | 0 |\n| native dependency pending | 0 |\n| renamed or superseded | 0 |\n| depends on an unpublished library | 1 |\n| none | 0 |\n";
    try t.expect((try check(ar, paths, bzl, "| [`a`](../src/a/) | depends on an unpublished library | imports `b` |\n" ++ b ++ tail)) == null);
    try expectRefusal(ar, paths, bzl, "| [`a`](../src/a/) | depends on an unpublished library | imports b |\n" ++ b ++ tail, "release/UNPUBLISHED.md:1: a says it depends on an unpublished library and names none in backticks");
    try expectRefusal(ar, paths, bzl, "| [`a`](../src/a/) | depends on an unpublished library | imports `b`, `p` |\n" ++ b ++ tail, "release/UNPUBLISHED.md:1: a names `p` as an unpublished dependency, and p is published: drop it from the detail, and give the reason that is left");
    try expectRefusal(ar, paths, bzl, "| [`a`](../src/a/) | depends on an unpublished library | imports `zz` |\n" ++ b ++ tail, "release/UNPUBLISHED.md:1: a names `zz` as an unpublished dependency, and the ledger has no row for zz");
}

test "the count table must give every reason the number of rows that give it" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const paths = "src/a/BUCK\nsrc/a/a.mojo\n";
    const bzl = "PACKAGES = {\n}\n";
    const a = "| [`a`](../src/a/) | none | d |\n";
    try t.expect((try check(ar, paths, bzl, a ++ comptime countTable("none", 1))) == null);
    try expectRefusal(ar, paths, bzl, a ++ comptime countTable("none", 2), "release/UNPUBLISHED.md:11: the count of \"none\" says 2, and 1 rows give that reason");
    try expectRefusal(ar, paths, bzl, a ++ comptime countTable("test-only", 1), "release/UNPUBLISHED.md:6: the count of \"test-only\" says 1, and 0 rows give that reason");
    const no_internal = try edit(ar, a ++ comptime countTable("none", 1), "| internal | 0 |\n", "");
    try expectRefusal(ar, paths, bzl, no_internal, "release/UNPUBLISHED.md: the count table has no row for \"internal\" (0 rows give it)");
    try expectRefusal(ar, paths, bzl, a ++ comptime countTable("none", 1) ++ "| none | 1 |\n", "release/UNPUBLISHED.md:12: the count of \"none\" is given twice");
}

test "the real ledger's counts are refused when one is changed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ar = arena.allocator();
    const r = try real(ar);
    const l = (try parse(ar, r.md)).ok;
    const c = l.counts[0];
    const from = try std.fmt.allocPrint(ar, "| {s} | {d} |\n", .{ c.reason, c.n });
    const to = try std.fmt.allocPrint(ar, "| {s} | {d} |\n", .{ c.reason, c.n + 1 });
    try expectRefusal(ar, r.paths, r.bzl, try edit(ar, r.md, from, to), try std.fmt.allocPrint(
        ar,
        "release/UNPUBLISHED.md:{d}: the count of \"{s}\" says {d}, and {d} rows give that reason",
        .{ c.line, c.reason, c.n + 1, c.n },
    ));
}
