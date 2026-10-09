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

/// `r` in `function` of `variant`.
fn named(r: R.Row, variant: []const u8, function: []const u8) R.Row {
    var o = r;
    o.variant = variant;
    o.function = function;
    return o;
}

/// `r` with its own latency median and p90, warm-up count and memory.
fn own(r: R.Row, median: u64, p90: u64, warmup: u64, memory: []const R.Mem) R.Row {
    var o = r;
    o.latency.median = median;
    o.latency.p90 = p90;
    o.latency.warmup_discarded = warmup;
    o.memory = memory;
    return o;
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
    // A missing line at N equal to the report's CPUs reads `missing`.
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

/// The table part of `got`, up to the report lines.
fn tablePart(got: []const u8) []const u8 {
    return got[0 .. std.mem.indexOf(u8, got, "\n## Reports").?];
}

test "table: each_line_reads_its_own_row" {
    // Every value a line shows differs between the rows, so a line that read
    // another row's (the group's first, or another group's) shows the wrong
    // number. per_batch: 1M rows/s at N=1, 2M at N=4 (efficiency 0.50);
    // per_row: 2M at N=1, 6.25M at N=4 (efficiency 0.78; against per_batch's
    // N=1 it would be 1.56). None is noisy and the host is not throttled.
    const mib = 1048576;
    const r = withRows(try F.report(&.{}), &.{
        own(try rowAt(1, 1_000_000_000, 1_000_000_000), 20, 30, 4, &.{.{ .k = "rss_delta_per_thread", .bytes = mib }}),
        own(try rowAt(4, 500_000_000, 2_000_000_000), 50, 70, 6, &.{.{ .k = "pss", .bytes = 2 * mib }}),
        named(own(try rowAt(1, 500_000_000, 500_000_000), 15, 25, 2, &.{.{ .k = "uss", .bytes = 3 * mib }}), "v", "per_row"),
        named(own(try rowAt(4, 160_000_000, 640_000_000), 11, 13, 9, &.{ .{ .k = "uss", .bytes = 4 * mib }, .{ .k = "memory_report", .bytes = mib / 2 } }), "v", "per_row"),
    });
    const want =
        \\# Parallelism table
        \\
        \\| variant | function | N | rows/s | rows/s per thread | efficiency | memory | latency ns (median / p90) | flags | run_id |
        \\| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        \\| v | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |
        \\| v | per_batch | 4 | 2000000 | 500000 | 0.50 | pss 2.0 MiB | 50 / 70 | - | r1 |
        \\| v | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |
        \\| v | per_row | 1 | 2000000 | 2000000 | 1.00 | uss 3.0 MiB | 15 / 25 | - | r1 |
        \\| v | per_row | 4 | 6250000 | 1562500 | 0.78 | uss 4.0 MiB, memory_report 0.5 MiB | 11 / 13 | - | r1 |
        \\| v | per_row | 16 | not measured: 8 cpus | - | - | - | - | - | r1 |
        \\
        \\## Reports
        \\
        \\- `komira//src/tests/e2e/x:x_bench[report]` run_id=r1: 8 cpus (Test CPU), cpu.max max 100000, nr_throttled +0, throttled_usec +0, loadavg 0.5 1 1.5; opt levels engine=O3 driver=O1; coverage no; versions python 3.13.9; warmup discarded 4/6/2/9
        \\
    ;
    try eqs(want, try rendered(&.{r}));
}

test "table: noisy_and_throttled" {
    // One row with both flags: 3 s of CPU is under 0.8 x 1 s x 4, and the
    // cgroup throttled the run.
    const r = withRows(
        try F.report(&.{.{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 1" }}),
        &.{try rowAt(4, 1_000_000_000, 3_000_000_000)},
    );
    try has(try rendered(&.{r}), "| v | per_batch | 4 | 1000000 | 250000 | - | rss_delta_per_thread 1.0 MiB | 20 / 30 | noisy, throttled | r1 |\n");
}

test "table: a_group_across_reports" {
    // One variant and function measured on hosts of 8 and 16 CPUs: each row
    // is judged by its own report's CPUs and throttling and carries its own
    // run id; a missing line by the report with the most CPUs (r2 before r3,
    // both 16).
    const a = withRows(try F.report(&.{}), &.{
        try rowAt(1, 1_000_000_000, 1_000_000_000),
        named(try rowAt(1, 1_000_000_000, 1_000_000_000), "v", "per_row"),
    });
    const b = withRows(try F.report(&.{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"r2\"" },
        .{ "x:x_bench", "y:y_bench" },
        .{ "\"cpus\": 8", "\"cpus\": 16" },
        .{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 1" },
    }), &.{
        try rowAt(16, 125_000_000, 2_000_000_000),
        named(try rowAt(4, 500_000_000, 2_000_000_000), "v", "per_row"),
        named(try rowAt(1, 1_000_000_000, 1_000_000_000), "w", "per_batch"),
    });
    const c = withRows(try F.report(&.{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"r3\"" },
        .{ "x:x_bench", "z:z_bench" },
        .{ "\"cpus\": 8", "\"cpus\": 16" },
    }), &.{named(try rowAt(2, 1_000_000_000, 2_000_000_000), "v", "per_row")});
    const d = withRows(try F.report(&.{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"r4\"" },
        .{ "x:x_bench", "u:u_bench" },
    }), &.{named(try rowAt(16, 1_000_000_000, 16_000_000_000), "w", "per_batch")});
    const want =
        \\# Parallelism table
        \\
        \\The reports are of 4 runs: r1, r2, r3, r4.
        \\
        \\| variant | function | N | rows/s | rows/s per thread | efficiency | memory | latency ns (median / p90) | flags | run_id |
        \\| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
        \\| v | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |
        \\| v | per_batch | 4 | missing | - | - | - | - | - | r2 |
        \\| v | per_batch | 16 | 8000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | throttled | r2 |
        \\| v | per_row | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r1 |
        \\| v | per_row | 2 | 1000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | - | r3 |
        \\| v | per_row | 4 | 2000000 | 500000 | 0.50 | rss_delta_per_thread 1.0 MiB | 20 / 30 | throttled | r2 |
        \\| v | per_row | 16 | missing | - | - | - | - | - | r2 |
        \\| w | per_batch | 1 | 1000000 | 1000000 | 1.00 | rss_delta_per_thread 1.0 MiB | 20 / 30 | throttled | r2 |
        \\| w | per_batch | 4 | missing | - | - | - | - | - | r2 |
        \\| w | per_batch | 16 | not measured: 8 cpus | - | - | - | - | - | r4 |
        \\
    ;
    try eqs(want, tablePart(try rendered(&.{ a, b, c, d })));
}

test "table: facts_line_per_report" {
    // Two reports differing in every fact, each value distinct within its
    // line (throttled count 1 and 2500 us; 7 and 900), so a fact read from
    // the wrong field or the wrong report changes a line.
    const a = withRows(try F.report(&.{
        .{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 1" },
        .{ "\"throttled_usec_delta\": 0", "\"throttled_usec_delta\": 2500" },
        .{ "{\"python\": \"3.13.9\"}", "{\"python\": \"3.13.9\", \"zig\": \"0.12.0\"}" },
    }), &.{
        try rowAt(1, 1_000_000_000, 1_000_000_000),
        named(own(try rowAt(1, 1_000_000_000, 1_000_000_000), 20, 30, 6, &.{.{ .k = "pss", .bytes = 1 }}), "v", "per_row"),
    });
    const b = try F.report(&.{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"r0\"" },
        .{ "x:x_bench", "y:y_bench" },
        .{ "\"cpus\": 8", "\"cpus\": 16" },
        .{ "Test CPU", "Other CPU" },
        .{ "max 100000", "200000 100000" },
        .{ "[0.5, 1, 1.5]", "[2, 3.25, 4]" },
        .{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 7" },
        .{ "\"throttled_usec_delta\": 0", "\"throttled_usec_delta\": 900" },
        .{ "{\"engine\": \"3\", \"driver\": \"1\"}", "{\"engine\": \"2\"}" },
        .{ "\"coverage\": false", "\"coverage\": true" },
        .{ "{\"python\": \"3.13.9\"}", "{}" },
        .{ "\"variant\": \"v\"", "\"variant\": \"w\"" },
        .{ "\"warmup_discarded\": 4", "\"warmup_discarded\": 5" },
    });
    const got = try rendered(&.{ a, b });
    const want =
        \\- `komira//src/tests/e2e/x:x_bench[report]` run_id=r1: 8 cpus (Test CPU), cpu.max max 100000, nr_throttled +1, throttled_usec +2500, loadavg 0.5 1 1.5; opt levels engine=O3 driver=O1; coverage no; versions python 3.13.9, zig 0.12.0; warmup discarded 4/6
        \\- `komira//src/tests/e2e/y:y_bench[report]` run_id=r0: 16 cpus (Other CPU), cpu.max 200000 100000, nr_throttled +7, throttled_usec +900, loadavg 2 3.25 4; opt levels engine=O2; coverage yes; versions -; warmup discarded 5
        \\
    ;
    try eqs(want, got[std.mem.indexOf(u8, got, "\n## Reports\n\n").? + 13 ..]);
}

/// `F.good` as the report of target `<t>:<t>_bench`, with `rows`.
fn at(t: []const u8, rows: []const R.Row) !R.Report {
    const target = C.fmt("{s}:{s}_bench", .{ t, t });
    return withRows(try F.report(&.{.{ "x:x_bench", target }}), rows);
}

fn one(variant: []const u8, function: []const u8) !R.Row {
    return named(try rowAt(1, 1_000_000_000, 1_000_000_000), variant, function);
}

test "table: groups_and_reports_keep_the_order_given" {
    // Neither ascending nor descending: variant w before v, per_row before
    // per_batch in the first report and after it in the second, then u; the
    // reports' targets y, x, z. Sorted either way, a group or a report line
    // moves.
    const got = try rendered(&.{
        try at("y", &.{ try one("w", "per_row"), try one("w", "per_batch") }),
        try at("x", &.{ try one("v", "per_batch"), try one("v", "per_row") }),
        try at("z", &.{try one("u", "per_batch")}),
    });
    try eqs("w per_row, w per_batch, v per_batch, v per_row, u per_batch", F.groupOrder(got));
    const y = std.mem.indexOf(u8, got, "- `komira//src/tests/e2e/y:y_bench[report]`").?;
    const x = std.mem.indexOf(u8, got, "- `komira//src/tests/e2e/x:x_bench[report]`").?;
    const z = std.mem.indexOf(u8, got, "- `komira//src/tests/e2e/z:z_bench[report]`").?;
    try expect(y < x and x < z);
}

test "table: runs_line_names_each_run_once" {
    // Two reports of one run (r1): no runs line.
    const a = try at("x", &.{try one("v", "per_batch")});
    const b = try at("y", &.{try one("w", "per_batch")});
    const c = withRows(try F.report(&.{ .{ "\"run_id\": \"r1\"", "\"run_id\": \"r2\"" }, .{ "x:x_bench", "z:z_bench" } }), &.{try one("u", "per_batch")});
    try expect(std.mem.startsWith(u8, try rendered(&.{ a, b }), "# Parallelism table\n\n| variant |"));
    // Run ids r1, r1, r2 in any order (the repeat adjacent, apart, or
    // after r2): two runs, each named once, sorted.
    const want = "# Parallelism table\n\nThe reports are of 2 runs: r1, r2.\n\n| variant |";
    try expect(std.mem.startsWith(u8, try rendered(&.{ a, b, c }), want));
    try expect(std.mem.startsWith(u8, try rendered(&.{ a, c, b }), want));
    try expect(std.mem.startsWith(u8, try rendered(&.{ c, a, b }), want));
}

test "table: duplicate_names_the_earlier_target_first" {
    // u per_row N=4 in the second (y) and third (z) reports, after a first
    // (x) without it: the message names y, then z.
    const four = named(try rowAt(4, 1_000_000_000, 4_000_000_000), "u", "per_row");
    const x = try at("x", &.{try one("v", "per_batch")});
    if (T.render(&.{ x, try at("y", &.{four}), try at("z", &.{four}) })) |_| return error.TestUnexpectedResult else |_| {}
    try eqs("u per_row N=4 is in komira//src/tests/e2e/y:y_bench and in komira//src/tests/e2e/z:z_bench", C.msg);
}
