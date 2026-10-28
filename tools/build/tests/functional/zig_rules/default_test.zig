// The defaults of zig_test, which are what it was before it had `target` and
// `optimize`: Debug, and the musl libc.
const std = @import("std");
const builtin = @import("builtin");

test "default mode and libc" {
    try std.testing.expectEqual(std.builtin.OptimizeMode.Debug, builtin.mode);
    try std.testing.expectEqual(std.Target.Abi.musl, builtin.abi);
}
