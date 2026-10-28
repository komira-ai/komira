//! lint: the action behind the lint rules in tools/build/lint/defs.bzl.
//!
//! usage: lint <result.json> <kind> <stage> <prefix> [tools...] -- <args...>
//!
//! Runs one lint over its inputs and writes <result.json>, the validation
//! result Buck2 reads (ValidationInfo): status "failure" with the findings as
//! the message when there are any, "success" otherwise. The action itself
//! succeeds either way; Buck2 fails any build or test whose graph holds the
//! target. A run that checks nothing is a finding. The files linted are
//! copies under <stage> (a buck-out directory; see _stage in defs.bzl);
//! findings name them as <prefix><path in the package> instead, e.g.
//! komira//tools/build/lint/defs.bzl.
//!
//! The kinds, each documented where it is written:
//!   shellcheck, actionlint, doc_links       tools.zig (a pinned tool's findings)
//!   action_pins, push_verdicts, no_endpoint workflow.zig
//!   retired_names, src_layout               tree.zig
//! The pointer_lint and public_boundary rules each run a Zig tool of their own
//! (tools/build/lint/pointer_lint.zig, tools/build/lint/public_boundary).
//!
//! Exit status: 0 the result is written (either status); 1 an input cannot be
//! read, a tool cannot be run or the result cannot be written; 2 bad usage.
//!
//! A static executable: it runs no shell and reads no PATH. Only the pinned
//! tools passed in run.

const std = @import("std");
const lint = @import("lint.zig");
const tools = @import("tools.zig");
const workflow = @import("workflow.zig");
const tree = @import("tree.zig");

const usage = "usage: lint <result.json> <kind> <stage> <prefix> [tools...] -- <args...>\n";

fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lint: " ++ fmt ++ "\n" ++ usage, args);
    std.process.exit(2);
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lint: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Runs lint `kind` with `tools` and `args`, its findings into `c`.
pub fn dispatch(c: *lint.Ctx, kind: []const u8, tl: []const []const u8, args: []const []const u8) !void {
    const eql = std.mem.eql;
    if (eql(u8, kind, "shellcheck")) return tools.shellcheck(c, tl, args);
    if (eql(u8, kind, "actionlint")) return tools.actionlint(c, tl, args);
    if (eql(u8, kind, "doc_links")) return tools.docLinks(c, tl, args);
    if (tl.len != 0) return error.Usage;
    if (eql(u8, kind, "action_pins")) return workflow.actionPins(c, args);
    if (eql(u8, kind, "push_verdicts")) return workflow.pushVerdicts(c, args);
    if (eql(u8, kind, "no_endpoint")) return workflow.noEndpoint(c, args);
    if (eql(u8, kind, "retired_names")) return tree.retiredNames(c, args);
    if (eql(u8, kind, "src_layout")) return tree.srcLayout(c, args);
    return error.UnknownKind;
}

/// A directory of this action's own: the one buck2 names in
/// BUCK_SCRATCH_PATH, or, on a remote worker (where it is unset and the
/// working directory is the action's own), one under the working directory.
fn scratchDir(alloc: std.mem.Allocator) ![]const u8 {
    const cwd = try std.process.getCwdAlloc(alloc);
    const named = std.process.getEnvVarOwned(alloc, "BUCK_SCRATCH_PATH") catch null;
    const dir = if (named) |n|
        try std.fs.path.resolve(alloc, &.{ cwd, n, "komira_lint" })
    else
        try std.fs.path.join(alloc, &.{ cwd, ".komira_lint" });
    try std.fs.cwd().makePath(dir);
    return dir;
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const argv = std.process.argsAlloc(alloc) catch fail("out of memory", .{});
    if (argv.len < 5) usageFail("too few arguments", .{});
    const kind = argv[2];
    const stage = argv[3];
    var sep: usize = 5;
    while (sep < argv.len and !std.mem.eql(u8, argv[sep], "--")) sep += 1;
    if (sep == argv.len) usageFail("no `--` before the arguments", .{});
    const tl: []const []const u8 = argv[5..sep];
    const args: []const []const u8 = argv[sep + 1 ..];

    const scratch = scratchDir(alloc) catch |err| fail("cannot make a scratch directory: {s}", .{@errorName(err)});
    var c = lint.Ctx.init(alloc, stage, scratch);
    dispatch(&c, kind, tl, args) catch |err| switch (err) {
        error.Usage => usageFail("bad arguments for kind {s}", .{kind}),
        error.UnknownKind => usageFail("unknown kind {s}", .{kind}),
        else => fail("{s}: {s}", .{ kind, @errorName(err) }),
    };
    const json = lint.result(alloc, kind, stage, argv[4], c.report.items, c.checked) catch fail("out of memory", .{});
    std.fs.cwd().writeFile(.{ .sub_path = argv[1], .data = json }) catch |err| fail("cannot write {s}: {s}", .{ argv[1], @errorName(err) });
    std.fs.cwd().deleteTree(scratch) catch {};
}
