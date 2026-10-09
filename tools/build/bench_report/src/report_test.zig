//! The schema check's cases (report.zig): a good report read field by
//! field, and each refusal with its path and reason.

const std = @import("std");
const C = @import("common.zig");
const F = @import("fixture.zig");

const eqs = std.testing.expectEqualStrings;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;

test "report: good_report" {
    const r = try F.report(&.{});
    try eqs("r1", r.run_id);
    try eqs("komira//src/tests/e2e/x:x_bench", r.target);
    const h = r.host;
    try eq(@as(u64, 8), h.cpus);
    try eqs("Test CPU", h.cpu_model);
    try eqs("max 100000", h.cpu_max);
    try eq([3]f64{ 0.5, 1, 1.5 }, h.loadavg);
    try eq(@as(u64, 0), h.nr_throttled_delta);
    try eq(@as(u64, 0), h.throttled_usec_delta);
    try eq(@as(usize, 2), r.build.opt_levels.len);
    try eqs("engine", r.build.opt_levels[0].k);
    try eqs("3", r.build.opt_levels[0].v);
    try eqs("driver", r.build.opt_levels[1].k);
    try eqs("1", r.build.opt_levels[1].v);
    try expect(!r.build.coverage);
    try eq(@as(usize, 1), r.build.versions.len);
    try eqs("python", r.build.versions[0].k);
    try eqs("3.13.9", r.build.versions[0].v);
    const row = r.rows[0];
    try eqs("v", row.variant);
    try eqs("per_batch", row.function);
    try eq([_]u64{ 1, 1000000, 100, 100, 1000000000 }, [_]u64{ row.threads, row.rows, row.batches, row.calls, row.wall_ns });
    try eq([_]u64{ 900000000, 100000000, 3 }, [_]u64{ row.cpu_user_ns, row.cpu_sys_ns, row.invol_ctx_switches });
    try eq(@as(usize, 1), row.memory.len);
    try eqs("rss_delta_per_thread", row.memory[0].k);
    try eq(@as(u64, 1048576), row.memory[0].bytes);
    try eq(@as(u64, 4), row.latency.warmup_discarded);
    try eq([_]u64{ 30, 10, 20, 30, 40 }, [_]u64{ row.latency.samples, row.latency.min, row.latency.median, row.latency.p90, row.latency.max });
}

test "report: each_value_from_its_own_key" {
    // The good report has samples equal to p90 (30) and both throttle counts
    // 0; here each differs, so a value stored in another field is seen.
    const r = try F.report(&.{
        .{ "\"nr_throttled_delta\": 0", "\"nr_throttled_delta\": 1" },
        .{ "\"throttled_usec_delta\": 0", "\"throttled_usec_delta\": 2500" },
        .{ "\"samples\": 30", "\"samples\": 31" },
    });
    try eq([_]u64{ 1, 2500 }, [_]u64{ r.host.nr_throttled_delta, r.host.throttled_usec_delta });
    const l = r.rows[0].latency;
    try eq([_]u64{ 4, 31, 10, 20, 30, 40 }, [_]u64{ l.warmup_discarded, l.samples, l.min, l.median, l.p90, l.max });
    // Each row is read from its own element: a second row differing in
    // every field the table reads.
    const second =
        \\,
        \\    {"variant": "w", "function": "per_row", "threads": 2, "rows": 7, "batches": 5, "calls": 5,
        \\     "wall_ns": 11, "cpu_user_ns": 12, "cpu_sys_ns": 13, "invol_ctx_switches": 14,
        \\     "memory": {"pss": 15},
        \\     "latency_ns": {"warmup_discarded": 16, "samples": 30, "min": 17, "median": 18, "p90": 19, "max": 20}}
        \\  ]
    ;
    const two = try F.report(&.{.{ "}}\n  ]", "}}" ++ second }});
    try eq(@as(usize, 2), two.rows.len);
    try eqs("v", two.rows[0].variant);
    const w = two.rows[1];
    try eqs("w", w.variant);
    try eqs("per_row", w.function);
    try eq([_]u64{ 2, 7, 5, 5, 11, 12, 13, 14 }, [_]u64{ w.threads, w.rows, w.batches, w.calls, w.wall_ns, w.cpu_user_ns, w.cpu_sys_ns, w.invol_ctx_switches });
    try eqs("pss", w.memory[0].k);
    try eq(@as(u64, 15), w.memory[0].bytes);
    try eq([_]u64{ 16, 30, 17, 18, 19, 20 }, [_]u64{ w.latency.warmup_discarded, w.latency.samples, w.latency.min, w.latency.median, w.latency.p90, w.latency.max });
}

