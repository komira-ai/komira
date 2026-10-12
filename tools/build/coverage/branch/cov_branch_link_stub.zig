//! cov_branch_link_stub: the stand-in busybox, lld and zig of the process
//! tests of `cov_branch link` (cov_branch_link_exe_test.zig), reached
//! through a symbolic link named as the program it stands in for.
//!
//! usage: <dir>/<name> <arguments...>
//!
//! <dir> is the directory argv[0] names. It writes its arguments
//! (argv[1..]), one per line, to `<dir>/argv` and its environment, one
//! NAME=VALUE per line in the order it was given, to `<dir>/env`. When
//! `<dir>/say` exists, it writes `stdout: <say>` to stdout and `stderr:
//! <say>` to stderr. When `<dir>/stub_out` exists, it writes its bytes to the
//! file the last `-o <file>` argument names. It exits with the decimal
//! status in `<dir>/stub_rc`, 0 when there is none. A test-only program: no
//! rule hands it out.

const std = @import("std");

fn readOpt(alloc: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !?[]const u8 {
    return dir.readFileAlloc(alloc, name, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
}

pub fn main() !u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const argv = try std.process.argsAlloc(alloc);
    var dir = try std.fs.cwd().openDir(std.fs.path.dirname(argv[0]) orelse return error.NoDirectory, .{});
    defer dir.close();

    var rec = std.ArrayList(u8).init(alloc);
    var out: ?[]const u8 = null;
    for (argv[1..], 1..) |a, i| {
        try rec.appendSlice(a);
        try rec.append('\n');
        if (std.mem.eql(u8, a, "-o") and i + 1 < argv.len) out = argv[i + 1];
    }
    try dir.writeFile("argv", rec.items);

    var env = std.ArrayList(u8).init(alloc);
    for (std.os.environ) |e| {
        try env.appendSlice(std.mem.span(e));
        try env.append('\n');
    }
    try dir.writeFile("env", env.items);

    if (try readOpt(alloc, dir, "say")) |say| {
        try std.io.getStdOut().writer().print("stdout: {s}\n", .{say});
        try std.io.getStdErr().writer().print("stderr: {s}\n", .{say});
    }
    if (out) |o| {
        if (try readOpt(alloc, dir, "stub_out")) |bytes| try std.fs.cwd().writeFile(o, bytes);
    }
    const rc = (try readOpt(alloc, dir, "stub_rc")) orelse return 0;
    return try std.fmt.parseUnsigned(u8, std.mem.trim(u8, rc, " \n"), 10);
}
