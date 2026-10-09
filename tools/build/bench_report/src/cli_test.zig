//! The command line's cases (cli.zig): usage errors, a refused report named
//! by its file, and reports merged in the order given.

const std = @import("std");
const C = @import("common.zig");
const F = @import("fixture.zig");
const cli = @import("cli.zig");

const eqs = std.testing.expectEqualStrings;
const eq = std.testing.expectEqual;
const expect = std.testing.expect;

fn files(path: []const u8) anyerror![]const u8 {
    if (C.eql(path, "good.json")) return F.good;
    if (C.eql(path, "other.json")) return F.edit(F.good, &.{ .{ "x:x_bench", "y:y_bench" }, .{ "\"variant\": \"v\"", "\"variant\": \"w\"" } });
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
}

test "cli: merges_reports_in_order" {
    const t = switch (cli.run(&.{ "--out", "t.md", "--report", "good.json", "--report", "other.json" }, files)) {
        .table => |t| t,
        .refused => |r| {
            std.debug.print("refused: {s}\n", .{r.msg});
            return error.TestUnexpectedResult;
        },
    };
    try eqs("t.md", t.out);
    const v = std.mem.indexOf(u8, t.md, "| v | per_batch | 1 | 1000000 |").?;
    const w = std.mem.indexOf(u8, t.md, "| w | per_batch | 1 | 1000000 |").?;
    try expect(v < w);
    try expect(std.mem.indexOf(u8, t.md, "- `komira//src/tests/e2e/y:y_bench[report]` run_id=r1: ") != null);
}
