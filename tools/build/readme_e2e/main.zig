//! readme_e2e: a package of a release tried as the user of what was staged
//! (cli.zig says the commands; verify.zig and assemble.zig do them).

const std = @import("std");
const cli = @import("cli.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var out: std.ArrayList(u8) = .empty;
    const code = try cli.execute(a, argv[1..], &out);
    try std.fs.File.stdout().writeAll(out.items);
    std.process.exit(code);
}
