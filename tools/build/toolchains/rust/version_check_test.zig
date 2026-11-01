//! version_check's own checks, each the defect it would let through. Welded:
//! the checker is built only when these pass (BUCK).
const std = @import("std");
const vc = @import("version_check.zig");
const t = std.testing;

const pin = "rustc 1.99.0 (b940084d7 2026-09-28)";

test "the pinned line and its newline match" {
    try t.expect(vc.matches(pin ++ "\n", pin));
}

test "another release does not match" {
    try t.expect(!vc.matches("rustc 1.99.1 (58cf8f9c3 2026-10-13)\n", pin));
    try t.expect(!vc.matches("rustc 1.98.1 (aaaaaaaaa 2026-09-03)\n", pin));
}

test "a prefix or an extension of the pin does not match" {
    try t.expect(!vc.matches("rustc 1.99.0\n", pin));
    try t.expect(!vc.matches(pin ++ " extra\n", pin));
    try t.expect(!vc.matches("x" ++ pin ++ "\n", pin));
}

test "no newline, a second line, or nothing does not match" {
    try t.expect(!vc.matches(pin, pin));
    try t.expect(!vc.matches(pin ++ "\n\n", pin));
    try t.expect(!vc.matches(pin ++ "\nmore\n", pin));
    try t.expect(!vc.matches("", pin));
}

test "an empty pin matches nothing" {
    try t.expect(!vc.matches("\n", ""));
    try t.expect(!vc.matches("", ""));
}

test "the result is the validation JSON of a success" {
    const v = try std.json.parseFromSlice(std.json.Value, t.allocator, vc.result_json, .{});
    defer v.deinit();
    try t.expectEqualStrings("success", v.value.object.get("data").?.object.get("status").?.string);
    try t.expectEqual(@as(i64, 1), v.value.object.get("version").?.integer);
}
