//! The validation result: the JSON Buck2 reads, findings renamed from the
//! stage to the package, the message capped, a run that checked nothing a
//! failure.

const std = @import("std");
const lint = @import("lint.zig");

var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);

fn res(report: []const u8, checked: usize) ![]u8 {
    return lint.result(arena.allocator(), "k", "buck-out/s", "komira//pkg/", report, checked);
}

test "result: a pass names the count" {
    const j = try res("", 3);
    try std.testing.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"k: 3 checked\"}}\n", j);
}

test "result: findings fail, renamed, escaped, control bytes dropped" {
    const j = try res("buck-out/s/a.sh:1: \"x\"\tq\\z\x01\n", 1);
    try std.testing.expectEqualStrings("{\"version\": 1, \"data\": {\"status\": \"failure\", \"message\": \"k: 1 finding line(s)\\nkomira//pkg/a.sh:1: \\\"x\\\"\\tq\\\\z\\n\"}}\n", j);
}

test "result: checking nothing is a finding" {
    const j = try res("", 0);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"failure\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "k: checked nothing (no inputs, or no lines to check)") != null);
}

test "result: the message holds at most 200 lines and counts them all" {
    var report = std.ArrayList(u8).init(std.testing.allocator);
    defer report.deinit();
    for (0..250) |i| try report.writer().print("line {d}\n", .{i});
    const j = try res(report.items, 1);
    try std.testing.expect(std.mem.indexOf(u8, j, "k: 250 finding line(s)") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "line 199\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "line 200") == null);
}
