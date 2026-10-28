//! Which lines of a grounding file declare a constant, and in which form.

const std = @import("std");
const g = @import("grounding.zig");

fn expectTag(line: []const u8, id: []const u8) !void {
    const d = g.declaration(line) orelse return error.TestExpectedDeclaration;
    try std.testing.expectEqualStrings(id, d.id);
    try std.testing.expectEqual(g.Form.tag, d.form);
}

fn expectUnread(line: []const u8, id: []const u8) !void {
    const d = g.declaration(line) orelse return error.TestExpectedDeclaration;
    try std.testing.expectEqualStrings(id, d.id);
    try std.testing.expectEqual(g.Form.unread, d.form);
}

test "the two tag forms, with any blanks" {
    try expectTag("comptime PLAN_SCAN: UInt8 = 1", "PLAN_SCAN");
    try expectTag("comptime\tPLAN_SCAN :UInt8= 1", "PLAN_SCAN");
    try expectTag("comptime PLAN_UNTYPED = UInt8(16)", "PLAN_UNTYPED");
    try expectTag("comptime  JOIN_LEFT=UInt8 (2)", "JOIN_LEFT");
}

test "another type annotation is no tag and is not read" {
    try std.testing.expect(g.declaration("comptime PLAN_TAG_COUNT: Int = 15") == null);
    try std.testing.expect(g.declaration("comptime PLAN_WIDE: UInt8x = 1") == null);
    try std.testing.expect(g.declaration("comptime PLAN_PARAM: UInt8") == null);
}

test "any other form is unread, so a family constant written so is a finding" {
    try expectUnread("comptime PLAN_ODD = 17", "PLAN_ODD");
    try expectUnread("comptime PLAN_BARE", "PLAN_BARE");
    try expectUnread("comptime PLAN_CALL = make(1)", "PLAN_CALL");
}

test "only column 0 and only `comptime <identifier>`" {
    try std.testing.expect(g.declaration("    comptime PLAN_NESTED: UInt8 = 9") == null);
    try std.testing.expect(g.declaration("# comptime PLAN_RETIRED: UInt8 = 8") == null);
    try std.testing.expect(g.declaration("comptimePLAN_X: UInt8 = 1") == null);
    try std.testing.expect(g.declaration("comptime 1PLAN: UInt8 = 1") == null);
    try std.testing.expect(g.declaration("comptime") == null);
    try std.testing.expect(g.declaration("") == null);
}
