//! The command line's cases (cli.zig): usage errors, a refused report named
//! by its file, a line in two reports, reports merged in the order given, and
//! the table written only when every report passes.

const std = @import("std");
const C = @import("common.zig");
const F = @import("fixture.zig");
const cli = @import("cli.zig");

const eqs = std.testing.expectEqualStrings;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;

/// `F.good` as target y with two rows of variant w: per_row, then per_batch.
fn reversed() ![]const u8 {
    const start = std.mem.indexOf(u8, F.good, "    {\"variant\"").?;
    const end = std.mem.indexOf(u8, F.good, "}}\n  ]").? + 2;
    const row = F.good[start..end];
    const w = [2][]const u8{ "\"variant\": \"v\"", "\"variant\": \"w\"" };
    const first = try F.edit(row, &.{ w, .{ "per_batch", "per_row" } });
    const second = try F.edit(row, &.{w});
    return F.edit(F.good, &.{ .{ "x:x_bench", "y:y_bench" }, .{ row, C.fmt("{s},\n{s}", .{ first, second }) } });
}

fn files(path: []const u8) anyerror![]const u8 {
    if (C.eql(path, "good.json")) return F.good;
    if (C.eql(path, "reversed.json")) return reversed();
    if (C.eql(path, "z.json")) return F.edit(F.good, &.{ .{ "x:x_bench", "z:z_bench" }, .{ "\"variant\": \"v\"", "\"variant\": \"z\"" } });
    if (C.eql(path, "y_same_line.json")) return F.edit(F.good, &.{.{ "x:x_bench", "y:y_bench" }});
    if (C.eql(path, "broken.json")) return "{\"run_id\": ";
    if (C.eql(path, "bad_schema.json")) return F.edit(F.good, &.{.{ "\"cpus\": 8", "\"cpus\": 0" }});
    if (C.eql(path, "latin1.json")) return "\"caf\xe9\"";
    return error.FileNotFound;
}

fn refused(args: []const []const u8, code: u8, msg: []const u8) !void {
    switch (cli.run(args, files)) {
        .table => {
            std.debug.print("a table; want {s}\n", .{msg});
            return error.TestUnexpectedResult;
        },
        .refused => |r| {
            try eqs(msg, r.msg);
            try eq(code, r.code);
        },
    }
}

fn usage(args: []const []const u8, why: []const u8) !void {
    try refused(args, 2, C.fmt("bench_report: {s}\n{s}", .{ why, cli.usage }));
}

test "cli: usage_errors" {
    try usage(&.{}, "--out is required");
    try usage(&.{ "--out", "t.md" }, "at least one --report is required");
    try usage(&.{ "--report", "good.json" }, "--out is required");
    try usage(&.{"--out"}, "--out needs a value");
    try usage(&.{ "--out", "t.md", "--report" }, "--report needs a value");
    try usage(&.{ "--out", "a", "--out", "b", "--report", "good.json" }, "--out is given twice");
    try usage(&.{ "--out", "a", "good.json", "x" }, "unknown argument good.json");
}

test "cli: refused_reports_name_the_file" {
    try refused(&.{ "--out", "t.md", "--report", "good.json", "--report", "missing.json" }, 1, "bench_report: missing.json: cannot read: FileNotFound");
    try refused(&.{ "--out", "t.md", "--report", "latin1.json" }, 1, "bench_report: latin1.json: cannot read: not UTF-8");
    try refused(&.{ "--out", "t.md", "--report", "broken.json" }, 1, "bench_report: broken.json: not JSON: byte 11: unexpected end of input");
    try refused(&.{ "--out", "t.md", "--report", "bad_schema.json" }, 1, "bench_report: bad_schema.json: host.cpus: 0 is below 1");
    try refused(
        &.{ "--out", "t.md", "--report", "good.json", "--report", "good.json" },
        1,
        "bench_report: v per_batch N=1 is in komira//src/tests/e2e/x:x_bench and in komira//src/tests/e2e/x:x_bench",
    );
    // Two refused reports: only the first given is named, either way round.
    try refused(&.{ "--out", "t.md", "--report", "latin1.json", "--report", "broken.json" }, 1, "bench_report: latin1.json: cannot read: not UTF-8");
    try refused(&.{ "--out", "t.md", "--report", "broken.json", "--report", "latin1.json" }, 1, "bench_report: broken.json: not JSON: byte 11: unexpected end of input");
    // A file that cannot be read after one that is read but refused: the
    // first is named, so each file is checked before the next is read.
    try refused(&.{ "--out", "t.md", "--report", "broken.json", "--report", "missing.json" }, 1, "bench_report: broken.json: not JSON: byte 11: unexpected end of input");
    try refused(&.{ "--out", "t.md", "--report", "latin1.json", "--report", "missing.json" }, 1, "bench_report: latin1.json: cannot read: not UTF-8");
    // A line in two reports of different targets: the earlier one first,
    // in either order.
    try refused(
        &.{ "--out", "t.md", "--report", "good.json", "--report", "y_same_line.json" },
        1,
        "bench_report: v per_batch N=1 is in komira//src/tests/e2e/x:x_bench and in komira//src/tests/e2e/y:y_bench",
    );
    try refused(
        &.{ "--out", "t.md", "--report", "y_same_line.json", "--report", "good.json" },
        1,
        "bench_report: v per_batch N=1 is in komira//src/tests/e2e/y:y_bench and in komira//src/tests/e2e/x:x_bench",
    );
}

