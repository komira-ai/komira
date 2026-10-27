//! The transition ledger (transition.bzl, built as `:transition`): the libraries
//! whose generated sources are not committed yet. It only shrinks, and ends empty;
//! this holds it well formed and its count equal to the number in the BUCK file,
//! so a line added or removed is a change to two files. The cases below run
//! `check` over made-up ledgers; the last test runs it over the real one, and
//! prints what is left to migrate.
const std = @import("std");
const t = std.testing;

pub const Problem = error{ Unsorted, Duplicate, NotALabel, GeneratedTarget, CountMismatch };

fn isLabel(l: []const u8) bool {
    const cell_end = std.mem.indexOf(u8, l, "//") orelse return false;
    if (cell_end == 0) return false;
    for (l[0..cell_end]) |c| if (!std.ascii.isLower(c)) return false;
    const colon = std.mem.lastIndexOfScalar(u8, l, ':') orelse return false;
    if (colon < cell_end + 2 or colon + 1 >= l.len) return false;
    for (l[colon + 1 ..]) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    return true;
}

/// Holds the ledger (`listing`: one label per line) to its rules and to `max`.
pub fn check(listing: []const u8, max: usize) Problem!void {
    var n: usize = 0;
    var prev: []const u8 = "";
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        if (!isLabel(l)) return error.NotALabel;
        // `<name>_gen` and `<name>_fresh` are made by the rule; the ledger names the library.
        if (std.mem.endsWith(u8, l, "_gen") or std.mem.endsWith(u8, l, "_fresh")) return error.GeneratedTarget;
        if (n > 0) {
            switch (std.mem.order(u8, prev, l)) {
                .lt => {},
                .eq => return error.Duplicate,
                .gt => return error.Unsorted,
            }
        }
        prev = l;
        n += 1;
    }
    if (n != max) return error.CountMismatch;
}

test "a sorted ledger of library labels, as long as its count, is well formed" {
    try check("komira//src/a:a\nkomira//src/b:b\ntests//functional/x:y\n", 3);
    try check("", 0);
}

test "a ledger out of order, with a repeat, or with something that is not a library label is refused" {
    try t.expectError(error.Unsorted, check("komira//src/b:b\nkomira//src/a:a\n", 2));
    try t.expectError(error.Duplicate, check("komira//src/a:a\nkomira//src/a:a\n", 2));
    try t.expectError(error.NotALabel, check("src/a:a\n", 1));
    try t.expectError(error.NotALabel, check("komira//src/a\n", 1));
    try t.expectError(error.NotALabel, check("komira//src/a:\n", 1));
    try t.expectError(error.NotALabel, check("komira//src/a:a b\n", 1));
    try t.expectError(error.GeneratedTarget, check("komira//src/a:a_gen\n", 1));
    try t.expectError(error.GeneratedTarget, check("komira//src/a:a_fresh\n", 1));
}

test "a line added to or removed from the ledger without the count in BUCK is refused" {
    try t.expectError(error.CountMismatch, check("komira//src/a:a\nkomira//src/b:b\n", 1));
    try t.expectError(error.CountMismatch, check("komira//src/a:a\n", 2));
    try t.expectError(error.CountMismatch, check("", 1));
}

test "the real ledger is well formed and as long as the count in BUCK; what it lists is still to migrate" {
    const work = try std.process.getEnvVarOwned(t.allocator, "KOMIRA_TEST_WORK");
    defer t.allocator.free(work);
    var dir = try std.fs.openDirAbsolute(work, .{});
    defer dir.close();
    const listing = try dir.readFileAlloc(t.allocator, "transition/unmigrated.txt", 1 << 20);
    defer t.allocator.free(listing);
    const max_text = try dir.readFileAlloc(t.allocator, "transition/max.txt", 64);
    defer t.allocator.free(max_text);
    const max = try std.fmt.parseInt(usize, std.mem.trim(u8, max_text, " \n"), 10);
    std.debug.print("transition ledger: {d} generated libraries still built from the generator:\n{s}", .{ max, listing });
    try check(listing, max);
}