test "report: variants_that_pass" {
    // Empty versions are allowed.
    try eq(@as(usize, 0), (try F.report(&.{.{ "{\"python\": \"3.13.9\"}", "{}" }})).build.versions.len);
    // Every memory kind is accepted, in the order written.
    const all = "{\"pss\": 1, \"uss\": 2, \"rss_delta_per_thread\": 3, \"memory_report\": 4}";
    const m = (try F.report(&.{.{ "{\"rss_delta_per_thread\": 1048576}", all }})).rows[0].memory;
    try eq(@as(usize, 4), m.len);
    try eqs("memory_report", m[3].k);
    try eq(@as(u64, 4), m[3].bytes);
    try expect((try F.report(&.{.{ "\"coverage\": false", "\"coverage\": true" }})).build.coverage);
    // A coarse timer: every quantile equal is in order.
    const flat = (try F.report(&.{.{ "\"min\": 10, \"median\": 20, \"p90\": 30, \"max\": 40", "\"min\": 7, \"median\": 7, \"p90\": 7, \"max\": 7" }})).rows[0].latency;
    try eq([_]u64{ 7, 7, 7, 7 }, [_]u64{ flat.min, flat.median, flat.p90, flat.max });
    // Counts at the bounds: 2^53, and samples exactly 30 (the good report's).
    try eq(@as(u64, 9007199254740992), (try F.report(&.{.{ "\"rows\": 1000000,", "\"rows\": 9007199254740992," }})).rows[0].rows);
    try eq(@as(u64, 9007199254740992), (try F.report(&.{.{ "\"rows\": 1000000,", "\"rows\": 9.007199254740992e15," }})).rows[0].rows);
    // Names may hold a-z 0-9 _ and ': each end of each range included.
    try eqs("a_9'", (try F.report(&.{.{ "\"variant\": \"v\"", "\"variant\": \"a_9'\"" }})).rows[0].variant);
    try eqs("az09_", (try F.report(&.{.{ "\"function\": \"per_batch\"", "\"function\": \"az09_\"" }})).rows[0].function);
    // Opt levels at both ends: "0" and "3" (the good report's engine).
    try eqs("0", (try F.report(&.{.{ "\"driver\": \"1\"", "\"driver\": \"0\"" }})).build.opt_levels[1].v);
}

test "report: boundaries_that_pass" {
    // Each count at its least allowed value, alone, and a load average of 0
    // (only a negative one is refused). Every case runs, and each one that is
    // refused is named, so one build shows which boundary moved.
    const cases = [_]struct { []const u8, []const [2][]const u8 }{
        .{ "cpus_1", &.{.{ "\"cpus\": 8", "\"cpus\": 1" }} },
        .{ "loadavg_0", &.{.{ "[0.5, 1, 1.5]", "[0, 0, 0]" }} },
        .{ "rows_1", &.{.{ "\"rows\": 1000000,", "\"rows\": 1," }} },
        .{ "batches_and_calls_1", &.{ .{ "\"batches\": 100", "\"batches\": 1" }, .{ "\"calls\": 100", "\"calls\": 1" } } },
        .{ "wall_ns_1", &.{.{ "\"wall_ns\": 1000000000", "\"wall_ns\": 1" }} },
        .{ "cpu_user_ns_0", &.{.{ "\"cpu_user_ns\": 900000000", "\"cpu_user_ns\": 0" }} },
        .{ "cpu_sys_ns_0", &.{.{ "\"cpu_sys_ns\": 100000000", "\"cpu_sys_ns\": 0" }} },
        .{ "invol_ctx_switches_0", &.{.{ "\"invol_ctx_switches\": 3", "\"invol_ctx_switches\": 0" }} },
        .{ "memory_bytes_0", &.{.{ "{\"rss_delta_per_thread\": 1048576}", "{\"rss_delta_per_thread\": 0}" }} },
        .{ "warmup_discarded_0", &.{.{ "\"warmup_discarded\": 4", "\"warmup_discarded\": 0" }} },
        .{ "latency_all_0", &.{.{ "\"min\": 10, \"median\": 20, \"p90\": 30, \"max\": 40", "\"min\": 0, \"median\": 0, \"p90\": 0, \"max\": 0" }} },
    };
    var bad: usize = 0;
    for (cases) |c| {
        if (F.checked(try F.edit(F.good, c[1]))) |_| {} else |_| {
            std.debug.print("{s}: refused: {s}\n", .{ c[0], C.msg });
            bad += 1;
        }
    }
    try eq(@as(usize, 0), bad);
}

