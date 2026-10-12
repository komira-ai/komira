//! The self-test scenarios' helper library (docs/design/build_selftests.md,
//! "The helper library"). A scenario's root file is
//!
//!     const lib = @import("lib/lib.zig");
//!     pub fn main() u8 { return lib.main(body); }
//!     fn body(c: *lib.Ctx) !void { ... }
//!
//! `main` parses the command line selftest_scenario gives (args.zig), runs
//! the guard (guard.zig), runs `body`, stops every daemon the scenario
//! started and deletes its scratch trees, whatever happened, and exits 0
//! only when the scenario asserted something and nothing failed.
const std = @import("std");
pub const args = @import("args.zig");
pub const expect = @import("expect.zig");
pub const guard = @import("guard.zig");
pub const parse = @import("parse.zig");
pub const reds = @import("reds.zig");
pub const refusals = @import("refusals.zig");
pub const runner = @import("runner.zig");
pub const scratch = @import("scratch.zig");
pub const text = @import("text.zig");
pub const whatran = @import("whatran.zig");

pub const Row = refusals.Row;

pub const Ctx = struct {
    a: std.mem.Allocator,
    args: args.Args,
    r: runner.Runner,
    rep: expect.Report,
    tmp: []const u8,
    trees: std.ArrayList(scratch.Tree),

    /// `buck2 <words>` in the checkout, under the scenario's isolation dir.
    pub fn run(c: *Ctx, words: []const []const u8, opts: runner.Opts) !runner.Result {
        return c.r.run(words, opts);
    }

    pub fn pass(c: *Ctx, comptime fmt: []const u8, a: anytype) void {
        c.rep.pass(fmt, a);
    }

    pub fn fail(c: *Ctx, comptime fmt: []const u8, a: anytype) void {
        c.rep.fail(fmt, a);
    }

    pub fn refusals(c: *Ctx, rows: []const Row) !void {
        try refusals_run(&c.r, &c.rep, rows);
    }

    /// Each row's target must fail to build, in an action run on the farm,
    /// printing the row's text (reds.zig).
    pub fn reds(c: *Ctx, rows: []const Row) !void {
        try reds_run(&c.r, &c.rep, rows);
    }

    /// A scratch tree of the checkout (scratch.zig); deleted when the
    /// scenario ends. Fails the scenario (error.Scratch) when it cannot be
    /// made its own project root.
    pub fn scratchTree(c: *Ctx) !scratch.Tree {
        var why: []const u8 = "";
        const name = try std.fmt.allocPrint(c.a, "selftest_{s}_scratch_{d}", .{ c.args.scenario, c.trees.items.len });
        const t = scratch.create(c.a, &c.r, c.tmp, name, &why) catch |e| {
            c.rep.fail("scratch tree: {s}", .{if (why.len > 0) why else @errorName(e)});
            return error.Scratch;
        };
        try c.trees.append(t);
        c.rep.pass("scratch tree {s} ({d} files) is its own project root", .{ t.root, t.files });
        return t;
    }
};

const refusals_run = refusals.run;
const reds_run = reds.run;

fn stderr() std.fs.File.Writer {
    return std.io.getStdErr().writer();
}

/// Where the scenario's logs and scratch trees go:
/// `buck-out/selftest_tmp/<scenario>` of the project root (its working
/// directory), emptied first. `buck2 test` gives a local test no $TMPDIR,
/// and buck-out is outside every package, so nothing there is a source.
fn workDir(a: std.mem.Allocator, scenario: []const u8) ![]const u8 {
    const root = try std.fs.cwd().realpathAlloc(a, ".");
    const dir = try std.fs.path.join(a, &.{ root, "buck-out", "selftest_tmp", scenario });
    std.fs.deleteTreeAbsolute(dir) catch {};
    try std.fs.cwd().makePath(dir);
    return dir;
}

fn uname() struct { sys: []const u8, machine: []const u8 } {
    const u = std.posix.uname();
    return .{ .sys = std.mem.sliceTo(&u.sysname, 0), .machine = std.mem.sliceTo(&u.machine, 0) };
}

