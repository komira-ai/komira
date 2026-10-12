//! `gate step` (S1-S6 of docs/design/zig_gate_runner.md): each recorded
//! result, the timeout's group kill, a skip, the `-o` outputs, an infra exit
//! and the scratch directory. The command is testkit's fixture.

const std = @import("std");
const kit = @import("testkit.zig");

const Env = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    dir: []const u8,
    real: []const u8,

    fn init() !*Env {
        const e = try std.heap.page_allocator.create(Env);
        e.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        e.a = e.arena.allocator();
        e.dir = try kit.tempDir(e.a);
        e.real = try std.fs.realpathAlloc(e.a, e.dir);
        return e;
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        std.heap.page_allocator.destroy(e);
    }

    fn p(e: *Env, rel: []const u8) []const u8 {
        return std.fmt.allocPrint(e.a, "{s}/{s}", .{ e.dir, rel }) catch unreachable;
    }

    fn step(e: *Env, opts: []const []const u8, cmd: []const []const u8, env: ?[]const []const u8) !kit.Result {
        var l = std.ArrayList([]const u8).init(e.a);
        try l.appendSlice(&.{ "step", "--status", "status" });
        try l.appendSlice(opts);
        try l.append("--");
        try l.appendSlice(cmd);
        return kit.runGate(e.a, e.dir, l.items, .{ .env = env, .timeout_ms = 30_000 });
    }

    fn status(e: *Env) ![]const u8 {
        return kit.readFile(e.a, e.p("status"));
    }
};

const no_scratch = [_][]const u8{"GATE_TEST=1"};

// S1. Mutant: accept a leading zero in the limit.
test "S1 usage: each bad command line exits 2, and an unreadable --after file fails before any status" {
    const e = try Env.init();
    defer e.deinit();
    const Case = struct { argv: []const []const u8, msg: []const u8 };
    for ([_]Case{
        .{ .argv = &.{"step"}, .msg = "mut_step: usage error\n" },
        .{ .argv = &.{ "step", "--status", "s", "--", "x/exit" }, .msg = "mut_step: usage error\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "05", "--", "x/exit" }, .msg = "mut_step: limit '05' is not a positive number of seconds\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "", "--", "x/exit" }, .msg = "mut_step: limit '' is not a positive number of seconds\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--after" }, .msg = "mut_step: --after needs a status file\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--infra-exit" }, .msg = "mut_step: --infra-exit needs a status\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--infra-exit", "x", "--", "x/exit" }, .msg = "mut_step: --infra-exit x is not a status\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--infra-exit", "", "--", "x/exit" }, .msg = "mut_step: --infra-exit  is not a status\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--bogus", "1", "--", "x/exit" }, .msg = "mut_step: unknown argument --bogus\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5" }, .msg = "mut_step: expected -- and a command\n" },
        .{ .argv = &.{ "step", "--status", "s", "--limit-s", "5", "--" }, .msg = "mut_step: expected -- and a command\n" },
    }) |c| {
        const r = try kit.runGate(e.a, e.dir, c.argv, .{});
        if (r.status != 2 or !std.mem.eql(u8, r.err, c.msg)) {
            std.debug.print("{s}: exit {d}, stderr {s}\n", .{ c.argv, r.status, r.err });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(!kit.exists(e.p("s")));
    }
    const r = try e.step(&.{ "--limit-s", "5", "--after", "nope" }, &.{"x/exit"}, null);
    try std.testing.expect(r.status != 0 and r.status != 2);
    try std.testing.expect(!kit.exists(e.p("status")));
}

// S4. Mutant: record a timeout as `fail` (the group is killed either way).
test "S4 results: ok, fail <n>, and timeout <n> with the whole group gone; each with the log's tail" {
    const e = try Env.init();
    defer e.deinit();
    var r = try e.step(&.{ "--limit-s", "30" }, &.{ "x/lines", "2", "1", "0" }, &no_scratch);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("ok\nline 1\nline 2\n", try e.status());
    r = try e.step(&.{ "--limit-s", "30", "--infra-exit", "124" }, &.{ "x/exit", "3" }, &no_scratch);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("fail 3\n", try e.status());
    const f = e.p("s4.pids");
    r = try e.step(&.{ "--limit-s", "2", "--infra-exit", "143" }, &.{ "x/spawnwait", f }, &no_scratch);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("timeout 2\n", try e.status());
    try std.testing.expect(r.ms >= 2000 and r.ms < 7000);
    try std.testing.expect(kit.goneWithin(try kit.pidsFrom(e.a, f, 2), 2000));
    // Inside its limit, a run that takes 1 s is ok.
    r = try e.step(&.{ "--limit-s", "5" }, &.{ "x/sleep", "1" }, &no_scratch);
    try std.testing.expectEqualStrings("ok\n", try e.status());
}

