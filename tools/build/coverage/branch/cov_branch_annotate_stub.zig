//! A stand-in for lld and llvm-profdata in the process tests of
//! `cov_branch annotate` (cov_branch_exe_test.zig), reached through a
//! symbolic link named like the program it stands in for. Beside that link,
//! for the name <p> it was run as:
//!   - it writes its arguments to <p>.argv and its environment to <p>.env,
//!     one per line;
//!   - it writes the file <p>.stdout, if there is one, to its stdout, and
//!     <p>.stderr to its stderr;
//!   - it exits with the number in <p>.exit, 0 without one.

const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const dir = std.fs.path.dirname(args[0]) orelse ".";
    const name = std.fs.path.basename(args[0]);
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();

    try d.writeFile(try std.fmt.allocPrint(a, "{s}.argv", .{name}), try std.mem.join(a, "\n", args));
    var env = try std.process.getEnvMap(a);
    var lines = std.ArrayList([]const u8).init(a);
    var it = env.iterator();
    while (it.next()) |e| try lines.append(try std.fmt.allocPrint(a, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* }));
    try d.writeFile(try std.fmt.allocPrint(a, "{s}.env", .{name}), try std.mem.join(a, "\n", lines.items));

    if (d.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}.stdout", .{name}), 1 << 26)) |t| {
        try std.io.getStdOut().writeAll(t);
    } else |_| {}
    if (d.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}.stderr", .{name}), 1 << 26)) |t| {
        try std.io.getStdErr().writeAll(t);
    } else |_| {}
    const code = if (d.readFileAlloc(a, try std.fmt.allocPrint(a, "{s}.exit", .{name}), 16)) |t|
        try std.fmt.parseInt(u8, std.mem.trim(u8, t, " \n"), 10)
    else |_|
        0;
    std.process.exit(code);
}
