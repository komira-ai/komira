//! The flake measurement's pure parts: the rerun flag, the grouping of
//! failing runs, the rate and the verdict, and the JSON read back.
const std = @import("std");
const flake = @import("flake.zig");
const report = @import("report.zig");
const t = std.testing;

test "the rerun flag names the target as given and the run's n" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectEqualStrings("komira.rerun=//t:a#3", try flake.rerunValue(arena.allocator(), "//t:a", 3));
    try t.expectEqualStrings("komira.rerun=komira//src/x:x#1700000000001", try flake.rerunValue(arena.allocator(), "komira//src/x:x", 1700000000001));
}

test "a label names one target; a pattern does not" {
    try t.expect(flake.isLabel("//t:a"));
    try t.expect(flake.isLabel("komira//src/x:x"));
    try t.expect(!flake.isLabel("//t/..."));
    try t.expect(!flake.isLabel("//..."));
    try t.expect(!flake.isLabel("//t:"));
    try t.expect(!flake.isLabel("//t"));
}

test "a target has its cell, or not" {
    try t.expect(flake.hasCell("komira//src/x:x"));
    try t.expect(flake.hasCell("root//t:a"));
    try t.expect(!flake.hasCell("//t:a"));
    try t.expect(!flake.hasCell("t:a"));
    try t.expectEqualStrings("//t:a", flake.firstWithoutCell(&.{ "komira//t:b", "//t:a", "//t:c" }).?);
    // A pattern is refused for being one, not here.
    try t.expectEqual(@as(?[]const u8, null), flake.firstWithoutCell(&.{ "komira//t:b", "//t/..." }));
}

test "the first failing line: the line that marks a failure, never a line ending OK" {
    // A first line naming the run, and a passing test whose line says error:,
    // come before the FAIL line.
    try t.expectEqualStrings("2/3 test.y...FAIL (PlantedFlake)", flake.firstFailingLine("seed 99\n1/3 test.no error: here...OK\n2/3 test.y...FAIL (PlantedFlake)\nerror: later"));
    try t.expectEqualStrings("thread 1 panic: index out of bounds", flake.firstFailingLine("running run 3\n  thread 1 panic: index out of bounds\n"));
    try t.expectEqualStrings("Thread 1 PANICKED here", flake.firstFailingLine("\nThread 1 PANICKED here"));
    try t.expectEqualStrings("AssertionError: 1 != 2", flake.firstFailingLine("run 4\nAssertionError: 1 != 2"));
    try t.expectEqualStrings("Action failed: root//t:a (genrule)", flake.firstFailingLine("started\nAction failed: root//t:a (genrule)\nBUILD FAILED"));
    try t.expectEqualStrings("BUILD FAILED", flake.firstFailingLine("1/1 test.failing case name...OK\nBUILD FAILED"));
    // Words that mark nothing: `failed`, `failing` and `error` without a colon.
    try t.expectEqualStrings("assertion failed: x", flake.firstFailingLine("1/2 test.a...OK\nassertion failed: x\n0 errors"));
    // No line marks a failure: the first line that is not blank or OK.
    try t.expectEqualStrings("killed", flake.firstFailingLine("\n  killed  \nsomething else"));
    try t.expectEqualStrings("", flake.firstFailingLine("1/1 test.error: x...OK\n"));
    try t.expectEqualStrings("", flake.firstFailingLine(""));
}

test "failing runs group by their first failing line, in the order each first appeared" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const got = try flake.dedup(arena.allocator(), &.{
        .{ .run = 3, .excerpt = "running //t:a, run 3\n1/2 test.x...FAIL (A)" },
        .{ .run = 5, .excerpt = "running //t:a, run 5\n2/2 test.y...FAIL (B)" },
        .{ .run = 8, .excerpt = "running //t:a, run 8\n1/2 test.x...FAIL (A)" },
    });
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("1/2 test.x...FAIL (A)", got[0].first_failing_line);
    try t.expectEqualSlices(u64, &.{ 3, 8 }, got[0].runs);
    // The excerpt kept is the first run's.
    try t.expectEqualStrings("running //t:a, run 3\n1/2 test.x...FAIL (A)", got[0].excerpt);
    try t.expectEqualStrings("2/2 test.y...FAIL (B)", got[1].first_failing_line);
    try t.expectEqualSlices(u64, &.{5}, got[1].runs);
}

