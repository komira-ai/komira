//! The verdict's cases: the JSON read back, field by field.
const std = @import("std");
const report = @import("report.zig");
const t = std.testing;

test "the pull request number of a GitHub merge subject, and of nothing else" {
    try t.expectEqual(@as(?u64, 1337), report.prNumber("Merge pull request #1337 from org/branch"));
    try t.expectEqual(@as(?u64, 7), report.prNumber("Merge pull request #7"));
    try t.expectEqual(@as(?u64, null), report.prNumber("Merge pull request #"));
    try t.expectEqual(@as(?u64, null), report.prNumber("Merge pull request #12x from a/b"));
    try t.expectEqual(@as(?u64, null), report.prNumber("Merge branch 'main' into x"));
    try t.expectEqual(@as(?u64, null), report.prNumber("fix: see Merge pull request #5"));
    try t.expectEqual(@as(?u64, null), report.prNumber("Merge pull request #99999999999999999999999 from a/b"));
}

fn render(a: std.mem.Allocator, r: report.Report) !std.json.Value {
    var buf = std.Io.Writer.Allocating.init(a);
    try report.write(r, &buf.writer);
    return (try std.json.parseFromSlice(std.json.Value, a, buf.written(), .{})).value;
}

test "a culprit verdict: first_bad with its pr, no candidates, probes and failures in order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try render(a, .{
        .verdict = .culprit,
        .good = "g",
        .bad = "b",
        .targets = &.{"//t:a"},
        .first_bad = .{ .commit = "c5", .subject = "Merge pull request #105 from x/y", .pr = 105 },
        .last_good = "c4",
        .probes = &.{
            .{ .commit = "b", .role = .recheck, .outcome = .fail, .attempts = 1, .buck2_exit = 3, .failed_targets = &.{"//t:a"}, .seconds = 2 },
            .{ .commit = "c3", .role = .search, .outcome = .infra, .attempts = 2, .buck2_exit = null, .failed_targets = &.{}, .seconds = 1 },
        },
        .failures = &.{.{ .target = "//t:a", .excerpt = "line \"1\"\nline 2" }},
        .infra = &.{.{ .commit = "c3", .buck2_exit = null, .excerpt = "killed" }},
    });
    const o = v.object;
    try t.expectEqualStrings("culprit", o.get("verdict").?.string);
    try t.expectEqualStrings("c5", o.get("first_bad").?.object.get("commit").?.string);
    try t.expectEqual(@as(i64, 105), o.get("first_bad").?.object.get("pr").?.integer);
    try t.expectEqualStrings("c4", o.get("last_good").?.string);
    try t.expect(o.get("candidates") == null);
    const probes = o.get("probes").?.array.items;
    try t.expectEqual(@as(usize, 2), probes.len);
    try t.expectEqualStrings("recheck", probes[0].object.get("role").?.string);
    try t.expectEqualStrings("FAIL", probes[0].object.get("outcome").?.string);
    try t.expectEqualStrings("INFRA", probes[1].object.get("outcome").?.string);
    try t.expectEqual(@as(i64, 2), probes[1].object.get("attempts").?.integer);
    try t.expect(probes[1].object.get("buck2_exit").? == .null);
    try t.expectEqualStrings("line \"1\"\nline 2", o.get("failures").?.array.items[0].object.get("excerpt").?.string);
    try t.expectEqualStrings("c3", o.get("infra").?.array.items[0].object.get("commit").?.string);
}

test "an inconclusive verdict: first_bad is null and the candidates are listed" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try render(arena.allocator(), .{
        .verdict = .inconclusive,
        .good = "g",
        .bad = "b",
        .targets = &.{"//t:a"},
        .last_good = "c4",
        .candidates = &.{ "c5", "c6" },
        .probes = &.{},
        .failures = &.{},
        .infra = &.{},
    });
    try t.expect(v.object.get("first_bad").? == .null);
    try t.expectEqual(@as(usize, 2), v.object.get("candidates").?.array.items.len);
}

test "a pull request number is null in the JSON when the subject has none" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const v = try render(arena.allocator(), .{
        .verdict = .culprit,
        .good = "g",
        .bad = "b",
        .targets = &.{},
        .first_bad = .{ .commit = "b", .subject = "a direct push", .pr = null },
        .probes = &.{},
        .failures = &.{},
        .infra = &.{},
    });
    try t.expect(v.object.get("first_bad").?.object.get("pr").? == .null);
    try t.expect(v.object.get("last_good").? == .null);
}
