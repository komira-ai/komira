// zig_test(target = "x86_64-linux-gnu").
const std = @import("std");
const builtin = @import("builtin");

test "target reaches the compile" {
    try std.testing.expectEqual(std.Target.Abi.gnu, builtin.abi);
}
