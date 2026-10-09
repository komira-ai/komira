//! The parallelism table's cases (table.zig): its numbers, flags and missing
//! lines, the full-machine row, several reports, and a duplicate row.

const std = @import("std");
const C = @import("common.zig");
const F = @import("fixture.zig");
const R = @import("report.zig");
const T = @import("table.zig");

const eqs = std.testing.expectEqualStrings;
const expect = std.testing.expect;

/// The good report's row at N threads, with `wall_ns` and CPU time set so
/// the rows/s and efficiency are as the test wants.
fn rowAt(n: u64, wall_ns: u64, cpu_user_ns: u64) !R.Row {
    var r = (try F.report(&.{})).rows[0];
    r.threads = n;
    r.wall_ns = wall_ns;
    r.cpu_user_ns = cpu_user_ns;
    r.cpu_sys_ns = 0;
    return r;
}

fn withRows(rep: R.Report, rows: []const R.Row) R.Report {
    var out = rep;
    out.rows = C.a().dupe(R.Row, rows) catch C.oom();
    return out;
}

fn rendered(reports: []const R.Report) ![]const u8 {
    return T.render(reports) catch {
        std.debug.print("refused: {s}\n", .{C.msg});
        return error.TestUnexpectedResult;
    };
}

fn has(got: []const u8, want: []const u8) !void {
    if (std.mem.indexOf(u8, got, want) == null) {
        std.debug.print("missing {s}\nin:\n{s}\n", .{ want, got });
        return error.TestUnexpectedResult;
    }
}

test "table: numbers_flags_and_missing_lines" {
    // 1M rows: N=1 in 1 s (1M rows/s), N=4 in 0.5 s (2M rows/s, efficiency 0.5).
    // The N=4 row used 1.5 s of CPU, under 0.8 x 0.5 x 4 = 1.6 s: noisy.
    const r = withRows(try F.report(&.{}), &.{ try rowAt(1, 1_000_000_000, 1_000_000_000), try rowAt(4, 500_000_000, 1_500_000_000) });
    const want =
        \\# Parallelism table
        \\
        \\| variant | function | N | rows/s | rows/s per thread | efficiency | memory | latency ns (median / p90) | flags | run_id |
        \\| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        \\| v | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |
        \\| v | per_batch | 4 | 2000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | noisy | r1 |
        \\| v | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |
        \\
        \\## Reports
        \\
        \\- `komira//src/tests/e2e/x:x_bench[report]` run_id=r1: 8 cpus (Test CPU), cpu.max max 100000, nr_throttled +0, throttled_usec +0, loadavg 0.5 1 1.5; opt levels engine=O3 driver=O1; coverage no; versions python 3.13.9; warmup discarded 4/4
        \\
    ;
    try eqs(want, try rendered(&.{r}));
}

test "table: noisy_boundary" {
    // Exactly 0.8 x wall x N is not noisy; one nanosecond less is.
    try expect(!T.noisy(try rowAt(4, 1_000_000_000, 3_200_000_000)));
    try expect(T.noisy(try rowAt(4, 1_000_000_000, 3_199_999_999)));
    var r = try rowAt(1, 1_000_000_000, 700_000_000);
    r.cpu_sys_ns = 100_000_000;
    try expect(!T.noisy(r));
}

test "table: full_machine_row_is_measured" {
    // N equal to the host's CPUs is measured; only N above them is not.
    const r = withRows(try F.report(&.{}), &.{ try rowAt(1, 1_000_000_000, 1_000_000_000), try rowAt(8, 250_000_000, 2_000_000_000) });
    const got = try rendered(&.{r});
    try has(got, "| v | per_batch | 8 | 4000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |\n");
    // A missing line at N equal to the first report's CPUs reads `missing`.
    const r16 = withRows(try F.report(&.{.{ "\"cpus\": 8", "\"cpus\": 16" }}), &.{try rowAt(1, 1_000_000_000, 1_000_000_000)});
    try has(try rendered(&.{r16}), "| v | per_batch | 16 | missing | - | - | - | - | - | r1 |\n");
}

