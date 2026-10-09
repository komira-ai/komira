//! Test-only: a report that passes the check, and helpers that edit it.

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");
const R = @import("report.zig");

/// A report that passes the check; tests edit one value of it.
pub const good =
    \\{
    \\  "run_id": "r1",
    \\  "target": "komira//src/tests/e2e/x:x_bench",
    \\  "schema": "komira-bench-report-1",
    \\  "host": {"cpus": 8, "cpu_model": "Test CPU", "cpu_max": "max 100000", "loadavg": [0.5, 1, 1.5],
    \\           "nr_throttled_delta": 0, "throttled_usec_delta": 0},
    \\  "build": {"opt_levels": {"engine": "3", "driver": "1"}, "coverage": false, "versions": {"python": "3.13.9"}},
    \\  "rows": [
    \\    {"variant": "v", "function": "per_batch", "threads": 1, "rows": 1000000, "batches": 100, "calls": 100,
    \\     "wall_ns": 1000000000, "cpu_user_ns": 900000000, "cpu_sys_ns": 100000000, "invol_ctx_switches": 3,
    \\     "memory": {"rss_delta_per_thread": 1048576},
    \\     "latency_ns": {"warmup_discarded": 4, "samples": 30, "min": 10, "median": 20, "p90": 30, "max": 40}}
    \\  ]
    \\}
;

/// `doc` with each edit's `from` (which must occur exactly once) replaced.
pub fn edit(doc: []const u8, edits: []const [2][]const u8) ![]const u8 {
    var out: []const u8 = doc;
    for (edits) |e| {
        out = C.replaceOnce(out, e[0], e[1]) orelse {
            std.debug.print("not exactly once: {s}\n", .{e[0]});
            return error.TestUnexpectedResult;
        };
    }
    return out;
}

/// The check of `doc`, which must parse.
pub fn checked(doc: []const u8) C.Fail!R.Report {
    const v = J.parse(doc) catch @panic("a test document does not parse");
    return R.check(v);
}

/// `good` with `edits`, checked, which must pass.
pub fn report(edits: []const [2][]const u8) !R.Report {
    return checked(try edit(good, edits)) catch {
        std.debug.print("refused: {s}\n", .{C.msg});
        return error.TestUnexpectedResult;
    };
}

/// The variant and function of each N=1 line of a rendered table, in table
/// order: the order of its groups.
pub fn groupOrder(md: []const u8) []const u8 {
    var names = C.list([]const u8);
    const table = md[0 .. std.mem.indexOf(u8, md, "\n## Reports").?];
    var lines = std.mem.splitScalar(u8, table, '\n');
    while (lines.next()) |l| {
        var cells = std.mem.splitSequence(u8, l, " | ");
        const variant = cells.next() orelse continue;
        const function = cells.next() orelse continue;
        const n = cells.next() orelse continue;
        if (C.eql(n, "1")) C.push([]const u8, &names, C.fmt("{s} {s}", .{ variant[2..], function }));
    }
    return C.join(names.items, ", ");
}
