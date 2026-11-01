//! The stand-in for kci: prints the directory it runs in and its arguments, one
//! per line, to its standard output.
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("cwd={s}\n", .{cwd});
    const argv = try std.process.argsAlloc(a);
    for (argv[1..]) |x| try out.print("arg={s}\n", .{x});
}
