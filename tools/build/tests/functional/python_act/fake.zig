//! A stand-in for the Python interpreter of python_act's cases. It requires
//! to be run as `-I -S -c <program>` with the program asking for
//! Py_GIL_DISABLED, and prints the first line of ../PRINTS (next to bin/) or
//! 3.13.1; it exits 9 on any other arguments.
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 5 or !std.mem.eql(u8, args[1], "-I") or !std.mem.eql(u8, args[2], "-S") or !std.mem.eql(u8, args[3], "-c") or
        std.mem.indexOf(u8, args[4], "Py_GIL_DISABLED") == null) std.process.exit(9);
    const dir = std.fs.path.dirname(args[0]) orelse ".";
    const prints = try std.fs.path.join(a, &.{ dir, "..", "PRINTS" });
    const text = std.fs.cwd().readFileAlloc(a, prints, 1 << 16) catch "3.13.1\n";
    const out = std.io.getStdOut().writer();
    try out.print("{s}\n", .{std.mem.sliceTo(text, '\n')});
    std.debug.print("stderr of the interpreter\n", .{});
}
