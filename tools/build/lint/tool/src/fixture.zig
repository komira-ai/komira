//! What the unit tests share: a temporary tree to plant files in, a lint run
//! over it, and the pinned tools the zig_test targets pass in the environment
//! (tools/build/lint/tool/BUCK).

const std = @import("std");
const lint = @import("lint.zig");
const main = @import("main.zig");

pub const Fixture = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    /// The temporary tree's absolute path.
    root: []const u8,

    pub fn init() !Fixture {
        var f = Fixture{ .arena = std.heap.ArenaAllocator.init(std.testing.allocator), .tmp = std.testing.tmpDir(.{ .iterate = true }), .root = "" };
        f.root = try f.tmp.dir.realpathAlloc(f.arena.allocator(), ".");
        return f;
    }

    pub fn deinit(f: *Fixture) void {
        f.tmp.cleanup();
        f.arena.deinit();
    }

    pub fn alloc(f: *Fixture) std.mem.Allocator {
        return f.arena.allocator();
    }

    /// Writes `data` at `rel` under the tree and returns its absolute path.
    pub fn write(f: *Fixture, rel: []const u8, data: []const u8) ![]const u8 {
        if (std.fs.path.dirname(rel)) |d| try f.tmp.dir.makePath(d);
        try f.tmp.dir.writeFile(rel, data);
        return f.path(rel);
    }

    /// The absolute path of `rel` under the tree.
    pub fn path(f: *Fixture, rel: []const u8) ![]const u8 {
        return std.fs.path.join(f.alloc(), &.{ f.root, rel });
    }

    /// Runs lint `kind` with `stage` (a directory under the tree), `tools` and
    /// `args`, as the action does, and returns the run's report and count.
    pub fn run(f: *Fixture, kind: []const u8, stage: []const u8, tools: []const []const u8, args: []const []const u8) !Run {
        const scratch = try f.path("scratch");
        try std.fs.cwd().makePath(scratch);
        try f.tmp.dir.makePath(stage);
        var c = lint.Ctx.init(f.alloc(), try busybox(f.alloc()), try f.path(stage), scratch);
        try main.dispatch(&c, kind, tools, args);
        const json = try lint.result(f.alloc(), kind, c.stage, "test//", c.report.items, c.checked);
        return .{ .report = c.report.items, .checked = c.checked, .json = json };
    }
};

pub const Run = struct {
    /// The findings, under their staged paths.
    report: []const u8,
    checked: usize,
    /// The validation result.
    json: []const u8,

    pub fn failed(r: Run) bool {
        return std.mem.indexOf(u8, r.json, "\"status\": \"failure\"") != null;
    }
};

/// Fails unless the run passed, having checked `checked` inputs.
pub fn expectPass(r: Run, checked: usize) !void {
    if (r.failed()) {
        std.debug.print("expected a pass, got:\n{s}\n", .{r.json});
        return error.TestExpectedPass;
    }
    try std.testing.expectEqual(checked, r.checked);
}

/// Fails unless the run failed with a finding holding `needle`.
pub fn expectFinding(r: Run, needle: []const u8) !void {
    if (!r.failed() or std.mem.indexOf(u8, r.report, needle) == null) {
        std.debug.print("expected a finding holding `{s}`, got:\n{s}\n", .{ needle, r.json });
        return error.TestExpectedFinding;
    }
}

/// The path of a pinned tool the zig_test target names in its environment.
/// A test that needs one fails without it: it never passes unchecked.
pub fn tool(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    const v = std.process.getEnvVarOwned(alloc, name) catch {
        std.debug.print("the test target does not pass {s}\n", .{name});
        return error.TestToolMissing;
    };
    return std.fs.cwd().realpathAlloc(alloc, v);
}

/// The pinned busybox when the target passes it (the reader tests require
/// it with `tool`), else a name no test runs.
fn busybox(alloc: std.mem.Allocator) ![]const u8 {
    const v = std.process.getEnvVarOwned(alloc, "LINT_BUSYBOX") catch return "busybox";
    return std.fs.cwd().realpathAlloc(alloc, v);
}
