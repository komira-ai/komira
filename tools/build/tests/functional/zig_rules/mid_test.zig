// A zig_test given a module whose own import is another module.
const std = @import("std");
const mid = @import("zr_mid");

test "the answer reaches through two modules" {
    try std.testing.expectEqual(@as(u32, 42), mid.answer());
}