test "cli: merges_reports_in_order" {
    // Neither ascending nor descending: target y (variant w, per_row before
    // per_batch), then x (v), then z (z). Sorted either way, a group or a
    // report line moves.
    const t = switch (cli.run(&.{ "--out", "t.md", "--report", "reversed.json", "--report", "good.json", "--report", "z.json" }, files)) {
        .table => |t| t,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{r.msg});
            return error.TestUnexpectedResult;
        },
    };
    try eqs("t.md", t.out);
    try eqs("w per_row, w per_batch, v per_batch, z per_batch", F.groupOrder(t.md));
    const y = std.mem.indexOf(u8, t.md, "- `komira//src/tests/e2e/y:y_bench[report]` run_id=r1: ").?;
    const x = std.mem.indexOf(u8, t.md, "- `komira//src/tests/e2e/x:x_bench[report]` run_id=r1: ").?;
    const z = std.mem.indexOf(u8, t.md, "- `komira//src/tests/e2e/z:z_bench[report]` run_id=r1: ").?;
    try expect(y < x and x < z);
    // Three reports of one run: no runs line.
    try expect(std.mem.indexOf(u8, t.md, "runs:") == null);
}

var writes: usize = 0;
var wrote_path: []const u8 = "";
var wrote_data: []const u8 = "";

fn record(path: []const u8, data: []const u8) anyerror!void {
    writes += 1;
    wrote_path = path;
    wrote_data = data;
}

fn denied(_: []const u8, _: []const u8) anyerror!void {
    return error.AccessDenied;
}

test "cli: exec_writes_the_table_only_when_every_report_passes" {
    // Every report passes: the table is written once, to --out, exit 0, no message.
    writes = 0;
    const args = [_][]const u8{ "--out", "t.md", "--report", "good.json" };
    const ok = cli.exec(&args, files, record);
    try eq(@as(u8, 0), ok.code);
    try eqs("", ok.msg);
    try eq(@as(usize, 1), writes);
    try eqs("t.md", wrote_path);
    try eqs(cli.run(&args, files).table.md, wrote_data);
    // --report before --out: the table goes to the --out value.
    writes = 0;
    const late = cli.exec(&.{ "--report", "good.json", "--out", "late.md" }, files, record);
    try eq(@as(u8, 0), late.code);
    try eq(@as(usize, 1), writes);
    try eqs("late.md", wrote_path);
    // A refused report after a good one, and a usage error: nothing written.
    writes = 0;
    const bad = cli.exec(&.{ "--out", "t.md", "--report", "good.json", "--report", "broken.json" }, files, record);
    try eq(@as(u8, 1), bad.code);
    try eqs("bench_report: broken.json: not JSON: byte 11: unexpected end of input", bad.msg);
    const use = cli.exec(&.{"--out"}, files, record);
    try eq(@as(u8, 2), use.code);
    try eqs(C.fmt("bench_report: --out needs a value\n{s}", .{cli.usage}), use.msg);
    try eq(@as(usize, 0), writes);
    // The table cannot be written: exit 1, the file and the error named.
    const no = cli.exec(&args, files, denied);
    try eq(@as(u8, 1), no.code);
    try eqs("bench_report: cannot write t.md: AccessDenied", no.msg);
}
