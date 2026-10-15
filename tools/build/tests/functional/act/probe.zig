//! A stand-in binary for act's run-check cases. It prints the library-path
//! variables it inherited, then does what PROBE_MODE says: `ok` (exit 0), `exit:N`,
//! `stderr:N` (N lines on stderr, then exit 3) or `stdin` (reads stdin, prints its length).
const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const out = std.io.getStdOut().writer();
    for ([_][]const u8{ "LD_LIBRARY_PATH", "LD_PRELOAD", "DYLD_LIBRARY_PATH", "DYLD_FALLBACK_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES", "KEPT" }) |n| {
        const v = std.process.getEnvVarOwned(a, n) catch "(unset)";
        try out.print("{s}={s}\n", .{ n, v });
    }
    const mode = std.process.getEnvVarOwned(a, "PROBE_MODE") catch "ok";
    if (std.mem.startsWith(u8, mode, "exit:")) std.process.exit(try std.fmt.parseInt(u8, mode[5..], 10));
    if (std.mem.startsWith(u8, mode, "stderr:")) {
        const n = try std.fmt.parseInt(usize, mode[7..], 10);
        var i: usize = 0;
        while (i < n) : (i += 1) std.debug.print("err line {d}\n", .{i});
        std.process.exit(3);
    }
    if (std.mem.eql(u8, mode, "stdin")) {
        const data = try std.io.getStdIn().readToEndAlloc(a, 1 << 20);
        try out.print("stdin {d} bytes\n", .{data.len});
    }
    const home = std.process.getEnvVarOwned(a, "HOME") catch "(unset)";
    const tmp = std.process.getEnvVarOwned(a, "TMPDIR") catch "(unset)";
    try out.print("home-set={s}\ntmp-set={s}\n", .{ if (std.mem.indexOf(u8, home, ".komira_run.") != null) "yes" else home, if (std.mem.indexOf(u8, tmp, ".komira_run.") != null) "yes" else tmp });
}
