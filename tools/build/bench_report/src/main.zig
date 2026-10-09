//! bench_report: checks bench reports against their schema and merges them
//! into the parallelism table (README.md).
//!
//!   bench_report --out <table.md> --report <report.json> [--report <report.json>]...
//!
//! Each `--report` is the `[report]` of a report test (a `py_test` with a
//! `run_id`): one JSON object of the schema in report.zig. The table
//! (table.zig) is written to `--out` only if every report passes the check.
//! Exit status 2 is a usage error, 1 a report that is refused, with
//! `bench_report: <file>: <where>: <why>` on standard error.

const std = @import("std");
const C = @import("common.zig");
const cli = @import("cli.zig");

fn readFile(path: []const u8) anyerror![]const u8 {
    return std.fs.cwd().readFileAlloc(C.a(), path, std.math.maxInt(usize));
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(data);
}

pub fn main() void {
    const raw = std.process.argsAlloc(C.a()) catch C.oom();
    const args = C.a().alloc([]const u8, raw.len - 1) catch C.oom();
    for (raw[1..], 0..) |arg, i| args[i] = arg;
    const stderr = std.io.getStdErr();
    switch (cli.run(args, readFile)) {
        .table => |t| writeFile(t.out, t.md) catch |e| {
            stderr.writeAll(C.fmt("bench_report: cannot write {s}: {s}\n", .{ t.out, @errorName(e) })) catch {};
            std.process.exit(1);
        },
        .refused => |r| {
            stderr.writeAll(C.fmt("{s}\n", .{r.msg})) catch {};
            std.process.exit(r.code);
        },
    }
}

// The unit tests, run by `zig test` on this file (BUCK: `:bench_report_unit`).
test {
    _ = @import("json_test.zig");
    _ = @import("report_test.zig");
    _ = @import("table_test.zig");
    _ = @import("cli_test.zig");
}
