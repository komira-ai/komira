//! cov_branch: the tool of a mojo_library's branch coverage actions
//! (tools/build/mojo/coverage_branch.bzl; README.md). One static executable
//! built with the pinned zig, one subcommand per action:
//!
//!   cov_branch link ...       `mojo_cov_pgo_link` (cov_branch_link.zig)
//!   cov_branch run ...        `mojo_cov_branch_run` (cov_branch_run.zig)
//!   cov_branch annotate ...   `mojo_cov_branch_annotate`
//!                             (cov_branch_annotate.zig)
//!
//! Exit status: the subcommand's; 2 for no subcommand or an unknown one.

const std = @import("std");
const br = @import("bounded_run.zig");
const link_cmd = @import("cov_branch_link.zig");
const run_cmd = @import("cov_branch_run.zig");
const annotate_cmd = @import("cov_branch_annotate.zig");

pub const USAGE = "usage: cov_branch link ... (" ++ link_cmd.USAGE ++ ")\n       cov_branch run ... (" ++ run_cmd.USAGE ++ ")\n       cov_branch annotate ... (" ++ annotate_cmd.USAGE ++ ")";

/// `argv` without the program's name. Messages go to `err`.
pub fn dispatch(alloc: std.mem.Allocator, argv: []const []const u8, where: run_cmd.Where, runner: run_cmd.Runner, err: *std.ArrayList(u8)) !u8 {
    if (argv.len == 0) {
        try err.writer().print("cov_branch: no subcommand\n{s}\n", .{USAGE});
        return 2;
    }
    if (std.mem.eql(u8, argv[0], "link")) return link_cmd.cli(alloc, argv[1..], where, runner, err);
    if (std.mem.eql(u8, argv[0], "run")) return run_cmd.cli(alloc, argv[1..], where, runner, err);
    if (std.mem.eql(u8, argv[0], "annotate")) return annotate_cmd.cli(alloc, argv[1..], where, runner, err);
    try err.writer().print("cov_branch: unknown subcommand {s}\n{s}\n", .{ argv[0], USAGE });
    return 2;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const code = mainIn(alloc) catch |e| blk: {
        std.io.getStdErr().writer().print("cov_branch: {s}\n", .{@errorName(e)}) catch {};
        break :blk 2;
    };
    std.process.exit(code);
}

fn mainIn(alloc: std.mem.Allocator) !u8 {
    const raw = try std.process.argsAlloc(alloc);
    const argv = try alloc.alloc([]const u8, raw.len - 1);
    for (raw[1..], 0..) |a, i| argv[i] = a;
    const cwd = try std.process.getCwdAlloc(alloc);
    var env_map = try std.process.getEnvMap(alloc);
    // Each subcommand's scratch directory is its own (`link`'s, `annotate`'s,
    // or `run`'s).
    const scratch = env_map.get("BUCK_SCRATCH_PATH");
    const is_link = argv.len > 0 and std.mem.eql(u8, argv[0], "link");
    const is_annotate = argv.len > 0 and std.mem.eql(u8, argv[0], "annotate");
    const where = run_cmd.Where{
        .cwd = cwd,
        .k = if (is_link)
            try link_cmd.scratchDir(alloc, cwd, scratch)
        else if (is_annotate)
            try annotate_cmd.scratchDir(alloc, cwd, scratch)
        else
            try run_cmd.scratchDir(alloc, cwd, scratch),
        .env = try br.envFromMap(alloc, &env_map),
    };
    var err = std.ArrayList(u8).init(alloc);
    const code = dispatch(alloc, argv, where, run_cmd.real_runner, &err) catch |e| blk: {
        try err.writer().print("cov_branch: {s}\n", .{@errorName(e)});
        break :blk 2;
    };
    std.io.getStdErr().writeAll(err.items) catch {};
    return code;
}

test {
    _ = br;
    _ = link_cmd;
    _ = run_cmd;
    _ = annotate_cmd;
    _ = @import("cov_branch_link_test.zig");
    _ = @import("cov_branch_run_test.zig");
    _ = @import("cov_branch_annotate_test.zig");
    _ = @import("cov_branch_annotate_order_test.zig");
}

test "no subcommand, or an unknown one, is a usage error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const where = run_cmd.Where{ .cwd = "/nowhere", .k = "/nowhere/k", .env = &.{} };
    var err = std.ArrayList(u8).init(a);
    try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{}, where, run_cmd.real_runner, &err));
    // The whole message: the reason, then the usage of every subcommand.
    try std.testing.expectEqualStrings("cov_branch: no subcommand\n" ++ USAGE ++ "\n", err.items);
    err.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{"lnk"}, where, run_cmd.real_runner, &err));
    try std.testing.expectEqualStrings("cov_branch: unknown subcommand lnk\n" ++ USAGE ++ "\n", err.items);
    err.clearRetainingCapacity();
    // A subcommand is matched on its whole name: a longer, shorter, other
    // case or empty name is unknown.
    for ([_][]const u8{ "linker", "lin", "blink", "LINK", "", "running", "annotat", "annotates", "ANNOTATE" }) |name| {
        try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{name}, where, run_cmd.real_runner, &err));
        const want = try std.fmt.allocPrint(a, "cov_branch: unknown subcommand {s}\n{s}\n", .{ name, USAGE });
        try std.testing.expectEqualStrings(want, err.items);
        err.clearRetainingCapacity();
    }
    // `link` reaches the subcommand: its own usage error.
    try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{"link"}, where, run_cmd.real_runner, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.items, "cov_branch link: usage error: --busybox is missing") != null);
    err.clearRetainingCapacity();
    // `run` reaches the subcommand: its own usage error.
    try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{"run"}, where, run_cmd.real_runner, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.items, "cov_branch run: usage error: --busybox is missing") != null);
    err.clearRetainingCapacity();
    // So does `annotate`.
    try std.testing.expectEqual(@as(u8, 2), try dispatch(a, &.{"annotate"}, where, run_cmd.real_runner, &err));
    try std.testing.expect(std.mem.indexOf(u8, err.items, "cov_branch annotate: usage error: --lld is missing") != null);
}
