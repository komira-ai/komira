// Prints the answer of the module chain and the optimization mode it was
// built with: `42 Debug`.
const std = @import("std");
const builtin = @import("builtin");
const mid = @import("zr_mid");

pub fn main() !void {
    try std.io.getStdOut().writer().print("{d} {s}\n", .{ mid.answer(), @tagName(builtin.mode) });
}
