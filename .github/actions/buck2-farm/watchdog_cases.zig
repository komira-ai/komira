//! The cases of the buck2-farm action for a run that hangs on a dead
//! connection to the farm (the watchdog,
//! tools/build/ci/assert_remote/farm_watchdog.zig), part of //:buck2_farm_cases:
//! action_test.zig, whose header says what each case catches, holds the
//! harness and imports this file.

const std = @import("std");
const t = std.testing;
const h = @import("action_test.zig");

// ---- a run that hangs on a dead connection to the farm -----------------------------

/// The watchdog's bound in the cases: 2 s, so a hanging case ends in seconds.
const fast: h.Setup = .{ .serve = .silent, .dead_seconds = 2 };

/// The line the watchdog writes when it ends a run, but for the time the connection was silent.
const cut_head = "buck2-farm: watchdog: the connection to the farm from local port ";
const cut_tail = ", past the bound of 0 min 2 s: the farm has closed it and buck2 would wait on it for ever; ending buck2 (SIGINT)\n";
const dead_head = "buck2-farm: the first run of `build` hung on a dead connection to the farm (nothing heard for 0 min ";
const dead_tail = ", past the watchdog's bound of 0 min 2 s), so buck2 and its daemon were ended; the farm answered at once; ran again (run 2 of at most 3); the first run's log is buck2-farm.first.log\n";

/// The number of lines of `text` that start with `head` and end with `tail`.
fn linesLike(text: []const u8, head: []const u8, tail: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, head) and std.mem.endsWith(u8, l, tail[0 .. tail.len - 1])) n += 1;
    }
    return n;
}

test "a farm that takes the request and then goes silent with the socket open: the run is ended and run again, green" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try h.runCaseWith(a, "build", &.{ h.hanging(h.waiting_log), h.fixture("build_remote.log", 0) }, fast);
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    // the client ended, then its daemon stopped, once
    try t.expectEqual(@as(usize, 1), c.kills);
    try t.expectEqual(@as(usize, 1), linesLike(c.out1, cut_head, cut_tail));
    try t.expect(h.has(c.out1, "buck2-farm: stopping buck2's daemon, which holds the dead connection (`./buck2 kill`)\n"));
    try t.expect(h.has(c.out1, "buck2-farm: the first run hung on a dead connection to the farm and was ended; waiting for the farm's port to answer, up to 20 min 0 s\n"));
    try t.expect(h.has(c.out1, "buck2-farm: the second run passed\n"));
    // one line in the job summary, saying why and what followed
    const summary = (try c.file(a, "summary.md")).?;
    try t.expectEqual(@as(usize, 1), std.mem.count(u8, summary, "\n"));
    try t.expectEqual(@as(usize, 1), linesLike(summary, dead_head, dead_tail));
    // the ended run's log is kept, the tool step read the second
    try t.expectEqualStrings(h.waiting_log, (try c.file(a, "buck2-farm.first.log")).?);
    try t.expectEqualStrings(try h.recorded(a, "build_remote.log"), (try c.file(a, "buck2-farm.log")).?);
    try t.expect(std.mem.startsWith(u8, c.out2, "assert_remote: ok"));
}

test "a hanging buck2 that ignores SIGINT is ended with SIGKILL, and the step runs again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var stubborn = h.hanging(h.waiting_log);
    stubborn.hang = .stubborn;
    const c = try h.runCaseWith(a, "build", &.{ stubborn, h.fixture("build_remote.log", 0) }, fast);
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqual(@as(usize, 1), c.kills);
    try t.expect(h.has(c.out1, "buck2-farm: buck2 has not ended 2 s after SIGINT; ending it with SIGKILL\n"));
    try t.expect(h.has(c.out1, "buck2-farm: the second run passed\n"));
}

test "three runs that hang: red after three, never a fourth, saying the third hung too" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try h.runCaseWith(a, "build", &.{ h.hanging(h.waiting_log), h.hanging(h.waiting_log), h.hanging(h.waiting_log), h.fixture("build_remote.log", 0) }, fast);
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 130), c.code); // the third run, ended by SIGINT
    try t.expectEqual(@as(usize, 3), c.runs);
    try t.expectEqual(@as(usize, 3), c.kills);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the third run hung on a dead connection to the farm too: the connection to the farm was lost in each of 3 runs; not run again\n"));
    try t.expectEqual(@as(usize, 2), std.mem.count(u8, (try c.file(a, "summary.md")).?, "\n"));
}

test "a run that hangs, then a real failure: red after two runs, naming the failure" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try h.runCaseWith(a, "build", &.{ h.hanging(h.waiting_log), h.derived(try h.compileError(a), 3), h.fixture("build_remote.log", 0) }, fast);
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 3), c.code);
    try t.expectEqual(@as(usize, 2), c.runs);
    try t.expectEqual(@as(usize, 1), c.kills);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: FAILED: the second run failed: a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))\n"));
}

test "a subcommand other than build, test or bxl that hangs is ended and not run again" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = try h.runCaseWith(a, "run", &.{ h.hanging(h.waiting_log), h.fixture("build_remote.log", 0) }, fast);
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 130), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expectEqual(@as(usize, 1), c.kills);
    try t.expectEqual(@as(usize, 1), linesLike(c.out1, cut_head, cut_tail));
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: not run again: `run` is not build, test or bxl\n"));
    try t.expect((try c.file(a, "summary.md")) == null);
}

test "a farm that is slow but alive is never cut: a run longer than twice the bound passes, run once" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 200 bytes, one every 25 ms: the run lasts at least 5 s on a connection that keeps hearing from the farm
    var slow = h.fixture("build_remote.log", 0);
    slow.farm_bytes = 200;
    const c = try h.runCaseWith(a, "build", &.{ slow, h.fixture("build_remote.log", 0) }, .{ .serve = .alive, .dead_seconds = 2 });
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 2), c.step);
    try t.expectEqual(@as(u8, 0), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expectEqual(@as(usize, 0), c.kills);
    try t.expect(!h.has(c.out1, "watchdog"));
    try t.expect((try c.file(a, "summary.md")) == null);
}

test "a real failure after talking to a live farm is not run again, and nothing is ended" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var failed = h.derived(try h.compileError(a), 3);
    failed.farm_bytes = 40;
    const c = try h.runCaseWith(a, "build", &.{ failed, h.fixture("build_remote.log", 0) }, .{ .serve = .alive, .dead_seconds = 2 });
    errdefer h.show(c);
    try t.expectEqual(@as(u8, 1), c.step);
    try t.expectEqual(@as(u8, 3), c.code);
    try t.expectEqual(@as(usize, 1), c.runs);
    try t.expectEqual(@as(usize, 0), c.kills);
    try t.expect(std.mem.endsWith(u8, c.out1, "buck2-farm: not run again: a failure that is not a cut connection: [2026-11-21T13:40:17.627+00:00] Action failed: komira//tools/build/examples/cshim:add (komira//tools/build/platforms:linux-x86_64#03cc1a891c89e4be) (c_compile add_files/add.c (pic))\n"));
    try t.expect((try c.file(a, "summary.md")) == null);
}
