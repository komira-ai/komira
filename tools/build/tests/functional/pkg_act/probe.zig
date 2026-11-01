//! A stand-in for the program pkg_act runs: the launcher level test's
//! program. PROBE_MODE says what it does:
//!   level       report on stdout, a note on stderr, exit 0
//!   level_fail  report on stdout, exit 3
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const out = std.fs.File.stdout().deprecatedWriter();
    const mode = std.process.getEnvVarOwned(a, "PROBE_MODE") catch "level";
    if (std.mem.eql(u8, mode, "level")) {
        try out.writeAll("level report\n");
        std.debug.print("a note on stderr\n", .{});
        return;
    }
    if (std.mem.eql(u8, mode, "level_fail")) {
        try out.writeAll("level report: wrong\n");
        std.process.exit(3);
    }
    std.debug.print("unknown PROBE_MODE {s}\n", .{mode});
    std.process.exit(2);
}
