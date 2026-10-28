// Why Zig: build tools are Zig (tools/build/README.md). This replaces the busybox
// shell script of `pixi_version_check` (pixi.bzl), so that the check runs no shell.
//! version_check: a pinned tool runs and prints the release the platform table pins.
//!
//! usage: version_check <exe> <expected output> <out>
//!
//! Runs `<exe> --version` with no environment but PATH and HOME set to a
//! path that does not exist (the tool must not read a user's configuration to
//! answer) and fails unless the output (stdout and stderr, trailing newlines
//! dropped) is `<expected output>`. The download itself is checked by its
//! sha256 (pinned_file), so this checks that the bytes are the release the
//! table's URL names, and that they run on the platform they are pinned for.
//! On success `<out>` holds the output and a newline.
//!
//! Exit status: 0; 1 for a failed check; 2 for a usage error.

const std = @import("std");

/// The two refusals of a version answer: the run failed, or it printed
/// another version. Null when it is the expected one.
pub fn refusal(a: std.mem.Allocator, exe_name: []const u8, ok: bool, got: []const u8, want: []const u8) !?[]u8 {
    if (!ok) return try std.fmt.allocPrint(a, "{s} --version failed: {s}", .{ exe_name, got });
    if (!std.mem.eql(u8, got, want)) return try std.fmt.allocPrint(a, "{s} --version printed '{s}', expected '{s}' (tools/build/platforms/table.bzl)", .{ exe_name, got, want });
    return null;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    if (argv.len != 4) {
        std.debug.print("usage: version_check <exe> <expected output> <out>\n", .{});
        std.process.exit(2);
    }
    var env = std.process.EnvMap.init(a);
    try env.put("PATH", "/nonexistent");
    try env.put("HOME", "/nonexistent");
    const r = std.process.Child.run(.{ .allocator = a, .argv = &.{ argv[1], "--version" }, .env_map = &env, .max_output_bytes = 1 << 20 }) catch |e| {
        std.debug.print("version_check: cannot run {s}: {s}\n", .{ argv[1], @errorName(e) });
        std.process.exit(1);
    };
    const ok = switch (r.term) {
        .Exited => |c| c == 0,
        else => false,
    };
    const both = try std.mem.concat(a, u8, &.{ r.stdout, r.stderr });
    const got = std.mem.trimRight(u8, both, "\n");
    const name = std.fs.path.basename(argv[2][0 .. std.mem.indexOfScalar(u8, argv[2], ' ') orelse argv[2].len]);
    if (try refusal(a, name, ok, got, argv[2])) |msg| {
        std.debug.print("{s}\n", .{msg});
        std.process.exit(1);
    }
    const f = try std.fs.cwd().createFile(argv[3], .{});
    defer f.close();
    try f.writeAll(got);
    try f.writeAll("\n");
}