test "two failures behind the same passing line that says fail or error: are two groups" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const ok_line = "1/3 flake_test.test.the first failing line: error: words...OK";
    const got = try flake.dedup(arena.allocator(), &.{
        .{ .run = 3, .excerpt = ok_line ++ "\n2/3 flake_test.test.p...FAIL (PlantedFlake)" },
        .{ .run = 6, .excerpt = ok_line ++ "\n3/3 flake_test.test.q...FAIL (OtherDefect)" },
    });
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("2/3 flake_test.test.p...FAIL (PlantedFlake)", got[0].first_failing_line);
    try t.expectEqualStrings("3/3 flake_test.test.q...FAIL (OtherDefect)", got[1].first_failing_line);
}

test "check.bxl's exit: 0 measurable, 3 (user error) not measurable, else infra" {
    try t.expectEqual(flake.Check.measurable, flake.checkOutcome(0));
    try t.expectEqual(flake.Check.not_measurable, flake.checkOutcome(3));
    try t.expectEqual(flake.Check.infra, flake.checkOutcome(2));
    try t.expectEqual(flake.Check.infra, flake.checkOutcome(1));
    try t.expectEqual(flake.Check.infra, flake.checkOutcome(null));
}

fn target(name: []const u8, runs: u32, failures: u32) flake.Target {
    return .{ .target = name, .runs = runs, .failures = failures, .attempts = runs, .failing_runs = &.{}, .excerpts = &.{}, .infra = &.{} };
}

test "the rate is failures over counted runs" {
    try t.expectEqual(@as(f64, 0.2), flake.rate(target("//t:a", 15, 3)));
    try t.expectEqual(@as(f64, 0), flake.rate(target("//t:a", 5, 0)));
    try t.expectEqual(@as(f64, 1), flake.rate(target("//t:a", 4, 4)));
    try t.expectEqual(@as(f64, 0), flake.rate(target("//t:a", 0, 0)));
}

test "the verdict: any failure is flake; never_failed needs every run of every target counted" {
    const m = struct {
        fn of(ts: []const flake.Target) flake.Measurement {
            return .{ .rev = "r", .runs_requested = 5, .rerun_base = 0, .targets = ts };
        }
    };
    try t.expectEqual(flake.Verdict.flake, flake.verdict(m.of(&.{ target("//t:a", 5, 0), target("//t:b", 5, 1) })));
    try t.expectEqual(flake.Verdict.never_failed, flake.verdict(m.of(&.{ target("//t:a", 5, 0), target("//t:b", 5, 0) })));
    // One run of //t:b stayed INFRA: 0 of 4 is not "never failed in 5".
    try t.expectEqual(flake.Verdict.inconclusive, flake.verdict(m.of(&.{ target("//t:a", 5, 0), target("//t:b", 4, 0) })));
    // A failure counts even when another run stayed INFRA.
    try t.expectEqual(flake.Verdict.flake, flake.verdict(m.of(&.{target("//t:a", 4, 1)})));
    // A target check.bxl refused: not_measurable, never never_failed, even
    // next to one that ran 5 times; a failure elsewhere is still flake.
    var nm = target("//t:n", 0, 0);
    nm.check = .not_measurable;
    try t.expectEqual(flake.Verdict.not_measurable, flake.verdict(m.of(&.{ target("//t:a", 5, 0), nm })));
    try t.expectEqual(flake.Verdict.not_measurable, flake.verdict(m.of(&.{ target("//t:a", 4, 0), nm })));
    try t.expectEqual(flake.Verdict.flake, flake.verdict(m.of(&.{ target("//t:a", 5, 1), nm })));
    // A check that stayed INFRA left the target unmeasured: inconclusive.
    var ci = target("//t:c", 0, 0);
    ci.check = .infra;
    try t.expectEqual(flake.Verdict.inconclusive, flake.verdict(m.of(&.{ target("//t:a", 5, 0), ci })));
}

fn render(a: std.mem.Allocator, m: flake.Measurement) !std.json.Value {
    var buf = std.ArrayList(u8).init(a);
    try flake.writeVerdict(m, buf.writer());
    return (try std.json.parseFromSlice(std.json.Value, a, buf.items, .{})).value;
}