test "table: one_past_the_cpus" {
    // N one above the host's CPUs: a row at N=9 on 8 CPUs is not measured,
    // and a missing N=16 line on 15 CPUs reads `not measured`, not `missing`.
    const r9 = withRows(try F.report(&.{}), &.{ try rowAt(1, 1_000_000_000, 1_000_000_000), try rowAt(9, 1_000_000_000, 9_000_000_000) });
    try has(try rendered(&.{r9}), "| v | per_batch | 9 | not measured: 8 cpus | - | - | - | - | - | r1 |\n");
    const r15 = withRows(try F.report(&.{.{ "\"cpus\": 8", "\"cpus\": 15" }}), &.{try rowAt(1, 1_000_000_000, 1_000_000_000)});
    try has(try rendered(&.{r15}), "| v | per_batch | 16 | not measured: 15 cpus | - | - | - | - | - | r1 |\n");
}

test "table: two_functions_of_one_variant" {
    // A group is a variant and a function: two functions of one variant, each
    // at N=1, are two lines, not one N=1 written twice.
    var other = try rowAt(1, 500_000_000, 500_000_000);
    other.function = "per_row";
    const r = withRows(try F.report(&.{}), &.{ try rowAt(1, 1_000_000_000, 1_000_000_000), other });
    const got = try rendered(&.{r});
    try has(got, "| v | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |\n");
    try has(got, "| v | per_row | 1 | 2000000 | 2000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |\n");
}

test "table: over_cpus_missing_and_no_base" {
    // A 16-thread row on 8 CPUs is not measured whatever its numbers;
    // N=4 is missing (4 <= 8 CPUs); with no N=1 row, efficiency is "-";
    // a throttled count of 1 (the least above 0) flags the row.
    const r = withRows(
        try F.report(&.{.{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 1" }}),
        &.{ try rowAt(2, 1_000_000_000, 2_000_000_000), try rowAt(16, 1_000_000_000, 16_000_000_000) },
    );
    const got = try rendered(&.{r});
    try has(got, "| v | per_batch | 1 | missing | - | - | - | - | - | r1 |\n");
    try has(got, "| v | per_batch | 2 | 1000000 | 500000 | - | rss_delta_per_thread 1.0 MiB | 20 / 30 | throttled | r1 |\n");
    try has(got, "| v | per_batch | 4 | missing |");
    try has(got, "| v | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |\n");
    var ns = C.list([]const u8);
    var lines = std.mem.splitScalar(u8, got, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, "| v ")) continue;
        var cells = std.mem.splitSequence(u8, l, " | ");
        _ = cells.next();
        _ = cells.next();
        C.push([]const u8, &ns, cells.next().?);
    }
    try eqs("1 2 4 16", C.join(ns.items, " "));
}

test "table: several_reports_groups_and_duplicates" {
    const a = try F.report(&.{});
    const b = try F.report(&.{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"r0\"" },
        .{ "x:x_bench", "y:y_bench" },
        .{ "\"coverage\": false", "\"coverage\": true" },
        .{ "{\"python\": \"3.13.9\"}", "{}" },
        .{ "\"variant\": \"v\"", "\"variant\": \"w\"" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "{\"pss\": 1572864, \"uss\": 0}" },
    });
    const got = try rendered(&.{ a, b });
    try expect(std.mem.startsWith(u8, got, "# Parallelism table\n\nThe reports are of 2 runs: r0, r1.\n\n"));
    // Groups keep the order of the reports.
    const v = std.mem.indexOf(u8, got, "| v | per_batch | 1 |").?;
    const w = std.mem.indexOf(u8, got, "| w | per_batch | 1 | 1000000 | 1000000 | 1.00 | pss 1.5 MiB, uss 0.0 MiB |") orelse {
        std.debug.print("{s}\n", .{got});
        return error.TestUnexpectedResult;
    };
    try expect(v < w);
    try has(got, "- `komira//src/tests/e2e/y:y_bench[report]` run_id=r0: ");
    try has(got, "; coverage yes; versions -; ");
    // One run id: no runs line.
    try expect(std.mem.indexOf(u8, try rendered(&.{a}), "runs:") == null);
    // The same variant, function and N twice.
    if (T.render(&.{ a, a })) |_| return error.TestUnexpectedResult else |_| {}
    try eqs("v per_batch N=1 is in komira//src/tests/e2e/x:x_bench and in komira//src/tests/e2e/x:x_bench", C.msg);
}
