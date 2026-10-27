//! `gate rust` (R1-R8 of docs/design/zig_gate_runner.md), on fake libtest
//! harnesses (testkit.zig, `rust_*`): usage, the environment, each verdict
//! and its message, and the marker.

const std = @import("std");
const kit = @import("testkit.zig");
const util = @import("util.zig");

const Env = struct {
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    dir: []const u8,
    bb: []const u8,

    fn init() !*Env {
        const e = try std.heap.page_allocator.create(Env);
        e.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        e.a = e.arena.allocator();
        e.dir = try kit.tempDir(e.a);
        e.bb = try kit.busybox(e.a);
        return e;
    }

    fn deinit(e: *Env) void {
        e.arena.deinit();
        std.heap.page_allocator.destroy(e);
    }

    fn run(e: *Env, harness: []const u8, timeout: []const u8) !kit.Result {
        const bin = try std.fmt.allocPrint(e.a, "h/{s}", .{harness});
        return kit.runGate(e.a, e.dir, &.{ "rust", "--busybox", e.bb, "--label", "//r:t", "--test", bin, "--marker", "passed", "--timeout-s", timeout }, .{ .clock = true });
    }

    fn marker(e: *Env) []const u8 {
        return std.fmt.allocPrint(e.a, "{s}/passed", .{e.dir}) catch unreachable;
    }
};

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// R1. Mutant: accept a timeout of 0.
test "R1 usage: exactly five options; a timeout that is empty, not a number, or 0 is refused; 007 is not" {
    const e = try Env.init();
    defer e.deinit();
    const bad = [_][]const []const u8{
        &.{"rust"},
        &.{ "rust", "--busybox", e.bb, "--label", "l", "--test", "t", "--marker", "m" },
        &.{ "rust", "--busybox", e.bb, "--label", "l", "--test", "t", "--marker", "m", "--timeout-s", "1", "--x", "y" },
        &.{ "rust", "--busybox", e.bb, "--label", "l", "--test", "t", "--marker", "m", "--bogus", "1" },
    };
    for (bad) |argv| {
        const r = try kit.runGate(e.a, e.dir, argv, .{});
        try std.testing.expectEqual(@as(u8, 2), r.status);
        try std.testing.expectEqualStrings("rust test_runner: usage error\n", r.err);
    }
    for ([_][]const u8{ "", "x", "1s", "0", "00" }) |t| {
        const r = try e.run("rust_ok", t);
        try std.testing.expectEqual(@as(u8, 2), r.status);
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(e.a, "rust test_runner: timeout must be a positive number of seconds, not '{s}'\n", .{t}), r.err);
    }
    try std.testing.expectEqual(@as(u8, 0), (try e.run("rust_ok", "007")).status);
}

// R8. Mutant: a trailing space, or the marker written before the summary
// checks (the refusals below then leave one).
test "R8 marker: `PASS <label>: <n> passed\\n` to the marker and to stdout" {
    const e = try Env.init();
    defer e.deinit();
    const r = try e.run("rust_ok", "30");
    try std.testing.expectEqual(@as(u8, 0), r.status);
    try std.testing.expectEqualStrings("PASS //r:t: 3 passed\n", r.out);
    try std.testing.expectEqualStrings("PASS //r:t: 3 passed\n", try kit.readFile(e.a, e.marker()));
}

// R3. Mutant: inherit the action's environment.
test "R3 environment: exactly PATH, TMPDIR and HOME" {
    const e = try Env.init();
    defer e.deinit();
    const r = try kit.runGate(e.a, e.dir, &.{ "rust", "--busybox", e.bb, "--label", "//r:t", "--test", "h/rust_env", "--marker", "passed", "--timeout-s", "30" }, .{ .env = &.{ "RUST_TEST_THREADS=1", "LD_PRELOAD=/x.so", "PATH=/nowhere" } });
    try std.testing.expectEqual(@as(u8, 7), r.status);
    // The banner's output: the three variables, nothing else.
    const head = "GATED TEST FAILED: //r:t (exit 7)\n";
    const i = std.mem.indexOf(u8, r.err, head).?;
    var it = util.lines(r.err[i + head.len ..]);
    var names = std.ArrayList([]const u8).empty;
    while (it.next()) |l| try names.append(e.a, l[0 .. std.mem.indexOfScalar(u8, l, '=') orelse l.len]);
    try std.testing.expectEqual(@as(usize, 3), names.items.len);
    try std.testing.expectEqualStrings("PATH", names.items[0]);
    try std.testing.expectEqualStrings("TMPDIR", names.items[1]);
    try std.testing.expectEqualStrings("HOME", names.items[2]);
    try std.testing.expect(std.mem.indexOf(u8, r.err, "/.komira_rust_test.") != null);
}

