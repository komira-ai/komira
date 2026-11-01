//! check_release_ref: the guard of .github/workflows/release.yml. It says
//! whether this run builds a release (see release_lib/ref_guard.zig for the
//! rules), before anything is built.
//!
//!   check_release_ref --event <push|workflow_dispatch> --ref <ref> --sha <id>
//!       --artifacts <path> [--work-dir <dir>] [--reason <why>] [--actor <login>]
//!       [--github-output <file>] [--summary-file <file>]
//!
//! It writes `release=true` or `release=false` to --github-output (standard
//! output without it). `false` is a push whose commit has no artifacts file:
//! a warning, a summary line, exit 0, and the workflow's later steps are
//! skipped. A break-glass (manual) run writes its banner as the first line
//! of --summary-file.
//!
//! Exit 0 when the run may go on (or has nothing to release), 1 when it is
//! refused (the reason is on standard error), 2 on a usage error.
const std = @import("std");
const lib = @import("release_lib");

const util = lib.util;

const NAMES = [_][]const u8{
    "--event",         "--ref",           "--sha",
    "--artifacts",     "--work-dir",      "--reason",
    "--actor",         "--github-output", "--summary-file",
};

const USAGE =
    \\usage: check_release_ref --event <push|workflow_dispatch> --ref <ref> --sha <commit id>
    \\                         --artifacts <path> [--work-dir <dir>] [--reason <why>] [--actor <login>]
    \\                         [--github-output <file>] [--summary-file <file>]
    \\
;

fn die(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.fs.File.stderr().deprecatedWriter().print("check_release_ref: " ++ fmt ++ "\n", args) catch {};
    std.process.exit(code);
}

pub fn main() void {
    run() catch |e| die(1, "{s}", .{@errorName(e)});
}

fn emit(path: ?[]const u8, text: []const u8) !void {
    if (path) |p| return util.appendFile(p, text);
    try std.fs.File.stdout().writeAll(text);
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const argv = try std.process.argsAlloc(a);
    var bad: []const u8 = "";
    const flags = util.Flags.parse(a, argv[1..], &NAMES, &bad) catch |e| {
        std.fs.File.stderr().deprecatedWriter().print("check_release_ref: {s}: {s}\n{s}", .{ @errorName(e), bad, USAGE }) catch {};
        std.process.exit(2);
    };
    for ([_][]const u8{ "--event", "--ref", "--sha", "--artifacts" }) |need| {
        if (flags.get(need) == null) {
            std.fs.File.stderr().deprecatedWriter().print("check_release_ref: {s} is required\n{s}", .{ need, USAGE }) catch {};
            std.process.exit(2);
        }
    }
    const work_dir = flags.get("--work-dir") orelse ".";
    const artifacts = flags.get("--artifacts").?;
    const exists = blk: {
        var d = try std.fs.cwd().openDir(work_dir, .{});
        defer d.close();
        d.access(artifacts, .{}) catch break :blk false;
        break :blk true;
    };
    const git = util.RealGit{ .work_dir = work_dir };
    const outcome = try lib.ref_guard.decide(a, .{
        .event = flags.get("--event").?,
        .ref = flags.get("--ref").?,
        .sha = flags.get("--sha").?,
        .reason = flags.getOr("--reason"),
        .actor = flags.getOr("--actor"),
        .artifacts = artifacts,
        .artifacts_exist = exists,
    }, git);
    const out = flags.get("--github-output");
    const summary = flags.get("--summary-file");
    switch (outcome) {
        .refuse => |why| die(1, "refused: {s}", .{why}),
        .skip => |msg| {
            try std.fs.File.stdout().writeAll(try std.fmt.allocPrint(a, "::warning title=release skipped::{s}\n", .{msg}));
            if (summary) |s| try util.appendFile(s, try std.fmt.allocPrint(a, "release SKIPPED: {s} (nothing was built)\n", .{msg}));
            try emit(out, "release=false\n");
        },
        .release => |banner| {
            if (banner) |b| {
                try std.fs.File.stderr().writeAll(try std.fmt.allocPrint(a, "check_release_ref: {s}\n", .{b}));
                if (summary) |s| try util.appendFile(s, try std.fmt.allocPrint(a, "{s}\n", .{b}));
            }
            try emit(out, "release=true\n");
        },
    }
}