fn refused(doc: []const u8, why: []const u8) !void {
    if (F.checked(doc)) |_| {
        std.debug.print("passed; want {s}\n", .{why});
        return error.TestUnexpectedResult;
    } else |_| try eqs(why, C.msg);
}

test "report: refusals" {
    const cases = [_][3][]const u8{
        .{ "\"run_id\": \"r1\"", "\"run_id\": \"\"", "run_id: is empty" },
        .{ "\"run_id\": \"r1\",\n", "", "run_id: missing" },
        .{ "\"target\": \"komira//src/tests/e2e/x:x_bench\"", "\"target\": 3", "target: is a number, not a string" },
        .{ "\"komira-bench-report-1\"", "\"komira-bench-report-2\"", "schema: is not \"komira-bench-report-1\"" },
        .{ "\"komira-bench-report-1\"", "1", "schema: is not \"komira-bench-report-1\"" },
        .{ "\"schema\"", "\"extra\": 1, \"schema\"", "extra: not a key of the schema" },
        .{ "\"cpus\": 8", "\"cpus\": 0", "host.cpus: 0 is below 1" },
        .{ "\"cpus\": 8", "\"cpus\": 8.5", "host.cpus: 8.5 is not a whole number from 0 to 2^53" },
        .{ "\"cpus\": 8", "\"cpus\": -1", "host.cpus: -1 is not a whole number from 0 to 2^53" },
        .{ "\"cpus\": 8", "\"cpus\": 1e16", "host.cpus: 10000000000000000 is not a whole number from 0 to 2^53" },
        .{ "\"cpus\": 8", "\"cpus\": 9007199254740994", "host.cpus: 9007199254740994 is not a whole number from 0 to 2^53" },
        .{ "\"cpus\": 8", "\"cpus\": \"8\"", "host.cpus: is a string, not a number" },
        .{ "[0.5, 1, 1.5]", "[0.5, 1]", "host.loadavg: is not an array of three numbers" },
        .{ "[0.5, 1, 1.5]", "{}", "host.loadavg: is not an array of three numbers" },
        .{ "[0.5, 1, 1.5]", "[0.5, -1, 1.5]", "host.loadavg[1]: -1 is negative" },
        .{ "[0.5, 1, 1.5]", "[0.5, 1, null]", "host.loadavg[2]: is null, not a number" },
        .{ "\"nr_throttled_delta\": 0,", "\"nr_throttled_delta\": 0, \"pid\": 1,", "host.pid: not a key of the schema" },
        .{ "\"cpu_max\": \"max 100000\", ", "", "host.cpu_max: missing" },
        .{ "\"host\": {", "\"host\": [], \"x\": {", "host: is an array, not an object" },
        .{ "\"engine\": \"3\"", "\"engine\": \"fast\"", "build.opt_levels.engine: 'fast' is not one of 0, 1, 2, 3" },
        .{ "\"engine\": \"3\"", "\"engine\": \"4\"", "build.opt_levels.engine: '4' is not one of 0, 1, 2, 3" },
        .{ "\"engine\": \"3\"", "\"engine\": \"33\"", "build.opt_levels.engine: '33' is not one of 0, 1, 2, 3" },
        .{ "{\"engine\": \"3\", \"driver\": \"1\"}", "{}", "build.opt_levels: is empty" },
        .{ "\"coverage\": false", "\"coverage\": \"no\"", "build.coverage: is a string, not a boolean" },
        .{ "\"python\": \"3.13.9\"", "\"python\": 3", "build.versions.python: is a number, not a string" },
        .{ "\"coverage\": false,", "\"coverage\": false, \"lto\": true,", "build.lto: not a key of the schema" },
        .{ "\"variant\": \"v\"", "\"variant\": \"V-1\"", "rows[0].variant: 'V-1' is not a name (a-z 0-9 _ ')" },
        .{ "\"function\": \"per_batch\"", "\"function\": \"\"", "rows[0].function: is empty" },
        .{ "\"threads\": 1", "\"threads\": 0", "rows[0].threads: 0 is below 1" },
        .{ "\"calls\": 100", "\"calls\": 1000000", "rows[0]: 1000000 runtime calls for 100 batches; a runtime is called once per batch" },
        .{ "\"calls\": 100", "\"calls\": 99", "rows[0]: 99 runtime calls for 100 batches; a runtime is called once per batch" },
        .{ "\"wall_ns\": 1000000000", "\"wall_ns\": 0", "rows[0].wall_ns: 0 is below 1" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "{}", "rows[0].memory: is empty" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "{\"rss\": 1}", "rows[0].memory.rss: not a memory kind (pss, uss, rss_delta_per_thread, memory_report)" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "{\"v8_heap\": 1}", "rows[0].memory.v8_heap: not a memory kind (pss, uss, rss_delta_per_thread, memory_report)" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "{\"pss\": -1}", "rows[0].memory.pss: -1 is not a whole number from 0 to 2^53" },
        .{ "{\"rss_delta_per_thread\": 1048576}", "7", "rows[0].memory: is a number, not an object" },
        .{ "\"samples\": 30", "\"samples\": 29", "rows[0].latency_ns.samples: 29 is below 30" },
        .{ "\"min\": 10", "\"min\": 21", "rows[0].latency_ns: min 21 <= median 20 <= p90 30 <= max 40 does not hold" },
        .{ "\"median\": 20", "\"median\": 31", "rows[0].latency_ns: min 10 <= median 31 <= p90 30 <= max 40 does not hold" },
        .{ "\"p90\": 30", "\"p90\": 41", "rows[0].latency_ns: min 10 <= median 20 <= p90 41 <= max 40 does not hold" },
        .{ "\"median\": 20", "\"median\": 9", "rows[0].latency_ns: min 10 <= median 9 <= p90 30 <= max 40 does not hold" },
        .{ "\"p90\": 30", "\"p90\": 19", "rows[0].latency_ns: min 10 <= median 20 <= p90 19 <= max 40 does not hold" },
        .{ "\"max\": 40", "\"max\": 29", "rows[0].latency_ns: min 10 <= median 20 <= p90 30 <= max 29 does not hold" },
        .{ "\"max\": 40", "\"max\": 40, \"mean\": 25", "rows[0].latency_ns.mean: not a key of the schema" },
        .{ "\"invol_ctx_switches\": 3,", "\"invol_ctx_switches\": 3, \"ok\": true,", "rows[0].ok: not a key of the schema" },
        // Just past each boundary: four loads, a count at 0 where 1 is the
        // least, and the byte next to each end of a name's and an opt level's
        // ranges.
        .{ "[0.5, 1, 1.5]", "[0.5, 1, 1.5, 2]", "host.loadavg: is not an array of three numbers" },
        .{ "\"rows\": 1000000,", "\"rows\": 0,", "rows[0].rows: 0 is below 1" },
        .{ "\"batches\": 100", "\"batches\": 0", "rows[0].batches: 0 is below 1" },
        .{ "\"variant\": \"v\"", "\"variant\": \"`\"", "rows[0].variant: '`' is not a name (a-z 0-9 _ ')" },
        .{ "\"variant\": \"v\"", "\"variant\": \"{\"", "rows[0].variant: '{' is not a name (a-z 0-9 _ ')" },
        .{ "\"variant\": \"v\"", "\"variant\": \"/\"", "rows[0].variant: '/' is not a name (a-z 0-9 _ ')" },
        .{ "\"variant\": \"v\"", "\"variant\": \":\"", "rows[0].variant: ':' is not a name (a-z 0-9 _ ')" },
        .{ "\"engine\": \"3\"", "\"engine\": \"/\"", "build.opt_levels.engine: '/' is not one of 0, 1, 2, 3" },
        // Capitals, refused for their case alone: one inside A-Z and each end.
        .{ "\"variant\": \"v\"", "\"variant\": \"V\"", "rows[0].variant: 'V' is not a name (a-z 0-9 _ ')" },
        .{ "\"variant\": \"v\"", "\"variant\": \"A\"", "rows[0].variant: 'A' is not a name (a-z 0-9 _ ')" },
        .{ "\"variant\": \"v\"", "\"variant\": \"Z\"", "rows[0].variant: 'Z' is not a name (a-z 0-9 _ ')" },
    };
    // Every case runs; each one that passes or fails otherwise is named.
    var bad: usize = 0;
    for (cases) |c| {
        const doc = try F.edit(F.good, &.{.{ c[0], c[1] }});
        refused(doc, c[2]) catch {
            std.debug.print("edit: {s} -> {s}\n", .{ c[0], c[1] });
            bad += 1;
        };
    }
    try eq(@as(usize, 0), bad);
    try refused("[]", "report: is an array, not an object");
    const rows_at = std.mem.indexOf(u8, F.good, "\"rows\": [").?;
    const head = F.good[0..rows_at];
    try refused(C.fmt("{s}\"rows\": []\n}}", .{head}), "rows: is empty");
    try refused(C.fmt("{s}\"rows\": {{}}\n}}", .{head}), "rows: is an object, not an array");
    try refused(C.fmt("{s}\"rows\": [[]]\n}}", .{head}), "rows[0]: is an array, not an object");
}