// R4-R6. Mutant: drop a refusal (its case passes and leaves a marker).
test "R4-R6 refusals: empty list, a failing list, a failing run, ignored tests, a count mismatch, no summary" {
    const e = try Env.init();
    defer e.deinit();
    const Case = struct { h: []const u8, rc: u8, msg: []const u8 };
    const rule = "==================================================================\n";
    for ([_]Case{
        .{ .h = "rust_empty", .rc = 1, .msg = rule ++ "EMPTY GATE: //r:t lists 0 tests. A gate that runs nothing passes for any code; give it a #[test], or drop it from `tests`.\n" },
        .{ .h = "rust_listfails", .rc = 5, .msg = rule ++ "GATED TEST FAILED: //r:t: listing its tests exited 5.\ncannot list\n" },
        .{ .h = "rust_fails", .rc = 101, .msg = rule ++ "GATED TEST FAILED: //r:t (exit 101)\ntest a ... FAILED\ntest result: FAILED. 0 passed; 1 failed; 0 ignored;\n" },
        .{ .h = "rust_ignored", .rc = 1, .msg = rule ++ "REFUSED: //r:t: 1 #[ignore]d test(s) did not run. An ignored test is a mute; remove its #[ignore] and make it pass, or delete it.\ntest b ... ignored\n" },
        .{ .h = "rust_mismatch", .rc = 1, .msg = rule ++ "REFUSED: //r:t: 2 tests listed, so 2 must pass; the harness reports 1.\ntest result: ok. 1 passed; 0 failed; 0 ignored;\n" },
        .{ .h = "rust_nosummary", .rc = 1, .msg = rule ++ "GATED TEST FAILED: //r:t: the harness exited 0 without a `test result: ok.` line.\ntest a ... ok\n" },
    }) |c| {
        const r = try e.run(c.h, "30");
        if (r.status != c.rc or !std.mem.eql(u8, r.err, c.msg)) {
            std.debug.print("{s}: exit {d}, stderr\n{s}\n", .{ c.h, r.status, r.err });
            return error.TestUnexpectedResult;
        }
        try std.testing.expect(!kit.exists(e.marker()));
        try std.testing.expectEqualStrings("", r.out);
    }
}

// R7. Mutant: check NO VERDICT after the status check (137 and 142 would
// read GATED TEST FAILED).
test "R7 NO VERDICT: SIGKILL (137) in either run, and the timeout's SIGALRM (142)" {
    const e = try Env.init();
    defer e.deinit();
    const rule = "==================================================================\n";
    const r1 = try e.run("rust_killedlist", "30");
    try std.testing.expectEqual(@as(u8, 137), r1.status);
    try std.testing.expectEqualStrings(rule ++ "NO VERDICT: listing the tests of //r:t was killed by SIGKILL (exit 137).\n  A memory limit's kill is not the test's failure; retry on a larger machine.\n", r1.err);
    const r2 = try e.run("rust_killed", "30");
    try std.testing.expectEqual(@as(u8, 137), r2.status);
    try std.testing.expect(contains(r2.err, "NO VERDICT: the tests of //r:t was killed by SIGKILL (exit 137).\n"));
    const r3 = try e.run("rust_hangs", "01");
    try std.testing.expectEqual(@as(u8, 142), r3.status);
    try std.testing.expectEqualStrings(rule ++ "NO VERDICT: the tests of //r:t timed out after 01s (exit 142).\n  A hang is not the test's failure; find what it waits on, or raise `test_timeout_s`.\n", r3.err);
    // SIGALRM goes to the harness alone, at its timeout on the test's clock.
    try std.testing.expect(kit.hasEvents(r3.events, &.{"t=1000 ALRM C"}));
    try std.testing.expect(!kit.exists(e.marker()));
}

test "summary parsing follows the shell's sed expression" {
    const rust = @import("rust.zig");
    try std.testing.expectEqualStrings("3", rust.summary("x\ntest result: ok. 3 passed; 0 failed; 1 ignored; 0 measured\n").?.passed);
    try std.testing.expectEqualStrings("1", rust.summary("test result: ok. 3 passed; 0 failed; 1 ignored;").?.ignored);
    try std.testing.expect(rust.summary("test result: ok.  passed; 0 failed; 0 ignored;\n") == null);
    // Only the first `test result: ok.` line counts.
    try std.testing.expect(rust.summary("test result: ok. junk\ntest result: ok. 3 passed; 0 failed; 0 ignored;\n") == null);
}