// S2, S6. Mutant: create the `-o` outputs after a success (a step's own
// output is truncated).
test "S2 S6 skip and outputs: skipped with an empty -o file; -o kept after a success" {
    const e = try Env.init();
    defer e.deinit();
    try kit.writeFile(e.p("before"), "fail 1\n");
    var r = try e.step(&.{ "--limit-s", "5", "--after", "before" }, &.{ "x/exit", "0", "-o", e.p("out/deep/x.mojoc") }, &no_scratch);
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("skipped\n", try e.status());
    try std.testing.expectEqualStrings("", try kit.readFile(e.a, e.p("out/deep/x.mojoc")));
    // `ok` without a newline, and `ok` as the first of several lines, run.
    try kit.writeFile(e.p("ok1"), "ok");
    try kit.writeFile(e.p("ok2"), "ok\nline\n");
    try kit.writeFile(e.p("made"), "kept bytes");
    r = try e.step(&.{ "--limit-s", "5", "--after", "ok1", "--after", "ok2" }, &.{ "x/exit", "0", "-o", e.p("made") }, &no_scratch);
    try std.testing.expectEqualStrings("ok\n", try e.status());
    try std.testing.expectEqualStrings("kept bytes", try kit.readFile(e.a, e.p("made")));
    // `okay` is not `ok`.
    try kit.writeFile(e.p("okay"), "okay\n");
    r = try e.step(&.{ "--limit-s", "5", "--after", "okay" }, &.{ "x/exit", "0" }, &no_scratch);
    try std.testing.expectEqualStrings("skipped\n", try e.status());
}

// S5. Mutant: record an infra exit as `fail` (the action would be cached).
test "S5 infra exit: a listed status fails the action with the log's tail, and writes no status" {
    const e = try Env.init();
    defer e.deinit();
    const r = try e.step(&.{ "--limit-s", "30", "--infra-exit", "2", "--infra-exit", "124" }, &.{ "x/lines", "1", "1", "124" }, &no_scratch);
    try std.testing.expectEqual(@as(u8, 124), r.status);
    try std.testing.expectEqualStrings("mut_step: the step exited 124, a failure of the machine it ran on, not of the mutant; failing the action so that it is not cached\nline 1\n", r.err);
    try std.testing.expect(!kit.exists(e.p("status")));
}

// S3. Mutant: a relative BUCK_SCRATCH_PATH taken from / (or not made).
test "S3 @MUT_SCRATCH@: absolute, relative and unset scratch paths" {
    const e = try Env.init();
    defer e.deinit();
    const abs_env = [_][]const u8{try std.fmt.allocPrint(e.a, "BUCK_SCRATCH_PATH={s}/abs", .{e.real})};
    var r = try e.step(&.{ "--limit-s", "5" }, &.{ "x/args", "@MUT_SCRATCH@/passed", "x@MUT_SCRATCH@" }, &abs_env);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, "fail 3\n[x/args]\n[{s}/abs/mut_step/passed]\n[x@MUT_SCRATCH@]\n", .{e.real}), try e.status());
    try std.testing.expect(kit.exists(e.p("abs/mut_step/log")));
    r = try e.step(&.{ "--limit-s", "5" }, &.{ "x/args", "@MUT_SCRATCH@/passed" }, &.{"BUCK_SCRATCH_PATH=rel/s"});
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, "fail 3\n[x/args]\n[{s}/rel/s/mut_step/passed]\n", .{e.real}), try e.status());
    // Unset: a .mut_step.XXXXXX directory under the working directory,
    // made before the --after verdict, so it exists on a skip too.
    try kit.writeFile(e.p("no"), "fail 1\n");
    r = try e.step(&.{ "--limit-s", "5", "--after", "no" }, &.{ "x/args", "-o", "@MUT_SCRATCH@/o" }, &no_scratch);
    try std.testing.expectEqualStrings("skipped\n", try e.status());
    var d = try std.fs.cwd().openDir(e.dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    var found = false;
    while (try it.next()) |entry| {
        if (std.mem.startsWith(u8, entry.name, ".mut_step.")) {
            const o = try std.fmt.allocPrint(e.a, "{s}/{s}/o", .{ e.dir, entry.name });
            try std.testing.expect(kit.exists(o));
            found = true;
        }
    }
    try std.testing.expect(found);
}
