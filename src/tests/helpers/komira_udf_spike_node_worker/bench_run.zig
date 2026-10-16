// Why Zig: build tools are Zig (tools/build/README.md). This replaces the busybox
// shell script of `udf_bench` (defs.bzl), so that the bench runs no shell.
//! bench_run: runs the bench program in its data directory and keeps its
//! standard output.
//!
//! usage: bench_run <program> <data dir> <out> <run id file> [<argument>...]
//!
//! Runs <program> in <data dir> with the arguments, then the run id (the first
//! line of the run id file, without its newline), and writes the program's
//! standard output to <out>. Its standard error is this program's. Exit status:
//! the program's when it fails; 2 for a usage error or a failure to run it.

const std = @import("std");

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("bench_run: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

/// The first line of `text` (everything when it has no newline).
pub fn firstLine(text: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, text, '\n')) |i| text[0..i] else text;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len < 5) die("usage: bench_run <program> <data dir> <out> <run id file> [<argument>...]", .{});
    const program = if (std.fs.path.isAbsolute(argv[1])) argv[1] else try std.fs.path.join(a, &.{ try std.fs.cwd().realpathAlloc(a, "."), argv[1] });
    const run_id_text = std.fs.cwd().readFileAlloc(a, argv[4], 1 << 20) catch |e| die("cannot read {s}: {s}", .{ argv[4], @errorName(e) });
    var cmd = std.ArrayList([]const u8).init(a);
    try cmd.append(program);
    try cmd.appendSlice(argv[5..]);
    try cmd.append(firstLine(run_id_text));
    const out = std.fs.cwd().createFile(argv[3], .{}) catch |e| die("cannot create {s}: {s}", .{ argv[3], @errorName(e) });
    defer out.close();
    var child = std.process.Child.init(cmd.items, a);
    child.cwd = argv[2];
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Inherit;
    child.spawn() catch |e| die("cannot run {s}: {s}", .{ program, @errorName(e) });
    var buf: [65536]u8 = undefined;
    const reader = child.stdout.?.reader();
    while (true) {
        const n = reader.read(&buf) catch |e| die("cannot read the program's output: {s}", .{@errorName(e)});
        if (n == 0) break;
        out.writeAll(buf[0..n]) catch |e| die("cannot write {s}: {s}", .{ argv[3], @errorName(e) });
    }
    const term = child.wait() catch |e| die("cannot wait for {s}: {s}", .{ program, @errorName(e) });
    switch (term) {
        .Exited => |c| if (c != 0) std.process.exit(c),
        else => die("{s} did not exit", .{program}),
    }
}