pub fn main(comptime body: fn (*Ctx) anyerror!void) u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = std.process.argsAlloc(a) catch return 2;
    var sargs = std.ArrayList([]const u8).init(a);
    for (argv[1..]) |x| sargs.append(x) catch return 2;
    const p = args.parse(sargs.items) catch |e| {
        stderr().print("selftest: bad command line: {s}\n", .{@errorName(e)}) catch {};
        return 2;
    };
    if (guard.nestedRefusal(p.nested)) |why| {
        stderr().print("FAIL  {s}: {s}\n", .{ p.scenario, why }) catch {};
        return 1;
    }
    const u = uname();
    if (guard.clientRefusal(u.sys, u.machine)) |why| {
        stderr().print("FAIL  {s}: {s}; this is {s} {s}\n", .{ p.scenario, why, u.sys, u.machine }) catch {};
        return 1;
    }
    const tmp = workDir(a, p.scenario) catch |e| {
        stderr().print("FAIL  {s}: cannot make its work directory under buck-out/selftest_tmp: {s}\n", .{ p.scenario, @errorName(e) }) catch {};
        return 1;
    };
    if (pinRefusal(a, p.buck2_zst)) |why| {
        stderr().print("FAIL  {s}: {s}\n", .{ p.scenario, why }) catch {};
        return 1;
    }
    const log_dir = std.fs.path.join(a, &.{ tmp, "logs" }) catch return 2;
    std.fs.cwd().makePath(log_dir) catch {
        stderr().print("FAIL  {s}: cannot create {s}\n", .{ p.scenario, log_dir }) catch {};
        return 1;
    };
    var c = Ctx{
        .a = a,
        .args = p,
        .r = runner.Runner.init(a, p.buck2, p.scenario, log_dir) catch return 2,
        .rep = expect.Report.init(a, p.scenario),
        .tmp = tmp,
        .trees = std.ArrayList(scratch.Tree).init(a),
    };
    std.io.getStdOut().writer().print("{s}: buck2 {s}, logs in {s}\n", .{ p.scenario, p.buck2, log_dir }) catch {};

    checkPlatforms(&c) catch |e| c.rep.fail("guard: {s}", .{@errorName(e)});
    if (c.rep.fails == 0) {
        body(&c) catch |e| c.rep.fail("stopped by {s}", .{@errorName(e)});
    }
    c.r.killAll();
    if (!p.keep_scratch) {
        for (c.trees.items) |t| scratch.destroy(t);
    }
    return c.rep.finish();
}

/// Why the buck2 the scenario was given is not the release `tools/buck2`
/// pins (read from the project root, the scenario's working directory), or null.
fn pinRefusal(a: std.mem.Allocator, zst: []const u8) ?[]const u8 {
    const pin = std.fs.cwd().readFileAlloc(a, "tools/buck2", 1 << 20) catch return "cannot read tools/buck2 in the project root";
    const want = guard.pinnedDigest(pin) orelse return "tools/buck2 has no linux-x86_64 digest";
    const bytes = std.fs.cwd().readFileAlloc(a, zst, 1 << 30) catch return "cannot read the --buck2-zst file";
    const got = guard.sha256Hex(bytes);
    if (std.mem.eql(u8, &got, want)) return null;
    return std.fmt.allocPrint(a, "the buck2 the rule gives (sha256 {s} of its release asset) is not the one tools/buck2 pins ({s}): update tools/build/selftest/BUCK's buck2 pin with tools/buck2", .{ &got, want }) catch "the buck2 pin differs";
}

/// The guard's platform check, as an inner command: every execution
/// platform the inner daemon registers matches the scenario's `--expect`.
fn checkPlatforms(c: *Ctx) !void {
    const cfg = try c.run(&.{ "audit", "config", "--json", "build.execution_platforms" }, .{});
    const ep = parse.configValue(cfg.stdout, "build.execution_platforms") orelse {
        c.fail("guard: cannot read build.execution_platforms (see {s})", .{cfg.log});
        return;
    };
    const prov = try c.run(&.{ "audit", "providers", ep }, .{});
    if (!prov.ok()) {
        c.fail("guard: cannot analyse the execution platforms {s} (see {s})", .{ ep, prov.log });
        return;
    }
    const e = parse.executors(prov.stdout);
    if (guard.platformsRefusal(e, c.args.expect)) |why| {
        c.fail("guard: {s}: {d} platforms from {s}, {d} local, {d} remote (see {s})", .{ why, e.platforms, ep, e.local, e.remote, prov.log });
        return;
    }
    // Not an assertion of the scenario: a guard that passes counts nothing,
    // so a scenario whose body asserts nothing is still red.
    std.io.getStdOut().writer().print("guard: {d} {s} execution platform(s) from {s}\n", .{ e.platforms, @tagName(c.args.expect), ep }) catch {};
}
