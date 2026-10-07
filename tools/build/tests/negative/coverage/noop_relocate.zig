//! A planted defect (test 41): a debug_relocate that rewrites nothing and
//! reports one occurrence of every directory, as if it had. cov_zig accepts
//! its counts, so only mojo_wrapper.sh's own check (exit 4, the output holds
//! the action's working directory) can stop the build.
//!
//! usage: noop_relocate <file> <dir>...

const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const argv = try std.process.argsAlloc(arena.allocator());
    const out = std.io.getStdOut().writer();
    for (argv[2..]) |d| try out.print("1 {s}\n", .{d});
}
