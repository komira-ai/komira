//! The command line: the arguments in, the table and where it goes out, or
//! an exit status and the message for standard error. main.zig reads the
//! files and writes the table; the tests (cli_test.zig) give `run` a reader
//! of their own.

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");
const R = @import("report.zig");
const T = @import("table.zig");

pub const usage = "usage: bench_report --out <table.md> --report <report.json> [--report <report.json>]...";

/// The table and its path, or the exit status (2 a usage error, 1 a refused
/// report) and the message.
pub const Outcome = union(enum) {
    table: struct { out: []const u8, md: []const u8 },
    refused: struct { code: u8, msg: []const u8 },
};

/// Reads the file at a path: its bytes, or an error whose name the message
/// gives.
pub const Reader = *const fn (path: []const u8) anyerror![]const u8;

fn usageError(why: []const u8) Outcome {
    return .{ .refused = .{ .code = 2, .msg = C.fmt("bench_report: {s}\n{s}", .{ why, usage }) } };
}

fn refusedReport(path: []const u8, why: []const u8) Outcome {
    return .{ .refused = .{ .code = 1, .msg = C.fmt("bench_report: {s}: {s}", .{ path, why }) } };
}

/// What `bench_report <args>` does (`args` without the program name).
pub fn run(args: []const []const u8, read: Reader) Outcome {
    var out: ?[]const u8 = null;
    var paths = C.list([]const u8);
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return usageError(C.fmt("{s} needs a value", .{args[i]}));
        const v = args[i + 1];
        if (C.eql(args[i], "--out")) {
            if (out != null) return usageError("--out is given twice");
            out = v;
        } else if (C.eql(args[i], "--report")) {
            C.push([]const u8, &paths, v);
        } else return usageError(C.fmt("unknown argument {s}", .{args[i]}));
    }
    const dest = out orelse return usageError("--out is required");
    if (paths.items.len == 0) return usageError("at least one --report is required");
    var reports = C.list(R.Report);
    for (paths.items) |p| {
        const text = read(p) catch |e| return refusedReport(p, C.fmt("cannot read: {s}", .{@errorName(e)}));
        if (!std.unicode.utf8ValidateSlice(text)) return refusedReport(p, "cannot read: not UTF-8");
        const doc = J.parse(text) catch return refusedReport(p, C.fmt("not JSON: {s}", .{C.msg}));
        C.push(R.Report, &reports, R.check(doc) catch return refusedReport(p, C.msg));
    }
    const md = T.render(reports.items) catch return .{ .refused = .{ .code = 1, .msg = C.fmt("bench_report: {s}", .{C.msg}) } };
    return .{ .table = .{ .out = dest, .md = md } };
}
