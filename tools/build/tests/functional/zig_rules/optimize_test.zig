// zig_test(optimize = "ReleaseFast").
const std = @import("std");
const builtin = @import("builtin");

test "optimize reaches the compile" {
    try std.testing.expectEqual(std.builtin.OptimizeMode.ReleaseFast, builtin.mode);
}
