//! The stand-in for the bench program: prints its directory and arguments to its
//! standard output, a note to its standard error, and exits 3 when an argument
//! is `fail`.
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const out = std.fs.File.stdout().deprecatedWriter();
    try out.print("cwd={s}\n", .{try std.fs.cwd().realpathAlloc(a, ".")});
    const argv = try std.process.argsAlloc(a);
    var fail = false;
    for (argv[1..]) |x| {
        try out.print("arg={s}\n", .{x});
        if (std.mem.eql(u8, x, "fail")) fail = true;
    }
    try std.fs.File.stderr().deprecatedWriter().writeAll("bench note\n");
    if (fail) std.process.exit(3);
}
