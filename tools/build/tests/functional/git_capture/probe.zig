//! The stand-in for the pinned git as a server: prints the service and path it was
//! asked for, then every byte of its standard input back, and exits 7 when the
//! input is `die`.
const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const out = std.io.getStdOut().writer();
    try out.print("service={s} path={s}\n", .{ argv[1], argv[2] });
    const input = try std.io.getStdIn().readToEndAlloc(a, 1 << 20);
    try out.writeAll(input);
    if (std.mem.eql(u8, input, "die")) std.process.exit(7);
}