test "bisect flake's JSON read back: verdict, per-target counts, rate, runs and excerpts" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try render(a, .{
        .rev = "c9",
        .runs_requested = 15,
        .rerun_base = 0,
        .targets = &.{
            .{
                .target = "//t:a",
                .runs = 15,
                .failures = 3,
                .attempts = 16,
                .failing_runs = &.{ 3, 8, 13 },
                .excerpts = &.{.{ .first_failing_line = "assertion failed", .runs = &.{ 3, 8, 13 }, .excerpt = "run 3\nassertion failed" }},
                .infra = &.{},
            },
            .{ .target = "//t:b", .runs = 14, .failures = 0, .attempts = 16, .failing_runs = &.{}, .excerpts = &.{}, .infra = &.{.{ .run = 8, .buck2_exit = 2, .excerpt = "planted" }} },
            .{ .target = "//t:n", .check = .not_measurable, .check_excerpt = "runs no test action", .runs = 0, .failures = 0, .attempts = 0, .failing_runs = &.{}, .excerpts = &.{}, .infra = &.{} },
        },
    });
    const o = v.object;
    try t.expectEqualStrings("flake", o.get("mode").?.string);
    try t.expectEqualStrings("flake", o.get("verdict").?.string);
    const m = o.get("measurement").?.object;
    try t.expectEqualStrings("c9", m.get("rev").?.string);
    try t.expectEqual(@as(i64, 15), m.get("runs_requested").?.integer);
    try t.expectEqual(@as(i64, 0), m.get("rerun_base").?.integer);
    const ts = m.get("targets").?.array.items;
    try t.expectEqual(@as(usize, 3), ts.len);
    const ta = ts[0].object;
    try t.expectEqualStrings("//t:a", ta.get("target").?.string);
    try t.expectEqualStrings("measurable", ta.get("check").?.string);
    try t.expect(ta.get("check_excerpt").? == .null);
    const tn = ts[2].object;
    try t.expectEqualStrings("not_measurable", tn.get("check").?.string);
    try t.expectEqualStrings("runs no test action", tn.get("check_excerpt").?.string);
    try t.expectEqual(@as(i64, 15), ta.get("runs").?.integer);
    try t.expectEqual(@as(i64, 3), ta.get("failures").?.integer);
    try t.expectEqual(@as(f64, 0.2), ta.get("failure_rate").?.float);
    try t.expectEqual(@as(i64, 16), ta.get("attempts").?.integer);
    try t.expectEqual(@as(usize, 3), ta.get("failing_runs").?.array.items.len);
    const ex = ta.get("excerpts").?.array.items;
    try t.expectEqual(@as(usize, 1), ex.len);
    try t.expectEqualStrings("assertion failed", ex[0].object.get("first_failing_line").?.string);
    try t.expectEqual(@as(usize, 3), ex[0].object.get("runs").?.array.items.len);
    const tb = ts[1].object;
    try t.expectEqual(@as(i64, 8), tb.get("infra").?.array.items[0].object.get("run").?.integer);
    try t.expectEqual(@as(i64, 2), tb.get("infra").?.array.items[0].object.get("buck2_exit").?.integer);
}

test "bisect's verdict carries flake_runs when it measured, null otherwise" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = report.Report{ .verdict = .flake, .good = "g", .bad = "b", .targets = &.{"//t:a"}, .probes = &.{}, .failures = &.{}, .infra = &.{} };
    var buf = std.ArrayList(u8).init(a);
    try report.write(base, buf.writer());
    const none = (try std.json.parseFromSlice(std.json.Value, a, buf.items, .{})).value;
    try t.expect(none.object.get("flake_runs").? == .null);

    var with = base;
    with.flake_runs = .{ .rev = "b", .runs_requested = 5, .rerun_base = 100, .targets = &.{target("//t:a", 5, 1)} };
    buf.clearRetainingCapacity();
    try report.write(with, buf.writer());
    const got = (try std.json.parseFromSlice(std.json.Value, a, buf.items, .{})).value;
    const fr = got.object.get("flake_runs").?.object;
    try t.expectEqual(@as(i64, 100), fr.get("rerun_base").?.integer);
    try t.expectEqual(@as(i64, 1), fr.get("targets").?.array.items[0].object.get("failures").?.integer);
}
