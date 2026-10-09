//! The command line: the arguments in, the table and where it goes out, or
//! an exit status and the message for standard error. main.zig gives `exec`
//! the file system; the tests (cli_test.zig) give it a reader and a writer
//! of their own.
//!
//! The messages on standard error (the first refusal only):
//!   exit 2   bench_report: <why>                      and the usage line under it
//!   exit 1   bench_report: <file>: cannot read: <error name>
//!            bench_report: <file>: cannot read: not UTF-8
//!            bench_report: <file>: not JSON: byte <offset>: <why>
//!            bench_report: <file>: <where>: <why>     the schema check (report.zig)
//!            bench_report: <variant> <function> N=<n> is in <target> and in <target>
//!                                                     the earlier report's target first
//!            bench_report: cannot write <file>: <error name>

const std = @import("std");
const C = @import("common.zig");
const J = @import("json.zig");
const R = @import("report.zig");
const T = @import("table.zig");

pub const usage = "usage: bench_report --out <table.md> --report <report.json> [--report <report.json>]...";

/// The table and its path, or the exit status (2 a usage error, 1 a refused
/// report or two reports holding one line) and the message.
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

/// Writes `data` to the file at a path.
pub const Writer = *const fn (path: []const u8, data: []const u8) anyerror!void;

/// The exit status and the message for standard error ("" for none).
pub const Exit = struct { code: u8, msg: []const u8 };

/// What `bench_report <args>` does, start to end: the table is written only
/// when every report passes.
pub fn exec(args: []const []const u8, read: Reader, write: Writer) Exit {
    switch (run(args, read)) {
        .table => |t| {
            write(t.out, t.md) catch |e| return .{ .code = 1, .msg = C.fmt("bench_report: cannot write {s}: {s}", .{ t.out, @errorName(e) }) };
            return .{ .code = 0, .msg = "" };
        },
        .refused => |r| return .{ .code = r.code, .msg = r.msg },
    }
}

/// What `bench_report <args>` decides (`args` without the program name).
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
